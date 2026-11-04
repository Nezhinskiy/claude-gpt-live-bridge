// The JSON messages between the mod and LiveBridge.app, mirroring
// app/Sources/BridgeCore/Wire/Wire.swift (wire/fixtures holds an example of each). Optional
// fields are omitted when absent, never null. Non-2xx replies carry an ErrorReply: 400 schema,
// 404 unknown session, 409 unknown or stale request id, 410 a session the owner removed (code
// `removed`; also the reply to its join unless `owner` is true), 413 body over 131072 bytes.

/** The socket path relative to the home folder Foundation reports. */
const SOCKET_REL = 'Library/Application Support/LiveBridge/run/bridge.sock';

/**
 * The app's socket. The app finds Application Support through Foundation, which takes
 * `CFFIXED_USER_HOME` over the account's home when it is set, so the mod does the same.
 */
export function socketPath(home: string, fixedHome: string | undefined): string {
  return `${fixedHome || home}/${SOCKET_REL}`;
}

export type SessionId = string;
export type RequestId = string;

export type Role = 'user' | 'assistant';
export type Utterance = { role: Role; text: string };

/** brief: the voice model's self-contained request; transcript: the speech since the last one. */
export type VoiceRequest = { id: RequestId; brief: string; transcript: Utterance[] };
/** `reply`: the owner's reply to the question Claude is waiting on, for the request in flight. */
export type Work =
  | ({ kind: 'request' } & VoiceRequest)
  | ({ kind: 'reply' } & VoiceRequest)
  | { kind: 'context' };

/**
 * Joining again renames the session and refreshes its liveness. `replaces` is the id the
 * session had before `/clear`: its place, target and requests move to the new id. `owner: true`
 * says the owner asked for it (`/live on`): only such a join brings back a session the owner
 * removed, any other is answered 410 `removed`; absent means false. Whether a new target is asked
 * for its summary is the app's own setting, not the join's.
 */
export type JoinBody = { sessionId: SessionId; title: string; replaces?: SessionId; owner?: boolean };
export type LeaveBody = { sessionId: SessionId };
export type TargetBody = { sessionId: SessionId };

/** ok, failed and question close the request; update is a later result and closes nothing. */
export type AnswerStatus = 'ok' | 'failed' | 'question' | 'update';
export type AnswerBody =
  { sessionId: SessionId; id: RequestId; status: AnswerStatus; text: string; reason?: string };

export type SessionActivity = 'idle' | 'working' | 'approval';
/**
 * `question`, with `approval`: Claude asked the owner this in a voice turn and waits for the
 * reply, which the voice may hand over as a `reply` work item.
 */
export type ActivityBody = { sessionId: SessionId; state: SessionActivity; question?: string };
/** `last`: Claude's last reply in the session, when there is one. */
export type ContextBody = { sessionId: SessionId; summary: string; last?: string };

export type CallAction = 'start' | 'stop';
export type CallBody = { action: CallAction };

export type CallPhase = 'off' | 'listening' | 'connecting' | 'live';
export type SessionRow =
  { sessionId: SessionId; label: string; activity: SessionActivity; isTarget: boolean };

/** What every joined session's band shows; the app's menu has more, which no session is sent. */
export type StatusReply = {
  call: CallPhase;
  sessions: SessionRow[];
  minutesToday: number;
  problem?: string;
  /** Results the voice has not said yet. */
  unheard: number;
};

/** The reply to GET /v1/next; each poll also refreshes the session's liveness. */
export type PollReply = { status: StatusReply; work?: Work };
/** `removed` (410): the owner removed this session; the mod turns off instead of joining again. */
export type ErrorCode = 'removed';
export type ErrorReply = { error: string; code?: ErrorCode };
