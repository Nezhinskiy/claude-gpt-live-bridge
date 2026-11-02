// The mod's side of the bridge: HTTP over the app's Unix socket, the app's launch, the
// one-second poll loop and the queue that runs the session's link work one piece at a time.
// Each call answers what happened and never throws.
import type { HttpInit, HttpResponse, ProcessRunResult, Timer } from 'claude-code'

import type { AnswerBody, CallAction, JoinBody, PollReply, SessionActivity } from './wire.ts'

/** LiveBridge.app's bundle identifier. */
export const BUNDLE_ID = 'io.github.nezhinskiy.livebridge'
const POLL_MS = 1000
/** What `next` and `answer` answer once the owner removed this session in the app (HTTP 410). */
export const REMOVED = 'removed'

/**
 * The engine calls the link makes. A hooks module spells every call `$.noun.event(...)` where
 * it is made, so the hook that creates the link hands it these instead of `$` itself.
 */
export type LinkPorts = {
  fetch(url: string, init: HttpInit): Promise<HttpResponse>
  run(argv: readonly string[]): Promise<ProcessRunResult>
  every(ms: number, fn: () => void): Timer
  log(text: string): void
  /** The app answered 410: the owner removed the session, which the link has already forgotten. */
  removed(sessionId: string): void
}

export class BridgeLink {
  readonly #ports: LinkPorts
  readonly #socketPath: string
  readonly #appPath: string
  /** What this session last joined as, kept so that it can join again after the app restarts. */
  #joined: JoinBody | null = null
  #isKnown = false
  #timer: Timer | null = null
  #isPolling = false
  #queue: Promise<unknown> = Promise.resolve()

  /** `appPath`: where build-app.sh installs the app. */
  constructor(ports: LinkPorts, paths: { socketPath: string; appPath: string }) {
    this.#ports = ports
    this.#socketPath = paths.socketPath
    this.#appPath = paths.appPath
  }

  get session(): JoinBody | null {
    return this.#joined
  }

  /**
   * Runs `work` once all work queued before it has settled. The poll, joining, following the
   * title and leaving go through here, so none of them sees another half done.
   */
  serial<T>(work: () => Promise<T>): Promise<T> {
    const run = this.#queue.then(work)
    this.#queue = run.catch(() => {})
    return run
  }

  /** Joins; true when the app took it. */
  async join(body: JoinBody): Promise<boolean> {
    const { replaces: _, ...kept } = body  // a later join (after an app restart) replaces nothing
    this.#joined = kept
    this.#isKnown = (await this.#send('join', body))?.ok === true
    return this.#isKnown
  }

  /** Joins again under a new id or title; false, with nothing sent, once the session left or was removed. */
  async rejoin(body: JoinBody): Promise<boolean> {
    return this.#joined !== null && this.join(body)
  }

  async leave(): Promise<void> {
    const joined = this.#joined
    this.#joined = null
    this.#isKnown = false
    if (joined !== null) await this.#send('leave', { sessionId: joined.sessionId })
  }

  /**
   * One poll: the app's status and any work for this session, or null while the app is out of
   * reach. A session the app does not know (it restarted) joins again first; one the owner
   * removed is `REMOVED`.
   */
  async next(retry = true): Promise<PollReply | null | typeof REMOVED> {
    const joined = this.#joined
    if (joined === null || (!this.#isKnown && !(await this.join(joined)))) return null
    const reply = await this.#send(`next?sessionId=${encodeURIComponent(joined.sessionId)}`)
    if (reply?.ok === true) return parse(reply.text)
    if (reply?.status === 410) return REMOVED
    this.#isKnown = false
    return reply?.status === 404 && retry ? this.next(false) : null
  }

  /**
   * Posts an answer; false when the app did not take it (out of reach, restarted, or ended),
   * `REMOVED` when the owner removed the session.
   */
  async answer(post: Omit<AnswerBody, 'sessionId'>): Promise<boolean | typeof REMOVED> {
    const reply = await this.#forSession('answer', post)
    if (reply?.status === 404) this.#isKnown = false
    return reply?.status === 410 ? REMOVED : reply?.ok === true
  }

  async activity(state: SessionActivity): Promise<void> {
    await this.#forSession('activity', { state })
  }

  /** Posts the session's summary; false when the app did not take it. */
  async context(summary: string): Promise<boolean> {
    return (await this.#forSession('context', { summary }))?.ok === true
  }

  async target(): Promise<void> {
    await this.#forSession('target', {})
  }

  async call(action: CallAction): Promise<void> {
    await this.#send('call', { action })
  }

  /**
   * Opens the app in the background (ADR 0001, item f); false when that did not work. First by
   * the path build-app.sh installs it at, a folder only the owner writes; only then by bundle id,
   * which trusts whichever app Launch Services picks for it.
   */
  async ensureApp(): Promise<boolean> {
    return (await this.#open(['open', '-g', this.#appPath])) || this.#open(['open', '-g', '-b', BUNDLE_ID])
  }

  async #open(argv: readonly string[]): Promise<boolean> {
    try {
      return (await this.#ports.run(argv)).exitCode === 0
    } catch {
      return false
    }
  }

  /** Queues `tick` every second until `stop`, never two at once. */
  start(tick: () => Promise<void>): void {
    this.#timer ??= this.#ports.every(POLL_MS, () => {
      if (this.#isPolling) return
      this.#isPolling = true
      void this.serial(tick)
        .catch((error: unknown) => this.#ports.log(`voice poll failed: ${String(error)}`))
        .finally(() => { this.#isPolling = false })
    })
  }

  stop(): void {
    this.#timer?.cancel()
    this.#timer = null
  }

  async #forSession(route: string, body: object) {
    return this.#joined === null ? null : this.#send(route, { sessionId: this.#joined.sessionId, ...body })
  }

  /**
   * A POST with a JSON body, or a GET without one; null when the socket is out of reach. Every
   * 410 lands here: the owner removed the session, so the link forgets it, without leaving or
   * joining again, and says so once.
   */
  async #send(route: string, body?: object) {
    const init: HttpInit = body === undefined
      ? { socketPath: this.#socketPath }
      : {
          method: 'POST', socketPath: this.#socketPath,
          headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
        }
    let reply: HttpResponse
    try {
      reply = await this.#ports.fetch(`http://bridge/v1/${route}`, init)
    } catch {
      return null
    }
    const removed = this.#joined
    if (reply.status === 410 && removed !== null) {
      this.stop()
      this.#joined = null
      this.#isKnown = false
      this.#ports.removed(removed.sessionId)
    }
    return reply
  }
}

function parse(text: string): PollReply | null {
  try {
    return JSON.parse(text) as PollReply
  } catch {
    return null
  }
}
