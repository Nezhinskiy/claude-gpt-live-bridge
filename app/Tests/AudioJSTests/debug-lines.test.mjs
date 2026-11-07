import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createFakeLines } from '../../Sources/LiveBridge/Resources/audio/debug-lines.js';

/** Lines that record which were played, with the first one started. */
function rig(count, quietMs = 1000) {
  const played = [];
  const lines = createFakeLines({ count, play: (index) => played.push(index), quietMs });
  lines.start();
  return { lines, played };
}

test('start plays the first line and no other', () => {
  assert.deepEqual(rig(3).played, [0]);
});

test('the next line waits for the voice to finish', () => {
  const { lines, played } = rig(2);
  lines.ended();
  lines.voice(false, 5000);
  assert.deepEqual(played, [0]);
});

test('the next line starts once the voice has been quiet for the gap', () => {
  const { lines, played } = rig(2);
  lines.ended();
  lines.voiceFinished(1000);
  lines.voice(false, 1900);
  assert.deepEqual(played, [0]);
  lines.voice(false, 2000);
  assert.deepEqual(played, [0, 1]);
});

test('audio still playing after the transcript holds the next line back', () => {
  const { lines, played } = rig(2);
  lines.ended();
  lines.voiceFinished(1000);
  lines.voice(true, 1800);
  lines.voice(false, 2000);
  assert.deepEqual(played, [0]);
  lines.voice(false, 3000);
  assert.deepEqual(played, [0, 1]);
});

test('one finished reply plays one line', () => {
  const { lines, played } = rig(3);
  lines.ended();
  lines.voiceFinished(1000);
  lines.voice(false, 2000);
  lines.ended();
  lines.voice(false, 9000);
  assert.deepEqual(played, [0, 1]);
});

test('after the last line nothing plays', () => {
  const { lines, played } = rig(1);
  lines.ended();
  lines.voiceFinished(1000);
  lines.voice(false, 9000);
  assert.deepEqual(played, [0]);
});

test('starting again replays the current line, as Unmute takes the microphone again', () => {
  const { lines, played } = rig(2);
  lines.ended();
  lines.voiceFinished(1000);
  lines.voice(false, 2000);
  lines.stop();
  lines.start();
  assert.deepEqual(played, [0, 1, 1]);
});

test('a stopped microphone plays no next line', () => {
  const { lines, played } = rig(2);
  lines.stop();
  lines.voiceFinished(1000);
  lines.voice(false, 9000);
  assert.deepEqual(played, [0]);
});

test('a reply before the microphone is taken does not skip the first line', () => {
  const played = [];
  const lines = createFakeLines({ count: 2, play: (index) => played.push(index), quietMs: 1000 });
  lines.voiceFinished(0);
  lines.voice(false, 5000);
  assert.deepEqual(played, []);
  lines.start();
  assert.deepEqual(played, [0]);
});

test('a reply finished while muted owes no line after the replay', () => {
  const { lines, played } = rig(2);
  lines.ended();
  lines.stop();
  lines.voiceFinished(1000);
  lines.start();
  lines.ended();
  lines.voice(false, 5000);
  assert.deepEqual(played, [0, 0]);
});

/** Lines where line 1 cuts in 3000 ms into the voice's reply. */
function cutRig() {
  const played = [];
  const lines = createFakeLines({ count: 3, play: (index) => played.push(index), quietMs: 1000, cuts: [null, 3000] });
  lines.start();
  lines.ended();
  return { lines, played };
}

test('a cut line plays over the voice, that long into its reply', () => {
  const { lines, played } = cutRig();
  lines.voice(true, 1000);
  lines.voice(true, 3900);
  assert.deepEqual(played, [0]);
  lines.voice(true, 4000);
  assert.deepEqual(played, [0, 1]);
});

test('the reply that was cut off owes no line when it finishes', () => {
  const { lines, played } = cutRig();
  lines.voice(true, 1000);
  lines.voice(true, 4000);
  lines.voiceFinished(4200);
  lines.ended();
  lines.voice(false, 9000);
  assert.deepEqual(played, [0, 1]);
});

test('the reply to a cut line owes the next line', () => {
  const { lines, played } = cutRig();
  lines.voice(true, 1000);
  lines.voice(true, 4000);
  lines.voiceFinished(4200);
  lines.ended();
  lines.voice(true, 6000);
  lines.voiceFinished(8000);
  lines.voice(false, 9000);
  assert.deepEqual(played, [0, 1, 2]);
});

test('a word the voice drops into a playing line owes no line', () => {
  const played = [];
  const lines = createFakeLines({ count: 3, play: (index) => played.push(index) });
  lines.start();
  lines.voice(true, 3000);
  lines.voiceFinished(3500);
  lines.ended();
  lines.voice(false, 9000);
  assert.deepEqual(played, [0]);
  lines.voice(true, 10000);
  lines.voiceFinished(12000);
  lines.voice(false, 13000);
  assert.deepEqual(played, [0, 1]);
});

test('after a handoff the next line waits for the answer, not the acknowledgement', () => {
  const { lines, played } = rig(2);
  lines.ended();
  lines.handoff();
  lines.voiceFinished(1000);
  lines.voice(false, 9000);
  assert.deepEqual(played, [0]);
  lines.voice(true, 20000);
  lines.voiceFinished(25000);
  lines.voice(false, 26000);
  assert.deepEqual(played, [0, 1]);
});
