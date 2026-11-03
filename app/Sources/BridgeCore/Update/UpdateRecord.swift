import Foundation

/// What an update leaves for the app that starts after it: which versions, what became of the
/// mod, and whether the notice about it has been posted. Kept in `updates/record.json`.
public struct UpdateRecord: Codable, Equatable, Sendable {
  /// The version that was running.
  public var from: AppVersion
  /// The version that was installed.
  public var to: AppVersion
  /// What became of the Claude Code mod.
  public var mod: ModOutcome
  /// The relaunched app has posted its notice, so it does not post it again.
  public var noticePosted: Bool

  public init(from: AppVersion, to: AppVersion, mod: ModOutcome, noticePosted: Bool) {
    self.from = from
    self.to = to
    self.mod = mod
    self.noticePosted = noticePosted
  }

  /// The commands that update the mod when LiveBridge could not.
  public static let byHandCommands = Updater.modCommands.map {
    (["claude"] + $0).joined(separator: " ")
  }

  /// The record in `file`, or nil when there is none or it does not decode.
  public static func read(_ file: URL) -> UpdateRecord? {
    (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(UpdateRecord.self, from: $0) }
  }

  /// Writes the record to `file` in one step, creating its folder when it is not there yet.
  public func write(_ file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(self).write(to: file, options: .atomic)
  }
}

/// What became of the mod during an update.
public enum ModOutcome: Codable, Equatable, Sendable {
  /// The mod was updated along with the app.
  case updated
  /// The mod was not updated: the owner runs these commands.
  case byHand(commands: [String])
}
