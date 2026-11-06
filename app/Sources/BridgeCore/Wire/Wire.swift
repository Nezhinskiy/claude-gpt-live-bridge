// The JSON messages between the mod and the app: `POST /v1/join|leave|answer|activity|context|
// sync|target|call` with the bodies below, and `GET /v1/next?sessionId=` answering a `PollReply`.
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

/// Work for a session, tagged by `kind`: `{"kind":"request", <VoiceRequest>}`,
/// `{"kind":"reply", <VoiceRequest>, "forRequest"}` (the owner's reply to the question Claude is
/// waiting on; `forRequest` is the request its answer belongs to) or `{"kind":"context"}` (summarise the session for the
/// voice).
public enum Work: Sendable, Equatable {
  case request(VoiceRequest)
  /// `forRequest`: the request the turn's answer belongs to, the one in flight once this reply
  /// goes out.
  case reply(VoiceRequest, forRequest: RequestID)
  case context
}

extension Work: Codable {
  private enum Kind: String, Codable { case request, reply, context }
  private enum CodingKeys: String, CodingKey { case kind, forRequest }

  public init(from decoder: any Decoder) throws {
    switch try decoder.container(keyedBy: CodingKeys.self).decode(Kind.self, forKey: .kind) {
    case .request: self = .request(try VoiceRequest(from: decoder))
    case .reply:
      let forRequest = try decoder.container(keyedBy: CodingKeys.self)
        .decode(RequestID.self, forKey: .forRequest)
      self = .reply(try VoiceRequest(from: decoder), forRequest: forRequest)
    case .context: self = .context
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .request(let request):
      try container.encode(Kind.request, forKey: .kind)
      try request.encode(to: encoder)
    case .reply(let request, let forRequest):
      try container.encode(Kind.reply, forKey: .kind)
      try container.encode(forRequest, forKey: .forRequest)
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
  /// `true`: the owner asked for it (`/live on`). Only such a join brings back a session the
  /// owner removed; any other is answered `410 removed`.
  public var owner: Bool?
  /// The mod's version, from its own plugin.json; absent from a mod from before this field, or
  /// one that could not read it.
  public var modVersion: String?
  /// `true` from a mod that posts sync lines (`POST /v1/sync`); absent from one that does not.
  public var syncs: Bool?
  /// `true`: a turn of this session did not arrive, so the voice's picture of it has a gap.
  public var missed: Bool?
}

public enum SyncSource: String, Codable, Sendable { case owner, claude }

/// `POST /v1/sync`: a line of a turn that is not a voice request. Empty `text`, at a turn's
/// start, takes the turn's decision and records nothing.
public struct SyncBody: Codable, Sendable, Equatable {
  public var sessionId: SessionID
  public var turnId: String
  public var from: SyncSource
  public var text: String
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

/// `POST /v1/activity`. `question`, with `approval`: Claude asked the owner this in a voice
/// turn and waits for the reply, which the voice may hand over as `Work.reply`; without it, a
/// permission prompt waits, which the voice only reports. `text`, with `approval`: what Claude
/// wrote in the step that pauses. `typedTurn`: the turn's id when it is not a voice turn.
public struct ActivityBody: Codable, Sendable, Equatable {
  public var sessionId: SessionID
  public var state: SessionActivity
  public var question: String?
  public var text: String?
  public var typedTurn: String?
}

/// `POST /v1/context`: the session's own summary, sent in reply to `Work.context`.
public struct ContextBody: Codable, Sendable, Equatable {
  public var sessionId: SessionID
  public var summary: String
}

public enum CallAction: String, Codable, Sendable { case start, stop, mute, unmute }

/// `POST /v1/call`: Start, Stop, Mute or Unmute from the Claude Code band.
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

/// What every joined session's band shows, and the menu with it (`BridgeUpdate`).
public struct StatusReply: Codable, Sendable, Equatable {
  public var call: CallPhase
  public var sessions: [SessionRow]
  public var minutesToday: Double
  /// One sentence on why the call cannot start or just stopped.
  public var problem: String?
  /// Results the voice has not said yet: waiting for the owner to speak, or given to the open
  /// session.
  public var unheard: Int
  /// The microphone is released while the call goes on.
  public var isMuted = false
}

/// The reply to `GET /v1/next`. Each poll also refreshes the session's liveness.
public struct PollReply: Codable, Sendable, Equatable {
  public var status: StatusReply
  public var work: Work?
}

/// What a non-2xx reply asks of the mod, beyond its HTTP status.
public enum ErrorCode: String, Codable, Sendable {
  /// `410`: the owner removed this session; the mod turns itself off instead of joining again.
  /// Its joins get it too, until one says the owner asked for it (`JoinBody.owner`).
  case removed
}

/// The body of every non-2xx reply.
public struct ErrorReply: Codable, Sendable, Equatable {
  public var error: String
  public var code: ErrorCode?
}
