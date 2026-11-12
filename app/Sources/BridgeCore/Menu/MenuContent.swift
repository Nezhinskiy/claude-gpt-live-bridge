import Foundation

/// What the menu bar menu holds for one status, top to bottom, as a plain value: the call card,
/// the sessions, the target's whole conversation, the minutes, an update to install, Quick
/// Settings, Settings, Feedback & Support and Quit. The app renders it
/// into an `NSMenu`, the custom rows as hosted SwiftUI views and the rest as native items, so
/// the menu has the system's own corners, material and shadow. Pure.
public struct MenuContent: Sendable, Equatable {
  /// Session rows in the menu itself; the rest go in a "More sessions" submenu, as a native menu
  /// scrolls only once it reaches the screen's height.
  public static let visibleSessions = 5

  /// What a native item does.
  public enum Command: Sendable, Equatable {
    case copyJoinCommand, loadContext, newConversation, starOnGitHub, settings, quit
    /// Opens the repository's bug report form (`Release.bugReportForm`).
    case reportBug
    /// Opens the project's website (`Release.website`).
    case website
    /// Opens debug mode's folder in the Finder.
    case showDebugFiles
    /// Installs the release announced, this version.
    case installUpdate(AppVersion)

    /// With ⌘, as the system's menus have it; empty for none.
    public var keyEquivalent: String {
      switch self {
      case .settings: ","
      case .quit: "q"
      case .copyJoinCommand, .loadContext, .newConversation, .starOnGitHub, .reportBug, .website,
        .showDebugFiles, .installUpdate:
        ""
      }
    }
  }

  /// A setting the menu shows as a checkmark item: the setting of the same name in Settings, not
  /// a copy.
  public enum Switch: Sendable, Equatable, CaseIterable {
    case connectsOverTCP, confirmHandoffs, notifyResults, pauseSyncWhileStopped,
      loadContextOnFirstCall, debugMode

    /// Quick Settings' switches, in menu order; debug mode is in Feedback & Support.
    public static let quickSettings: [Switch] = [
      .connectsOverTCP, .confirmHandoffs, .notifyResults, .pauseSyncWhileStopped,
      .loadContextOnFirstCall,
    ]

    /// Settings' own words for it.
    public var title: String {
      switch self {
      case .connectsOverTCP: "Connect over TCP"
      case .confirmHandoffs: "Play sounds for requests and answers"
      case .notifyResults: "Notify when a result is waiting"
      case .pauseSyncWhileStopped: "Pause sync while the call is stopped"
      case .loadContextOnFirstCall: "Load a session's context on its first call"
      case .debugMode: "Debug Mode"
      }
    }

    public func isOn(in settings: Settings) -> Bool {
      switch self {
      case .connectsOverTCP: settings.connectsOverTCP
      case .confirmHandoffs: settings.confirmHandoffs
      case .notifyResults: settings.notifyResults
      case .pauseSyncWhileStopped: settings.pauseSyncWhileStopped
      case .loadContextOnFirstCall: settings.loadContextOnFirstCall
      case .debugMode: settings.debugMode
      }
    }
  }

  /// The menu's first item: the call, its button, and a problem with its help.
  public struct CallCard: Sendable, Equatable {
    public let headline: String
    public let detail: String
    public let tint: Tint
    /// What the button does; nil while there is no bridge to ask.
    public let action: CallAction?
    public let canAct: Bool
    /// Mute, or Unmute while muted; nil while the call is off or there is no bridge.
    public let muteAction: CallAction?
    /// "N unheard — speak to hear", when results wait; "N unheard — unmute and speak to hear"
    /// while muted.
    public let unheard: String?
    public let problem: String?
    /// The problem is the microphone's refusal: the card offers to open that setting.
    public let opensMicrophoneSettings: Bool
    /// codex is missing or not signed in: the card explains how, with a command to copy.
    public let codexHelp: CodexHelp?

    public var actionTitle: String? { action.map { $0 == .start ? "Start" : "Stop" } }
    public var muteActionTitle: String? { muteAction.map { $0 == .mute ? "Mute" : "Unmute" } }
  }

  public indirect enum Item: Sendable, Equatable {
    /// A custom view.
    case call(CallCard)
    case separator
    /// A native section header.
    case header(String)
    /// A custom view: click makes the session the target, × removes it.
    case session(SessionRowPresentation)
    /// A disabled native item that only informs.
    case note(String)
    case command(Command, title: String, isEnabled: Bool)
    /// A native checkmark item: the switch, titled by it, checked while on.
    case toggle(Switch, isOn: Bool)
    case submenu(String, isEnabled: Bool, items: [Item])
    /// A custom view: every line of the target's conversation, whole and wrapped, oldest
    /// first; it scrolls inside the menu and opens at the newest.
    case transcript([Conversation.Line])
    /// A source's usage: a row that only informs, its tooltip saying when the windows reset.
    case limit(LimitRow)
  }

  public let items: [Item]

  /// `settings` are the app's, shown in Quick Settings with or without a bridge. `problem` is the
  /// app's own or the bridge's; `update` is nil while there is no bridge. `available` is a newer
  /// release found and not yet installed: the menu offers to install it.
  public init(
    settings: Settings, update: BridgeUpdate?, problem: Problem?, contextLoad: ContextLoadState,
    available: AppVersion?, codexLimits: UsageLimits? = nil, claudeLimits: UsageLimits? = nil,
    now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
  ) {
    let footer = Self.foot(settings: settings, available: available)
    let shown = update.map { StatusPresentation($0.status) }
    let hear =
      update?.status.call == .off
      ? "start and speak" : shown?.isMuted == true ? "unmute and speak" : "speak"
    let card = CallCard(
      headline: shown?.headline ?? (problem == nil ? "Starting…" : "Off"),
      detail: shown?.detail ?? "",
      tint: problem != nil ? .problem : shown?.tint ?? .quiet, action: shown?.action,
      canAct: shown?.canAct ?? false, muteAction: shown?.muteAction,
      unheard: shown.flatMap {
        $0.unheard > 0
          ? "\($0.unheard) unheard — \(hear) to hear" : nil
      },
      problem: problem?.sentence,
      opensMicrophoneSettings: problem?.opensMicrophoneSettings ?? false,
      codexHelp: problem?.help)
    guard let update, let shown else {
      items = [.call(card), .separator] + footer
      return
    }

    var sessions: [Item] = [.header("Sessions")]
    if shown.rows.isEmpty {
      let join = StatusPresentation.joinCommand
      sessions += [
        .note("Run \(join) in a Claude Code session"),
        .command(.copyJoinCommand, title: "Copy \(join)", isEnabled: true),
      ]
    } else {
      sessions += shown.rows.prefix(Self.visibleSessions).map(Item.session)
      let rest = shown.rows.dropFirst(Self.visibleSessions)
      if !rest.isEmpty {
        sessions.append(.submenu("More sessions", isEnabled: true, items: rest.map(Item.session)))
      }
    }

    let target = update.status.sessions.first(where: \.isTarget)?.label
    var talk: [Item] = []
    if !update.conversation.isEmpty {
      if let target { talk.append(.header(target)) }
      talk.append(.transcript(update.conversation))
    }
    let load = target == nil ? contextLoad : contextLoad.shown(update.contextNeed)
    let context: [Item] = [
      .command(.loadContext, title: load.title, isEnabled: target != nil && load.isEnabled),
      .command(.newConversation, title: "New conversation…", isEnabled: target != nil),
      .submenu("Conversation", isEnabled: !talk.isEmpty, items: talk),
    ]

    let limits: [Item] = [("Codex", codexLimits), ("Claude", claudeLimits)].compactMap {
      LimitRow(name: $0.0, limits: $0.1, now: now, calendar: calendar, locale: locale)
        .map(Item.limit)
    }
    items =
      [.call(card), .separator] + sessions + [.separator] + context + [.separator] + limits
      + (limits.isEmpty ? [] : [.separator]) + [.note(Self.minutes(update)), .separator] + footer
  }

  /// The menu's foot, the same with or without a bridge: an update to install, Quick Settings,
  /// Settings, Feedback & Support and Quit.
  private static func foot(settings: Settings, available: AppVersion?) -> [Item] {
    let install: [Item] =
      available.map {
        [.command(.installUpdate($0), title: "Install LiveBridge \($0)…", isEnabled: true)]
      } ?? []
    let quick = Switch.quickSettings.map { Item.toggle($0, isOn: $0.isOn(in: settings)) }
    let support: [Item] = [
      .command(.reportBug, title: "Report a Bug…", isEnabled: true),
      .command(.website, title: "LiveBridge Website", isEnabled: true),
      .command(.starOnGitHub, title: "Star LiveBridge on GitHub", isEnabled: true),
      .separator,
      .toggle(.debugMode, isOn: settings.debugMode),
      .command(.showDebugFiles, title: "Show Debug Files…", isEnabled: true),
    ]
    return install + [
      .submenu("Quick Settings", isEnabled: true, items: quick),
      .command(.settings, title: "Settings…", isEnabled: true),
      .separator,
      .submenu("Feedback & Support", isEnabled: true, items: support),
      .separator,
      .command(.quit, title: "Quit LiveBridge", isEnabled: true),
    ]
  }

  private static func minutes(_ update: BridgeUpdate) -> String {
    let call = Int(update.minutesThisCall.rounded())
    return "\(call) min this call · \(Int(update.status.minutesToday.rounded())) min today"
  }

  /// The menu as plain lines, one per item; a submenu's items follow it, indented. For tests and
  /// logs: "---" is a separator, "#" a section header, "▸" a submenu, "(•)" the target, "|"
  /// a line of the conversation, "[x]" and "[ ]" a switch on and off.
  public var outline: [String] { Self.outline(items, indent: "") }

  private static func outline(_ items: [Item], indent: String) -> [String] {
    items.flatMap { item -> [String] in
      switch item {
      case .call(let card):
        let button = card.actionTitle.map { " · \($0)" + (card.canAct ? "" : " (disabled)") }
        let mute = card.muteActionTitle.map { " · \($0)" }
        return [indent + "[call] \(card.headline)" + (button ?? "") + (mute ?? "")]
      case .separator: return [indent + "---"]
      case .header(let title): return [indent + "# \(title)"]
      case .session(let row):
        return [indent + "\(row.isTarget ? "(•)" : "( )") \(row.label) — \(row.detail)"]
      case .note(let text): return [indent + "\(text) (disabled)"]
      case .command(let command, let title, let isEnabled):
        let key = command.keyEquivalent.isEmpty ? "" : " ⌘" + command.keyEquivalent.uppercased()
        return [indent + title + (isEnabled ? "" : " (disabled)") + key]
      case .toggle(let toggle, let isOn):
        return [indent + (isOn ? "[x] " : "[ ] ") + toggle.title]
      case .submenu(let title, let isEnabled, let items):
        guard isEnabled else { return [indent + "\(title) (disabled)"] }
        return [indent + "\(title) ▸"] + outline(items, indent: indent + "  ")
      case .transcript(let lines):
        return [indent + "[transcript]"]
          + lines.map { indent + "| \($0.speaker.name): \($0.text)" }
      case .limit(let row): return [indent + "[limit] \(row.name) — \(row.text)"]
      }
    }
  }
}
