import { expect, test } from 'claude-code/testing'

import { fakeWorld, ID, LIVE } from './fake-bridge.ts'

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
  await $.command.run({ ...LIVE, args: 'on' })
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
  await $.command.run({ ...LIVE, args: 'on' })
  world.take('join')
  world.title = 'Renamed session'
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Renamed session', autoContext: false }])
})

test('offTurnsContextAutoAndLeaves', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  await $.command.run({ ...LIVE, args: 'context auto' })
  expect(world.take('join').at(-1)).toEqual({ sessionId: ID, title: 'Example session', autoContext: true })
  expect((await $.command.run({ ...LIVE, args: 'off' })).text).toContain('Left')
  expect(world.take('leave')).toEqual([{ sessionId: ID }])
  await world.clock.advance(3000)
  expect(world.take('next')).toEqual([])
})

test('aHalfWrittenRecordDoesNotBreakTheJoin', async ($, on) => {
  // Claude Code rewrites these files on every status change, so one may be empty or cut short.
  const world = fakeWorld(on)
  world.otherRecords = { '1.json': '', '2.json': '{"sessionId": "', '3.json': 'null' }
  await $.session.start(START)
  expect((await $.command.run({ ...LIVE, args: 'on' })).text).toContain('Example session')
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', autoContext: false }])
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'working' }])
})

test('bareCommandShowsTheStatus', async ($, on) => {
  fakeWorld(on)
  await $.session.start(START)
  for (const args of ['', '   ']) expect((await $.command.run({ ...LIVE, args })).text).toContain('Voice is off')
})

test('offDuringAPollSubmitsNothing', async ($, on) => {
  // The app hands out a request, then the owner leaves before the reply is read: leaving
  // reports the request failed, so the session must not act on it.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  world.work.push({ kind: 'request', id: '00000000-0000-0000-0000-00000000000a', brief: 'Delete the build folder', transcript: [] })
  let release = () => {}
  world.holdNext = new Promise(resolve => { release = resolve })
  const held = new Promise<void>(resolve => { world.onNextHeld = resolve })
  const poll = world.clock.advance(1000)
  await held
  await $.command.run({ ...LIVE, args: 'off' })
  release()
  await poll
  expect(world.submitted).toEqual([])
})

test('aFixedHomeMovesTheSocketOnly', async ($, on) => {
  // CFFIXED_USER_HOME=/tmp/lb build-app.sh --run keeps the app's files there; the registry stays home.
  const world = fakeWorld(on, {}, { CFFIXED_USER_HOME: '/tmp/lb' })
  world.socket = '/tmp/lb/Library/Application Support/claude-gpt-live-bridge/run/bridge.sock'
  await $.session.start(START)
  expect((await $.command.run({ ...LIVE, args: 'on' })).text).toContain('Example session')
  expect(world.read.every(path => path.startsWith('/Users/example/.claude/sessions/'))).toBe(true)
})

test('theCommandIsLive', async ($, on) => {
  // `/voice` is Claude Code's own command (voice mode), so the engine refuses that name.
  const world = fakeWorld(on)
  await $.session.start(START)
  expect(world.commands).toEqual(['live'])
  expect((await $.command.run({ ...LIVE, args: 'help' })).text).toBe('Usage: /live on | off | target | status | context [auto|manual]')
  expect((await $.command.run({ ...LIVE, args: 'status' })).text).toContain('/live on')
})

test('aRefusedCommandStillResumesTheJoin', async ($, on) => {
  const world = fakeWorld(on, { [`joined:${ID}`]: { pending: null, followUp: null, turns: [] } })
  world.isCommandRefused = true
  await $.session.start(START)
  expect(world.take('join')).toHaveLength(1)
  expect(world.logs.some(line => line.includes('/live'))).toBe(true)
})

test('aSurfaceThatAttachesLaterIsToldOfTheCommand', async ($, on) => {
  // The desktop app attaches to a session the mod may have loaded into before; declaring the
  // command again announces it to every attached client.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.session.attach({ surface: 'desktop', clientId: 'desktop:default' })
  expect(world.commands).toEqual(['live', 'live'])
})

test('aRemovedSessionTurnsItselfOffAndDoesNotRejoin', async ($, on) => {
  // The owner removed it in the popover: joining again by itself would undo that.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  await world.clock.advance(1000)
  world.take('join')
  world.joined.delete(ID)
  world.removed.add(ID)
  await world.clock.advance(1000)
  expect(world.logs).toContain('Removed from LiveBridge. /live on joins again.')
  world.take('next')
  await world.clock.advance(3000)
  expect(world.take('join')).toEqual([])
  expect(world.take('next')).toEqual([])
  expect(world.take('leave')).toEqual([])
  expect((await $.command.run({ ...LIVE, args: 'status' })).text).toContain('Voice is off')
  // A reload does not resume it either; /live on joins again.
  await $.session.start(START)
  expect(world.take('join')).toEqual([])
  expect((await $.command.run({ ...LIVE, args: 'on' })).text).toContain('Joined')
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', autoContext: false }])
})

test('aTitleGivenAfterTheJoinIsFollowedOnThePoll', async ($, on) => {
  // The desktop app may name a session seconds after the mod joined it, with no turn between.
  const world = fakeWorld(on)
  world.otherRecords = { '1.json': '{"sessionId":"11111111-0000-0000-0000-000000000002","name":"Other"}' }
  world.title = ''
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'example-project', autoContext: false }])
  world.title = 'Live mode'
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Live mode', autoContext: false }])
  // Once found, a poll reads this session's record alone.
  world.read = []
  await world.clock.advance(1000)
  expect(world.read).toEqual(['/Users/example/.claude/sessions/12345.json'])
  expect(world.take('join')).toEqual([])
})
