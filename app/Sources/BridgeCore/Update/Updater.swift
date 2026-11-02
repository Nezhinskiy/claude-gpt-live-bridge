import CryptoKit
import Darwin
import Foundation

/// Where an update check or install stands, for the Settings window and the menu.
public enum UpdateStatus: Equatable, Sendable {
  case idle
  case checking
  case upToDate
  case available(Release)
  case downloading
  case verifying
  case waiting
  case updatingMod
  case installing
  case failed(UpdateProblem)
}

/// Checks for a release and installs it: download, proof of origin with `gh`, bundle checks,
/// staging, the mod, the swap and the relaunch (the spec's "How an update runs"). One run at a
/// time: a second check or install while one runs is refused, and the run holds `updates/lock`
/// so a second instance of the app cannot run one beside it. Every program starts through
/// `environment.run`.
public actor Updater {
  /// The time a check-like program (`gh`, `hdiutil`, `codesign`, `ditto`, `xattr`) is given.
  static let checkTimeout: Duration = .seconds(30)
  /// The largest image downloaded.
  static let imageLimit = 100 * 1024 * 1024
  static let repository = "getLiveBridge/LiveBridge"
  static let signerWorkflow = "getLiveBridge/LiveBridge/.github/workflows/release.yml"

  private let environment: any UpdateEnvironment
  private let paths: UpdatePaths
  private let running: AppVersion
  private let hasOpenRequests: @Sendable () async -> Bool
  private let stopCall: @Sendable () async -> Void
  private let quit: @Sendable () -> Void
  private let pid: Int32
  private let stream: AsyncStream<UpdateStatus>
  private let continuation: AsyncStream<UpdateStatus>.Continuation
  /// A check or install is under way in this actor.
  private var busy = false

  public private(set) var status: UpdateStatus = .idle

  /// Every status as it is set.
  public nonisolated var statuses: AsyncStream<UpdateStatus> { stream }

  public init(
    environment: any UpdateEnvironment, paths: UpdatePaths, running: AppVersion,
    hasOpenRequests: @escaping @Sendable () async -> Bool,
    stopCall: @escaping @Sendable () async -> Void, quit: @escaping @Sendable () -> Void,
    pid: Int32
  ) {
    self.environment = environment
    self.paths = paths
    self.running = running
    self.hasOpenRequests = hasOpenRequests
    self.stopCall = stopCall
    self.quit = quit
    self.pid = pid
    (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
  }

  /// Asks GitHub for the latest release: `available` when it is newer than the running app.
  public func check() async -> UpdateStatus {
    guard !busy else { return .failed(.busy) }
    guard begin() else { return status }
    defer { end() }
    set(.checking)
    do throws(UpdateProblem) {
      let release = try Release.parse(try await environment.fetchLatest())
      set(release.version > running ? .available(release) : .upToDate)
    } catch {
      set(.failed(error))
    }
    return status
  }

  /// Why the image could not be verified on this Mac: `gh` missing or signed out; nil when it
  /// can be.
  public func verifierProblem() async -> UpdateProblem? {
    guard let gh = await environment.locate("gh") else { return .ghMissing }
    let answer = await environment.run(
      gh, ["auth", "status"], cwd: paths.dataDir, timeout: Self.checkTimeout)
    return answer?.status == 0 ? nil : .ghSignedOut
  }

  /// Installs `release`. The outcome is in `status`; on success the app relaunches and quits.
  public func install(_ release: Release) async {
    guard !busy, begin() else { return }
    defer { end() }
    let folder = paths.updates.appending(path: release.version.description)
    defer { try? FileManager.default.removeItem(at: folder) }
    do throws(UpdateProblem) {
      if let problem = await verifierProblem() { throw problem }
      set(.downloading)
      let image = try await download(release, into: folder)
      set(.verifying)
      try await verifyOrigin(image, version: release.version)
    } catch {
      set(.failed(error))
    }
  }

  // MARK: The run

  /// Starts a run: takes `updates/lock`, or reports `busy` when another instance holds it.
  private func begin() -> Bool {
    let lock = paths.updates.appending(path: "lock")
    try? FileManager.default.createDirectory(at: paths.updates, withIntermediateDirectories: true)
    let file = open(lock.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
    guard file >= 0 else {
      set(.failed(.busy))
      return false
    }
    close(file)
    busy = true
    return true
  }

  private func end() {
    busy = false
    try? FileManager.default.removeItem(at: paths.updates.appending(path: "lock"))
  }

  private func set(_ next: UpdateStatus) {
    status = next
    continuation.yield(next)
  }

  // MARK: Download and verify

  /// Downloads the release's image into a fresh `folder` and returns it.
  private func download(_ release: Release, into folder: URL) async throws(UpdateProblem) -> URL {
    let files = FileManager.default
    try? files.removeItem(at: folder)
    do {
      try files.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      throw .network("The update folder could not be created.")
    }
    let image = folder.appending(path: Release.imageName)
    try await environment.download(release.imageURL, to: image, maxBytes: Self.imageLimit)
    return image
  }

  /// Requires `gh attestation verify` to pass for `image`, pinned to this repository, the
  /// release workflow, the version's tag and GitHub's own runners, and the attested digest to
  /// be the image's SHA-256.
  private func verifyOrigin(_ image: URL, version: AppVersion) async throws(UpdateProblem) {
    guard let digest = Self.sha256(of: image) else {
      throw .network("The downloaded image could not be read.")
    }
    guard let gh = await environment.locate("gh") else { throw .ghMissing }
    let arguments = [
      "attestation", "verify", image.path, "--repo", Self.repository, "--signer-workflow",
      Self.signerWorkflow, "--source-ref", "refs/tags/\(version.tag)",
      "--deny-self-hosted-runners", "--format", "json",
    ]
    let answer = await environment.run(
      gh, arguments, cwd: paths.dataDir, timeout: Self.checkTimeout)
    guard let answer, answer.status == 0,
      let results = try? JSONDecoder().decode([Attestation].self, from: Data(answer.output.utf8))
    else { throw .attestationFailed }
    let attested = results.flatMap(\.verificationResult.statement.subject).map {
      $0.digest.sha256.lowercased()
    }
    guard attested.contains(digest) else { throw .digestMismatch }
  }

  /// The lowercase hex SHA-256 of `file`, read in pieces, or nil when it cannot be read.
  static func sha256(of file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    do {
      while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
    } catch {
      return nil
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// One result of `gh attestation verify --format json`, only the part that names the digest.
  private struct Attestation: Decodable {
    let verificationResult: Verification

    struct Verification: Decodable { let statement: Statement }
    struct Statement: Decodable { let subject: [Subject] }
    struct Subject: Decodable { let digest: Digest }
    struct Digest: Decodable { let sha256: String }
  }
}
