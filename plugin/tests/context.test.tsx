// The app asks for this session's context (the line it opens does, and so does the voice's
// fetch): the summary and Claude's last reply, once per change, never for a new session, and
// with a short note in the band while it goes.
import { expect, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { askedText, voicePrompt } from '../hooks/prompt.ts'
import type { VoiceRequest } from '../hooks/wire.ts'
import { ASKED, BAND, fakeWorld, framed, ID, LIVE, model } from './fake-bridge.ts'

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

/** The app asks for the session's context; the poll that brings the ask is the one that runs it. */
async function appAsks(world: ReturnType<typeof fakeWorld>) {
  world.work.push({ kind: 'context' })
  await world.clock.advance(1000)
}

/** A typed turn that ends with `answer`. */
async function typedTurn($: Engine, turnId: string, answer: string) {
  await $.turn.start({ text: 'Count the files', turnId })
  await $.turn.complete({ ...DONE, turnId, answer })
}

const REQUEST: VoiceRequest = {
  id: '00000000-0000-0000-0000-00000000000a',
  brief: 'Please list the files in this folder',
  transcript: [{ role: 'user', text: 'Please list the files in this folder' }],
}

/** The band's note on the summary, if it shows one. */
const note = async (band: { find(query: { type: 'Text'; text: RegExp }): Promise<{ text?: string } | undefined> }) =>
  (await band.find({ type: 'Text', text: /^(Loading context…|Context sent)$/ }))?.text

test('startAsksNoContextItself', async ($, on) => {
  // The line the app opens asks for the context, so Start does not.
  const world = await joined($, on)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'call' })
  await world.clock.advance(1000)
  expect(world.take('target')).toEqual([{ sessionId: ID }])
  expect(world.take('call')).toEqual([{ action: 'start' }])
  expect(world.take('context')).toEqual([])
  expect(world.forks).toBe(0)
  await band.unmount()
})

test('theAppsAskPostsThisSessionsSummary', async ($, on) => {
  const world = await joined($, on)
  await appAsks(world)
  expect(world.take('context')).toEqual([SUMMARY])
  expect(world.forks).toBe(1)
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
  await appAsks(world)
  expect(world.take('context')).toEqual([])
  expect(world.forks).toBe(0)
  expect(await note(band)).toBeUndefined()
  await band.unmount()
})

test('askingAgainWithNoNewTurnAsksTheModelForNothing', async ($, on) => {
  const world = await joined($, on)
  await appAsks(world)
  expect(world.take('context')).toEqual([SUMMARY])
  // The summary the model wrote still holds, so it is sent as it was (the app may have erased it
  // with New conversation) and the model is not asked again.
  await appAsks(world)
  expect(world.take('context')).toEqual([SUMMARY])
  expect(world.forks).toBe(1)
  // A turn completes: the next ask gets a new summary.
  await typedTurn($, 't1', 'Renamed.')
  world.summary = 'Goal: tidy the example project. The helper is renamed.'
  await appAsks(world)
  expect(world.take('context')).toEqual([{ sessionId: ID, summary: world.summary, last: 'Renamed.' }])
  expect(world.forks).toBe(2)
})

test('theBandSaysLoadingThenSent', async ($, on) => {
  const world = await joined($, on)
  world.forkMs = 5000
  for (const surface of ['terminal', 'desktop'] as const) {
    world.summary = `Goal: tidy the example project (${surface}).`
    await typedTurn($, `t-${surface}`, 'Done.')
    const band = await $.ui.mount({ ...BAND, surface })
    await appAsks(world)
    expect(await note(band)).toBe('Loading context…')
    expect(world.take('context')).toEqual([])
    await world.clock.advance(5000)
    expect(world.take('context')).toEqual([{ sessionId: ID, summary: world.summary, last: 'Done.' }])
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
  await appAsks(world)
  expect(await note(band)).toBe('Loading context…')
  // The minute keeps its own timer, so the app holds its reply to the poll meanwhile: the clock
  // crosses the minute with one held poll instead of sixty, each a round trip a loaded machine
  // slows.
  let release = () => {}
  world.holdNext = new Promise<void>(resolve => { release = resolve })
  await world.clock.advance(59_999)
  expect(await note(band)).toBe('Loading context…')
  await world.clock.advance(1)
  release()
  world.holdNext = null
  expect(await note(band)).toBeUndefined()
  expect(world.logs.some(line => line.includes('could not summarise'))).toBe(true)
  // The next ask tries again instead of waiting on the lost one.
  world.forkMs = 0
  await appAsks(world)
  expect(world.forks).toBe(2)
  expect(world.take('context')).toEqual([SUMMARY])
  await band.unmount()
})

test('aFailedSummaryClearsTheNoteAndSaysSo', async ($, on) => {
  const world = await joined($, on)
  world.forkFails = 'api-error'
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await appAsks(world)
  expect(world.take('context')).toEqual([])
  expect(await note(band)).toBeUndefined()
  expect(world.logs.some(line => line.includes('could not summarise'))).toBe(true)
  await band.unmount()
})

test('twoAsksAtOnceShareOneSummary', async ($, on) => {
  // The app asks again while the first summary is being written: one summary serves both.
  const world = await joined($, on)
  world.forkMs = 5000
  await appAsks(world)
  await appAsks(world)
  await world.clock.advance(4000)
  expect(world.take('context')).toEqual([SUMMARY])
  expect(world.forks).toBe(1)
})

test('aContextCarriesClaudesLastReply', async ($, on) => {
  const world = await joined($, on)
  await typedTurn($, 't1', 'Three files.')
  await appAsks(world)
  expect(world.take('context')).toEqual([{ ...SUMMARY, last: 'Three files.' }])
})

test('anOpenQuestionComesWithTheTextThatAskedIt', async ($, on) => {
  const claude = model(on)
  const world = await joined($, on)
  await $.turn.start({ text: 'Rename the folder', turnId: 't1' })
  await claude.step($, 't1', 'Two folders.')
  const asked = $.tool.call({ tool: 'AskUserQuestion', questions: ASKED })
  await appAsks(world)
  expect(world.take('context')).toEqual([{ ...SUMMARY, last: `Two folders.\n\n${askedText(ASKED)}` }])
  world.answerDialog('build')
  await asked
  await appAsks(world)
  expect(world.take('context')).toEqual([SUMMARY])
})

test('aLongLastReplyIsClipped', async ($, on) => {
  const world = await joined($, on)
  const answer = ('x'.repeat(97) + '\n').repeat(205).slice(0, 20_000)
  await typedTurn($, 't1', answer)
  await appAsks(world)
  const [{ last }] = world.take('context') as [{ last: string }]
  expect(last.length).toBeLessThanOrEqual(8000)
  expect(last.length).toBeGreaterThan(7000)
  expect(answer.startsWith(`${last}\n`)).toBe(true)
})

test('aVoiceTurnKeepsTheSummaryCached', async ($, on) => {
  const world = await joined($, on)
  await appAsks(world)
  expect(world.forks).toBe(1)
  world.work.push({ kind: 'request', ...REQUEST })
  await world.clock.advance(1000)
  expect(world.submitted).toEqual([voicePrompt(REQUEST)])
  await $.turn.start({ text: framed(world.submitted[0]!), turnId: 't1' })
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Three files.' })
  await appAsks(world)
  expect(world.forks).toBe(1)
  await typedTurn($, 't2', 'Renamed.')
  await appAsks(world)
  expect(world.forks).toBe(2)
})

test('aFailedSummaryStillSendsTheLastReply', async ($, on) => {
  const world = await joined($, on)
  await typedTurn($, 't1', 'Three files.')
  world.forkFails = 'api-error'
  await appAsks(world)
  expect(world.take('context')).toEqual([{ sessionId: ID, summary: '', last: 'Three files.' }])
})

test('clearForgetsTheLastReply', async ($, on) => {
  const world = await joined($, on)
  await typedTurn($, 't1', 'Three files.')
  await appAsks(world)
  expect(world.take('context')).toEqual([{ ...SUMMARY, last: 'Three files.' }])
  // /clear gives the session a new id, which the next poll joins under.
  const cleared = '00000000-0000-0000-0000-000000000002'
  world.sessionId = cleared
  await world.clock.advance(1000)
  await appAsks(world)
  expect(world.take('context')).toEqual([{ sessionId: cleared, summary: SUMMARY.summary }])
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

test('onlyNothingToForkIsNothingToSummarise', async ($, on) => {
  // The engine answers an outage as a resolved api-error, which is a failure, not an empty session.
  const world = await joined($, on)
  world.forkFails = 'nothing-to-fork'
  expect((await $.command.run({ ...LIVE, args: 'context' })).text).toBe('Nothing to summarise yet.')
  world.forkFails = 'api-error'
  expect((await $.command.run({ ...LIVE, args: 'context' })).text).toContain('could not summarise')
  expect(world.take('context')).toEqual([])
})
