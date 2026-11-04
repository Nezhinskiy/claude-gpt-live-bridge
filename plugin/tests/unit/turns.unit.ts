import assert from 'node:assert/strict'
import { test } from 'node:test'

import { FRAMING, voicePrompt } from '../../hooks/prompt.ts'
import { clip, clipToEnd, FOLLOW_UP_MS, originOf, TurnTracker } from '../../hooks/turns.ts'

const ID = '00000000-0000-0000-0000-00000000000a'
const framed = (id: string) =>
  `${FRAMING}${voicePrompt({ id, brief: 'List the files', transcript: [] })}\n\nThis is how Claude Code surfaces a prompt a plugin submits between turns.`

function voiceTurn(answer: string, outcome: 'answer' | 'aborted' | 'error' = 'answer') {
  const tracker = new TurnTracker()
  tracker.submitted(ID)
  tracker.turnStarted('t1', framed(ID), 'background', 0)
  const post = tracker.turnCompleted('t1', answer, outcome)
  return { tracker, post }
}

test('voiceTurnPostsOk', () => {
  assert.deepEqual(voiceTurn('  Three files: alpha, beta and gamma.\n').post, {
    id: ID, status: 'ok', text: 'Three files: alpha, beta and gamma.',
  })
  assert.deepEqual(voiceTurn('', 'aborted').post, {
    id: ID, status: 'failed', text: '', reason: 'the turn was interrupted',
  })
  assert.equal(voiceTurn('', 'error').post?.status, 'failed')
})

test('questionAnswerPostsQuestion', () => {
  assert.equal(voiceTurn('Which folder do you mean, src or docs?').post?.status, 'question')
  assert.equal(voiceTurn('Is it **src**?**').post?.status, 'question')
  assert.equal(voiceTurn('Done? Yes, all three files are listed.').post?.status, 'ok')
})

test('backgroundTurnAfterVoicePostsUpdate', () => {
  const { tracker } = voiceTurn('Started the build in the background.')
  tracker.turnStarted('t2', 'A background task finished.', 'background', 1000)
  assert.deepEqual(tracker.turnCompleted('t2', 'The build passed.', 'answer'), {
    id: ID, status: 'update', text: 'The build passed.',
  })
  tracker.turnStarted('t3', '', 'background', 2000)
  assert.equal(tracker.turnCompleted('t3', '', 'answer'), null, 'nothing to say is no update')
  // The window survives a reload of the mod.
  const restored = new TurnTracker(JSON.parse(JSON.stringify(tracker.snapshot())))
  restored.turnStarted('t4', 'Another task finished.', 'background', 3000)
  assert.equal(restored.turnCompleted('t4', 'Deployed.', 'answer')?.status, 'update')
})

test('followUpWindowClosesAfterTenMinutes', () => {
  const { tracker } = voiceTurn('Started the build in the background.')
  tracker.turnStarted('t2', 'A background task finished.', 'background', FOLLOW_UP_MS)
  assert.equal(tracker.turnCompleted('t2', 'The build passed.', 'answer'), null)
  tracker.turnStarted('t3', 'Another task finished.', 'background', 1000)
  assert.equal(tracker.turnCompleted('t3', 'Deployed.', 'answer'), null, 'the window stays closed')
})

test('typedTurnClosesTheFollowUpWindow', () => {
  const { tracker } = voiceTurn('Started the build in the background.')
  tracker.turnStarted('t2', 'thanks', 'typed', 1000)
  tracker.turnCompleted('t2', 'You are welcome.', 'answer')
  tracker.turnStarted('t3', 'A background task finished.', 'background', 2000)
  assert.equal(tracker.turnCompleted('t3', 'The build passed.', 'answer'), null)
})

test('typedTurnNeverPosts', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'What is in this folder?', 'typed', 0)
  assert.equal(tracker.turnCompleted('t1', 'Three files.', 'answer'), null)
  tracker.turnStarted('t2', 'A background task finished.', 'background', 1000)
  assert.equal(tracker.turnCompleted('t2', 'Done.', 'answer'), null, 'no voice request, no window')
  assert.equal(tracker.turnCompleted('unknown', 'Done.', 'answer'), null)
})

/** Only known background work reports to the voice; any other origin, new ones too, counts as typed. */
test('originComesFromPromptSubmit', () => {
  const self = 'livebridge'
  assert.equal(originOf({ kind: 'plugin', name: self }, self), 'voice')
  assert.equal(originOf({ kind: 'task-notification' }, self), 'background')
  const others = ['composer', 'bridge', 'sdk', 'slack-ping', 'scheduled-trigger', 'peer', 'unclassified', 'new-kind']
  for (const kind of others) assert.equal(originOf({ kind }, self), 'typed', kind)
  assert.equal(originOf({ kind: 'plugin', name: 'other' }, self), 'typed')
})

test('aRefusedSubmissionIsNoLongerPending', () => {
  const tracker = new TurnTracker()
  tracker.submitted(ID)
  tracker.refused('11111111-0000-0000-0000-00000000000b')
  assert.equal(tracker.snapshot().pending, ID, 'another id leaves it')
  tracker.refused(ID)
  assert.equal(tracker.snapshot().pending, null)
})

test('onlyARunningVoiceTurnIsRunning', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'Rename the folder', 'typed', 0)
  tracker.submitted(ID)
  assert.equal(tracker.running, null, 'a request waiting behind a typed turn')
  tracker.turnCompleted('t1', 'Renamed.', 'answer')
  tracker.turnStarted('t2', framed(ID), 'background', 1000)
  assert.equal(tracker.running, ID)
  tracker.turnCompleted('t2', 'Done.', 'answer')
  assert.equal(tracker.running, null)
})

test('clipCutsWholeCharactersOnly', () => {
  // Cut by UTF-16 units, an emoji would leave a lone surrogate the app's JSON decoder may refuse.
  assert.equal(clip('ab😀cd', 3), 'ab😀')
  assert.equal(clip('😀😀😀', 2), '😀😀')
  assert.equal(clip('short', 10), 'short')
  // In a `u` pattern a pair is one character, so only a lone surrogate matches.
  for (let limit = 0; limit < 8; limit++) assert.ok(!/[\uD800-\uDFFF]/u.test(clip('a😀'.repeat(4), limit)))
})

test('clipToEndLeavesShortTextAlone', () => {
  assert.equal(clipToEnd('one\ntwo', 20), 'one\ntwo')
  assert.equal(clipToEnd('one\ntwo', 7), 'one\ntwo')
})

test('clipToEndKeepsTheEndFromALineStart', () => {
  // The last 12 characters are "ee\nfour\nfive"; the cut line "ee" goes whole.
  assert.equal(clipToEnd('one\ntwo\nthree\nfour\nfive', 12), 'four\nfive')
})

test('clipToEndKeepsTheWindowWhenItHoldsNoLineBreak', () => {
  assert.equal(clipToEnd('abcdefghij', 4), 'ghij')
})

test('clipToEndNeverSplitsASurrogatePair', () => {
  assert.equal(clipToEnd('a😀😀😀', 2), '😀😀')
})
