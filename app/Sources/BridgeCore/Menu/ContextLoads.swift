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

/// The menu's Load context item for the target: loading while the bridge has its summary in flight
/// (`SummaryDisplay.loading`, whatever asked for it), then loaded for `shownLoaded` after a summary
/// with text was taken. An empty answer shows nothing. Pure: the caller passes the time.
public enum ContextLoads {
  public static func state(_ display: SummaryDisplay, at now: Date) -> ContextLoadState {
    if display == .loading { return .loading }
    return nextChange(display, after: now) == nil ? .ready : .loaded
  }

  /// When the state of `display` next changes by itself, after `now`: the end of loaded.
  public static func nextChange(_ display: SummaryDisplay, after now: Date) -> Date? {
    guard case .loaded(let at) = display, now < at + SummaryAsks.Policy.shownLoaded else {
      return nil
    }
    return at + SummaryAsks.Policy.shownLoaded
  }
}
