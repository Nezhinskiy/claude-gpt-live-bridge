// The mod's side of the bridge: HTTP over the app's Unix socket, the app's launch, the poll
// loop (five times a second for the target, once a second otherwise) and the queue that runs
// the session's link work one piece at a time.
// Each call answers what happened and never throws.
import type { HttpInit, HttpResponse, ProcessRunResult, Timer } from 'claude-code'

import type { SyncLine } from './turns.ts'
import type {
  ActivityBody, AnswerBody, CallAction, ContextBody, JoinBody, LimitWindowBody, PollReply,
  SessionActivity,
} from './wire.ts'

/** LiveBridge.app's bundle identifier. */
export const BUNDLE_ID = 'com.getlivebridge.livebridge'
const POLL_MS = 200
/** A session that is not the target polls on every fifth tick, once a second. */
const TICKS_A_SECOND = 5
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
  /** The app took a join, the first or one after it restarted or appeared; it has no reading yet. */
  joined(): void
}

export class BridgeLink {
  readonly #ports: LinkPorts
  readonly #socketPath: string
  readonly #appPath: string
  /** What this session last joined as, kept so that it can join again after the app restarts. */
  #joined: JoinBody | null = null
  #isKnown = false
  /** A turn did not reach the app, and no join has said so yet. */
  #hasGap = false
  #timer: Timer | null = null
  #ticks = 0
  /** A once-a-second tick came while a poll ran, so the next tick that polls is it. */
  #isSlowDue = false
  /** The last poll's reply named this session the target. */
  #isTarget = false
  #isPolling = false
  #queue: Promise<unknown> = Promise.resolve()

  /** `appPath`: where both install routes put the app. */
  constructor(ports: LinkPorts, paths: { socketPath: string; appPath: string }) {
    this.#ports = ports
    this.#socketPath = paths.socketPath
    this.#appPath = paths.appPath
  }

  get session(): JoinBody | null {
    return this.#joined
  }

  get hasGap(): boolean {
    return this.#hasGap
  }

  /** A turn did not reach the app: the next poll joins again with `missed`. */
  noteGap(): void {
    this.#hasGap = true
    this.#isKnown = false
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
    // A later join (after an app restart, or following the title) replaces nothing and is not the
    // owner's: it must not bring back a session the owner removed.
    const { replaces: _, owner: __, ...kept } = body
    this.#joined = kept
    // A gap noted while this join is on its way is one it did not say: only the one it said clears.
    const saysGap = this.#hasGap
    this.#hasGap = false
    const isTaken = (await this.#send('join', { ...body, ...(saysGap && { missed: true }) }))?.ok === true
    if (!isTaken) this.#hasGap ||= saysGap
    this.#isKnown = isTaken && !this.#hasGap
    if (isTaken) this.#ports.joined()
    return isTaken
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
   * removed is `REMOVED`. Whether the reply names this session the target sets how often it polls.
   */
  async next(retry = true): Promise<PollReply | null | typeof REMOVED> {
    this.#isTarget = false
    const joined = this.#joined
    if (joined === null || (!this.#isKnown && !(await this.join(joined)))) return null
    const reply = await this.#send(`next?sessionId=${encodeURIComponent(joined.sessionId)}`)
    if (reply?.ok === true) {
      const polled = parse(reply.text)
      this.#isTarget = polled?.status.sessions.some(row => row.isTarget && row.sessionId === joined.sessionId) === true
      return polled
    }
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

  /**
   * `said`: what Claude asks the owner, or wrote before a permission prompt (`approval` only), and
   * the turn. False when the app did not take it.
   */
  async activity(state: SessionActivity, said: Omit<ActivityBody, 'sessionId' | 'state'> = {}): Promise<boolean> {
    return (await this.#forSession('activity', { state, ...said }))?.ok === true
  }

  /** Posts a line of a turn; false when the app did not take it, which a session not joined never does. */
  async sync(line: SyncLine): Promise<boolean> {
    return (await this.#forSession('sync', line))?.ok === true
  }

  /** Posts the session's summary, and what went wrong on the way; false when the app did not take it. */
  async context(body: Omit<ContextBody, 'sessionId'>): Promise<boolean> {
    return (await this.#forSession('context', body))?.ok === true
  }

  /** Posts Claude's usage windows; nothing for an empty list, and the app's reply changes nothing. */
  async limits(windows: readonly LimitWindowBody[]): Promise<void> {
    if (windows.length > 0) await this.#forSession('limits', { windows })
  }

  async target(): Promise<void> {
    await this.#forSession('target', {})
  }

  async call(action: CallAction): Promise<void> {
    await this.#send('call', { action })
  }

  /**
   * Opens the app in the background (ADR 0001, item f); false when that did not work. First by
   * the path both install routes put it at, a folder only an administrator writes; only then by
   * bundle id, which trusts whichever app Launch Services picks for it.
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

  /**
   * Queues `tick` every 200 ms while the last poll named this session the target, and once a
   * second otherwise, until `stop`, never two at once. `isFast`: a tick between the once-a-second
   * ones, which only the target polls on. A once-a-second tick that a slow poll held back is the
   * next one that polls, so its work runs about once a second whatever a poll takes.
   */
  start(tick: (isFast: boolean) => Promise<void>): void {
    this.#timer ??= this.#ports.every(POLL_MS, () => {
      if (++this.#ticks % TICKS_A_SECOND === 0) this.#isSlowDue = true
      const isFast = !this.#isSlowDue
      if (this.#isPolling || (isFast && !this.#isTarget)) return
      this.#isSlowDue = false
      this.#isPolling = true
      void this.serial(() => tick(isFast))
        .catch((error: unknown) => this.#ports.log(`voice poll failed: ${String(error)}`))
        .finally(() => { this.#isPolling = false })
    })
  }

  stop(): void {
    this.#timer?.cancel()
    this.#timer = null
    this.#ticks = 0
    this.#isSlowDue = false
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
