// Which turns answer a voice request, what each one posts back to the app, and which lines of
// the other main-loop turns the app is sent. Pure: the hooks feed it `prompt.submit` origins and
// the main loop's turn starts and ends.
import { voiceRequestId } from './prompt.ts'
import type { AnswerStatus, RequestId, SyncBody, TurnRef } from './wire.ts'

/**
 * In characters: under the app's 131,072-byte body limit even at four UTF-8 bytes each; the app
 * shortens answers for speech itself.
 */
export const ANSWER_LIMIT = 32_000
/** How long after a voice request its background work still reports to the voice. */
export const FOLLOW_UP_MS = 10 * 60_000

export type TurnOrigin = 'voice' | 'owner' | 'other' | 'background'
export type TurnOutcome = 'answer' | 'aborted' | 'refusal' | 'error'
export type Post = { id: RequestId; status: AnswerStatus; text: string; reason?: string }
/** A line of a turn for the app. */
export type SyncLine = Omit<SyncBody, 'sessionId'>

/** What the tracker keeps across a reload of the mod (JSON data). */
export type TurnSnapshot = {
  pending: RequestId | null
  followUp: FollowUp | null
  turns: [string, Tracked][]
  /** Absent from a snapshot written before sync. */
  typed?: TypedPrompt[]
  /** Absent from a snapshot written before sync. */
  prompts?: OpenPrompt[]
}
type FollowUp = { id: RequestId; until: number }
/**
 * A main-loop turn. `id`: the voice request its answer goes to; null for a turn with none behind
 * it. `linesUnder`: the turn id its lines go under, when that is not its own.
 */
type Tracked = ({ id: RequestId; isVoice: boolean } | { id: null; isVoice: false }) & { linesUnder?: string }
/** The turn running, with its id and, always, the id its lines go under. */
type Running = Tracked & { turnId: string; linesUnder: string }
/** A prompt posted with a running turn's id, until a turn turns out to be its own, or none will. */
type TypedPrompt = { text: string; turnId: string }
/**
 * A permission prompt reported and not settled, in the agent that asked (absent: the main loop). A
 * tool's name is not enough to tell its prompt from its other runs, and the hooks share no id, so
 * `input` holds the tool's input as JSON.
 */
type OpenPrompt = { tool: string; input: string; agent?: string }

/**
 * Background work a voice request may have started (a background task's notification, a
 * returning background agent included). Every other origin, one this list does not know too,
 * is `other`: its answer never goes to the voice as a result.
 */
const BACKGROUND = new Set(['task-notification'])
/** The origins seen to be a person's own typing (ADR 0001, item m). */
const OWNER = new Set(['composer'])
const FAILURE: Record<TurnOutcome, string> = {
  /** An empty answer: a plain No at a permission dialog, or a cancelled question (ADR 0001, item i). */
  answer: 'Claude ended the turn without an answer',
  aborted: 'the turn was interrupted',
  refusal: 'the model refused the request',
  error: 'the turn ended with an error',
}

/** The mod's line for a turn that ended without an answer: a voice turn says it as its reason instead. */
function endedWithout(outcome: TurnOutcome): string {
  const reason = FAILURE[outcome]
  return `${reason.charAt(0).toUpperCase()}${reason.slice(1)}.`
}

/** How the wire names a turn: by the id its lines go under, with the request its answer belongs to. */
const refOf = (turn: Running): TurnRef =>
  ({ id: turn.linesUnder, ...(turn.id !== null && { request: turn.id }) })

/** The first `limit` characters of `text`, counted as code points, so no surrogate pair is cut. */
export function clip(text: string, limit: number): string {
  let end = 0
  let count = 0
  for (const char of text) {
    if (count === limit) return text.slice(0, end)
    end += char.length
    count += 1
  }
  return text
}

/**
 * A turn's origin from the `origin` of the `prompt.submit` before it (ADR 0001, item m).
 * `isMeta`: the person does not see the prompt as typed, so it is not their words.
 */
export function originOf(origin: { kind: string; name?: string }, self: string, isMeta = false): TurnOrigin {
  if (origin.kind === 'plugin' && origin.name === self) return 'voice'
  if (BACKGROUND.has(origin.kind)) return 'background'
  return OWNER.has(origin.kind) && !isMeta ? 'owner' : 'other'
}

/**
 * Follows every main-loop turn: the voice request in flight, the follow-up window after it (for
 * `FOLLOW_UP_MS` and until any other turn, each background turn's answer is a later update to
 * the last voice request), and what a turn with no request behind it posts as sync lines.
 */
export class TurnTracker {
  #pending: RequestId | null
  #followUp: FollowUp | null
  /** Main-loop turns run one at a time. */
  #turn: Running | null
  #typed: TypedPrompt[]
  #prompts: OpenPrompt[]
  /** The visible text of the main loop's model step so far, until a question or an approval takes it. */
  #stepText = ''

  constructor(saved?: TurnSnapshot) {
    this.#pending = saved?.pending ?? null
    this.#followUp = saved?.followUp ?? null
    const held = saved?.turns?.at(-1)
    this.#turn = held === undefined ? null : { linesUnder: held[0], ...held[1], turnId: held[0] }
    this.#typed = saved?.typed ?? []
    this.#prompts = saved?.prompts ?? []
  }

  /** The main-loop turn running, as the wire names it; null between turns. */
  get current(): TurnRef | null {
    return this.#turn && refOf(this.#turn)
  }

  /** The main loop's next model step starts: nothing of it is written yet. */
  stepStarted(): void {
    this.#stepText = ''
  }

  /** The main loop's model step streamed `text` of its visible text. */
  streamed(text: string): void {
    this.#stepText += text
  }

  /**
   * What the step wrote, for the question or permission prompt it pauses on: the engine's turn
   * end carries only the turn's last text, and a pause only itself. Taken once, so a second pause
   * in the same step does not repeat it, and cut to `ANSWER_LIMIT`.
   */
  takeStepText(): string {
    const text = clip(this.#stepText, ANSWER_LIMIT)
    this.#stepText = ''
    return text
  }

  /** Whether a permission prompt is open, in any agent. */
  get isPrompting(): boolean {
    return this.#prompts.length > 0
  }

  /** A permission prompt in `agent` (absent: the main loop) is open for the tool's run on `input`. */
  promptOpened(tool: string, input: unknown, agent?: string): void {
    this.#prompts.push({ tool, input: JSON.stringify(input), ...(agent !== undefined && { agent }) })
  }

  /** A tool ran, or failed: whether that settles an open prompt, which is then over. */
  promptRan(tool: string, input: unknown, agent?: string): boolean {
    const json = JSON.stringify(input)
    return this.#takePrompt(one => one.tool === tool && one.input === json && one.agent === agent) !== null
  }

  /**
   * `agent`'s next model step or its end shows its dialogs are gone, with no tool run: the tool of
   * one of its prompts, which is then over, or null when none is left.
   */
  promptGone(agent?: string): string | null {
    return this.#takePrompt(one => one.agent === agent)?.tool ?? null
  }

  #takePrompt(isIt: (prompt: OpenPrompt) => boolean): OpenPrompt | null {
    const at = this.#prompts.findIndex(isIt)
    return at < 0 ? null : (this.#prompts.splice(at, 1)[0] ?? null)
  }

  /** A voice request was submitted; its turn starts once the session is idle. */
  submitted(id: RequestId): void {
    this.#pending = id
  }

  /** Claude Code did not take the voice request's prompt: no turn of it will start. */
  refused(id: RequestId): void {
    if (this.#pending === id) this.#pending = null
  }

  /**
   * The owner typed `text` into running turn `turnId`, and it goes under that turn. The engine
   * does not say whether it folds in or gets a turn of its own later (ADR 0001, item m), so it is
   * remembered as `entered`, what a hook left of it and what that turn's start will hold, until a
   * turn claims it.
   */
  typedInto(turnId: string, text: string, entered = text): SyncLine {
    const turn = refOf(this.#turn?.turnId === turnId ? this.#turn : { id: null, isVoice: false, turnId, linesUnder: turnId })
    this.#typed.push({ text: entered, turnId: turn.id })
    return { turn, kind: 'typed', text }
  }

  /**
   * A main-loop turn started at `now` (ms): the lines it opens with. Every turn opens with a
   * `start`, which takes its decision, and an owner's turn with its prompt after that. `text` is
   * `turn.start`'s, which names the voice request; `prompt` is `prompt.submit`'s, what was typed.
   * `origin` is null when no `prompt.submit` came first: so starts the turn of a prompt typed into
   * the turn before it, whose lines stay under that id and which has that turn's decision.
   * `isLost`: a turn was still held, so it ended where the tracker could not follow it: neither its
   * lines nor its answer went to the app.
   */
  turnStarted(
    turnId: string, text: string, origin: TurnOrigin | null, now: number, prompt = text,
  ): { lines: SyncLine[]; isLost: boolean } {
    const isLost = this.#turn !== null
    this.#turn = null
    this.#prompts = []
    return { lines: this.#open(turnId, text, origin, now, prompt), isLost }
  }

  #open(turnId: string, text: string, origin: TurnOrigin | null, now: number, prompt: string): SyncLine[] {
    const opened = (turn: Tracked): SyncLine[] => {
      this.#turn = { ...turn, turnId, linesUnder: turnId }
      return [{ turn: refOf(this.#turn), kind: 'start' }]
    }
    const id = voiceRequestId(text)
    const at = id === null && origin !== 'owner' ? this.#typed.findIndex(one => one.text === text) : -1
    const claimed = this.#typed[at]
    // Prompts before the one claimed folded in; with none claimed, every one did.
    this.#typed = claimed === undefined ? [] : this.#typed.slice(at + 1)
    if (id !== null) {
      this.#followUp = { id, until: now + FOLLOW_UP_MS }
      if (this.#pending === id) this.#pending = null
      return opened({ id, isVoice: true })
    }
    if (claimed !== undefined) {
      this.#turn = { id: null, isVoice: false, turnId, linesUnder: claimed.turnId }
      this.#followUp = null
      return []
    }
    if (origin === 'background' && this.#followUp !== null && now < this.#followUp.until) {
      return opened({ id: this.#followUp.id, isVoice: false })
    }
    this.#followUp = null
    const lines = opened({ id: null, isVoice: false })
    return origin === 'owner' ? [...lines, { turn: { id: turnId }, kind: 'typed', text: prompt }] : lines
  }

  /**
   * The owner's spoken reply `replyId` answered the running turn's question, and the app says
   * its answer belongs to `forRequest`, undefined from an older app. The turn's own request:
   * nothing changes. The reply itself: the rest of the turn is a voice turn, as it is for a typed
   * turn, and for a voice turn whose request timed out or went with an app restart, which would
   * otherwise leave the reply open with no answer to close it. Another one, already in flight: the
   * answer is an update to it.
   */
  replied(replyId: RequestId, forRequest: RequestId | undefined, now: number): void {
    const turn = this.#turn
    if (turn === null || forRequest === undefined || turn.id === forRequest) return
    const isOwn = forRequest === replyId
    this.#turn = { ...turn, id: forRequest, isVoice: isOwn }
    if (isOwn) this.#followUp = { id: forRequest, until: now + FOLLOW_UP_MS }
  }

  /**
   * A main-loop turn ended: what to post for it, as an answer to the voice request or a line.
   * `isLost`: the tracker never saw it start, so none of it went to the app.
   */
  turnCompleted(turnId: string, answer: string, outcome: TurnOutcome): { post: Post | null; sync: SyncLine | null; isLost?: true } {
    this.#prompts = []
    const turn = this.#turn
    if (turn?.turnId !== turnId) return { post: null, sync: null, isLost: true }
    this.#turn = null
    const text = answer.trim()
    const isAnswered = outcome === 'answer' && text !== ''
    if (turn.isVoice) {
      if (!isAnswered) return { post: { id: turn.id, status: 'failed', text, reason: FAILURE[outcome] }, sync: null }
      return { post: { id: turn.id, status: /\?[*_`)"'”’\s]*$/u.test(text) ? 'question' : 'ok', text }, sync: null }
    }
    const under = refOf(turn)
    if (!isAnswered) return { post: null, sync: { turn: under, kind: 'report', text: endedWithout(outcome) } }
    if (turn.id === null) return { post: null, sync: { turn: under, kind: 'answer', text } }
    return { post: { id: turn.id, status: 'update', text }, sync: null }
  }

  snapshot(): TurnSnapshot {
    return {
      pending: this.#pending, followUp: this.#followUp,
      turns: this.#turn === null ? [] : [[this.#turn.turnId, this.#turn]],
      typed: this.#typed, prompts: this.#prompts,
    }
  }
}
