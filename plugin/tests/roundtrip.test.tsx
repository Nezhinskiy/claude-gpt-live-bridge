import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

import { spokenReply, voicePrompt } from '../hooks/prompt.ts'
import type { VoiceRequest } from '../hooks/wire.ts'
import { BAND, fakeWorld, framed, ID, LIVE, step } from './fake-bridge.ts'

const REQUEST: VoiceRequest = {
  id: '00000000-0000-0000-0000-00000000000a',
  brief: 'Please list the files in this folder',
  transcript: [{ role: 'user', text: 'Please list the files in this folder' }],
}
const DONE = { durationMs: 1, isAborted: false, reason: 'answer' } as const

test('roundtrip', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/Users/example/Dev/example-project', surface: 'terminal', isInteractive: true })
  const reply = await $.command.run({ ...LIVE, args: 'on' })
  expect(reply.text).toContain('Joined')
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', owner: true, syncs: true, missed: true }])
  expect(world.read.every(path => path.endsWith('.json'))).toBe(true)

  world.work.push({ kind: 'request', ...REQUEST })
  await world.clock.advance(1000)
  expect(world.submitted).toEqual([voicePrompt(REQUEST)])

  await $.turn.start({ text: framed(world.submitted[0]!), turnId: 't1' })
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Three files: alpha, beta and gamma.' })
  expect(world.take('answer')).toEqual([
    { sessionId: ID, id: REQUEST.id, status: 'ok', text: 'Three files: alpha, beta and gamma.' },
  ])
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'working' }, { sessionId: ID, state: 'idle' }])
})

/** The app restarted mid-request and forgot it: the answer stays in the session, and the band says so. */
test('rejectedAnswerIsShownNotDropped', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  expect((await $.command.run({ ...LIVE, args: 'on' })).text).toContain('Joined')
  expect((await $.command.run({ ...LIVE, args: 'status' })).text).toContain('joining')
  world.work.push({ kind: 'request', ...REQUEST })
  await world.clock.advance(1000)
  world.answerStatus = 409
  await $.turn.start({ text: framed(world.submitted[0]!), turnId: 't1' })
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Three files.' })
  await world.clock.advance(1000)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await band.find({ type: 'Text', text: /did not get/ }))?.text).toContain('it is in this session')
  await band.unmount()
})

test('refusedPromptFailsTheRequestAtOnce', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...LIVE, args: 'on' })
  world.isSubmitRefused = true
  world.work.push({ kind: 'request', ...REQUEST })
  await world.clock.advance(1000)
  expect(world.take('answer')).toEqual([
    { sessionId: ID, id: REQUEST.id, status: 'failed', text: '', reason: 'Claude Code did not take the prompt' },
  ])
  // A typed turn after it is no voice turn: its permission dialog is not reported.
  world.take('activity')
  await $.turn.start({ text: 'Remove the build folder', turnId: 't1' })
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'rm -r build' } })
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'working' }])
})

test('approvalIsReported', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...LIVE, args: 'on' })
  world.work.push({ kind: 'request', ...REQUEST })
  await world.clock.advance(1000)
  await $.turn.start({ text: framed(world.submitted[0]!), turnId: 't1' })
  world.take('activity')

  // An ask the permission mode settles shows no dialog, so it is no approval.
  await $.tool.check({ tool: 'Bash', input: { command: 'ls' } })
  expect(world.take('activity')).toEqual([])
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'rm -r build' } })
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'approval' }])
  await $.classic.PostToolUse({ tool_name: 'Bash', tool_input: {}, tool_response: {}, tool_use_id: 'u1' })
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'working' }])
})

/** What Claude wrote in the step that asks for a permission goes with the approval notice. */
test('theTextBeforeAnApprovalGoesWithIt', async ($, on) => {
  const world = fakeWorld(on)
  await inVoiceTurn($, world)
  await step($, world, 't1', "I'm going to delete build/ and re-run.")
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'rm -r build' } })
  expect(world.take('activity')).toEqual([
    { sessionId: ID, state: 'approval', text: "I'm going to delete build/ and re-run." },
  ])
})

/**
 * The engine may run a tool while its step still streams: a prompt then gets the text the step
 * has streamed so far, never the step before it.
 */
test('aPromptWhileItsStepStreamsGetsThatStepsText', async ($, on) => {
  const world = fakeWorld(on)
  await inVoiceTurn($, world)
  await step($, world, 't1', 'Reading the config.')
  world.stepText = "I'm going to delete build/ and re-run."
  const streaming = $.turn.step({ turnId: 't1', index: 1, model: 'example-model', messageCount: 1 })
  await streaming.next()
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'rm -r build' } })
  expect(world.take('activity')).toEqual([
    { sessionId: ID, state: 'approval', text: "I'm going to delete build/ and re-run." },
  ])
  for await (const chunk of streaming) void chunk
})

/** A subagent's permission request is not the main loop's step: it neither carries nor takes that text. */
test('aSubagentsApprovalGoesWithoutTheMainLoopsText', async ($, on) => {
  const world = fakeWorld(on)
  await inVoiceTurn($, world)
  await step($, world, 't1', 'Two folders hold build output.')
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'rm -r build' }, agent_id: 'a1' })
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'approval' }])
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'rm -r out' } })
  expect(world.take('activity')).toEqual([
    { sessionId: ID, state: 'approval', text: 'Two folders hold build output.' },
  ])
})

/** A step longer than an answer may be is cut, so the notice still fits the app's body limit. */
test('aLongStepIsCutForTheApproval', async ($, on) => {
  const world = fakeWorld(on)
  await inVoiceTurn($, world)
  await step($, world, 't1', 'a'.repeat(40_000))
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'rm -r build' } })
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'approval', text: 'a'.repeat(32_000) }])
})

/** A voice request waiting for the next turn does not make the typed turn's approval the voice's. */
test('aTypedTurnsApprovalIsNotReportedWhileAVoiceRequestWaits', async ($, on) => {
  const world = fakeWorld(on)
  await inTypedTurnWithVoiceWaiting($, world, 'Remove the build folder')
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'rm -r build' } })
  expect(world.take('activity')).toEqual([])
})

const ASKED = [{
  question: 'Which name should the folder get?', header: 'Name', multiSelect: false,
  options: [{ label: 'build', description: 'the default' }, { label: 'out', description: 'shorter' }],
}]
const SPOKEN = { id: '00000000-0000-0000-0000-00000000000b', brief: 'What would out change?', transcript: [] }

/** A voice turn whose prompt Claude has started; the activity it posted so far is taken. */
async function inVoiceTurn($: Engine, world: ReturnType<typeof fakeWorld>) {
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...LIVE, args: 'on' })
  world.work.push({ kind: 'request', ...REQUEST })
  await world.clock.advance(1000)
  await $.turn.start({ text: framed(world.submitted[0]!), turnId: 't1' })
  world.take('activity')
}

/** A typed turn that runs while a voice request waits behind it; the activity so far is taken. */
async function inTypedTurnWithVoiceWaiting($: Engine, world: ReturnType<typeof fakeWorld>, text: string) {
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...LIVE, args: 'on' })
  await $.turn.start({ text, turnId: 't1' })
  world.work.push({ kind: 'request', ...REQUEST })
  await world.clock.advance(1000)
  expect(world.submitted).toHaveLength(1)
  world.take('activity')
}

/** Claude's question goes to the voice whole; the owner's spoken reply answers it as free text. */
test('claudesQuestionIsAnsweredByVoice', async ($, on) => {
  const world = fakeWorld(on)
  await inVoiceTurn($, world)
  const asked = $.tool.call({ tool: 'AskUserQuestion', questions: ASKED })
  await world.clock.advance(1000)
  expect(world.take('activity')).toEqual([{
    sessionId: ID, state: 'approval',
    question: 'Which name should the folder get? Options: build: the default; out: shorter.',
  }])
  world.work.push({ kind: 'reply', ...SPOKEN, forRequest: SPOKEN.id })
  await world.clock.advance(1000)
  expect((await asked).result).toEqual({ questions: ASKED, answers: {}, response: spokenReply(SPOKEN) })
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'working' }])
})

const PLAIN = 'Which name should the folder get? Options: build: the default; out: shorter.'

/** What Claude wrote in the step that asks the question goes with the question. */
test('theTextBeforeClaudesQuestionGoesWithIt', async ($, on) => {
  const world = fakeWorld(on)
  await inVoiceTurn($, world)
  world.take('answer')
  await step($, world, 't1', 'Here is what I found: the folder has two outputs.')
  const asked = $.tool.call({ tool: 'AskUserQuestion', questions: ASKED })
  await world.clock.advance(1000)
  expect(world.take('activity')).toEqual([{
    sessionId: ID, state: 'approval',
    question: PLAIN, text: 'Here is what I found: the folder has two outputs.',
  }])
  expect(world.take('answer')).toEqual([])
  world.answerDialog('build')
  await asked
})

/** A step with no text after one with text: the question goes alone. */
test('aQuestionAfterAStepWithNoTextGoesAlone', async ($, on) => {
  const world = fakeWorld(on)
  await inVoiceTurn($, world)
  await step($, world, 't1', 'Let me look at the folder.')
  await step($, world, 't1', '')
  const asked = $.tool.call({ tool: 'AskUserQuestion', questions: ASKED })
  await world.clock.advance(1000)
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'approval', question: PLAIN }])
  world.answerDialog('build')
  await asked
})

/** The text goes with one question only. */
test('aSecondQuestionDoesNotRepeatTheText', async ($, on) => {
  const world = fakeWorld(on)
  await inVoiceTurn($, world)
  await step($, world, 't1', 'Two folders hold build output.')
  const first = $.tool.call({ tool: 'AskUserQuestion', questions: ASKED })
  await world.clock.advance(1000)
  world.answerDialog('out')
  await first
  world.take('activity')
  const asked = $.tool.call({ tool: 'AskUserQuestion', questions: ASKED })
  await world.clock.advance(1000)
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'approval', question: PLAIN }])
  world.answerDialog('build')
  await asked
})

/** The text goes with one pause only: a question after a prompt in the same step goes alone. */
test('aQuestionAfterAnApprovalInTheSameStepGoesAlone', async ($, on) => {
  const world = fakeWorld(on)
  await inVoiceTurn($, world)
  world.stepText = 'Two folders hold build output.'
  const streaming = $.turn.step({ turnId: 't1', index: 0, model: 'example-model', messageCount: 1 })
  await streaming.next()
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'rm -r build' } })
  for await (const chunk of streaming) void chunk
  world.take('activity')
  const asked = $.tool.call({ tool: 'AskUserQuestion', questions: ASKED })
  await world.clock.advance(1000)
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'approval', question: PLAIN }])
  world.answerDialog('build')
  await asked
})

/** A subagent's step does not replace what the main loop wrote. */
test('aSubagentsStepLeavesTheMainLoopsText', async ($, on) => {
  const world = fakeWorld(on)
  await inVoiceTurn($, world)
  await step($, world, 't1', 'Two folders hold build output.')
  await step($, world, 't1', 'A subagent report.', 'a1')
  const asked = $.tool.call({ tool: 'AskUserQuestion', questions: ASKED })
  await world.clock.advance(1000)
  expect(world.take('activity')).toEqual([{
    sessionId: ID, state: 'approval',
    question: PLAIN, text: 'Two folders hold build output.',
  }])
  world.answerDialog('build')
  await asked
})

/** Answered at the keyboard, the question is settled for the voice too; a reply after it is not lost silently. */
test('claudesQuestionAnsweredAtTheKeyboard', async ($, on) => {
  const world = fakeWorld(on)
  await inVoiceTurn($, world)
  const asked = $.tool.call({ tool: 'AskUserQuestion', questions: ASKED })
  await world.clock.advance(1000)
  world.take('activity')
  world.answerDialog('out')
  expect((await asked).result).toEqual({ questions: ASKED, answers: { [ASKED[0]!.question]: 'out' } })
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'working' }])
  world.work.push({ kind: 'reply', ...SPOKEN, forRequest: SPOKEN.id })
  await world.clock.advance(1000)
  expect(world.logs.some(line => line.includes('came after the question was answered'))).toBe(true)
  expect(world.submitted).toHaveLength(1)
})

/** In a typed turn the dialog is Claude Code's alone: nothing goes to the voice. */
test('aTypedTurnsQuestionStaysInClaudeCode', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...LIVE, args: 'on' })
  await $.turn.start({ text: 'Rename the folder', turnId: 't1' })
  world.take('activity')
  const asked = $.tool.call({ tool: 'AskUserQuestion', questions: ASKED })
  await world.clock.advance(1000)
  expect(world.take('activity')).toEqual([])
  world.answerDialog('build')
  expect((await asked).result).toEqual({ questions: ASKED, answers: { [ASKED[0]!.question]: 'build' } })
})

/** A voice request waiting for the next turn does not make the typed turn's question the voice's. */
test('aTypedTurnsQuestionStaysInClaudeCodeWhileAVoiceRequestWaits', async ($, on) => {
  const world = fakeWorld(on)
  await inTypedTurnWithVoiceWaiting($, world, 'Rename the folder')
  const asked = $.tool.call({ tool: 'AskUserQuestion', questions: ASKED })
  await world.clock.advance(1000)
  expect(world.take('activity')).toEqual([])
  world.answerDialog('build')
  expect((await asked).result).toEqual({ questions: ASKED, answers: { [ASKED[0]!.question]: 'build' } })
})

/** What the composer hands the engine: a prompt the owner typed, over a running turn when `turnId` is given. */
const composer = (text: string, turnId?: string) =>
  ({ text, wait: false, origin: { kind: 'composer' }, ...(turnId !== undefined && { turnId }) }) as const

/** The owner's prompt, then the turn it starts; the mod has joined. */
async function ownerTurn($: Engine, turnId: string, text: string) {
  await $.prompt.submit(composer(text))
  await $.turn.start({ text, turnId })
}

async function joined($: Engine, world: ReturnType<typeof fakeWorld>) {
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...LIVE, args: 'on' })
  world.take('join')
}

const owner = (turnId: string, text: string) => ({ sessionId: ID, turnId, from: 'owner', text })
const claude = (turnId: string, text: string) => ({ sessionId: ID, turnId, from: 'claude', text })

test('anOwnerTurnIsSynced', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  await ownerTurn($, 't1', 'Rename the folder')
  // Posted at the turn's start, so an open line knows before Claude finishes.
  expect(world.calls.map(call => call.route).filter(route => route === 'sync' || route === 'activity')).toEqual(['sync', 'activity'])
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Renamed to out.' })
  expect(world.take('sync')).toEqual([owner('t1', 'Rename the folder'), claude('t1', 'Renamed to out.')])
  expect(world.take('answer')).toEqual([])
})

test('aTurnSyncsWhileTheCallIsOff', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  for (const call of ['off', 'listening', 'live'] as const) {
    world.status = { ...world.status, call }
    await world.clock.advance(1000)
    await ownerTurn($, `t-${call}`, 'Rename the folder')
    await $.turn.complete({ ...DONE, turnId: `t-${call}`, answer: 'Renamed.' })
    expect(world.take('sync')).toHaveLength(2)
  }
})

test('anOtherTurnPostsNoOwnerLine', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  await $.prompt.submit({ text: 'A peer session wrote.', wait: false, origin: { kind: 'peer' } as never })
  await $.turn.start({ text: 'A peer session wrote.', turnId: 't1' })
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Noted.' })
  expect(world.take('sync')).toEqual([claude('t1', ''), claude('t1', 'Noted.')])
})

test('textTypedIntoARunningTurnIsSynced', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  await ownerTurn($, 't1', 'first')
  world.take('sync')
  await $.prompt.submit(composer('second', 't1'))
  expect(world.take('sync')).toEqual([owner('t1', 'second')])
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Done.' })
  world.take('sync')
  // A voice turn's too.
  world.work.push({ kind: 'request', ...REQUEST })
  await world.clock.advance(1000)
  await $.turn.start({ text: framed(voicePrompt(REQUEST)), turnId: 't2' })
  await $.prompt.submit(composer('third', 't2'))
  expect(world.take('sync')).toEqual([owner('t2', 'third')])
})

/** Terminal, ADR 0001 (m): a prompt typed while the final text streams has `turn.start` with no second `prompt.submit`. */
test('aPromptIsNotPostedTwice', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  await ownerTurn($, 't1', 'first')
  await $.prompt.submit(composer('second', 't1'))
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'One.' })
  world.take('sync')
  await $.turn.start({ text: 'second', turnId: 't2' })
  expect(world.take('sync')).toEqual([])
})

test('aQueuedPromptsTurnIsUnderTheFirstTurnsId', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  await ownerTurn($, 't1', 'first')
  await $.prompt.submit(composer('second', 't1'))
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'One.' })
  await $.turn.start({ text: 'second', turnId: 't2' })
  await $.turn.complete({ ...DONE, turnId: 't2', answer: 'Two.' })
  expect(world.take('sync')).toEqual([
    owner('t1', 'first'), owner('t1', 'second'), claude('t1', 'One.'), claude('t1', 'Two.'),
  ])
})

/** Press Stop with the pause on, type into a running turn, press Start: its own turn stays out. */
test('aRefusedTurnStaysRefusedThroughItsQueuedPrompt', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  await ownerTurn($, 't1', 'first')
  world.isPausing = true
  await $.prompt.submit(composer('private', 't1'))
  world.isPausing = false
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'One.' })
  await $.turn.start({ text: 'private', turnId: 't2' })
  await $.turn.complete({ ...DONE, turnId: 't2', answer: 'It repeats private.' })
  expect(world.kept).toEqual(['first'])
})

test('aSlashCommandsOwnerLineIsWhatWasTyped', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  await $.prompt.submit({ ...composer('/expand foo'), command: { name: 'expand', args: 'foo' } as never })
  await $.turn.start({ text: '<command-message>expand</command-message>\n<command-name>/expand</command-name>', turnId: 't1' })
  expect(world.take('sync')).toEqual([owner('t1', '/expand foo')])
})

test('aPromptThatDidNotEnterIsNotSynced', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  await ownerTurn($, 't1', 'first')
  world.take('sync')
  world.isPromptDropped = true
  await $.prompt.submit(composer('second', 't1'))
  expect(world.take('sync')).toEqual([])
})

test('aVoicePromptIntoARunningTurnIsNotSynced', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  await ownerTurn($, 't1', 'first')
  world.take('sync')
  await $.prompt.submit({ text: voicePrompt(REQUEST), wait: false, turnId: 't1', origin: { kind: 'plugin', name: 'livebridge' } })
  expect(world.take('sync')).toEqual([])
})

test('aDeliveryThatIsNotTheOwnersIsNotSynced', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  await ownerTurn($, 't1', 'first')
  world.take('sync')
  await $.prompt.submit({ text: 'A task finished.', wait: false, turnId: 't1', origin: { kind: 'task-notification' } as never })
  await $.prompt.submit({ text: 'A peer session wrote.', wait: false, turnId: 't1', origin: { kind: 'peer' } as never })
  await $.prompt.submit({ ...composer('Not seen as typed.', 't1'), isMeta: true })
  expect(world.take('sync')).toEqual([])
})

/** A long prompt or answer is cut to what fits the app's body limit; the app shapes it for the voice. */
test('aLongLineIsCutToAnAnswersLimit', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  await ownerTurn($, 't1', 'first')
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'a'.repeat(40_000) })
  expect(world.take('sync').at(-1)).toEqual(claude('t1', 'a'.repeat(32_000)))
})

test('aLostVoiceAnswerMeansAMissedJoin', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  world.work.push({ kind: 'request', ...REQUEST })
  await world.clock.advance(1000)
  await $.turn.start({ text: framed(world.submitted[0]!), turnId: 't1' })
  world.answerStatus = 409
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Three files.' })
  world.take('join')
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', syncs: true, missed: true }])
})

/** The answer went to neither the voice nor the conversation, whatever the reason the app gave. */
test('aRefusedUpdateMeansAMissedJoin', async ($, on) => {
  const world = fakeWorld(on)
  await joined($, world)
  world.work.push({ kind: 'request', ...REQUEST })
  await world.clock.advance(1000)
  await $.turn.start({ text: framed(world.submitted[0]!), turnId: 't1' })
  await $.turn.complete({ ...DONE, turnId: 't1', answer: 'Started the build.' })
  await $.prompt.submit({ text: 'A task finished.', wait: false, origin: { kind: 'task-notification' } as never })
  await $.turn.start({ text: 'A task finished.', turnId: 't2' })
  world.answerStatus = 409
  await $.turn.complete({ ...DONE, turnId: 't2', answer: 'The build passed.' })
  world.take('join')
  await world.clock.advance(1000)
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', syncs: true, missed: true }])
  expect(world.logs.some(line => line.includes('did not get the last answer'))).toBe(false)
})

test('bandShowsTheCallAndStartsIt', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...LIVE, args: 'on' })
  world.status = {
    ...world.status, call: 'listening', unheard: 2,
    sessions: [{ sessionId: ID, label: 'Example session', activity: 'idle', isTarget: true }],
  }
  await world.clock.advance(1000)
  for (const surface of ['terminal', 'desktop'] as const) {
    const band = await $.ui.mount({ ...BAND, surface })
    expect((await band.find({ type: 'Text', text: /Listening/ }))?.text).toContain('Listening')
    expect((await band.find({ type: 'Text', text: /unheard/ }))?.text).toContain('2 unheard')
    expect(await band.find({ key: 'target' })).toBeUndefined()
    await band.press({ key: 'call' })
    expect(world.take('call')).toEqual([{ action: 'stop' }])
    await band.unmount()
  }
})

test('aFailedSummaryIsReportedNotThrown', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...LIVE, args: 'on' })
  world.forkFails = 'api-error'
  expect((await $.command.run({ ...LIVE, args: 'context' })).text).toContain('could not summarise')
  world.work.push({ kind: 'context' })
  await world.clock.advance(1000)
  expect(world.take('context')).toEqual([])
  expect(world.logs.some(line => line.includes('could not summarise'))).toBe(true)
  expect(world.logs.some(line => line.includes('poll failed'))).toBe(false)
})

test('theSummaryIsSentWholeForTheAppToRedactAndCap', async ($, on) => {
  // Cutting before the app redacts could shorten a token past what its patterns match.
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...LIVE, args: 'on' })
  world.summary = `${'x'.repeat(1495)} sk-${'a'.repeat(30)}`
  await $.command.run({ ...LIVE, args: 'context' })
  expect(world.take('context')).toEqual([{ sessionId: ID, summary: world.summary }])
})
