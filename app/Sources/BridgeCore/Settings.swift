import Foundation
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
    voice: String? = nil, autoContext: Bool = false, notifyResults: Bool = true,
    prompt: String = ""
  ) {
    self.voice = voice
    self.autoContext = autoContext
    self.notifyResults = notifyResults
    self.prompt = prompt
  }

  /// A field the file lacks keeps its default, so an older file still reads.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    voice = try container.decodeIfPresent(String.self, forKey: .voice)
    autoContext = try container.decodeIfPresent(Bool.self, forKey: .autoContext) ?? false
    notifyResults = try container.decodeIfPresent(Bool.self, forKey: .notifyResults) ?? true
    prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
  }
}

/// The settings, read once and written on each change. Safe from any thread: the voice and the
/// prompt are read each time the line opens.
public final class SettingsStore: Sendable {
  private let file: URL
  private let state: OSAllocatedUnfairLock<Settings>

  /// A file that does not decode gives the defaults.
  public init(file: URL) {
    self.file = file
    let saved = (try? Data(contentsOf: file)).flatMap {
      try? JSONDecoder().decode(Settings.self, from: $0)
    }
    state = OSAllocatedUnfairLock(initialState: saved ?? Settings())
  }

  public var current: Settings { state.withLock { $0 } }

  public func update(_ change: (inout Settings) -> Void) {
    let next = state.withLockUnchecked { settings in
      change(&settings)
      return settings
    }
    try? JSONEncoder().encode(next).write(to: file, options: .atomic)
  }
}
