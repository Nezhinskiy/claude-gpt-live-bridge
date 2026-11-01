/// The text notification that goes with the chime for a result waiting while the line is
/// closed. It names the sessions, never a result: a result can be private, and it is long.
public struct ResultNotice: Sendable, Equatable {
  public let title = "LiveBridge"
  public let body: String
  /// One identity for every notice, so each replaces the one before instead of stacking.
  public let identifier = "io.github.nezhinskiy.livebridge.waiting-results"

  /// The notice for the results waiting, nil when none waits. `labels` names the joined
  /// sessions; a line of LiveBridge's own or from a session that left names none.
  public static func waiting(_ lines: [VoiceLine], labels: [SessionID: String]) -> ResultNotice? {
    guard !lines.isEmpty else { return nil }
    var sessions: [String] = []
    for label in lines.compactMap({ $0.session.flatMap { labels[$0] } })
    where !sessions.contains(label) {
      sessions.append(label)
    }
    switch sessions.count {
    case 0: return ResultNotice(body: "A new result is waiting — speak to hear it.")
    case 1 where lines.count(where: { $0.session.flatMap { labels[$0] } != nil }) == 1:
      return ResultNotice(body: "\(sessions[0]) has a new result — speak to hear it.")
    case 1: return ResultNotice(body: "\(sessions[0]) has new results — speak to hear them.")
    default:
      return ResultNotice(body: "\(sessions.count) sessions have new results — speak to hear them.")
    }
  }
}

/// Posts the notices; the app's side asks macOS for permission and shows them.
public protocol ResultNotifying: Sendable {
  func post(_ notice: ResultNotice) async
}
