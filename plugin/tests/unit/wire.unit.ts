import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { test } from 'node:test'

import { socketPath } from '../../hooks/wire.ts'
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
})
const WORK: Shape = {
  anyOf: [
    fields<Extract<Wire.Work, { kind: 'request' }>>({
      kind: { oneOf: ['request'] }, id: S, brief: S, transcript: { list: UTTERANCE },
    }),
    fields<Extract<Wire.Work, { kind: 'reply' }>>({
      kind: { oneOf: ['reply'] }, id: S, brief: S, transcript: { list: UTTERANCE },
    }),
    fields<Extract<Wire.Work, { kind: 'context' }>>({ kind: { oneOf: ['context'] } }),
  ],
}

const SHAPES: Record<string, Shape> = {
  'activity': fields<Wire.ActivityBody>({
    sessionId: S, state: { oneOf: ['idle', 'working', 'approval'] }, question: optional(S),
    text: optional(S),
  }),
  'answer': fields<Wire.AnswerBody>({
    sessionId: S, id: S, status: { oneOf: ['ok', 'failed', 'question', 'update'] }, text: S,
    reason: optional(S),
  }),
  'call': fields<Wire.CallBody>({ action: { oneOf: ['start', 'stop'] } }),
  'context': fields<Wire.ContextBody>({ sessionId: S, summary: S }),
  'error': fields<Wire.ErrorReply>({ error: S, code: optional({ oneOf: ['removed'] }) }),
  'join': fields<Wire.JoinBody>({ sessionId: S, title: S, replaces: optional(S), owner: optional('boolean'), modVersion: optional(S) }),
  'leave': fields<Wire.LeaveBody>({ sessionId: S }),
  'next': fields<Wire.PollReply>({ status: STATUS, work: optional(WORK) }),
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
  assert.ok(names.length >= 13)
  for (const name of names) {
    const shape = SHAPES[name.replace(/(-[a-z]+)?\.json$/, '')]
    assert.ok(shape, `${name}: no wire type for this fixture`)
    assert.deepEqual(mismatches(JSON.parse(readFileSync(`${dir}/${name}`, 'utf8')), shape, name), [])
  }
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
