// The audio side of a LiveBridge call, run in a hidden WKWebView. The app calls `LB.*` and
// awaits the returned promises; the page posts `speechStarted`, `speechEnded`, `level` and
// `audioFailed` to `window.webkit.messageHandlers.bridge`.
//
// The microphone runs through one 1024-sample processor. While the line is closed it feeds the
// voice detector and the pre-roll; from `makeOffer` on, the pre-roll and everything said while
// connecting queue up, and from `flushPreroll` the queue plays into the peer's track, dropping
// silence until it has caught up (ADR 0001 (c)).

import { createVad, dbfs } from './vad.js';
import { createCatchUp, createPreroll } from './preroll.js';

const FRAME = 1024;
const say = {
  denied:
    'LiveBridge cannot use the microphone. Allow it in System Settings > Privacy & Security > Microphone.',
  noDevice: 'No microphone is connected.',
  lost: 'The microphone stopped and no other input was found.',
  localNetwork:
    'The voice line could not reach the network. Allow LiveBridge in System Settings > Privacy & Security > Local Network, then start again.',
  timeout: 'The voice line did not open in time.',
};

const post = (message) => window.webkit.messageHandlers.bridge.postMessage(message);
const rms = (f32) => Math.sqrt(f32.reduce((sum, x) => sum + x * x, 0) / f32.length);

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

/** Connects the default input, or the debug WAV, to the processor. */
async function attachInput(fake) {
  let node;
  if (fake) {
    const data = await (await fetch('fake-mic.wav')).arrayBuffer();
    node = ctx.createBufferSource();
    node.buffer = await ctx.decodeAudioData(data);
    node.start();
  } else {
    const next = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
    stream?.getTracks().forEach((track) => track.stop());
    stream = next;
    stream.getAudioTracks()[0].onended = reacquire;
    node = ctx.createMediaStreamSource(stream);
  }
  input?.disconnect();
  input = node;
  input.connect(pump);
}

/** The input device changed or went away: take the new default and keep the peer. */
function reacquire() {
  if (ctx) attachInput(false).catch(() => fail(say.lost));
}

async function listen(fake) {
  if (ctx) return;
  ctx = new AudioContext({ sampleRate: 48000 });
  vad = createVad();
  preroll = createPreroll({ sampleRate: ctx.sampleRate });
  catchUp = createCatchUp({ sampleRate: ctx.sampleRate });
  pump = ctx.createScriptProcessor(FRAME, 1, 1);
  pump.onaudioprocess = process;
  const mute = ctx.createGain();
  mute.gain.value = 0;
  pump.connect(mute).connect(ctx.destination);
  try {
    await attachInput(fake);
    await ctx.resume();
  } catch (error) {
    stop();
    fail(error?.name === 'NotFoundError' ? say.noDevice : say.denied);
    return;
  }
  if (!fake) navigator.mediaDevices.ondevicechange = reacquire;
}

function stop() {
  closePeer();
  if (navigator.mediaDevices) navigator.mediaDevices.ondevicechange = null;
  stream?.getTracks().forEach((track) => track.stop());
  ctx?.close();
  ctx = stream = input = null;
}

/** Resolves once ICE gathering is done; no candidate within 2 s means Local Network is blocked
 * (ADR 0001 (a)). */
function gathered(peer) {
  return new Promise((resolve, reject) => {
    let candidates = 0;
    const settle = () => (candidates ? resolve() : reject(fail(say.localNetwork)));
    const timer = setTimeout(settle, 2000);
    peer.onicecandidate = (event) => {
      if (event.candidate) return candidates++;
      clearTimeout(timer);
      settle();
    };
  });
}

async function makeOffer() {
  closePeer();
  holding = true;
  const kept = preroll.drain();
  for (let i = kept.length % FRAME; i < kept.length; i += FRAME) catchUp.push(kept.subarray(i, i + FRAME));
  out = ctx.createMediaStreamDestination();
  pump.connect(out);
  pc = new RTCPeerConnection();
  pc.addTrack(out.stream.getAudioTracks()[0], out.stream);
  pc.ontrack = (event) => {
    remote = new Audio();
    remote.srcObject = event.streams[0] ?? new MediaStream([event.track]);
    remote.play().catch(() => {});
  };
  channel = pc.createDataChannel('oai-events');
  const ice = gathered(pc);
  await pc.setLocalDescription(await pc.createOffer());
  await ice;
  return pc.localDescription.sdp;
}

/** Applies the answer and resolves at the data channel's `session.started` (ADR 0001 (d)). */
async function applyAnswer(sdp) {
  const ready = new Promise((resolve, reject) => {
    channel.onmessage = (event) => {
      if (event.data.includes('"session.started"')) resolve();
    };
    setTimeout(() => reject(new Error(say.timeout)), 10000);
  });
  await pc.setRemoteDescription({ type: 'answer', sdp });
  await ready;
}

function flushPreroll() {
  sending = true;
}

function closePeer() {
  holding = sending = false;
  catchUp?.clear();
  channel?.close();
  pc?.close();
  remote?.pause();
  if (out) pump.disconnect(out);
  pc = channel = remote = out = null;
}

window.LB = { listen, stop, makeOffer, applyAnswer, flushPreroll, closePeer };
