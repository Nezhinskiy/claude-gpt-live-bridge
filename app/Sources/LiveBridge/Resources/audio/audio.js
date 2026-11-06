// The audio side of a LiveBridge call, run in an invisible WKWebView. The app calls `LB.*` and
// awaits the returned promises; the page posts `speechStarted`, `speechEnded`, `level`,
// `microphoneDenied` (the app has the sentence), `audioFailed` and `lineError` to
// `window.webkit.messageHandlers.bridge`.
//
// The microphone runs through one 1024-sample processor. While the line is closed it feeds the
// voice detector and the pre-roll; from the first word (or `makeOffer`) on, the pre-roll and
// everything said while codex starts and the line connects queue up, and from `flushPreroll`
// the queue plays into the peer's track, dropping silence until it has caught up (ADR 0001 (c)).
// A timer or a promise outlives neither its peer nor its microphone: each checks it is still
// the current one before it reports anything. `microphone.js` owns the capture: Mute releases
// it while the call goes on, so a result can still open the line and be said.

import { createVad, dbfs, rms } from './vad.js';
import { createLineAudio } from './preroll.js';
import { within } from './deadline.js';
import { lineError } from './events.js';
import { MIC_DEADLINE_MS, createMicrophone, microphoneFailure } from './microphone.js';

const FRAME = 1024;
const say = {
  lost: 'The microphone stopped and no other input was found.',
  localNetwork:
    'The voice line could not reach the network. Allow LiveBridge in System Settings > Privacy & Security > Local Network, then start again.',
  timeout: 'The voice line did not open in time.',
};

const post = (message) => window.webkit.messageHandlers.bridge.postMessage(message);

let ctx = null;
let fake = false; // the debug WAV stands in for the microphone (`--fake-mic`)
let pump, vad, line;
let pc = null;
let channel = null;
let remote = null;
let out = null; // the peer's outgoing track
let sending = false; // the line is open: the queue plays into the peer's track
let frames = 0;

function fail(reason) {
  post({ type: 'audioFailed', reason });
  return new Error(reason);
}

function process(event) {
  const output = event.outputBuffer.getChannelData(0);
  output.fill(0);
  if (mic.muted) {
    // No detection and no pre-roll: what is already held still plays into an open line.
    if (sending) play(output);
    return;
  }
  const frame = new Float32Array(event.inputBuffer.getChannelData(0));
  const level = rms(frame);
  const decision = vad.push(level, ctx.currentTime * 1000);
  if (decision === 'start') line.hold();
  if (decision) post({ type: decision === 'start' ? 'speechStarted' : 'speechEnded' });
  line.write(frame);
  if (!sending) return;
  play(output);
  if (++frames % 4 === 0) post({ type: 'level', value: Math.min(1, Math.max(0, (dbfs(level) + 60) / 50)) });
}

function play(output) {
  const next = line.pull();
  if (next) output.set(next);
}

const stopTracks = (stream) => stream.getTracks().forEach((track) => track.stop());

/** The default input, or the debug WAV, as a capture of the context it started with; null when
 * the microphone was muted or stopped meanwhile, or before `listen`. */
async function acquire(isCurrent) {
  const context = ctx;
  if (!context) return null;
  if (fake) {
    const data = await (await fetch('fake-mic.wav')).arrayBuffer();
    if (!isCurrent()) return null;
    const node = context.createBufferSource();
    node.buffer = await context.decodeAudioData(data);
    if (!isCurrent()) return null;
    node.start();
    return { node, stop: () => node.stop(), onEnded: () => {} };
  }
  const asked = navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
  });
  const stream = await within(asked, MIC_DEADLINE_MS, micLate, stopTracks);
  if (!isCurrent()) {
    stopTracks(stream);
    return null;
  }
  let node;
  try {
    node = context.createMediaStreamSource(stream);
  } catch (error) {
    stopTracks(stream); // not yet a capture, so nothing else would stop it
    throw error;
  }
  const track = stream.getAudioTracks()[0];
  return { node, stop: () => stopTracks(stream), onEnded: (handler) => (track.onended = handler) };
}

/** Named only: `microphoneFailure` says it by its name. */
function micLate() {
  return Object.assign(new Error(), { name: 'MicTimeoutError' });
}

const mic = createMicrophone({
  acquire,
  connect: (node) => node.connect(pump),
  disconnect: (node) => node.disconnect(),
  watchDevices(handler) {
    if (!fake && navigator.mediaDevices) navigator.mediaDevices.ondevicechange = handler;
  },
  onLost: () => fail(say.lost),
});

/** The microphone could not be taken: the call ends with the reason. */
function failMicrophone(error) {
  stop();
  post(microphoneFailure(error));
}

async function listen(wav) {
  if (ctx) return;
  const mine = (ctx = new AudioContext({ sampleRate: 48000 }));
  fake = wav;
  vad = createVad();
  line = createLineAudio({ sampleRate: ctx.sampleRate, frame: FRAME });
  pump = ctx.createScriptProcessor(FRAME, 1, 1);
  pump.onaudioprocess = process;
  const silent = ctx.createGain();
  silent.gain.value = 0;
  pump.connect(silent).connect(ctx.destination);
  try {
    // False when muted: the context still runs, so a result can open the line.
    await mic.attach();
    if (ctx !== mine) return;
    await ctx.resume();
  } catch (error) {
    if (ctx === mine) failMicrophone(error);
  }
}

/** Releases the microphone; the call, and an open line, go on. */
function mute() {
  if (mic.muted) return; // a second Mute changes nothing, and posts nothing
  mic.mute();
  if (!ctx) return;
  vad = createVad();
  if (!pc) line.reset();
  post({ type: 'level', value: 0 });
}

/** Resolves, to nothing on every path, once the microphone is back or its failure was posted. */
async function unmute() {
  await mic.unmute().catch(failMicrophone);
}

function stop() {
  closePeer();
  mic.release();
  ctx?.close();
  ctx = null;
  fake = false;
}

/** Resolves once ICE gathering is done, with whether any candidate came; none within 2 s
 * means Local Network is blocked (ADR 0001 (a)). */
function gathered(peer) {
  return new Promise((resolve) => {
    let candidates = 0;
    const timer = setTimeout(() => resolve(candidates > 0), 2000);
    peer.onicecandidate = (event) => {
      if (event.candidate) return candidates++;
      clearTimeout(timer);
      resolve(candidates > 0);
    };
  });
}

const closed = () => new Error('The voice line was closed.');

async function makeOffer(keepPreroll = true) {
  dropPeer();
  line.hold(keepPreroll);
  out = ctx.createMediaStreamDestination();
  pump.connect(out);
  const peer = (pc = new RTCPeerConnection());
  peer.addTrack(out.stream.getAudioTracks()[0], out.stream);
  peer.ontrack = (event) => {
    if (peer !== pc) return;
    remote = new Audio();
    remote.srcObject = event.streams[0] ?? new MediaStream([event.track]);
    remote.play().catch(() => {});
  };
  channel = peer.createDataChannel('oai-events');
  const ice = gathered(peer);
  await peer.setLocalDescription(await peer.createOffer());
  const reached = await ice;
  if (peer !== pc) throw closed();
  if (!reached) throw fail(say.localNetwork);
  return peer.localDescription.sdp;
}

/** Applies the answer and resolves at the data channel's `session.started` (ADR 0001 (d)). */
async function applyAnswer(sdp) {
  const peer = pc;
  if (!peer) throw closed();
  let timer;
  const ready = new Promise((resolve, reject) => {
    // kept for the line's whole life: the service's usage gate speaks only on this channel
    channel.onmessage = (event) => {
      if (event.data.includes('"session.started"')) resolve();
      const message = peer === pc ? lineError(event.data) : null;
      if (message) post({ type: 'lineError', message });
    };
    timer = setTimeout(() => reject(peer === pc ? new Error(say.timeout) : closed()), 10000);
  });
  try {
    await peer.setRemoteDescription({ type: 'answer', sdp });
    await ready;
  } finally {
    clearTimeout(timer);
  }
}

function flushPreroll() {
  sending = true;
}

/** Ends the line: the peer, and the queue held for it. */
function closePeer() {
  sending = false;
  line?.clear();
  dropPeer();
}

function dropPeer() {
  channel?.close();
  pc?.close();
  remote?.pause();
  if (out) pump.disconnect(out);
  pc = channel = remote = out = null;
}

window.LB = { listen, stop, mute, unmute, makeOffer, applyAnswer, flushPreroll, closePeer };
