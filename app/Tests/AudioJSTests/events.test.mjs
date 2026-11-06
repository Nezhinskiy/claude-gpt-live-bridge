import assert from 'node:assert/strict';
import { test } from 'node:test';
import { lineError } from '../../Sources/LiveBridge/Resources/audio/events.js';

test('anErrorEventGivesItsMessageAndCode', () => {
  const event = { type: 'error', error: { code: 'usage_check_failed', message: 'Unable to verify usage availability.' } };
  assert.deepEqual(lineError(JSON.stringify(event)), { code: 'usage_check_failed', message: 'Unable to verify usage availability.' });
});

test('anEmptyMessageFallsBackToTheCode', () => {
  assert.deepEqual(lineError('{"type":"error","error":{"code":"usage_check_failed","message":""}}'), { code: 'usage_check_failed', message: 'usage_check_failed' });
});

test('anErrorTypeStandsInForAMissingCode', () => {
  assert.deepEqual(lineError('{"type":"error","error":{"type":"usage_limit_reached","message":"No."}}'), { code: 'usage_limit_reached', message: 'No.' });
});

test('anyOtherEventGivesNothing', () => {
  assert.equal(lineError('{"type":"session.started"}'), null);
});

test('textThatIsNotJSONGivesNothing', () => {
  assert.equal(lineError('not json'), null);
});
