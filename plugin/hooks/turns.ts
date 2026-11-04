// Which turns answer a voice request, and what each one posts back to the app. Pure: the hooks
// feed it `prompt.submit` origins and the main loop's turn starts and ends.
import { voiceRequestId } from './prompt.ts'
import type { AnswerStatus, RequestId } from './wire.ts'

/** How long after a voice request its background work still reports to the voice. */
export const FOLLOW_UP_MS = 10 * 60_000

export type TurnOrigin = 'voice' | 'typed' | 'background'
export type TurnOutcome = 'answer' | 'aborted' | 'refusal' | 'error'
export type Post = { id: RequestId; status: AnswerStatus; text: string; reason?: string }

/** What the tracker keeps across a reload of the mod (JSON data). */
export type TurnSnapshot = {
  pending: RequestId | null
  followUp: FollowUp | null
  turns: [string, Tracked][]
}
type FollowUp = { id: RequestId; until: number }
type Tracked = { id: RequestId; isVoice: boolean }

/**
 * Background work a voice request may have started (a background task's notification, a
 * returning background agent included). Every other origin, one this list does not know too,
 * counts as typed: its answer reaches the voice only as the context's `last`, when asked for.
 */
const BACKGROUND = new Set(['task-notification'])
const FAILURE: Record<Exclude<TurnOutcome, 'answer'>, string> = {
  aborted: 'the turn was interrupted',
  refusal: 'the model refused the request',
  error: 'the turn ended with an error',
}

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
 * The last `limit` characters of `text` (code points, so no surrogate pair is cut), from the start
 * of a line when it is cut at all: what is left of the line the cut fell in is dropped.
 */
export function clipToEnd(text: string, limit: number): string {
  const chars = [...text]
  if (chars.length <= limit) return text
  const window = chars.slice(chars.length - limit).join('')
  const cut = window.indexOf('\n')
  return cut < 0 ? window : window.slice(cut + 1)
}

/** A turn's origin from the `origin` of the `prompt.submit` before it (ADR 0001, item m). */
export function originOf(origin: { kind: string; name?: string }, self: string): TurnOrigin {
  if (origin.kind === 'plugin' && origin.name === self) return 'voice'
  return BACKGROUND.has(origin.kind) ? 'background' : 'typed'
}

/**
 * Follows the voice request in flight and the follow-up window after it: for `FOLLOW_UP_MS`
 * and until any other turn, each background turn's answer is a later update to the last voice
 * request.
 */
export class TurnTracker {
  #pending: RequestId | null
  #followUp: FollowUp | null
  #turns: Map<string, Tracked>
  /** The visible text of the main loop's last model step, until a question takes it. */
  #stepText = ''

  constructor(saved?: TurnSnapshot) {
    this.#pending = saved?.pending ?? null
    this.#followUp = saved?.followUp ?? null
    this.#turns = new Map(saved?.turns ?? [])
  }

  /**
   * The voice request whose turn runs now. One waiting to start does not count: until its turn
   * starts, the running turn is someone else's, and so are its questions and approvals.
   */
  get running(): RequestId | null {
    for (const turn of this.#turns.values()) if (turn.isVoice) return turn.id
    return null
  }

  /** The main loop's model step ended with `text` visible (empty when it only called tools). */
  stepped(text: string): void {
    this.#stepText = text
  }

  /**
   * What the last step wrote, for the question it asked: the engine's turn end carries only the
   * turn's last text, and a question only its options. Taken once, so a second question in the
   * same step does not repeat it.
   */
  takeStepText(): string {
    const text = this.#stepText
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

  /** A main-loop turn started at `now` (ms). Its prompt names the voice request it answers, if any. */
  turnStarted(turnId: string, text: string, origin: TurnOrigin, now: number): void {
    const id = voiceRequestId(text)
    if (id !== null) {
      this.#turns.set(turnId, { id, isVoice: true })
      this.#followUp = { id, until: now + FOLLOW_UP_MS }
      if (this.#pending === id) this.#pending = null
    } else if (origin === 'background' && this.#followUp !== null && now < this.#followUp.until) {
      this.#turns.set(turnId, { id: this.#followUp.id, isVoice: false })
    } else {
      this.#followUp = null
    }
  }

  /** A main-loop turn ended: what to post for it, or null when it posts nothing. */
  turnCompleted(turnId: string, answer: string, outcome: TurnOutcome): Post | null {
    const turn = this.#turns.get(turnId)
    if (turn === undefined) return null
    this.#turns.delete(turnId)
    const text = answer.trim()
    if (!turn.isVoice) return outcome === 'answer' && text !== '' ? { id: turn.id, status: 'update', text } : null
    if (outcome !== 'answer') return { id: turn.id, status: 'failed', text, reason: FAILURE[outcome] }
    return { id: turn.id, status: /\?[*_`)"'”’\s]*$/u.test(text) ? 'question' : 'ok', text }
  }

  snapshot(): TurnSnapshot {
    return { pending: this.#pending, followUp: this.#followUp, turns: [...this.#turns] }
  }
}
