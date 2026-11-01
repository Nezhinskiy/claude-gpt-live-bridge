// The JSON messages between the mod and the app: `POST /v1/join|leave|answer|activity|context|
// target|call` with the bodies below, and `GET /v1/next?sessionId=` answering a `PollReply`.
// `wire/fixtures` holds an example of each and `plugin/hooks/wire.ts` mirrors these types; a
// change here changes both. Optional fields are omitted when absent, never `null`.

/// A Claude Code session id, as the mod's `$.session.id()` returns it.
public struct SessionID: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

/// The id the app gives a voice request; the answer quotes it.
public struct RequestID: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public enum Role: String, Codable, Sendable { case user, assistant }

/// One final line of speech.
public struct Utterance: Codable, Sendable, Equatable {
  public var role: Role
  public var text: String
}

/// A request the voice hands to a session.
public struct VoiceRequest: Codable, Sendable, Equatable {
  public var id: RequestID
  /// The voice model's self-contained request (codex `input_transcript`).
  public var brief: String
  /// The recognised speech since the previous handoff (codex `active_transcript`).
  public var transcript: [Utterance]
}

/// Work for a session, tagged by `kind`: `{"kind":"request", <VoiceRequest>}` or
/// `{"kind":"context"}` (summarise the session for the voice).
public enum Work: Sendable, Equatable {
  case request(VoiceRequest)
  case context
}

extension Work: Codable {
  private enum Kind: String, Codable { case request, context }
  private enum CodingKeys: String, CodingKey { case kind }

  public init(from decoder: any Decoder) throws {
    switch try decoder.container(keyedBy: CodingKeys.self).decode(Kind.self, forKey: .kind) {
    case .request: self = .request(try VoiceRequest(from: decoder))
    case .context: self = .context
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .request(let request):
      try container.encode(Kind.request, forKey: .kind)
      try request.encode(to: encoder)
    case .context:
      try container.encode(Kind.context, forKey: .kind)
    }
  }
}

/// `POST /v1/join`: an upsert. Joining again renames the session and refreshes its liveness.
public struct JoinBody: Codable, Sendable, Equatable {
  public var sessionId: SessionID
  public var title: String
  /// The id the session had before `/clear`: its place, target and requests move to the new id.
  public var replaces: SessionID?
}

/// `POST /v1/leave`.
public struct LeaveBody: Codable, Sendable, Equatable { public var sessionId: SessionID }

/// `POST /v1/target`: make this session the one the voice hands requests to.
public struct TargetBody: Codable, Sendable, Equatable { public var sessionId: SessionID }

public enum AnswerStatus: String, Codable, Sendable {
  /// `ok`, `failed` and `question` close the request; `update` is a later result tied to the
  /// session's last voice request and closes nothing.
  case ok, failed, question, update
}

/// `POST /v1/answer`: the session's reply to request `id`.
public struct AnswerBody: Codable, Sendable, Equatable {
  public var sessionId: SessionID
  public var id: RequestID
  public var status: AnswerStatus
  public var text: String
  public var reason: String?
}

public enum SessionActivity: String, Codable, Sendable { case idle, working, approval }

/// `POST /v1/activity`.
public struct ActivityBody: Codable, Sendable, Equatable {
  public var sessionId: SessionID
  public var state: SessionActivity
}

/// `POST /v1/context`: the session's own summary, sent in reply to `Work.context`.
public struct ContextBody: Codable, Sendable, Equatable {
  public var sessionId: SessionID
  public var summary: String
}

public enum CallAction: String, Codable, Sendable { case start, stop }

/// `POST /v1/call`: Start or Stop from the Claude Code band.
public struct CallBody: Codable, Sendable, Equatable { public var action: CallAction }

/// `off`: no microphone. `listening`: microphone and local voice detection only, no realtime
/// session. `connecting`, then `live`: a realtime session is open.
public enum CallPhase: String, Codable, Sendable { case off, listening, connecting, live }

public struct SessionRow: Codable, Sendable, Equatable {
  public var sessionId: SessionID
  /// The session title, with a short id suffix when two titles are the same.
  public var label: String
  public var activity: SessionActivity
  public var isTarget: Bool
}

/// What the band and the popover show.
public struct StatusReply: Codable, Sendable, Equatable {
  public var call: CallPhase
  public var sessions: [SessionRow]
  public var minutesToday: Double
  public var minutesThisCall: Double
  /// One sentence on why the call cannot start or just stopped.
  public var problem: String?
  /// The target session's `[CONTEXT]` line, exactly as the voice gets it; kept across restarts.
  public var lastContext: String?
  /// The last three lines of the target session's conversation.
  public var recentTranscript: [String]
  /// Results the voice has not said yet: waiting for the owner to speak, or given to the open
  /// session.
  public var unheard: Int
}

/// The reply to `GET /v1/next`. Each poll also refreshes the session's liveness.
public struct PollReply: Codable, Sendable, Equatable {
  public var status: StatusReply
  public var work: Work?
}

/// What a non-2xx reply asks of the mod, beyond its HTTP status.
public enum ErrorCode: String, Codable, Sendable {
  /// `410`: the owner removed this session; the mod turns itself off instead of joining again.
  case removed
}

/// The body of every non-2xx reply.
public struct ErrorReply: Codable, Sendable, Equatable {
  public var error: String
  public var code: ErrorCode?
}
