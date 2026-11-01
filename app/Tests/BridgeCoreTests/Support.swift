import Foundation
import Testing

@testable import BridgeCore

/// The observed codex messages in `Fixtures/adr` (ADR 0001).
func adrFixture(_ name: String, extension ext: String = "json") throws -> Data {
  let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/adr")
  return try Data(contentsOf: try #require(url))
}

func adrJSON(_ name: String) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: adrFixture(name))
}

/// Waits, in real time, up to two seconds for `condition`.
func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
  for _ in 0..<200 {
    if try await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return false
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
