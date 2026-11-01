// Which turns answer a voice request, and what each one posts back to the app. Pure: the hooks
// feed it `prompt.submit` origins and the main loop's turn starts and ends.
import { voiceRequestId } from './prompt.ts'
import type { AnswerStatus, RequestId } from './wire.ts'

export type TurnOrigin = 'voice' | 'typed' | 'background'
export type TurnOutcome = 'answer' | 'aborted' | 'refusal' | 'error'
export type Post = { id: RequestId; status: AnswerStatus; text: string; reason?: string }

/** What the tracker keeps across a reload of the mod (JSON data). */
export type TurnSnapshot = {
  pending: RequestId | null
  followUp: RequestId | null
  turns: [string, Tracked][]
}
type Tracked = { id: RequestId; isVoice: boolean }

/** Origins a person stands behind; every other kind is background work. */
const TYPED = new Set(['composer', 'bridge', 'sdk', 'slack-ping'])
const FAILURE: Record<Exclude<TurnOutcome, 'answer'>, string> = {
  aborted: 'the turn was interrupted',
  refusal: 'the model refused the request',
  error: 'the turn ended with an error',
}

/** A turn's origin from the `origin` of the `prompt.submit` before it (ADR 0001, item m). */
export function originOf(origin: { kind: string; name?: string }, self: string): TurnOrigin {
  if (origin.kind === 'plugin' && origin.name === self) return 'voice'
  return TYPED.has(origin.kind) ? 'typed' : 'background'
}

/**
 * Follows the voice request in flight and the follow-up window after it: until a typed turn,
 * each background turn's answer is a later update to the last voice request.
 */
export class TurnTracker {
  #pending: RequestId | null
  #followUp: RequestId | null
  #turns: Map<string, Tracked>

  constructor(saved?: TurnSnapshot) {
    this.#pending = saved?.pending ?? null
    this.#followUp = saved?.followUp ?? null
    this.#turns = new Map(saved?.turns ?? [])
  }

  /** The voice request whose turn runs or waits to start. */
  get current(): RequestId | null {
    for (const turn of this.#turns.values()) if (turn.isVoice) return turn.id
    return this.#pending
  }

  /** A voice request was submitted; its turn starts once the session is idle. */
  submitted(id: RequestId): void {
    this.#pending = id
  }

  /** A main-loop turn started. Its prompt names the voice request it answers, if any. */
  turnStarted(turnId: string, text: string, origin: TurnOrigin): void {
    const id = voiceRequestId(text)
    if (id !== null) {
      this.#turns.set(turnId, { id, isVoice: true })
      this.#followUp = id
      if (this.#pending === id) this.#pending = null
    } else if (origin === 'typed') {
      this.#followUp = null
    } else if (this.#followUp !== null) {
      this.#turns.set(turnId, { id: this.#followUp, isVoice: false })
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
