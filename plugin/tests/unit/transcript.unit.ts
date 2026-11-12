import assert from 'node:assert/strict'
import { test } from 'node:test'

import { FIRST_CAP, MESSAGE_CAP, transcriptText } from '../../hooks/transcript.ts'
import type { TranscriptMessage } from '../../hooks/transcript.ts'

const user = (text: string): TranscriptMessage => ({ role: 'user', content: [{ type: 'text', text }] })
const claude = (text: string): TranscriptMessage => ({ role: 'assistant', content: [{ type: 'text', text }] })

test('remindersToolResultsAndThinkingAreLeftOut', () => {
  const text = transcriptText([
    { role: 'user', content: 'Rename the helper <system-reminder>The date is today.</system-reminder>' },
    { role: 'assistant', content: [{ type: 'thinking', text: 'SECRET-THOUGHT' }, { type: 'text', text: 'Renaming it.' }] },
    { role: 'user', content: [{ type: 'tool_result', text: 'SECRET-OUTPUT' }, { type: 'image' }] },
    { role: 'user', content: [{ type: 'text', text: '<system-reminder>Only a reminder.</system-reminder>' }] },
    claude('Renamed.'),
  ])
  assert.match(text, /Rename the helper/)
  assert.match(text, /Renaming it\./)
  assert.match(text, /Renamed\./)
  for (const left of ['system-reminder', 'The date is today', 'SECRET-THOUGHT', 'SECRET-OUTPUT', 'Only a reminder']) {
    assert.ok(!text.includes(left), left)
  }
})

test('aToolUseIsItsNameAlone', () => {
  const text = transcriptText([
    user('List the files'),
    { role: 'assistant', content: [{ type: 'tool_use', name: 'Bash', text: 'SECRET-INPUT' }] },
  ])
  assert.match(text, /Bash/)
  assert.ok(!text.includes('SECRET-INPUT'))
})

test('aLongMessageKeepsItsStartAndEnd', () => {
  const long = `START${'x'.repeat(MESSAGE_CAP - 8)}END!`
  assert.equal(long.length, MESSAGE_CAP + 1)
  const text = transcriptText([user('Tidy the project'), claude(long)])
  const kept = text.slice(text.indexOf('START'))
  assert.ok(kept.endsWith('END!'))
  assert.match(kept, /left out/)
  assert.ok(kept.length <= MESSAGE_CAP)
})

test('theGoalThenTheNewestUntilTheBudget', () => {
  const goal = `GOAL${'g'.repeat(FIRST_CAP)}`
  const middle = Array.from({ length: 40 }, (_, i) => claude(`m${String(i).padStart(2, '0')} ${'y'.repeat(900)}`))
  const budget = 20_000
  const text = transcriptText([user(goal), ...middle], budget)
  assert.ok(text.length <= budget)
  assert.ok(text.indexOf('GOAL') < text.indexOf('m39'))
  // The goal is cut to its cap, the newest messages follow, and the oldest after the goal go.
  const first = text.split('\n\n')[0]!
  assert.ok(first.includes('GOAL') && first.length <= FIRST_CAP + 20)
  assert.match(text, /m39/)
  assert.ok(!text.includes('m00'))
  const left = Number(/(\d+) messages? left out/.exec(text)?.[1])
  const shown = middle.filter((_, i) => text.includes(`m${String(i).padStart(2, '0')} `)).length
  assert.equal(left + shown, middle.length)
  assert.ok(left > 0)
})
