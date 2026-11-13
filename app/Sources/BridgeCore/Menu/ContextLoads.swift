import Foundation

/// Why the target's voice would want a summary, as far as the menu is concerned.
public enum ContextNeed: Sendable, Equatable {
  /// The voice has the whole session.
  case none
  /// No line is open, and the next one loads the only thing missing, a summary, by itself.
  case withTheLine
  /// A press is worth offering: a gap, a mod that does not sync or too many lines, which the next
  /// line also asks for, or a pause that holds the next line back, so only a press loads.
  case load
}

/// Where the menu's Load context stands for one session.
public enum ContextLoadState: Sendable, Equatable {
  /// Nothing pending: the button can be pressed.
  case ready
  /// The session's summary is on its way.
  case loading
  /// The summary arrived a moment ago.
  case loaded
  /// The voice has the whole session: there is nothing to load.
  case current
  /// The next line loads the summary by itself.
  case withTheLine

  public var title: String {
    switch self {
    case .ready: "Load context"
    case .loading: "Loading context…"
    case .loaded: "Context loaded"
    case .current: "Context up to date"
    case .withTheLine: "Context loads with the line"
    }
  }

  /// Pressing again while a summary is on its way would only ask for it twice.
  public var isEnabled: Bool { self == .ready }

  /// As the menu shows it: a summary just loaded, or on its way, is shown as that; otherwise it
  /// is what the voice needs.
  public func shown(_ need: ContextNeed) -> ContextLoadState {
    guard self == .ready else { return self }
    switch need {
    case .none: return .current
    case .withTheLine: return .withTheLine
    case .load: return .ready
    }
  }
}

/// A session's answer to a context ask, as the bridge took it; `wrote` is false for an empty one.
public struct ContextArrival: Sendable, Equatable {
  public let session: SessionID
  public let wrote: Bool
}

/// The menu's Load context item for one session. While the bridge has the session's summary in
/// flight (`Bridge.summariesInFlight`, whatever asked for it) it is loading; a summary with text
/// that arrived (`POST /v1/context`) is then shown as loaded for `shownLoaded`. An empty answer
/// shows nothing. Pure: the caller passes the time and what is in flight.
public struct ContextLoads: Sendable, Equatable {
  public static let shownLoaded: TimeInterval = 3

  private var loadedAt: [SessionID: Date] = [:]

  public init() {}

  /// An answer from `id`; `wrote` is false for an empty one, which loaded nothing.
  public mutating func arrived(_ id: SessionID, at now: Date, wrote: Bool) {
    loadedAt[id] = wrote ? now : nil
  }

  /// Forgets the sessions not in `ids`: they left or were removed.
  public mutating func keep(only ids: Set<SessionID>) {
    loadedAt = loadedAt.filter { ids.contains($0.key) }
  }

  public func state(of id: SessionID, inFlight: Set<SessionID>, at now: Date) -> ContextLoadState {
    if inFlight.contains(id) { return .loading }
    if let loaded = loadedAt[id], now < loaded + Self.shownLoaded { return .loaded }
    return .ready
  }

  /// The first moment after `now` at which some session's state changes by itself.
  public func nextChange(after now: Date) -> Date? {
    loadedAt.values.map { $0 + Self.shownLoaded }.filter { $0 > now }.min()
  }
}
