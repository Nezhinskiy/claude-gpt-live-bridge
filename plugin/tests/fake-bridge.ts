// The world beneath the mod in its engine tests: a fake LiveBridge app answering the mod's
// HTTP over the socket, a registry record for the session title, and the engine's answers.
import type { On } from 'claude-code'
import { mock } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

import { FRAMING } from '../hooks/prompt.ts'
import { socketPath } from '../hooks/wire.ts'
import type { StatusReply, Work } from '../hooks/wire.ts'

export const ID = '00000000-0000-0000-0000-000000000001'
/** Where the app listens for this home (wire.unit.ts holds the path itself). */
export const SOCKET = socketPath('/Users/example', undefined)
export const BAND = {
  plugin: 'livebridge',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 10 }, view: {},
  },
} as const
export const LIVE = { command: 'live', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 100 } } as const

export type Call = { route: string; body?: Record<string, unknown> }

export function fakeWorld(on: On, store: Record<string, unknown> = {}, env: Record<string, string> = {}) {
  const clock = mock.clock(on)
  mock.env(on, { HOME: '/Users/example', ...env })
  // The store in memory, whose next write can be held where the mod awaits it.
  const held = async () => {
    const hold = world.holdStore
    world.holdStore = null
    if (hold !== null) {
      world.onStoreHeld()
      await hold
    }
  }
  // The model beneath the mod: each step it is asked for streams `world.stepText` as its text.
  on('turn.step', async function* (_, e) {
    if (world.stepText !== '') yield { kind: 'text', index: 0, text: world.stepText }
    return { turnId: e.turnId, index: e.index, answer: world.stepText, toolUses: [], stopReason: 'end_turn', usage: null }
  })
  on('store.get', (_, e) => ({ value: world.stored.get(e.key) }))
  on('store.set', async (_, e) => {
    if (world.isStoreBroken) throw new Error('the store is full')
    await held()
    world.stored.set(e.key, e.value)
    return { value: undefined }
  })
  on('store.delete', async (_, e) => {
    if (world.isStoreBroken) throw new Error('the store is full')
    await held()
    world.stored.delete(e.key)
    return { value: undefined }
  })
  const world = {
    clock,
    sessionId: ID,
    title: 'Example session',
    isAppUp: true,
    /** The socket the app listens on. */
    socket: SOCKET as string,
    /** Whether /Applications holds the app; Launch Services never finds it by bundle id here. */
    isAppInstalled: false,
    /** The status the app answers an answer with (409: it restarted and forgot the request). */
    answerStatus: 200,
    /** The status the app answers a sync line with (404: an older app has no such route). */
    syncStatus: 200,
    /** The pause setting is on and the call is off, as `Continuity.admits` sees them. */
    isPausing: false,
    /** The last turn the app decided on, its one slot per conversation (`Continuity.admits`). */
    decision: null as { turnId: string; isAdmitted: boolean } | null,
    /** The non-empty sync lines the app admitted, in order. */
    kept: [] as string[],
    isSubmitRefused: false,
    /** A hook beneath the mod refuses the owner's prompt (`{ drop }`). */
    isPromptDropped: false,
    /** What a hook beneath the mod rewrites a prompt to, or null. */
    enteredText: null as string | null,
    /** The engine refuses the command's name (as it does a built-in's). */
    isCommandRefused: false,
    /** Every slash command the mod declared, in order. */
    commands: [] as string[],
    /** Why the session's model writes no summary (the fork's `reason`), or null when it writes one. */
    forkFails: null as null | 'api-error' | 'nothing-to-fork',
    logs: [] as string[],
    /** Every event the mod asked the engine to run again (`$.ui.invalidate`), in order. */
    invalidated: [] as string[],
    /** The visible text of the next model step. */
    stepText: '',
    summary: 'Goal: tidy the example project.',
    /** How many prompts the session has had; 0 is a new session with nothing to summarise. */
    turns: 1,
    /** How many summaries the session's model was asked for. */
    forks: 0,
    /** How long the session's model takes over a summary, on the mocked clock. */
    forkMs: 0,
    joined: new Set<string>(),
    /** Sessions the owner removed in the menu; only the owner's join (`/live on`) clears the mark. */
    removed: new Set<string>(),
    status: { call: 'off', sessions: [], minutesToday: 0, unheard: 0, isMuted: false } as StatusReply,
    work: [] as Work[],
    calls: [] as Call[],
    submitted: [] as string[],
    launches: [] as (readonly string[])[],
    read: [] as string[],
    /** The version the mod's own plugin.json names, or null when it cannot be read. */
    modVersion: null as string | null,
    /** While set, the app's reply to a poll is held until it resolves (built before, as the app does). */
    holdNext: null as Promise<void> | null,
    /** Called once a poll is being held. */
    onNextHeld: () => {},
    /** What the mod's store holds. */
    stored: new Map(Object.entries(store)),
    /** The mod's writes to its store fail. */
    isStoreBroken: false,
    /** While set, the mod's next write to its store is held until it resolves. */
    holdStore: null as Promise<void> | null,
    /** Called once a write is being held. */
    onStoreHeld: () => {},
    /** Prompts submitted and leaves posted, in the order they happened. */
    timeline: [] as ('submit' | 'leave')[],
    /** While set, the app's reply to a sync line is held until it resolves. */
    holdSync: null as Promise<void> | null,
    /** How many AskUserQuestion dialogs the session opened. */
    dialogs: 0,
    /** Answers the open AskUserQuestion dialog at the keyboard with a label. */
    answerDialog: (_label: string) => {},
    /** Closes the open AskUserQuestion dialog with Esc: the tool reports an error. */
    cancelDialog: () => {},
    /** The registry's other `*.json` files, by name: Claude Code rewrites them, so one may be half written. */
    otherRecords: {} as Record<string, string>,
    /** The calls to one route since the last look, then forgets them. */
    take(route: string) {
      const found = world.calls.filter(call => call.route === route)
      world.calls = world.calls.filter(call => call.route !== route)
      return found.map(call => call.body)
    },
  }
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.end', (_, e) => ({ sessionId: e.sessionId }))
  on('session.id', () => ({ value: world.sessionId }))
  on('session.turns', () => ({ value: world.turns }))
  on('session.cwd', () => ({ value: '/Users/example/Dev/example-project' }))
  on('command.register', (_, e) => {
    if (world.isCommandRefused) return { deny: `"/${e.name}" refused: it is the built-in /${e.name}` }
    world.commands.push(e.name)
    return { value: { command: e.name } }
  })
  on('session.attach', (_, e) => ({ clientId: e.clientId }))
  on('fs.list', () => ({
    value: [...Object.keys(world.otherRecords), '12345.json', '12345.key']
      .map(name => ({ name, kind: 'file', size: 1, mtimeMs: 0, isLink: false }) as const),
  }))
  on('fs.read', (_, e) => {
    // The mod's own manifest, not one of the session registry's files `read` lists.
    if (e.path.endsWith('/.claude-plugin/plugin.json')) {
      if (world.modVersion === null) throw new Error('ENOENT')
      return { value: JSON.stringify({ name: 'livebridge', version: world.modVersion }) }
    }
    world.read.push(e.path)
    const other = world.otherRecords[e.path.split('/').at(-1) ?? '']
    return { value: other ?? JSON.stringify({ pid: 12345, sessionId: world.sessionId, name: world.title }) }
  })
  on('process.run', (_, e) => {
    world.launches.push(e.argv)
    const exitCode = world.isAppInstalled && e.argv.at(-1) === '/Applications/LiveBridge.app' ? 0 : 1
    return { value: { exitCode, stdout: '', stderr: exitCode === 0 ? '' : 'no such application', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('http.fetch', async (_, e) => {
    if (!world.isAppUp || e.init?.socketPath !== world.socket) throw new Error('connect ENOENT')
    const route = new URL(e.url).pathname.replace('/v1/', '')
    const body = e.init.body === undefined ? undefined : JSON.parse(e.init.body)
    world.calls.push({ route, body })
    if (route === 'join' && body.owner === true) world.removed.delete(body.sessionId)
    if (route === 'join') world.joined.add(body.sessionId)
    if (route === 'join' && body.replaces !== undefined) world.joined.delete(body.replaces)
    if (route === 'leave') world.joined.delete(body.sessionId)
    if (route === 'leave') world.timeline.push('leave')
    if (route === 'answer' && world.answerStatus !== 200) {
      return { value: { status: world.answerStatus, ok: false, headers: {}, text: '{"error":"unknown or stale request id"}' } }
    }
    if (route === 'sync' && world.syncStatus !== 200) {
      return { value: { status: world.syncStatus, ok: false, headers: {}, text: '{"error":"unknown session"}' } }
    }
    // The app answers a removed session's calls so, its own joins included, until the owner joins it
    // again. Two routes look the session up among the joined instead: `sync` finds none, 404, and
    // `activity` ignores it, 200.
    if (world.removed.has(body?.sessionId ?? new URL(e.url).searchParams.get('sessionId') ?? '')) {
      if (route === 'sync') return { value: { status: 404, ok: false, headers: {}, text: '{"error":"unknown session"}' } }
      if (route !== 'activity') {
        return { value: { status: 410, ok: false, headers: {}, text: '{"error":"this session was removed from LiveBridge","code":"removed"}' } }
      }
    }
    if (route === 'sync') {
      const held = world.decision?.turnId === body.turnId ? world.decision : null
      const isAdmitted = held ? held.isAdmitted && !(body.from === 'owner' && world.isPausing) : !world.isPausing
      world.decision = { turnId: body.turnId, isAdmitted }
      if (isAdmitted && body.text !== '') world.kept.push(body.text)
      if (world.holdSync !== null) await world.holdSync
    }
    const reply = route !== 'next'
      ? {}
      : world.joined.has(new URL(e.url).searchParams.get('sessionId') ?? '')
        ? { status: world.status, ...(world.work.length > 0 && { work: world.work.shift() }) }
        : undefined
    const text = JSON.stringify(reply ?? { error: 'unknown session' })
    if (route === 'next' && world.holdNext !== null) {
      world.onNextHeld()
      await world.holdNext
    }
    return { value: { status: reply ? 200 : 404, ok: reply !== undefined, headers: {}, text } }
  })
  on('prompt.submit', (_, e) => {
    if (world.isSubmitRefused) throw new Error('the session is closing')
    if (world.isPromptDropped) return { drop: 'a hook refused the prompt' }
    world.submitted.push(e.text)
    world.timeline.push('submit')
    return { text: world.enteredText ?? e.text, origin: e.origin }
  })
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('ui.log', (_, e) => {
    world.logs.push(e.text)
    return { value: undefined }
  })
  on('ui.invalidate', (_, e) => {
    world.invalidated.push(e.event)
    return { value: undefined }
  })
  on('model.fork', async () => {
    world.forks += 1
    if (world.forkMs > 0) await world.clock.sleep(world.forkMs)
    const usage = { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 }
    // The engine resolves every outcome, an API error included; it does not throw.
    if (world.forkFails === 'api-error') {
      return { value: { isAnswered: false, reason: 'api-error', status: 529, error: 'overloaded', usage } } as const
    }
    if (world.forkFails === 'nothing-to-fork') return { value: { isAnswered: false, reason: 'nothing-to-fork' } } as const
    return { value: { isAnswered: true, text: world.summary, usage } } as const
  })
  // AskUserQuestion's dialog is its own permission prompt; any other tool asks first.
  on('tool.check', (_, e) => ({ decision: e.tool === 'AskUserQuestion' ? 'allow' : 'ask' }))
  // The AskUserQuestion dialog: open until `answerDialog` picks a label at the keyboard.
  on('tool.call', (_, e) => {
    if (e.tool !== 'AskUserQuestion') return { deny: 'no other tool runs in this world' }
    const { questions } = e
    world.dialogs += 1
    return new Promise(resolve => {
      // As the engine resolves them, ADR 0001 (i): `answers` inside `result`; an error's `result` a string.
      world.answerDialog = label => resolve({
        ref: 1, result: { questions, answers: { [questions[0]!.question]: label }, annotations: {} },
        text: 'Your questions have been answered.', isReadOnly: true,
      })
      world.cancelDialog = () => resolve({
        ref: 1, result: "Error: The user doesn't want to proceed with this tool use.",
        text: "The user doesn't want to proceed with this tool use.", isError: true,
      })
    })
  })
  on('classic.PermissionRequest', () => ({}))
  on('classic.PostToolUse', () => ({}))
  return world
}

/** How the engine starts the turn of a prompt this plugin submitted (ADR 0001, item j). */
export const framed = (text: string) =>
  `${FRAMING}${text}\n\nThis is how Claude Code surfaces a prompt a plugin submits between turns — it starts this turn in the user's place. Address the message above.`

/** One model step of turn `turnId` (a subagent's, with `agentId`) whose visible text is `text`. */
export async function step($: Engine, world: ReturnType<typeof fakeWorld>, turnId: string, text: string, agentId?: string) {
  world.stepText = text
  const stream = $.turn.step({ turnId, index: 0, model: 'example-model', messageCount: 1, ...(agentId && { agentId }) })
  for await (const chunk of stream) void chunk
  return stream.result
}
