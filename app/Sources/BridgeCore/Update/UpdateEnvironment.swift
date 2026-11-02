import Foundation

/// How a program the updater ran ended: its exit status and its output.
public struct ProgramResult: Sendable, Equatable {
  public var status: Int32
  public var output: String

  public init(status: Int32, output: String) {
    self.status = status
    self.output = output
  }
}

/// Everything the `Updater` does to the world outside its folders: the network, the programs it
/// runs, the swap, the relaunch, the clock. The app's is `SystemUpdateEnvironment`; tests use a
/// fake that records every call.
public protocol UpdateEnvironment: Sendable {
  /// GitHub's `releases/latest` reply, unparsed.
  func fetchLatest() async throws(UpdateProblem) -> Data
  /// Downloads `url` into `file`, refusing more than `maxBytes` (`tooLarge`).
  func download(_ url: URL, to file: URL, maxBytes: Int) async throws(UpdateProblem)
  /// `program` on the search path, or nil when it is not installed.
  func locate(_ program: String) async -> URL?
  /// Runs `executable` with `arguments` in `cwd`; nil when it did not start or did not finish
  /// within `timeout`.
  func run(_ executable: URL, _ arguments: [String], cwd: URL?, timeout: Duration) async
    -> ProgramResult?
  /// Exchanges `a` and `b` in one step.
  func swap(_ a: URL, _ b: URL) throws
  /// Opens `app` once the process `pid` has exited.
  func relaunch(pid: Int32, app: URL) throws
  /// The running macOS.
  func osVersion() -> OperatingSystemVersion
  /// Waits `duration`.
  func sleep(for duration: Duration) async
}

/// The folders an update works in.
public struct UpdatePaths: Sendable {
  /// `/Applications`: the installed app and the staged copies.
  public var applications: URL
  /// `<data dir>/updates`: the images, the record, the check state and the lock.
  public var updates: URL
  /// The data folder, the working directory of every `claude` command.
  public var dataDir: URL

  public init(applications: URL, updates: URL, dataDir: URL) {
    self.applications = applications
    self.updates = updates
    self.dataDir = dataDir
  }

  /// The installed app.
  public var installed: URL { applications.appending(path: "LiveBridge.app") }
}
