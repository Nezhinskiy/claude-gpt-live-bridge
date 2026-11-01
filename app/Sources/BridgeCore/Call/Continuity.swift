/// One item seeding a realtime session (codex `initialItems`).
public struct InitialItem: Codable, Sendable, Equatable {
  public var role: Role
  public var text: String
}

/// The conversation carried from one realtime session to the next, and across Stop and Start,
/// so the owner does not notice the session was replaced. "New conversation" starts a new one.
public struct Continuity: Codable, Sendable, Equatable {
  public static let keptUtterances = 24
  /// codex's limits on `initialItems`; tokens are estimated at 4 characters each.
  public static let maxItems = 128
  public static let maxTokens = 8_192

  public private(set) var utterances: [Utterance] = []
  public private(set) var context: String?

  public init() {}

  public mutating func record(_ utterance: Utterance) {
    utterances = Array((utterances + [utterance]).suffix(Self.keptUtterances))
  }

  /// The session's context summary, or `nil` once it is no longer loaded.
  public mutating func setContext(_ summary: String?) { context = summary }

  /// The loaded context and the open task lines, then the newest utterances that fit codex's
  /// limits. Notes go in as `user` lines, data with the rank of the owner's words and no more,
  /// like every line the app adds while a session is open.
  public func initialItems(tasks: [String]) -> [InitialItem] {
    let notes = ([context].compactMap { $0 } + tasks).map { InitialItem(role: .user, text: $0) }
    var tokens = notes.reduce(0) { $0 + Self.estimatedTokens($1.text) }
    var talk: [InitialItem] = []
    for utterance in utterances.reversed() {
      tokens += Self.estimatedTokens(utterance.text)
      guard tokens <= Self.maxTokens, notes.count + talk.count < Self.maxItems else { break }
      talk.insert(InitialItem(role: utterance.role, text: utterance.text), at: 0)
    }
    return notes + talk
  }

  static func estimatedTokens(_ text: String) -> Int { (text.count + 3) / 4 }
}
