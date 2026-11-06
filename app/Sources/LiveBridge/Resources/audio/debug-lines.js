// Debug builds only. The fake microphone's scripted lines: the first plays when the microphone is
// taken, each next one once the voice has finished its reply and has been quiet for `quietMs`
// (its transcript ends before its audio does). Pure: the page passes in what plays a line.

/** `play(index)` plays line `index`; `ended` reports it played out. */
export function createFakeLines({ count, play, quietMs = 600 }) {
  let current = 0;
  let playing = false;
  let stopped = false;
  let due = false; // a finished reply is owed the next line
  let quietSince = 0;

  function begin() {
    playing = true;
    play(current);
  }

  return {
    /** The microphone was taken: the current line plays, from its start. */
    start() {
      stopped = false;
      begin();
    },
    /** The microphone was released. */
    stop() {
      stopped = true;
      playing = false;
    },
    ended() {
      playing = false;
    },
    voiceFinished(tMs) {
      due = current + 1 < count;
      quietSince = tMs;
    },
    /** One frame of the voice: whether it was loud, and when. */
    voice(loud, tMs) {
      if (loud) quietSince = tMs;
      if (!due || stopped || playing || loud || tMs - quietSince < quietMs) return;
      due = false;
      current++;
      begin();
    },
  };
}
