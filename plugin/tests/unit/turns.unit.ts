import assert from 'node:assert/strict'
import { test } from 'node:test'

import { voicePrompt } from '../../hooks/prompt.ts'
import { originOf, TurnTracker } from '../../hooks/turns.ts'

const ID = '00000000-0000-0000-0000-00000000000a'
const framed = (id: string) =>
  `The livebridge plugin sent a message:\n${voicePrompt({ id, brief: 'List the files', transcript: [] })}\n\nThis is how Claude Code surfaces a prompt a plugin submits between turns.`

function voiceTurn(answer: string, outcome: 'answer' | 'aborted' | 'error' = 'answer') {
  const tracker = new TurnTracker()
  tracker.submitted(ID)
  assert.equal(tracker.current, ID)
  tracker.turnStarted('t1', framed(ID), 'background')
  assert.equal(tracker.current, ID)
  const post = tracker.turnCompleted('t1', answer, outcome)
  assert.equal(tracker.current, null)
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
  tracker.turnStarted('t2', 'A background task finished.', 'background')
  assert.deepEqual(tracker.turnCompleted('t2', 'The build passed.', 'answer'), {
    id: ID, status: 'update', text: 'The build passed.',
  })
  tracker.turnStarted('t3', '', 'background')
  assert.equal(tracker.turnCompleted('t3', '', 'answer'), null, 'nothing to say is no update')
  // The window survives a reload of the mod.
  const restored = new TurnTracker(JSON.parse(JSON.stringify(tracker.snapshot())))
  restored.turnStarted('t4', 'Another task finished.', 'background')
  assert.equal(restored.turnCompleted('t4', 'Deployed.', 'answer')?.status, 'update')
})

test('typedTurnClosesTheFollowUpWindow', () => {
  const { tracker } = voiceTurn('Started the build in the background.')
  tracker.turnStarted('t2', 'thanks', 'typed')
  tracker.turnCompleted('t2', 'You are welcome.', 'answer')
  tracker.turnStarted('t3', 'A background task finished.', 'background')
  assert.equal(tracker.turnCompleted('t3', 'The build passed.', 'answer'), null)
})

test('typedTurnNeverPosts', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'What is in this folder?', 'typed')
  assert.equal(tracker.turnCompleted('t1', 'Three files.', 'answer'), null)
  tracker.turnStarted('t2', 'A background task finished.', 'background')
  assert.equal(tracker.turnCompleted('t2', 'Done.', 'answer'), null, 'no voice request, no window')
  assert.equal(tracker.turnCompleted('unknown', 'Done.', 'answer'), null)
})

test('originComesFromPromptSubmit', () => {
  const self = 'livebridge'
  assert.equal(originOf({ kind: 'plugin', name: self }, self), 'voice')
  assert.equal(originOf({ kind: 'plugin', name: 'other' }, self), 'background')
  for (const kind of ['composer', 'bridge', 'sdk', 'slack-ping']) assert.equal(originOf({ kind }, self), 'typed')
  for (const kind of ['task-notification', 'scheduled-trigger', 'peer', 'unclassified']) {
    assert.equal(originOf({ kind }, self), 'background')
  }
})
