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
  // One join that replaces the old id, so the app keeps the target and any open request.
  expect(world.take('leave')).toEqual([])
  expect(world.take('join')).toEqual([{ sessionId: OTHER, title: 'Example session', autoContext: false, replaces: ID }])
  expect(world.joined).toEqual(new Set([OTHER]))
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([])
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

test('aHalfWrittenRecordDoesNotBreakTheJoin', async ($, on) => {
  // Claude Code rewrites these files on every status change, so one may be empty or cut short.
  const world = fakeWorld(on)
  world.otherRecords = { '1.json': '', '2.json': '{"sessionId": "', '3.json': 'null' }
  await $.session.start(START)
  expect((await $.command.run({ ...VOICEMOD, args: 'on' })).text).toContain('Example session')
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', autoContext: false }])
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'working' }])
})

test('bareCommandShowsTheStatus', async ($, on) => {
  fakeWorld(on)
  await $.session.start(START)
  for (const args of ['', '   ']) expect((await $.command.run({ ...VOICEMOD, args })).text).toContain('Voice is off')
})

test('offDuringAPollSubmitsNothing', async ($, on) => {
  // The app hands out a request, then the owner leaves before the reply is read: leaving
  // reports the request failed, so the session must not act on it.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...VOICEMOD, args: 'on' })
  world.work.push({ kind: 'request', id: '00000000-0000-0000-0000-00000000000a', brief: 'Delete the build folder', transcript: [] })
  let release = () => {}
  world.holdNext = new Promise(resolve => { release = resolve })
  const held = new Promise<void>(resolve => { world.onNextHeld = resolve })
  const poll = world.clock.advance(1000)
  await held
  await $.command.run({ ...VOICEMOD, args: 'off' })
  release()
  await poll
  expect(world.submitted).toEqual([])
})
