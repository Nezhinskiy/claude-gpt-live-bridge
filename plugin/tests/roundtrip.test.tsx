import { expect, test } from 'claude-code/testing'

import { voicePrompt } from '../hooks/prompt.ts'
import type { VoiceRequest } from '../hooks/wire.ts'
import { BAND, fakeWorld, framed, ID, VOICEMOD } from './fake-bridge.ts'

const REQUEST: VoiceRequest = {
  id: '00000000-0000-0000-0000-00000000000a',
  brief: 'Please list the files in this folder',
  transcript: [{ role: 'user', text: 'Please list the files in this folder' }],
}
const DONE = { durationMs: 1, isAborted: false, reason: 'answer' } as const

test('roundtrip', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/Users/example/Dev/example-project', surface: 'terminal', isInteractive: true })
  const reply = await $.command.run({ ...VOICEMOD, args: 'on' })
  expect(reply.text).toContain('Example session')
  expect(world.take('join')).toEqual([{ sessionId: ID, title: 'Example session', autoContext: false }])
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
  expect((await $.command.run({ ...VOICEMOD, args: 'on' })).text).toContain('Joined')
  expect((await $.command.run({ ...VOICEMOD, args: 'status' })).text).toContain('joining')
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

test('approvalIsReported', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...VOICEMOD, args: 'on' })
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

test('bandShowsTheCallAndStartsIt', async ($, on) => {
  const world = fakeWorld(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...VOICEMOD, args: 'on' })
  world.status = {
    ...world.status, call: 'listening', target: ID, unheard: 2,
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
    await band.press({ key: 'context' })
    expect(world.take('context')).toEqual([{ sessionId: ID, summary: 'Goal: tidy the example project.' }])
    await band.unmount()
  }
})
