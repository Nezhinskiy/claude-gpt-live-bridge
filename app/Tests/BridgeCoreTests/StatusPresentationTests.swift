import Testing

@testable import BridgeCore

struct StatusPresentationTests {
  static let target = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  static let other = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")

  static func status(
    _ call: CallPhase, other activity: SessionActivity = .idle, problem: String? = nil,
    unheard: Int = 0, muted: Bool = false
  ) -> StatusReply {
    StatusReply(
      call: call,
      sessions: [
        SessionRow(sessionId: target, label: "Example session", activity: .idle, isTarget: true),
        SessionRow(
          sessionId: other, label: "Docs site · ab12", activity: activity, isTarget: false),
      ],
      minutesToday: 31.4, problem: problem, unheard: unheard, isMuted: muted)
  }

  static let phases: [(CallPhase, String, CallAction, CallAction?, Tint)] = [
    (.off, "Off", .start, nil, .quiet),
    (.listening, "Listening — line closed", .stop, .mute, .quiet),
    (.connecting, "Connecting…", .stop, .mute, .active),
    (.live, "Live", .stop, .mute, .active),
  ]

  @Test(arguments: [SessionActivity.idle, .working, .approval])
  func eachPhaseWithEachActivity(_ activity: SessionActivity) {
    for (phase, headline, action, muteAction, tint) in Self.phases {
      let shown = StatusPresentation(Self.status(phase, other: activity))
      #expect(shown.bars == phase)
      #expect(shown.headline == headline)
      #expect(shown.action == action)
      #expect(shown.muteAction == muteAction)
      let badge: Badge =
        phase == .off && activity == .working
        ? .none : [.idle: .none, .working: .working, .approval: .approval][activity]!
      #expect(shown.badge == badge, "\(phase) \(activity)")
      #expect(shown.tint == (activity == .approval ? .attention : tint), "\(phase) \(activity)")
      #expect(shown.badge != .problem)
    }
  }

  @Test func aMutedCallOffersUnmute() {
    #expect(
      StatusPresentation(Self.status(.listening, muted: true)).muteAction == .unmute)
  }

  @Test func mutedListeningSaysOnlyClaudeOpensTheLine() {
    let shown = StatusPresentation(Self.status(.listening, muted: true))
    #expect(shown.headline == "Muted — line closed")
    #expect(shown.detail == "The line opens when Claude answers you.")
    #expect(shown.accessibilityLabel.contains("Muted"))
  }

  @Test func aMutedConnectingCallKeepsItsHeadline() {
    let shown = StatusPresentation(Self.status(.connecting, muted: true))
    #expect(shown.headline == "Connecting… · muted")
  }

  @Test func aMutedLineKeepsItsPhase() {
    let shown = StatusPresentation(Self.status(.live, muted: true))
    #expect(shown.headline == "Live · muted")
    #expect(shown.bars == .live)
    #expect(shown.tint == .active)
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
    #expect(shown.accessibilityLabel.contains(sentence))
  }

  /// The menu bar stays still while the call is stopped (the table above), but the row still says so.
  @Test func aStoppedCallsRowStillSaysClaudeWorks() {
    #expect(
      StatusPresentation(Self.status(.off, other: .working)).rows[1].detail == "Claude working")
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

  /// The ring turns while the target's own summary is on its way and the call is on.
  @Test func loadingContextShowsWhileTheTargetsSummaryIsInFlight() {
    for phase in [CallPhase.listening, .connecting, .live] {
      let shown = StatusPresentation(Self.status(phase), targetSummary: .loading)
      #expect(shown.badge == .loadingContext, "\(phase)")
    }
    #expect(StatusPresentation(Self.status(.off), targetSummary: .loading).badge == .none)
    #expect(StatusPresentation(Self.status(.live), targetSummary: .none).badge == .none)
  }

  @Test func loadingContextRanksAfterProblemAndApprovalBeforeUnheard() {
    let loading = SummaryDisplay.loading
    let problem = StatusPresentation(
      Self.status(.listening, problem: "The line dropped.", unheard: 1), targetSummary: loading)
    #expect(problem.badge == .problem)
    let approval = StatusPresentation(
      Self.status(.live, other: .approval, unheard: 1), targetSummary: loading)
    #expect(approval.badge == .approval)
    let unheard = StatusPresentation(
      Self.status(.live, other: .working, unheard: 1), targetSummary: loading)
    #expect(unheard.badge == .loadingContext)
  }

  /// Start is disabled until a session joins, and the line under it names the command.
  @Test func startNeedsASession() {
    var empty = Self.status(.off)
    empty.sessions = []
    let shown = StatusPresentation(empty)
    #expect(!shown.canAct && shown.detail.contains("Run /live in"))
    #expect(StatusPresentation(Self.status(.off)).canAct)
    empty.call = .listening
    #expect(StatusPresentation(empty).canAct)  // Stop always works
  }

}
