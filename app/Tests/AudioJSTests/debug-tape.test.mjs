import assert from 'node:assert/strict';
import { test } from 'node:test';
import { pcmChunk } from '../../Sources/LiveBridge/Resources/audio/debug-tape.js';

const samples = (text) => {
  const bytes = Buffer.from(text, 'base64');
  return Array.from({ length: bytes.length / 2 }, (_, i) => bytes.readInt16LE(i * 2));
};

test('a chunk interleaves the two channels, left first', () => {
  const left = Float32Array.of(0.5, 0);
  const right = Float32Array.of(0, -0.5);
  assert.deepEqual(samples(pcmChunk(left, right)), [16384, 0, 0, -16384]);
});

test('samples beyond full scale clip', () => {
  assert.deepEqual(samples(pcmChunk(Float32Array.of(2), Float32Array.of(-2))), [32767, -32768]);
});
