import assert from 'node:assert/strict';
import { test } from 'node:test';
import { lineError } from '../../Sources/LiveBridge/Resources/audio/events.js';

test('anErrorEventGivesItsMessageAndCode', () => {
  const event = { type: 'error', error: { code: 'usage_check_failed', message: 'Unable to verify usage availability.' } };
  assert.equal(lineError(JSON.stringify(event)), 'Unable to verify usage availability. (usage_check_failed)');
});

test('anErrorWithOnlyACodeGivesTheCode', () => {
  assert.equal(lineError('{"type":"error","error":{"code":"usage_check_failed"}}'), 'usage_check_failed');
});

test('anyOtherEventGivesNothing', () => {
  assert.equal(lineError('{"type":"session.started"}'), null);
});

test('textThatIsNotJSONGivesNothing', () => {
  assert.equal(lineError('not json'), null);
});
