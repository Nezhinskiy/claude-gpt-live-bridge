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
  /// The time each `claude` command is given.
  static let claudeTimeout: Duration = .seconds(120)
  /// The largest image downloaded.
  static let imageLimit = 100 * 1024 * 1024
  static let repository = "getLiveBridge/LiveBridge"
  static let signerWorkflow = "getLiveBridge/LiveBridge/.github/workflows/release.yml"
  static let hdiutil = URL(filePath: "/usr/bin/hdiutil")
  static let codesign = URL(filePath: "/usr/bin/codesign")
  static let ditto = URL(filePath: "/usr/bin/ditto")
  static let xattr = URL(filePath: "/usr/bin/xattr")
  static let quarantine = "com.apple.quarantine"
  /// The start of a staged copy's name in `/Applications`.
  static let stagedPrefix = ".LiveBridge-update-"
  /// The commands that update the mod, run in this order; `UpdateRecord.byHandCommands` are
  /// the same for the owner.
  static let modCommands = [
    ["plugin", "marketplace", "update", "livebridge"],
    ["plugin", "update", "livebridge@livebridge"],
  ]
  static let modID = "livebridge@livebridge"

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
    let version = release.version
    let folder = paths.updates.appending(path: version.description)
    defer { try? FileManager.default.removeItem(at: folder) }
    var staged: URL?
    do throws(UpdateProblem) {
      guard version > running else { throw .notNewer }
      if let problem = await verifierProblem() { throw problem }
      set(.downloading)
      let image = try await download(release, into: folder)
      set(.verifying)
      try await verifyOrigin(image, version: version)
      let checked = try await stage(image, in: folder, version: version)
      staged = checked.copy
      try await settle(checked)
      await waitForQuiet()
      set(.updatingMod)
      let mod = await updateMod(to: version)
      await waitForQuiet()
      set(.installing)
      await stopCall()
      try await swapIn(checked)
      staged = nil
      try? UpdateRecord(from: running, to: version, mod: mod, noticePosted: false)
        .write(paths.updates.appending(path: "record.json"))
    } catch {
      if let staged { try? FileManager.default.removeItem(at: staged) }
      set(.failed(error))
      return
    }
    try? environment.relaunch(pid: pid, app: paths.installed)
    quit()
  }

  /// What the app does at launch: removes every staged copy in `/Applications` (the previous
  /// bundle, or a copy a failed run left) and every image folder and lock in `updates`, and
  /// returns the record an update left. An `updates` that is a symbolic link is left alone and
  /// gives no record; a staged name that is a symbolic link is unlinked, never followed.
  public static func cleanUp(paths: UpdatePaths) -> UpdateRecord? {
    let files = FileManager.default
    for name in (try? files.contentsOfDirectory(atPath: paths.applications.path)) ?? []
    where name.hasPrefix(stagedPrefix) && name.hasSuffix(".app") {
      try? files.removeItem(at: paths.applications.appending(path: name))
    }
    guard UpdateBundleCheck.isDirectory(paths.updates) else { return nil }
    let record = UpdateRecord.read(paths.updates.appending(path: "record.json"))
    for name in (try? files.contentsOfDirectory(atPath: paths.updates.path)) ?? []
    where name == "lock" || AppVersion(name) != nil {
      try? files.removeItem(at: paths.updates.appending(path: name))
    }
    return record
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

  // MARK: Stage, wait and update the mod

  /// A staged copy in `/Applications` and the CDHash its app had in the image.
  struct Staged {
    let copy: URL
    let cdhash: String
  }

  /// Attaches the image, checks its app and copies it into a new staged copy; the image is
  /// detached on every path. A failure after the staged copy exists removes it.
  private func stage(_ image: URL, in folder: URL, version: AppVersion) async throws(UpdateProblem)
    -> Staged
  {
    let arguments = [
      "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountrandom", folder.path, "-plist",
      image.path,
    ]
    let attach = await environment.run(
      Self.hdiutil, arguments, cwd: nil, timeout: Self.checkTimeout)
    guard let attach, attach.status == 0 else { throw .noApp }
    let volume = UpdateBundleCheck.volume(attachPlist: attach.output)
    defer {
      if let device = volume.device {
        _ = await environment.run(
          Self.hdiutil, ["detach", device], cwd: nil, timeout: Self.checkTimeout)
      }
    }
    guard let mountPoint = volume.mountPoint else { throw .noApp }
    let app = mountPoint.appending(path: "LiveBridge.app")
    let cdhash = try await checkBundle(app, version: version)
    let copy = paths.applications.appending(path: "\(Self.stagedPrefix)\(UUID().uuidString).app")
    guard mkdir(copy.path, 0o755) == 0 else { throw .notWritable }
    let ditto = await environment.run(
      Self.ditto, [app.path, copy.path], cwd: nil, timeout: Self.checkTimeout)
    guard ditto?.status == 0 else {
      try? FileManager.default.removeItem(at: copy)
      throw .notWritable
    }
    return Staged(copy: copy, cdhash: cdhash)
  }

  /// Requires the app in the image to be LiveBridge at `version`, runnable on this macOS and
  /// validly signed, and returns its CDHash.
  private func checkBundle(_ app: URL, version: AppVersion) async throws(UpdateProblem) -> String {
    guard UpdateBundleCheck.isDirectory(app),
      let info = UpdateBundleCheck.info(app.appending(path: "Contents/Info.plist"))
    else { throw .noApp }
    let identifier = info["CFBundleIdentifier"] as? String ?? ""
    guard identifier == Paths.bundleID else { throw .wrongBundle(identifier) }
    let shown = info["CFBundleShortVersionString"] as? String ?? ""
    guard AppVersion(shown) == version else { throw .wrongVersion(shown) }
    if let minimum = info["LSMinimumSystemVersion"] {
      let text = minimum as? String ?? "\(minimum)"
      guard UpdateBundleCheck.runs(on: environment.osVersion(), minimum: text) else {
        throw .needsNewerMacOS(text)
      }
    }
    guard await signatureIsValid(app), let cdhash = await cdhash(of: app) else {
      throw .signatureInvalid
    }
    return cdhash
  }

  /// Requires the staged copy to have the image's CDHash, then removes a quarantine attribute
  /// from it (and from nothing else).
  private func settle(_ staged: Staged) async throws(UpdateProblem) {
    guard await cdhash(of: staged.copy) == staged.cdhash else { throw .stagedChanged }
    guard getxattr(staged.copy.path, Self.quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0 else {
      return
    }
    _ = await environment.run(
      Self.xattr, ["-d", Self.quarantine, staged.copy.path], cwd: nil, timeout: Self.checkTimeout)
  }

  /// Puts the staged copy in place of the installed app in one exchange, once it is still a
  /// directory (not a symbolic link) with the image's CDHash and a valid signature.
  private func swapIn(_ staged: Staged) async throws(UpdateProblem) {
    guard UpdateBundleCheck.isDirectory(staged.copy),
      await cdhash(of: staged.copy) == staged.cdhash, await signatureIsValid(staged.copy)
    else { throw .stagedChanged }
    do {
      try environment.swap(staged.copy, paths.installed)
    } catch let problem as UpdateProblem {
      throw problem
    } catch {
      throw .swapFailed(error.localizedDescription)
    }
  }

  /// `codesign --verify --deep --strict` passes for `app`.
  private func signatureIsValid(_ app: URL) async -> Bool {
    let answer = await environment.run(
      Self.codesign, ["--verify", "--deep", "--strict", app.path], cwd: nil,
      timeout: Self.checkTimeout)
    return answer?.status == 0
  }

  /// The CDHash `codesign -dvvv` reports for `app`, or nil.
  private func cdhash(of app: URL) async -> String? {
    let answer = await environment.run(
      Self.codesign, ["-dvvv", app.path], cwd: nil, timeout: Self.checkTimeout)
    guard let answer, answer.status == 0 else { return nil }
    return UpdateBundleCheck.cdhash(codesignOutput: answer.output)
  }

  /// Waits, polling each second, while any joined session has a request open.
  private func waitForQuiet() async {
    guard await hasOpenRequests() else { return }
    set(.waiting)
    repeat { await environment.sleep(for: .seconds(1)) } while await hasOpenRequests()
  }

  /// Updates the mod with `claude` in the data folder, never answering a prompt for the owner,
  /// and requires the installed mod to be `version` after it.
  private func updateMod(to version: AppVersion) async -> ModOutcome {
    let byHand = ModOutcome.byHand(commands: UpdateRecord.byHandCommands)
    guard let claude = await environment.locate("claude") else { return byHand }
    for arguments in Self.modCommands {
      let answer = await environment.run(
        claude, arguments, cwd: paths.dataDir, timeout: Self.claudeTimeout)
      guard answer?.status == 0 else { return byHand }
    }
    let list = await environment.run(
      claude, ["plugin", "list", "--json"], cwd: paths.dataDir, timeout: Self.claudeTimeout)
    guard let list, list.status == 0,
      UpdateBundleCheck.modVersion(pluginList: list.output, id: Self.modID) == version
    else { return byHand }
    return .updated
  }

  // MARK: Helpers

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
