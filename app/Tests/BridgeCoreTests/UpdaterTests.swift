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
  /// Where the fake `hdiutil attach` says the image is mounted.
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

  func run(_ executable: URL, _ arguments: [String], cwd: URL?, timeout: Duration) async
    -> ProgramResult?
  {
    let program = executable.lastPathComponent
    log.append(.run(program: program, arguments: arguments, cwd: cwd))
    let line = ([program] + arguments).joined(separator: " ")
    let scripted = script.withLockUnchecked { $0.answers.first { line.hasPrefix($0.prefix) } }
    if let scripted { return scripted.answer(arguments) }
    return genuine(program, arguments)
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
  private func genuine(_ program: String, _ arguments: [String]) -> ProgramResult? {
    let ok = ProgramResult(status: 0, output: "")
    switch (program, arguments.first) {
    case ("gh", "attestation"):
      let digest = Self.sha256(of: URL(filePath: arguments[2]))
      return ProgramResult(status: 0, output: Self.attestation(digest: digest))
    case ("hdiutil", "attach"):
      let plist: [String: Any] = [
        "system-entities": [
          ["dev-entry": "/dev/disk9", "content-hint": "GUID_partition_scheme"],
          ["dev-entry": "/dev/disk9s1", "mount-point": mount.path],
        ]
      ]
      let data = try? PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
      return ProgramResult(status: 0, output: String(decoding: data ?? Data(), as: UTF8.self))
    case ("codesign", "-dvvv"):
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
}
