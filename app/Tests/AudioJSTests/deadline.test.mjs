import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { within } from '../../Sources/LiveBridge/Resources/audio/deadline.js';

const late = () => new Error('late');

test('aPromiseThatNeverSettlesFailsAtTheDeadline', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    const never = new Promise(() => {});
    let settled = 'pending';
    const result = within(never, 10000, late).then(
      () => (settled = 'resolved'),
      (error) => (settled = error.message),
    );
    mock.timers.tick(9999);
    await new Promise(setImmediate); // every reaction to a deadline that fired has run by now
    assert.equal(settled, 'pending', 'still waiting 1 ms before the deadline');
    mock.timers.tick(1);
    await result;
    assert.equal(settled, 'late');
  } finally {
    mock.timers.reset();
  }
});

test('aPromiseInTimeSettlesAsItIs', async () => {
  assert.equal(await within(Promise.resolve('stream'), 10000, late), 'stream');
  await assert.rejects(within(Promise.reject(new Error('denied')), 10000, late), /denied/);
});

test('aValueAfterTheDeadlineGoesToOnLate', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    let resolve;
    const slow = new Promise((r) => (resolve = r));
    const handed = [];
    const result = within(slow, 10000, late, (value) => handed.push(value)).catch((e) => e.message);
    mock.timers.tick(10000);
    assert.equal(await result, 'late');
    resolve('stream');
    await slow;
    await Promise.resolve();
    assert.deepEqual(handed, ['stream'], 'a stream that opens late is handed back to be stopped');
  } finally {
    mock.timers.reset();
  }
});
