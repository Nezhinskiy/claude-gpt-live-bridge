// The audio before and during a connect. `createPreroll` keeps the last seconds of the
// microphone; `createCatchUp` queues what is said while the line connects and lets the line
// catch up with the speaker by dropping silence while it lags (ADR 0001 (c)); `createLineAudio`
// holds the two for the line. Pure.

import { THRESHOLD_DB, dbfs, rms } from './vad.js';

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


export function createCatchUp({ sampleRate = 48000, thresholdDb = THRESHOLD_DB, keepMs = 40 } = {}) {
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

/** The line's audio: the pre-roll while nobody is speaking, and from the first word (`hold`)
 * the queue the line plays from. */
export function createLineAudio({ sampleRate = 48000, frame = 1024 } = {}) {
  const preroll = createPreroll({ sampleRate });
  const catchUp = createCatchUp({ sampleRate });
  let holding = false; // a connect is under way: frames queue instead of filling the pre-roll
  const clear = () => {
    holding = false;
    catchUp.clear();
  };
  return {
    write(f32) {
      if (holding) catchUp.push(f32);
      else preroll.write(f32);
    },
    /** Queues the pre-roll and what follows for the line; `keep` false drops the pre-roll, for
     * a line nobody spoke on. */
    hold(keep = true) {
      if (holding) return;
      holding = true;
      const kept = preroll.drain();
      if (!keep) return;
      for (let i = kept.length % frame; i < kept.length; i += frame) catchUp.push(kept.subarray(i, i + frame));
    },
    pull: () => catchUp.pull(),
    /** The line ended: nothing held or queued. */
    clear,
    /** As `clear`, and the pre-roll emptied: nothing recorded so far can reach a line. */
    reset() {
      clear();
      preroll.drain();
    },
  };
}
