/// What the menu bar menu holds for one status, top to bottom, as a plain value: the call card,
/// the sessions, the target's conversation, the minutes, Settings and Quit. The app renders it
/// into an `NSMenu`, the custom rows as hosted SwiftUI views and the rest as native items, so
/// the menu has the system's own corners, material and shadow. Pure.
public struct MenuContent: Sendable, Equatable {
  /// Session rows in the menu itself; the rest go in a "More sessions" submenu, as a native menu
  /// scrolls only once it reaches the screen's height.
  public static let visibleSessions = 5
  /// What was sent is cut to this many characters, so the submenu stays a readable size.
  public static let sentCharacters = 600

  /// What a native item does.
  public enum Command: Sendable, Equatable {
    case copyJoinCommand, loadContext, newConversation, settings, quit

    /// With ⌘, as the system's menus have it; empty for none.
    public var keyEquivalent: String {
      switch self {
      case .settings: ","
      case .quit: "q"
      case .copyJoinCommand, .loadContext, .newConversation: ""
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
    /// "N unheard — speak to hear", when results wait.
    public let unheard: String?
    public let problem: String?
    /// The problem is the microphone's refusal: the card offers to open that setting.
    public let opensMicrophoneSettings: Bool
    /// codex is missing or not signed in: the card explains how, with a command to copy.
    public let codexHelp: CodexHelp?

    public var actionTitle: String? { action.map { $0 == .start ? "Start" : "Stop" } }
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
    case submenu(String, isEnabled: Bool, items: [Item])
    /// A custom view, wrapped.
    case line(TranscriptLine)
    /// The target's context line as it was sent: a custom view, wrapped.
    case sent(String)
  }

  public let items: [Item]

  /// `problem` is the app's own or the status's; `status` is nil while there is no bridge.
  public init(status: StatusReply?, problem: String?, contextLoad: ContextLoadState) {
    let footer: [Item] = [
      .command(.settings, title: "Settings…", isEnabled: true),
      .command(.quit, title: "Quit LiveBridge", isEnabled: true),
    ]
    guard let status else {
      let card = CallCard(
        headline: problem == nil ? "Starting…" : "Off", detail: "",
        tint: problem == nil ? .quiet : .problem, action: nil, canAct: false, unheard: nil,
        problem: problem, opensMicrophoneSettings: problem == MicrophoneAccess.deniedSentence,
        codexHelp: CodexHelp.for(problem: problem))
      items = [.call(card), .separator] + footer
      return
    }
    let shown = StatusPresentation(status)
    let card = CallCard(
      headline: shown.headline, detail: shown.detail,
      tint: problem != nil ? .problem : shown.tint, action: shown.action,
      canAct: shown.canAct,
      unheard: shown.unheard > 0 ? "\(shown.unheard) unheard — speak to hear" : nil,
      problem: problem, opensMicrophoneSettings: problem == MicrophoneAccess.deniedSentence,
      codexHelp: CodexHelp.for(problem: problem))

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

    let target = status.sessions.first(where: \.isTarget)?.label
    var conversation: [Item] = []
    if !status.recentTranscript.isEmpty {
      conversation.append(.header(target.map { "Last lines with \($0)" } ?? "Last lines"))
      conversation += status.recentTranscript.map { .line(TranscriptLine($0)) }
    }
    if let sent = status.lastContext {
      if !conversation.isEmpty { conversation.append(.separator) }
      conversation += [.header("What was sent"), .sent(Self.capped(sent))]
    }
    let context: [Item] = [
      .command(
        .loadContext, title: contextLoad.title, isEnabled: target != nil && contextLoad.isEnabled
      ),
      .command(.newConversation, title: "New conversation…", isEnabled: target != nil),
      .submenu("Conversation", isEnabled: !conversation.isEmpty, items: conversation),
    ]

    items =
      [.call(card), .separator] + sessions + [.separator] + context
      + [.separator, .note(shown.minutes), .separator] + footer
  }

  private static func capped(_ text: String) -> String {
    text.count <= sentCharacters ? text : text.prefix(sentCharacters - 1) + "…"
  }

  /// The menu as plain lines, one per item; a submenu's items follow it, indented. For tests and
  /// logs: "---" is a separator, "#" a section header, "▸" a submenu, "(•)" the target.
  public var outline: [String] { Self.outline(items, indent: "") }

  private static func outline(_ items: [Item], indent: String) -> [String] {
    items.flatMap { item -> [String] in
      switch item {
      case .call(let card):
        let button = card.actionTitle.map { " · \($0)" + (card.canAct ? "" : " (disabled)") }
        return [indent + "[call] \(card.headline)" + (button ?? "")]
      case .separator: return [indent + "---"]
      case .header(let title): return [indent + "# \(title)"]
      case .session(let row):
        return [indent + "\(row.isTarget ? "(•)" : "( )") \(row.label) — \(row.detail)"]
      case .note(let text): return [indent + "\(text) (disabled)"]
      case .command(let command, let title, let isEnabled):
        let key = command.keyEquivalent.isEmpty ? "" : " ⌘" + command.keyEquivalent.uppercased()
        return [indent + title + (isEnabled ? "" : " (disabled)") + key]
      case .submenu(let title, let isEnabled, let items):
        guard isEnabled else { return [indent + "\(title) (disabled)"] }
        return [indent + "\(title) ▸"] + outline(items, indent: indent + "  ")
      case .line(let line):
        return [indent + "[line] " + (line.speaker.isEmpty ? "" : "\(line.speaker): ") + line.text]
      case .sent(let text): return [indent + "[sent] \(text)"]
      }
    }
  }
}
