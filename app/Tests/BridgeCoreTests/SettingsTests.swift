import Foundation
import Observation
import Testing
import os

@testable import BridgeCore

struct SettingsStoreTests {
  @Test func defaultsUntilChanged() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    let store = SettingsStore(file: file)
    #expect(store.current == Settings(voice: nil, notifyResults: true))
    #expect(store.current.prompt == "")
  }

  /// A file from before the setting was removed: opting out of the automatic summary becomes
  /// the pause, so summaries stay by hand; opting in leaves it off.
  @Test func anOldOptOutBecomesThePause() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    try Data(#"{"voice":"marin","autoContext":false}"#.utf8).write(to: file)
    #expect(SettingsStore(file: file).current.pauseSyncWhileStopped)
    // an explicit choice of the new setting wins over the old key
    try Data(#"{"autoContext":false,"pauseSyncWhileStopped":false}"#.utf8).write(to: file)
    #expect(!SettingsStore(file: file).current.pauseSyncWhileStopped)
  }

  @Test func anOldOptInLeavesThePauseOff() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    try Data(#"{"autoContext":true}"#.utf8).write(to: file)
    #expect(!SettingsStore(file: file).current.pauseSyncWhileStopped)
  }

  @Test func pauseSyncDefaultsOff() throws {
    #expect(!Settings().pauseSyncWhileStopped)
    let file = try temporaryDirectory().appending(path: "settings.json")
    try Data(#"{"voice":"marin"}"#.utf8).write(to: file)
    #expect(!SettingsStore(file: file).current.pauseSyncWhileStopped)
    SettingsStore(file: file).update { $0.pauseSyncWhileStopped = true }
    #expect(SettingsStore(file: file).current.pauseSyncWhileStopped)
  }

  /// UDP by default, an older file included; the choice is kept.
  @Test func tcpIsOffUntilTurnedOn() throws {
    #expect(!Settings().connectsOverTCP)
    let file = try temporaryDirectory().appending(path: "settings.json")
    try Data(#"{"voice":"marin"}"#.utf8).write(to: file)
    #expect(!SettingsStore(file: file).current.connectsOverTCP)
    SettingsStore(file: file).update { $0.connectsOverTCP = true }
    #expect(SettingsStore(file: file).current.connectsOverTCP)
  }

  @Test func aFreshInstallLoadsContextOnTheFirstCall() {
    #expect(Settings().loadContextOnFirstCall)
  }

  /// The settings a file gives, as an update reads it.
  private func decoded(_ json: String) throws -> Settings {
    let file = try temporaryDirectory().appending(path: "settings.json")
    try Data(json.utf8).write(to: file)
    return SettingsStore(file: file).current
  }

  @Test func aFileWithoutThePauseLoadsContextOnTheFirstCall() throws {
    #expect(try decoded(#"{"voice":"marin"}"#).loadContextOnFirstCall)
  }

  /// They chose that context loads only from the menu; an update must not widen that.
  @Test func aFileWithThePauseOnDoesNotLoadContextOnTheFirstCall() throws {
    #expect(try !decoded(#"{"pauseSyncWhileStopped":true}"#).loadContextOnFirstCall)
  }

  @Test func anOldOptOutDoesNotLoadContextOnTheFirstCall() throws {
    #expect(try !decoded(#"{"autoContext":false}"#).loadContextOnFirstCall)
  }

  /// The migration follows the pause as read: an explicit pause off wins over the old opt-out.
  @Test func anOldOptOutWithThePauseOffLoadsContextOnTheFirstCall() throws {
    let settings = try decoded(#"{"autoContext":false,"pauseSyncWhileStopped":false}"#)
    #expect(settings.loadContextOnFirstCall)
  }

  @Test func aSavedChoiceWinsOverThePauseMigration() throws {
    let on = try decoded(#"{"pauseSyncWhileStopped":true,"loadContextOnFirstCall":true}"#)
    #expect(on.loadContextOnFirstCall)
    let off = try decoded(#"{"loadContextOnFirstCall":false}"#)
    #expect(!off.loadContextOnFirstCall)
  }

  /// An owner with the pause on turns it on in Settings, and the migration does not undo that.
  @Test func turningItOnUnderThePauseIsKept() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    try Data(#"{"pauseSyncWhileStopped":true}"#.utf8).write(to: file)
    SettingsStore(file: file).update { $0.loadContextOnFirstCall = true }
    #expect(SettingsStore(file: file).current.loadContextOnFirstCall)
  }

  @Test func theLineKeepsTodaysTimersByDefault() {
    #expect(Settings().timeouts == CallMachine.Timeouts(silence: 20, firstWord: 5, noise: 90))
  }

  @Test func aFileFromBeforeTheTimersKeepsTodaysTimers() throws {
    #expect(try decoded(#"{"voice":"marin"}"#).timeouts == Settings().timeouts)
  }

  @Test func changesAreKeptAcrossRestarts() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    SettingsStore(file: file).update {
      $0.voice = "cedar"
      $0.notifyResults = false
      $0.prompt = "Speak with me in Spanish."
    }
    #expect(
      SettingsStore(file: file).current
        == Settings(
          voice: "cedar", notifyResults: false,
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
        == Settings(voice: "marin", notifyResults: true))
    try Data(#"{"voice":"marin","model":"gpt-realtime-example","prompt":"Hi."}"#.utf8)
      .write(to: file)
    #expect(SettingsStore(file: file).current == Settings(voice: "marin", prompt: "Hi."))
  }

  /// A file from before the update setting reads with it unset, which leaves the choice to the
  /// build (`UpdatePolicy.checksAutomatically`).
  @Test func anOlderSettingsFileLeavesUpdateChecksUnset() throws {
    let file = try temporaryDirectory().appending(path: "settings.json")
    try Data(#"{"voice":"marin","autoContext":true}"#.utf8).write(to: file)
    #expect(SettingsStore(file: file).current.checkUpdatesAutomatically == nil)
    SettingsStore(file: file).update { $0.checkUpdatesAutomatically = false }
    #expect(SettingsStore(file: file).current.checkUpdatesAutomatically == false)
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
