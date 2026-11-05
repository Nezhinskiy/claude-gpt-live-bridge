// The audio side of a LiveBridge call, run in an invisible WKWebView. The app calls `LB.*` and
// awaits the returned promises; the page posts `speechStarted`, `speechEnded`, `level`,
// `microphoneDenied` (the app has the sentence) and `audioFailed` to
// `window.webkit.messageHandlers.bridge`.
//
// The microphone runs through one 1024-sample processor. While the line is closed it feeds the
// voice detector and the pre-roll; from the first word (or `makeOffer`) on, the pre-roll and
// everything said while codex starts and the line connects queue up, and from `flushPreroll`
// the queue plays into the peer's track, dropping silence until it has caught up (ADR 0001 (c)).
// A timer or a promise outlives neither its peer nor its microphone: each checks it is still
// the current one before it reports anything.

import { createVad, dbfs, rms } from './vad.js';
import { createCatchUp, createPreroll } from './preroll.js';
import { within } from './deadline.js';

const FRAME = 1024;
/** A microphone request still pending after this fails, so the call never listens to nothing. */
const MIC_DEADLINE_MS = 10000;
const say = {
  micTimeout:
    'The microphone did not start within 10 seconds. Check System Settings > Privacy & Security > Microphone, then start again.',
  noDevice: 'No microphone is connected.',
  busy: 'The microphone could not be opened; another app may be using it.',
  lost: 'The microphone stopped and no other input was found.',
  localNetwork:
    'The voice line could not reach the network. Allow LiveBridge in System Settings > Privacy & Security > Local Network, then start again.',
  timeout: 'The voice line did not open in time.',
};

const post = (message) => window.webkit.messageHandlers.bridge.postMessage(message);

let ctx = null;
let pump, input, stream, vad, preroll, catchUp;
let pc = null;
let channel = null;
let remote = null;
let out = null; // the peer's outgoing track
let holding = false; // a connect is under way: frames queue instead of filling the pre-roll
let sending = false; // the line is open: the queue plays into the peer's track
let frames = 0;

function fail(reason) {
  post({ type: 'audioFailed', reason });
  return new Error(reason);
}

function process(event) {
  const frame = new Float32Array(event.inputBuffer.getChannelData(0));
  const level = rms(frame);
  const decision = vad.push(level, ctx.currentTime * 1000);
  if (decision === 'start') hold();
  if (decision) post({ type: decision === 'start' ? 'speechStarted' : 'speechEnded' });
  if (holding) catchUp.push(frame);
  else preroll.write(frame);
  const output = event.outputBuffer.getChannelData(0);
  output.fill(0);
  if (!sending) return;
  const next = catchUp.pull();
  if (next) output.set(next);
  if (++frames % 4 === 0) post({ type: 'level', value: Math.min(1, Math.max(0, (dbfs(level) + 60) / 50)) });
}

/** From the first word on, the pre-roll and what follows queue for the line; `keep` false drops
 * the pre-roll, for a line nobody spoke on. */
function hold(keep = true) {
  if (holding) return;
  holding = true;
  const kept = preroll.drain();
  if (!keep) return;
  for (let i = kept.length % FRAME; i < kept.length; i += FRAME) catchUp.push(kept.subarray(i, i + FRAME));
}

/** Connects the default input, or the debug WAV, to the processor; false when the microphone
 * was stopped meanwhile. */
async function attachInput(fake) {
  const mine = ctx;
  let node;
  if (fake) {
    const data = await (await fetch('fake-mic.wav')).arrayBuffer();
    if (ctx !== mine) return false;
    node = ctx.createBufferSource();
    node.buffer = await ctx.decodeAudioData(data);
    if (ctx !== mine) return false;
    node.start();
  } else {
    const asked = navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
    const next = await within(asked, MIC_DEADLINE_MS, micLate, (late) =>
      late.getTracks().forEach((track) => track.stop()),
    );
    if (ctx !== mine) {
      next.getTracks().forEach((track) => track.stop());
      return false;
    }
    stream?.getTracks().forEach((track) => track.stop());
    stream = next;
    stream.getAudioTracks()[0].onended = reacquire;
    node = ctx.createMediaStreamSource(stream);
  }
  input?.disconnect();
  input = node;
  input.connect(pump);
  return true;
}

function micLate() {
  const error = new Error(say.micTimeout);
  error.name = 'MicTimeoutError';
  return error;
}

/** The input device changed or went away: take the new default and keep the peer. */
function reacquire() {
  const mine = ctx;
  if (ctx) attachInput(false).catch(() => ctx === mine && fail(say.lost));
}

async function listen(fake) {
  if (ctx) return;
  const mine = (ctx = new AudioContext({ sampleRate: 48000 }));
  vad = createVad();
  preroll = createPreroll({ sampleRate: ctx.sampleRate });
  catchUp = createCatchUp({ sampleRate: ctx.sampleRate });
  pump = ctx.createScriptProcessor(FRAME, 1, 1);
  pump.onaudioprocess = process;
  const mute = ctx.createGain();
  mute.gain.value = 0;
  pump.connect(mute).connect(ctx.destination);
  try {
    if (!(await attachInput(fake))) return;
    await ctx.resume();
  } catch (error) {
    if (ctx !== mine) return;
    stop();
    if (error?.name === 'NotAllowedError') return post({ type: 'microphoneDenied' });
    const reasons = { NotFoundError: say.noDevice, MicTimeoutError: say.micTimeout };
    fail(reasons[error?.name] ?? say.busy);
    return;
  }
  if (ctx === mine && !fake) navigator.mediaDevices.ondevicechange = reacquire;
}

function stop() {
  closePeer();
  if (navigator.mediaDevices) navigator.mediaDevices.ondevicechange = null;
  stream?.getTracks().forEach((track) => track.stop());
  ctx?.close();
  ctx = stream = input = null;
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
  hold(keepPreroll);
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
    channel.onmessage = (event) => {
      if (event.data.includes('"session.started"')) resolve();
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
  holding = sending = false;
  catchUp?.clear();
  dropPeer();
}

function dropPeer() {
  channel?.close();
  pc?.close();
  remote?.pause();
  if (out) pump.disconnect(out);
  pc = channel = remote = out = null;
}

window.LB = { listen, stop, makeOffer, applyAnswer, flushPreroll, closePeer };
