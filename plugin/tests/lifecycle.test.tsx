import { expect, test } from 'claude-code/testing'

import type { Work } from '../hooks/wire.ts'
import { fakeWorld, framed, ID, LIVE } from './fake-bridge.ts'

const START = { cwd: '/Users/example/Dev/example-project', surface: 'terminal', isInteractive: true } as const
const OTHER = '22222222-0000-0000-0000-000000000003'
const REQUEST: Work = { kind: 'request', id: '00000000-0000-0000-0000-00000000000a', brief: 'Delete the build folder', transcript: [] }
const DONE = { durationMs: 1, isAborted: false, reason: 'answer' } as const
declare const setTimeout: (fn: () => void, ms: number) => unknown
/** Lets whatever is not held run as far as it can. */
const aMoment = () => new Promise<void>(resolve => setTimeout(resolve, 20))

test('reloadResumesPolling', async ($, on) => {
  // A hot reload runs session.start again with the module's own variables gone; the store stays.
  const world = fakeWorld(on, { [`joined:${ID}`]: { pending: null, followUp: null, turns: [] } })
  await $.session.start(START)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session' }])
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
  expect(world.take('join')).toEqual([{ sessionId: OTHER, title: 'Example session', replaces: ID }])
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
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Renamed session' }])
})

test('offLeaves', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
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
  expect((await $.command.run({ ...LIVE, args: 'on' })).text).toContain('Joined')
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session' }])
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
  // reports the request failed, so the session must not act on it. The off waits for the poll.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  world.work.push(REQUEST)
  let release = () => {}
  world.holdNext = new Promise(resolve => { release = resolve })
  const held = new Promise<void>(resolve => { world.onNextHeld = resolve })
  const poll = world.clock.advance(1000)
  await held
  const off = $.command.run({ ...LIVE, args: 'off' })
  await aMoment()
  release()
  await off
  await poll
  expect(world.submitted).toEqual([])
  expect(world.take('leave')).toEqual([{ sessionId: ID }])
})

test('aFixedHomeMovesTheSocketOnly', async ($, on) => {
  // CFFIXED_USER_HOME=/tmp/lb build-app.sh --run keeps the app's files there; the registry stays home.
  const world = fakeWorld(on, {}, { CFFIXED_USER_HOME: '/tmp/lb' })
  world.socket = '/tmp/lb/Library/Application Support/claude-gpt-live-bridge/run/bridge.sock'
  await $.session.start(START)
  expect((await $.command.run({ ...LIVE, args: 'on' })).text).toContain('Joined')
  expect(world.read.every(path => path.startsWith('/Users/example/.claude/sessions/'))).toBe(true)
})

test('theCommandIsLive', async ($, on) => {
  // `/voice` is Claude Code's own command (voice mode), so the engine refuses that name.
  const world = fakeWorld(on)
  await $.session.start(START)
  expect(world.commands).toEqual(['live'])
  expect((await $.command.run({ ...LIVE, args: 'help' })).text).toBe('Usage: /live on | off | target | status | context')
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
  // The owner removed it in the menu: joining again by itself would undo that.
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
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session' }])
})

test('aTitleGivenAfterTheJoinIsFollowedOnThePoll', async ($, on) => {
  // The desktop app may name a session seconds after the mod joined it, with no turn between.
  const world = fakeWorld(on)
  world.otherRecords = { '1.json': '{"sessionId":"11111111-0000-0000-0000-000000000002","name":"Other"}' }
  world.title = ''
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'example-project' }])
  world.title = 'Live mode'
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Live mode' }])
  // Once found, a poll reads this session's record alone.
  world.read = []
  await world.clock.advance(1000)
  expect(world.read).toEqual(['/Users/example/.claude/sessions/12345.json'])
  expect(world.take('join')).toEqual([])
})

test('theJoinNamesNoTitleTheAppWillReplace', async ($, on) => {
  // A new session's record first holds a name Claude Code derives from its folder; the desktop
  // app names it after its first prompt, and the app shows that name once the poll follows it.
  const world = fakeWorld(on)
  world.title = 'example-project-42'
  await $.session.start(START)
  const joined = (await $.command.run({ ...LIVE, args: 'on' })).text
  expect(joined).toContain('Joined')
  expect(joined).not.toContain('example-project')
  world.title = 'Live on'
  await world.clock.advance(1000)
  expect(world.take('join').at(-1)).toEqual({ sessionId: ID, title: 'Live on' })
})

test('offWhileAPollIsAtWorkNeverSubmitsAfterTheLeave', async ($, on) => {
  // Off lands while the poll that took a request is still writing: the leave fails the request
  // in the app, so a prompt for it may only come before that, never after.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  world.work.push(REQUEST)
  let release = () => {}
  world.holdStore = new Promise(resolve => { release = resolve })
  const held = new Promise<void>(resolve => { world.onStoreHeld = resolve })
  const poll = world.clock.advance(1000)
  await held
  const off = $.command.run({ ...LIVE, args: 'off' })
  await aMoment()
  release()
  expect((await off).text).toContain('Left')
  await poll
  await world.clock.advance(3000)
  expect(world.timeline.at(-1)).toBe('leave')
  expect(world.take('next')).toHaveLength(1)
  expect(world.stored.has(`joined:${ID}`)).toBe(false)
})

test('offWhileATitleIsFollowedStaysOff', async ($, on) => {
  // After /clear the poll joins under the new id; an off in the middle of it is not undone.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  await $.session.end({ reason: 'clear', sessionId: ID, resume: { sessionId: ID } as never })
  world.sessionId = OTHER
  let release = () => {}
  world.holdStore = new Promise(resolve => { release = resolve })
  const held = new Promise<void>(resolve => { world.onStoreHeld = resolve })
  const poll = world.clock.advance(1000)
  await held
  const off = $.command.run({ ...LIVE, args: 'off' })
  await aMoment()  // the off may run meanwhile, or wait for the poll
  release()
  await off
  await poll
  expect(world.joined).toEqual(new Set())
  expect((await $.command.run({ ...LIVE, args: 'status' })).text).toContain('Voice is off')
  expect((await $.command.run({ ...LIVE, args: 'on' })).text).toBe('Joined LiveBridge.')
})

test('aNewTitleDoesNotUndoARemove', async ($, on) => {
  // Any join clears the app's removal mark, so the poll asks before it follows a title.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  world.take('join')
  world.joined.delete(ID)
  world.removed.add(ID)
  world.title = 'Renamed session'
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([])
  expect(world.logs).toContain('Removed from LiveBridge. /live on joins again.')
})

test('aRemovalTheAnswerMeetsTurnsTheSessionOff', async ($, on) => {
  // The owner removed the session while its voice turn ran: the 410 on the answer is the
  // removal, not a lost answer.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  world.work.push(REQUEST)
  await world.clock.advance(1000)
  await $.turn.start({ text: framed(world.submitted[0]!), turnId: 't1' })
  world.joined.delete(ID)
  world.removed.add(ID)
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Deleted.' })
  world.take('next')
  await world.clock.advance(3000)
  expect(world.logs).toEqual(['Removed from LiveBridge. /live on joins again.'])
  expect(world.take('next')).toEqual([])
  expect((await $.command.run({ ...LIVE, args: 'status' })).text).toContain('Voice is off')
})
