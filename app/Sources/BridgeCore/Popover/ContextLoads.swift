import Foundation

/// Where the popover's Load context stands for one session.
public enum ContextLoadState: Sendable, Equatable {
  /// Nothing pending: the button can be pressed.
  case ready
  /// Pressed; the session's summary has not arrived yet.
  case loading
  /// The summary arrived a moment ago.
  case loaded

  public var title: String {
    switch self {
    case .ready: "Load context"
    case .loading: "Loading context…"
    case .loaded: "Context loaded"
    }
  }

  public var symbol: String {
    switch self {
    case .ready: "square.and.arrow.down"
    case .loading: "hourglass"
    case .loaded: "checkmark.circle"
    }
  }

  /// Pressing again while a summary is on its way would only ask for it twice.
  public var isEnabled: Bool { self == .ready }
}

/// The popover's Load context presses, per session: pending from the press until that session's
/// summary arrives (`POST /v1/context`), `timeout` passes or the session leaves; then shown as
/// loaded for `shownLoaded`. Pure: the caller passes the time.
public struct ContextLoads: Sendable, Equatable {
  public static let timeout: TimeInterval = 60
  public static let shownLoaded: TimeInterval = 3

  private var pressedAt: [SessionID: Date] = [:]
  private var loadedAt: [SessionID: Date] = [:]

  public init() {}

  public mutating func pressed(_ id: SessionID, at now: Date) {
    pressedAt[id] = now
    loadedAt[id] = nil
  }

  /// A summary from `id`; it counts only as the answer to a press still pending.
  public mutating func arrived(_ id: SessionID, at now: Date) {
    guard let pressed = pressedAt.removeValue(forKey: id), now < pressed + Self.timeout else {
      return
    }
    loadedAt[id] = now
  }

  /// Forgets the sessions not in `ids`: they left or were removed.
  public mutating func keep(only ids: Set<SessionID>) {
    pressedAt = pressedAt.filter { ids.contains($0.key) }
    loadedAt = loadedAt.filter { ids.contains($0.key) }
  }

  public func state(of id: SessionID, at now: Date) -> ContextLoadState {
    if let pressed = pressedAt[id], now < pressed + Self.timeout { return .loading }
    if let loaded = loadedAt[id], now < loaded + Self.shownLoaded { return .loaded }
    return .ready
  }

  /// The first moment after `now` at which some session's state changes by itself.
  public func nextChange(after now: Date) -> Date? {
    let deadlines =
      pressedAt.values.map { $0 + Self.timeout } + loadedAt.values.map { $0 + Self.shownLoaded }
    return deadlines.filter { $0 > now }.min()
  }
}
