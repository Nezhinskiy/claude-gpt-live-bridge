import assert from 'node:assert/strict'
import { test } from 'node:test'

import { FRAMING, voicePrompt } from '../../hooks/prompt.ts'
import { ANSWER_LIMIT, clip, FOLLOW_UP_MS, originOf, TurnTracker } from '../../hooks/turns.ts'

const ID = '00000000-0000-0000-0000-00000000000a'
const REPLY = '00000000-0000-0000-0000-00000000000b'
const framed = (id: string) =>
  `${FRAMING}${voicePrompt({ id, brief: 'List the files', transcript: [] })}\n\nThis is how Claude Code surfaces a prompt a plugin submits between turns.`

function voiceTurn(answer: string, outcome: 'answer' | 'aborted' | 'error' = 'answer') {
  const tracker = new TurnTracker()
  tracker.submitted(ID)
  tracker.turnStarted('t1', framed(ID), 'background', 0)
  const { post } = tracker.turnCompleted('t1', answer, outcome)
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
  assert.deepEqual(tracker.turnCompleted('t2', 'The build passed.', 'answer').post, {
    id: ID, status: 'update', text: 'The build passed.',
  })
  tracker.turnStarted('t3', '', 'background', 2000)
  assert.equal(tracker.turnCompleted('t3', '', 'answer').post, null, 'nothing to say is no update')
  // The window survives a reload of the mod.
  const restored = new TurnTracker(JSON.parse(JSON.stringify(tracker.snapshot())))
  restored.turnStarted('t4', 'Another task finished.', 'background', 3000)
  assert.equal(restored.turnCompleted('t4', 'Deployed.', 'answer').post?.status, 'update')
})

test('followUpWindowClosesAfterTenMinutes', () => {
  const { tracker } = voiceTurn('Started the build in the background.')
  tracker.turnStarted('t2', 'A background task finished.', 'background', FOLLOW_UP_MS)
  assert.equal(tracker.turnCompleted('t2', 'The build passed.', 'answer').post, null)
  tracker.turnStarted('t3', 'Another task finished.', 'background', 1000)
  assert.equal(tracker.turnCompleted('t3', 'Deployed.', 'answer').post, null, 'the window stays closed')
})

test('anyOtherTurnClosesTheFollowUpWindow', () => {
  for (const origin of ['owner', 'other', null] as const) {
    const { tracker } = voiceTurn('Started the build in the background.')
    tracker.turnStarted('t2', 'thanks', origin, 1000)
    tracker.turnCompleted('t2', 'You are welcome.', 'answer')
    tracker.turnStarted('t3', 'A background task finished.', 'background', 2000)
    assert.equal(tracker.turnCompleted('t3', 'The build passed.', 'answer').post, null, String(origin))
  }
})

test('aTurnThatIsNotAVoiceRequestPostsNoAnswer', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'What is in this folder?', 'owner', 0)
  assert.equal(tracker.turnCompleted('t1', 'Three files.', 'answer').post, null)
  tracker.turnStarted('t2', 'A background task finished.', 'background', 1000)
  assert.equal(tracker.turnCompleted('t2', 'Done.', 'answer').post, null, 'no voice request, no window')
  assert.deepEqual(tracker.turnCompleted('unknown', 'Done.', 'answer'), { post: null, sync: null })
})

test('an owner turn posts its prompt', () => {
  const tracker = new TurnTracker()
  assert.deepEqual(tracker.turnStarted('t1', 'Rename the folder', 'owner', 0), [
    { turn: { id: 't1' }, kind: 'start' }, { turn: { id: 't1' }, kind: 'typed', text: 'Rename the folder' },
  ])
})

test('an owner turn posts its answer', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'Rename the folder', 'owner', 0)
  assert.deepEqual(tracker.turnCompleted('t1', '  Renamed to out.\n', 'answer'), {
    post: null, sync: { turn: { id: 't1' }, kind: 'answer', text: 'Renamed to out.' },
  })
})

/** Only `composer` was seen as a person's own typing (ADR 0001, item m); a new kind is nobody's words. */
test('only an observed origin is the owner', () => {
  const self = 'livebridge'
  assert.equal(originOf({ kind: 'composer' }, self), 'owner')
  assert.equal(originOf({ kind: 'plugin', name: self }, self), 'voice')
  assert.equal(originOf({ kind: 'task-notification' }, self), 'background')
  const others = ['bridge', 'sdk', 'slack-ping', 'scheduled-trigger', 'peer', 'unclassified', 'new-kind']
  for (const kind of others) assert.equal(originOf({ kind }, self), 'other', kind)
  assert.equal(originOf({ kind: 'plugin', name: 'other-plugin' }, self), 'other')
})

test('a prompt the person does not see as typed is not the owner\'s', () => {
  const self = 'livebridge'
  assert.equal(originOf({ kind: 'composer' }, self, true), 'other')
  assert.equal(originOf({ kind: 'task-notification' }, self, true), 'background', 'it stays what it was')
})

test('an other turn takes its decision and posts its answer, not its prompt', () => {
  const tracker = new TurnTracker()
  assert.deepEqual(tracker.turnStarted('t1', 'A message from a peer session.', 'other', 0), [
    { turn: { id: 't1' }, kind: 'start' },
  ])
  assert.deepEqual(tracker.turnCompleted('t1', 'Done.', 'answer').sync, { turn: { id: 't1' }, kind: 'answer', text: 'Done.' })
})

test('a turn with no origin seen is other', () => {
  const tracker = new TurnTracker()
  assert.deepEqual(tracker.turnStarted('t1', 'Rename the folder', null, 0), [{ turn: { id: 't1' }, kind: 'start' }])
})

test('a background turn outside the window posts its answer and no prompt', () => {
  const tracker = new TurnTracker()
  assert.deepEqual(tracker.turnStarted('t1', 'A background task finished.', 'background', 0), [
    { turn: { id: 't1' }, kind: 'start' },
  ])
  assert.deepEqual(tracker.turnCompleted('t1', 'The build passed.', 'answer'), {
    post: null, sync: { turn: { id: 't1' }, kind: 'answer', text: 'The build passed.' },
  })
})

test('a background turn in the window stays an update', () => {
  const { tracker } = voiceTurn('Started the build in the background.')
  assert.deepEqual(tracker.turnStarted('t2', 'A background task finished.', 'background', 1000), [
    { turn: { id: 't2', request: ID }, kind: 'start' },
  ])
  assert.deepEqual(tracker.turnCompleted('t2', 'The build passed.', 'answer'), {
    post: { id: ID, status: 'update', text: 'The build passed.' }, sync: null,
  })
})

test('a voice turn posts only its start', () => {
  const tracker = new TurnTracker()
  tracker.submitted(ID)
  assert.deepEqual(tracker.turnStarted('t1', framed(ID), 'voice', 0).map(line => line.kind), ['start'])
  assert.equal(tracker.turnCompleted('t1', 'Three files.', 'answer').sync, null)
})

test('an interrupted turn posts a report', () => {
  for (const outcome of ['aborted', 'refusal', 'error'] as const) {
    const tracker = new TurnTracker()
    tracker.turnStarted('t1', 'Rename the folder', 'owner', 0)
    const { post, sync } = tracker.turnCompleted('t1', 'Half an answer', outcome)
    assert.equal(post, null, outcome)
    assert.equal(sync?.kind, 'report', outcome)
    assert.deepEqual(sync?.turn, { id: 't1' }, outcome)
    assert.ok(sync?.text && !sync.text.includes('Half an answer'), outcome)
  }
})

/** A plain No at a permission dialog, or a cancelled question, ends the turn this way. */
test('a turn that ends with no answer posts a report', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'Rename the folder', 'owner', 0)
  assert.equal(tracker.turnCompleted('t1', ' \n', 'answer').sync?.kind, 'report')
})

test('an other turn that ends with no answer posts a report', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'A message from a peer session.', 'other', 0)
  assert.equal(tracker.turnCompleted('t1', '', 'aborted').sync?.kind, 'report')
})

/** Its prompt went to the app and its answer would have gone as an update: nothing else closes it. */
test('a turn a spoken reply tied to another request posts a report under it', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'Rename the folder', 'owner', 0)
  tracker.replied(REPLY, ID, 1000)
  const { post, sync } = tracker.turnCompleted('t1', '', 'aborted')
  assert.equal(post, null)
  assert.equal(sync?.kind, 'report')
  assert.deepEqual(sync?.turn, { id: 't1', request: ID })
})

/** The same end in a voice turn: its request closes as failed, and the reason says what happened. */
test('a voice turn that ends with no answer fails, with a reason', () => {
  const { post } = voiceTurn(' \n')
  assert.equal(post?.status, 'failed')
  assert.equal(post?.text, '')
  assert.ok(post?.reason)
})

test('a voice turn that fails posts no second line', () => {
  for (const outcome of ['aborted', 'error'] as const) {
    const tracker = new TurnTracker()
    tracker.submitted(ID)
    tracker.turnStarted('t1', framed(ID), 'voice', 0)
    assert.equal(tracker.turnCompleted('t1', '', outcome).sync, null, outcome)
  }
})

test('replied makes the rest of the turn a voice turn', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'Rename the folder', 'owner', 0)
  tracker.replied(REPLY, REPLY, 1000)
  assert.equal(tracker.running, REPLY)
  assert.deepEqual(tracker.current, { id: 't1', request: REPLY })
  assert.deepEqual(tracker.turnCompleted('t1', 'Renamed to out.', 'answer'), {
    post: { id: REPLY, status: 'ok', text: 'Renamed to out.' }, sync: null,
  })
  assert.deepEqual(tracker.snapshot().followUp, { id: REPLY, until: 1000 + FOLLOW_UP_MS })
})

test('replied with another request in flight makes the answer its update', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'Rename the folder', 'owner', 0)
  tracker.replied(REPLY, ID, 1000)
  assert.equal(tracker.running, null)
  assert.deepEqual(tracker.current, { id: 't1', request: ID })
  assert.deepEqual(tracker.turnCompleted('t1', 'Renamed to out.', 'answer'), {
    post: { id: ID, status: 'update', text: 'Renamed to out.' }, sync: null,
  })
})

test('a voice turn starts naming its request', () => {
  const tracker = new TurnTracker()
  tracker.submitted(ID)
  assert.deepEqual(tracker.turnStarted('t1', framed(ID), 'voice', 0), [{ turn: { id: 't1', request: ID }, kind: 'start' }])
})

test('text typed into a voice turn names its request', () => {
  const tracker = new TurnTracker()
  tracker.submitted(ID)
  tracker.turnStarted('t1', framed(ID), 'voice', 0)
  assert.deepEqual(tracker.typedInto('t1', 'second'), { turn: { id: 't1', request: ID }, kind: 'typed', text: 'second' })
})

test('a spoken reply puts its request on the turn\'s later lines', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'Rename the folder', 'owner', 0)
  assert.deepEqual(tracker.typedInto('t1', 'first').turn, { id: 't1' })
  tracker.replied(REPLY, REPLY, 1000)
  assert.deepEqual(tracker.typedInto('t1', 'second').turn, { id: 't1', request: REPLY })
})

test('replied changes nothing in a voice turn', () => {
  const tracker = new TurnTracker()
  tracker.submitted(ID)
  tracker.turnStarted('t1', framed(ID), 'voice', 0)
  tracker.replied(REPLY, REPLY, 1000)
  assert.equal(tracker.running, ID)
  assert.deepEqual(tracker.turnCompleted('t1', 'Done.', 'answer').post, { id: ID, status: 'ok', text: 'Done.' })
})

test('replied changes nothing without forRequest', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'Rename the folder', 'owner', 0)
  tracker.replied(REPLY, undefined, 1000)
  assert.equal(tracker.running, null)
  assert.deepEqual(tracker.turnCompleted('t1', 'Done.', 'answer'), {
    post: null, sync: { turn: { id: 't1' }, kind: 'answer', text: 'Done.' },
  })
})

test('replied changes nothing with no turn', () => {
  const tracker = new TurnTracker()
  tracker.replied(REPLY, REPLY, 1000)
  assert.equal(tracker.running, null)
  assert.equal(tracker.snapshot().followUp, null)
})

test('current is the running turn of either kind, null after it ends', () => {
  const tracker = new TurnTracker()
  assert.equal(tracker.current, null)
  tracker.turnStarted('t1', 'Rename the folder', 'owner', 0)
  assert.deepEqual(tracker.current, { id: 't1' })
  tracker.turnCompleted('t1', 'Renamed.', 'answer')
  assert.equal(tracker.current, null)
  tracker.submitted(ID)
  tracker.turnStarted('t2', framed(ID), 'voice', 1000)
  assert.deepEqual(tracker.current, { id: 't2', request: ID })
  tracker.turnCompleted('t2', 'Three files.', 'answer')
  assert.equal(tracker.current, null)
})

test('a turn the tracker never saw start is lost, once', () => {
  const tracker = new TurnTracker()
  assert.equal(tracker.takeLostTurn(), false)
  tracker.turnCompleted('t1', 'Done.', 'answer')
  assert.equal(tracker.takeLostTurn(), true)
  assert.equal(tracker.takeLostTurn(), false)
})

test('a turn that started and ended is not lost', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  tracker.turnCompleted('t1', 'Done.', 'answer')
  assert.equal(tracker.takeLostTurn(), false)
})

/** Crash, then --resume: the snapshot holds a turn whose end never came. */
test('a turn still held when the next one starts ended unseen', () => {
  const tracker = new TurnTracker({ pending: null, followUp: null, turns: [['t0', { id: null, isVoice: false }]] })
  tracker.turnStarted('t1', 'first', 'owner', 0)
  assert.equal(tracker.takeLostTurn(), true)
  assert.deepEqual(tracker.snapshot().turns.map(([id]) => id), ['t1'])
  assert.deepEqual(tracker.current, { id: 't1' })
})

test('a held turn does not hide one the tracker never saw', () => {
  const tracker = new TurnTracker({ pending: null, followUp: null, turns: [['t0', { id: null, isVoice: false }]] })
  tracker.turnCompleted('t1', 'Done.', 'answer')
  assert.equal(tracker.takeLostTurn(), true)
})

test('a snapshot from before sync loads', () => {
  const tracker = new TurnTracker({
    pending: null, followUp: { id: ID, until: 5000 }, turns: [['t1', { id: ID, isVoice: true }]],
  })
  assert.equal(tracker.running, ID)
  assert.deepEqual(tracker.current, { id: 't1', request: ID })
  assert.equal(tracker.turnCompleted('t1', 'Done.', 'answer').post?.status, 'ok')
  assert.deepEqual(tracker.turnStarted('t2', 'second', null, 1000).map(line => line.kind), ['start'], 'nothing was typed into it')
})

test('a slash command\'s owner line is the typed text', () => {
  const tracker = new TurnTracker()
  const wrapper = '<command-message>expand</command-message>\n<command-name>/expand</command-name>'
  assert.deepEqual(tracker.turnStarted('t1', wrapper, 'owner', 0, '/expand foo').at(-1), {
    turn: { id: 't1' }, kind: 'typed', text: '/expand foo',
  })
})

test('text typed into a running turn goes under that turn', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  assert.deepEqual(tracker.typedInto('t1', 'second'), { turn: { id: 't1' }, kind: 'typed', text: 'second' })
})

/** A hook may rewrite a prompt on its way in: `turn.start` holds what entered, the line what was typed. */
test('a queued prompt is claimed by what entered', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  assert.deepEqual(tracker.typedInto('t1', 'second', 'second, rewritten'), { turn: { id: 't1' }, kind: 'typed', text: 'second' })
  tracker.turnCompleted('t1', 'One.', 'answer')
  assert.deepEqual(tracker.turnStarted('t2', 'second, rewritten', null, 1000), [])
})

/** Terminal, ADR 0001 (m): at Enter the prompt carries the running turn's id; its own turn starts after that turn. */
test('a queued prompt\'s own turn is the owner\'s and posts no prompt again', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  tracker.typedInto('t1', 'second')
  tracker.turnCompleted('t1', 'Done with the first.', 'answer')
  assert.deepEqual(tracker.turnStarted('t2', 'second', null, 1000), [])
  assert.deepEqual(tracker.current, { id: 't1' })
})

test('a queued prompt\'s answer goes under the first turn\'s id', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  tracker.typedInto('t1', 'second')
  tracker.turnCompleted('t1', 'Done with the first.', 'answer')
  tracker.turnStarted('t2', 'second', null, 1000)
  assert.deepEqual(tracker.turnCompleted('t2', 'Done with the second.', 'answer'), {
    post: null, sync: { turn: { id: 't1' }, kind: 'answer', text: 'Done with the second.' },
  })
})

test('a chain of queued prompts keeps the first id', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  tracker.typedInto('t1', 'second')
  tracker.turnCompleted('t1', 'One.', 'answer')
  tracker.turnStarted('t2', 'second', null, 1000)
  assert.deepEqual(tracker.typedInto('t2', 'third'), { turn: { id: 't1' }, kind: 'typed', text: 'third' })
  tracker.turnCompleted('t2', 'Two.', 'answer')
  tracker.turnStarted('t3', 'third', null, 2000)
  assert.deepEqual(tracker.turnCompleted('t3', 'Three.', 'answer').sync?.turn, { id: 't1' })
})

test('two prompts queued at once each find their own turn', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  tracker.typedInto('t1', 'second')
  tracker.typedInto('t1', 'third')
  tracker.turnCompleted('t1', 'One.', 'answer')
  assert.deepEqual(tracker.turnStarted('t2', 'second', null, 1000), [])
  tracker.turnCompleted('t2', 'Two.', 'answer')
  assert.deepEqual(tracker.turnStarted('t3', 'third', null, 2000), [])
})

/** A prompt typed while a tool runs folds in: no turn of its own will claim what was remembered. */
test('a folded prompt leaves nothing remembered', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  tracker.typedInto('t1', 'yes')
  tracker.turnCompleted('t1', 'Done.', 'answer')
  tracker.turnStarted('t2', 'A peer session wrote.', null, 1000)
  tracker.turnCompleted('t2', 'Noted.', 'answer')
  assert.deepEqual(tracker.turnStarted('t3', 'yes', null, 2000), [{ turn: { id: 't3' }, kind: 'start' }])
})

test('the owner typing a folded prompt again is a prompt of its own', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  tracker.typedInto('t1', 'yes')
  tracker.turnCompleted('t1', 'Done.', 'answer')
  assert.deepEqual(tracker.turnStarted('t2', 'yes', 'owner', 1000).at(-1), { turn: { id: 't2' }, kind: 'typed', text: 'yes' })
})

/** Its `turn.start` holds the expansion, not what was typed: the window the owner accepted. */
test('a queued slash command stays other', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  tracker.typedInto('t1', '/expand foo')
  tracker.turnCompleted('t1', 'Done.', 'answer')
  const wrapper = '<command-message>expand</command-message>'
  assert.deepEqual(tracker.turnStarted('t2', wrapper, null, 1000), [{ turn: { id: 't2' }, kind: 'start' }])
})

test('a prompt typed into a voice turn takes the voice turn\'s id', () => {
  const tracker = new TurnTracker()
  tracker.submitted(ID)
  tracker.turnStarted('t1', framed(ID), 'voice', 0)
  tracker.typedInto('t1', 'second')
  tracker.turnCompleted('t1', 'Three files.', 'answer')
  tracker.turnStarted('t2', 'second', null, 1000)
  assert.deepEqual(tracker.current, { id: 't1' })
})

/** A refused prompt must stay refused through its answer, across a reload too. */
test('a queued prompt survives a reload', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  tracker.typedInto('t1', 'second')
  const restored = new TurnTracker(JSON.parse(JSON.stringify(tracker.snapshot())))
  restored.turnCompleted('t1', 'One.', 'answer')
  assert.deepEqual(restored.turnStarted('t2', 'second', null, 1000), [])
  const again = new TurnTracker(JSON.parse(JSON.stringify(restored.snapshot())))
  assert.deepEqual(again.turnCompleted('t2', 'Two.', 'answer').sync?.turn, { id: 't1' })
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
  tracker.turnStarted('t1', 'Rename the folder', 'owner', 0)
  tracker.submitted(ID)
  assert.equal(tracker.running, null, 'a request waiting behind a typed turn')
  tracker.turnCompleted('t1', 'Renamed.', 'answer')
  tracker.turnStarted('t2', framed(ID), 'background', 1000)
  assert.equal(tracker.running, ID)
  tracker.turnCompleted('t2', 'Done.', 'answer')
  assert.equal(tracker.running, null)
})

test('a tool run settles only the prompt for its own input', () => {
  const tracker = new TurnTracker()
  tracker.promptOpened('Read', { file_path: '/etc/hosts' })
  assert.equal(tracker.promptRan('Read', { file_path: './a' }), false)
  assert.equal(tracker.promptRan('Read', { file_path: '/etc/hosts' }), true)
  assert.equal(tracker.promptRan('Read', { file_path: '/etc/hosts' }), false, 'once')
})

test('a tool run settles only its own agent\'s prompt', () => {
  const tracker = new TurnTracker()
  tracker.promptOpened('Bash', { command: 'ls' }, 'a1')
  assert.equal(tracker.promptRan('Bash', { command: 'ls' }), false)
  assert.equal(tracker.promptRan('Bash', { command: 'ls' }, 'a2'), false)
  assert.equal(tracker.promptRan('Bash', { command: 'ls' }, 'a1'), true)
})

test('a step ends only its own agent\'s prompts', () => {
  const tracker = new TurnTracker()
  tracker.promptOpened('Bash', { command: 'ls' }, 'a1')
  tracker.promptOpened('Read', { file_path: './a' })
  assert.equal(tracker.promptGone(), 'Read')
  assert.equal(tracker.promptGone(), null)
  assert.equal(tracker.promptGone('a1'), 'Bash')
  assert.equal(tracker.promptGone('a1'), null)
})

test('two prompts for one tool are told apart', () => {
  const tracker = new TurnTracker()
  tracker.promptOpened('Read', { file_path: '/etc/hosts' })
  tracker.promptOpened('Read', { file_path: '/etc/passwd' })
  assert.equal(tracker.promptRan('Read', { file_path: '/etc/passwd' }), true)
  assert.equal(tracker.promptGone(), 'Read')
  assert.equal(tracker.promptGone(), null)
})

test('an open prompt survives a reload', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  tracker.promptOpened('Bash', { command: 'ls' }, 'a1')
  const restored = new TurnTracker(JSON.parse(JSON.stringify(tracker.snapshot())))
  assert.equal(restored.promptRan('Bash', { command: 'ls' }, 'a1'), true)
})

test('a turn\'s end forgets its prompts', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  tracker.promptOpened('Bash', { command: 'ls' }, 'a1')
  tracker.turnCompleted('t1', 'Done.', 'answer')
  assert.equal(tracker.promptGone('a1'), null)
})

/** Crash, then --resume: no dialog outlives the turn it was asked in. */
test('the next turn\'s start forgets a lost turn\'s prompts', () => {
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'first', 'owner', 0)
  tracker.promptOpened('Bash', { command: 'ls' })
  tracker.turnStarted('t2', 'second', 'owner', 1000)
  assert.equal(tracker.promptGone(), null)
})

test('clipCutsWholeCharactersOnly', () => {
  // Cut by UTF-16 units, an emoji would leave a lone surrogate the app's JSON decoder may refuse.
  assert.equal(clip('ab😀cd', 3), 'ab😀')
  assert.equal(clip('😀😀😀', 2), '😀😀')
  assert.equal(clip('short', 10), 'short')
  // In a `u` pattern a pair is one character, so only a lone surrogate matches.
  for (let limit = 0; limit < 8; limit++) assert.ok(!/[\uD800-\uDFFF]/u.test(clip('a😀'.repeat(4), limit)))
})

test('aStepsTextIsTakenOnce', () => {
  const tracker = new TurnTracker()
  tracker.stepStarted()
  tracker.streamed('Two folders ')
  tracker.streamed('hold build output.')
  assert.equal(tracker.takeStepText(), 'Two folders hold build output.')
  assert.equal(tracker.takeStepText(), '')
  tracker.streamed('Looking.')
  tracker.stepStarted()
  assert.equal(tracker.takeStepText(), '')
})

test('aStepsTextIsCutToAnAnswersLimit', () => {
  const tracker = new TurnTracker()
  tracker.stepStarted()
  tracker.streamed('a'.repeat(ANSWER_LIMIT + 1))
  assert.equal(tracker.takeStepText(), 'a'.repeat(ANSWER_LIMIT))
})
