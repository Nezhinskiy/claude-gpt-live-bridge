// Local voice detection on frame energy. Speech starts after `minSpeechMs` of frames above
// `thresholdDb` and ends after `hangMs` below it. Pure: no Web APIs, tested with node --test.

/** Frame RMS (linear, 0 to 1) to dBFS. */
export const dbfs = (rms) => 20 * Math.log10(Math.max(rms, 1e-9));

export function createVad({ thresholdDb = -45, minSpeechMs = 250, hangMs = 600 } = {}) {
  let speaking = false;
  let loudSince = null;
  let lastLoud = 0;
  return {
    /** @returns {'start' | 'end' | null} */
    push(frameRms, tMs) {
      const loud = dbfs(frameRms) > thresholdDb;
      if (!speaking) {
        if (!loud) loudSince = null;
        else if (loudSince === null) loudSince = tMs;
        if (loud && tMs - loudSince >= minSpeechMs) {
          speaking = true;
          lastLoud = tMs;
          return 'start';
        }
        return null;
      }
      if (loud) lastLoud = tMs;
      else if (tMs - lastLoud >= hangMs) {
        speaking = false;
        loudSince = null;
        return 'end';
      }
      return null;
    },
  };
}
