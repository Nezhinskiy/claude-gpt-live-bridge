// The JSON messages between the mod and LiveBridge.app, mirroring
// app/Sources/BridgeCore/Wire/Wire.swift (wire/fixtures holds an example of each). The routes:
// `POST /v1/join|leave|answer|activity|context|sync|limits|target|call|model-check` and
// `GET /v1/next?sessionId=`,
// which answers a PollReply. Optional
// fields are omitted when absent, never null. Non-2xx replies carry an ErrorReply: 400 schema,
// 404 unknown session, 409 unknown or stale request id, 410 a session the owner removed (code
// `removed`; also the reply to its join unless `owner` is true), 413 body over 131072 bytes.
// `sync` and `context` look a session up among the joined, so a removed one gets their 404, and
// `activity` and `limits` ignore it, 200.

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
/**
 * `reply`: the owner's reply to the question Claude is waiting on. `forRequest` is the request
 * the turn's answer belongs to: the one in flight once this reply goes out. Absent from an
 * older app's reply. `context`: summarise the session; `model` is the model to write it with,
 * absent from an older app, and `fallbackModel` the one tried once if `model` fails, absent when
 * `model` is the app's default. `ask` is the ask's number, which the answer echoes; absent from an
 * older app. `checkModel`: check that `model` answers, and post the result (`ModelCheckBody`) under
 * the check's `id`; sent only to a mod that says `writesSummaries`.
 */
export type Work =
  | ({ kind: 'request' } & VoiceRequest)
  | ({ kind: 'reply'; forRequest?: RequestId } & VoiceRequest)
  | { kind: 'context'; model?: string; fallbackModel?: string; ask?: number }
  | { kind: 'checkModel'; id: string; model: string };

/**
 * Joining again renames the session and refreshes its liveness. `replaces` is the id the
 * session had before `/clear`: its place, target and requests move to the new id. `owner: true`
 * says the owner asked for it (`/live`): only such a join brings back a session the owner
 * removed, any other is answered 410 `removed`; absent means false. `modVersion` is this mod's
 * version, from its plugin.json; absent from a mod from before the field, or one that could not
 * read it, and Settings then lists the session as on the old mod. `syncs: true` says this mod
 * posts its turns as sync lines (POST /v1/sync), so the app may rely on what it has recorded of
 * the session; absent, the app asks for a summary as before. `missed: true` says a turn of the
 * session did not arrive, so the voice's picture of it has a gap. `writesSummaries: true` says this
 * mod writes with the model an ask names and answers every context ask, with an empty summary
 * when it has none.
 */
export type JoinBody = {
  sessionId: SessionId; title: string; replaces?: SessionId; owner?: boolean; modVersion?: string;
  syncs?: boolean; missed?: boolean; writesSummaries?: boolean;
};
/**
 * The main-loop turn a line or an activity belongs to. `request`: the voice request the turn's
 * answer belongs to; absent from a turn with none behind it. A spoken reply that makes a typed
 * turn a voice turn adds it to the turn's later lines.
 */
export type TurnRef = { id: string; request?: RequestId };
/**
 * `start`: a turn's first word, which takes the turn's decision and records nothing; the only kind
 * with no `text`. `typed`: the owner's words, the only kind that refuses a turn. `answer`: Claude's
 * final answer. `report`: the mod's own line, which goes as Claude's.
 */
export type SyncKind = 'start' | 'typed' | 'answer' | 'report';
export type SyncBody = { sessionId: SessionId; turn: TurnRef; kind: SyncKind; text?: string };
export type LeaveBody = { sessionId: SessionId };
export type TargetBody = { sessionId: SessionId };

/** ok, failed and question close the request; update is a later result and closes nothing. */
export type AnswerStatus = 'ok' | 'failed' | 'question' | 'update';
export type AnswerBody =
  { sessionId: SessionId; id: RequestId; status: AnswerStatus; text: string; reason?: string };

export type SessionActivity = 'idle' | 'working' | 'approval';
/**
 * `question`, with `approval`: Claude asked the owner this and waits for the reply, which the
 * voice may hand over as a `reply` work item; without it, a permission prompt waits, which the
 * voice only reports. `text`, with `approval`: what Claude wrote in the step that pauses.
 * `turn`: the main-loop turn it belongs to; absent between turns.
 */
export type ActivityBody =
  { sessionId: SessionId; state: SessionActivity; question?: string; text?: string; turn?: TurnRef };
/**
 * Why one attempt at a summary wrote nothing; `error`, with `api-error`, the engine's kind of error.
 * `transcript-unreadable`: the session's transcript could not be read, so no model was asked.
 */
export type SummaryFailure = {
  reason: 'model-refused' | 'api-error' | 'empty-reply' | 'timed-out' | 'transcript-unreadable'; error?: string;
};
/** The numbers of the attempt that wrote a summary with a named model; a fork sends none. */
export type SummaryStats =
  { durationMs: number; transcriptChars: number; inputTokens: number; outputTokens: number };
/**
 * `failures`: one per attempt that wrote nothing, in order; with a summary the fallback wrote it,
 * with `""` none did. `stats`: of the attempt that wrote it. `ask`: the number of the ask it answers.
 */
export type ContextBody = {
  sessionId: SessionId; summary: string; failures?: SummaryFailure[]; stats?: SummaryStats; ask?: number;
};

/**
 * The result of the check `id`. `ok`: the model answered with text; otherwise `reason` says why not,
 * and `error`, with `api-error`, the engine's kind of error.
 */
export type ModelCheckBody = {
  sessionId: SessionId; id: string; ok: boolean; reason?: SummaryFailure['reason']; error?: string;
};

/**
 * One usage window as the engine reports it. The app takes `five_hour` as a window of five hours
 * and `seven_day` as a week, ignores `spend_limit`, and shows any other kind of `[a-z0-9_]{1,32}`
 * by name; a kind outside that is ignored. `percentUsed` is usually 0 to 100 but is not checked:
 * it is clamped only when shown. `resetsAt` is an ISO 8601 time, omitted when absent.
 */
export type LimitWindowBody = { kind: string; percentUsed: number; resetsAt?: string };
/** Claude's usage windows, as this session read them. */
export type LimitsBody = { sessionId: SessionId; windows: LimitWindowBody[] };

export type CallAction = 'start' | 'stop' | 'mute' | 'unmute';
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
  /** The microphone is released while the call goes on. */
  isMuted?: boolean;
};

/** The reply to GET /v1/next; each poll also refreshes the session's liveness. */
export type PollReply = { status: StatusReply; work?: Work };
/** `removed` (410): the owner removed this session; the mod turns off instead of joining again. */
export type ErrorCode = 'removed';
export type ErrorReply = { error: string; code?: ErrorCode };
