// The JSON messages between the mod and LiveBridge.app, mirroring
// app/Sources/BridgeCore/Wire/Wire.swift (wire/fixtures holds an example of each). Optional
// fields are omitted when absent, never null. Non-2xx replies carry an ErrorReply: 400 schema,
// 404 unknown session, 409 unknown or stale request id, 413 body over 131072 bytes.

/** The socket path relative to the user's home directory. */
export const SOCKET_REL = 'Library/Application Support/claude-gpt-live-bridge/run/bridge.sock';

export type SessionId = string;
export type RequestId = string;

export type Role = 'user' | 'assistant' | 'developer';
export type Utterance = { role: Role; text: string };

/** brief: the voice model's self-contained request; transcript: the speech since the last one. */
export type VoiceRequest = { id: RequestId; brief: string; transcript: Utterance[] };
export type Work = ({ kind: 'request' } & VoiceRequest) | { kind: 'context' };

/**
 * Joining again renames the session and refreshes its liveness. `replaces` is the id the
 * session had before `/clear`: its place, target and requests move to the new id.
 */
export type JoinBody = { sessionId: SessionId; title: string; autoContext: boolean; replaces?: SessionId };
export type LeaveBody = { sessionId: SessionId };
export type TargetBody = { sessionId: SessionId };

/** ok, failed and question close the request; update is a later result and closes nothing. */
export type AnswerStatus = 'ok' | 'failed' | 'question' | 'update';
export type AnswerBody =
  { sessionId: SessionId; id: RequestId; status: AnswerStatus; text: string; reason?: string };

export type SessionActivity = 'idle' | 'working' | 'approval';
export type ActivityBody = { sessionId: SessionId; state: SessionActivity };
export type ContextBody = { sessionId: SessionId; summary: string };

export type CallAction = 'start' | 'stop';
export type CallBody = { action: CallAction };

export type CallPhase = 'off' | 'listening' | 'connecting' | 'live';
export type SessionRow =
  { sessionId: SessionId; label: string; activity: SessionActivity; isTarget: boolean };

export type StatusReply = {
  call: CallPhase;
  target?: SessionId;
  sessions: SessionRow[];
  minutesToday: number;
  minutesThisCall: number;
  problem?: string;
  lastContext?: string;
  recentTranscript: string[];
  /** Results waiting for the owner to speak. */
  unheard: number;
};

/** The reply to GET /v1/next; each poll also refreshes the session's liveness. */
export type PollReply = { status: StatusReply; work?: Work };
export type ErrorReply = { error: string };
