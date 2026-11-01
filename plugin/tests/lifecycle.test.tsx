import { expect, test } from 'claude-code/testing'

import { fakeWorld, ID, VOICEMOD } from './fake-bridge.ts'

const START = { cwd: '/Users/example/Dev/example-project', surface: 'terminal', isInteractive: true } as const
const OTHER = '22222222-0000-0000-0000-000000000003'

test('reloadResumesPolling', async ($, on) => {
  // A hot reload runs session.start again with the module's own variables gone; the store stays.
  const world = fakeWorld(on, { [`joined:${ID}`]: { pending: null, followUp: null, turns: [] } })
  await $.session.start(START)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', autoContext: false }])
  await world.clock.advance(1000)
  expect(world.take('next')).toHaveLength(1)
})

test('clearRejoinsWithNewId', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...VOICEMOD, args: 'on' })
  world.take('join')
  await $.session.end({ reason: 'clear', sessionId: ID, resume: { sessionId: ID } as never })
  world.sessionId = OTHER
  await world.clock.advance(1000)
  expect(world.take('leave')).toEqual([{ sessionId: ID }])
  expect(world.take('join')).toEqual([{ sessionId: OTHER, title: 'Example session', autoContext: false }])
  expect(world.joined).toEqual(new Set([OTHER]))
})

test('renameRejoins', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...VOICEMOD, args: 'on' })
  world.take('join')
  world.title = 'Renamed session'
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Renamed session', autoContext: false }])
})

test('offTurnsContextAutoAndLeaves', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...VOICEMOD, args: 'on' })
  await $.command.run({ ...VOICEMOD, args: 'context auto' })
  expect(world.take('join').at(-1)).toEqual({ sessionId: ID, title: 'Example session', autoContext: true })
  expect((await $.command.run({ ...VOICEMOD, args: 'off' })).text).toContain('Left')
  expect(world.take('leave')).toEqual([{ sessionId: ID }])
  await world.clock.advance(3000)
  expect(world.take('next')).toEqual([])
})
