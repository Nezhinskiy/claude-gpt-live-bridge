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

    func arguments(pid: Int32, attempts: Int = 10) -> [String] {
      RelaunchScript.arguments(
        pid: pid, app: "/Applications/LiveBridge.app", open: folder.appending(path: "open").path,
        pgrep: folder.appending(path: "pgrep").path, sleep: folder.appending(path: "sleep").path,
        attempts: attempts)
    }

    var opens: [String] {
      ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(
        String.init)
    }
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
}
