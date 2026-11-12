import Foundation
import Testing

@testable import BridgeCore

/// The Trash move the menu's Uninstall LiveBridge leaves to `/bin/sh`, run for real in a scratch
/// folder standing in for the home folder.
struct UninstallScriptTests {
  let home: URL
  var library: URL { home.appending(path: "Library") }
  var app: URL { home.appending(path: "Applications/LiveBridge.app") }
  var trash: URL { home.appending(path: ".Trash/LiveBridge 2026-11-12 15.30.00") }

  init() throws { home = try temporaryDirectory() }

  /// Makes each path as a folder with something in it; the script moves files the same way.
  func make(_ urls: [URL]) throws {
    for url in urls {
      try FileManager.default.createDirectory(
        at: url.appending(path: "inner"), withIntermediateDirectories: true)
    }
  }

  func start(_ executable: String, _ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    try process.run()
    return process
  }

  func run(pid: Int32) throws {
    let process = try start(
      "/bin/sh",
      UninstallScript.arguments(
        pid: pid, trash: trash.path,
        paths: Paths.uninstalled(app: app, library: library).map(\.path)))
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }

  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  @Test func onceTheAppIsGoneEveryFileGoesToOneTrashFolder() throws {
    let ours = Paths.uninstalled(app: app, library: library)
    let neighbour = library.appending(path: "Caches/com.example.other")
    try make(ours + [neighbour])
    let quitting = try start("/bin/sleep", ["0.5"])
    try run(pid: quitting.processIdentifier)
    #expect(!quitting.isRunning)  // it waited for the app's process to end
    #expect(ours.allSatisfy { !exists($0) })
    #expect(exists(neighbour))
    let moved = [
      "Applications/LiveBridge.app", "Application Support/LiveBridge",
      "Caches/com.getlivebridge.livebridge", "WebKit/com.getlivebridge.livebridge",
      "HTTPStorages/com.getlivebridge.livebridge",
      "HTTPStorages/com.getlivebridge.livebridge.binarycookies",
      "Preferences/com.getlivebridge.livebridge.plist",
    ]
    #expect(moved.allSatisfy { exists(trash.appending(path: $0)) })
  }

  @Test func aFileThatIsNotThereIsSkipped() throws {
    try make([app])
    let gone = try start("/usr/bin/true", [])
    gone.waitUntilExit()
    try run(pid: gone.processIdentifier)
    #expect(exists(trash.appending(path: "Applications/LiveBridge.app")))
    #expect(!exists(trash.appending(path: "WebKit")))
  }
}
