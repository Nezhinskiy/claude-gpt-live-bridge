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

  @Test func theButtonSaysWhatIsHappening() {
    #expect(ContextLoadState.ready.title == "Load context")
    #expect(ContextLoadState.ready.isEnabled)
    #expect(ContextLoadState.loading.title == "Loading context…")
    #expect(!ContextLoadState.loading.isEnabled)
    #expect(ContextLoadState.loaded.title == "Context loaded")
    #expect(!ContextLoadState.loaded.isEnabled)
  }
}

struct TranscriptLineTests {
  @Test func aLineNamesItsSpeaker() {
    let line = TranscriptLine("Claude: [OK] Alpha: Done.")
    #expect(line.speaker == "Claude")
    #expect(line.text == "[OK] Alpha: Done.")
    #expect(TranscriptLine("no speaker here").speaker == "")
    #expect(TranscriptLine("no speaker here").text == "no speaker here")
  }

  @Test func aLongLineIsKeptWhole() {
    let paragraph = Array(repeating: "word", count: 200).joined(separator: " ")
    let line = TranscriptLine("Claude: [QUESTION] Alpha: \(paragraph)\n\n\(paragraph)\n")
    #expect(line.text == "[QUESTION] Alpha: \(paragraph)\n\n\(paragraph)")
  }

  @Test func aShortLineIsKeptAsItIs() {
    let text = "[OK] Alpha: Tests pass."
    #expect(TranscriptLine("Voice: \(text)").text == text)
  }
}

struct ConfirmationTests {
  @Test func newConversationSaysWhatIsErased() {
    let ask = Confirmation.newConversation(label: "Alpha")
    #expect(ask.title == "Erase the conversation with Alpha?")
    #expect(ask.message.contains("what the voice remembers"))
    #expect(ask.message.contains("loaded context"))
    #expect(ask.confirm == "Erase")
  }

  @Test func removeSaysHowToJoinAgain() {
    let ask = Confirmation.remove(label: "Alpha")
    #expect(ask.title == "Remove Alpha from LiveBridge?")
    #expect(ask.message.contains("erased"))
    #expect(ask.message.contains("/live on"))
    #expect(ask.confirm == "Remove")
  }
}

struct MenuContentTests {
  static func id(_ n: Int) -> SessionID {
    SessionID(rawValue: String(format: "00000000-0000-0000-0000-%012d", n))
  }

  static func status(
    _ call: CallPhase = .off, sessions count: Int, target: Int = 0, problem: String? = nil,
    lines: [String] = [], context: String? = nil, unheard: Int = 0
  ) -> StatusReply {
    StatusReply(
      call: call,
      sessions: (0..<count).map {
        SessionRow(
          sessionId: id($0), label: "Session \($0)", activity: $0 == 1 ? .working : .idle,
          isTarget: $0 == target)
      },
      minutesToday: 31.4, minutesThisCall: 4.2, problem: problem, lastContext: context,
      recentTranscript: lines, unheard: unheard)
  }

  /// The conversation is the status's last lines unless the test gives the whole of it.
  static func menu(
    _ status: StatusReply?, problem: String? = nil, load: ContextLoadState = .ready,
    conversation: [String]? = nil
  ) -> MenuContent {
    MenuContent(
      status: status, problem: problem ?? status?.problem, contextLoad: load,
      conversation: conversation ?? status?.recentTranscript ?? [])
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

  @Test func threeSessionsAreRowsWithTheirMarker() {
    let menu = Self.menu(
      Self.status(.live, sessions: 3, target: 2, lines: ["Voice: Hello.", "You: Hi."]))
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

  /// Every line the app keeps, whole, in one item that scrolls, not the status's last three.
  @Test func theConversationSubmenuHoldsTheWholeConversation() throws {
    let long = String(repeating: "word ", count: 120) + "end."
    let whole = (1...12).map { "You: Line \($0)." } + ["Claude: \(long)"]
    let menu = Self.menu(
      Self.status(sessions: 1, lines: Array(whole.suffix(3)), context: "[CONTEXT] Alpha: Tidy."),
      conversation: whole)
    let items = try #require(
      menu.items.lazy.compactMap { item -> [MenuContent.Item]? in
        if case .submenu("Conversation", true, let items) = item { items } else { nil }
      }.first)
    let lines = try #require(
      items.lazy.compactMap { if case .transcript(let lines) = $0 { lines } else { nil } }.first)
    #expect(lines == whole.map(TranscriptLine.init))
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
    let sentence = MicrophoneAccess.deniedSentence
    let menu = Self.menu(Self.status(sessions: 1, problem: sentence, unheard: 2))
    let card = try #require(Self.card(menu))
    #expect(card.problem == sentence)
    #expect(card.opensMicrophoneSettings)
    #expect(card.unheard == "2 unheard — speak to hear")
    #expect(card.tint == .problem)
    #expect(card.actionTitle == "Start")
    #expect(card.canAct)
  }

  @Test func withoutABridgeOnlyTheProblemSettingsAndQuitAreLeft() throws {
    let menu = Self.menu(nil, problem: "LiveBridge could not start its bridge: boom")
    #expect(menu.outline == ["[call] Off", "---", "Settings… ⌘,", "Quit LiveBridge ⌘Q"])
    let card = try #require(Self.card(menu))
    #expect(card.problem == "LiveBridge could not start its bridge: boom")
    #expect(card.action == nil)
    #expect(Self.menu(nil).outline.first == "[call] Starting…")
  }

  @Test func onlySettingsAndQuitHaveShortcuts() {
    #expect(MenuContent.Command.settings.keyEquivalent == ",")
    #expect(MenuContent.Command.quit.keyEquivalent == "q")
    for command in [MenuContent.Command.copyJoinCommand, .loadContext, .newConversation] {
      #expect(command.keyEquivalent == "")
    }
  }
}
