// Wiring only: engine events to the bridge link, the turn tracker and the band. A hooks module
// passes `$` only to functions declared at its top level, so the session's state lives here too.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Band } from '../types'
import { bandStatus, drawBand, JOINING } from './band.tsx'
import { summarize } from './context.ts'
import { BridgeLink, REMOVED } from './link.ts'
import { askedText, PLUGIN_NAME, spokenReply, voicePrompt } from './prompt.ts'
import { fallbackTitle, recordIndex, titleFromRegistry } from './title.ts'
import { clip, originOf, TurnTracker } from './turns.ts'
import type { TurnOrigin, TurnSnapshot } from './turns.ts'
import { socketPath } from './wire.ts'
import type { VoiceRequest } from './wire.ts'

const OFFLINE_AFTER_MS = 10_000
/** How often a poll looks through the whole registry while this session's record is not found. */
const RESCAN_MS = 10_000
const OPEN_APP = 'Open LiveBridge from the menu bar.'
/**
 * In characters: under the app's 131,072-byte body limit even at four UTF-8 bytes each; the app
 * shortens answers for speech itself.
 */
const ANSWER_LIMIT = 32_000
/** How long a summary may take before the band stops saying it is loading. */
const CONTEXT_TIMEOUT_MS = 60_000
/** How long the band says "Context sent". */
const SENT_NOTE_MS = 3_000
/** How long the polled band may go undrawn before every surface is asked for it again. */
const UNDRAWN_MS = 3_000
const LOST_ANSWER = 'LiveBridge did not get the last answer, so the voice will not say it; it is in this session.'
const NO_SUMMARY = 'LiveBridge could not summarise this session; the voice has no new context.'
const REMOVED_NOTE = 'Removed from LiveBridge. /live on joins again.'
const LATE_REPLY = 'LiveBridge: the reply said by voice came after the question was answered here; Claude did not get it.'
const USAGE = 'Usage: /live on | off | target | status | context'

/** The store key that marks a session as joined; it holds the tracker, so a reload resumes. */
const joinedKey = (sessionId: string) => `joined:${sessionId}`

/** What the band draws (the scan that lists a module's state reads it here, in this file). */
const band = atom({ plugin: 'livebridge', key: 'band' } as const, null)

let link: BridgeLink | null = null
let home = ''
let tracker = new TurnTracker()
let lastOrigin: TurnOrigin | null = null
/** When a surface last asked for the band while this session was joined. */
let drawnAt = 0
/** The visible text of the main loop's last model step: what Claude wrote beside a tool call. */
let stepText = ''
let approval: { tool: string; agent: string | undefined } | null = null
/** Answers the question Claude asked in a voice turn with the owner's spoken reply, while it is open. */
let answerQuestion: ((text: string) => void) | null = null
let offlineSince: number | null = null
/** The mod's own sentence while online; it lasts until the next voice request. */
let note: string | null = null
/** The registry file holding this session's record, once found: each poll reads it alone. */
let recordFile: string | null = null
let lastScan = -Infinity
/**
 * The last summary the model wrote, while no turn has completed since: sending it again costs
 * no model call. Kept in memory only, as the transcript it summarises is the session's own.
 */
let summary: string | null = null
/** Counts completed main turns, so a summary written across one is not kept as current. */
let turnsDone = 0
/** The summary on its way, which a second ask joins instead of asking the model again. */
let sending: Promise<ContextOutcome> | null = null
/** Counts sends; one that timed out is over, and what it wrote later is dropped. */
let sendCount = 0

type ContextOutcome = 'sent' | 'empty' | 'failed'

const setBand = ($: EngineInterface, change: Partial<Band> | null) =>
  update($, band, now => (change === null ? null : { isOffline: false, ...now, ...change }))

async function save($: EngineInterface): Promise<void> {
  if (link?.session) await $.store.set(joinedKey(link.session.sessionId), tracker.snapshot())
}

/**
 * Runs `work` after the link work queued before it (`BridgeLink.serial`): joining, the poll,
 * following the title, a removal and leaving each see the others whole.
 */
function serial<T>(work: () => Promise<T>): Promise<T> {
  return link === null ? work() : link.serial(work)
}

/** Queues `work` without waiting for it; a failure is logged. */
function enqueue($: EngineInterface, work: () => Promise<void>): void {
  void serial(work).catch((error: unknown) => $.ui.log(`LiveBridge: ${String(error)}`))
}

/**
 * The `name` of this session's registry record, read from `*.json` files only (never `*.key`).
 *
 * Fragile by design: `~/.claude/sessions` is Claude Code's private state, not the mod API, and
 * its shape may change in any release (ADR 0001, item e). The API has no call for the title the
 * session list shows; only the classic hook payloads carry an optional `session_title`, and only
 * at a session's start or a prompt, while the desktop app may name a session seconds after
 * either. So the poll follows the record: once found, it reads that one file; until then it looks
 * through them all at most every `RESCAN_MS` (`isPoll`), and answers null when it did not look.
 * Each file is parsed on its own, because Claude Code rewrites them on every status change and
 * one may be empty or half written at any moment.
 */
async function readTitle($: EngineInterface, sessionId: string, isPoll = false): Promise<string | null> {
  const dir = `${home}/.claude/sessions`
  const read = (name: string) => $.fs.read(`${dir}/${name}`).then(text => parseRecord(String(text)), () => null)
  let records: unknown[] = recordFile === null ? [] : [await read(recordFile)]
  if (recordIndex(records, sessionId) < 0) {
    recordFile = null
    const now = await $.clock.now()
    if (isPoll && now - lastScan < RESCAN_MS) return null
    lastScan = now
    const names = (await $.fs.list(dir).catch(() => []))
      .filter(one => one.kind === 'file' && one.name.endsWith('.json')).map(one => one.name)
    records = []
    for (const name of names) records.push(await read(name))
    recordFile = names[recordIndex(records, sessionId)] ?? null
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

/** Joins; `byOwner` when the owner typed /live on (a reload's resume is not their decision). */
async function turnOn($: EngineInterface, byOwner: boolean): Promise<boolean> {
  // What the last join learnt about the app is stale: the owner may have opened or installed it.
  offlineSince = null
  note = null
  const sessionId = await $.session.id()
  const title = (await readTitle($, sessionId)) ?? ''
  // Only the owner's own join brings back a session they removed.
  const isJoined = (await link?.join({ sessionId, title, ...(byOwner && { owner: true }) })) === true
  await save($)
  await setBand($, {})
  redrawBand($)
  link?.start(() => tick($))
  return isJoined
}

/**
 * Asks every surface for the band. Writing the band redraws only the instances that read it: a
 * surface that asked for the band before this hook could run (the desktop app opening a new
 * session asks a process with no hooks), or that dropped it, holds it as drawn by nobody and
 * asks again only when told to.
 */
function redrawBand($: EngineInterface): void {
  $.ui.invalidate('ui.render')
}

async function turnOff($: EngineInterface): Promise<void> {
  link?.stop()
  const joined = link?.session
  // Leaving first forgets the session, so no snapshot is saved for it after its key goes.
  await link?.leave()
  if (joined) await $.store.delete(joinedKey(joined.sessionId))
  await setBand($, null)
}

/**
 * Joins again when its title changed, or when /clear gave the session a new id: that join
 * replaces the old id, so the app keeps the target and the request in flight. `isPoll`: the
 * one-second poll, which looks for the title as cheaply as `readTitle` allows.
 */
async function follow($: EngineInterface, isPoll: boolean): Promise<void> {
  const joined = link?.session
  if (!link || !joined) return
  const sessionId = await $.session.id()
  const isNewId = sessionId !== joined.sessionId
  const title = (await readTitle($, sessionId, isPoll && !isNewId)) ?? joined.title
  if (!isNewId && title === joined.title) return
  if (isNewId) {
    staleSummary()  // /clear: a new transcript
    await $.store.delete(joinedKey(joined.sessionId))
  }
  await link.rejoin({ ...joined, sessionId, title, ...(isNewId && { replaces: joined.sessionId }) })
  await save($)
}

/**
 * One poll: status into the band, a voice request queued as a prompt, a context request
 * answered. It polls before it follows the title: any join clears the app's removal mark, so
 * only a session the app still holds may join again.
 */
async function tick($: EngineInterface): Promise<void> {
  if (!link?.session) return  // it left, or was removed, while this poll waited its turn
  const reply = await link.next()
  if (reply === REMOVED) return  // the link queued `removed`
  if (!reply) {
    const now = await $.clock.now()
    if (offlineSince === null) {
      offlineSince = now
      if (!(await link?.ensureApp())) await setBand($, { problem: OPEN_APP })
    }
    await setBand($, { isOffline: now - offlineSince >= OFFLINE_AFTER_MS })
    return
  }
  offlineSince = null
  await follow($, true)
  const self = link?.session?.sessionId ?? ''
  if (reply.work?.kind === 'request') note = null
  await update($, band, now => ({
    isOffline: false, status: bandStatus(reply.status, self),
    ...(note && { problem: note }), ...(now?.context && { context: now.context }),
  }))
  // That write redraws each surface that shows the band; one that asked for none for a while
  // lost it, and is asked again.
  const at = await $.clock.now()
  if (at - drawnAt >= UNDRAWN_MS) {
    drawnAt = at
    redrawBand($)
  }
  const work = reply.work
  if (work?.kind === 'request') {
    // Queued behind an off or a removal that came in while this poll ran: those fail it in the app.
    enqueue($, () => deliver($, work))
  } else if (work?.kind === 'reply') {
    if (answerQuestion === null) $.ui.log(LATE_REPLY)
    else answerQuestion(spokenReply(work))
  } else if (work?.kind === 'context') {
    void contextAsked($)
  }
}

/** A voice request into a prompt, unless the session left or was removed since the poll. */
async function deliver($: EngineInterface, request: VoiceRequest): Promise<void> {
  if (!link?.session) return
  tracker.submitted(request.id)
  // It resolves once the turn starts, which may be after the running one: do not hold the queue.
  void $.prompt.submit({ text: voicePrompt(request) }).catch(() => refused($, request.id))
  await save($)
}

/** The owner removed this session in the app: off here too, with no leave and no rejoin. */
async function removed($: EngineInterface, sessionId: string): Promise<void> {
  await $.store.delete(joinedKey(sessionId))
  await setBand($, null)
  $.ui.log(REMOVED_NOTE)
}

/** The prompt was refused: the request fails at once, and no later turn counts as its turn. */
async function refused($: EngineInterface, id: string): Promise<void> {
  tracker.refused(id)
  await save($).catch(() => {})  // the answer matters more than the snapshot
  await link?.answer({ id, status: 'failed', text: '', reason: 'Claude Code did not take the prompt' })
}

function staleSummary(): void {
  turnsDone += 1
  summary = null
}

/** The band's note on the summary; undefined takes it down. */
function showContext($: EngineInterface, context: Band['context']) {
  return update($, band, now => {
    if (now === null) return null
    const { context: _, ...rest } = now
    return context === undefined ? rest : { ...rest, context }
  })
}

/** Whether the session has had a prompt: a new one has nothing to summarise. */
async function hasTurns($: EngineInterface): Promise<boolean> {
  try {
    return (await $.session.turns()) > 0
  } catch {
    return true  // not known: the model says when there is nothing
  }
}

/**
 * Sends the session's summary to the app; says what happened and never rejects. `isFresh` asks
 * the model again even when no turn has completed since its last summary. While one is on its
 * way a second ask joins it.
 */
function sendContext($: EngineInterface, isFresh: boolean): Promise<ContextOutcome> {
  sending ??= deliverContext($, isFresh).finally(() => { sending = null })
  return sending
}

async function deliverContext($: EngineInterface, isFresh: boolean): Promise<ContextOutcome> {
  if (!(await hasTurns($))) return 'empty'
  const send = ++sendCount
  await showContext($, 'loading')
  let timer: { cancel(): void } | undefined
  const late = new Promise<'failed'>(resolve => { timer = $.clock.after(CONTEXT_TIMEOUT_MS, () => resolve('failed')) })
  const outcome = await Promise.race([writeAndPost($, isFresh, send), late])
  timer?.cancel()
  if (outcome !== 'sent') sendCount += 1  // a summary this send writes after its time is dropped
  await showContext($, outcome === 'sent' ? 'sent' : undefined)
  if (outcome === 'sent') {
    $.clock.after(SENT_NOTE_MS, () => void (send === sendCount && showContext($, undefined)))
  }
  return outcome
}

async function writeAndPost($: EngineInterface, isFresh: boolean, send: number): Promise<ContextOutcome> {
  try {
    const turns = turnsDone
    const text = !isFresh && summary !== null ? summary : await summarize($)
    if (send !== sendCount) return 'failed'
    if (text === '') return 'empty'
    if (turns === turnsDone) summary = text
    return (await link?.context(text)) === true ? 'sent' : 'failed'
  } catch {
    return 'failed'
  }
}

/** The summary asked for by the app or the band, which have no reply line of their own. */
async function contextAsked($: EngineInterface): Promise<void> {
  // A send that outlived the join (the owner left meanwhile) is no failure worth a line.
  if ((await sendContext($, false)) === 'failed' && link?.session) $.ui.log(NO_SUMMARY)
}

async function statusText($: EngineInterface): Promise<string> {
  const state = await read($, band)
  if (state === null) return 'Voice is off for this session. /live on joins LiveBridge.'
  const status = state.status
  if (!state.isOffline && status === undefined) return JOINING
  if (state.isOffline || status === undefined) return `LiveBridge is not reachable. ${state.problem ?? ''}`.trim()
  return `LiveBridge: ${status.call}; target: ${status.target}; ${status.unheard} unheard; ` +
    `${Math.round(status.minutesToday)} min today.${status.problem ? ` ${status.problem}` : ''}`
}

/** `/live on|off|target|status|context`. */
async function live($: EngineInterface, args: string): Promise<string> {
  // ''.split(/\s+/) is [''], which would leave the default unused.
  const [verb = 'status', option] = args.trim() === '' ? [] : args.trim().split(/\s+/)
  const joined = link?.session
  if (verb === 'status') return statusText($)
  if (verb === 'on') {
    return serial(async () => {
      if (link?.session) {
        redrawBand($)  // the owner's way back to a band the surface lost
        return 'This session has already joined LiveBridge.'
      }
      // No title here: a new session's is still the one Claude Code derives from its folder, and
      // the app shows the name the session is given next, once the poll follows it.
      return (await turnOn($, true))
        ? 'Joined LiveBridge.'
        : 'LiveBridge is not running; the mod opens it and joins as soon as it is up.'
    })
  }
  if (!['off', 'target', 'context'].includes(verb) || option !== undefined) return USAGE
  if (!joined) return 'This session has not joined LiveBridge.'
  if (verb === 'off') {
    await serial(() => turnOff($))
    return 'Left LiveBridge.'
  }
  if (verb === 'target') {
    await link?.target()
    return 'This session is now the voice target.'
  }
  const sent = await sendContext($, true)
  return sent === 'sent' ? 'Sent a summary of this session to LiveBridge.' : sent === 'empty' ? 'Nothing to summarise yet.' : NO_SUMMARY
}

/**
 * The band's Start: a call started from a session talks to that session, and the voice gets the
 * session's summary as the call starts, without holding it up.
 */
async function startHere($: EngineInterface): Promise<void> {
  await link?.target()
  void contextAsked($)
  await link?.call('start')
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
      argumentHint: 'on|off|target|status|context',
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
      removed: sessionId => enqueue($, () => removed($, sessionId)),
    }, {
      socketPath: socketPath(home, await $.env.get('CFFIXED_USER_HOME')),
      appPath: '/Applications/LiveBridge.app',
    })
    // A hot reload runs this again with the module's variables gone; the store kept the join.
    const saved = await $.store.get(joinedKey(await $.session.id()))
    if (saved !== undefined) {
      tracker = new TurnTracker(saved as TurnSnapshot)
      await serial(() => turnOn($, false))
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

  // The hooks at sites that can refuse only observe: one that fails lets the event go on.
  on('prompt.submit', ($, e, next) => {
    // A delivery into a running turn starts no turn of its own.
    if (e.turnId === undefined) lastOrigin = originOf(e.origin, PLUGIN_NAME)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) {
      // A turn with no origin seen is treated as typed: its answer never reaches the voice.
      tracker.turnStarted(e.turnId, e.text, lastOrigin ?? 'typed', await $.clock.now())
      lastOrigin = null
      await serial(() => follow($, false))
      await save($)
      await link?.activity('working')
    }
    return next(e)
  })

  // The engine's turn.complete carries only the turn's last text, and a question only its
  // options: what Claude wrote in the step that asks would reach the voice in neither.
  on('turn.step', async function* ($, e, next) {
    const result = yield* next(e)
    if (e.agentId === undefined) stepText = result.answer
    return result
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      const post = tracker.turnCompleted(e.turnId, e.answer, e.reason)
      staleSummary()
      approval = null
      await save($)
      const taken = post && (await link?.answer({ ...post, text: clip(post.text, ANSWER_LIMIT) }))
      // An update to a request a newer one replaced is refused by design; a removal says so itself.
      if (post && taken !== true && taken !== REMOVED && post.status !== 'update') {
        note = LOST_ANSWER
        $.ui.log(LOST_ANSWER)
      }
      await link?.activity('idle')
    }
    return next(e)
  })

  // A question Claude asks in a voice turn goes to the voice as well, and the dialog stays open
  // for the keyboard: the reply that comes first answers it. A spoken reply is the dialog's
  // free text, so the owner may ask back instead of choosing; returning before the dialog's
  // own answer closes it.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    if (e.agentId !== undefined || tracker.running === null || !link?.session) return next(e)
    const answered = next(e)
    const spoken = new Promise<string>(resolve => { answerQuestion = resolve })
    const id = tracker.running
    const said = stepText.trim()
    stepText = ''
    try {
      // What Claude wrote before asking goes first, as an update that leaves the request open.
      if (said !== '') await link.answer({ id, status: 'update', text: clip(said, ANSWER_LIMIT) })
      await link.activity('approval', askedText(e.questions))
      const first = await Promise.race([answered, spoken])
      return typeof first === 'string' ? { result: { questions: e.questions, answers: {}, response: first } } : first
    } finally {
      answerQuestion = null
      await link?.activity('working')
    }
  }).catch(($, e, next) => next(e))

  // ADR 0001 (i): a permission request that reaches the person during a voice turn. Claude's
  // question has its own report above.
  on('classic.PermissionRequest', async ($, e, next) => {
    if (tracker.running !== null && e.tool_name !== 'AskUserQuestion') {
      approval = { tool: e.tool_name, agent: e.agent_id }
      await link?.activity('approval')
    }
    return next(e)
  }).catch(($, e, next) => next(e))
  on('classic.PostToolUse', async ($, e, next) => (settles(e) && (await link?.activity('working')), next(e)))
    .catch(($, e, next) => next(e))
  on('classic.PostToolUseFailure', async ($, e, next) => (settles(e) && (await link?.activity('working')), next(e)))
    .catch(($, e, next) => next(e))
  on('classic.PermissionDenied', async ($, e, next) => (settles(e) && (await link?.activity('working')), next(e)))
    .catch(($, e, next) => next(e))

  on('session.end', async ($, e, next) => {
    // After /clear the session goes on under a new id: the next poll leaves the old one and joins.
    if (e.reason !== 'clear') await serial(() => turnOff($))
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const state = await read($, band)
    if (state === null || !link?.session) return next(e)
    drawnAt = await $.clock.now()
    if (e.props.hasSurvey) return next(e)
    return drawBand($, e, state, {
      start: () => void startHere($),
      stop: () => void link?.call('stop'),
      target: () => void link?.target(),
    })
  })
}
