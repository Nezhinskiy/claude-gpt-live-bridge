import CryptoKit
import Foundation
import Testing
import os

@testable import BridgeCore

/// What the updater did, in order: every program it ran and every other environment call, with
/// the call stop and the quit it asked of the app.
enum UpdateEvent: Equatable, Sendable {
  case fetch
  case run(program: String, arguments: [String], cwd: URL?)
  case download(URL, to: URL)
  case swap(URL, URL)
  case relaunch(pid: Int32, app: URL)
  case sleep
  case stopCall
  case quit
}

/// An ordered record shared by the fake environment and the app's closures.
final class UpdateLog: Sendable {
  private let events = OSAllocatedUnfairLock<[UpdateEvent]>(initialState: [])

  func append(_ event: UpdateEvent) { events.withLock { $0.append(event) } }
  var all: [UpdateEvent] { events.withLock { $0 } }

  /// The argument lists `program` was run with.
  func runs(of program: String) -> [[String]] {
    all.compactMap {
      guard case .run(program, let arguments, _) = $0 else { return nil }
      return arguments
    }
  }

  /// The position of the first event that `matches`, or nil.
  func index(_ matches: (UpdateEvent) -> Bool) -> Int? { all.firstIndex(where: matches) }

  /// The position of the last run of `program` whose arguments start with `prefix`.
  func lastRun(_ program: String, _ prefix: [String] = []) -> Int? {
    all.lastIndex {
      guard case .run(program, let arguments, _) = $0 else { return false }
      return arguments.starts(with: prefix)
    }
  }

  var downloads: Int {
    all.filter { if case .download = $0 { true } else { false } }.count
  }
}

/// A switch the tests flip from any task.
final class Switch: Sendable {
  private let value: OSAllocatedUnfairLock<Bool>
  init(_ initial: Bool = false) { value = OSAllocatedUnfairLock(initialState: initial) }
  var isSet: Bool { value.withLock { $0 } }
  func set(_ new: Bool) { value.withLock { $0 = new } }
}

/// An `UpdateEnvironment` that records every call in `log` and answers from a script: by
/// default every program succeeds as on a Mac where the update is genuine, and `answer` replaces
/// the answer for the commands that start with a given prefix.
final class FakeUpdateEnvironment: UpdateEnvironment {
  typealias Answer = @Sendable (_ arguments: [String]) -> ProgramResult?

  struct Script {
    var latest: Result<Data, UpdateProblem>
    var programs: [String: URL] = [
      "gh": URL(filePath: "/Users/example/.local/bin/gh"),
      "claude": URL(filePath: "/Users/example/.local/bin/claude"),
    ]
    var image = Data("example image".utf8)
    var answers: [(prefix: String, answer: Answer)] = []
    var holdFetch = false
    var swapError: (any Error)?
    var os = OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)
    var onSleep: (@Sendable () async -> Void)?
    var cdhash = "0123456789abcdef0123456789abcdef01234567"
    var quarantineStaged = false
  }

  let log: UpdateLog
  /// Where the fake `diskutil image attach` says the image is mounted.
  let mount: URL
  /// The mod version `claude plugin list --json` reports.
  let modVersion: String
  private let script: OSAllocatedUnfairLock<Script>

  init(log: UpdateLog, mount: URL, latest: Data, modVersion: String = "0.1.3") {
    self.log = log
    self.mount = mount
    self.modVersion = modVersion
    script = OSAllocatedUnfairLock(uncheckedState: Script(latest: .success(latest)))
  }

  func change(_ edit: (inout Script) -> Void) { script.withLockUnchecked { edit(&$0) } }

  /// Answers commands whose `<program> <arguments…>` line starts with `prefix`.
  func answer(_ prefix: String, _ answer: @escaping Answer) {
    change { $0.answers.insert((prefix, answer), at: 0) }
  }

  func fetchLatest() async throws(UpdateProblem) -> Data {
    log.append(.fetch)
    while script.withLockUnchecked({ $0.holdFetch }) {
      try? await Task.sleep(for: .milliseconds(1))
    }
    return try script.withLockUnchecked { $0.latest }.get()
  }

  func download(_ url: URL, to file: URL, maxBytes: Int) async throws(UpdateProblem) {
    log.append(.download(url, to: file))
    let image = script.withLockUnchecked { $0.image }
    do { try image.write(to: file) } catch { throw .network("\(error)") }
  }

  func locate(_ program: String) async -> URL? { script.withLockUnchecked { $0.programs[program] } }

  func run(
    _ executable: URL, _ arguments: [String], cwd: URL?, mergingErrors: Bool, timeout: Duration
  ) async -> ProgramResult? {
    let program = executable.lastPathComponent
    log.append(.run(program: program, arguments: arguments, cwd: cwd))
    let line = ([program] + arguments).joined(separator: " ")
    let scripted = script.withLockUnchecked { $0.answers.first { line.hasPrefix($0.prefix) } }
    if let scripted { return scripted.answer(arguments) }
    return genuine(program, arguments, mergingErrors: mergingErrors)
  }

  func swap(_ a: URL, _ b: URL) throws {
    log.append(.swap(a, b))
    if let error = script.withLockUnchecked({ $0.swapError }) { throw error }
  }

  func relaunch(pid: Int32, app: URL) throws { log.append(.relaunch(pid: pid, app: app)) }

  func osVersion() -> OperatingSystemVersion { script.withLockUnchecked { $0.os } }

  func sleep(for duration: Duration) async {
    log.append(.sleep)
    if let onSleep = script.withLockUnchecked({ $0.onSleep }) { await onSleep() }
    await Task.yield()
  }

  /// What each program answers when the update is genuine.
  private func genuine(_ program: String, _ arguments: [String], mergingErrors: Bool)
    -> ProgramResult?
  {
    let ok = ProgramResult(status: 0, output: "")
    switch (program, arguments.first) {
    case ("gh", "attestation"):
      let digest = Self.sha256(of: URL(filePath: arguments[2]))
      return ProgramResult(status: 0, output: Self.attestation(digest: digest))
    case ("diskutil", "image") where arguments.dropFirst().first == "attach":
      // macOS 14's diskutil refuses a mount point that does not exist yet (64, "doesn't exist")
      guard let at = arguments.firstIndex(of: "--mountPoint"), at + 1 < arguments.count,
        UpdateBundleCheck.isDirectory(URL(filePath: arguments[at + 1]))
      else { return ProgramResult(status: 64, output: "") }
      // diskutil's own output, recorded on macOS 27, with the rig's mount point in it
      return ProgramResult(status: 0, output: Self.attachOutput(mountedAt: mount))
    case ("codesign", "-dvvv"):
      // codesign reports on standard error, which is in the output only when asked for
      guard mergingErrors else { return ok }
      let cdhash = script.withLockUnchecked { $0.cdhash }
      return ProgramResult(
        status: 0,
        output: "Executable=\(arguments[1])\nCandidateCDHash sha256=ffff\nCDHash=\(cdhash)\n")
    case ("ditto", _):
      let (source, target) = (URL(filePath: arguments[0]), URL(filePath: arguments[1]))
      let files = FileManager.default
      for name in (try? files.contentsOfDirectory(atPath: source.path)) ?? [] {
        try? files.copyItem(at: source.appending(path: name), to: target.appending(path: name))
      }
      if script.withLockUnchecked({ $0.quarantineStaged }) {
        _ = setxattr(target.path, "com.apple.quarantine", "0081;00000000;Example;", 22, 0, 0)
      }
      return ok
    case ("claude", "plugin") where arguments.contains("list"):
      let list = #"[{"id":"livebridge@livebridge","version":"\#(modVersion)","enabled":true}]"#
      return ProgramResult(status: 0, output: list)
    default:
      return ok
    }
  }

  static func sha256(of file: URL) -> String {
    let data = (try? Data(contentsOf: file)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// `gh attestation verify --format json` output naming `digest`.
  /// The recorded `diskutil image attach --plist` output, its mount point replaced by `mount`.
  static func attachOutput(mountedAt mount: URL) -> String {
    let fixture = Bundle.module.url(
      forResource: "diskutil-image-attach", withExtension: "plist", subdirectory: "Fixtures")
    let recorded = fixture.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    return recorded.replacing(
      "/Users/example/Library/Application Support/LiveBridge/updates/0.1.3/mount-00000000-0000-0000-0000-000000000000",
      with: mount.path)
  }

  static func attestation(digest: String) -> String {
    """
    [{"verificationResult":{"statement":{"_type":"https://in-toto.io/Statement/v1",\
    "subject":[{"name":"LiveBridge.dmg","digest":{"sha256":"\(digest)"}}]}}}]
    """
  }
}

/// A Mac in a temporary folder: `/Applications` with the installed app, the data folder, the
/// mounted image's app, and the fake environment that runs the update.
struct UpdateRig {
  let root: URL
  let paths: UpdatePaths
  let mount: URL
  let env: FakeUpdateEnvironment
  let log = UpdateLog()
  let requestOpen = Switch()

  init(latest tag: String = "v0.1.3", modVersion: String = "0.1.3") throws {
    root = try temporaryDirectory()
    let data = root.appending(path: "Application Support/LiveBridge")
    paths = UpdatePaths(
      applications: root.appending(path: "Applications"), updates: data.appending(path: "updates"),
      dataDir: data)
    mount = root.appending(path: "mount")
    env = FakeUpdateEnvironment(
      log: log, mount: mount, latest: Self.reply(tag), modVersion: modVersion)
    let files = FileManager.default
    try files.createDirectory(
      at: paths.installed.appending(path: "Contents"), withIntermediateDirectories: true)
    try Data("old".utf8).write(to: paths.installed.appending(path: "Contents/marker"))
    try files.createDirectory(at: data, withIntermediateDirectories: true)
    try writeMountedInfo([
      "CFBundleIdentifier": "com.getlivebridge.livebridge", "CFBundleShortVersionString": "0.1.3",
      "LSMinimumSystemVersion": "14.0",
    ])
  }

  static func reply(_ tag: String) -> Data {
    Data(#"{"tag_name":"\#(tag)","assets":[{"name":"LiveBridge.dmg"}]}"#.utf8)
  }

  var release: Release { get throws { try Release.parse(Self.reply("v0.1.3")) } }

  var mountedApp: URL { mount.appending(path: "LiveBridge.app") }

  /// Replaces the mounted app's `Info.plist`.
  func writeMountedInfo(_ info: [String: String]) throws {
    let contents = mountedApp.appending(path: "Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appending(path: "Info.plist"))
  }

  func updater(running: String = "0.1.2") throws -> Updater {
    let (log, requestOpen) = (log, requestOpen)
    return Updater(
      environment: env, paths: paths, running: try #require(AppVersion(running)),
      hasOpenRequests: { requestOpen.isSet }, stopCall: { log.append(.stopCall) },
      quit: { log.append(.quit) }, pid: 4242)
  }

  /// The staged copies left in `/Applications`.
  var stagedCopies: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: paths.applications.path)) ?? [])
      .filter { $0.hasPrefix(".LiveBridge-update-") }
  }

  var installedMarker: String? {
    (try? Data(contentsOf: paths.installed.appending(path: "Contents/marker")))
      .map { String(decoding: $0, as: UTF8.self) }
  }

  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  /// The first swap the updater asked for.
  var swap: (staged: URL, installed: URL)? {
    log.all.lazy.compactMap { event -> (URL, URL)? in
      guard case .swap(let staged, let installed) = event else { return nil }
      return (staged, installed)
    }.first
  }

  /// Answers `codesign -dvvv` for the staged copy with `stagedHash(n)` on its `n`th call (from
  /// 1), and with the image's CDHash for the app in the image.
  func answerStagedCDHash(_ stagedHash: @escaping @Sendable (Int) -> String) {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    env.answer("codesign -dvvv") { arguments in
      guard arguments[1].contains(".LiveBridge-update-") else {
        return ProgramResult(status: 0, output: "CDHash=0123456789\n")
      }
      let call = calls.withLock { count in
        count += 1
        return count
      }
      return ProgramResult(status: 0, output: "CDHash=\(stagedHash(call))\n")
    }
  }

  /// The record the install left.
  var record: UpdateRecord? { UpdateRecord.read(paths.updates.appending(path: "record.json")) }

  /// Installs 0.1.3 over 0.1.2 and returns the final status.
  func install(_ updater: Updater? = nil) async throws -> UpdateStatus {
    let updater = try updater ?? self.updater()
    await updater.install(try release)
    return await updater.status
  }
}

/// Statuses seen from inside the run.
final class SeenStatuses: Sendable {
  private let seen = OSAllocatedUnfairLock<[UpdateStatus]>(initialState: [])
  func append(_ status: UpdateStatus) { seen.withLock { $0.append(status) } }
  var all: [UpdateStatus] { seen.withLock { $0 } }
}

/// A fault in the image that stops the install between attaching and detaching it.
enum BundleFault: CaseIterable, Sendable {
  case noApp, otherBundle, otherVersion, newerMacOS, badSignature, readOnlyApplications

  /// Puts the fault into `rig`.
  func apply(to rig: UpdateRig) throws {
    var info = [
      "CFBundleIdentifier": "com.getlivebridge.livebridge", "CFBundleShortVersionString": "0.1.3",
      "LSMinimumSystemVersion": "14.0",
    ]
    switch self {
    case .noApp: try FileManager.default.removeItem(at: rig.mountedApp)
    case .otherBundle: info["CFBundleIdentifier"] = "com.example.other"
    case .otherVersion: info["CFBundleShortVersionString"] = "0.1.2"
    case .newerMacOS: info["LSMinimumSystemVersion"] = "15.2"
    case .badSignature:
      rig.env.answer("codesign --verify") { _ in ProgramResult(status: 1, output: "") }
    case .readOnlyApplications:
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: rig.paths.applications.path)
    }
    if self != .noApp { try rig.writeMountedInfo(info) }
  }
}

struct UpdaterTests {
  static let failed = ProgramResult(status: 1, output: "")

  // MARK: Check, download and verify

  @Test func aNewerReleaseIsAvailable() async throws {
    let rig = try UpdateRig()
    #expect(try await rig.updater().check() == .available(rig.release))
  }

  @Test func anEqualReleaseIsUpToDate() async throws {
    let rig = try UpdateRig()
    #expect(try await rig.updater(running: "0.1.3").check() == .upToDate)
  }

  @Test func anOlderReleaseIsUpToDate() async throws {
    let rig = try UpdateRig()
    #expect(try await rig.updater(running: "0.1.10").check() == .upToDate)
  }

  @Test func anHTTPErrorIsReported() async throws {
    let rig = try UpdateRig()
    rig.env.change { $0.latest = .failure(.http(403)) }
    let updater = try rig.updater()
    #expect(await updater.check() == .failed(.http(403)))
    #expect(await updater.status == .failed(.http(403)))
  }

  @Test func anInstallOfAReleaseThatIsNotNewerIsRefused() async throws {
    for running in ["0.1.3", "0.1.10"] {
      let rig = try UpdateRig()
      let updater = try rig.updater(running: running)
      await updater.install(try rig.release)
      #expect(await updater.status == .failed(.notNewer), "\(running)")
      #expect(rig.log.downloads == 0, "\(running)")
    }
  }

  @Test func noGhDownloadsNothing() async throws {
    let rig = try UpdateRig()
    rig.env.change { $0.programs["gh"] = nil }
    let updater = try rig.updater()
    await updater.install(try rig.release)
    #expect(await updater.status == .failed(.ghMissing))
    #expect(rig.log.downloads == 0)
  }

  @Test func ghSignedOutDownloadsNothing() async throws {
    let rig = try UpdateRig()
    rig.env.answer("gh auth status") { _ in Self.failed }
    let updater = try rig.updater()
    await updater.install(try rig.release)
    #expect(await updater.status == .failed(.ghSignedOut))
    #expect(rig.log.downloads == 0)
  }

  @Test func verifierProblemNamesAMissingGh() async throws {
    let rig = try UpdateRig()
    #expect(try await rig.updater().verifierProblem() == nil)
    rig.env.change { $0.programs["gh"] = nil }
    #expect(try await rig.updater().verifierProblem() == .ghMissing)
  }

  @Test func anAttestationArgvPinsWorkflowRefAndRunners() async throws {
    let rig = try UpdateRig()
    try await rig.updater().install(try rig.release)
    let image = rig.paths.updates.appending(path: "0.1.3/LiveBridge.dmg").path
    #expect(
      rig.log.runs(of: "gh").filter { $0.first == "attestation" } == [
        [
          "attestation", "verify", image, "--repo", "getLiveBridge/LiveBridge",
          "--signer-workflow", "getLiveBridge/LiveBridge/.github/workflows/release.yml",
          "--source-ref", "refs/tags/v0.1.3", "--deny-self-hosted-runners", "--format", "json",
        ]
      ])
  }

  @Test func aFailedAttestationDeletesTheImage() async throws {
    let rig = try UpdateRig()
    rig.env.answer("gh attestation") { _ in Self.failed }
    let updater = try rig.updater()
    await updater.install(try rig.release)
    #expect(await updater.status == .failed(.attestationFailed))
    #expect(!rig.exists(rig.paths.updates.appending(path: "0.1.3")))
    #expect(rig.log.runs(of: "hdiutil").isEmpty)
  }

  @Test func aDifferentAttestedDigestStagesNothing() async throws {
    let rig = try UpdateRig()
    rig.env.answer("gh attestation") { _ in
      ProgramResult(
        status: 0,
        output: FakeUpdateEnvironment.attestation(digest: String(repeating: "0", count: 64)))
    }
    let updater = try rig.updater()
    await updater.install(try rig.release)
    #expect(await updater.status == .failed(.digestMismatch))
    #expect(rig.log.runs(of: "hdiutil").isEmpty)
    #expect(rig.stagedCopies.isEmpty)
  }

  @Test func aSecondRunIsRefused() async throws {
    let rig = try UpdateRig()
    rig.env.change { $0.holdFetch = true }
    let updater = try rig.updater()
    let first = Task { await updater.check() }
    #expect(await eventually { rig.log.all.contains(.fetch) })
    #expect(await updater.check() == .failed(.busy))
    await updater.install(try rig.release)
    #expect(await updater.status == .checking)
    #expect(rig.log.downloads == 0)
    rig.env.change { $0.holdFetch = false }
    #expect(try await first.value == .available(rig.release))
  }

  @Test func anotherInstancesLockRefusesTheRun() async throws {
    let rig = try UpdateRig()
    try FileManager.default.createDirectory(
      at: rig.paths.updates, withIntermediateDirectories: true)
    let lock = rig.paths.updates.appending(path: "lock")
    try Data().write(to: lock)
    let updater = try rig.updater()
    #expect(await updater.check() == .failed(.busy))
    #expect(!rig.log.all.contains(.fetch))
    #expect(rig.exists(lock))
  }

  @Test func aRunLeavesNoLock() async throws {
    let rig = try UpdateRig()
    _ = try await rig.updater().check()
    #expect(!rig.exists(rig.paths.updates.appending(path: "lock")))
  }

  // MARK: Bundle checks, staging, waiting and the mod

  @Test func anImageWithoutTheAppIsRefused() async throws {
    let rig = try UpdateRig()
    try BundleFault.noApp.apply(to: rig)
    #expect(try await rig.install() == .failed(.noApp))
    #expect(rig.stagedCopies.isEmpty)
  }

  @Test func anotherBundleIdIsRefused() async throws {
    let rig = try UpdateRig()
    try BundleFault.otherBundle.apply(to: rig)
    #expect(try await rig.install() == .failed(.wrongBundle("com.example.other")))
    #expect(rig.stagedCopies.isEmpty)
  }

  @Test func anotherBundleVersionIsRefused() async throws {
    let rig = try UpdateRig()
    try BundleFault.otherVersion.apply(to: rig)
    #expect(try await rig.install() == .failed(.wrongVersion("0.1.2")))
    #expect(rig.stagedCopies.isEmpty)
  }

  @Test func anAppNeedingANewerMacOSIsRefused() async throws {
    let rig = try UpdateRig()
    try BundleFault.newerMacOS.apply(to: rig)
    #expect(try await rig.install() == .failed(.needsNewerMacOS("15.2")))
    #expect(rig.stagedCopies.isEmpty)
  }

  @Test func aRefusedSignatureIsRefused() async throws {
    let rig = try UpdateRig()
    try BundleFault.badSignature.apply(to: rig)
    #expect(try await rig.install() == .failed(.signatureInvalid))
    #expect(rig.stagedCopies.isEmpty)
  }

  @Test(arguments: BundleFault.allCases)
  func theImageIsDetachedOnFailure(_ fault: BundleFault) async throws {
    let rig = try UpdateRig()
    try fault.apply(to: rig)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: rig.paths.applications.path)
    }
    #expect(try await rig.install() != .installing)
    #expect(rig.log.runs(of: "diskutil").contains(["eject", rig.mount.path]))
  }

  /// A fresh mount folder each run, so a volume a crash left mounted is never stacked on.
  @Test func theImageIsAttachedReadOnlyWithoutBrowsingInAFreshFolder() async throws {
    let rig = try UpdateRig()
    _ = try await rig.install()
    let folder = rig.paths.updates.appending(path: "0.1.3")
    let attach = try #require(rig.log.runs(of: "diskutil").first)
    #expect(
      attach.prefix(6) == [
        "image", "attach", "--plist", "--readOnly", "--nobrowse", "--mountPoint",
      ])
    let mount = URL(filePath: attach[6])
    #expect(mount.deletingLastPathComponent().path == folder.path)
    #expect(mount.lastPathComponent.hasPrefix("mount-"))
    #expect(UUID(uuidString: String(mount.lastPathComponent.dropFirst(6))) != nil)
    #expect(attach[7...] == [folder.appending(path: "LiveBridge.dmg").path])
    #expect(rig.log.runs(of: "hdiutil").isEmpty)
  }

  @Test func diskutilsAttachOutputNamesTheMountPoint() throws {
    let fixture = try #require(
      Bundle.module.url(
        forResource: "diskutil-image-attach", withExtension: "plist", subdirectory: "Fixtures"))
    let mount =
      "/Users/example/Library/Application Support/LiveBridge/updates/0.1.3/mount-00000000-0000-0000-0000-000000000000"
    #expect(
      UpdateBundleCheck.volume(attachPlist: try String(contentsOf: fixture, encoding: .utf8))
        == .init(ejectTarget: mount, mountPoint: URL(filePath: mount)))
  }

  @Test func readOnlyApplicationsLeavesTheAppAsItWas() async throws {
    let rig = try UpdateRig()
    try BundleFault.readOnlyApplications.apply(to: rig)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: rig.paths.applications.path)
    }
    #expect(try await rig.install() == .failed(.notWritable))
    #expect(rig.installedMarker == "old")
    #expect(rig.stagedCopies.isEmpty)
  }

  @Test func aFailureAfterStagingRemovesTheStagedCopy() async throws {
    let rig = try UpdateRig()
    rig.env.answer("codesign -dvvv") { arguments in
      let staged = arguments[1].contains(".LiveBridge-update-")
      return ProgramResult(status: 0, output: "CDHash=\(staged ? "feedface" : "0123456789")\n")
    }
    #expect(try await rig.install() == .failed(.stagedChanged))
    #expect(rig.stagedCopies.isEmpty)
    #expect(rig.installedMarker == "old")
  }

  @Test func aQuarantinedStagedCopyIsClearedAfterItsCDHashMatched() async throws {
    let rig = try UpdateRig()
    rig.env.change { $0.quarantineStaged = true }
    _ = try await rig.install()
    let clear = try #require(rig.log.lastRun("xattr"))
    let stagedHash = try #require(
      rig.log.index {
        guard case .run("codesign", let arguments, _) = $0 else { return false }
        return arguments.first == "-dvvv" && arguments[1].contains(".LiveBridge-update-")
      })
    #expect(stagedHash < clear)
    let arguments = try #require(rig.log.runs(of: "xattr").first)
    #expect(Array(arguments.prefix(2)) == ["-d", "com.apple.quarantine"])
    #expect(arguments.last?.hasPrefix(rig.paths.applications.path + "/.LiveBridge-update-") == true)
  }

  @Test func theInstallWaitsWhileARequestIsOpen() async throws {
    let rig = try UpdateRig()
    let updater = try rig.updater()
    let seen = SeenStatuses()
    rig.requestOpen.set(true)
    rig.env.change {
      $0.onSleep = {
        seen.append(await updater.status)
        rig.requestOpen.set(false)
      }
    }
    _ = try await rig.install(updater)
    #expect(seen.all == [.waiting])
    let firstClaude = try #require(
      rig.log.index { if case .run("claude", _, _) = $0 { true } else { false } })
    #expect(try #require(rig.log.index { $0 == .sleep }) < firstClaude)
  }

  @Test func claudeMissingLeavesTheAppUpdated() async throws {
    let rig = try UpdateRig()
    rig.env.change { $0.programs["claude"] = nil }
    _ = try await rig.install()
    #expect(rig.record?.mod == .byHand(commands: UpdateRecord.byHandCommands))
    #expect(rig.log.index { if case .swap = $0 { true } else { false } } != nil)
  }

  @Test func aFailingClaudeLeavesTheAppUpdated() async throws {
    let rig = try UpdateRig()
    rig.env.answer("claude plugin marketplace") { _ in ProgramResult(status: 1, output: "") }
    _ = try await rig.install()
    #expect(rig.record?.mod == .byHand(commands: UpdateRecord.byHandCommands))
  }

  @Test func aModOfAnotherVersionIsReportedByHand() async throws {
    let rig = try UpdateRig(modVersion: "0.1.2")
    _ = try await rig.install()
    #expect(rig.record?.mod == .byHand(commands: UpdateRecord.byHandCommands))
  }

  @Test func claudeIsNeverAskedToAccept() async throws {
    let rig = try UpdateRig()
    _ = try await rig.install()
    let runs = rig.log.all.compactMap { event -> ([String], URL?)? in
      guard case .run("claude", let arguments, let cwd) = event else { return nil }
      return (arguments, cwd)
    }
    #expect(
      runs.map(\.0) == [
        ["plugin", "marketplace", "update", "livebridge"],
        ["plugin", "update", "livebridge@livebridge"], ["plugin", "list", "--json"],
      ])
    for (arguments, cwd) in runs {
      #expect(Set(arguments).isDisjoint(with: ["-y", "--yes", "--accept-command"]))
      #expect(cwd == rig.paths.dataDir)
    }
    #expect(rig.record?.mod == .updated)
  }

  @Test func aRequestOpenedDuringTheModUpdateDelaysTheSwap() async throws {
    let rig = try UpdateRig()
    let updater = try rig.updater()
    let seen = SeenStatuses()
    let requestOpen = rig.requestOpen
    rig.env.answer("claude plugin update") { _ in
      requestOpen.set(true)
      return ProgramResult(status: 0, output: "")
    }
    rig.env.change {
      $0.onSleep = {
        seen.append(await updater.status)
        requestOpen.set(false)
      }
    }
    _ = try await rig.install(updater)
    #expect(seen.all == [.waiting])
    let wait = try #require(rig.log.index { $0 == .sleep })
    #expect(try #require(rig.log.lastRun("claude", ["plugin", "update"])) < wait)
    #expect(try wait < #require(rig.log.index { if case .swap = $0 { true } else { false } }))
  }

  /// A request opened between the last wait and the call's stop is waited for before the swap.
  @Test func aRequestOpenedWhileTheCallStopsDelaysTheSwap() async throws {
    let rig = try UpdateRig()
    let (log, requestOpen) = (rig.log, rig.requestOpen)
    let updater = Updater(
      environment: rig.env, paths: rig.paths, running: try #require(AppVersion("0.1.2")),
      hasOpenRequests: { requestOpen.isSet },
      stopCall: {
        log.append(.stopCall)
        requestOpen.set(true)
      }, quit: { log.append(.quit) }, pid: 4242)
    rig.env.change { $0.onSleep = { requestOpen.set(false) } }
    #expect(try await rig.install(updater) == .installing)
    let stop = try #require(rig.log.index { $0 == .stopCall })
    let wait = try #require(rig.log.index { $0 == .sleep })
    #expect(stop < wait)
    #expect(try wait < #require(rig.log.index { if case .swap = $0 { true } else { false } }))
  }

  // MARK: Swap, record, relaunch and the launch cleanup

  @Test func theSwapExchangesTheBundles() async throws {
    let rig = try UpdateRig()
    #expect(try await rig.install() == .installing)
    let swap = try #require(rig.swap)
    #expect(swap.staged.path == rig.paths.applications.path + "/" + swap.staged.lastPathComponent)
    #expect(swap.staged.lastPathComponent.hasPrefix(".LiveBridge-update-"))
    #expect(swap.installed == rig.paths.installed)
    #expect(
      rig.record
        == UpdateRecord(
          from: try #require(AppVersion("0.1.2")), to: try #require(AppVersion("0.1.3")),
          mod: .updated, noticePosted: false))
    let relaunch = try #require(
      rig.log.index { $0 == .relaunch(pid: 4242, app: rig.paths.installed) })
    #expect(try relaunch < #require(rig.log.index { $0 == .quit }))
  }

  @Test func theCallStopsOnlyAtTheSwap() async throws {
    let rig = try UpdateRig()
    _ = try await rig.install()
    #expect(rig.log.all.filter { $0 == .stopCall }.count == 1)
    let stop = try #require(rig.log.index { $0 == .stopCall })
    #expect(try #require(rig.log.lastRun("claude")) < stop)
    #expect(try stop < #require(rig.log.index { if case .swap = $0 { true } else { false } }))
  }

  @Test func aStagedCopyWithAnotherCDHashIsNotSwapped() async throws {
    let rig = try UpdateRig()
    rig.answerStagedCDHash { $0 == 1 ? "0123456789" : "feedface" }
    #expect(
      try await rig.install()
        == .failed(.modAlreadyUpdated(.stagedChanged, version: #require(AppVersion("0.1.3")))))
    #expect(rig.swap == nil)
    #expect(rig.stagedCopies.isEmpty)
  }

  @Test func aStagedSymlinkIsNotSwapped() async throws {
    let rig = try UpdateRig()
    let elsewhere = rig.root.appending(path: "elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let applications = rig.paths.applications
    rig.env.answer("claude plugin list") { _ in
      let files = FileManager.default
      for name in (try? files.contentsOfDirectory(atPath: applications.path)) ?? []
      where name.hasPrefix(".LiveBridge-update-") {
        let staged = applications.appending(path: name)
        try? files.removeItem(at: staged)
        try? files.createSymbolicLink(at: staged, withDestinationURL: elsewhere)
      }
      return ProgramResult(status: 0, output: "[]")
    }
    #expect(try await rig.install() == .failed(.stagedChanged))
    #expect(rig.swap == nil)
    #expect(rig.stagedCopies.isEmpty)
    #expect(rig.exists(elsewhere))
  }

  @Test func aFailedSwapLeavesTheInstalledApp() async throws {
    let rig = try UpdateRig()
    rig.env.change { $0.swapError = CocoaError(.fileWriteNoPermission) }
    let status = try await rig.install()
    guard case .failed(.modAlreadyUpdated(.swapFailed, _)) = status else {
      Issue.record("status \(status)")
      return
    }
    #expect(!rig.log.all.contains(.quit))
    #expect(!rig.log.all.contains { if case .relaunch = $0 { true } else { false } })
    #expect(rig.installedMarker == "old")
    #expect(rig.stagedCopies.isEmpty)
  }

  /// The system's reason for a failed swap reaches the owner as it was given; with the mod left
  /// to the owner, nothing is added to it.
  @Test func aFailedSwapKeepsItsReason() async throws {
    let rig = try UpdateRig(modVersion: "0.1.2")
    rig.env.change { $0.swapError = UpdateProblem.swapFailed("Example reason") }
    #expect(try await rig.install() == .failed(.swapFailed("Example reason")))
  }

  /// A failure after the mod was updated says the mod is already the new version.
  @Test func aFailedSwapAfterTheModUpdateSaysTheModIsNew() async throws {
    let rig = try UpdateRig()
    rig.env.change { $0.swapError = UpdateProblem.swapFailed("Example reason") }
    let version = try #require(AppVersion("0.1.3"))
    #expect(
      try await rig.install()
        == .failed(.modAlreadyUpdated(.swapFailed("Example reason"), version: version)))
  }

  @Test func aModAlreadyUpdatedSentenceKeepsTheReasonAndNamesTheVersion() throws {
    let problem = UpdateProblem.modAlreadyUpdated(
      .swapFailed("Example reason"), version: try #require(AppVersion("0.1.3")))
    #expect(problem.sentence.hasPrefix(UpdateProblem.swapFailed("Example reason").sentence))
    #expect(problem.sentence.contains("0.1.3"))
  }

  @Test func onlyAnImageThatCannotBeVerifiedSendsToTheReleasePage() {
    let verifying: [UpdateProblem] = [.ghMissing, .ghSignedOut, .attestationFailed]
    let others: [UpdateProblem] = [
      .network("Example reason"), .http(403), .noImage, .digestMismatch, .signatureInvalid,
      .notWritable, .busy,
    ]
    #expect(verifying.map(\.offersReleasePage) == [true, true, true])
    #expect(others.filter(\.offersReleasePage) == [])
  }

  // MARK: The schedule

  static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func aDueCheckRecordsItsTime() async throws {
    let rig = try UpdateRig()
    let state = UpdateStateStore(file: rig.paths.updates.appending(path: "state.json"))
    _ = try await rig.updater().checkIfDue(now: Self.t0, enabled: true, state: state)
    #expect(state.current.lastCheck == Self.t0)
  }

  @Test func aCheckGitHubDidNotAnswerIsNotTheDaysCheck() async throws {
    let rig = try UpdateRig()
    rig.env.change { $0.latest = .failure(.network("The Internet connection appears offline.")) }
    let state = UpdateStateStore(file: rig.paths.updates.appending(path: "state.json"))
    _ = try await rig.updater().checkIfDue(now: Self.t0, enabled: true, state: state)
    #expect(state.current.lastCheck == nil)
  }

  @Test func aReleaseIsAnnouncedOnce() async throws {
    let rig = try UpdateRig()
    let state = UpdateStateStore(file: rig.paths.updates.appending(path: "state.json"))
    let updater = try rig.updater()
    let first = await updater.checkIfDue(now: Self.t0, enabled: true, state: state)
    let later = Self.t0 + UpdatePolicy.interval
    let second = await updater.checkIfDue(now: later, enabled: true, state: state)
    #expect(first == (try rig.release))
    #expect(second == nil)
  }

  @Test func aCheckThatIsNotDueDoesNothing() async throws {
    let rig = try UpdateRig()
    let state = UpdateStateStore(file: rig.paths.updates.appending(path: "state.json"))
    state.update { $0.lastCheck = Self.t0 }
    let found = try await rig.updater().checkIfDue(
      now: Self.t0 + 60, enabled: true, state: state)
    #expect(found == nil)
    #expect(!rig.log.all.contains(.fetch))
  }

  @Test func aNewerAnnouncedReleaseIsRestoredAtLaunch() async throws {
    let rig = try UpdateRig()
    let state = UpdateStateStore(file: rig.paths.updates.appending(path: "state.json"))
    let announced = try #require(AppVersion("0.1.3"))
    state.update {
      $0.announced = [announced]
      $0.lastCheck = Self.t0
    }
    let before = state.current
    let restored = try await rig.updater(running: "0.1.2").restoreAnnounced(
      now: Self.t0 + 60, enabled: true, state: state)
    #expect(restored == (try rig.release))
    #expect(state.current == before)  // not the day's check, and nothing announced again
  }

  @Test func anAnnouncedReleaseIsLeftToTheDueCheck() async throws {
    let rig = try UpdateRig()
    let state = UpdateStateStore(file: rig.paths.updates.appending(path: "state.json"))
    let announced = try #require(AppVersion("0.1.3"))
    state.update {
      $0.announced = [announced]
      $0.lastCheck = Self.t0
    }
    let restored = try await rig.updater(running: "0.1.2").restoreAnnounced(
      now: Self.t0 + UpdatePolicy.interval, enabled: true, state: state)
    #expect(restored == nil)
    #expect(!rig.log.all.contains(.fetch))
  }

  @Test func anAnnouncedReleaseNoNewerIsNotRestored() async throws {
    let rig = try UpdateRig()
    let state = UpdateStateStore(file: rig.paths.updates.appending(path: "state.json"))
    let announced = try #require(AppVersion("0.1.2"))
    state.update {
      $0.announced = [announced]
      $0.lastCheck = Self.t0
    }
    let restored = try await rig.updater(running: "0.1.2").restoreAnnounced(
      now: Self.t0 + 60, enabled: true, state: state)
    #expect(restored == nil)
    #expect(!rig.log.all.contains(.fetch))
  }

  @Test func theRecordIsReadAfterARelaunch() async throws {
    let rig = try UpdateRig()
    _ = try await rig.install()
    let written = try #require(rig.record)
    #expect(Updater.cleanUp(paths: rig.paths) == written)
  }

  @Test func cleanupRemovesLeftovers() throws {
    let rig = try UpdateRig()
    let files = FileManager.default
    let leftovers = [
      rig.paths.applications.appending(
        path: ".LiveBridge-update-00000000-0000-0000-0000-000000000001.app"),
      rig.paths.applications.appending(
        path: ".LiveBridge-update-00000000-0000-0000-0000-000000000002.app"),
      rig.paths.updates.appending(path: "0.1.3"),
    ]
    for folder in leftovers {
      try files.createDirectory(
        at: folder.appending(path: "Contents"), withIntermediateDirectories: true)
    }
    let kept = ["record.json", "state.json"].map { rig.paths.updates.appending(path: $0) }
    for file in kept { try Data("{}".utf8).write(to: file) }
    try Data().write(to: rig.paths.updates.appending(path: "lock"))
    _ = Updater.cleanUp(paths: rig.paths)
    for folder in leftovers { #expect(!rig.exists(folder), "\(folder.lastPathComponent)") }
    #expect(!rig.exists(rig.paths.updates.appending(path: "lock")))
    for file in kept { #expect(rig.exists(file), "\(file.lastPathComponent)") }
    #expect(rig.installedMarker == "old")
  }

  @Test func cleanupRefusesAnUpdatesSymlink() throws {
    let rig = try UpdateRig()
    let files = FileManager.default
    let target = rig.root.appending(path: "elsewhere")
    try files.createDirectory(
      at: target.appending(path: "0.1.3"), withIntermediateDirectories: true)
    try files.createSymbolicLink(at: rig.paths.updates, withDestinationURL: target)
    _ = Updater.cleanUp(paths: rig.paths)
    #expect(rig.exists(target.appending(path: "0.1.3")))
  }

  @Test func cleanupUnlinksASymlinkWithoutFollowingIt() throws {
    let rig = try UpdateRig()
    let files = FileManager.default
    let target = rig.root.appending(path: "elsewhere")
    try files.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("kept".utf8).write(to: target.appending(path: "file"))
    let link = rig.paths.applications.appending(path: ".LiveBridge-update-planted.app")
    try files.createSymbolicLink(at: link, withDestinationURL: target)
    _ = Updater.cleanUp(paths: rig.paths)
    #expect((try? files.destinationOfSymbolicLink(atPath: link.path)) == nil)
    #expect(rig.exists(target.appending(path: "file")))
  }
}
