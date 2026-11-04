import Foundation
import os

/// What the update check remembers between launches.
public struct UpdateState: Codable, Equatable, Sendable {
  /// When the last automatic check GitHub answered finished, with a release or an error.
  public var lastCheck: Date?
  /// The versions the owner has already been told about, so each is announced once.
  public var announced: Set<AppVersion>

  public init(lastCheck: Date? = nil, announced: Set<AppVersion> = []) {
    self.lastCheck = lastCheck
    self.announced = announced
  }
}

/// The check state, kept in `<data dir>/updates/state.json` and written on each change. Safe
/// from any thread.
public final class UpdateStateStore: Sendable {
  private let file: URL
  private let state: OSAllocatedUnfairLock<UpdateState>

  /// A file that is missing or does not decode gives the empty state.
  public init(file: URL) {
    self.file = file
    let saved = (try? Data(contentsOf: file)).flatMap {
      try? JSONDecoder().decode(UpdateState.self, from: $0)
    }
    state = OSAllocatedUnfairLock(initialState: saved ?? UpdateState())
  }

  public var current: UpdateState { state.withLock { $0 } }

  /// Applies `change` and writes the result, creating the folder when it is not there yet.
  public func update(_ change: (inout UpdateState) -> Void) {
    let next = state.withLockUnchecked { state in
      change(&state)
      return state
    }
    try? FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(next).write(to: file, options: .atomic)
  }
}
