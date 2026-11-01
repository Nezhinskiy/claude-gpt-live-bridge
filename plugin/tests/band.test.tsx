import { expect, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

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
    expect(kids(actions).map(button => button.props.label)).toEqual(['Stop', 'Load context'])
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
