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
    lines: [Conversation.Line] = [], unheard: Int = 0,
    muted: Bool = false, needsContext: Bool = true
  ) -> BridgeUpdate {
    BridgeUpdate(
      status: StatusReply(
        call: call,
        sessions: (0..<count).map {
          SessionRow(
            sessionId: id($0), label: "Session \($0)", activity: $0 == 1 ? .working : .idle,
            isTarget: $0 == target)
        },
        minutesToday: 31.4, problem: problem?.sentence, unheard: unheard, isMuted: muted),
      problem: problem, minutesThisCall: 4.2, conversation: lines,
      labelsOnAnOlderMod: [], contextNeed: needsContext ? .load : .none)
  }

  static func menu(
    _ update: BridgeUpdate?, problem: Problem? = nil, load: ContextLoadState = .ready,
    available: AppVersion? = nil, settings: Settings = Settings()
  ) -> MenuContent {
    MenuContent(
      settings: settings, update: update, problem: problem ?? update?.problem, contextLoad: load,
      available: available)
  }

  static func line(_ speaker: Conversation.Line.Speaker, _ text: String) -> Conversation.Line {
    Conversation.Line(speaker: speaker, text: text)
  }

  @Test func loadContextIsDisabledWhileCurrent() {
    let outline = Self.menu(Self.status(sessions: 1, needsContext: false)).outline
    #expect(outline.contains("Context up to date (disabled)"))
    #expect(!outline.contains("Load context"))
  }

  /// Nothing lost, and the next line loads a summary by itself: nothing to press.
  @Test func loadContextIsDisabledWhenTheLineLoadsIt() {
    let waiting = Self.status(sessions: 1).with(contextNeed: .withTheLine)
    let outline = Self.menu(waiting).outline
    #expect(outline.contains("Context loads with the line (disabled)"))
    #expect(!outline.contains("Load context"))
  }

  /// Out of sync (missed or paused), or a summary only a press can load: the update says so.
  @Test func loadContextIsEnabledOutOfSync() {
    let outline = Self.menu(Self.status(sessions: 1, needsContext: true)).outline
    #expect(outline.contains("Load context"))
  }

  /// A summary that just arrived says so for its 3 s, though the session is current by then.
  @Test func loadedOutranksUpToDate() {
    let current = Self.status(sessions: 1, needsContext: false)
    #expect(
      Self.menu(current, load: .loaded).outline.contains("Context loaded (disabled)"))
    #expect(
      Self.menu(current, load: .loading).outline.contains("Loading context… (disabled)"))
  }

  @Test func withNoSessionsItOffersTheJoinCommand() {
    #expect(
      Self.menu(Self.status(sessions: 0, needsContext: false)).outline == [
        "[call] Off · Start (disabled)",
        "---",
        "# Sessions",
        "Run /live in a Claude Code session (disabled)",
        "Copy /live",
        "---",
        "Load context (disabled)",
        "New conversation… (disabled)",
        "Conversation (disabled)",
        "---",
        "4 min this call · 31 min today (disabled)",
        "---",
        "Quick Settings ▸",
        "  [ ] Connect over TCP",
        "  [x] Play sounds for requests and answers",
        "  [x] Notify when a result is waiting",
        "  [ ] Pause sync while the call is stopped",
        "  [x] Load a session's context on its first call",
        "Settings… ⌘,",
        "---",
        "Feedback & Support ▸",
        "  Report a Bug…",
        "  LiveBridge Website",
        "  Star LiveBridge on GitHub",
        "  ---",
        "  [ ] Debug Mode",
        "  Show Debug Files…",
        "  ---",
        "  Uninstall LiveBridge…",
        "---",
        "Quit LiveBridge ⌘Q",
      ])
  }

  /// The card of a muted call with two results unheard.
  static func mutedCard() -> MenuContent.CallCard? {
    let menu = Self.menu(Self.status(.listening, sessions: 1, unheard: 2, muted: true))
    guard case .call(let card) = menu.items.first else { return nil }
    return card
  }

  @Test func aMutedCardOffersUnmute() {
    #expect(Self.mutedCard()?.muteActionTitle == "Unmute")
  }

  @Test func aMutedCardSaysUnmuteToHear() {
    #expect(Self.mutedCard()?.unheard == "2 unheard — unmute and speak to hear")
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
        "[call] Live · Stop · Mute",
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
        "Quick Settings ▸",
        "  [ ] Connect over TCP",
        "  [x] Play sounds for requests and answers",
        "  [x] Notify when a result is waiting",
        "  [ ] Pause sync while the call is stopped",
        "  [x] Load a session's context on its first call",
        "Settings… ⌘,",
        "---",
        "Feedback & Support ▸",
        "  Report a Bug…",
        "  LiveBridge Website",
        "  Star LiveBridge on GitHub",
        "  ---",
        "  [ ] Debug Mode",
        "  Show Debug Files…",
        "  ---",
        "  Uninstall LiveBridge…",
        "---",
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
    let menu = Self.menu(Self.status(sessions: 1, lines: whole))
    let items = try #require(
      menu.items.lazy.compactMap { item -> [MenuContent.Item]? in
        if case .submenu("Conversation", true, let items) = item { items } else { nil }
      }.first)
    let lines = try #require(
      items.lazy.compactMap { if case .transcript(let lines) = $0 { lines } else { nil } }.first)
    #expect(lines == whole)
    #expect(lines.last?.text == long)
    #expect(items.filter { if case .transcript = $0 { true } else { false } }.count == 1)
  }

  /// Nothing said yet, but a summary was loaded: there is still something to open.
  @Test func aSummaryAloneOpensTheConversationSubmenu() {
    let menu = Self.menu(
      Self.status(sessions: 1, lines: [Self.line(.context, "[CONTEXT] Alpha: Tidy.")]))
    #expect(
      menu.items.contains {
        if case .submenu("Conversation", true, _) = $0 { true } else { false }
      })
  }

  @Test func theCardCarriesTheProblemAndItsHelp() throws {
    let problem = Problem.microphoneDenied
    let menu = Self.menu(Self.status(sessions: 1, problem: problem, unheard: 2))
    let card = try #require(Self.card(menu))
    #expect(card.problem == problem.sentence)
    #expect(card.opensMicrophoneSettings && card.codexHelp == nil)
    let signIn = try #require(Self.card(Self.menu(nil, problem: .codex(.notLoggedIn))))
    #expect(signIn.codexHelp == .signIn && !signIn.opensMicrophoneSettings)
    #expect(card.unheard == "2 unheard — start and speak to hear")
    #expect(card.tint == .problem)
    #expect(card.actionTitle == "Start")
    #expect(card.canAct)
  }

  @Test func withoutABridgeOnlyTheProblemAndTheFooterAreLeft() throws {
    let menu = Self.menu(nil, problem: .other("LiveBridge could not start its bridge: boom"))
    #expect(
      menu.outline.filter { !$0.hasPrefix(" ") } == [
        "[call] Off", "---", "Quick Settings ▸", "Settings… ⌘,", "---", "Feedback & Support ▸",
        "---", "Quit LiveBridge ⌘Q",
      ])
    let card = try #require(Self.card(menu))
    #expect(card.problem == "LiveBridge could not start its bridge: boom")
    #expect(card.action == nil)
    #expect(Self.menu(nil).outline.first == "[call] Starting…")
  }

  /// The menu's own lines, a submenu's items left out.
  static func topLevel(_ menu: MenuContent) -> [String] {
    menu.outline.filter { !$0.hasPrefix(" ") }
  }

  /// The items of the submenu titled `title`, nil if the menu has none.
  static func submenu(_ title: String, in menu: MenuContent) -> [MenuContent.Item]? {
    menu.items.lazy.compactMap { item -> [MenuContent.Item]? in
      if case .submenu(title, _, let items) = item { items } else { nil }
    }.first
  }

  static func switches(_ settings: Settings) -> [Bool]? {
    submenu("Quick Settings", in: menu(status(sessions: 1), settings: settings))?.compactMap {
      if case .toggle(_, let isOn) = $0 { isOn } else { nil }
    }
  }

  @Test func theFootIsQuickSettingsSettingsFeedbackAndQuit() throws {
    let foot = [
      "Quick Settings ▸", "Settings… ⌘,", "---", "Feedback & Support ▸", "---",
      "Quit LiveBridge ⌘Q",
    ]
    let lines = Self.topLevel(Self.menu(Self.status(sessions: 1)))
    #expect(Array(lines.suffix(foot.count)) == foot)
    let minutes = try #require(lines.firstIndex(of: "4 min this call · 31 min today (disabled)"))
    #expect(lines[minutes + 1] == "---" && lines[minutes + 2] == "Quick Settings ▸")
    #expect(!lines.contains("Star LiveBridge on GitHub"))
    let offered = Self.topLevel(
      Self.menu(Self.status(sessions: 1), available: AppVersion("0.1.3")))
    #expect(Array(offered.suffix(foot.count + 1)) == ["Install LiveBridge 0.1.3…"] + foot)
  }

  @Test func quickSettingsShowEachSwitchAsSet() throws {
    let items = try #require(
      Self.submenu(
        "Quick Settings",
        in: Self.menu(
          Self.status(sessions: 1),
          settings: Settings(pauseSyncWhileStopped: true, connectsOverTCP: true))))
    #expect(items == MenuContent.Switch.quickSettings.map { .toggle($0, isOn: true) })
    // Each switch follows its own setting: flipping one flips only its item.
    let flips: [MenuContent.Switch: Settings] = [
      .connectsOverTCP: Settings(connectsOverTCP: true),
      .confirmHandoffs: Settings(confirmHandoffs: false),
      .notifyResults: Settings(notifyResults: false),
      .pauseSyncWhileStopped: Settings(pauseSyncWhileStopped: true),
      .loadContextOnFirstCall: Settings(loadContextOnFirstCall: false),
    ]
    let defaults = [false, true, true, false, true]
    for (index, flipped) in MenuContent.Switch.quickSettings.enumerated() {
      var expected = defaults
      expected[index].toggle()
      #expect(Self.switches(try #require(flips[flipped])) == expected, "\(flipped)")
    }
  }

  /// The links, then debug mode as set and its files; Quick Settings does not repeat it.
  @Test func feedbackAndSupportEndsWithUninstall() throws {
    for on in [false, true] {
      let menu = Self.menu(Self.status(sessions: 1), settings: Settings(debugMode: on))
      #expect(
        Self.submenu("Feedback & Support", in: menu) == [
          .command(.reportBug, title: "Report a Bug…", isEnabled: true),
          .command(.website, title: "LiveBridge Website", isEnabled: true),
          .command(.starOnGitHub, title: "Star LiveBridge on GitHub", isEnabled: true),
          .separator,
          .toggle(.debugMode, isOn: on),
          .command(.showDebugFiles, title: "Show Debug Files…", isEnabled: true),
          .separator,
          .command(.uninstall, title: "Uninstall LiveBridge…", isEnabled: true),
        ])
      let quick = try #require(Self.submenu("Quick Settings", in: menu))
      #expect(quick.count == 5 && !quick.contains(.toggle(.debugMode, isOn: on)))
    }
    #expect(MenuContent.Switch.debugMode.title == "Debug Mode")
  }

  @Test func withoutABridgeQuickSettingsAreStillThere() throws {
    let settings = Settings(connectsOverTCP: true)
    let bridged = try #require(
      Self.submenu("Quick Settings", in: Self.menu(Self.status(sessions: 1), settings: settings)))
    #expect(Self.submenu("Quick Settings", in: Self.menu(nil, settings: settings)) == bridged)
  }
}

struct LimitRowTests {
  static var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }
  static let gb = Locale(identifier: "en_GB")

  /// A UTC time in November 2026; the 6th is a Friday.
  static func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
    utc.date(
      from: DateComponents(
        year: 2026, month: 11, day: day, hour: hour, minute: minute))!
  }

  static let now = at(6, 5, 8)
  static let reset = at(6, 6, 4)
  static let weekReset = at(11, 8, 1)  // a Wednesday

  static func limits(
    five: Double? = 7, week: Double? = 19, blocked: Bool = false, readAt: Date = now
  ) -> UsageLimits {
    UsageLimits(
      windows: [
        five.map { LimitWindow(span: .minutes(300), usedPercent: $0, resetsAt: reset) },
        week.map { LimitWindow(span: .minutes(10080), usedPercent: $0, resetsAt: weekReset) },
      ].compactMap { $0 },
      isBlocked: blocked, readAt: readAt)
  }

  static func row(
    _ limits: UsageLimits?, name: String = "Codex", locale: Locale = gb
  ) -> LimitRow? {
    LimitRow(name: name, limits: limits, now: now, calendar: utc, locale: locale)
  }

  @Test func aRowShowsBothWindows() {
    #expect(Self.row(Self.limits())?.text == "7% of 5 h · 19% of week")
  }

  @Test func theRunsAreTheTextInOrder() {
    let row = Self.row(Self.limits(five: 95, blocked: true))
    #expect(
      row?.runs.map(\.text) == ["95% of 5 h", " · ", "19% of week", " · ", "blocked"])
    #expect(row?.runs.map(\.isNear) == [true, false, false, false, false])
    #expect(row?.runs.map(\.text).joined() == row?.text)
    #expect(
      Self.row(Self.limits(five: nil, week: nil, blocked: true))?.runs.map(\.text) == ["blocked"])
  }

  @Test func percentsAreRounded() {
    #expect(Self.row(Self.limits(five: 7.5))?.runs.first?.text == "8% of 5 h")
  }

  @Test func anAbsurdPercentDoesNotCrash() {
    let row = Self.row(Self.limits(five: 1e300, week: -5))
    #expect(row?.text == "100% of 5 h · 0% of week")
  }

  @Test func aNonFinitePercentIsZero() {
    // Built directly: the wire refuses these, but the row must not trap on them.
    let row = Self.row(Self.limits(five: .nan, week: .infinity))
    #expect(row?.text == "0% of 5 h · 0% of week")
  }

  @Test func aMissingWindowIsLeftOut() {
    #expect(Self.row(Self.limits(five: nil))?.text == "19% of week")
  }

  @Test func noWindowAndNoBlockIsNoRow() {
    #expect(Self.row(Self.limits(five: nil, week: nil)) == nil)
    #expect(Self.row(nil) == nil)
  }

  @Test func aWindowPastItsResetIsLeftOut() {
    let stale = UsageLimits(
      windows: [
        LimitWindow(span: .minutes(300), usedPercent: 50, resetsAt: Self.now - 60),
        LimitWindow(span: .minutes(10080), usedPercent: 19, resetsAt: Self.weekReset),
      ], readAt: Self.now - 3600)
    #expect(Self.row(stale)?.text == "19% of week")
  }

  @Test func aFigureShowingNinetyIsNear() {
    let below = Self.row(Self.limits(five: 89.4, week: 89.5))
    #expect(below?.runs.map(\.isNear) == [false, false, true])
    #expect(below?.runs.last?.text == "90% of week")
  }

  @Test func aBlockWithNoWindowStillShows() {
    let row = Self.row(Self.limits(five: nil, week: nil, blocked: true))
    #expect(row?.isBlocked == true)
    #expect(row?.runs.map(\.text) == ["blocked"])
    #expect(row?.text == "blocked")
  }

  @Test func aBlockFollowsTheFigures() {
    #expect(
      Self.row(Self.limits(blocked: true))?.text == "7% of 5 h · 19% of week · blocked")
  }

  @Test func theTooltipSaysWhenEachWindowResets() {
    #expect(
      Self.row(Self.limits())?.tooltip
        == "5-hour window resets at 06:04\nWeekly window resets Wed 08:01\nRead at 05:08")
  }

  @Test func timesFollowTheLocale() {
    let tooltip = Self.row(Self.limits(), locale: Locale(identifier: "en_US"))?.tooltip ?? ""
    #expect(tooltip.contains("resets at 6:04"))
    #expect(tooltip.contains("resets Wed 8:01"))
    #expect(tooltip.contains("AM"))
  }

  @Test func anOldReadingSaysItsDay() {
    let row = Self.row(Self.limits(readAt: Self.at(2, 5, 8)))
    #expect(row?.tooltip.hasSuffix("Read at Mon 05:08") == true)
  }

  @Test func aFarDateShowsTheDate() {
    func tooltip(reset: Date, readAt: Date) -> String? {
      let limits = UsageLimits(
        windows: [LimitWindow(span: .minutes(43200), usedPercent: 6, resetsAt: reset)],
        readAt: readAt)
      return Self.row(limits)?.tooltip
    }
    let october = Self.utc.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 5))!
    // Six days either way keeps the weekday.
    #expect(
      tooltip(reset: Self.at(12, 8, 1), readAt: Self.at(1, 5, 8))
        == "30-day window resets Thu 08:01\nRead at Sun 05:08")
    // Seven days either way shows the date.
    #expect(
      tooltip(reset: Self.at(13, 8, 1), readAt: october)
        == "30-day window resets 13 Nov at 08:01\nRead at 30 Oct at 05:00")
  }

  @Test func aBlockedTooltipOpensWithTheBlock() {
    let row = Self.row(Self.limits(blocked: true))
    #expect(
      row?.tooltip.components(separatedBy: "\n").first
        == "Codex reports usage is blocked right now.")
  }

  @Test func aWindowWithNoResetHasNoResetLine() {
    let limits = UsageLimits(
      windows: [LimitWindow(span: .minutes(300), usedPercent: 7, resetsAt: nil)],
      readAt: Self.now)
    #expect(Self.row(limits)?.tooltip == "Read at 05:08")
  }

  @Test func aWindowOfAnotherLengthShowsByItsLength() {
    let limits = UsageLimits(
      windows: [LimitWindow(span: .minutes(240), usedPercent: 22, resetsAt: Self.reset)],
      readAt: Self.now)
    let row = Self.row(limits)
    #expect(row?.text == "22% of 4 h")
    #expect(row?.tooltip.hasPrefix("4-hour window resets at 06:04") == true)
  }

  @Test func aWindowWithNoLengthIsTheLimit() {
    let limits = UsageLimits(
      windows: [LimitWindow(span: .unknown, usedPercent: 22, resetsAt: Self.reset)],
      readAt: Self.now)
    let row = Self.row(limits)
    #expect(row?.text == "22% of limit")
    #expect(row?.tooltip.hasPrefix("Limit resets at 06:04") == true)
  }

  @Test func theMenuHoldsTheRowsAboveTheMinutes() {
    let menu = MenuContent(
      settings: Settings(), update: MenuContentTests.status(sessions: 0), problem: nil,
      contextLoad: .ready, available: nil, codexLimits: Self.limits(),
      claudeLimits: Self.limits(five: nil, week: nil, blocked: true),
      now: Self.now, calendar: Self.utc, locale: Self.gb)
    let lines = menu.outline
    let at = lines.firstIndex(of: "[limit] Codex — 7% of 5 h · 19% of week")
    #expect(at != nil)
    guard let at else { return }
    #expect(lines[at + 1] == "[limit] Claude — blocked")
    #expect(lines[at + 2] == "---")
    #expect(lines[at + 3] == "4 min this call · 31 min today (disabled)")
    #expect(lines[at - 1] == "---")
  }

  @Test func withNoRowsTheSectionIsNotThere() {
    let lines = MenuContentTests.menu(MenuContentTests.status(sessions: 0)).outline
    #expect(!lines.contains { $0.hasPrefix("[limit]") })
    let minutes = lines.firstIndex(of: "4 min this call · 31 min today (disabled)")
    #expect(minutes.map { lines[$0 - 1] } == "---")
    #expect(minutes.map { lines[$0 - 2] } == "Conversation (disabled)")
  }
}
