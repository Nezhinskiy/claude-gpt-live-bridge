import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createCatchUp, createPreroll } from '../../Sources/LiveBridge/Resources/audio/preroll.js';

const frame = (value, length = 1024) => new Float32Array(length).fill(value);

test('keepsLastTwoSeconds', () => {
  const preroll = createPreroll({ seconds: 2, sampleRate: 1000 });
  for (let i = 0; i < 3000; i += 100) preroll.write(frame(i, 100));
  const kept = preroll.drain();
  assert.equal(kept.length, 2000);
  assert.equal(kept[0], 1000, 'the oldest second is gone');
  assert.equal(kept[1999], 2900, 'the newest frame is last');
});

test('drainEmptiesBuffer', () => {
  const preroll = createPreroll({ seconds: 2, sampleRate: 1000 });
  preroll.write(frame(0.5, 300));
  assert.equal(preroll.drain().length, 300);
  assert.equal(preroll.drain().length, 0);
});

test('catchUpDropsSilenceWhileLagging', () => {
  const catchUp = createCatchUp({ sampleRate: 48000 }); // keeps 40 ms of each silent run
  for (let i = 0; i < 47; i++) catchUp.push(frame(0)); // about one second of silence
  catchUp.push(frame(0.5));
  const pulled = [];
  for (let next = catchUp.pull(); next; next = catchUp.pull()) pulled.push(next);
  assert.equal(pulled.length, 3, 'two silent frames (>= 40 ms) and the spoken one');
  assert.equal(pulled[2][0], 0.5);
});

test('catchUpKeepsEverySpokenFrameAndLiveAudio', () => {
  const catchUp = createCatchUp({ sampleRate: 48000 });
  for (let i = 0; i < 10; i++) catchUp.push(frame(0.1));
  let pulled = 0;
  while (catchUp.pull()) pulled++;
  assert.equal(pulled, 10);
  for (let i = 0; i < 5; i++) {
    catchUp.push(frame(0)); // caught up: live silence passes as it is
    assert.ok(catchUp.pull());
  }
});
