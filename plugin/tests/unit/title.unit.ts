import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

import { fallbackTitle, titleFromRegistry } from '../../hooks/title.ts'

const record: unknown = JSON.parse(
  readFileSync(`${import.meta.dirname}/../fixtures/adr/session-registry-record.json`, 'utf8'),
)
const ID = '00000000-0000-0000-0000-000000000001'

test('titleFromTheRegistryRecord', () => {
  const other = { sessionId: '11111111-0000-0000-0000-000000000002', name: 'Other session' }
  assert.equal(titleFromRegistry([null, 'text', other, record], ID), 'Example session')
})

test('missingRecordIsNull', () => {
  assert.equal(titleFromRegistry([], ID), null)
  assert.equal(titleFromRegistry([{ sessionId: ID }, { sessionId: ID, name: '  ' }], ID), null)
})

test('fallbackIsTheFolderName', () => {
  assert.equal(fallbackTitle('/Users/example/Dev/example-project/'), 'example-project')
  assert.equal(fallbackTitle('/'), '/')
})
