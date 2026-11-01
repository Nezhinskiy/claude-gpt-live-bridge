/// One item seeding a realtime session (codex `initialItems`).
public struct InitialItem: Codable, Sendable, Equatable {
  public var role: Role
  public var text: String
}

/// One Claude Code session's conversation with the voice, carried from one realtime session to
/// the next, and across Stop and Start, so the owner does not notice the session was replaced.
public struct Conversation: Codable, Sendable, Equatable {
  public static let keptLines = 24
  /// codex's limits on `initialItems`; tokens are estimated at 4 characters each.
  public static let maxItems = 128
  public static let maxTokens = 8_192

  public struct Line: Codable, Sendable, Equatable {
    /// `claude`: a line the session sent the voice (a result, question, update or approval
    /// notice), as the voice got it.
    public enum Speaker: String, Codable, Sendable { case owner, voice, claude }
    public var speaker: Speaker
    public var text: String
  }

  public private(set) var lines: [Line] = []
  /// The session's `[CONTEXT]` line, as the voice gets it.
  public var context: String?
  /// When the conversation was last used, on `Continuity`'s count.
  var lastUsed = 0

  public init() {}

  public mutating func record(_ speaker: Line.Speaker, _ text: String) {
    lines = Array((lines + [Line(speaker: speaker, text: text)]).suffix(Self.keptLines))
  }

  /// The context and the open task lines, then the newest lines that fit codex's limits. Notes
  /// and the session's lines go in as `user` lines, data with the rank of the owner's words and
  /// no more, like every line the app adds while a session is open. A session's line still in
  /// `unheard` is left out: the line is given it again once it opens.
  public func initialItems(tasks: [String], unheard: Set<String> = []) -> [InitialItem] {
    let notes = ([context].compactMap { $0 } + tasks).map { InitialItem(role: .user, text: $0) }
    var tokens = notes.reduce(0) { $0 + Self.estimatedTokens($1.text) }
    var talk: [InitialItem] = []
    for line in lines.reversed() where line.speaker != .claude || !unheard.contains(line.text) {
      tokens += Self.estimatedTokens(line.text)
      guard tokens <= Self.maxTokens, notes.count + talk.count < Self.maxItems else { break }
      talk.insert(
        InitialItem(role: line.speaker == .voice ? .assistant : .user, text: line.text), at: 0)
    }
    return notes + talk
  }

  static func estimatedTokens(_ text: String) -> Int { (text.count + 3) / 4 }
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

  public mutating func setContext(_ line: String, for id: SessionID) {
    use(id) { $0.context = line }
  }

  /// "New conversation", or the session was removed from the app.
  public mutating func forget(_ id: SessionID) { conversations[id.rawValue] = nil }

  /// The session got a new id (`/clear`); its conversation goes with it.
  public mutating func move(_ old: SessionID, to new: SessionID) {
    guard let conversation = conversations.removeValue(forKey: old.rawValue) else { return }
    conversations[new.rawValue] = conversation
  }

  private mutating func use(_ id: SessionID, _ change: (inout Conversation) -> Void) {
    var conversation = self[id]
    change(&conversation)
    conversation.lastUsed = (conversations.values.map(\.lastUsed).max() ?? 0) + 1
    conversations[id.rawValue] = conversation
    while conversations.count > Self.keptConversations,
      let oldest = conversations.min(by: { $0.value.lastUsed < $1.value.lastUsed })
    {
      conversations[oldest.key] = nil
    }
  }
}
