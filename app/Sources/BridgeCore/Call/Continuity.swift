import Foundation

/// One item seeding a realtime session (codex `initialItems`).
public struct InitialItem: Codable, Sendable, Equatable {
  public var role: Role
  public var text: String
}

/// Why the voice may lack part of a session: a turn the app did not receive (`missed`), or one
/// the pause setting kept out (`paused`).
public enum OutOfSync: String, Codable, Sendable { case missed, paused }

/// One Claude Code session's conversation with the voice, carried from one realtime session to
/// the next, and across Stop and Start, so the owner does not notice the session was replaced.
public struct Conversation: Codable, Sendable, Equatable {
  public static let keptLines = 64
  /// codex's limits on `initialItems`; tokens are estimated at 4 UTF-8 bytes each, as codex counts.
  public static let maxItems = 128
  public static let maxTokens = 8_192
  /// How long an ask can still be answered: twice what the mod allows a summary, which may never
  /// come (a failure, or a session with nothing to summarise).
  static let askLife = 2 * ContextLoads.timeout

  public struct Line: Codable, Sendable, Equatable {
    /// `claude`: a line the session sent the voice (a result, question, update or approval
    /// notice), as the voice got it, or Claude's final answer to a turn that was not a voice
    /// request (synced, as context). `handoff`: the brief of a request the session's queue took,
    /// so the menu shows that it was handed on. `context`: a loaded summary, as the voice got it,
    /// where it was loaded.
    public enum Speaker: String, Codable, Sendable {
      case owner, voice, claude, handoff, context

      /// How the menu names who said a line.
      public var name: String {
        switch self {
        case .owner: "You"
        case .voice: "Voice"
        case .claude: "Claude"
        case .handoff: "Task"
        case .context: "Loaded context"
        }
      }

      /// The role a line has when it seeds the voice; none for a line that is the menu's only.
      var role: Role? {
        switch self {
        case .voice: .assistant
        case .owner, .claude: .user
        case .handoff, .context: nil
        }
      }
    }
    public var speaker: Speaker
    public var text: String
  }

  public private(set) var lines: [Line] = []
  /// The lines as the menu shows them. A summary no kept line holds is older than them all, or
  /// was loaded by 0.4.0, which kept no place for it, so it goes first.
  public var shownLines: [Line] {
    guard let context, !lines.contains(where: { $0.speaker == .context }) else { return lines }
    return [Line(speaker: .context, text: context)] + lines
  }
  /// The session's `[CONTEXT]` line, as the voice gets it.
  public var context: String?
  /// When the conversation was last used, on `Continuity`'s count.
  var lastUsed = 0
  /// Why the voice may lack part of the session, if it may. Each field below is optional, so a
  /// file saved before they existed still decodes.
  public private(set) var outOfSync: OutOfSync?
  /// Lines with a seed role recorded since the last `setContext`; absent in an older file, where
  /// the lines kept stand in for it.
  private var linesSinceContext: Int?
  /// The decision on the turn whose lines were last offered (`Continuity.admits`).
  var turn: TurnDecision?
  /// The summary asked for and not yet arrived.
  private var summaryAsk: SummaryAsk?
  /// The number the last new ask took; it outlives the ask, so an old number never comes back.
  private var asksMade: Int?

  struct TurnDecision: Codable, Sendable, Equatable {
    var id: String
    var admitted: Bool
  }

  struct SummaryAsk: Codable, Sendable, Equatable {
    var at: Date
    /// A gap or a forget came after the ask, so its summary cannot cover the conversation.
    var isStale = false
    /// The model the ask named and its fallback; nil on an ask to a mod that forks.
    var model: String?
    var fallbackModel: String?
    /// The ask's number in the session, which a current mod's answer echoes; nil in an older file.
    var number: Int?
  }

  public init() {}

  private var seedLinesSinceContext: Int {
    linesSinceContext ?? lines.filter { $0.speaker.role != nil }.count
  }

  /// The voice has everything: a context, no gap, and the seed carries every line since the
  /// summary (lines rolled off, or too many for codex's limits, are lost to it).
  public var isCurrent: Bool { context != nil && outOfSync == nil && !isOverSeed }

  /// The seed no longer carries every line since the summary.
  var isOverSeed: Bool {
    seedLinesSinceContext > initialItems(tasks: []).count - (context == nil ? 0 : 1)
  }

  public mutating func record(_ speaker: Line.Speaker, _ text: String) {
    if speaker.role != nil { linesSinceContext = seedLinesSinceContext + 1 }
    lines = Array((lines + [Line(speaker: speaker, text: text)]).suffix(Self.keptLines))
  }

  mutating func setContext(_ line: String) {
    if line != context { record(.context, line) }
    context = line
    outOfSync = nil
    linesSinceContext = 0
  }

  mutating func markPaused() {
    outOfSync = .paused
    summaryAsk?.isStale = true
  }

  mutating func markMissed(asPaused: Bool) {
    if outOfSync != .paused { outOfSync = asPaused ? .paused : .missed }
    summaryAsk?.isStale = true
  }

  /// A summary was asked for; the ask now open. An ask still open and current stays as it is,
  /// number included: the mod joins a second ask to the summary on its way, which is the first
  /// ask's. A stale one is replaced by a new ask with the next number.
  mutating func noteSummaryAsk(at now: Date, model: String?, fallbackModel: String?) -> SummaryAsk {
    if let open = openAsk(at: now), !open.isStale { return open }
    let number = (asksMade ?? 0) + 1
    asksMade = number
    let ask = SummaryAsk(at: now, model: model, fallbackModel: fallbackModel, number: number)
    summaryAsk = ask
    return ask
  }

  /// A summary arrived and answers the open ask. False: it was asked for before a gap or a forget.
  /// One that carries the number of another ask answers none and leaves the open ask as it is.
  mutating func takeSummaryAsk(at now: Date, number: Int?) -> Bool {
    let open = openAsk(at: now)
    if let number, open?.number != number { return false }
    summaryAsk = nil
    return open?.isStale != true
  }

  /// The open ask; nil when none is open.
  func openSummaryAsk(at now: Date) -> SummaryAsk? { openAsk(at: now) }

  private func openAsk(at now: Date) -> SummaryAsk? {
    summaryAsk.flatMap { now < $0.at + Self.askLife ? $0 : nil }
  }

  /// What forgetting leaves: a pause, the turn's decision, and an ask that can no longer cover
  /// anything.
  var afterForgetting: Conversation? {
    var kept = Conversation()
    kept.lastUsed = lastUsed
    kept.asksMade = asksMade
    kept.turn = turn
    if outOfSync == .paused { kept.outOfSync = .paused }
    kept.summaryAsk = summaryAsk
    kept.summaryAsk?.isStale = true
    return kept.turn == nil && kept.outOfSync == nil && kept.summaryAsk == nil ? nil : kept
  }

  /// The context and the open task lines, then the newest lines that fit codex's limits. Notes
  /// and the session's lines go in as `user` lines, data with the rank of the owner's words and
  /// no more, like every line the app adds while a session is open. A session's line still in
  /// `unheard` is left out: the line is given it again once it opens. A handoff or summary line is
  /// the menu's only, so seeding sends nothing it did not send before; an open request still goes in
  /// as its task line.
  public func initialItems(tasks: [String], unheard: Set<String> = []) -> [InitialItem] {
    let notes = ([context].compactMap { $0 } + tasks).map { InitialItem(role: .user, text: $0) }
    var tokens = notes.reduce(0) { $0 + Self.estimatedTokens($1.text) }
    var talk: [InitialItem] = []
    for line in lines.reversed() where line.speaker != .claude || !unheard.contains(line.text) {
      guard let role = line.speaker.role else { continue }
      tokens += Self.estimatedTokens(line.text)
      guard tokens <= Self.maxTokens, notes.count + talk.count < Self.maxItems else { break }
      talk.insert(InitialItem(role: role, text: line.text), at: 0)
    }
    return notes + talk
  }

  /// codex's own estimate: UTF-8 bytes over 4. Past its limits it refuses the line (ADR 0001 (o)).
  static func estimatedTokens(_ text: String) -> Int { (text.utf8.count + 3) / 4 }
}

/// Every session's conversation, by session id, so the voice never mixes two sessions'. Saved
/// as a map from session id to conversation; only the `keptConversations` used last are kept,
/// as each new Claude Code session comes with a new id.
public struct Continuity: Codable, Sendable, Equatable {
  public static let keptConversations = 20

  private(set) var conversations: [String: Conversation] = [:]

  public init() {}

  /// The session's conversation; an empty one if it has none.
  public subscript(id: SessionID) -> Conversation { conversations[id.rawValue] ?? Conversation() }

  public mutating func record(
    _ speaker: Conversation.Line.Speaker, _ text: String, in id: SessionID
  ) {
    use(id) { $0.record(speaker, text) }
  }

  /// A summary arrived: the voice has the session as of now.
  public mutating func setContext(_ line: String, for id: SessionID) {
    use(id) { $0.setContext(line) }
  }

  /// The app asked `id` for a summary, with `model` and `fallbackModel` if it named them; the ask
  /// now open, whose number the ask carries.
  @discardableResult
  mutating func noteSummaryAsk(
    of id: SessionID, at now: Date, model: String? = nil, fallbackModel: String? = nil
  ) -> Conversation.SummaryAsk {
    use(id) { $0.noteSummaryAsk(at: now, model: model, fallbackModel: fallbackModel) }
  }

  /// The ask of `id` still open at `now`, without taking it.
  func openSummaryAsk(of id: SessionID, at now: Date) -> Conversation.SummaryAsk? {
    self[id].openSummaryAsk(at: now)
  }

  /// A summary from `id` arrived. False: it was asked for before the latest gap or forget, so it
  /// covers less than the conversation lacks and must not be taken. One nobody asked for (an older
  /// mod's `/live context`) cannot be dated, and is taken. `number`: the ask a current mod says it
  /// answers; only the open ask's own number takes it.
  public mutating func takeSummaryAsk(of id: SessionID, at now: Date, number: Int? = nil) -> Bool {
    use(id) { $0.takeSummaryAsk(at: now, number: number) }
  }

  /// Whether a line of `turn` goes in. A turn's first line decides, and later lines keep that
  /// decision, except that a `typed` line while `pausing` refuses the turn from there on. A voice
  /// turn holds nothing of the owner's until then, so only a `typed` line refuses it. A line of
  /// Claude's that opens a turn in a `paused` session stays out: the turn's `start` never arrived,
  /// and its prompt may be the paused text.
  /// `pausing`: the pause setting is on and the call is off. Every refused line marks `paused`.
  public mutating func admits(
    turn: TurnRef, kind: SyncKind, in id: SessionID, pausing: Bool
  ) -> Bool {
    use(id) { conversation in
      let decided = conversation.turn.flatMap { $0.id == turn.id ? $0.admitted : nil }
      let isClaudes = kind == .answer || kind == .report
      let isUnseen = isClaudes && conversation.outOfSync == .paused
      let first = turn.request != nil || !(pausing || isUnseen)
      let admitted = (decided ?? first) && !(kind == .typed && pausing)
      conversation.turn = Conversation.TurnDecision(id: turn.id, admitted: admitted)
      if !admitted { conversation.markPaused() }
      return admitted
    }
  }

  /// A turn of the session did not arrive. `asPaused`: the pause setting is on, so the gap may
  /// hold text meant to stay out. Never replaces `paused`.
  public mutating func markMissed(_ id: SessionID, asPaused: Bool) {
    use(id) { $0.markMissed(asPaused: asPaused) }
  }

  /// "New conversation", or the session was removed from the app. The lines and the context go
  /// and so does a `missed` mark; a `paused` mark and the turn's decision stay.
  public mutating func forget(_ id: SessionID) {
    conversations[id.rawValue] = conversations[id.rawValue]?.afterForgetting
  }

  /// The session got a new id (`/clear`); its conversation goes with it.
  public mutating func move(_ old: SessionID, to new: SessionID) {
    guard let conversation = conversations.removeValue(forKey: old.rawValue) else { return }
    conversations[new.rawValue] = conversation
  }

  @discardableResult
  private mutating func use<Result>(
    _ id: SessionID, _ change: (inout Conversation) -> Result
  ) -> Result {
    var conversation = self[id]
    let result = change(&conversation)
    conversation.lastUsed = (conversations.values.map(\.lastUsed).max() ?? 0) + 1
    conversations[id.rawValue] = conversation
    while conversations.count > Self.keptConversations,
      let oldest = conversations.min(by: { $0.value.lastUsed < $1.value.lastUsed })
    {
      conversations[oldest.key] = nil
    }
    return result
  }
}
