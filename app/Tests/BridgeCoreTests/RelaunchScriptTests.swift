import Foundation
import Testing

@testable import BridgeCore

/// The relaunch after an update (the spec's step 9), run by the real `/bin/sh` with stand-ins for
/// `open`, `pgrep` and `sleep`: the stand-in `open` logs each call and, from its `appearsOn`th,
/// leaves a marker that the stand-in `pgrep` reports as a running app.
struct RelaunchScriptTests {
  /// The folder holding the stand-ins, their log and marker.
  struct Stage {
    let folder: URL
    var log: URL { folder.appending(path: "open.log") }
    var marker: URL { folder.appending(path: "running") }

    /// `appearsOn` nil never starts the app; `watching` is a pid whose state each `open` logs.
    init(appearsOn: Int?, watching pid: Int32? = nil) throws {
      folder = try temporaryDirectory()
      let state = pid.map {
        "if /bin/kill -0 \($0) 2>/dev/null; then echo alive; else echo gone; fi"
      }
      let appear = appearsOn.map {
        "[ \"$(/usr/bin/wc -l < '\(log.path)')\" -ge \($0) ] && /usr/bin/touch '\(marker.path)'"
      }
      try write(
        "open", ["echo \"open $1 $(\(state ?? "echo -"))\" >> '\(log.path)'", appear ?? ""])
      try write("pgrep", ["[ -e '\(marker.path)' ]"])
      try write("sleep", ["exec /bin/sleep 0.01"])
    }

    private func write(_ name: String, _ lines: [String]) throws {
      let file = folder.appending(path: name)
      try (["#!/bin/sh"] + lines).joined(separator: "\n").write(
        to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// `app` and `pgrep` nil are `/Applications/LiveBridge.app` and the stand-in `pgrep`.
    func arguments(
      pid: Int32, attempts: Int = 10, app: String? = nil, pgrep: String? = nil
    ) -> [String] {
      RelaunchScript.arguments(
        pid: pid, app: app ?? "/Applications/LiveBridge.app",
        open: folder.appending(path: "open").path,
        pgrep: pgrep ?? folder.appending(path: "pgrep").path,
        sleep: folder.appending(path: "sleep").path, attempts: attempts)
    }

    var opens: [String] {
      ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(
        String.init)
    }
  }

  /// A `LiveBridge.app` in a new folder whose executable is a copy of `sleep`, signed ad hoc so
  /// it runs; its process is named `LiveBridge`.
  func sleepingApp() throws -> URL {
    let app = try temporaryDirectory().appending(path: "LiveBridge.app")
    let executable = app.appending(path: "Contents/MacOS/LiveBridge")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: executable)
    let sign = try start("/usr/bin/codesign", ["-s", "-", "-f", executable.path])
    sign.waitUntilExit()
    return app
  }

  /// Starts `app`'s executable for ten seconds; the caller terminates it.
  func run(_ app: URL) throws -> Process {
    let process = try start(app.appending(path: "Contents/MacOS/LiveBridge").path, ["10"])
    Thread.sleep(forTimeInterval: 0.2)
    return process
  }

  /// A pid that has already exited and been reaped.
  func goneProcess() throws -> Int32 {
    let process = try start("/usr/bin/true", [])
    process.waitUntilExit()
    return process.processIdentifier
  }

  func start(_ executable: String, _ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    try process.run()
    return process
  }

  /// Runs the script to its end; false when it is still running after ten seconds.
  func runs(_ arguments: [String]) throws -> Bool {
    let script = try start("/bin/sh", arguments)
    let deadline = Date().addingTimeInterval(10)
    while script.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    guard !script.isRunning else {
      script.terminate()
      return false
    }
    return true
  }

  @Test func aRelaunchRetriesUntilTheAppRuns() throws {
    let stage = try Stage(appearsOn: 3)
    #expect(try runs(stage.arguments(pid: goneProcess())))
    #expect(stage.opens.count == 3)
  }

  /// The app is looked for before each `open`, so an instance already started (by the mod's
  /// `ensureApp`, say) gets no `open` at all, which would only bring it forward.
  @Test func aRelaunchStopsWhenAnotherInstanceAlreadyRuns() throws {
    let stage = try Stage(appearsOn: 1)
    FileManager.default.createFile(atPath: stage.marker.path, contents: nil)
    #expect(try runs(stage.arguments(pid: goneProcess())))
    #expect(stage.opens.isEmpty)
  }

  @Test func aRelaunchGivesUpAfterItsAttempts() throws {
    let stage = try Stage(appearsOn: nil)
    #expect(try runs(stage.arguments(pid: goneProcess(), attempts: 3)))
    #expect(stage.opens.count == 3)
  }

  @Test func theRelaunchWaitsForTheOldProcess() throws {
    let old = try start("/bin/sleep", ["0.5"])
    let stage = try Stage(appearsOn: 1, watching: old.processIdentifier)
    #expect(try runs(stage.arguments(pid: old.processIdentifier)))
    #expect(stage.opens == ["open /Applications/LiveBridge.app gone"])
  }

  /// Only the installed app counts as running: another `LiveBridge` of this user (a debug build,
  /// say) does not end the loop before the installed app is opened.
  @Test func aLiveBridgeElsewhereDoesNotEndTheRelaunch() throws {
    let stage = try Stage(appearsOn: nil)
    let (installed, elsewhere) = (try sleepingApp(), try sleepingApp())
    let other = try run(elsewhere)
    defer { other.terminate() }
    let arguments = stage.arguments(
      pid: try goneProcess(), attempts: 2, app: installed.path, pgrep: "/usr/bin/pgrep")
    #expect(try runs(arguments))
    #expect(stage.opens.count == 2)
  }

  @Test func theInstalledAppRunningEndsTheRelaunch() throws {
    let stage = try Stage(appearsOn: nil)
    let installed = try sleepingApp()
    let app = try run(installed)
    defer { app.terminate() }
    let arguments = stage.arguments(
      pid: try goneProcess(), attempts: 2, app: installed.path, pgrep: "/usr/bin/pgrep")
    #expect(try runs(arguments))
    #expect(stage.opens.isEmpty)
  }
}
