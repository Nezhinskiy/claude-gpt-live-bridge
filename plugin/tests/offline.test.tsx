import { expect, test } from 'claude-code/testing'

import { BAND, fakeWorld, ID, LIVE, liveOn } from './fake-bridge.ts'

declare const setTimeout: (fn: () => void, ms: number) => unknown
/** Lets whatever is not held run as far as it can. */
const aMoment = () => new Promise<void>(resolve => setTimeout(resolve, 20))

test('offlineAppIsLaunchedOrExplained', async ($, on) => {
  const world = fakeWorld(on)
  world.isAppUp = false
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  expect((await $.command.run({ ...LIVE, args: '' })).text).toContain('not running')

  await world.clock.advance(1000)
  // Where both install routes put it first; then whatever app Launch Services knows by the
  // bundle id.
  expect(world.launches).toEqual([
    ['open', '-g', '/Applications/LiveBridge.app'],
    ['open', '-g', '-b', 'com.getlivebridge.livebridge'],
  ])
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await band.find({ type: 'Text', text: /menu bar/ }))?.text).toContain('Open LiveBridge from the menu bar')
  expect(await band.find({ type: 'Text', text: /bridge offline/ })).toBeUndefined()

  await world.clock.advance(10_000)
  expect(await band.find({ type: 'Text', text: /bridge offline/ })).toBeDefined()
  expect(world.launches).toHaveLength(2)

  world.isAppUp = true
  await world.clock.advance(1000)
  expect(world.take('join')).toHaveLength(1)
  expect(await band.find({ type: 'Text', text: /bridge offline|menu bar/ })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: /Voice off/ })).toBeDefined()
  await band.unmount()
})

test('aFailedPostMeansAMissedJoin', async ($, on) => {
  // The app is down for a turn; the join after it says so, once.
  const world = fakeWorld(on)
  world.turns = 0
  await liveOn($)
  world.take('join')
  world.isAppUp = false
  await $.turn.start({ text: 'Rename the folder', turnId: 't1' })
  await $.turn.complete({ durationMs: 1, isAborted: false, reason: 'answer', turnId: 't1', answer: 'Renamed.' })
  world.joined.delete(ID)
  world.isAppUp = true
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', syncs: true, writesSummaries: true, missed: true }])
  world.joined.delete(ID)
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', syncs: true, writesSummaries: true }])
})

test('anAppThatRestartedIsToldOfTheLineItLost', async ($, on) => {
  const world = fakeWorld(on)
  world.turns = 0
  await liveOn($)
  world.take('join')
  await $.turn.start({ text: 'Rename the folder', turnId: 't1' })
  world.joined.delete(ID)
  world.syncStatus = 404
  await $.turn.complete({ durationMs: 1, isAborted: false, reason: 'answer', turnId: 't1', answer: 'Renamed.' })
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', syncs: true, writesSummaries: true, missed: true }])
})

/** The voice never hears of the question or the prompt, so its picture of the turn has a hole. */
test('aPromptTheAppDidNotGetMeansAMissedJoin', async ($, on) => {
  const world = fakeWorld(on)
  await liveOn($)
  await $.turn.start({ text: 'Remove the build folder', turnId: 't1' })
  world.take('join')
  world.isAppUp = false
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'rm -r build' } })
  world.isAppUp = true
  await world.clock.advance(1000)
  expect(world.take('join').map(body => body?.missed)).toEqual([true])
})

test('aQuestionTheAppDidNotGetMeansAMissedJoin', async ($, on) => {
  const world = fakeWorld(on)
  await liveOn($)
  await $.turn.start({ text: 'Rename the folder', turnId: 't1' })
  world.take('join')
  world.isAppUp = false
  const asked = $.tool.call({ tool: 'AskUserQuestion', questions: [{ question: 'Which name?', options: [{ label: 'out' }] }] } as never)
  await aMoment()
  world.isAppUp = true
  await world.clock.advance(1000)
  expect(world.take('join').map(body => body?.missed)).toEqual([true])
  world.answerDialog('out')
  await asked
})

test('aFailedJoinKeepsTheGapForTheNextOne', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  world.isAppUp = false
  await $.command.run({ ...LIVE, args: '' })
  world.isAppUp = true
  await world.clock.advance(1000)
  expect(world.take('join').map(body => body?.missed)).toEqual([true])
})

test('anOlderAppWithNoSyncRouteTakesTheTurnAsBefore', async ($, on) => {
  const world = fakeWorld(on)
  await liveOn($)
  world.syncStatus = 404
  await $.turn.start({ text: 'Rename the folder', turnId: 't1' })
  await $.turn.complete({ durationMs: 1, isAborted: false, reason: 'answer', turnId: 't1', answer: 'Renamed.' })
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'working', turn: { id: 't1' } }, { sessionId: ID, state: 'idle', turn: { id: 't1' } }])
})

test('joiningAgainOpensTheAppAgain', async ($, on) => {
  // Off, then install or quit the app, then on: the next join tries to open it afresh.
  const world = fakeWorld(on)
  world.isAppUp = false
  await liveOn($)
  await world.clock.advance(11_000)
  const opened = world.launches.length
  await $.command.run({ ...LIVE, args: 'off' })
  await $.command.run({ ...LIVE, args: '' })
  await world.clock.advance(1000)
  expect(world.launches.length).toBeGreaterThan(opened)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /bridge offline/ })).toBeUndefined()
  await band.unmount()
})

test('anInstalledAppIsOpenedByItsPath', async ($, on) => {
  const world = fakeWorld(on)
  world.isAppUp = false
  world.isAppInstalled = true
  await liveOn($)
  await world.clock.advance(1000)
  expect(world.launches).toEqual([['open', '-g', '/Applications/LiveBridge.app']])
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /menu bar/ })).toBeUndefined()
  await band.unmount()
})
