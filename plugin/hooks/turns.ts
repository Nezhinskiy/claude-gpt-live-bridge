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
}
type FollowUp = { id: RequestId; until: number }
/**
 * A main-loop turn. `id`: the voice request its answer goes to; null for a turn with none behind
 * it. `linesUnder`: the turn id its lines go under, when that is not its own.
 */
type Tracked = ({ id: RequestId; isVoice: boolean } | { id: null; isVoice: false }) & { linesUnder?: string }
/** A prompt posted with a running turn's id, until a turn turns out to be its own, or none will. */
type TypedPrompt = { text: string; turnId: string }

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
const refOf = (turnId: string, turn: Tracked): TurnRef =>
  ({ id: turn.linesUnder ?? turnId, ...(turn.id !== null && { request: turn.id }) })

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
  #turns: Map<string, Tracked>
  #typed: TypedPrompt[]
  #isTurnLost = false
  /** The visible text of the main loop's model step so far, until a question or an approval takes it. */
  #stepText = ''

  constructor(saved?: TurnSnapshot) {
    this.#pending = saved?.pending ?? null
    this.#followUp = saved?.followUp ?? null
    this.#turns = new Map(saved?.turns ?? [])
    this.#typed = saved?.typed ?? []
  }

  /**
   * The voice request whose turn runs now. One waiting to start does not count: until its turn
   * starts, the running turn is someone else's, and so are its questions and approvals.
   */
  get running(): RequestId | null {
    for (const turn of this.#turns.values()) if (turn.isVoice) return turn.id
    return null
  }

  /** The main-loop turn running, as the wire names it; null between turns. */
  get current(): TurnRef | null {
    const running = this.#latest
    return running && refOf(running.turnId, running.turn)
  }

  /** The turn that started last: main-loop turns run one at a time. */
  get #latest(): { turnId: string; turn: Tracked } | null {
    const entry = [...this.#turns].at(-1)
    return entry === undefined ? null : { turnId: entry[0], turn: entry[1] }
  }

  /**
   * Whether a turn ended where the tracker could not follow it, since the last ask: one that
   * completed unseen, or one still held when the next started. Neither its lines nor its answer
   * went to the app.
   */
  takeLostTurn(): boolean {
    const isLost = this.#isTurnLost
    this.#isTurnLost = false
    return isLost
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
    const turn = refOf(turnId, this.#turns.get(turnId) ?? { id: null, isVoice: false })
    this.#typed.push({ text: entered, turnId: turn.id })
    return { turn, kind: 'typed', text }
  }

  /**
   * A main-loop turn started at `now` (ms): the lines it opens with. Every turn opens with a
   * `start`, which takes its decision, and an owner's turn with its prompt after that. `text` is
   * `turn.start`'s, which names the voice request; `prompt` is `prompt.submit`'s, what was typed.
   * `origin` is null when no `prompt.submit` came first: so starts the turn of a prompt typed into
   * the turn before it, whose lines stay under that id and which has that turn's decision.
   */
  turnStarted(turnId: string, text: string, origin: TurnOrigin | null, now: number, prompt = text): SyncLine[] {
    const opened = (turn: Tracked): SyncLine[] => {
      this.#turns.set(turnId, turn)
      return [{ turn: refOf(turnId, turn), kind: 'start' }]
    }
    // Main-loop turns run one at a time: one still held never reported its end.
    if (this.#turns.size > 0) this.#isTurnLost = true
    this.#turns.clear()
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
      this.#turns.set(turnId, { id: null, isVoice: false, linesUnder: claimed.turnId })
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
   * its answer belongs to `forRequest`, undefined from an older app. The same request: the rest of
   * the turn is a voice turn. Another one, already in flight: the answer is an update to it.
   */
  replied(replyId: RequestId, forRequest: RequestId | undefined, now: number): void {
    const running = this.#latest
    if (running === null || running.turn.isVoice || forRequest === undefined) return
    const isOwn = forRequest === replyId
    this.#turns.set(running.turnId, { ...running.turn, id: forRequest, isVoice: isOwn })
    if (isOwn) this.#followUp = { id: forRequest, until: now + FOLLOW_UP_MS }
  }

  /** A main-loop turn ended: what to post for it, as an answer to the voice request or a line. */
  turnCompleted(turnId: string, answer: string, outcome: TurnOutcome): { post: Post | null; sync: SyncLine | null } {
    const turn = this.#turns.get(turnId)
    if (turn === undefined) {
      this.#isTurnLost = true
      return { post: null, sync: null }
    }
    this.#turns.delete(turnId)
    const text = answer.trim()
    const isAnswered = outcome === 'answer' && text !== ''
    if (turn.isVoice) {
      if (!isAnswered) return { post: { id: turn.id, status: 'failed', text, reason: FAILURE[outcome] }, sync: null }
      return { post: { id: turn.id, status: /\?[*_`)"'”’\s]*$/u.test(text) ? 'question' : 'ok', text }, sync: null }
    }
    const under = refOf(turnId, turn)
    if (!isAnswered) return { post: null, sync: { turn: under, kind: 'report', text: endedWithout(outcome) } }
    if (turn.id === null) return { post: null, sync: { turn: under, kind: 'answer', text } }
    return { post: { id: turn.id, status: 'update', text }, sync: null }
  }

  snapshot(): TurnSnapshot {
    return { pending: this.#pending, followUp: this.#followUp, turns: [...this.#turns], typed: this.#typed }
  }
}
