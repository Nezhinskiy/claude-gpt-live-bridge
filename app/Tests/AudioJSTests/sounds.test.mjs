import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const bundled = (name) =>
  readFileSync(new URL(`../../Sources/LiveBridge/Resources/audio/${name}.wav`, import.meta.url));

// AudioHost plays each with `?.play()`, so a missing or unreadable file is only silence.
for (const name of ['handoff', 'chime']) {
  test(`${name}IsBundledAsPcmWav`, () => {
    const wav = bundled(name);
    assert.equal(wav.toString('latin1', 0, 4), 'RIFF');
    assert.equal(wav.toString('latin1', 8, 12), 'WAVE');
    assert.equal(wav.readUInt16LE(20), 1, 'PCM');
    assert.equal(wav.readUInt32LE(24), 44100, 'sample rate');
    assert.equal(wav.readUInt32LE(40), wav.length - 44, 'the data fills the file');
    assert.ok(wav.length > 44, 'there is sound in it');
  });
}
