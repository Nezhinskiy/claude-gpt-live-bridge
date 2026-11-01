import Testing

@testable import BridgeCore

struct StatusPresentationTests {
  static let target = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  static let other = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")

  static func status(
    _ call: CallPhase, other activity: SessionActivity = .idle, problem: String? = nil,
    unheard: Int = 0
  ) -> StatusReply {
    StatusReply(
      call: call,
      sessions: [
        SessionRow(sessionId: target, label: "Example session", activity: .idle, isTarget: true),
        SessionRow(
          sessionId: other, label: "Docs site · ab12", activity: activity, isTarget: false),
      ],
      minutesToday: 31.4, minutesThisCall: 4.2, problem: problem, lastContext: nil,
      recentTranscript: [], unheard: unheard)
  }

  static let phases: [(CallPhase, String, CallAction, Tint)] = [
    (.off, "Off", .start, .quiet),
    (.listening, "Listening — line closed", .stop, .quiet),
    (.connecting, "Connecting…", .stop, .active),
    (.live, "Live", .stop, .active),
  ]

  @Test(arguments: [SessionActivity.idle, .working, .approval])
  func eachPhaseWithEachActivity(_ activity: SessionActivity) {
    for (phase, headline, action, tint) in Self.phases {
      let shown = StatusPresentation(Self.status(phase, other: activity))
      #expect(shown.bars == phase)
      #expect(shown.headline == headline)
      #expect(shown.action == action)
      let badge: Badge = [.idle: .none, .working: .working, .approval: .approval][activity]!
      #expect(shown.badge == badge, "\(phase) \(activity)")
      #expect(shown.tint == (activity == .approval ? .attention : tint), "\(phase) \(activity)")
      #expect(shown.problem == nil)
    }
  }

  @Test func liveNamesTheTarget() {
    #expect(StatusPresentation(Self.status(.live)).detail == "Talking to Example session")
  }

  @Test(arguments: [CallPhase.off, .listening])
  func problemOutranksEveryBadge(_ phase: CallPhase) {
    let sentence = "Codex is not signed in: run `codex login` with your ChatGPT account."
    let shown = StatusPresentation(
      Self.status(phase, other: .approval, problem: sentence, unheard: 2))
    #expect(shown.badge == .problem)
    #expect(shown.tint == .problem)
    #expect(shown.problem == sentence)
    #expect(shown.accessibilityLabel.contains(sentence))
  }

  @Test func unheardOutranksWorkingNotApproval() {
    #expect(
      StatusPresentation(Self.status(.listening, other: .working, unheard: 2)).badge == .unheard)
    #expect(
      StatusPresentation(Self.status(.listening, other: .approval, unheard: 2)).badge == .approval)
    #expect(StatusPresentation(Self.status(.listening, unheard: 2)).unheard == 2)
  }

  @Test func rowsShowActivityAndTarget() {
    let rows = StatusPresentation(Self.status(.live, other: .approval)).rows
    #expect(rows.map(\.label) == ["Example session", "Docs site · ab12"])
    #expect(rows.map(\.detail) == ["Idle", "Waiting for your approval"])
    #expect(rows.map(\.isTarget) == [true, false])
    let working = StatusPresentation(Self.status(.live, other: .working)).rows[1]
    #expect(working.detail == "Claude working")
  }

  /// Start is disabled until a session joins, and the line under it names the command.
  @Test func startNeedsASession() {
    var empty = Self.status(.off)
    empty.sessions = []
    let shown = StatusPresentation(empty)
    #expect(!shown.canAct && shown.detail.contains("/live on"))
    #expect(StatusPresentation(Self.status(.off)).canAct)
    empty.call = .listening
    #expect(StatusPresentation(empty).canAct)  // Stop always works
  }

  @Test func minutesAreRounded() {
    #expect(StatusPresentation(Self.status(.live)).minutes == "4 min this call · 31 min today")
  }
}
