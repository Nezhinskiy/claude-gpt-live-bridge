import Foundation
import Observation
import os

/// The app's own settings, kept in `<data dir>/settings.json`.
public struct Settings: Codable, Sendable, Equatable {
  /// The realtime voice; nil leaves the choice to codex.
  public var voice: String?
  /// Ask a session for its context summary whenever it becomes the target.
  public var autoContext: Bool
  /// Post a notification with the chime for a result waiting while the line is closed.
  public var notifyResults: Bool
  /// The owner's own prompt for the voice, added after its rules (`VoicePrompt.composed`);
  /// empty adds nothing.
  public var prompt: String

  public init(
    voice: String? = nil, autoContext: Bool = false, notifyResults: Bool = true, prompt: String = ""
  ) {
    self.voice = voice
    self.autoContext = autoContext
    self.notifyResults = notifyResults
    self.prompt = prompt
  }

  /// A field the file lacks keeps its default, and one it no longer has (`model`) is ignored.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    voice = try container.decodeIfPresent(String.self, forKey: .voice)
    autoContext = try container.decodeIfPresent(Bool.self, forKey: .autoContext) ?? false
    notifyResults = try container.decodeIfPresent(Bool.self, forKey: .notifyResults) ?? true
    prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
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
