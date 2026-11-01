import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { within } from '../../Sources/LiveBridge/Resources/audio/deadline.js';

const late = () => new Error('late');

test('aPromiseThatNeverSettlesFailsAtTheDeadline', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    const never = new Promise(() => {});
    const result = within(never, 10000, late).then(() => 'resolved', (error) => error.message);
    mock.timers.tick(9999);
    await Promise.resolve();
    mock.timers.tick(1);
    assert.equal(await result, 'late');
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
