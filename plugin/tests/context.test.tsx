// The app asks for this session's context (the line it opens does): the summary, once per change,
// never for a new session, and with a short note in the band while it goes.
import { expect, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { voicePrompt } from '../hooks/prompt.ts'
import { transcriptText } from '../hooks/transcript.ts'
import type { VoiceRequest } from '../hooks/wire.ts'
import { BAND, fakeWorld, framed, ID, liveOn } from './fake-bridge.ts'

const DONE = { durationMs: 1, isAborted: false, reason: 'answer' } as const
const SUMMARY = { sessionId: ID, summary: 'Goal: tidy the example project.' }

/** Joined, the call off, this session the target. */
async function joined(...[$, on]: Parameters<TestBody>) {
  const world = fakeWorld(on)
  await liveOn($)
  world.status = {
    ...world.status, call: 'off',
    sessions: [{ sessionId: ID, label: 'Example session', activity: 'idle', isTarget: true }],
  }
  await world.clock.advance(1000)
  world.calls = []
  return world
}

/**
 * The app asks for the session's context, naming a model or, as an older app, none; the poll that
 * brings the ask is the one that runs it.
 */
async function appAsks(world: ReturnType<typeof fakeWorld>, ask: { model?: string; fallbackModel?: string; ask?: number } = {}) {
  world.work.push({ kind: 'context', ...ask })
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
  (await band.find({ type: 'Text', text: /^(Loading context…|Context sent|Context failed)$/ }))?.text

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
  expect(world.take('context')).toEqual([{ sessionId: ID, summary: world.summary }])
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

test('everyCompletedTurnStalesTheSummary', async ($, on) => {
  // The app asks for one when the conversation could not carry something: it must not be a
  // summary from before that, which would clear the out-of-sync mark with nothing new.
  const world = await joined($, on)
  await appAsks(world)
  expect(world.forks).toBe(1)
  world.work.push({ kind: 'request', ...REQUEST })
  await world.clock.advance(1000)
  expect(world.submitted).toEqual([voicePrompt(REQUEST)])
  await $.turn.start({ text: framed(world.submitted[0]!), turnId: 't1' })
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Three files.' })
  await appAsks(world)
  expect(world.forks).toBe(2)
  await typedTurn($, 't2', 'Renamed.')
  await appAsks(world)
  expect(world.forks).toBe(3)
})

/** The prompt never reached the app, so a summary from before it would clear the mark with it still lost. */
test('aGapStalesTheSummary', async ($, on) => {
  const world = await joined($, on)
  await appAsks(world)
  expect(world.forks).toBe(1)
  world.syncStatus = 503
  await $.turn.start({ text: 'Count the files', turnId: 't1' })
  world.syncStatus = 200
  await world.clock.advance(1000)
  await appAsks(world)
  expect(world.forks).toBe(2)
})

/** Crash, then --resume: t1 never ended, and neither its lines nor its answer reached the app. */
test('aTurnLostAtTheNextStartStalesTheSummary', async ($, on) => {
  const world = await joined($, on)
  await appAsks(world)
  expect(world.forks).toBe(1)
  await $.turn.start({ text: 'Count the files', turnId: 't1' })
  await $.turn.start({ text: 'Count them again', turnId: 't2' })
  await world.clock.advance(1000)
  await appAsks(world)
  expect(world.forks).toBe(2)
})

/** Only the mod knows the gap came while the summary was written. */
test('aSummaryWrittenAcrossAGapIsNotPosted', async ($, on) => {
  const world = await joined($, on)
  world.forkMs = 5000
  await appAsks(world)
  expect(world.forks).toBe(1)
  world.syncStatus = 503
  await $.turn.start({ text: 'Count the files', turnId: 't1' })
  world.syncStatus = 200
  await world.clock.advance(5000)
  expect(world.logs.some(line => line.includes('could not summarise'))).toBe(true)
  expect(world.take('context')).toEqual([])
})

/** A gap ends a send under way, and only that: the note of one already sent still comes down. */
test('aGapAfterASummaryWasSentLeavesItsNoteToGo', async ($, on) => {
  const world = await joined($, on)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await appAsks(world)
  expect(await note(band)).toBe('Context sent')
  world.syncStatus = 503
  await $.turn.start({ text: 'Count the files', turnId: 't1' })
  world.syncStatus = 200
  await world.clock.advance(3000)
  expect(await note(band)).toBeUndefined()
  await band.unmount()
})

test('clearMakesTheContextSummariseAgain', async ($, on) => {
  // /clear starts a new transcript, so the summary of the old one is not sent for it.
  const world = await joined($, on)
  await appAsks(world)
  expect(world.forks).toBe(1)
  await $.session.end({ reason: 'clear', sessionId: ID, resume: { sessionId: ID } as never })
  const cleared = '00000000-0000-0000-0000-000000000002'
  world.sessionId = cleared
  await world.clock.advance(1000)  // the poll rejoins under the new id
  await appAsks(world)
  expect(world.forks).toBe(2)
  expect(world.take('context')).toEqual([SUMMARY, { ...SUMMARY, sessionId: cleared }])
})

test('nothingToForkIsNoFailure', async ($, on) => {
  // The engine answers an outage as a resolved api-error, which is a failure, not an empty session.
  const world = await joined($, on)
  world.forkFails = 'nothing-to-fork'
  await appAsks(world)
  expect(world.take('context')).toEqual([])
  expect(world.logs.some(line => line.includes('could not summarise'))).toBe(false)
})

const OPUS = 'claude-opus-5-5'
const HAIKU = 'claude-haiku-5-5'
const MINUTE = 60_000
/** An ask from an app that names a model other than its default. */
const NAMED = { model: OPUS, fallbackModel: HAIKU }

test('aNamedModelWritesWithComplete', async ($, on) => {
  const world = await joined($, on)
  world.completeMs = 6400
  await appAsks(world, NAMED)
  await world.clock.advance(6400)
  const transcript = transcriptText(world.messages)
  expect(world.take('context')).toEqual([{
    ...SUMMARY,
    stats: { durationMs: 6400, transcriptChars: transcript.length, inputTokens: 13105, outputTokens: 412 },
  }])
  expect(world.completes).toEqual([expect.objectContaining({ model: OPUS, effort: 'low', maxTokens: 4096 })])
  expect(world.completes[0]!.prompt).toContain(transcript)
  expect(world.forks).toBe(0)
})

test('aFailedModelFallsBackOnce', async ($, on) => {
  const world = await joined($, on)
  const cases = [
    ['refused', { reason: 'model-refused' }],
    ['api-error', { reason: 'api-error', error: 'overloaded' }],
    ['empty-reply', { reason: 'empty-reply' }],
  ] as const
  for (const [fails, failure] of cases) {
    await typedTurn($, `t-${fails}`, 'Done.')
    world.completes = []
    world.completeFails = { [OPUS]: fails }
    await appAsks(world, NAMED)
    expect(world.take('context')).toEqual([expect.objectContaining({ ...SUMMARY, failures: [failure] })])
    expect(world.completes.map(one => one.model)).toEqual([OPUS, HAIKU])
  }
})

test('aTimeOutDoesNotFallBack', async ($, on) => {
  const world = await joined($, on)
  world.completeFails = { [OPUS]: 'held' }
  await appAsks(world, NAMED)
  // The app holds its reply to the poll, so the clock crosses the minute with one held poll.
  let release = () => {}
  world.holdNext = new Promise<void>(resolve => { release = resolve })
  await world.clock.advance(MINUTE)
  release()
  world.holdNext = null
  expect(world.take('context')).toEqual([{ ...SUMMARY, summary: '', failures: [{ reason: 'timed-out' }] }])
  expect(world.completes.map(one => [one.model, one.timeoutMs])).toEqual([[OPUS, MINUTE]])
})

test('noFallbackWhenTheModelIsTheDefault', async ($, on) => {
  const world = await joined($, on)
  world.completeFails = { [HAIKU]: 'api-error' }
  await appAsks(world, { model: HAIKU })
  expect(world.take('context')).toEqual([
    { ...SUMMARY, summary: '', failures: [{ reason: 'api-error', error: 'overloaded' }] },
  ])
  expect(world.completes.map(one => one.model)).toEqual([HAIKU])
})

test('bothFailingGivesNoTextAndTwoFailures', async ($, on) => {
  const world = await joined($, on)
  world.completeFails = { [OPUS]: 'refused', [HAIKU]: 'empty-reply' }
  await appAsks(world, NAMED)
  expect(world.take('context')).toEqual([
    { ...SUMMARY, summary: '', failures: [{ reason: 'model-refused' }, { reason: 'empty-reply' }] },
  ])
  expect(world.completes.map(one => one.model)).toEqual([OPUS, HAIKU])
})

// An app that names a model is answered at every exit, so it never waits on an ask the mod dropped.

const saidNoSummary = (world: ReturnType<typeof fakeWorld>) => world.logs.some(line => line.includes('could not summarise'))

test('noTurnsPostsEmptyWithoutFailures', async ($, on) => {
  const world = await joined($, on)
  world.turns = 0
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await appAsks(world, NAMED)
  expect(world.take('context')).toEqual([{ ...SUMMARY, summary: '' }])
  expect(world.completes).toEqual([])
  expect(await note(band)).toBeUndefined()
  expect(saidNoSummary(world)).toBe(false)
  await band.unmount()
})

test('bothModelsFailingPostsEmptyWithTwoFailures', async ($, on) => {
  const world = await joined($, on)
  world.completeFails = { [OPUS]: 'api-error', [HAIKU]: 'empty-reply' }
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await appAsks(world, NAMED)
  expect(world.take('context')).toEqual([
    { ...SUMMARY, summary: '', failures: [{ reason: 'api-error', error: 'overloaded' }, { reason: 'empty-reply' }] },
  ])
  expect(saidNoSummary(world)).toBe(true)
  expect(await note(band)).toBe('Context failed')
  await band.unmount()
})

test('theDeadlinePostsTimedOut', async ($, on) => {
  // The first model fails late; the fallback gets only what is left of the minute, then the ask is answered.
  const world = await joined($, on)
  world.completeMs = 50_000
  world.completeFails = { [OPUS]: 'api-error', [HAIKU]: 'held' }
  await appAsks(world, NAMED)
  let release = () => {}
  world.holdNext = new Promise<void>(resolve => { release = resolve })
  await world.clock.advance(MINUTE - 1)
  expect(world.take('context')).toEqual([])
  await world.clock.advance(1)
  release()
  world.holdNext = null
  expect(world.take('context')).toEqual([
    { ...SUMMARY, summary: '', failures: [{ reason: 'api-error', error: 'overloaded' }, { reason: 'timed-out' }] },
  ])
  expect(world.completes.map(one => one.timeoutMs)).toEqual([MINUTE, MINUTE - 50_000])
  expect(saidNoSummary(world)).toBe(true)
})

test('aGapDuringTheWriteStillPosts', async ($, on) => {
  // The app asked before the gap, so it ignores this answer as stale; it is an answer all the same.
  const world = await joined($, on)
  world.completeMs = 5000
  await appAsks(world, NAMED)
  world.syncStatus = 503
  await $.turn.start({ text: 'Count the files', turnId: 't1' })
  world.syncStatus = 200
  await world.clock.advance(5000)
  expect(world.take('context')).toEqual([expect.objectContaining(SUMMARY)])
})

test('aThrowWhileReadingTheTranscriptPostsEmpty', async ($, on) => {
  const world = await joined($, on)
  world.isTranscriptBroken = true
  await appAsks(world, NAMED)
  expect(world.take('context')).toEqual([{ ...SUMMARY, summary: '' }])
  expect(world.completes).toEqual([])
  expect(saidNoSummary(world)).toBe(true)
})

test('anAskAfterAGapDoesNotJoinTheDoomedSend', async ($, on) => {
  const world = await joined($, on)
  world.completeMs = 5000
  await appAsks(world, NAMED)
  world.syncStatus = 503
  await $.turn.start({ text: 'Count the files', turnId: 't1' })
  world.syncStatus = 200
  await appAsks(world, NAMED)
  expect(world.completes).toHaveLength(2)
  await world.clock.advance(5000)
  expect(world.take('context')).toHaveLength(2)
})

test('anAskWithoutAModelIsAsBefore', async ($, on) => {
  // An older app: the session's own model forks, and nothing is posted when there is nothing to fork.
  const world = await joined($, on)
  await appAsks(world)
  expect(world.take('context')).toEqual([SUMMARY])
  expect([world.forks, world.completes.length]).toEqual([1, 0])
  await typedTurn($, 't1', 'Renamed.')
  world.forkFails = 'nothing-to-fork'
  await appAsks(world)
  expect(world.take('context')).toEqual([])
})

test('aCachedFallbackSummaryKeepsItsFailures', async ($, on) => {
  const world = await joined($, on)
  world.completeFails = { [OPUS]: 'refused' }
  await appAsks(world, NAMED)
  expect(world.take('context')).toEqual([expect.objectContaining({ ...SUMMARY, failures: [{ reason: 'model-refused' }] })])
  // No turn since: the same model asked again gets what was written, and why, with no model call.
  await appAsks(world, NAMED)
  expect(world.take('context')).toEqual([{ ...SUMMARY, failures: [{ reason: 'model-refused' }] }])
  expect(world.completes.map(one => one.model)).toEqual([OPUS, HAIKU])
})

test('theSummaryEchoesItsAsk', async ($, on) => {
  const world = await joined($, on)
  await appAsks(world, { ...NAMED, ask: 7 })
  expect(world.take('context')).toEqual([expect.objectContaining({ ...SUMMARY, ask: 7 })])
  // A replay of the kept summary answers the ask that asked for it.
  await appAsks(world, { ...NAMED, ask: 8 })
  expect(world.take('context')).toEqual([expect.objectContaining({ ...SUMMARY, ask: 8 })])
  expect(world.completes.map(one => one.model)).toEqual([OPUS])
})

test('aSendANewerAskReplacedIsNoFailure', async ($, on) => {
  // The app numbered the second ask as another, after a gap or a forget: each send answers its own.
  const world = await joined($, on)
  world.completeMs = 5000
  await appAsks(world, { ...NAMED, ask: 1 })
  await appAsks(world, { ...NAMED, ask: 2 })
  await world.clock.advance(5000)
  expect(world.take('context')).toEqual([
    expect.objectContaining({ ...SUMMARY, ask: 1 }), expect.objectContaining({ ...SUMMARY, ask: 2 }),
  ])
  expect(saidNoSummary(world)).toBe(false)
})

test('aJoinSaysItWritesSummaries', async ($, on) => {
  const world = fakeWorld(on)
  await liveOn($)
  expect(world.take('join')).toEqual([expect.objectContaining({ sessionId: ID, writesSummaries: true })])
})
