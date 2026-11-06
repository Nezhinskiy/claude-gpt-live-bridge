// Wiring only: engine events to the bridge link, the turn tracker and the band. A hooks module
// passes `$` only to functions declared at its top level, so the session's state lives here too.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Band } from '../types'
import { bandStatus, drawBand, JOINING } from './band.tsx'
import { summarize } from './context.ts'
import { BridgeLink, REMOVED } from './link.ts'
import { askedText, keyboardAnswer, PLUGIN_NAME, spokenReply, voicePrompt } from './prompt.ts'
import { fallbackTitle, recordIndex, titleFromRegistry } from './title.ts'
import { ANSWER_LIMIT, clip, originOf, TurnTracker } from './turns.ts'
import type { SyncLine, TurnOrigin, TurnSnapshot } from './turns.ts'
import { socketPath } from './wire.ts'
import type { AnswerStatus, VoiceRequest, Work } from './wire.ts'

const OFFLINE_AFTER_MS = 10_000
/** How often a poll looks through the whole registry while this session's record is not found. */
const RESCAN_MS = 10_000
const OPEN_APP = 'Open LiveBridge from the menu bar.'
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
const ANSWERED_HERE = 'the question was answered at the keyboard'
const UNREAD_VERSION = 'LiveBridge: the mod could not read its version from its plugin.json; Settings will list this session as on the old mod.'
const USAGE = 'Usage: /live on | off | target | status | context'

type Reply = Extract<Work, { kind: 'reply' }>

/** The store key that marks a session as joined; it holds the tracker, so a reload resumes. */
const joinedKey = (sessionId: string) => `joined:${sessionId}`

/** What the band draws (the scan that lists a module's state reads it here, in this file). */
const band = atom({ plugin: 'livebridge', key: 'band' } as const, null)

let link: BridgeLink | null = null
let home = ''
/** This mod's version, from its own plugin.json at load, for the app's Settings; undefined if unread. */
let modVersion: string | undefined
let tracker = new TurnTracker()
let lastOrigin: TurnOrigin | null = null
/** That `prompt.submit`'s text, what was typed: a slash command's `turn.start` holds its expansion. */
let lastPrompt: string | undefined
/** When a surface last asked for the band while this session was joined. */
let drawnAt = 0
let approval: { tool: string; agent: string | undefined } | null = null
/** Answers the question Claude asked in the running turn with the owner's spoken reply, while it is open. */
let answerQuestion: ((reply: Reply) => void) | null = null
let offlineSince: number | null = null
/** The mod's own sentence while online; it lasts until the next voice request. */
let note: string | null = null
/** The registry file holding this session's record, once found: each poll reads it alone. */
let recordFile: string | null = null
let lastScan = -Infinity
/**
 * The last summary the model wrote, while nothing has happened since: until any main turn
 * completes, or `/clear`. Sending it again costs no model call. Kept in memory only, as the
 * transcript it summarises is the session's own.
 */
let summary: string | null = null
/** Counts what ends a summary's use, so a summary written across one is not kept as current. */
let turnsDone = 0
/** The summary on its way, which a second ask joins instead of asking the model again. */
let sending: Promise<ContextOutcome> | null = null
/** Counts sends; one that timed out is over, and what it wrote later is dropped. */
let sendCount = 0

type ContextOutcome = 'sent' | 'empty' | 'failed'

const setBand = ($: EngineInterface, change: Partial<Band> | null) =>
  update($, band, now => (change === null ? null : { isOffline: false, ...now, ...change }))

async function save($: EngineInterface): Promise<void> {
  if (link?.session) await $.store.set(joinedKey(link.session.sessionId), { ...tracker.snapshot(), hasGap: link.hasGap })
}

/** For a hook past its `next`, whose `.catch` would run the event again: the snapshot matters less. */
const trySave = ($: EngineInterface) => save($).catch(() => {})

/** Posts a line of a turn; one the app did not take is a gap, which the next join says. */
async function postSync($: EngineInterface, line: SyncLine): Promise<void> {
  if ((await link?.sync({ ...line, text: clip(line.text, ANSWER_LIMIT) })) === true) return
  link?.noteGap()
  await trySave($)
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
  const read = (name: string) => readJSON($, `${dir}/${name}`)
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

/** The JSON in the file at `path`, or null when it cannot be read or parsed. */
function readJSON($: EngineInterface, path: string): Promise<unknown> {
  return $.fs.read(path).then(text => parseRecord(String(text)), () => null)
}

function parseRecord(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

/**
 * The version in this mod's plugin.json, read when the module loads, so it is the version of the
 * code that runs; undefined, and said, when it cannot be read: Settings then lists the session
 * as on the old mod.
 */
async function ownVersion($: EngineInterface): Promise<string | undefined> {
  const manifest = await readJSON($, `${$.plugin.root}/.claude-plugin/plugin.json`)
  const version = (manifest as { version?: unknown } | null)?.version
  if (typeof version === 'string') return version
  $.ui.log(UNREAD_VERSION)
  return undefined
}

/** Joins; `byOwner` when the owner typed /live on (a reload's resume is not their decision). */
async function turnOn($: EngineInterface, byOwner: boolean): Promise<boolean> {
  // What the last join learnt about the app is stale: the owner may have opened or installed it.
  offlineSince = null
  note = null
  const sessionId = await $.session.id()
  const title = (await readTitle($, sessionId)) ?? ''
  // The app got no turn from before the owner's join; a reload's gap is in its snapshot.
  if (byOwner && (await hasTurns($))) link?.noteGap()
  // Only the owner's own join brings back a session they removed.
  const isJoined = (await link?.join({ sessionId, title, modVersion, syncs: true, ...(byOwner && { owner: true }) })) === true
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
  const hadGap = link.hasGap
  const reply = await link.next()
  if (reply === REMOVED) return  // the link queued `removed`
  if (hadGap && !link.hasGap) await save($)  // a join said it: a reload must not say it again
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
    if (answerQuestion !== null) {
      answerQuestion(work)
    } else {
      $.ui.log(LATE_REPLY)
      // The app opened a request for a reply to a typed turn; a voice turn's refuses this, harmlessly.
      await link?.answer({ id: work.id, status: 'failed', text: '', reason: ANSWERED_HERE })
    }
  } else if (work?.kind === 'context') {
    void contextAsked($)
  }
}

/**
 * The app took neither a turn's answer nor, so, its place in the conversation. An update to a
 * request a newer one replaced is refused by design, so only a result is said to be lost.
 */
async function answerLost($: EngineInterface, status: AnswerStatus): Promise<void> {
  link?.noteGap()
  await save($)
  if (status === 'update') return
  note = LOST_ANSWER
  $.ui.log(LOST_ANSWER)
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
  await trySave($)  // the answer matters more than the snapshot
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

/** The summary asked for by the app, which has no reply line of its own. */
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
 * The band's Start: a call started from a session talks to that session. The line the app opens
 * asks for the session's context itself.
 */
async function startHere(): Promise<void> {
  await link?.target()
  await link?.call('start')
}

/** What the step that pauses wrote, as the activity's `text`; none when it wrote nothing. */
const wrote = (text: string) => (text === '' ? {} : { text })

/** Names a main-loop turn that is not a voice turn: the app decides on it as on its lines. */
const typedTurn = ({ turnId, isVoice }: { turnId: string; isVoice: boolean }) => (isVoice ? {} : { typedTurn: turnId })

/** Whether a tool's run, failure or denial settles the permission request being reported. */
function settles(e: { tool_name: string; agent_id?: string }): boolean {
  if (approval?.tool !== e.tool_name || approval.agent !== e.agent_id) return false
  approval = null
  return true
}

/** A settled prompt: a line of the owner's for the running turn, and the session works on. */
async function promptSettled($: EngineInterface, text: string): Promise<void> {
  const turn = tracker.current
  if (turn) await postSync($, { turnId: turn.turnId, from: 'owner', text })
  await link?.activity('working')
}

/** The tool ran, or failed, so the prompt was allowed. */
async function toolRan($: EngineInterface, e: { tool_name: string; agent_id?: string }): Promise<void> {
  if (settles(e)) await promptSettled($, `You allowed ${e.tool_name} at the keyboard.`)
}

/**
 * The next main step, or the turn's end, with the main loop's prompt still open: no tool ran and
 * the dialog is gone. No hook reports a person's No (ADR 0001, item i), so it is only settled.
 */
async function promptGone($: EngineInterface): Promise<void> {
  if (approval === null || approval.agent !== undefined) return
  const { tool } = approval
  approval = null
  await promptSettled($, `The permission prompt for ${tool} was settled at the keyboard.`)
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
    modVersion = await ownVersion($)
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
      // A snapshot from before sync says nothing: none of its turns reached the app.
      if ((saved as { hasGap?: boolean }).hasGap !== false) link.noteGap()
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
  on('prompt.submit', async ($, e, next) => {
    const origin = originOf(e.origin, PLUGIN_NAME, e.isMeta)
    if (e.turnId === undefined) {
      lastOrigin = origin
      lastPrompt = e.text
    }
    const entered = await next(e)
    // Whether it folds in or gets a turn of its own, it goes to the app now, under the running turn.
    if (e.turnId !== undefined && origin === 'owner' && entered.drop === undefined) {
      await postSync($, tracker.typedInto(e.turnId, e.text))
      await trySave($)
    }
    return entered
  }).catch(($, e, next) => next(e))

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) {
      const line = tracker.turnStarted(e.turnId, e.text, lastOrigin, await $.clock.now(), lastPrompt)
      lastOrigin = null
      lastPrompt = undefined
      await serial(() => follow($, false))  // /clear: the line goes under the session's new id
      await save($)
      if (line) await postSync($, line)
      await link?.activity('working')
    }
    return next(e)
  })

  // The engine's turn.complete carries only the turn's last text, and a question or a permission
  // prompt only itself: what Claude wrote in the step that asks would reach the voice in neither.
  // Kept as it streams, since the engine may run the step's tools before the step ends.
  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined) return yield* next(e)
    tracker.stepStarted()
    await promptGone($)
    const stream = next(e)
    let block: number | undefined
    for await (const chunk of stream) {
      if (chunk.kind === 'text') {
        tracker.streamed(block === undefined || block === chunk.index ? chunk.text : `\n${chunk.text}`)
        block = chunk.index
      }
      yield chunk
    }
    return stream.result
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      await promptGone($)
      const { post, sync } = tracker.turnCompleted(e.turnId, e.answer, e.reason)
      staleSummary()
      approval = null
      answerQuestion = null  // a question cancelled at the dialog may leave its tool's call unfinished
      await save($)
      if (sync) await postSync($, sync)
      const taken = post && (await link?.answer({ ...post, text: clip(post.text, ANSWER_LIMIT) }))
      if (post && taken !== true && taken !== REMOVED) await answerLost($, post.status)
      await link?.activity('idle')
    }
    return next(e)
  })

  // A question Claude asks in a main-loop turn goes to the voice as well, and the dialog stays
  // open for the keyboard: the reply that comes first answers it. A spoken reply is the dialog's
  // free text, so the owner may ask back instead of choosing; returning before the dialog's own
  // answer closes it. It also tells the tracker whose answer the rest of the turn is.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const turn = tracker.current
    if (e.agentId !== undefined || turn === null || !link?.session) return next(e)
    const answered = next(e)
    const spoken = new Promise<Reply>(resolve => { answerQuestion = resolve })
    try {
      await link.activity('approval', {
        question: askedText(e.questions), ...wrote(tracker.takeStepText()), ...typedTurn(turn),
      })
      // Over at once: a reply from here on has no question, whatever posting the answer takes.
      const first = await Promise.race([answered, spoken]).finally(() => { answerQuestion = null })
      if ('kind' in first) {
        tracker.replied(first.id, first.forRequest, await $.clock.now())
        await trySave($)
        return { result: { questions: e.questions, answers: {}, response: spokenReply(first) } }
      }
      const result = first.isError === true ? undefined : first.result
      await postSync($, { turnId: turn.turnId, from: 'owner', text: keyboardAnswer(result) })
      return first
    } finally {
      await link?.activity('working')
    }
  }).catch(($, e, next) => next(e))

  // ADR 0001 (i): a permission request that reaches the person during a main-loop turn, with what
  // the main loop wrote in the step that asks for it. Claude's question has its own report above.
  // A subagent's is no step of the main loop's: it carries neither that text nor the turn.
  on('classic.PermissionRequest', async ($, e, next) => {
    const turn = tracker.current
    if (turn !== null && link?.session && e.tool_name !== 'AskUserQuestion') {
      approval = { tool: e.tool_name, agent: e.agent_id }
      const said = e.agent_id === undefined ? { ...wrote(tracker.takeStepText()), ...typedTurn(turn) } : {}
      await link.activity('approval', said)
    }
    return next(e)
  }).catch(($, e, next) => next(e))
  on('classic.PostToolUse', async ($, e, next) => (await toolRan($, e), next(e)))
    .catch(($, e, next) => next(e))
  on('classic.PostToolUseFailure', async ($, e, next) => (await toolRan($, e), next(e)))
    .catch(($, e, next) => next(e))
  // Auto mode's refusal, not the person's: nothing to tell the voice but that it goes on.
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
      start: () => void startHere(),
      stop: () => void link?.call('stop'),
      mute: () => void link?.call('mute'),
      unmute: () => void link?.call('unmute'),
      target: () => void link?.target(),
    })
  })
}
