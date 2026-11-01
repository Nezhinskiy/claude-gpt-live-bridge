// Wiring only: engine events to the bridge link, the turn tracker and the band. A hooks module
// passes `$` only to functions declared at its top level, so the session's state lives here too.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Band } from '../types'
import { bandStatus, drawBand } from './band.tsx'
import { summarize } from './context.ts'
import { BridgeLink } from './link.ts'
import { PLUGIN_NAME, voicePrompt } from './prompt.ts'
import { fallbackTitle, titleFromRegistry } from './title.ts'
import { clip, originOf, TurnTracker } from './turns.ts'
import type { TurnOrigin, TurnSnapshot } from './turns.ts'
import { socketPath } from './wire.ts'

const OFFLINE_AFTER_MS = 10_000
const OPEN_APP = 'Open LiveBridge from the menu bar.'
/**
 * In characters: under the app's 131,072-byte body limit even at four UTF-8 bytes each; the app
 * shortens answers for speech itself.
 */
const ANSWER_LIMIT = 32_000
const AUTO_CONTEXT = 'autoContext'
const LOST_ANSWER = 'LiveBridge did not get the last answer, so the voice will not say it; it is in this session.'
const NO_SUMMARY = 'LiveBridge could not summarise this session; the voice has no new context.'
const USAGE = 'Usage: /live on | off | target | status | context [auto|manual]'

/** The store key that marks a session as joined; it holds the tracker, so a reload resumes. */
const joinedKey = (sessionId: string) => `joined:${sessionId}`

/** What the band draws (the scan that lists a module's state reads it here, in this file). */
const band = atom({ plugin: 'livebridge', key: 'band' } as const, null)

let link: BridgeLink | null = null
let home = ''
let tracker = new TurnTracker()
let lastOrigin: TurnOrigin | null = null
let approval: { tool: string; agent: string | undefined } | null = null
let offlineSince: number | null = null
/** The mod's own sentence while online; it lasts until the next voice request. */
let note: string | null = null
/**
 * Counts joins and leaves. Work that awaited across one (a poll in flight when the owner left)
 * belongs to a join that is over, so it stops there instead of acting on the app's reply.
 */
let generation = 0

const setBand = ($: EngineInterface, change: Partial<Band> | null) =>
  update($, band, now => (change === null ? null : { isOffline: false, ...now, ...change }))

async function save($: EngineInterface): Promise<void> {
  if (link?.session) await $.store.set(joinedKey(link.session.sessionId), tracker.snapshot())
}

/**
 * The `name` of this session's registry record, read from `*.json` files only (never `*.key`).
 *
 * Fragile by design: `~/.claude/sessions` is Claude Code's private state, not the mod API, and
 * its shape may change in any release (ADR 0001, item e). The API has no call for the title the
 * session list shows; only the classic hook payloads carry an optional `session_title`, and only
 * at a session's start or a prompt. Each file is parsed on its own, because Claude Code rewrites
 * them on every status change and one may be empty or half written at any moment.
 */
async function readTitle($: EngineInterface, sessionId: string): Promise<string> {
  const dir = `${home}/.claude/sessions`
  const entries = await $.fs.list(dir).catch(() => [])
  const records: unknown[] = []
  for (const entry of entries.filter(one => one.kind === 'file' && one.name.endsWith('.json'))) {
    records.push(await $.fs.read(`${dir}/${entry.name}`).then(text => parseRecord(String(text)), () => null))
  }
  return titleFromRegistry(records, sessionId) ?? fallbackTitle(await $.session.cwd())
}

function parseRecord(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

async function turnOn($: EngineInterface): Promise<boolean> {
  generation += 1
  // What the last join learnt about the app is stale: the owner may have opened or installed it.
  offlineSince = null
  note = null
  const sessionId = await $.session.id()
  const autoContext = (await $.store.get(AUTO_CONTEXT)) === true
  const isJoined = (await link?.join({ sessionId, title: await readTitle($, sessionId), autoContext })) === true
  await save($)
  await setBand($, {})
  link?.start(() => tick($))
  return isJoined
}

async function turnOff($: EngineInterface): Promise<void> {
  generation += 1
  link?.stop()
  if (link?.session) await $.store.delete(joinedKey(link.session.sessionId))
  await link?.leave()
  await setBand($, null)
}

/**
 * Joins again when, when asked, its title changed, or when /clear gave the session a new id:
 * that join replaces the old id, so the app keeps the target and the request in flight.
 */
async function follow($: EngineInterface, isTitleChecked: boolean): Promise<void> {
  const joined = link?.session
  const live = generation
  if (!link || !joined) return
  const sessionId = await $.session.id()
  const isNewId = sessionId !== joined.sessionId
  if (!isNewId && !isTitleChecked) return
  const title = await readTitle($, sessionId)
  if (live !== generation || (!isNewId && title === joined.title)) return
  if (isNewId) await $.store.delete(joinedKey(joined.sessionId))
  await link.join({ ...joined, sessionId, title, ...(isNewId && { replaces: joined.sessionId }) })
  await save($)
}

/** One poll: status into the band, a voice request into a prompt, a context request answered. */
async function tick($: EngineInterface): Promise<void> {
  const live = generation
  await follow($, false)
  const reply = await link?.next()
  if (live !== generation) return
  if (!reply) {
    const now = await $.clock.now()
    if (offlineSince === null) {
      offlineSince = now
      const isOpened = await link?.ensureApp()
      if (live !== generation) return
      if (!isOpened) await setBand($, { problem: OPEN_APP })
    }
    if (live === generation) await setBand($, { isOffline: now - offlineSince >= OFFLINE_AFTER_MS })
    return
  }
  offlineSince = null
  const self = link?.session?.sessionId ?? ''
  if (reply.work?.kind === 'request') note = null
  await update($, band, () => ({ isOffline: false, status: bandStatus(reply.status, self), ...(note && { problem: note }) }))
  if (reply.work?.kind === 'request') {
    tracker.submitted(reply.work.id)
    await save($)
    // It resolves once the turn starts, which may be after the running one: do not hold the poll.
    const id = reply.work.id
    void $.prompt.submit({ text: voicePrompt(reply.work) }).catch(() => refused($, id))
  } else if (reply.work?.kind === 'context') {
    void contextAsked($)
  }
}

/** The prompt was refused: the request fails at once, and no later turn counts as its turn. */
async function refused($: EngineInterface, id: string): Promise<void> {
  tracker.refused(id)
  await save($).catch(() => {})  // the answer matters more than the snapshot
  await link?.answer({ id, status: 'failed', text: '', reason: 'Claude Code did not take the prompt' })
}

/** Sends the session's summary to the app; says what happened and never rejects. */
async function sendContext($: EngineInterface): Promise<'sent' | 'empty' | 'failed'> {
  try {
    const summary = await summarize($)
    if (summary === '') return 'empty'
    await link?.context(summary)
    return 'sent'
  } catch {
    return 'failed'
  }
}

/** The summary asked for by the app or the band, which have no reply line of their own. */
async function contextAsked($: EngineInterface): Promise<void> {
  if ((await sendContext($)) === 'failed') $.ui.log(NO_SUMMARY)
}

async function statusText($: EngineInterface): Promise<string> {
  const state = await read($, band)
  if (state === null) return 'Voice is off for this session. /live on joins LiveBridge.'
  const status = state.status
  if (!state.isOffline && status === undefined) return 'LiveBridge: joining…'
  if (state.isOffline || status === undefined) return `LiveBridge is not reachable. ${state.problem ?? ''}`.trim()
  return `LiveBridge: ${status.call}; target: ${status.target}; ${status.unheard} unheard; ` +
    `${Math.round(status.minutesToday)} min today.${status.problem ? ` ${status.problem}` : ''}`
}

/** `/live on|off|target|status|context [auto|manual]`. */
async function live($: EngineInterface, args: string): Promise<string> {
  // ''.split(/\s+/) is [''], which would leave the default unused.
  const [verb = 'status', option] = args.trim() === '' ? [] : args.trim().split(/\s+/)
  const joined = link?.session
  if (verb === 'status') return statusText($)
  if (verb === 'on') {
    if (joined) return 'This session has already joined LiveBridge.'
    return (await turnOn($))
      ? `Joined LiveBridge as “${link?.session?.title}”.`
      : 'LiveBridge is not running; the mod opens it and joins as soon as it is up.'
  }
  if (verb === 'context' && (option === 'auto' || option === 'manual')) {
    await $.store.set(AUTO_CONTEXT, option === 'auto')
    if (joined) await link?.join({ ...joined, autoContext: option === 'auto' })
    return `Context is now loaded ${option === 'auto' ? 'automatically' : 'on request'}.`
  }
  if (!['off', 'target', 'context'].includes(verb) || option !== undefined) return USAGE
  if (!joined) return 'This session has not joined LiveBridge.'
  if (verb === 'off') {
    await turnOff($)
    return 'Left LiveBridge.'
  }
  if (verb === 'target') {
    await link?.target()
    return 'This session is now the voice target.'
  }
  const sent = await sendContext($)
  return sent === 'sent' ? 'Sent a summary of this session to LiveBridge.' : sent === 'empty' ? 'Nothing to summarise yet.' : NO_SUMMARY
}

/** Whether a tool's run, failure or denial settles the permission request being reported. */
function settles(e: { tool_name: string; agent_id?: string }): boolean {
  if (approval?.tool !== e.tool_name || approval.agent !== e.agent_id) return false
  approval = null
  return true
}

/**
 * Declares `/live`. Not `/voice`: that is Claude Code's own command (voice mode), and the engine
 * refuses a built-in's name. Declaring again replaces the command, so this may run any number of
 * times; a refusal is logged and stops nothing else.
 */
async function declareCommand($: EngineInterface): Promise<void> {
  try {
    await $.command.register({
      name: 'live',
      description: 'Talk to this session by voice through LiveBridge',
      argumentHint: 'on|off|target|status|context [auto|manual]',
    })
  } catch (error) {
    $.ui.log(`LiveBridge could not declare /live: ${String(error)}`)
  }
}

export const register: Register = on => {
  // Runs at the session's start and again whenever this module loads into a running session
  // (enabled, reloaded or its worker respawned), so a session open before the mod has /live too.
  on('session.start', async ($, e, next) => {
    await declareCommand($)
    home = (await $.env.get('HOME')) ?? ''
    link = new BridgeLink({
      fetch: (url, init) => $.http.fetch(url, init),
      run: argv => $.process.run(argv),
      every: (ms, fn) => $.clock.every(ms, fn),
      log: text => $.ui.log(text),
    }, {
      socketPath: socketPath(home, await $.env.get('CFFIXED_USER_HOME')),
      appPath: `${home}/Applications/LiveBridge.app`,
    })
    // A hot reload runs this again with the module's variables gone; the store kept the join.
    const saved = await $.store.get(joinedKey(await $.session.id()))
    if (saved !== undefined) {
      tracker = new TurnTracker(saved as TurnSnapshot)
      await turnOn($)
    }
    return next(e)
  })

  on('command.run', { command: 'live' }, async ($, e) => ({ text: await live($, e.args) }))

  // A client that attaches after the command was declared (the desktop app opening a session
  // the mod loaded into earlier) hears it announced again.
  on('session.attach', async ($, e, next) => {
    await declareCommand($)
    return next(e)
  })

  on('prompt.submit', ($, e, next) => {
    // A delivery into a running turn starts no turn of its own.
    if (e.turnId === undefined) lastOrigin = originOf(e.origin, PLUGIN_NAME)
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) {
      // A turn with no origin seen is treated as typed: its answer never reaches the voice.
      tracker.turnStarted(e.turnId, e.text, lastOrigin ?? 'typed', await $.clock.now())
      lastOrigin = null
      await follow($, true)
      await save($)
      await link?.activity('working')
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      const post = tracker.turnCompleted(e.turnId, e.answer, e.reason)
      approval = null
      await save($)
      if (post && !(await link?.answer({ ...post, text: clip(post.text, ANSWER_LIMIT) })) && post.status !== 'update') {
        note = LOST_ANSWER  // an update to a request a newer one replaced is refused by design
        $.ui.log(LOST_ANSWER)
      }
      await link?.activity('idle')
    }
    return next(e)
  })

  // ADR 0001 (i): a permission request that reaches the person during a voice turn.
  on('classic.PermissionRequest', async ($, e, next) => {
    if (tracker.current !== null) {
      approval = { tool: e.tool_name, agent: e.agent_id }
      await link?.activity('approval')
    }
    return next(e)
  })
  on('classic.PostToolUse', async ($, e, next) => (settles(e) && (await link?.activity('working')), next(e)))
  on('classic.PostToolUseFailure', async ($, e, next) => (settles(e) && (await link?.activity('working')), next(e)))
  on('classic.PermissionDenied', async ($, e, next) => (settles(e) && (await link?.activity('working')), next(e)))

  on('session.end', async ($, e, next) => {
    // After /clear the session goes on under a new id: the next poll leaves the old one and joins.
    if (e.reason !== 'clear') await turnOff($)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const state = await read($, band)
    if (state === null || e.props.hasSurvey || !link?.session) return next(e)
    return drawBand($, e, state, {
      call: action => void link?.call(action),
      target: () => void link?.target(),
      loadContext: () => void contextAsked($),
    })
  })
}
