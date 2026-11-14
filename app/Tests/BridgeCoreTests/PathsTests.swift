import Foundation
import Testing

@testable import BridgeCore

struct PathsTests {
  let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

  func permissions(_ url: URL) throws -> Int {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
  }

  @Test func runDirIsOwnerOnly() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let run = try Paths.runDir(in: base)
    #expect(run == base.appending(path: "LiveBridge/run"))
    #expect(try permissions(run) == 0o700)
    #expect(try permissions(run.deletingLastPathComponent()) == 0o700)
  }

  @Test func loosenedDirIsTightened() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let data = base.appending(path: "LiveBridge")
    try FileManager.default.createDirectory(
      at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    #expect(try Paths.dataDir(in: base) == data)
    #expect(try permissions(data) == 0o700)
  }

  /// The owner may keep the data elsewhere through a symlink; the folder it names is tightened.
  @Test func symlinkedDirIsFollowed() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let elsewhere = base.appending(path: "elsewhere")
    try FileManager.default.createDirectory(
      at: elsewhere, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try FileManager.default.createSymbolicLink(
      at: base.appending(path: "LiveBridge"), withDestinationURL: elsewhere)
    #expect(try Paths.dataDir(in: base) == base.appending(path: "LiveBridge"))
    #expect(try permissions(elsewhere) == 0o700)
  }

  /// `build-app.sh --uninstall` removes the same files the menu's Uninstall moves to the Trash, so
  /// a file the app starts to keep cannot be added to one route and missed by the other.
  @Test func theScriptRemovesTheFilesTheMenuMoves() throws {
    let script = try String(
      contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../scripts/build-app.sh").standardized, encoding: .utf8)
    let body =
      try #require(script.components(separatedBy: "uninstall() {").last)
      .components(separatedBy: "\n}").first ?? ""
    let removed = Set(body.matches(of: /"\$lib\/([^"]+)"/).map { String($0.1) })
    let moved = Set(
      Paths.uninstalled(library: URL(filePath: "/L")).map {
        String($0.path.dropFirst("/L/".count))
          .replacingOccurrences(of: Paths.bundleID, with: "$BUNDLE_ID")
      })
    #expect(removed == moved)
  }

  /// The notices, the log and System Settings' link use the bundle id the app ships with.
  @Test func theBundleIDIsTheAppsOwn() throws {
    let plist = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "../../Support/Info.plist").standardized
    let info =
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: plist), format: nil) as? [String: Any]
    #expect(info?["CFBundleIdentifier"] as? String == Paths.bundleID)
  }
}
