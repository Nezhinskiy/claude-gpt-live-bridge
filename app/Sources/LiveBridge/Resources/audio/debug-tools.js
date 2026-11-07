// Debug builds only; a release bundle leaves out every `debug-*.js`, and `audio.js` imports this
// one only for `--fake-mic` or `--record-call`. The fake microphone plays its scripted lines
// (`debug-lines.js`). One processor hears both sides of the call, the microphone on the left and
// the voice on the right, as they happen: it times the next line by the voice, and with `record`
// sends the two channels to the app's call tape.

import { createFakeLines } from './debug-lines.js';
import { pcmChunk } from './debug-tape.js';
import { THRESHOLD_DB, dbfs, rms } from './vad.js';

const FRAME = 4096;

async function fakeLine(context, index) {
  const data = await (await fetch(`fake-mic-${index}.wav`)).arrayBuffer();
  return context.decodeAudioData(data);
}

export async function createCallTools({ context, lines, cuts, record }) {
  const buffers = await Promise.all(
    Array.from({ length: lines }, (_, index) => fakeLine(context, index)),
  );
  const post = (message) => {
    if (record) window.webkit.messageHandlers.tape.postMessage(message);
  };
  const merger = context.createChannelMerger(2);
  const deck = context.createScriptProcessor(FRAME, 2, 2);
  const silent = context.createGain();
  silent.gain.value = 0;
  merger.connect(deck).connect(silent).connect(context.destination);
  const microphone = context.createGain();
  let playing = null;
  let voice = null;

  const sequence = createFakeLines({
    count: lines,
    cuts,
    play(index) {
      const line = (playing = context.createBufferSource());
      line.buffer = buffers[index];
      line.connect(microphone);
      line.onended = () => {
        if (line === playing) sequence.ended();
      };
      line.start();
      post({ mark: 'line', index });
    },
  });

  deck.onaudioprocess = (event) => {
    const left = event.inputBuffer.getChannelData(0);
    const right = event.inputBuffer.getChannelData(1);
    if (record) post({ pcm: pcmChunk(left, right) });
    sequence.voice(dbfs(rms(right)) > THRESHOLD_DB, context.currentTime * 1000);
  };
  post({ start: true });

  return {
    /** The capture that stands in for the microphone; taking it plays the current line. */
    microphone() {
      sequence.start();
      return {
        node: microphone,
        stop() {
          sequence.stop();
          playing?.stop();
          playing = null;
        },
        onEnded() {},
      };
    },
    tapMicrophone: (node) => node.connect(merger, 0, 0),
    /** The line's incoming audio, or null when the line closed. */
    tapVoice(stream) {
      voice?.disconnect();
      voice = stream ? context.createMediaStreamSource(stream) : null;
      voice?.connect(merger, 0, 1);
    },
    voiceFinished: () => sequence.voiceFinished(context.currentTime * 1000),
    handoff: () => sequence.handoff(),
  };
}
