import Foundation
import Observation
import os

/// The app's own settings, kept in `<data dir>/settings.json`.
public struct Settings: Codable, Sendable, Equatable {
  /// The realtime voice; nil leaves the choice to codex.
  public var voice: String?
  /// Keep what the owner types while the call is stopped out of the voice's conversation, and
  /// load no summary by itself: only Load context or `/live context` does.
  public var pauseSyncWhileStopped: Bool
  /// Post a notification with the chime for a result waiting while the line is closed.
  public var notifyResults: Bool
  /// Play a short sound when a handoff is queued for a session (BR-001).
  public var confirmHandoffs: Bool
  /// The owner's own prompt for the voice, added after its rules (`VoicePrompt.composed`);
  /// empty adds nothing.
  public var prompt: String
  /// Check GitHub for a newer release once a day; nil leaves it to the build, on for a release
  /// build and off for one from source (`UpdatePolicy.checksAutomatically`).
  public var checkUpdatesAutomatically: Bool?

  public init(
    voice: String? = nil, pauseSyncWhileStopped: Bool = false,
    notifyResults: Bool = true, confirmHandoffs: Bool = true, prompt: String = "",
    checkUpdatesAutomatically: Bool? = nil
  ) {
    self.voice = voice
    self.pauseSyncWhileStopped = pauseSyncWhileStopped
    self.notifyResults = notifyResults
    self.confirmHandoffs = confirmHandoffs
    self.prompt = prompt
    self.checkUpdatesAutomatically = checkUpdatesAutomatically
  }

  /// The key of the setting this one replaced.
  private enum LegacyKeys: String, CodingKey { case autoContext }

  /// A field the file lacks keeps its default, and one it no longer has (`model`) is ignored.
  /// An old `autoContext: false`, the owner's choice to load summaries by hand, becomes the
  /// pause when the file does not say.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    voice = try container.decodeIfPresent(String.self, forKey: .voice)
    let optedOut =
      try decoder.container(keyedBy: LegacyKeys.self)
      .decodeIfPresent(Bool.self, forKey: .autoContext) == false
    pauseSyncWhileStopped =
      try container.decodeIfPresent(Bool.self, forKey: .pauseSyncWhileStopped) ?? optedOut
    notifyResults = try container.decodeIfPresent(Bool.self, forKey: .notifyResults) ?? true
    confirmHandoffs = try container.decodeIfPresent(Bool.self, forKey: .confirmHandoffs) ?? true
    prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
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
