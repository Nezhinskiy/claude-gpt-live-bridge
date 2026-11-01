// The mod's side of the bridge: HTTP over the app's Unix socket, the app's launch, and the
// one-second poll loop. Each call answers what happened and never throws.
import type { HttpInit, HttpResponse, ProcessRunResult, Timer } from 'claude-code'

import type { AnswerBody, CallAction, JoinBody, PollReply, SessionActivity } from './wire.ts'

/** LiveBridge.app's bundle identifier. */
export const BUNDLE_ID = 'io.github.nezhinskiy.livebridge'
const POLL_MS = 1000

/**
 * The engine calls the link makes. A hooks module spells every call `$.noun.event(...)` where
 * it is made, so the hook that creates the link hands it these instead of `$` itself.
 */
export type LinkPorts = {
  fetch(url: string, init: HttpInit): Promise<HttpResponse>
  run(argv: readonly string[]): Promise<ProcessRunResult>
  every(ms: number, fn: () => void): Timer
  log(text: string): void
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

  /** `appPath`: where build-app.sh installs the app. */
  constructor(ports: LinkPorts, paths: { socketPath: string; appPath: string }) {
    this.#ports = ports
    this.#socketPath = paths.socketPath
    this.#appPath = paths.appPath
  }

  get session(): JoinBody | null {
    return this.#joined
  }

  /** Joins, or joins again under a new id or title; true when the app took it. */
  async join(body: JoinBody): Promise<boolean> {
    const { replaces: _, ...kept } = body  // a later join (after an app restart) replaces nothing
    this.#joined = kept
    this.#isKnown = (await this.#send('join', body))?.ok === true
    return this.#isKnown
  }

  async leave(): Promise<void> {
    const joined = this.#joined
    this.#joined = null
    this.#isKnown = false
    if (joined !== null) await this.#send('leave', { sessionId: joined.sessionId })
  }

  /**
   * One poll: the app's status and any work for this session, or null while the app is out of
   * reach. A session the app does not know (it restarted) joins again first.
   */
  async next(retry = true): Promise<PollReply | null> {
    const joined = this.#joined
    if (joined === null || (!this.#isKnown && !(await this.join(joined)))) return null
    const reply = await this.#send(`next?sessionId=${encodeURIComponent(joined.sessionId)}`)
    if (reply?.ok === true) return parse(reply.text)
    this.#isKnown = false
    return reply?.status === 404 && retry ? this.next(false) : null
  }

  /** Posts an answer; false when the app did not take it (out of reach, restarted, or ended). */
  async answer(post: Omit<AnswerBody, 'sessionId'>): Promise<boolean> {
    const reply = await this.#forSession('answer', post)
    if (reply?.status === 404) this.#isKnown = false
    return reply?.ok === true
  }

  async activity(state: SessionActivity): Promise<void> {
    await this.#forSession('activity', { state })
  }

  async context(summary: string): Promise<void> {
    await this.#forSession('context', { summary })
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

  /** Runs `tick` every second until `stop`, never two at once. */
  start(tick: () => Promise<void>): void {
    this.#timer ??= this.#ports.every(POLL_MS, () => {
      if (this.#isPolling) return
      this.#isPolling = true
      void tick()
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

  /** A POST with a JSON body, or a GET without one; null when the socket is out of reach. */
  async #send(route: string, body?: object) {
    const init: HttpInit = body === undefined
      ? { socketPath: this.#socketPath }
      : {
          method: 'POST', socketPath: this.#socketPath,
          headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
        }
    try {
      return await this.#ports.fetch(`http://bridge/v1/${route}`, init)
    } catch {
      return null
    }
  }
}

function parse(text: string): PollReply | null {
  try {
    return JSON.parse(text) as PollReply
  } catch {
    return null
  }
}
