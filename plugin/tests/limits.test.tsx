import { expect, test } from 'claude-code/testing'
import type { SessionRateLimit } from 'claude-code'

import { fakeWorld, ID, LIVE } from './fake-bridge.ts'

const OTHER = '11111111-0000-0000-0000-000000000002'

const START = { cwd: '/Users/example/Dev/example-project', surface: 'terminal', isInteractive: true } as const
const FIVE: SessionRateLimit = { kind: 'five_hour', percentUsed: 23.5, resetsAt: '2026-01-01T06:00:00Z' }
const WEEK: SessionRateLimit = { kind: 'seven_day', percentUsed: 7 }
const SPEND: SessionRateLimit = { kind: 'spend_limit', percentUsed: 50 }
declare const setTimeout: (fn: () => void, ms: number) => unknown
/** Lets whatever is not held run as far as it can. */
const aMoment = () => new Promise<void>(resolve => setTimeout(resolve, 20))

/** What `$.session.usage()` answers: these rate limits. */
const usage = (rateLimits: SessionRateLimit[]) => ({ value: { startedAt: 0, context: { window: 1000 }, rateLimits } })
const measure = (rateLimits: SessionRateLimit[], changed: ('context' | 'rateLimits')[] = ['rateLimits']) =>
  ({ context: { window: 1000 }, rateLimits, changed })

test('joiningSendsTheReading', async ($, on) => {
  const world = fakeWorld(on)
  on('session.usage', () => usage([FIVE, WEEK]))
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  await aMoment()
  // A window with no reset names none; the figures are the engine's.
  expect(world.take('limits')).toEqual([{ sessionId: ID, windows: [FIVE, WEEK] }])
})

test('anAppThatOpensLaterGetsTheReading', async ($, on) => {
  const world = fakeWorld(on)
  on('session.usage', () => usage([FIVE]))
  world.isAppUp = false
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  await world.clock.advance(1000)
  await aMoment()
  expect(world.take('limits')).toEqual([])
  world.isAppUp = true
  await world.clock.advance(1000)
  await aMoment()
  expect(world.take('limits')).toEqual([{ sessionId: ID, windows: [FIVE] }])
})

test('anAppRestartGetsTheReadingAgain', async ($, on) => {
  const world = fakeWorld(on)
  on('session.usage', () => usage([FIVE]))
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  await aMoment()
  expect(world.take('limits')).toHaveLength(1)
  world.joined.clear()  // the app restarted: its next poll answers 404
  await world.clock.advance(1000)
  await aMoment()
  expect(world.take('join')).toHaveLength(2)
  expect(world.take('limits')).toEqual([{ sessionId: ID, windows: [FIVE] }])
})

/** A turn did not reach the app, so the next poll joins again with `missed`. */
test('aRejoinThatSaysAGapSendsTheReading', async ($, on) => {
  const world = fakeWorld(on)
  on('session.usage', () => usage([FIVE]))
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  await aMoment()
  world.take('limits')
  world.take('join')
  world.syncStatus = 404
  await $.prompt.submit({ text: 'Rename the folder', wait: false, origin: { kind: 'composer' } as never })
  await $.turn.start({ text: 'Rename the folder', turnId: 't1' })
  world.syncStatus = 200
  await world.clock.advance(1000)
  await aMoment()
  expect(world.take('join')[0]?.missed).toBe(true)
  expect(world.take('limits')).toEqual([{ sessionId: ID, windows: [FIVE] }])
})

test('theOwnersJoinAfterARemovalSendsTheReading', async ($, on) => {
  const world = fakeWorld(on)
  on('session.usage', () => usage([FIVE]))
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  await aMoment()
  world.take('limits')
  world.removed.add(ID)
  await world.clock.advance(1000)
  await aMoment()
  expect(world.take('limits')).toEqual([])
  await $.command.run({ ...LIVE, args: 'on' })
  await aMoment()
  expect(world.take('limits')).toEqual([{ sessionId: ID, windows: [FIVE] }])
})

test('theJoinAfterClearSendsTheReadingUnderTheNewId', async ($, on) => {
  const world = fakeWorld(on)
  on('session.usage', () => usage([FIVE]))
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  await aMoment()
  world.take('limits')
  await $.session.end({ reason: 'clear', sessionId: ID, resume: { sessionId: ID } as never })
  world.sessionId = OTHER
  await world.clock.advance(1000)
  await aMoment()
  expect(world.take('limits')).toEqual([{ sessionId: OTHER, windows: [FIVE] }])
})

test('theResumeAfterAReloadSendsTheReading', async ($, on) => {
  const world = fakeWorld(on, { [`joined:${ID}`]: { pending: null, followUp: null, turns: [], hasGap: false } })
  on('session.usage', () => usage([FIVE]))
  await $.session.start(START)
  await aMoment()
  expect(world.take('limits')).toEqual([{ sessionId: ID, windows: [FIVE] }])
})

test('aMeasureWithRateLimitsSendsThem', async ($, on) => {
  const world = fakeWorld(on)
  on('session.usage', () => usage([]))
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  await aMoment()
  await $.session.measure(measure([FIVE, SPEND]))
  await aMoment()
  expect(world.take('limits')).toEqual([{ sessionId: ID, windows: [FIVE, SPEND] }])
})

test('aMeasureOfSomethingElseSendsNothing', async ($, on) => {
  const world = fakeWorld(on)
  on('session.usage', () => usage([]))
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  await $.session.measure(measure([FIVE], ['context']))
  await aMoment()
  expect(world.take('limits')).toEqual([])
})

test('aSessionNotJoinedSendsNothing', async ($, on) => {
  const world = fakeWorld(on)
  on('session.usage', () => usage([FIVE]))
  await $.session.start(START)
  await $.session.measure(measure([FIVE]))
  await aMoment()
  expect(world.take('limits')).toEqual([])
})

test('aRefusedSendChangesNothing', async ($, on) => {
  const world = fakeWorld(on)
  world.limitsStatus = 404
  on('session.usage', () => usage([FIVE]))
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: 'on' })
  await aMoment()
  expect(world.take('limits')).toHaveLength(1)
  world.take('join')
  await world.clock.advance(2000)
  expect(world.take('join')).toEqual([])
})

test('aUsageThatFailsDoesNotStopJoining', async ($, on) => {
  const world = fakeWorld(on)
  on('session.usage', () => { throw new Error('the engine refuses') })
  await $.session.start(START)
  expect((await $.command.run({ ...LIVE, args: 'on' })).text).toContain('Joined')
  await aMoment()
  expect(world.take('limits')).toEqual([])
})
