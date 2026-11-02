import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

import { spokenReply, voicePrompt } from '../hooks/prompt.ts'
import type { VoiceRequest } from '../hooks/wire.ts'
import { BAND, fakeWorld, framed, ID, LIVE } from './fake-bridge.ts'

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
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', owner: true }])
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
  world.work.push({ kind: 'reply', ...SPOKEN })
  await world.clock.advance(1000)
  expect((await asked).result).toEqual({ questions: ASKED, answers: {}, response: spokenReply(SPOKEN) })
  expect(world.take('activity')).toEqual([{ sessionId: ID, state: 'working' }])
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
  world.work.push({ kind: 'reply', ...SPOKEN })
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
