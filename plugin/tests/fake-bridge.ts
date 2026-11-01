// The world beneath the mod in its engine tests: a fake LiveBridge app answering the mod's
// HTTP over the socket, a registry record for the session title, and the engine's answers.
import type { On } from 'claude-code'
import { mock } from 'claude-code/testing'

import { FRAMING } from '../hooks/prompt.ts'
import type { StatusReply, Work } from '../hooks/wire.ts'

export const ID = '00000000-0000-0000-0000-000000000001'
export const SOCKET = '/Users/example/Library/Application Support/claude-gpt-live-bridge/run/bridge.sock'
export const BAND = {
  plugin: 'livebridge',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 10 }, view: {},
  },
} as const
export const VOICEMOD = { command: 'voicemod', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 100 } } as const

export type Call = { route: string; body?: Record<string, unknown> }

export function fakeWorld(on: On, store: Record<string, unknown> = {}) {
  const clock = mock.clock(on)
  mock.env(on, { HOME: '/Users/example' })
  mock.store(on, store)
  const world = {
    clock,
    sessionId: ID,
    title: 'Example session',
    isAppUp: true,
    /** The status the app answers an answer with (409: it restarted and forgot the request). */
    answerStatus: 200,
    isSubmitRefused: false,
    joined: new Set<string>(),
    status: { call: 'off', sessions: [], minutesToday: 0, minutesThisCall: 0, recentTranscript: [], unheard: 0 } as StatusReply,
    work: [] as Work[],
    calls: [] as Call[],
    submitted: [] as string[],
    launches: [] as (readonly string[])[],
    read: [] as string[],
    /** While set, the app's reply to a poll is held until it resolves (built before, as the app does). */
    holdNext: null as Promise<void> | null,
    /** Called once a poll is being held. */
    onNextHeld: () => {},
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
  on('session.cwd', () => ({ value: '/Users/example/Dev/example-project' }))
  on('command.register', () => ({ value: { command: 'voicemod' } }))
  on('fs.list', () => ({
    value: [...Object.keys(world.otherRecords), '12345.json', '12345.key']
      .map(name => ({ name, kind: 'file', size: 1, mtimeMs: 0, isLink: false }) as const),
  }))
  on('fs.read', (_, e) => {
    world.read.push(e.path)
    const other = world.otherRecords[e.path.split('/').at(-1) ?? '']
    return { value: other ?? JSON.stringify({ pid: 12345, sessionId: world.sessionId, name: world.title }) }
  })
  on('process.run', (_, e) => {
    world.launches.push(e.argv)
    return { value: { exitCode: 1, stdout: '', stderr: 'no such application', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('http.fetch', async (_, e) => {
    if (!world.isAppUp || e.init?.socketPath !== SOCKET) throw new Error('connect ENOENT')
    const route = new URL(e.url).pathname.replace('/v1/', '')
    const body = e.init.body === undefined ? undefined : JSON.parse(e.init.body)
    world.calls.push({ route, body })
    if (route === 'join') world.joined.add(body.sessionId)
    if (route === 'join' && body.replaces !== undefined) world.joined.delete(body.replaces)
    if (route === 'leave') world.joined.delete(body.sessionId)
    if (route === 'answer' && world.answerStatus !== 200) {
      return { value: { status: world.answerStatus, ok: false, headers: {}, text: '{"error":"unknown or stale request id"}' } }
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
    world.submitted.push(e.text)
    return { text: e.text, origin: e.origin }
  })
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('model.fork', () => ({
    value: {
      isAnswered: true, text: 'Goal: tidy the example project.',
      usage: { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
    },
  }))
  on('tool.check', () => ({ decision: 'ask' }))
  on('classic.PermissionRequest', () => ({}))
  on('classic.PostToolUse', () => ({}))
  return world
}

/** How the engine starts the turn of a prompt this plugin submitted (ADR 0001, item j). */
export const framed = (text: string) =>
  `${FRAMING}${text}\n\nThis is how Claude Code surfaces a prompt a plugin submits between turns — it starts this turn in the user's place. Address the message above.`
