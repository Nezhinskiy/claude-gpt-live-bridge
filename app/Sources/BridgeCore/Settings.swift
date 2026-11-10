import Foundation
import Observation
import os

/// The app's own settings, kept in `<data dir>/settings.json`.
public struct Settings: Codable, Sendable, Equatable {
  /// The realtime voice; nil leaves the choice to codex.
  public var voice: String?
  /// Keep what the owner types while the call is stopped out of the voice's conversation, and
  /// load no summary by itself: only Load context does, or an older mod's `/live context`, and a
  /// session's first summary under `loadContextOnFirstCall`.
  public var pauseSyncWhileStopped: Bool
  /// A line that opens for a session the voice has no summary for asks for one, even under the
  /// pause or a paused mark. That summary is written from the whole transcript, paused text
  /// included.
  public var loadContextOnFirstCall: Bool
  /// Post a notification with the chime for a result waiting while the line is closed.
  public var notifyResults: Bool
  /// Play a short sound when a handoff is queued for a session (BR-001) and when a session's
  /// answer reaches the call. The chime for a result that waits does not depend on it. The name
  /// predates the answer's sound, and saved settings hold it.
  public var confirmHandoffs: Bool
  /// The owner's own prompt for the voice, added after its rules (`VoicePrompt.composed`);
  /// empty adds nothing.
  public var prompt: String
  /// Prefer TCP port 443 over UDP for the voice line's audio, for a connection that loses
  /// packets (`AnswerSDP.preferringTCP`); each line reads it when it opens.
  public var connectsOverTCP: Bool
  /// Check GitHub for a newer release once a day; nil leaves it to the build, on for a release
  /// build and off for one from source (`UpdatePolicy.checksAutomatically`).
  public var checkUpdatesAutomatically: Bool?

  public init(
    voice: String? = nil, pauseSyncWhileStopped: Bool = false, loadContextOnFirstCall: Bool = true,
    notifyResults: Bool = true, confirmHandoffs: Bool = true, prompt: String = "",
    connectsOverTCP: Bool = false, checkUpdatesAutomatically: Bool? = nil
  ) {
    self.voice = voice
    self.pauseSyncWhileStopped = pauseSyncWhileStopped
    self.loadContextOnFirstCall = loadContextOnFirstCall
    self.notifyResults = notifyResults
    self.confirmHandoffs = confirmHandoffs
    self.prompt = prompt
    self.connectsOverTCP = connectsOverTCP
    self.checkUpdatesAutomatically = checkUpdatesAutomatically
  }

  /// The key of the setting this one replaced.
  private enum LegacyKeys: String, CodingKey { case autoContext }

  /// A field the file lacks keeps its default, and one it no longer has (`model`) is ignored.
  /// An old `autoContext: false`, the owner's choice to load summaries by hand, becomes the
  /// pause when the file does not say. A file from before `loadContextOnFirstCall` leaves it off
  /// under the pause: that owner chose context only from the menu, and an update must not widen it.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    voice = try container.decodeIfPresent(String.self, forKey: .voice)
    let optedOut =
      try decoder.container(keyedBy: LegacyKeys.self)
      .decodeIfPresent(Bool.self, forKey: .autoContext) == false
    pauseSyncWhileStopped =
      try container.decodeIfPresent(Bool.self, forKey: .pauseSyncWhileStopped) ?? optedOut
    loadContextOnFirstCall =
      try container.decodeIfPresent(Bool.self, forKey: .loadContextOnFirstCall)
      ?? !pauseSyncWhileStopped
    notifyResults = try container.decodeIfPresent(Bool.self, forKey: .notifyResults) ?? true
    confirmHandoffs = try container.decodeIfPresent(Bool.self, forKey: .confirmHandoffs) ?? true
    prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    connectsOverTCP = try container.decodeIfPresent(Bool.self, forKey: .connectsOverTCP) ?? false
    checkUpdatesAutomatically = try container.decodeIfPresent(
      Bool.self, forKey: .checkUpdatesAutomatically)
  }
}

/// The settings: the one copy the app has, read where each is needed and written on each
/// change. Observable, so the Settings window follows it; safe from any thread, as the line
/// reads the voice and the prompt each time it opens.
public final class SettingsStore: Sendable, Observable {
  private let file: URL?
  private let state: OSAllocatedUnfairLock<Settings>
  private let registrar = ObservationRegistrar()

  /// A file that does not decode gives the defaults; with no file, changes are not kept.
  public init(file: URL?) {
    self.file = file
    let saved = file.flatMap { try? Data(contentsOf: $0) }.flatMap {
      try? JSONDecoder().decode(Settings.self, from: $0)
    }
    state = OSAllocatedUnfairLock(initialState: saved ?? Settings())
  }

  public var current: Settings {
    registrar.access(self, keyPath: \.current)
    return state.withLock { $0 }
  }

  public func update(_ change: (inout Settings) -> Void) {
    let next = registrar.withMutation(of: self, keyPath: \.current) {
      state.withLockUnchecked { settings in
        change(&settings)
        return settings
      }
    }
    guard let file else { return }
    try? JSONEncoder().encode(next).write(to: file, options: .atomic)
  }
}
