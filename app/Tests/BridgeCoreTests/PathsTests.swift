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
    #expect(run == base.appending(path: "claude-gpt-live-bridge/run"))
    #expect(try permissions(run) == 0o700)
    #expect(try permissions(run.deletingLastPathComponent()) == 0o700)
  }

  @Test func loosenedDirIsTightened() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let data = base.appending(path: "claude-gpt-live-bridge")
    try FileManager.default.createDirectory(
      at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    #expect(try Paths.dataDir(in: base) == data)
    #expect(try permissions(data) == 0o700)
  }

  @Test func symlinkedDirIsRefused() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let elsewhere = base.appending(path: "elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: base.appending(path: "claude-gpt-live-bridge"), withDestinationURL: elsewhere)
    #expect(throws: PathsError.self) { try Paths.dataDir(in: base) }
  }
}
