import Foundation
import Testing

@testable import BridgeCore

struct ContextLoadsTests {
  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")
  let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func aPressIsPendingUntilItsContextArrives() {
    var loads = ContextLoads()
    #expect(loads.state(of: a, at: t0) == .ready)
    loads.pressed(a, at: t0)
    #expect(loads.state(of: a, at: t0 + 30) == .loading)
    #expect(loads.state(of: b, at: t0 + 30) == .ready)  // per session
    loads.arrived(a, at: t0 + 30)
    #expect(loads.state(of: a, at: t0 + 32.9) == .loaded)
    #expect(loads.state(of: a, at: t0 + 33) == .ready)
  }

  @Test func aPressGivesUpAfterSixtySeconds() {
    var loads = ContextLoads()
    loads.pressed(a, at: t0)
    #expect(loads.state(of: a, at: t0 + 59.9) == .loading)
    #expect(loads.state(of: a, at: t0 + 60) == .ready)
    loads.arrived(a, at: t0 + 61)  // too late to count as the press's
    #expect(loads.state(of: a, at: t0 + 61) == .ready)
  }

  @Test func aContextNobodyPressedForShowsNothing() {
    var loads = ContextLoads()
    loads.arrived(a, at: t0)  // as when automatic context asks a new target for it
    #expect(loads.state(of: a, at: t0) == .ready)
  }

  @Test func aSessionThatLeftIsForgotten() {
    var loads = ContextLoads()
    loads.pressed(a, at: t0)
    loads.pressed(b, at: t0)
    loads.keep(only: [b])
    #expect(loads.state(of: a, at: t0) == .ready)
    #expect(loads.state(of: b, at: t0) == .loading)
    loads.arrived(a, at: t0 + 1)
    #expect(loads.state(of: a, at: t0 + 1) == .ready)
  }

  @Test func theNextChangeIsTheEarliestDeadline() {
    var loads = ContextLoads()
    #expect(loads.nextChange(after: t0) == nil)
    loads.pressed(a, at: t0)
    loads.pressed(b, at: t0 + 10)
    #expect(loads.nextChange(after: t0) == t0 + 60)
    loads.arrived(b, at: t0 + 20)
    #expect(loads.nextChange(after: t0 + 20) == t0 + 23)
    #expect(loads.nextChange(after: t0 + 23) == t0 + 60)
    #expect(loads.nextChange(after: t0 + 60) == nil)
  }
}

struct MenuContentTests {
  static func id(_ n: Int) -> SessionID {
    SessionID(rawValue: String(format: "00000000-0000-0000-0000-%012d", n))
  }

  static func status(
    _ call: CallPhase = .off, sessions count: Int, target: Int = 0, problem: Problem? = nil,
    lines: [Conversation.Line] = [], context: String? = nil, unheard: Int = 0
  ) -> BridgeUpdate {
    BridgeUpdate(
      status: StatusReply(
        call: call,
        sessions: (0..<count).map {
          SessionRow(
            sessionId: id($0), label: "Session \($0)", activity: $0 == 1 ? .working : .idle,
            isTarget: $0 == target)
        },
        minutesToday: 31.4, problem: problem?.sentence, unheard: unheard),
      problem: problem, minutesThisCall: 4.2, context: context, conversation: lines)
  }

  static func menu(
    _ update: BridgeUpdate?, problem: Problem? = nil, load: ContextLoadState = .ready,
    available: AppVersion? = nil
  ) -> MenuContent {
    MenuContent(
      update: update, problem: problem ?? update?.problem, contextLoad: load,
      available: available)
  }

  static func line(_ speaker: Conversation.Line.Speaker, _ text: String) -> Conversation.Line {
    Conversation.Line(speaker: speaker, text: text)
  }

  @Test func withNoSessionsItOffersTheJoinCommand() {
    #expect(
      Self.menu(Self.status(sessions: 0)).outline == [
        "[call] Off · Start (disabled)",
        "---",
        "# Sessions",
        "Run /live on in a Claude Code session (disabled)",
        "Copy /live on",
        "---",
        "Load context (disabled)",
        "New conversation… (disabled)",
        "Conversation (disabled)",
        "---",
        "4 min this call · 31 min today (disabled)",
        "---",
        "Settings… ⌘,",
        "Quit LiveBridge ⌘Q",
      ])
  }

  @Test func anAvailableUpdateAddsItsInstallItem() {
    let outline = Self.menu(Self.status(sessions: 0), available: AppVersion("0.1.3")).outline
    let install = outline.firstIndex(of: "Install LiveBridge 0.1.3…")
    let settings = outline.firstIndex(of: "Settings… ⌘,")
    #expect(install != nil && settings != nil && install! < settings!)
  }

  @Test func noUpdateAddsNoInstallItem() {
    let outline = Self.menu(Self.status(sessions: 0), available: nil).outline
    #expect(!outline.contains { $0.hasPrefix("Install LiveBridge") })
  }

  @Test func threeSessionsAreRowsWithTheirMarker() {
    let menu = Self.menu(
      Self.status(
        .live, sessions: 3, target: 2,
        lines: [Self.line(.voice, "Hello."), Self.line(.owner, "Hi.")]))
    #expect(
      menu.outline == [
        "[call] Live · Stop",
        "---",
        "# Sessions",
        "( ) Session 0 — Idle",
        "( ) Session 1 — Claude working",
        "(•) Session 2 — Idle",
        "---",
        "Load context",
        "New conversation…",
        "Conversation ▸",
        "  # Session 2",
        "  [transcript]",
        "  | Voice: Hello.",
        "  | You: Hi.",
        "---",
        "4 min this call · 31 min today (disabled)",
        "---",
        "Settings… ⌘,",
        "Quit LiveBridge ⌘Q",
      ])
  }

  @Test func pastFiveSessionsTheRestAreInASubmenu() throws {
    let menu = Self.menu(Self.status(sessions: 7, target: 6))
    let rows = menu.items.filter { if case .session = $0 { true } else { false } }
    #expect(rows.count == MenuContent.visibleSessions)
    let outline = menu.outline
    let more = try #require(outline.firstIndex(of: "More sessions ▸"))
    #expect(outline[more - 1] == "( ) Session 4 — Idle")
    #expect(outline[more + 1] == "  ( ) Session 5 — Idle")
    #expect(outline[more + 2] == "  (•) Session 6 — Idle")
    #expect(outline[more + 3] == "---")
  }

  @Test func exactlyFiveSessionsNeedNoSubmenu() {
    #expect(!Self.menu(Self.status(sessions: 5)).outline.contains("More sessions ▸"))
  }

  @Test func aPendingLoadIsDisabledAndSaysSo() {
    let pending = Self.menu(Self.status(sessions: 2), load: .loading).outline
    #expect(pending.contains("Loading context… (disabled)"))
    let loaded = Self.menu(Self.status(sessions: 2), load: .loaded).outline
    #expect(loaded.contains("Context loaded (disabled)"))
    #expect(Self.menu(Self.status(sessions: 2)).outline.contains("Load context"))
  }

  static func card(_ menu: MenuContent) -> MenuContent.CallCard? {
    if case .call(let card)? = menu.items.first { card } else { nil }
  }

  /// Every line the app keeps, whole, in one item that scrolls.
  @Test func theConversationSubmenuHoldsTheWholeConversation() throws {
    let long = String(repeating: "word ", count: 120) + "end."
    let whole = (1...12).map { Self.line(.owner, "Line \($0).") } + [Self.line(.claude, long)]
    let menu = Self.menu(
      Self.status(sessions: 1, lines: whole, context: "[CONTEXT] Alpha: Tidy."))
    let items = try #require(
      menu.items.lazy.compactMap { item -> [MenuContent.Item]? in
        if case .submenu("Conversation", true, let items) = item { items } else { nil }
      }.first)
    let lines = try #require(
      items.lazy.compactMap { if case .transcript(let lines) = $0 { lines } else { nil } }.first)
    #expect(lines == whole)
    #expect(lines.last?.text == long)
    #expect(items.filter { if case .transcript = $0 { true } else { false } }.count == 1)
    #expect(items.suffix(2) == [.header("What was sent"), .sent("[CONTEXT] Alpha: Tidy.")])
  }

  @Test func theConversationSubmenuHoldsWhatWasSent() throws {
    let long = String(repeating: "a", count: MenuContent.sentCharacters + 50)
    let menu = Self.menu(Self.status(sessions: 1, context: long))
    let items = try #require(
      menu.items.lazy.compactMap { item -> [MenuContent.Item]? in
        if case .submenu("Conversation", true, let items) = item { items } else { nil }
      }.first)
    #expect(items.first == .header("What was sent"))
    let text = try #require(
      items.last.flatMap { if case .sent(let text) = $0 { text } else { nil } })
    #expect(text.count == MenuContent.sentCharacters)
    #expect(text.hasSuffix("…"))
  }

  @Test func theCardCarriesTheProblemAndItsHelp() throws {
    let problem = Problem.microphoneDenied
    let menu = Self.menu(Self.status(sessions: 1, problem: problem, unheard: 2))
    let card = try #require(Self.card(menu))
    #expect(card.problem == problem.sentence)
    #expect(card.opensMicrophoneSettings && card.codexHelp == nil)
    let signIn = try #require(Self.card(Self.menu(nil, problem: .codex(.notLoggedIn))))
    #expect(signIn.codexHelp == .signIn && !signIn.opensMicrophoneSettings)
    #expect(card.unheard == "2 unheard — speak to hear")
    #expect(card.tint == .problem)
    #expect(card.actionTitle == "Start")
    #expect(card.canAct)
  }

  @Test func withoutABridgeOnlyTheProblemSettingsAndQuitAreLeft() throws {
    let menu = Self.menu(nil, problem: .other("LiveBridge could not start its bridge: boom"))
    #expect(menu.outline == ["[call] Off", "---", "Settings… ⌘,", "Quit LiveBridge ⌘Q"])
    let card = try #require(Self.card(menu))
    #expect(card.problem == "LiveBridge could not start its bridge: boom")
    #expect(card.action == nil)
    #expect(Self.menu(nil).outline.first == "[call] Starting…")
  }

}
