/// The mark between the bridge towers in the menu bar glyph. Status never rests on color alone:
/// the bars' shape, this badge and the broken deck carry it.
public enum Badge: Sendable, Equatable {
  case none
  /// A session is working on a request: a turning ring.
  case working
  /// A session waits for the owner's approval: a pulsing diamond.
  case approval
  /// Results wait until the owner next speaks: a dot.
  case unheard
  /// The call cannot start or just stopped: the deck breaks at mid-span.
  case problem
}

/// The accent the menu gives the call.
public enum Tint: Sendable, Equatable { case quiet, active, attention, problem }

public struct SessionRowPresentation: Sendable, Equatable, Identifiable {
  public let id: SessionID
  public let label: String
  public let detail: String
  public let activity: SessionActivity
  public let isTarget: Bool
}

/// What the menu bar glyph and the menu show for one `StatusReply`. Pure.
public struct StatusPresentation: Sendable, Equatable {
  /// The call phase the glyph's bars draw.
  public let bars: CallPhase
  public let badge: Badge
  public let tint: Tint
  public let headline: String
  public let detail: String
  /// What the call button does.
  public let action: CallAction
  /// Start needs a joined session to talk to; Stop is always possible.
  public let canAct: Bool
  public let rows: [SessionRowPresentation]
  private let problem: String?
  public let unheard: Int
  public let minutes: String
  /// What joins a Claude Code session.
  public static let joinCommand = "/live on"

  /// A problem outranks everything; then a session waiting for approval, results the owner has
  /// not heard, and a session at work.
  public init(_ s: StatusReply) {
    let activities = Set(s.sessions.map(\.activity))
    bars = s.call
    problem = s.problem
    unheard = s.unheard
    badge =
      if s.problem != nil { .problem } else if activities.contains(.approval) {
        .approval
      } else if s.unheard > 0 { .unheard } else if activities.contains(.working) {
        .working
      } else { .none }
    tint =
      switch badge {
      case .problem: .problem
      case .approval: .attention
      default: [.connecting, .live].contains(s.call) ? .active : .quiet
      }
    action = s.call == .off ? .start : .stop
    canAct = action == .stop || !s.sessions.isEmpty
    let target = s.sessions.first(where: \.isTarget)?.label
    (headline, detail) =
      switch s.call {
      case .off:
        (
          "Off",
          s.sessions.isEmpty
            ? "Run \(Self.joinCommand) in a Claude Code session to start."
            : "Start to talk to your sessions."
        )
      case .listening: ("Listening — line closed", "The line opens when you speak.")
      case .connecting: ("Connecting…", "Opening the voice line.")
      case .live: ("Live", target.map { "Talking to \($0)" } ?? "No session has joined yet.")
      }
    rows = s.sessions.map {
      SessionRowPresentation(
        id: $0.sessionId, label: $0.label, detail: Self.text(of: $0.activity),
        activity: $0.activity, isTarget: $0.isTarget)
    }
    minutes =
      "\(Int(s.minutesThisCall.rounded())) min this call · \(Int(s.minutesToday.rounded())) min today"
  }

  private static func text(of activity: SessionActivity) -> String {
    switch activity {
    case .idle: "Idle"
    case .working: "Claude working"
    case .approval: "Waiting for your approval"
    }
  }

  /// The menu bar item's spoken description.
  public var accessibilityLabel: String {
    let badgeText: String? =
      switch badge {
      case .none: nil
      case .working: "Claude working"
      case .approval: "approval needed"
      case .unheard: "\(unheard) unheard"
      case .problem: problem
      }
    return (["LiveBridge", headline] + [badgeText].compactMap { $0 }).joined(separator: ", ")
  }
}
