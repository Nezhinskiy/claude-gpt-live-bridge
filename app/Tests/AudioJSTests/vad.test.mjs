import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createVad } from '../../Sources/LiveBridge/Resources/audio/vad.js';

const frameMs = 1024 / 48; // one 1024-sample frame at 48 kHz
const loud = 0.1; // -20 dBFS
const quiet = 0.001; // -60 dBFS

/** Feeds `ms` of one level from `t0`; returns the non-null decisions with their times. */
function feed(vad, rms, t0, ms) {
  const out = [];
  for (let t = t0; t < t0 + ms; t += frameMs) {
    const decision = vad.push(rms, t);
    if (decision) out.push([decision, t]);
  }
  return out;
}

test('ignoresShortBlips', () => {
  const vad = createVad();
  assert.deepEqual(feed(vad, loud, 0, 200), []);
  assert.deepEqual(feed(vad, quiet, 200, 1000), []);
});

test('startsAfterMinSpeech', () => {
  const vad = createVad();
  const decisions = feed(vad, loud, 0, 400);
  assert.equal(decisions.length, 1);
  assert.equal(decisions[0][0], 'start');
  assert.ok(decisions[0][1] >= 250 && decisions[0][1] < 250 + frameMs);
});

test('endsAfterHang', () => {
  const vad = createVad();
  feed(vad, loud, 0, 1000);
  assert.deepEqual(feed(vad, quiet, 1000, 500), [], 'a pause shorter than the hang keeps speech');
  feed(vad, loud, 1500, 200);
  const decisions = feed(vad, quiet, 1700, 1000);
  assert.equal(decisions.length, 1);
  assert.equal(decisions[0][0], 'end');
  assert.ok(decisions[0][1] >= 1700 + 600 - frameMs && decisions[0][1] < 1700 + 600 + frameMs);
});
