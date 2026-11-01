// The audio before and during a connect. `createPreroll` keeps the last seconds of the
// microphone; `createCatchUp` queues what is said while the line connects and lets the line
// catch up with the speaker by dropping silence while it lags (ADR 0001 (c)). Pure.

import { dbfs } from './vad.js';

export function createPreroll({ seconds = 2, sampleRate = 48000 } = {}) {
  const ring = new Float32Array(Math.round(seconds * sampleRate));
  let end = 0; // next write position
  let filled = 0;
  return {
    write(f32) {
      for (const sample of f32.subarray(Math.max(0, f32.length - ring.length))) {
        ring[end] = sample;
        end = (end + 1) % ring.length;
      }
      filled = Math.min(ring.length, filled + f32.length);
    },
    /** The kept audio, oldest first; the buffer is empty afterwards. */
    drain() {
      const out = new Float32Array(filled);
      const start = (end - filled + ring.length) % ring.length;
      for (let i = 0; i < filled; i++) out[i] = ring[(start + i) % ring.length];
      filled = 0;
      return out;
    },
  };
}

const rms = (f32) => Math.sqrt(f32.reduce((sum, x) => sum + x * x, 0) / Math.max(1, f32.length));

export function createCatchUp({ sampleRate = 48000, thresholdDb = -45, keepMs = 40 } = {}) {
  const queue = [];
  const keep = (keepMs / 1000) * sampleRate;
  let silentRun = 0; // samples of the current silent run already sent
  const silent = (f32) => dbfs(rms(f32)) <= thresholdDb;
  return {
    push(f32) {
      if (f32.length) queue.push(f32);
    },
    /** The next frame to send, or null when the queue is empty. While more than one frame
     * waits, a silent run is cut to about `keepMs`; once caught up every frame passes. */
    pull() {
      while (queue.length > 1 && silentRun >= keep && silent(queue[0])) queue.shift();
      const next = queue.shift() ?? null;
      if (next) silentRun = silent(next) ? silentRun + next.length : 0;
      return next;
    },
    clear() {
      queue.length = 0;
      silentRun = 0;
    },
  };
}
