// Wiring only: engine events to the bridge link, the turn tracker and the band. A hooks module
// passes `$` only to functions declared at its top level, so the session's state lives here too.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, SessionRateLimit } from 'claude-code'

import type { Band } from '../types'
import { bandStatus, drawBand, JOINING } from './band.tsx'
import { checkModel, summarize } from './context.ts'
import type { Summary } from './context.ts'
import { BridgeLink, REMOVED } from './link.ts'
import { askedText, keyboardAnswer, PLUGIN_NAME, spokenReply, voicePrompt } from './prompt.ts'
import { fallbackTitle, recordIndex, titleFromRegistry } from './title.ts'
import { ANSWER_LIMIT, clip, originOf, TurnTracker } from './turns.ts'
import type { SyncLine, TurnOrigin, TurnSnapshot } from './turns.ts'
import { socketPath } from './wire.ts'
import type {
  ActivityBody, AnswerStatus, LimitWindowBody, SummaryFailure, TurnRef, VoiceRequest, Work,
} from './wire.ts'

const OFFLINE_AFTER_MS = 10_000
/** How often a poll looks through the whole registry while this session's record is not found. */
const RESCAN_MS = 10_000
const OPEN_APP = 'Open LiveBridge from the menu bar.'
/** How long a summary may take: the models an ask names share it, and a fork is given up after it. */
const CONTEXT_TIMEOUT_MS = 60_000
/** How long the band says "Context sent". */
const SENT_NOTE_MS = 3_000
/** How long the polled band may go undrawn before every surface is asked for it again. */
const UNDRAWN_MS = 3_000
/** How long a hook waits for its posts to the app before it lets the engine go on. */
const HOOK_HOLD_MS = 200
const LOST_ANSWER = 'LiveBridge did not get the last answer, so the voice will not say it; it is in this session.'
const NO_SUMMARY = 'LiveBridge could not summarise this session; the voice has no new context.'
const REMOVED_NOTE = 'Removed from LiveBridge. /live joins again.'
const LATE_REPLY = 'LiveBridge: the reply said by voice came after the question was answered here; Claude did not get it.'
const ANSWERED_HERE = 'the question was answered at the keyboard'
const UNREAD_VERSION = 'LiveBridge: the mod could not read its version from its plugin.json; Settings will list this session as on the old mod.'
const USAGE = 'Usage: /live | /live off'

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
/**
 * The `prompt.submit` that will start the next turn: its origin, and what was typed, as a slash
 * command's `turn.start` holds its expansion.
 */
let lastSubmit: { origin: TurnOrigin; text: string } | null = null
/** When a surface last asked for the band while this session was joined. */
let drawnAt = 0
/** Answers the question Claude asked in the running turn with the owner's spoken reply, while it is open. */
let answerQuestion: ((reply: Reply) => void) | null = null
let offlineSince: number | null = null
/** The mod's own sentence while online; it lasts until the next voice request. */
let note: string | null = null
/** The registry file holding this session's record, once found: each poll reads it alone. */
let recordFile: string | null = null
let lastScan = -Infinity
/**
 * The last summary a model wrote, while nothing has happened since: until any main turn completes,
 * a gap, or `/clear`. `model` is the one the ask named (undefined: a fork), and only an ask naming
 * it gets the summary again, with the failures that came before it, at no model call. Kept in
 * memory only, as the transcript it summarises is the session's own.
 */
let summary: { model: string | undefined; text: string; failures: SummaryFailure[] } | null = null
/** Counts what ends a summary's use, so a summary written across one is not kept as current. */
let turnsDone = 0
/**
 * The summary on its way, which a second ask joins instead of asking a model again, and gets what
 * the first ask's model writes; not once a gap crossed it (`send` behind `sendCount`), nor when the
 * app numbered the second ask as another (`ask`).
 */
let sending: { send: number; ask: number | undefined; outcome: Promise<ContextOutcome> } | null = null
/** The hooks' posts to the app, in the order the hooks ran. */
let posts: Promise<unknown> = Promise.resolve()
/** Counts sends; one that timed out or that a gap crossed is over, and what it wrote later is dropped. */
let sendCount = 0

/**
 * `empty`: nothing to summarise yet; `failed`: no summary reached the app; `superseded`: a gap or a
 * newer ask overtook the send, so its answer is stale and no failure.
 */
type ContextOutcome = 'sent' | 'empty' | 'failed' | 'superseded'
/** What a context ask names: the model to write with, and the one to try if it fails; none from an older app. */
type ContextAsk = Omit<Extract<Work, { kind: 'context' }>, 'kind'>
/** The ask's number, which every answer to an ask that names a model echoes. */
const answering = (ask: ContextAsk) => (ask.ask === undefined ? {} : { ask: ask.ask })

const setBand = ($: EngineInterface, change: Partial<Band> | null) =>
  update($, band, now => (change === null ? null : { isOffline: false, ...now, ...change }))

/** The band as it draws: `minutesToday`, which grows while a line is open, is only `/live`'s text. */
const drawn = (state: Band | null) => JSON.stringify(state, (key, value: unknown) => (key === 'minutesToday' ? undefined : value))

/**
 * Writes the band; with `isFast`, only when that changes what it draws, since every write redraws
 * each surface that shows it. The once-a-second write stays, which keeps `/live`'s minutes and
 * tells a surface that dropped the band from one that draws it (`UNDRAWN_MS`).
 */
async function writeBand($: EngineInterface, change: (now: Band | null) => Band | null, isFast: boolean): Promise<void> {
  if (isFast) {
    const now = await read($, band)
    if (drawn(change(now)) === drawn(now)) return
  }
  await update($, band, change)
}

/**
 * Keeps the tracker and the gap for a reload. A store that fails costs nothing else: what goes to
 * the app matters more, and a hook past its `next` would have its `.catch` run the event again.
 */
async function save($: EngineInterface): Promise<void> {
  // The count first: a `/live off` during it deletes the key, which this must not write back.
  const sessionTurns = await turnCount($)
  if (!link?.session) return
  const key = joinedKey(link.session.sessionId)
  await $.store.set(key, { ...tracker.snapshot(), hasGap: link?.hasGap, sessionTurns }).catch(() => {})
}

/**
 * A turn did not reach the app, which the next join says. No summary from before it covers it: the
 * one kept goes. The one being written for an older app's ask is dropped; for a named ask it is
 * posted all the same, and the app takes it as fresh if it arrives before that join.
 */
function noteGap(): void {
  link?.noteGap()
  staleSummary()
  if (sending !== null) sendCount += 1
}

/** Posts a line of a turn, cut to `ANSWER_LIMIT`; one the app did not take is a gap, which the next join says. */
async function postSync($: EngineInterface, line: SyncLine): Promise<void> {
  const body = line.text === undefined ? line : { ...line, text: clip(line.text, ANSWER_LIMIT) }
  if ((await link?.sync(body)) === true) return
  noteGap()
  await save($)
}

/**
 * Runs a hook's `work` after the posts queued before it, and holds the hook no longer than
 * `HOOK_HOLD_MS`: the app answers a line once the open line took it, up to 20 s with codex stuck,
 * and typing must not wait for that. Its own queue, not `serial`: the app drops a session that
 * stops polling after 5 s, so a held line must leave the poll running. What `work` needs of the
 * hook's moment it takes before this call.
 */
async function inOrder($: EngineInterface, work: () => Promise<void>): Promise<void> {
  const done = posts.then(work).catch((error: unknown) => $.ui.log(`LiveBridge: ${String(error)}`))
  posts = done
  let timer: { cancel(): void } | undefined
  await Promise.race([done, new Promise<void>(resolve => { timer = $.clock.after(HOOK_HOLD_MS, resolve) })])
  timer?.cancel()
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

/** Joins; `byOwner` when the owner typed /live (a reload's resume is not their decision). */
async function turnOn($: EngineInterface, byOwner: boolean): Promise<boolean> {
  // What the last join learnt about the app is stale: the owner may have opened or installed it.
  offlineSince = null
  note = null
  const sessionId = await $.session.id()
  const title = (await readTitle($, sessionId)) ?? ''
  // The app got no turn from before the owner's join; a reload's gap is in its snapshot.
  if (byOwner && (await hasTurns($))) noteGap()
  // Only the owner's own join brings back a session they removed.
  const isJoined = (await link?.join({
    sessionId, title, modVersion, syncs: true, writesSummaries: true, ...(byOwner && { owner: true }),
  })) === true
  await save($)
  await setBand($, {})
  redrawBand($)
  link?.start(isFast => tick($, isFast))
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
 * once-a-second poll, which looks for the title as cheaply as `readTitle` allows.
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
    await $.store.delete(joinedKey(joined.sessionId)).catch(() => {})  // the join matters more
  }
  await link.rejoin({ ...joined, sessionId, title, ...(isNewId && { replaces: joined.sessionId }) })
  await save($)
}

/**
 * One poll: status into the band, a voice request queued as a prompt, a context request answered
 * or a model check run. It polls before it follows the title: any join clears the app's removal mark, so
 * only a session the app still holds may join again. `isFast`: one of the target's polls between
 * the once-a-second ones, which neither follows the title nor rewrites an unchanged band.
 */
async function tick($: EngineInterface, isFast: boolean): Promise<void> {
  if (!link?.session) return  // it left, or was removed, while this poll waited its turn
  const hadGap = link.hasGap
  const asked = answerQuestion  // a reply this poll brings can only be to a question open now
  const reply = await link.next()
  if (reply === REMOVED || !link.session) return  // the link queued `removed`; a join may have met it
  if (hadGap && !link.hasGap) await save($)  // a join said it: a reload must not say it again
  if (!reply) {
    const now = await $.clock.now()
    if (offlineSince === null) {
      offlineSince = now
      if (!(await link?.ensureApp())) await setBand($, { problem: OPEN_APP })
    }
    const isOffline = now - offlineSince >= OFFLINE_AFTER_MS
    await writeBand($, shown => ({ ...shown, isOffline }), isFast)
    return
  }
  offlineSince = null
  if (!isFast) await follow($, true)
  const self = link?.session?.sessionId ?? ''
  if (reply.work?.kind === 'request') note = null
  await writeBand($, now => ({
    isOffline: false, status: bandStatus(reply.status, self),
    ...(note && { problem: note }), ...(now?.context && { context: now.context }),
  }), isFast)
  // The once-a-second write redraws each surface that shows the band; one that asked for none
  // for a while lost it, and is asked again.
  const at = await $.clock.now()
  if (!isFast && at - drawnAt >= UNDRAWN_MS) {
    drawnAt = at
    redrawBand($)
  }
  const work = reply.work
  if (work?.kind === 'request') {
    // Queued behind an off or a removal that came in while this poll ran: those fail it in the app.
    enqueue($, () => deliver($, work))
  } else if (work?.kind === 'reply') {
    if (asked !== null && asked === answerQuestion) {
      asked(work)
    } else {
      $.ui.log(LATE_REPLY)
      // The app opened a request for a reply to a typed turn; a voice turn's refuses this, harmlessly.
      await link?.answer({ id: work.id, status: 'failed', text: '', reason: ANSWERED_HERE })
    }
  } else if (work?.kind === 'context') {
    const { kind: _, ...ask } = work
    void contextAsked($, ask)
  } else if (work?.kind === 'checkModel') {
    void modelChecked($, work.id, work.model)
  }
}

/** Runs the app's check of a model, without holding the poll, and posts what came of it. */
async function modelChecked($: EngineInterface, id: string, model: string): Promise<void> {
  const failure = await checkModel($, model)
  await link?.modelCheck({ id, ok: failure === null, ...failure })
}

/**
 * The app took neither a turn's answer nor, so, its place in the conversation. An update to a
 * request a newer one replaced is refused by design, so only a result is said to be lost.
 */
async function answerLost($: EngineInterface, status: AnswerStatus): Promise<void> {
  noteGap()
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

/** Claude's usage windows as the wire carries them; `resetsAt` only where the engine gave one. */
function windowsOf(limits: readonly SessionRateLimit[]): LimitWindowBody[] {
  return limits.map(one => ({
    kind: one.kind, percentUsed: one.percentUsed, ...(one.resetsAt !== undefined && { resetsAt: one.resetsAt }),
  }))
}

/** Sends the windows the session has now. An engine that has none to give leaves the join as it was. */
async function sendLimits($: EngineInterface): Promise<void> {
  try {
    await link?.limits(windowsOf((await $.session.usage()).rateLimits))
  } catch {
    // the windows are a courtesy to the menu: no reading is no harm
  }
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
  await save($)
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

/** How many prompts the session has had; undefined when the engine does not say. */
function turnCount($: EngineInterface): Promise<number | undefined> {
  return $.session.turns().catch(() => undefined)
}

/** Whether the session has had a prompt: a new one has nothing to summarise. */
async function hasTurns($: EngineInterface): Promise<boolean> {
  return ((await turnCount($)) ?? 1) > 0  // not known: the model says when there is nothing
}

/**
 * Answers one ask. An ask that names a model, from an app that waits on the answer, is answered at
 * every exit, an empty summary when there is none; an older app's ask is answered only with one.
 */
async function deliverContext($: EngineInterface, ask: ContextAsk, send: number): Promise<ContextOutcome> {
  const deadline = (await $.clock.now()) + CONTEXT_TIMEOUT_MS
  const isNamed = ask.model !== undefined
  if (!(await hasTurns($))) {
    if (isNamed) await link?.context({ summary: '', ...answering(ask) })
    return 'empty'
  }
  await showContext($, 'loading')
  let outcome: ContextOutcome
  if (isNamed) {
    // The models share the minute: each call's own time limit is what is left of it.
    outcome = await writeAndPost($, ask, send, deadline)
  } else {
    let timer: { cancel(): void } | undefined
    const late = new Promise<'failed'>(resolve => { timer = $.clock.after(CONTEXT_TIMEOUT_MS, () => resolve('failed')) })
    outcome = await Promise.race([forkAndPost($, send), late])
    timer?.cancel()
    if (outcome !== 'sent') sendCount += 1  // a summary this send writes after its time is dropped
  }
  // A newer send, after a gap, owns the band's note.
  if (sending?.send !== send) return outcome
  await showContext($, outcome === 'sent' ? 'sent' : outcome === 'failed' && isNamed ? 'failed' : undefined)
  if (outcome === 'sent') {
    $.clock.after(SENT_NOTE_MS, () => void (send === sendCount && showContext($, undefined)))
  }
  return outcome
}

/**
 * Writes with the model the ask names and posts what came of it, the failures included. One a gap
 * crossed is posted all the same, as its ask's answer, which the app then ignores as stale.
 */
async function writeAndPost($: EngineInterface, ask: ContextAsk, send: number, deadline: number): Promise<ContextOutcome> {
  const turns = turnsDone
  const kept = summary !== null && summary.model === ask.model ? summary : null
  let written: Summary
  try {
    written = kept ?? (await summarize($, ask, deadline))
  } catch {
    // The transcript could not be read, so no model was asked.
    await link?.context({ summary: '', ...answering(ask) })
    return 'failed'
  }
  const { text, failures, stats } = written
  if (text !== '' && turns === turnsDone) summary = { model: ask.model, text, failures }
  const isTaken = (await link?.context({
    summary: text, ...(failures.length > 0 && { failures }), ...(stats && { stats }), ...answering(ask),
  })) === true
  if (send !== sendCount) return 'superseded'
  if (!isTaken) return 'failed'
  return text !== '' ? 'sent' : failures.length > 0 ? 'failed' : 'empty'
}

/** An older app's ask: the session's own model forks, and only a summary is posted. */
async function forkAndPost($: EngineInterface, send: number): Promise<ContextOutcome> {
  try {
    const turns = turnsDone
    const text = summary !== null && summary.model === undefined ? summary.text : (await summarize($, {}, Infinity)).text
    if (send !== sendCount) return 'failed'
    if (text === '') return 'empty'
    if (turns === turnsDone) summary = { model: undefined, text, failures: [] }
    return (await link?.context({ summary: text })) === true ? 'sent' : 'failed'
  } catch {
    return 'failed'
  }
}

/**
 * Sends the summary the app asked for, which has no reply line of its own, and never rejects. While
 * one is on its way a second ask joins it, unless a gap crossed it or the app numbered the second
 * ask as another: that one is over.
 */
async function contextAsked($: EngineInterface, ask: ContextAsk): Promise<void> {
  if (sending === null || sending.send !== sendCount || sending.ask !== ask.ask) {
    const send = ++sendCount
    const mine: NonNullable<typeof sending> = {
      send, ask: ask.ask, outcome: deliverContext($, ask, send).finally(() => { if (sending === mine) sending = null }),
    }
    sending = mine
  }
  // A send that outlived the join (the owner left meanwhile) is no failure worth a line.
  if ((await sending.outcome) === 'failed' && link?.session) $.ui.log(NO_SUMMARY)
}

async function statusText($: EngineInterface): Promise<string> {
  const state = await read($, band)
  // A join on its way has no band yet.
  if (state === null || (!state.isOffline && state.status === undefined)) return JOINING
  const status = state.status
  if (state.isOffline || status === undefined) return `LiveBridge is not reachable. ${state.problem ?? ''}`.trim()
  return `LiveBridge: ${status.call}; target: ${status.target}; ${status.unheard} unheard; ` +
    `${Math.round(status.minutesToday)} min today.${status.problem ? ` ${status.problem}` : ''}`
}

/** `/live` in a joined session: the owner's way back to a band the surface lost, and the status. */
function joinedAnswer($: EngineInterface): Promise<string> {
  redrawBand($)
  return statusText($)
}

/**
 * `/live` joins, and in a joined session answers the status; `/live off` leaves. Not a toggle, so a
 * repeated `/live` never leaves. `on` is `/live` under its old name.
 */
async function live($: EngineInterface, args: string): Promise<string> {
  const form = args.trim()
  if (form === 'off') {
    if (!link?.session) return 'This session has not joined LiveBridge.'
    await serial(() => turnOff($))
    return 'Left LiveBridge.'
  }
  if (form !== '' && form !== 'on') return USAGE
  // Not through the queue: a held poll would outlast the engine's patience with a command.
  if (link?.session) return joinedAnswer($)
  return serial(async () => {
    if (link?.session) return joinedAnswer($)
    // No title here: a new session's is still the one Claude Code derives from its folder, and
    // the app shows the name the session is given next, once the poll follows it.
    return (await turnOn($, true))
      ? 'Joined LiveBridge.'
      : 'LiveBridge is not running; the mod opens it and joins as soon as it is up.'
  })
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

/** Names the main-loop turn an activity belongs to, for the app; none between turns. */
const under = (turn: TurnRef | null) => (turn === null ? {} : { turn })

/** Tells the app what waits; one it did not take is a gap, as the voice never hears of it. */
async function awaiting($: EngineInterface, said: Omit<ActivityBody, 'sessionId' | 'state'>): Promise<void> {
  if ((await link?.activity('approval', said)) === true) return
  noteGap()
  await save($)
}

/**
 * A settled prompt: a line for the running turn, and the session works on. It is the mod's report,
 * not the owner's typing, so it refuses nothing.
 */
async function promptSettled($: EngineInterface, text: string): Promise<void> {
  const turn = tracker.current
  const isOver = nothingWaits()
  // Its place in the queue first: a question's hook can run inside the save.
  const posted = inOrder($, async () => {
    if (turn) await postSync($, { turn, kind: 'report', text })
    if (isOver) await link?.activity('working', under(turn))
  })
  await save($)
  await posted
}

/** Whether the session works on: the app has one row for a prompt and for Claude's question. */
const nothingWaits = () => !tracker.isPrompting && answerQuestion === null

/** The tool ran, or failed, so the prompt for that very run was allowed. */
async function toolRan($: EngineInterface, e: { tool_name: string; tool_input: unknown; agent_id?: string }): Promise<void> {
  if (tracker.promptRan(e.tool_name, e.tool_input, e.agent_id)) await promptSettled($, `You allowed ${e.tool_name} at the keyboard.`)
}

/**
 * The next step of the loop that asked, or its end, with its prompt still open: no tool ran and the
 * dialog is gone. No hook reports a person's No (ADR 0001, item i), so it is only settled.
 */
async function promptGone($: EngineInterface, agent?: string): Promise<void> {
  for (let tool = tracker.promptGone(agent); tool !== null; tool = tracker.promptGone(agent)) {
    await promptSettled($, `The permission prompt for ${tool} was settled at the keyboard.`)
  }
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
      argumentHint: '[off]',
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
      joined: () => enqueue($, () => sendLimits($)),
    }, {
      socketPath: socketPath(home, await $.env.get('CFFIXED_USER_HOME')),
      appPath: '/Applications/LiveBridge.app',
    })
    // A hot reload runs this again with the module's variables gone; the store kept the join.
    const saved = await $.store.get(joinedKey(await $.session.id()))
    if (saved !== undefined) {
      tracker = new TurnTracker(saved as TurnSnapshot)
      // A snapshot from before sync says nothing: none of its turns reached the app. More turns than
      // the snapshot saw ran with the mod off: disabling it ends no session, so its key stayed.
      const { hasGap, sessionTurns } = saved as { hasGap?: boolean; sessionTurns?: number }
      if (hasGap !== false || (sessionTurns ?? Infinity) < ((await turnCount($)) ?? 0)) noteGap()
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
    if (e.turnId === undefined) lastSubmit = { origin, text: e.text }
    const entered = await next(e)
    if (e.turnId === undefined && entered.drop !== undefined) lastSubmit = null
    // Whether it folds in or gets a turn of its own, it goes to the app now, under the running turn.
    if (e.turnId !== undefined && origin === 'owner' && entered.drop === undefined) {
      const line = tracker.typedInto(e.turnId, e.text, entered.text)
      await save($)
      await inOrder($, () => postSync($, line))
    }
    return entered
  }).catch(($, e, next) => next(e))

  // A window moved: tell the app. Observes only, and queued so the engine is not held up.
  on('session.measure', ($, e, next) => {
    if (e.changed.includes('rateLimits')) {
      const windows = windowsOf(e.rateLimits)
      enqueue($, async () => { await link?.limits(windows) })
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) {
      const { lines, isLost } = tracker.turnStarted(e.turnId, e.text, lastSubmit?.origin ?? null, await $.clock.now(), lastSubmit?.text)
      if (isLost) noteGap()
      lastSubmit = null
      const turn = tracker.current
      await inOrder($, async () => {
        await serial(() => follow($, false))  // /clear: the line goes under the session's new id
        await save($)
        for (const line of lines) await postSync($, line)
        await link?.activity('working', under(turn))
      })
    }
    return next(e)
  })

  // The engine's turn.complete carries only the turn's last text, and a question or a permission
  // prompt only itself: what Claude wrote in the step that asks would reach the voice in neither.
  // Kept as it streams, since the engine may run the step's tools before the step ends.
  on('turn.step', async function* ($, e, next) {
    await promptGone($, e.agentId)
    if (e.agentId !== undefined) return yield* next(e)
    tracker.stepStarted()
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
    await promptGone($, e.agentId)
    if (e.agentId === undefined) {
      const turn = tracker.current
      const { post, sync, isLost } = tracker.turnCompleted(e.turnId, e.answer, e.reason)
      if (isLost) noteGap()
      staleSummary()
      await save($)
      await inOrder($, async () => {
        if (sync) await postSync($, sync)
        const taken = post && (await link?.answer({ ...post, text: clip(post.text, ANSWER_LIMIT) }))
        if (post && taken !== true && taken !== REMOVED) await answerLost($, post.status)
        await link?.activity('idle', under(turn))
      })
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
      const isOverPrompt = tracker.isPrompting
      const said = { question: askedText(e.questions), ...wrote(tracker.takeStepText()), turn }
      await inOrder($, async () => {
        // The app says what waits only on a change to `approval`.
        if (isOverPrompt) await link?.activity('working', { turn })
        await awaiting($, said)
      })
      // Over at once: a reply from here on has no question, whatever posting the answer takes.
      const first = await Promise.race([answered, spoken]).finally(() => { answerQuestion = null })
      if ('kind' in first) {
        tracker.replied(first.id, first.forRequest, await $.clock.now())
        await save($)
        return { result: { questions: e.questions, answers: {}, response: spokenReply(first) } }
      }
      const result = first.isError === true ? undefined : first.result
      await inOrder($, () => postSync($, { turn, ...keyboardAnswer(result) }))
      return first
    } finally {
      const after = under(tracker.current)
      const isPrompting = tracker.isPrompting
      await inOrder($, async () => {
        await link?.activity('working', after)
        if (isPrompting) await awaiting($, after)
      })
    }
  }).catch(($, e, next) => next(e))

  // ADR 0001 (i): a permission request that reaches the person during a main-loop turn, with what
  // the main loop wrote in the step that asks for it. Claude's question has its own report above.
  // A subagent's is no step of the main loop's, so it carries none of that text, but it ran in the turn.
  on('classic.PermissionRequest', async ($, e, next) => {
    const turn = tracker.current
    if (turn !== null && link?.session && e.tool_name !== 'AskUserQuestion') {
      tracker.promptOpened(e.tool_name, e.tool_input, e.agent_id)
      // A bare approval would take back the open question, and the app would say nothing for it.
      const isAsking = answerQuestion !== null
      const said = { ...(!isAsking && e.agent_id === undefined && wrote(tracker.takeStepText())), turn }
      // Its place in the queue first: a question's hook can run inside the save.
      const posted = isAsking ? null : inOrder($, () => awaiting($, said))
      await save($)
      await posted
    }
    return next(e)
  }).catch(($, e, next) => next(e))
  on('classic.PostToolUse', async ($, e, next) => (await toolRan($, e), next(e)))
    .catch(($, e, next) => next(e))
  on('classic.PostToolUseFailure', async ($, e, next) => (await toolRan($, e), next(e)))
    .catch(($, e, next) => next(e))
  // Auto mode's refusal, not the person's: nothing to tell the voice but that it goes on.
  on('classic.PermissionDenied', async ($, e, next) => {
    if (tracker.promptRan(e.tool_name, e.tool_input, e.agent_id) && nothingWaits()) {
      const turn = tracker.current
      await inOrder($, async () => { await link?.activity('working', under(turn)) })
    }
    return next(e)
  }).catch(($, e, next) => next(e))

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
