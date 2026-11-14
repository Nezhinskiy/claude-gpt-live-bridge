// The summaries the app asks for (`context` work): the one kept while it is current, the send on
// its way, the asks that join it, and what makes it stale. Pure: the hooks hand each ask the
// engine's and the link's calls it needs (`SendPort`), and say what ends a summary's use.
import { CONTEXT_TIMEOUT_MS } from './wire.ts'
import type { ContextBody, SummaryFailure, SummaryStats, Work } from './wire.ts'

/** How long the band says "Context sent". */
export const SENT_NOTE_MS = 3_000

export type Summary = { text: string; failures: SummaryFailure[]; stats?: SummaryStats }
/** What a context ask names: the model to write with, and the one to try if it fails; none from an older app. */
export type ContextAsk = Omit<Extract<Work, { kind: 'context' }>, 'kind'>
/** The band's note on the summary; undefined takes it down. */
export type ContextNote = 'loading' | 'sent' | 'failed' | undefined

/** What one send needs of the engine and the link. */
export type SendPort = {
  /** Whether the session has had a prompt: a new one has nothing to summarise. */
  hasTurns(): Promise<boolean>
  /**
   * `summarize`: it rejects only for an older app's ask, whose fork wrote none. `isCrossed` says
   * whether the send went stale, so it tries no fallback for nothing.
   */
  write(ask: ContextAsk, isCrossed: () => boolean): Promise<Summary>
  /** Posts an answer; true when the app took it. */
  post(body: Omit<ContextBody, 'sessionId'>): Promise<boolean>
  note(note: ContextNote): Promise<unknown>
  after(ms: number, fn: () => void): { cancel(): void }
  /** No summary reached the app for the ask that started a send. */
  failed(): void
}

/** `epoch`: what had ended a summary's use when the send started. `isCrossed`: it went stale on its way. */
type Send = { ask: number | undefined; epoch: number; isCrossed: boolean }
/** `failed`: no summary reached the app; `empty`: nothing to summarise, or a send gone stale. */
type Outcome = 'sent' | 'empty' | 'failed'

/** The ask's number, which every answer to an ask that names a model echoes. */
const answering = (ask: ContextAsk) => (ask.ask === undefined ? {} : { ask: ask.ask })

/**
 * The session's summary sends. Kept in memory only, as the transcript a summary covers is the
 * session's own.
 */
export class SummarySends {
  /**
   * The last summary a model wrote, while nothing has ended its use. `model` is the one the ask
   * named (undefined: a fork), and only an ask naming it gets the summary again, with the failures
   * that came before it, at no model call.
   */
  #kept: { model: string | undefined; text: string; failures: SummaryFailure[] } | null = null
  /** Counts what ends a summary's use, so a summary written across one is not kept. */
  #epoch = 0
  /** The send on its way, which an ask with its number joins unless it is crossed. */
  #sending: Send | null = null
  /** The latest send, which alone owns the band's note. */
  #latest: Send | null = null

  /**
   * What ends a summary's use: a main-loop turn completed, a gap (a turn did not reach the app), or
   * `/clear`. The kept summary goes; a gap or `/clear` also crosses the send on its way.
   */
  end(cause: 'turn' | 'gap' | 'clear'): void {
    this.#epoch += 1
    this.#kept = null
    if (cause !== 'turn' && this.#sending !== null) this.#sending.isCrossed = true
  }

  /**
   * Answers one ask. An ask with the number of the send on its way joins it, and says nothing: the
   * ask that started it says a failure, once.
   */
  async ask(ask: ContextAsk, port: SendPort): Promise<void> {
    const sending = this.#sending
    if (sending !== null && !sending.isCrossed && sending.ask === ask.ask) return
    const send: Send = { ask: ask.ask, epoch: this.#epoch, isCrossed: false }
    this.#sending = this.#latest = send
    const outcome = await this.#deliver(ask, send, port).finally(() => {
      if (this.#sending === send) this.#sending = null
    })
    if (outcome === 'failed') port.failed()
  }

  /**
   * An ask that names a model, from an app that waits on the answer, is answered at every exit, an
   * empty summary when there is none; an older app's ask is answered only with one.
   */
  async #deliver(ask: ContextAsk, send: Send, port: SendPort): Promise<Outcome> {
    const isNamed = ask.model !== undefined
    if (!(await port.hasTurns())) {
      if (isNamed) await port.post({ summary: '', ...answering(ask) })
      return 'empty'
    }
    await port.note('loading')
    const outcome = await (isNamed ? this.#write(ask, send, port) : this.#fork(ask, send, port))
    if (this.#latest !== send) return outcome
    await port.note(outcome === 'sent' ? 'sent' : outcome === 'failed' && isNamed ? 'failed' : undefined)
    if (outcome === 'sent') port.after(SENT_NOTE_MS, () => void (this.#latest === send && port.note(undefined)))
    return outcome
  }

  /**
   * Writes with the model the ask names and posts what came of it, the failures included. A
   * crossed send is posted all the same, as its ask's answer, which the app then ignores as stale.
   */
  async #write(ask: ContextAsk, send: Send, port: SendPort): Promise<Outcome> {
    const { text, failures, stats } = await this.#summary(ask, send, port)
    const isTaken = await port.post({
      summary: text, ...(failures.length > 0 && { failures }), ...(stats && { stats }), ...answering(ask),
    })
    if (this.#latest !== send || send.isCrossed) return 'empty'
    if (!isTaken) return 'failed'
    return text !== '' ? 'sent' : failures.length > 0 ? 'failed' : 'empty'
  }

  /** An older app's ask: over after `CONTEXT_TIMEOUT_MS`, which crosses it. */
  async #fork(ask: ContextAsk, send: Send, port: SendPort): Promise<Outcome> {
    let timer: { cancel(): void } | undefined
    const late = new Promise<Outcome>(resolve => {
      timer = port.after(CONTEXT_TIMEOUT_MS, () => {
        send.isCrossed = true
        resolve('failed')
      })
    })
    const outcome = await Promise.race([this.#forkAndPost(ask, send, port), late])
    timer?.cancel()
    return outcome
  }

  /** The session's own model forks, and only a summary is posted; a crossed send's is dropped. */
  async #forkAndPost(ask: ContextAsk, send: Send, port: SendPort): Promise<Outcome> {
    try {
      const { text } = await this.#summary(ask, send, port)
      if (send.isCrossed) return 'failed'
      if (text === '') return 'empty'
      return (await port.post({ summary: text })) ? 'sent' : 'failed'
    } catch {
      return 'failed'
    }
  }

  /** The summary kept for the ask's model, else what it writes, kept if nothing made it stale meanwhile. */
  async #summary(ask: ContextAsk, send: Send, port: SendPort): Promise<Summary> {
    if (this.#kept !== null && this.#kept.model === ask.model) return this.#kept
    const written = await port.write(ask, () => send.isCrossed)
    const { text, failures } = written
    if (text !== '' && !send.isCrossed && send.epoch === this.#epoch) this.#kept = { model: ask.model, text, failures }
    return written
  }
}
