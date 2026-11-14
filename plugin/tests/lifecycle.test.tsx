import { expect, test } from 'claude-code/testing'

import type { StatusReply, Work } from '../hooks/wire.ts'
import { fakeWorld, framed, ID, LIVE, liveOn, SOCKET } from './fake-bridge.ts'

const START = { cwd: '/Users/example/Dev/example-project', surface: 'terminal', isInteractive: true } as const
const OTHER = '22222222-0000-0000-0000-000000000003'
const REQUEST: Work = { kind: 'request', id: '00000000-0000-0000-0000-00000000000a', brief: 'Delete the build folder', transcript: [] }
const DONE = { durationMs: 1, isAborted: false, reason: 'answer' } as const
const TYPED = { id: 't1' }
const VOICE = { id: 't1', request: REQUEST.id }
declare const setTimeout: (fn: () => void, ms: number) => unknown
/** Lets whatever is not held run as far as it can. */
const aMoment = () => new Promise<void>(resolve => setTimeout(resolve, 20))

test('reloadResumesPolling', async ($, on) => {
  // A hot reload runs session.start again with the module's own variables gone; the store stays.
  const world = fakeWorld(on, { [`joined:${ID}`]: { pending: null, followUp: null, turns: [] } })
  await $.session.start(START)
  expect(world.take('join')).toHaveLength(1)
  await world.clock.advance(1000)
  expect(world.take('next')).toHaveLength(1)
})

test('joinSaysItSyncs', async ($, on) => {
  const world = fakeWorld(on)
  world.turns = 0
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', owner: true, syncs: true, writesSummaries: true }])
})

/** Disabling the mod ends no session, so its key stays: enabled again, the snapshot is all there is. */
test('aTurnWhileTheModWasOffIsAGap', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Nothing.' })
  await world.clock.advance(1000)
  world.take('join')
  world.turns = 2
  await $.session.start(START)
  expect(world.take('join').map(body => body?.missed)).toEqual([true])
})

test('aReloadWithNoNewTurnIsNoGap', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Nothing.' })
  await world.clock.advance(1000)
  world.take('join')
  await $.session.start(START)
  expect(world.take('join').map(body => body?.missed)).toEqual([undefined])
})

test('aTurnBeforeJoiningIsMissed', async ($, on) => {
  // /live in a session with turns: the app got none of them.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Nothing.' })
  world.turns = 1
  await $.command.run({ ...LIVE, args: '' })
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', owner: true, syncs: true, writesSummaries: true, missed: true }])
  // Said once: the app has it.
  world.joined.delete(ID)
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', syncs: true, writesSummaries: true }])
})

test('aFreshSessionJoinsWithoutMissed', async ($, on) => {
  const world = fakeWorld(on)
  world.turns = 0
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  expect(world.take('join')[0]?.missed).toBeUndefined()
})

test('aSnapshotFromBeforeSyncIsAGap', async ($, on) => {
  const world = fakeWorld(on, { [`joined:${ID}`]: { pending: null, followUp: null, turns: [] } })
  await $.session.start(START)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', syncs: true, writesSummaries: true, missed: true }])
})

test('aSnapshotWithNoGapJoinsWithoutMissed', async ($, on) => {
  const world = fakeWorld(on, { [`joined:${ID}`]: { pending: null, followUp: null, turns: [], hasGap: false } })
  await $.session.start(START)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', syncs: true, writesSummaries: true }])
})

test('aGapSurvivesAReload', async ($, on) => {
  const world = fakeWorld(on)
  world.turns = 0
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  world.syncStatus = 500
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Nothing.' })
  expect((world.stored.get(`joined:${ID}`) as { hasGap?: boolean }).hasGap).toBe(true)
  world.syncStatus = 200
  world.take('join')
  await $.session.start(START)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', syncs: true, writesSummaries: true, missed: true }])
})

test('theSavedGapClearsOnceAJoinSaidIt', async ($, on) => {
  const world = fakeWorld(on)
  world.turns = 0
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  world.syncStatus = 500
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Nothing.' })
  world.syncStatus = 200
  await world.clock.advance(1000)
  expect((world.stored.get(`joined:${ID}`) as { hasGap?: boolean }).hasGap).toBe(false)
})

/** The turn's prompt and answer both go after the join that follows /clear, under the new id. */
test('aTurnAfterClearSyncsUnderTheNewId', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  await $.session.end({ reason: 'clear', sessionId: ID, resume: { sessionId: ID } as never })
  world.sessionId = OTHER
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Nothing.' })
  expect(world.take('sync').map(line => line?.sessionId)).toEqual([OTHER, OTHER])
})

test('clearRejoinsWithNewId', async ($, on) => {
  const world = fakeWorld(on)
  world.modVersion = '0.3.1'
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  world.take('join')
  await $.session.end({ reason: 'clear', sessionId: ID, resume: { sessionId: ID } as never })
  world.sessionId = OTHER
  await world.clock.advance(1000)
  // One join that replaces the old id, so the app keeps the target and any open request.
  expect(world.take('leave')).toEqual([])
  // It names the mod's version again, or Settings would list the session as on the old mod.
  expect(world.take('join')).toEqual([{ sessionId: OTHER, title: 'Example session', modVersion: '0.3.1', syncs: true, writesSummaries: true, replaces: ID }])
  expect(world.joined).toEqual(new Set([OTHER]))
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([])
})

test('renameRejoins', async ($, on) => {
  const world = fakeWorld(on)
  world.modVersion = '0.3.1'
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  world.take('join')
  world.title = 'Renamed session'
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Renamed session', modVersion: '0.3.1', syncs: true, writesSummaries: true }])
})

/** The app moved the conversation, its decision with it: the rest of the turn goes under the new id. */
test('aTurnRunningThroughClearKeepsItsTurn', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  world.take('sync')
  await $.session.end({ reason: 'clear', sessionId: ID, resume: { sessionId: ID } as never })
  world.sessionId = OTHER
  await world.clock.advance(1000)
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Nothing.' })
  expect(world.take('sync')).toEqual([{ sessionId: OTHER, turn: { id: 't1' }, kind: 'answer', text: 'Nothing.' }])
})

test('aTurnRunningThroughAReloadKeepsItsLines', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  await $.session.start(START)
  world.take('sync')
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Nothing.' })
  expect(world.take('sync')).toEqual([{ sessionId: ID, turn: { id: 't1' }, kind: 'answer', text: 'Nothing.' }])
})

/** It started while the mod was away, so neither its prompt nor its answer went to the app. */
test('aTurnTheModNeverSawStartIsAGap', async ($, on) => {
  const world = fakeWorld(on)
  world.turns = 0
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  world.take('join')
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Nothing.' })
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', syncs: true, writesSummaries: true, missed: true }])
})

const HELD = { pending: null, followUp: null, turns: [['t0', { id: null, isVoice: false }]], hasGap: false }

/** Crash, then --resume: the turn's end never came, so its answer never went. */
test('aTurnLeftInASnapshotIsAGapAtTheNextTurn', async ($, on) => {
  const world = fakeWorld(on, { [`joined:${ID}`]: HELD })
  await $.session.start(START)
  world.take('join')
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  await world.clock.advance(1000)
  expect(world.take('join').map(body => body?.missed)).toEqual([true])
})

test('aTurnNeverSeenIsAGapThoughASnapshotHoldsAnother', async ($, on) => {
  const world = fakeWorld(on, { [`joined:${ID}`]: HELD })
  await $.session.start(START)
  world.take('join')
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Nothing.' })
  await world.clock.advance(1000)
  expect(world.take('join').map(body => body?.missed)).toEqual([true])
})

/** The answer matters more than the snapshot: a store that fails costs the turn none of its lines. */
test('aSnapshotThatFailsCostsATurnNothing', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  world.isStoreBroken = true
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Nothing.' })
  expect(world.take('sync')).toHaveLength(2)
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'working', turn: TYPED }, { sessionId: ID, state: 'idle', turn: TYPED }])
})

/** /clear gives the session a new id, whose join runs in `turn.start`; forgetting the old key can fail there. */
test('aStoreThatFailsAfterClearCostsATurnNothing', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  await $.session.end({ reason: 'clear', sessionId: ID, resume: { sessionId: ID } as never })
  world.sessionId = OTHER
  world.isStoreBroken = true
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  expect(world.joined).toEqual(new Set([OTHER]))
  expect(world.take('sync').map(line => line?.sessionId)).toEqual([OTHER])
  expect(world.take('activity')).toEqual([{ sessionId: OTHER, state: 'working', turn: TYPED }])
})

/** Work is handed out once: a join that said a gap must not lose what its poll brought. */
test('aSnapshotThatFailsCostsThePollItsWork', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  world.syncStatus = 503
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  world.syncStatus = 200
  world.isStoreBroken = true
  world.work.push(REQUEST)
  await world.clock.advance(1000)
  await aMoment()
  expect(world.submitted).toHaveLength(1)
})

test('offLeaves', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
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
  expect((await $.command.run({ ...LIVE, args: '' })).text).toContain('Joined')
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', owner: true, syncs: true, writesSummaries: true, missed: true }])
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'working', turn: TYPED }])
})

const USAGE = 'Usage: /live | /live off'
/** Everything `/live` does not take; `target`, `status` and `context` were commands once. */
const NOT_COMMANDS = ['target', 'status', 'context', 'help', 'on now', 'off now']
const STATUS_LINE = 'LiveBridge: off; target: none; 0 unheard; 0 min today.'

test('theBareCommandJoins', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  expect((await $.command.run({ ...LIVE, args: '' })).text).toBe('Joined LiveBridge.')
  expect(world.joined).toEqual(new Set([ID]))
})

test('spacesAreNoArguments', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  expect((await $.command.run({ ...LIVE, args: '   ' })).text).toBe('Joined LiveBridge.')
  expect(world.joined).toEqual(new Set([ID]))
})

test('theCommandInAJoinedSessionAnswersTheStatus', async ($, on) => {
  const world = fakeWorld(on)
  await liveOn($)
  await world.clock.advance(1000)
  world.take('join')
  expect((await $.command.run({ ...LIVE, args: '' })).text).toBe(STATUS_LINE)
  expect(world.take('join')).toEqual([])
})

/** The engine gives up on a command after 10 s, and an app that is stuck holds a poll for longer. */
test('theCommandInAJoinedSessionDoesNotWaitForAPoll', async ($, on) => {
  const world = fakeWorld(on)
  await liveOn($)
  await world.clock.advance(1000)
  world.invalidated.length = 0
  let release = () => {}
  world.holdNext = new Promise(resolve => { release = resolve })
  const held = new Promise<void>(resolve => { world.onNextHeld = resolve })
  const poll = world.clock.advance(1000)
  await held
  const waited = new Promise<string>(resolve => { setTimeout(() => resolve('it waited'), 1000) })
  const answer = await Promise.race([$.command.run({ ...LIVE, args: '' }).then(reply => reply.text), waited])
  const drawn = [...world.invalidated]
  release()
  await poll
  expect(answer).toBe(STATUS_LINE)
  expect(drawn).toEqual(['ui.render'])
})

/** The join is on its way, so the band is not there yet: nothing says voice is off. */
test('theCommandDuringTheJoinSaysItIsJoining', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  let release = () => {}
  world.holdStore = new Promise(resolve => { release = resolve })
  const held = new Promise<void>(resolve => { world.onStoreHeld = resolve })
  const first = $.command.run({ ...LIVE, args: '' })
  await held
  const waited = new Promise<string>(resolve => { setTimeout(() => resolve('it waited'), 1000) })
  const answer = await Promise.race([$.command.run({ ...LIVE, args: '' }).then(reply => reply.text), waited])
  release()
  await first
  expect(answer).toBe('LiveBridge: joining…')
})

/** Both pass the look before the queue while a leave runs, so the one that waits looks again. */
test('twoCommandsBehindALeaveJoinOnce', async ($, on) => {
  const world = fakeWorld(on)
  await liveOn($)
  world.take('join')
  let release = () => {}
  world.holdStore = new Promise(resolve => { release = resolve })
  const held = new Promise<void>(resolve => { world.onStoreHeld = resolve })
  const off = $.command.run({ ...LIVE, args: 'off' })
  await held
  const answers = [$.command.run({ ...LIVE, args: '' }), $.command.run({ ...LIVE, args: '' })]
  await aMoment()
  release()
  await off
  expect((await Promise.all(answers)).map(reply => reply.text)).toEqual(['Joined LiveBridge.', 'LiveBridge: joining…'])
  expect(world.take('join')).toHaveLength(1)
})

/** What the last join drew is gone: a status from before off must not answer for the new join. */
test('aJoinAfterOffStartsFromNoBand', async ($, on) => {
  const world = fakeWorld(on)
  await liveOn($)
  await world.clock.advance(1000)
  await $.command.run({ ...LIVE, args: 'off' })
  await $.command.run({ ...LIVE, args: '' })
  expect((await $.command.run({ ...LIVE, args: '' })).text).toBe('LiveBridge: joining…')
})

/** As after off: the removal takes the band with it. */
test('aJoinAfterARemovalStartsFromNoBand', async ($, on) => {
  const world = fakeWorld(on)
  await liveOn($)
  await world.clock.advance(1000)
  world.joined.delete(ID)
  world.removed.add(ID)
  await world.clock.advance(1000)
  await $.command.run({ ...LIVE, args: '' })
  expect((await $.command.run({ ...LIVE, args: '' })).text).toBe('LiveBridge: joining…')
})

test('aRepeatedCommandNeverLeaves', async ($, on) => {
  const world = fakeWorld(on)
  await liveOn($)
  await world.clock.advance(1000)
  for (let time = 0; time < 3; time += 1) await $.command.run({ ...LIVE, args: '' })
  expect(world.take('leave')).toEqual([])
  expect(world.joined).toEqual(new Set([ID]))
  world.take('next')
  await world.clock.advance(1000)
  expect(world.take('next')).toHaveLength(1)
})

test('onIsKeptForOldHabits', async ($, on) => {
  const world = fakeWorld(on)
  world.turns = 0
  await $.session.start(START)
  expect((await $.command.run({ ...LIVE, args: 'on' })).text).toBe('Joined LiveBridge.')
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', owner: true, syncs: true, writesSummaries: true }])
  await world.clock.advance(1000)
  expect((await $.command.run({ ...LIVE, args: 'on' })).text).toBe(STATUS_LINE)
  expect(world.take('leave')).toEqual([])
})

test('anythingElseInAJoinedSessionAnswersTheUsageAndChangesNothing', async ($, on) => {
  const world = fakeWorld(on)
  await liveOn($)
  await world.clock.advance(1000)
  world.calls = []
  world.invalidated.length = 0
  for (const args of NOT_COMMANDS) expect((await $.command.run({ ...LIVE, args })).text).toBe(USAGE)
  expect(world.calls).toEqual([])
  expect(world.forks).toBe(0)
  expect(world.invalidated).toEqual([])
  expect(world.joined).toEqual(new Set([ID]))
})

test('anythingElseOutsideASessionAnswersTheUsageAndJoinsNothing', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  for (const args of NOT_COMMANDS) expect((await $.command.run({ ...LIVE, args })).text).toBe(USAGE)
  expect(world.calls).toEqual([])
  expect(world.launches).toEqual([])
})

/** scripts/check-mod.sh leans on this: it probes a headless session with `/live off`. */
test('offInASessionNotJoinedTouchesNothing', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  expect((await $.command.run({ ...LIVE, args: 'off' })).text).toBe('This session has not joined LiveBridge.')
  expect(world.calls).toEqual([])
  expect(world.launches).toEqual([])
})

test('offDuringAPollSubmitsNothing', async ($, on) => {
  // The app hands out a request, then the owner leaves before the reply is read: leaving
  // reports the request failed, so the session must not act on it. The off waits for the poll.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
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
  world.socket = SOCKET.replace('/Users/example/', '/tmp/lb/')
  await $.session.start(START)
  expect((await $.command.run({ ...LIVE, args: '' })).text).toContain('Joined')
  expect(world.read.every(path => path.startsWith('/Users/example/.claude/sessions/'))).toBe(true)
})

test('theCommandIsLive', async ($, on) => {
  // `/voice` is Claude Code's own command (voice mode), so the engine refuses that name.
  const world = fakeWorld(on)
  await $.session.start(START)
  expect(world.commands).toEqual(['live'])
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
  await $.command.run({ ...LIVE, args: '' })
  await world.clock.advance(1000)
  world.take('join')
  world.joined.delete(ID)
  world.removed.add(ID)
  await world.clock.advance(1000)
  expect(world.logs).toContain('Removed from LiveBridge. /live joins again.')
  world.take('next')
  await world.clock.advance(3000)
  expect(world.take('join')).toEqual([])
  expect(world.take('next')).toEqual([])
  expect(world.take('leave')).toEqual([])
  expect((await $.command.run({ ...LIVE, args: 'off' })).text).toBe('This session has not joined LiveBridge.')
  // A reload does not resume it either; /live joins again.
  await $.session.start(START)
  expect(world.take('join')).toEqual([])
  expect((await $.command.run({ ...LIVE, args: '' })).text).toContain('Joined')
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', owner: true, syncs: true, writesSummaries: true, missed: true }])
})

test('aTitleGivenAfterTheJoinIsFollowedOnThePoll', async ($, on) => {
  // The desktop app may name a session seconds after the mod joined it, with no turn between.
  const world = fakeWorld(on)
  world.otherRecords = { '1.json': '{"sessionId":"11111111-0000-0000-0000-000000000002","name":"Other"}' }
  world.title = ''
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'example-project', owner: true, syncs: true, writesSummaries: true, missed: true }])
  world.title = 'Live mode'
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Live mode', syncs: true, writesSummaries: true }])
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
  const joined = (await $.command.run({ ...LIVE, args: '' })).text
  expect(joined).toContain('Joined')
  expect(joined).not.toContain('example-project')
  world.title = 'Live on'
  await world.clock.advance(1000)
  expect(world.take('join').at(-1)).toEqual({ sessionId: ID, title: 'Live on', syncs: true, writesSummaries: true })
})

test('offWhileAPollIsAtWorkNeverSubmitsAfterTheLeave', async ($, on) => {
  // Off lands while the poll that took a request is still writing: the leave fails the request
  // in the app, so a prompt for it may only come before that, never after.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
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

/** A reload would otherwise join again with no action of the owner's. */
test('offWhileASaveCountsTheTurnsStaysOff', async ($, on) => {
  const world = fakeWorld(on)
  await liveOn($)
  await $.turn.start({ text: 'Rename the folder', turnId: 't1' })
  await world.clock.advance(1000)
  let release = () => {}
  world.holdTurns = new Promise(resolve => { release = resolve })
  const done = $.turn.complete({ ...DONE, turnId: 't1', answer: 'Renamed.' })
  await aMoment()
  await $.command.run({ ...LIVE, args: 'off' })
  release()
  await done
  await aMoment()
  expect(world.stored.has(`joined:${ID}`)).toBe(false)
})

test('offWhileATitleIsFollowedStaysOff', async ($, on) => {
  // After /clear the poll joins under the new id; an off in the middle of it is not undone.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
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
  expect((await $.command.run({ ...LIVE, args: 'off' })).text).toBe('This session has not joined LiveBridge.')
  expect((await $.command.run({ ...LIVE, args: '' })).text).toBe('Joined LiveBridge.')
})

test('aNewTitleDoesNotUndoARemove', async ($, on) => {
  // Any join clears the app's removal mark, so the poll asks before it follows a title.
  const world = fakeWorld(on)
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  world.take('join')
  world.joined.delete(ID)
  world.removed.add(ID)
  world.title = 'Renamed session'
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([])
  expect(world.logs).toContain('Removed from LiveBridge. /live joins again.')
})

test('aRemovalTheAnswerMeetsTurnsTheSessionOff', async ($, on) => {
  // The owner removed the session while its voice turn ran: the 410 on the answer is the
  // removal, not a lost answer.
  const world = fakeWorld(on)
  world.modVersion = '0.3.1'
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  world.work.push(REQUEST)
  await world.clock.advance(1000)
  await $.turn.start({ text: framed(world.submitted[0]!), turnId: 't1' })
  world.joined.delete(ID)
  world.removed.add(ID)
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Deleted.' })
  world.take('next')
  await world.clock.advance(3000)
  expect(world.logs).toEqual(['Removed from LiveBridge. /live joins again.'])
  expect(world.take('next')).toEqual([])
  expect((await $.command.run({ ...LIVE, args: 'off' })).text).toBe('This session has not joined LiveBridge.')
})

/** The app answers the line 404, so the gap's join is what meets the removal: nothing is reopened. */
test('aRemovalALineMeetsTurnsTheSessionOff', async ($, on) => {
  const world = fakeWorld(on)
  world.modVersion = '0.3.1'
  await $.session.start(START)
  await $.command.run({ ...LIVE, args: '' })
  await $.turn.start({ text: 'What changed?', turnId: 't1' })
  world.joined.delete(ID)
  world.removed.add(ID)
  world.take('join')
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Nothing.' })
  await world.clock.advance(3000)
  expect(world.logs).toEqual(['Removed from LiveBridge. /live joins again.'])
  expect(world.take('join').map(body => body?.owner)).toEqual([undefined])
  expect(world.launches).toEqual([])
  expect((await $.command.run({ ...LIVE, args: 'off' })).text).toBe('This session has not joined LiveBridge.')
})

/** The join names the mod's version, read from its own plugin.json, for the app's Settings. */
test('theJoinNamesTheModsVersion', async ($, on) => {
  const world = fakeWorld(on)
  world.modVersion = '0.3.1'
  await liveOn($)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', owner: true, modVersion: '0.3.1', syncs: true, writesSummaries: true, missed: true }])
})

/** A mod that cannot read its own plugin.json says so: Settings will list it as on the old mod. */
test('anUnreadManifestIsLogged', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start(START)
  expect(world.logs.some(line => line.includes('could not read its version'))).toBe(true)
})

/** This session as the call's target, and the same app with another session as the target. */
const asTarget = (isTarget: boolean): StatusReply => ({
  call: 'listening', unheard: 0, minutesToday: 0, isMuted: false,
  sessions: [
    { sessionId: ID, label: 'Example session', activity: 'idle', isTarget },
    { sessionId: OTHER, label: 'Other session', activity: 'idle', isTarget: !isTarget },
  ],
})

/** The summary ask reaches the target on its poll, so the target polls every 200 ms. */
test('theTargetPollsFiveTimesASecond', async ($, on) => {
  const world = fakeWorld(on)
  world.status = asTarget(true)
  await liveOn($)
  await world.clock.advance(1000)  // the first poll says this session is the target
  world.take('next')
  await world.clock.advance(1000)
  expect(world.take('next')).toHaveLength(5)
})

test('othersPollOnceASecond', async ($, on) => {
  const world = fakeWorld(on)
  world.status = asTarget(false)
  await liveOn($)
  await world.clock.advance(1000)
  world.take('next')
  for (let at = 200; at < 1000; at += 200) {
    await world.clock.advance(200)
    expect(world.take('next')).toEqual([])
  }
  await world.clock.advance(200)
  expect(world.take('next')).toHaveLength(1)
})

/** The title still follows the session's record once a second, not on every poll. */
test('aFastTickDoesNotFollowTheTitle', async ($, on) => {
  const world = fakeWorld(on)
  world.status = asTarget(true)
  await liveOn($)
  await world.clock.advance(1000)
  world.take('join')
  world.take('next')
  world.read.length = 0
  world.title = 'Renamed session'
  await world.clock.advance(800)
  expect(world.take('next')).toHaveLength(4)
  expect(world.read).toEqual([])
  expect(world.take('join')).toEqual([])
  await world.clock.advance(200)
  expect(world.take('join').map(body => body?.title)).toEqual(['Renamed session'])
})

/** A poll that takes most of a second leaves the once-a-second work running about once a second. */
test('aSlowPollStillFollowsTheTitle', async ($, on) => {
  const world = fakeWorld(on)
  world.status = asTarget(true)
  await liveOn($)
  await world.clock.advance(1000)
  world.take('join')
  world.nextMs = 900
  world.title = 'Renamed session'
  await world.clock.advance(3000)
  expect(world.take('join').map(body => body?.title)).toEqual(['Renamed session'])
})

/** A fast tick whose reply changes nothing the band shows writes nothing, so it redraws nothing. */
test('anUnchangedBandIsNotRewritten', async ($, on) => {
  const world = fakeWorld(on)
  world.status = asTarget(true)
  const writes: unknown[] = []
  on('state.set', async (_, e, next) => {
    writes.push(e.value)
    return next(e)
  })
  await liveOn($)
  await world.clock.advance(1000)
  world.take('next')
  writes.length = 0
  await world.clock.advance(800)
  expect(world.take('next')).toHaveLength(4)
  expect(writes).toEqual([])
})

/** The minutes grow while a line is open, and the band draws none of them. */
test('aLiveLinesMinutesDoNotRewriteTheBand', async ($, on) => {
  const world = fakeWorld(on)
  world.status = { ...asTarget(true), call: 'live' }
  const writes: unknown[] = []
  on('state.set', async (_, e, next) => {
    writes.push(e.value)
    return next(e)
  })
  await liveOn($)
  await world.clock.advance(1000)
  world.take('next')
  writes.length = 0
  for (const minutesToday of [0.01, 0.02, 0.03, 0.04]) {
    world.status = { ...asTarget(true), call: 'live', minutesToday }
    await world.clock.advance(200)
  }
  expect(world.take('next')).toHaveLength(4)
  expect(writes).toEqual([])
})

test('aFastTickWritesAChangedBand', async ($, on) => {
  const world = fakeWorld(on)
  world.status = asTarget(true)
  const writes: unknown[] = []
  on('state.set', async (_, e, next) => {
    writes.push(e.value)
    return next(e)
  })
  await liveOn($)
  await world.clock.advance(1000)
  writes.length = 0
  world.status = { ...asTarget(true), call: 'live' }
  await world.clock.advance(200)
  expect(writes).toMatchObject([{ status: { call: 'live' } }])
})
