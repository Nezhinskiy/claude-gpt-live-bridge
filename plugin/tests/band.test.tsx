import { expect, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

import type { StatusReply } from '../hooks/wire.ts'
import { BAND, fakeWorld, ID, LIVE } from './fake-bridge.ts'

type Node = { type: string; props: Record<string, unknown>; children?: unknown[] }
const kids = (node: Node) =>
  (node.children ?? []).filter((child): child is Node => typeof child === 'object' && child !== null)
const all = (node: Node): Node[] => [node, ...kids(node).flatMap(all)]
const holding = (root: Node, type: string) => all(root).find(node => kids(node).some(child => child.type === type))

const SURFACES = ['terminal', 'desktop'] as const

async function joined(...[$, on]: Parameters<TestBody>) {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...LIVE, args: 'on' })
  world.status = {
    ...world.status, call: 'listening', unheard: 2,
    sessions: [{ sessionId: ID, label: 'Example session', activity: 'idle', isTarget: true }],
  }
  await world.clock.advance(1000)
  return world
}

test('theBandIsOneRowWithItsButtonsApart', async ($, on) => {
  await joined($, on)
  for (const surface of SURFACES) {
    const band = await $.ui.mount({ ...BAND, surface })
    const root = await band.drawn() as Node
    expect(kids(root)).toHaveLength(1)
    // The status to the left, the buttons in a group of their own to the right, with room between.
    const row = kids(root)[0]!
    expect(row.props).toMatchObject({ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' })
    const actions = holding(root, 'Button')!
    expect(actions).not.toBe(row)
    expect(actions.props.columnGap).toBeDefined()
    expect(kids(actions).map(button => button.props.label)).toEqual(['Stop'])
    expect((await band.find({ key: 'call' }))?.props.variant).toBe('primary')
    await band.unmount()
  }
})

test('aProblemSitsOnARowOfItsOwn', async ($, on) => {
  const world = await joined($, on)
  world.status = { ...world.status, problem: 'Codex is not signed in: run codex login in a terminal, then start again.' }
  await world.clock.advance(1000)
  for (const surface of SURFACES) {
    const band = await $.ui.mount({ ...BAND, surface })
    const root = await band.drawn() as Node
    const [status, problem] = kids(root)
    expect(kids(root)).toHaveLength(2)
    expect(all(status!).some(node => node.type === 'Button')).toBe(true)
    expect(all(problem!).some(node => node.type === 'Button')).toBe(false)
    expect((await band.find({ type: 'Text', text: /not signed in/ }))?.props.color).toBe('warning')
    await band.unmount()
  }
})

test('beforeTheFirstReplyTheBandSaysItIsJoining', async ($, on) => {
  fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...LIVE, args: 'on' })
  for (const surface of SURFACES) {
    const band = await $.ui.mount({ ...BAND, surface })
    expect(await band.find({ type: 'Text', text: /joining/ })).toBeDefined()
    expect(await band.findAll({ type: 'Button' })).toEqual([])
    await band.unmount()
  }
})

test('joiningAsksEverySurfaceToDrawTheBandAgain', async ($, on) => {
  // A surface keeps the band it drew last. One that drew it before this mod's hook ran (the
  // desktop app opening a new session, whose band it asked a process with no hooks) read no
  // state, so writing the band redraws nothing there and the band never shows: the join asks
  // for every instance again.
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(world.invalidated).toEqual([])
  await $.command.run({ ...LIVE, args: 'on' })
  expect(world.invalidated).toEqual(['ui.render'])
})

const OTHER = '11111111-0000-0000-0000-000000000002'
const elsewhere = (call: 'off' | 'listening'): StatusReply => ({
  call, unheard: 0, minutesToday: 0, minutesThisCall: 0, recentTranscript: [],
  sessions: [
    { sessionId: OTHER, label: 'Other session', activity: 'idle', isTarget: true },
    { sessionId: ID, label: 'Example session', activity: 'idle', isTarget: false },
  ],
})

test('startMakesThisSessionTheTargetThenStarts', async ($, on) => {
  // Starting from a session means talking to it: one press, no separate "Make target".
  const world = await joined($, on)
  world.status = elsewhere('off')
  await world.clock.advance(1000)
  for (const surface of SURFACES) {
    world.calls = []
    const band = await $.ui.mount({ ...BAND, surface })
    const root = await band.drawn() as Node
    expect(kids(holding(root, 'Button')!).map(button => button.props.label)).toEqual(['Start'])
    await band.press({ key: 'call' })
    const routes = world.calls.map(call => call.route).filter(route => route === 'target' || route === 'call')
    expect(routes).toEqual(['target', 'call'])
    expect(world.take('target')).toEqual([{ sessionId: ID }])
    expect(world.take('call')).toEqual([{ action: 'start' }])
    await band.unmount()
  }
})

test('talkHereShowsOnlyWhileTheCallTalksToAnotherSession', async ($, on) => {
  const world = await joined($, on)
  world.status = elsewhere('listening')
  await world.clock.advance(1000)
  for (const surface of SURFACES) {
    const band = await $.ui.mount({ ...BAND, surface })
    const root = await band.drawn() as Node
    expect(kids(holding(root, 'Button')!).map(button => button.props.label)).toEqual(['Stop', 'Talk here'])
    await band.press({ key: 'target' })
    expect(world.take('target')).toEqual([{ sessionId: ID }])
    expect(world.take('call')).toEqual([])
    await band.unmount()
  }
})
