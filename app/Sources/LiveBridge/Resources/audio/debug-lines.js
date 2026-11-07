// Debug builds only. The fake microphone's scripted lines: the first plays when the microphone is
// taken, each next one once the voice has finished its reply and has been quiet for `quietMs`
// (its transcript ends before its audio does). What the voice finishes during a line is a word
// dropped into it ("Mm-hmm"), not a reply, and what it finishes after a handoff is its
// acknowledgement: the line waits for the answer. A line with a cut plays over the voice instead, that
// long into its reply. Pure: the page passes in what plays a line.

/** `play(index)` plays line `index`; `ended` reports it played out. */
export function createFakeLines({ count, play, quietMs = 600, cuts = [] }) {
  let current = 0;
  let playing = false;
  let stopped = true; // until the microphone is taken
  let due = false; // a finished reply is owed the next line
  let quietSince = 0;
  let replyFrom = null; // when the voice's current reply became loud
  let cutOff = false; // the reply a cut line spoke over has not finished
  let acknowledging = false; // a handoff was queued: what the voice finishes next is its "On it"

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
      due = false;
    },
    ended() {
      playing = false;
    },
    voiceFinished(tMs) {
      if (cutOff && replyFrom === null) {
        cutOff = false; // what finished is the reply cut off, which owes nothing
        return;
      }
      if (playing) return; // a word dropped into a line, not a reply to it
      cutOff = false;
      if (acknowledging) {
        acknowledging = false;
        replyFrom = null;
        return;
      }
      replyFrom = null;
      due = !stopped && current + 1 < count;
      quietSince = tMs;
    },
    /** The voice handed a request to Claude. */
    handoff() {
      acknowledging = true;
    },
    /** One frame of the voice: whether it was loud, and when. */
    voice(loud, tMs) {
      if (loud) quietSince = tMs;
      if (loud && !playing && replyFrom === null) replyFrom = tMs;
      const cut = cuts[current + 1];
      if (!stopped && !playing && !acknowledging && cut != null && replyFrom !== null && tMs - replyFrom >= cut) {
        current++;
        replyFrom = null;
        cutOff = true;
        due = false;
        begin();
        return;
      }
      if (!due || stopped || playing || loud || tMs - quietSince < quietMs) return;
      due = false;
      current++;
      begin();
    },
  };
}
