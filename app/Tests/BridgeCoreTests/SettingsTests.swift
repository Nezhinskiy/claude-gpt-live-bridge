import Foundation
import Observation
import Testing
import os

@testable import BridgeCore

struct SettingsStoreTests {
  @Test func defaultsUntilChanged() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    let store = SettingsStore(file: file)
    #expect(store.current == Settings(voice: nil, autoContext: false, notifyResults: true))
    #expect(store.current.prompt == "")
  }

  @Test func changesAreKeptAcrossRestarts() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    SettingsStore(file: file).update {
      $0.voice = "cedar"
      $0.autoContext = true
      $0.notifyResults = false
      $0.prompt = "Speak with me in Spanish."
    }
    #expect(
      SettingsStore(file: file).current
        == Settings(
          voice: "cedar", autoContext: true, notifyResults: false,
          prompt: "Speak with me in Spanish."))
    SettingsStore(file: file).update { $0.voice = nil }
    #expect(SettingsStore(file: file).current.voice == nil)
  }

  /// A launch reads the settings and writes nothing: every saved value is there the next time
  /// (09d9df0 wiped one at each launch, writing it back from a copy not yet loaded).
  @Test func aLaunchWritesNothing() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    SettingsStore(file: file).update {
      $0.voice = "cedar"
      $0.autoContext = true
      $0.notifyResults = false
      $0.prompt = "Speak with me in Spanish."
    }
    let saved = try Data(contentsOf: file)
    let launched = SettingsStore(file: file)
    _ = launched.current
    #expect(try Data(contentsOf: file) == saved)
    #expect(SettingsStore(file: file).current == launched.current)
  }

  /// A file that does not decode, lacks a field a later build added, or has one an earlier
  /// build kept (the realtime model) reads; the missing fields keep their defaults.
  @Test func anUnreadableOlderOrNewerFileReads() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    try Data("not json".utf8).write(to: file)
    #expect(SettingsStore(file: file).current == Settings())
    try Data(#"{"voice":"marin"}"#.utf8).write(to: file)
    #expect(
      SettingsStore(file: file).current
        == Settings(voice: "marin", autoContext: false, notifyResults: true))
    try Data(#"{"voice":"marin","model":"gpt-realtime-example","prompt":"Hi."}"#.utf8)
      .write(to: file)
    #expect(SettingsStore(file: file).current == Settings(voice: "marin", prompt: "Hi."))
  }

  /// The Settings window follows the store: a change is observed where it was read.
  @Test func aChangeIsObserved() throws {
    let store = SettingsStore(file: nil)
    let changed = Flag()
    withObservationTracking {
      _ = store.current.voice
    } onChange: {
      changed.set()
    }
    store.update { $0.voice = "cedar" }
    #expect(changed.isSet && store.current.voice == "cedar")
  }
}

final class Flag: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: false)
  var isSet: Bool { state.withLock { $0 } }
  func set() { state.withLock { $0 = true } }
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
}
