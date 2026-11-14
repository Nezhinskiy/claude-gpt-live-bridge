import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { test } from 'node:test'

import { TurnTracker } from '../../hooks/turns.ts'
import { CONTEXT_TIMEOUT_MS, MODEL_CHECK_TIMEOUT_MS, socketPath } from '../../hooks/wire.ts'
import type * as Wire from '../../hooks/wire.ts'

// A field-by-field description of each wire type. `fields<T>` takes exactly the keys of T, so
// a field added to or removed from wire.ts fails the type check until its shape is written here.
type Shape =
  | 'string' | 'number' | 'boolean'
  | { oneOf: readonly string[] }
  | { list: Shape }
  | { optional: Shape }
  | { fields: Record<string, Shape> }
  | { anyOf: readonly Shape[] }

const fields = <T>(shape: { [K in keyof Required<T>]: Shape }): Shape => ({ fields: shape })
const optional = (shape: Shape): Shape => ({ optional: shape })
const S = 'string'

const UTTERANCE = fields<Wire.Utterance>({ role: { oneOf: ['user', 'assistant'] }, text: S })
const ROW = fields<Wire.SessionRow>({
  sessionId: S, label: S, activity: { oneOf: ['idle', 'working', 'approval'] }, isTarget: 'boolean',
})
const STATUS = fields<Wire.StatusReply>({
  call: { oneOf: ['off', 'listening', 'connecting', 'live'] },
  sessions: { list: ROW },
  minutesToday: 'number',
  problem: optional(S),
  unheard: 'number',
  isMuted: optional('boolean'),
})
const WORK: Shape = {
  anyOf: [
    fields<Extract<Wire.Work, { kind: 'request' }>>({
      kind: { oneOf: ['request'] }, id: S, brief: S, transcript: { list: UTTERANCE },
    }),
    fields<Extract<Wire.Work, { kind: 'reply' }>>({
      kind: { oneOf: ['reply'] }, id: S, brief: S, transcript: { list: UTTERANCE }, forRequest: optional(S),
    }),
    fields<Extract<Wire.Work, { kind: 'context' }>>({
      kind: { oneOf: ['context'] }, model: optional(S), fallbackModel: optional(S), ask: optional('number'),
    }),
    fields<Extract<Wire.Work, { kind: 'checkModel' }>>({ kind: { oneOf: ['checkModel'] }, id: S, model: S }),
  ],
}

const REASON = { oneOf: ['model-refused', 'api-error', 'empty-reply', 'timed-out', 'transcript-unreadable'] } as const

const TURN = fields<Wire.TurnRef>({ id: S, request: optional(S) })

const SHAPES: Record<string, Shape> = {
  'activity': fields<Wire.ActivityBody>({
    sessionId: S, state: { oneOf: ['idle', 'working', 'approval'] }, question: optional(S),
    text: optional(S), turn: optional(TURN),
  }),
  'answer': fields<Wire.AnswerBody>({
    sessionId: S, id: S, status: { oneOf: ['ok', 'failed', 'question', 'update'] }, text: S,
    reason: optional(S),
  }),
  'call': fields<Wire.CallBody>({ action: { oneOf: ['start', 'stop', 'mute', 'unmute'] } }),
  'context': fields<Wire.ContextBody>({
    sessionId: S, summary: S,
    failures: optional({
      list: fields<Wire.SummaryFailure>({
        reason: REASON, error: optional(S),
      }),
    }),
    stats: optional(fields<Wire.SummaryStats>({
      durationMs: 'number', transcriptChars: 'number', inputTokens: 'number', outputTokens: 'number',
    })),
    ask: optional('number'),
  }),
  'error': fields<Wire.ErrorReply>({ error: S, code: optional({ oneOf: ['removed'] }) }),
  'join': fields<Wire.JoinBody>({ sessionId: S, title: S, replaces: optional(S), owner: optional('boolean'), modVersion: optional(S), syncs: optional('boolean'), missed: optional('boolean'), writesSummaries: optional('boolean') }),
  'leave': fields<Wire.LeaveBody>({ sessionId: S }),
  'limits': fields<Wire.LimitsBody>({
    sessionId: S,
    windows: { list: fields<Wire.LimitWindowBody>({ kind: S, percentUsed: 'number', resetsAt: optional(S) }) },
  }),
  'model': fields<Wire.ModelCheckBody>({
    sessionId: S, id: S, ok: 'boolean', reason: optional(REASON), error: optional(S),
  }),
  'next': fields<Wire.PollReply>({ status: STATUS, work: optional(WORK) }),
  'sync': fields<Wire.SyncBody>({
    sessionId: S, turn: TURN, kind: { oneOf: ['start', 'typed', 'answer', 'report'] }, text: optional(S),
  }),
  'target': fields<Wire.TargetBody>({ sessionId: S }),
}

/** The paths at which `value` does not match `shape`; empty when it does. */
function mismatches(value: unknown, shape: Shape, at: string): string[] {
  if (typeof shape === 'string') return typeof value === shape ? [] : [`${at}: not a ${shape}`]
  if ('oneOf' in shape) return shape.oneOf.includes(value as string) ? [] : [`${at}: ${String(value)}`]
  if ('optional' in shape) return mismatches(value, shape.optional, at)
  if ('anyOf' in shape) {
    return shape.anyOf.some(one => mismatches(value, one, at).length === 0) ? [] : [`${at}: no variant`]
  }
  if ('list' in shape) {
    if (!Array.isArray(value)) return [`${at}: not a list`]
    return value.flatMap((item, i) => mismatches(item, shape.list, `${at}[${i}]`))
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return [`${at}: not an object`]
  const record = value as Record<string, unknown>
  const extra = Object.keys(record).filter(key => !(key in shape.fields)).map(key => `${at}.${key}: unknown`)
  return extra.concat(Object.entries(shape.fields).flatMap(([key, field]) => {
    if (record[key] === undefined) return typeof field === 'object' && 'optional' in field ? [] : [`${at}.${key}: missing`]
    if (record[key] === null) return [`${at}.${key}: null (absent fields are omitted)`]
    return mismatches(record[key], field, `${at}.${key}`)
  }))
}

test('everyWireFixtureParsesIntoItsType', () => {
  const dir = `${import.meta.dirname}/../../../wire/fixtures`
  const names = readdirSync(dir).filter(name => name.endsWith('.json'))
  assert.ok(names.length >= 29)
  for (const name of names) {
    const shape = SHAPES[name.replace(/(-[a-z]+)*\.json$/, '')]
    assert.ok(shape, `${name}: no wire type for this fixture`)
    assert.deepEqual(mismatches(JSON.parse(readFileSync(`${dir}/${name}`, 'utf8')), shape, name), [])
  }
})

/** An older app's reply has no `forRequest`: the mod goes on as if it had said nothing of the answer. */
test('aReplyWithoutItsRequestLeavesTheTurnTyped', () => {
  const dir = `${import.meta.dirname}/../../../wire/fixtures`
  const { work } = JSON.parse(readFileSync(`${dir}/next-reply-older.json`, 'utf8')) as Wire.PollReply
  assert.ok(work?.kind === 'reply')
  const tracker = new TurnTracker()
  tracker.turnStarted('t1', 'Rename the folder', 'owner', 0)
  tracker.replied(work.id, work.forRequest, 1000)
  assert.deepEqual(tracker.current, { id: 't1' })
})

test('theCheckRejectsADriftedShape', () => {
  const join = { sessionId: 'a', title: 'b' }
  assert.deepEqual(mismatches(join, SHAPES['join']!, 'join'), [])
  assert.deepEqual(mismatches({ ...join, extra: 1, title: null }, SHAPES['join']!, 'join'), [
    'join.extra: unknown', 'join.title: null (absent fields are omitted)',
  ])
})

test('socketFollowsTheHomeFoundationUses', () => {
  // The app finds Application Support through Foundation, which honours CFFIXED_USER_HOME.
  const rel = 'Library/Application Support/LiveBridge/run/bridge.sock'
  assert.equal(socketPath('/Users/example', undefined), `/Users/example/${rel}`)
  assert.equal(socketPath('/Users/example', ''), `/Users/example/${rel}`)
  assert.equal(socketPath('/Users/example', '/tmp/lb'), `/tmp/lb/${rel}`)
})

/** The mod gives a summary up after the budget the app waits on: this file ties their two constants. */
test('theSummaryBudgetIsTheApps', () => {
  const budget = JSON.parse(readFileSync(`${import.meta.dirname}/../../../wire/summary-budget.json`, 'utf8'))
  assert.equal(CONTEXT_TIMEOUT_MS, budget.summaryBudgetMs)
})

/** The app gives a model check up later than the mod does: this file ties the mod's limit. */
test('theModelCheckLimitIsTheFiles', () => {
  const budget = JSON.parse(readFileSync(`${import.meta.dirname}/../../../wire/summary-budget.json`, 'utf8'))
  assert.equal(MODEL_CHECK_TIMEOUT_MS, budget.modelCheckMs)
})
