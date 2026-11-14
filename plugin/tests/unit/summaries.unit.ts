import assert from 'node:assert/strict'
import { test } from 'node:test'

import { SENT_NOTE_MS, SummarySends } from '../../hooks/summaries.ts'
import type { ContextAsk, ContextNote, SendPort, Summary } from '../../hooks/summaries.ts'
import { CONTEXT_TIMEOUT_MS } from '../../hooks/wire.ts'
import type { ContextBody } from '../../hooks/wire.ts'

const SUMMARY = 'Goal: tidy the example project.'
const NAMED = { model: 'claude-opus-5-5', fallbackModel: 'claude-haiku-5-5' }
const API_ERROR = { reason: 'api-error', error: 'overloaded' } as const

/** Lets every send go as far as it can before the test goes on. */
const settle = () => new Promise(resolve => setImmediate(resolve))

/**
 * A session's sends against a fake engine and app that takes every post: each write gives
 * `written`, each fork its text, both after `gate`. A timer runs only when `pass` runs it.
 */
function session() {
  const sends = new SummarySends()
  const timers: { ms: number; run(): void; isDone: boolean }[] = []
  let release = () => {}
  const world = {
    sends,
    hasTurns: true,
    written: { text: SUMMARY, failures: [] } as Summary,
    isForkFailing: false,
    gate: Promise.resolve(),
    writes: 0,
    forks: 0,
    failed: 0,
    posts: [] as Omit<ContextBody, 'sessionId'>[],
    notes: [] as ContextNote[],
    /** Holds every write and fork until `release`. */
    hold: () => { world.gate = new Promise<void>(resolve => { release = resolve }) },
    release: () => release(),
    ask: (ask: ContextAsk = {}) => sends.ask(ask, port),
    /** Runs the timers set for `ms`, as if that long passed. */
    pass: (ms: number) => timers.filter(one => one.ms === ms && !one.isDone).forEach(one => { one.isDone = true; one.run() }),
  }
  const port: SendPort = {
    hasTurns: async () => world.hasTurns,
    write: async ask => {
      if (ask.model === undefined) world.forks += 1
      else world.writes += 1
      await world.gate
      if (world.isForkFailing && ask.model === undefined) throw new Error('the model wrote no summary (api-error)')
      return world.written
    },
    post: async body => (world.posts.push(body), true),
    note: async note => world.notes.push(note),
    after: (ms, run) => {
      const timer = { ms, run, isDone: false }
      timers.push(timer)
      return { cancel: () => { timer.isDone = true } }
    },
    failed: () => { world.failed += 1 },
  }
  return world
}

test('aSessionWithNoTurnsAsksNoModel', async () => {
  const world = session()
  world.hasTurns = false
  await world.ask()
  await world.ask({ ...NAMED, ask: 1 })
  // Only the app that waits on its answer gets one.
  assert.deepEqual(world.posts, [{ summary: '', ask: 1 }])
  assert.deepEqual([world.forks, world.writes, world.notes, world.failed], [0, 0, [], 0])
})

test('aKeptSummaryIsSentAgainUntilATurnCompletes', async () => {
  const world = session()
  await world.ask()
  await world.ask()
  assert.deepEqual(world.posts, [{ summary: SUMMARY }, { summary: SUMMARY }])
  assert.equal(world.forks, 1)
  world.sends.end('turn')
  await world.ask()
  assert.equal(world.forks, 2)
})

test('aSummaryWrittenAcrossATurnIsNotKept', async () => {
  const world = session()
  world.hold()
  const first = world.ask(NAMED)
  await settle()
  world.sends.end('turn')
  world.release()
  await first
  await world.ask(NAMED)
  assert.equal(world.writes, 2)
})

test('aTurnEndingDuringAWriteDoesNotCrossIt', async () => {
  // The app got the turn's lines, so the send is not stale; its summary is only not kept.
  const world = session()
  world.hold()
  const first = world.ask()
  await settle()
  world.sends.end('turn')
  world.release()
  await first
  assert.deepEqual([world.posts, world.failed], [[{ summary: SUMMARY }], 0])
})

test('onlyTheModelThatWroteTheKeptSummaryGetsIt', async () => {
  const world = session()
  await world.ask(NAMED)
  await world.ask({ model: NAMED.fallbackModel })
  await world.ask()
  assert.deepEqual([world.writes, world.forks], [2, 1])
})

test('aKeptSummaryKeepsItsFailures', async () => {
  const world = session()
  const stats = { durationMs: 1, transcriptChars: 1, inputTokens: 1, outputTokens: 1 }
  world.written = { text: SUMMARY, failures: [{ reason: 'model-refused' }], stats }
  await world.ask(NAMED)
  await world.ask(NAMED)
  assert.deepEqual(world.posts[1], { summary: SUMMARY, failures: [{ reason: 'model-refused' }] })
  assert.equal(world.writes, 1)
})

test('aKeptSummaryAnswersTheAskThatAskedForIt', async () => {
  const world = session()
  await world.ask({ ...NAMED, ask: 7 })
  await world.ask({ ...NAMED, ask: 8 })
  assert.deepEqual(world.posts.map(one => one.ask), [7, 8])
  assert.equal(world.writes, 1)
})

test('anAskWithTheSendsNumberJoinsIt', async () => {
  // An older app's asks have no number, so each joins the one on its way.
  for (const ask of [{}, { ...NAMED, ask: 1 }]) {
    const world = session()
    world.hold()
    const first = world.ask(ask)
    await world.ask(ask)
    world.release()
    await first
    assert.equal(world.posts.length, 1)
    assert.equal(world.forks + world.writes, 1)
  }
})

test('aFailingSendItsJoinedAskSharesFailsOnce', async () => {
  const world = session()
  world.written = { text: '', failures: [API_ERROR, API_ERROR] }
  world.hold()
  const first = world.ask({ ...NAMED, ask: 1 })
  await world.ask({ ...NAMED, ask: 1 })
  world.release()
  await first
  assert.equal(world.failed, 1)
  assert.deepEqual(world.notes, ['loading', 'failed'])
})

test('aSendANewerAskReplacedIsNoFailure', async () => {
  // The app numbered the second ask as another, after a gap or a forget: each send answers its own.
  const world = session()
  world.hold()
  const first = world.ask({ ...NAMED, ask: 1 })
  const second = world.ask({ ...NAMED, ask: 2 })
  world.release()
  await Promise.all([first, second])
  assert.deepEqual(world.posts.map(one => one.ask), [1, 2])
  assert.equal(world.failed, 0)
})

test('aForkThatWritesNothingClearsTheNoteAndFails', async () => {
  const world = session()
  world.isForkFailing = true
  await world.ask()
  assert.deepEqual([world.posts, world.notes, world.failed], [[], ['loading', undefined], 1])
})

test('aForkThatNeverComesIsOverAfterAMinute', async () => {
  const world = session()
  world.hold()
  const first = world.ask()
  await settle()
  world.pass(CONTEXT_TIMEOUT_MS)
  await first
  assert.deepEqual([world.notes, world.failed], [['loading', undefined], 1])
  // The next ask tries again instead of waiting on the lost one, whose summary is dropped.
  const second = world.ask()
  world.release()
  await second
  await settle()
  assert.deepEqual([world.forks, world.posts], [2, [{ summary: SUMMARY }]])
})

test('anAskAsAForkTimesOutStartsItsOwnSend', async () => {
  const world = session()
  world.hold()
  void world.ask()
  await settle()
  world.pass(CONTEXT_TIMEOUT_MS)
  void world.ask()  // before the timed-out send has taken its note down
  await settle()
  assert.equal(world.forks, 2)
})

test('aForkCrossedByAGapIsNotPosted', async () => {
  // Only the mod knows the gap came while the summary was written.
  const world = session()
  world.hold()
  const first = world.ask()
  await settle()
  world.sends.end('gap')
  world.release()
  await first
  assert.deepEqual([world.posts, world.failed], [[], 1])
})

test('aClearCrossesTheSendOnItsWay', async () => {
  // The old transcript's summary is not posted for the new one.
  const world = session()
  world.hold()
  const first = world.ask()
  await settle()
  world.sends.end('clear')
  world.release()
  await first
  assert.deepEqual([world.posts, world.failed], [[], 1])
})

test('aNamedSendCrossedByAGapStillPostsItsAnswer', async () => {
  // The app asked before the gap, so it ignores this answer as stale; it is an answer all the same.
  const world = session()
  world.hold()
  const first = world.ask({ ...NAMED, ask: 1 })
  await settle()
  world.sends.end('gap')
  world.release()
  await first
  assert.deepEqual(world.posts, [{ summary: SUMMARY, ask: 1 }])
  assert.deepEqual([world.notes, world.failed], [['loading', undefined], 0])
})

test('anAskAfterAGapDoesNotJoinTheCrossedSend', async () => {
  const world = session()
  world.hold()
  const first = world.ask(NAMED)
  await settle()
  world.sends.end('gap')
  const second = world.ask(NAMED)
  world.release()
  await Promise.all([first, second])
  assert.deepEqual([world.writes, world.posts.length], [2, 2])
})

test('theSentNoteComesDownOnlyForTheLatestSend', async () => {
  const world = session()
  await world.ask()
  world.sends.end('gap')  // a gap ends a send under way, and only that
  world.pass(SENT_NOTE_MS)
  assert.deepEqual(world.notes, ['loading', 'sent', undefined])
  await world.ask()
  await world.ask()  // a newer send's note stays up for it
  world.notes = []
  world.pass(SENT_NOTE_MS)
  assert.deepEqual(world.notes, [undefined])
})
