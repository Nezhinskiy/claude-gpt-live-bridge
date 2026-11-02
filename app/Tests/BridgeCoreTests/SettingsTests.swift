import Foundation
import Testing

@testable import BridgeCore

struct SettingsStoreTests {
  @Test func defaultsUntilChanged() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    let store = SettingsStore(file: file)
    #expect(store.current == Settings(voice: nil, autoContext: false, notifyResults: true))
    #expect(store.current.prompt == "" && store.current.model == nil)
  }

  @Test func changesAreKeptAcrossRestarts() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    SettingsStore(file: file).update {
      $0.voice = "cedar"
      $0.autoContext = true
      $0.notifyResults = false
      $0.prompt = "Speak with me in Spanish."
      $0.model = "gpt-realtime-example"
    }
    #expect(
      SettingsStore(file: file).current
        == Settings(
          voice: "cedar", autoContext: true, notifyResults: false,
          prompt: "Speak with me in Spanish.", model: "gpt-realtime-example"))
    SettingsStore(file: file).update {
      $0.voice = nil
      $0.model = nil
    }
    #expect(SettingsStore(file: file).current.voice == nil)
    #expect(SettingsStore(file: file).current.model == nil)
  }

  /// A file that does not decode, or lacks a field a later build added, keeps the defaults.
  @Test func anUnreadableOrOlderFileKeepsTheDefaults() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    try Data("not json".utf8).write(to: file)
    #expect(SettingsStore(file: file).current == Settings())
    try Data(#"{"voice":"marin"}"#.utf8).write(to: file)
    #expect(
      SettingsStore(file: file).current
        == Settings(voice: "marin", autoContext: false, notifyResults: true))
  }
}

@Suite(.timeLimit(.minutes(1)))
struct VoicesTests {
  /// codex 0.166.0's reply to `thread/realtime/listVoices` (probed): the app's sessions are V3.
  static let reply: JSONValue = [
    "voices": [
      "v1": ["juniper", "maple", "cove"], "v2": ["alloy", "marin", "cedar"],
      "v3": ["juniper", "maple", "cove", "aube", "viola"], "defaultV1": "cove",
      "defaultV2": "marin",
    ]
  ]

  @Test func listsTheV3Voices() async throws {
    let rpc = try FakeRPC()
    await rpc.set("thread/realtime/listVoices", [Self.reply])
    #expect(try await Voices.list(client: rpc) == ["juniper", "maple", "cove", "aube", "viola"])
    #expect(await rpc.params("thread/realtime/listVoices") == [[:]])
  }

  @Test func aReplyWithoutV3VoicesIsAProblem() async throws {
    let rpc = try FakeRPC()
    await rpc.set("thread/realtime/listVoices", [["voices": ["v1": ["cove"]]]])
    await #expect(throws: CodexProblem.self) { try await Voices.list(client: rpc) }
  }

  /// A choice codex no longer offers falls back to codex's default; with no list there is
  /// nothing to check it against, so it is kept.
  @Test func aChoiceMustBeOffered() {
    #expect(Voices.effective("viola", offered: ["viola", "cove"]) == "viola")
    #expect(Voices.effective("cedar", offered: ["viola", "cove"]) == nil)
    #expect(Voices.effective("cedar", offered: nil) == "cedar")
    #expect(Voices.effective(nil, offered: ["viola"]) == nil)
  }
}
