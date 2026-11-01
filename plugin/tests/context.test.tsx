// The band's Start loads this session's context: once per change, never for a new session, and
// with a short note in the band while it goes.
import { expect, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

import { BAND, fakeWorld, ID, LIVE } from './fake-bridge.ts'

const DONE = { durationMs: 1, isAborted: false, reason: 'answer' } as const
const SUMMARY = { sessionId: ID, summary: 'Goal: tidy the example project.' }

/** Joined, the call off, this session the target. */
async function joined(...[$, on]: Parameters<TestBody>) {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...LIVE, args: 'on' })
  world.status = {
    ...world.status, call: 'off',
    sessions: [{ sessionId: ID, label: 'Example session', activity: 'idle', isTarget: true }],
  }
  await world.clock.advance(1000)
  world.calls = []
  return world
}

/** The band's note on the summary, if it shows one. */
const note = async (band: { find(query: { type: 'Text'; text: RegExp }): Promise<{ text?: string } | undefined> }) =>
  (await band.find({ type: 'Text', text: /^(Loading context…|Context sent)$/ }))?.text

test('startLoadsThisSessionsContext', async ($, on) => {
  const world = await joined($, on)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'call' })
  expect(world.take('target')).toEqual([{ sessionId: ID }])
  expect(world.take('call')).toEqual([{ action: 'start' }])
  expect(world.take('context')).toEqual([SUMMARY])
  expect(world.forks).toBe(1)
  await band.unmount()
})

test('theBandHasNoLoadContextButton', async ($, on) => {
  const world = await joined($, on)
  for (const surface of ['terminal', 'desktop'] as const) {
    const band = await $.ui.mount({ ...BAND, surface })
    expect(await band.find({ key: 'context' })).toBeUndefined()
    expect((await band.findAll({ type: 'Button' })).map(button => button.props.label)).toEqual(['Start'])
    await band.unmount()
  }
  expect(world.forks).toBe(0)
})

test('aNewSessionHasNoContextToLoad', async ($, on) => {
  const world = await joined($, on)
  world.turns = 0
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'call' })
  expect(world.take('call')).toEqual([{ action: 'start' }])
  expect(world.take('context')).toEqual([])
  expect(world.forks).toBe(0)
  expect(await note(band)).toBeUndefined()
  await band.unmount()
})

test('startAgainWithNoNewTurnAsksTheModelForNothing', async ($, on) => {
  const world = await joined($, on)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'call' })
  expect(world.take('context')).toEqual([SUMMARY])
  // Stop, then Start again: the summary the model wrote still holds, so it is sent as it was (the
  // app may have erased it with New conversation) and the model is not asked again.
  await band.press({ key: 'call' })
  expect(world.take('context')).toEqual([SUMMARY])
  expect(world.forks).toBe(1)
  // A turn completes: the next Start asks for a new summary.
  await $.turn.start({ text: 'Rename the helper', turnId: 't1' })
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Renamed.' })
  world.summary = 'Goal: tidy the example project. The helper is renamed.'
  await band.press({ key: 'call' })
  expect(world.take('context')).toEqual([{ sessionId: ID, summary: world.summary }])
  expect(world.forks).toBe(2)
  await band.unmount()
})

test('theBandSaysLoadingThenSent', async ($, on) => {
  const world = await joined($, on)
  world.forkMs = 5000
  for (const surface of ['terminal', 'desktop'] as const) {
    world.summary = `Goal: tidy the example project (${surface}).`
    await $.turn.start({ text: 'Next step', turnId: `t-${surface}` })
    await $.turn.complete({ ...DONE, turnId: `t-${surface}`, answer: 'Done.' })
    const band = await $.ui.mount({ ...BAND, surface })
    await band.press({ key: 'call' })
    expect(await note(band)).toBe('Loading context…')
    expect(world.take('context')).toEqual([])
    await world.clock.advance(5000)
    expect(world.take('context')).toEqual([{ sessionId: ID, summary: world.summary }])
    expect(await note(band)).toBe('Context sent')
    await world.clock.advance(3000)
    expect(await note(band)).toBeUndefined()
    await band.unmount()
  }
})

test('aSummaryThatNeverComesStopsLoadingAfterAMinute', async ($, on) => {
  const world = await joined($, on)
  world.forkMs = 10 * 60_000
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'call' })
  expect(await note(band)).toBe('Loading context…')
  await world.clock.advance(60_000)
  expect(await note(band)).toBeUndefined()
  expect(world.logs.some(line => line.includes('could not summarise'))).toBe(true)
  // The next Start tries again instead of waiting on the lost one.
  world.forkMs = 0
  await band.press({ key: 'call' })
  expect(world.forks).toBe(2)
  expect(world.take('context')).toEqual([SUMMARY])
  await band.unmount()
})

test('aFailedSummaryClearsTheNoteAndSaysSo', async ($, on) => {
  const world = await joined($, on)
  world.isForkFailing = true
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'call' })
  expect(world.take('call')).toEqual([{ action: 'start' }])
  expect(world.take('context')).toEqual([])
  expect(await note(band)).toBeUndefined()
  expect(world.logs.some(line => line.includes('could not summarise'))).toBe(true)
  await band.unmount()
})

test('theAppsAskDuringStartsSummaryWaitsForIt', async ($, on) => {
  // With automatic context on in the app, it asks as Start makes the session the target: one
  // summary serves both.
  const world = await joined($, on)
  world.forkMs = 5000
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'call' })
  world.work.push({ kind: 'context' })
  await world.clock.advance(1000)
  await world.clock.advance(4000)
  expect(world.take('context')).toEqual([SUMMARY])
  expect(world.forks).toBe(1)
  await band.unmount()
})

test('liveContextAsksTheModelEachTime', async ($, on) => {
  // The manual path: the owner asked for a summary, so it is written again.
  const world = await joined($, on)
  expect((await $.command.run({ ...LIVE, args: 'context' })).text).toContain('Sent a summary')
  expect((await $.command.run({ ...LIVE, args: 'context' })).text).toContain('Sent a summary')
  expect(world.forks).toBe(2)
  world.turns = 0
  expect((await $.command.run({ ...LIVE, args: 'context' })).text).toBe('Nothing to summarise yet.')
  expect(world.forks).toBe(2)
})
