import assert from 'node:assert/strict';
import { test } from 'node:test';
import { MIC_DEADLINE_MS, createMicrophone, microphoneFailure } from '../../Sources/LiveBridge/Resources/audio/microphone.js';

/** A capture that records whether it was stopped, connected and what its ended handler is. */
function capture() {
  const made = {
    stopped: false,
    connected: false,
    everConnected: false,
    ended: null,
    stop() {
      made.stopped = true;
    },
    onEnded(handler) {
      made.ended = handler;
    },
  };
  made.node = { capture: made };
  return made;
}

/** A microphone whose acquisitions wait until the test settles them, oldest first. */
function rig() {
  const pending = [];
  const watched = [];
  const lost = [];
  const mic = createMicrophone({
    acquire(isCurrent) {
      return new Promise((resolve, reject) => pending.push({ isCurrent, resolve, reject }));
    },
    connect(node) {
      node.capture.connected = node.capture.everConnected = true;
    },
    disconnect(node) {
      node.capture.connected = false;
    },
    watchDevices: (handler) => watched.push(handler),
    onLost: (error) => lost.push(error),
  });
  /** Resolves the oldest acquisition with a new capture, and returns it. */
  const grant = () => {
    const got = capture();
    pending.shift().resolve(got);
    return got;
  };
  return { mic, pending, watched, lost, grant };
}

const settled = () => new Promise(setImmediate);
const namedError = (name) => Object.assign(new Error(name), { name });

test('muteReleasesTheCapture', async () => {
  const { mic, watched, grant } = rig();
  const attached = mic.attach();
  const got = grant();
  assert.equal(await attached, true);
  mic.mute();
  assert.equal(got.stopped, true);
  assert.equal(got.connected, false);
  assert.equal(got.ended, null);
  assert.equal(watched.at(-1), null);
  assert.equal(mic.muted, true);
});

test('anAcquisitionPendingAtMuteLeavesNoLiveCapture', async () => {
  const { mic, grant } = rig();
  const attached = mic.attach();
  mic.mute();
  const got = grant();
  assert.equal(await attached, false);
  assert.equal(got.stopped, true);
  assert.equal(got.everConnected, false);
});

test('unmuteThenMuteWhileAcquiringLeavesNoLiveCapture', async () => {
  const { mic, grant } = rig();
  mic.mute();
  const unmuted = mic.unmute();
  mic.mute();
  const got = grant();
  assert.equal(await unmuted, false);
  assert.equal(got.stopped, true);
  assert.equal(got.everConnected, false);
});

test('aDeviceChangePendingAtMuteLeavesNoLiveCapture', async () => {
  const { mic, pending, grant } = rig();
  const attached = mic.attach();
  const first = grant();
  await attached;
  mic.deviceChanged();
  assert.equal(pending.length, 1, 'the device change is acquiring');
  mic.mute();
  const second = grant();
  await settled();
  assert.equal(first.stopped, true);
  assert.equal(second.stopped, true);
  assert.equal(second.everConnected, false);
});

test('aDeviceChangeReplacesTheCapture', async () => {
  const { mic, grant } = rig();
  const attached = mic.attach();
  const first = grant();
  await attached;
  mic.deviceChanged();
  const second = grant();
  await settled();
  assert.equal(first.stopped, true);
  assert.equal(first.connected, false);
  assert.equal(second.connected, true);
});

test('aDeviceChangeThatFindsNoMicrophoneIsLost', async () => {
  const { mic, pending, lost, grant } = rig();
  const attached = mic.attach();
  grant();
  await attached;
  mic.deviceChanged();
  const missing = namedError('NotFoundError');
  pending.shift().reject(missing);
  await settled();
  assert.deepEqual(lost, [missing]);
});

test('aDeviceChangeWhileMutedAcquiresNothing', async () => {
  const { mic, pending } = rig();
  mic.mute();
  mic.deviceChanged();
  await settled();
  assert.equal(pending.length, 0);
});

test('aMuteBeforeTheFirstAttachIsKept', async () => {
  const { mic, pending } = rig();
  mic.mute();
  assert.equal(await mic.attach(), false);
  assert.equal(pending.length, 0);
});

test('releaseClearsTheMute', async () => {
  const { mic, watched, grant } = rig();
  mic.mute();
  mic.release();
  const attached = mic.attach();
  const got = grant();
  assert.equal(await attached, true);
  assert.equal(got.connected, true);
  assert.equal(typeof watched.at(-1), 'function');
});

test('anAcquisitionPendingAtReleaseLeavesNoLiveCapture', async () => {
  const { mic, grant } = rig();
  const attached = mic.attach();
  mic.release();
  const got = grant();
  assert.equal(await attached, false);
  assert.equal(got.stopped, true);
  assert.equal(got.everConnected, false);
});

test('aFailedUnmuteRejectsWithItsError', async () => {
  const { mic, pending } = rig();
  mic.mute();
  const unmuted = mic.unmute();
  const denied = namedError('NotAllowedError');
  pending.shift().reject(denied);
  await assert.rejects(unmuted, (error) => error === denied);
});

test('aFailureAfterMuteIsDropped', async () => {
  const { mic, pending, lost } = rig();
  const attached = mic.attach();
  mic.mute();
  pending.shift().reject(namedError('NotFoundError'));
  assert.equal(await attached, false);
  assert.equal(lost.length, 0);
});

test('unmuteWhileUnmutedAcquiresNothing', async () => {
  const { mic, pending } = rig();
  assert.equal(await mic.unmute(), true);
  assert.equal(pending.length, 0);
});

test('acquireIsToldWhenItTurnsStale', () => {
  const { mic, pending } = rig();
  mic.attach();
  const { isCurrent } = pending[0];
  assert.equal(isCurrent(), true);
  mic.mute();
  assert.equal(isCurrent(), false);
});

test('anAcquisitionThatGotNothingAttachesNothing', async () => {
  const { mic, pending, watched } = rig();
  const attached = mic.attach();
  pending.shift().resolve(null);
  assert.equal(await attached, false);
  assert.equal(watched.length, 0);
});

test('aRefusedMicrophoneIsReportedAsDenied', () => {
  assert.deepEqual(microphoneFailure(namedError('NotAllowedError')), { type: 'microphoneDenied' });
});

test('eachOtherCauseHasItsOwnSentence', () => {
  const failures = ['NotFoundError', 'MicTimeoutError', 'NotReadableError'].map((name) =>
    microphoneFailure(namedError(name)));
  assert.ok(failures.every((failure) => failure.type === 'audioFailed' && typeof failure.reason === 'string'));
  assert.equal(new Set(failures.map((failure) => failure.reason)).size, 3);
});

test('anUnknownFailureReadsAsABusyMicrophone', () => {
  assert.equal(microphoneFailure(undefined).reason, microphoneFailure(namedError('NotReadableError')).reason);
});

test('theTimeoutSentenceNamesTheDeadline', () => {
  const { reason } = microphoneFailure(namedError('MicTimeoutError'));
  assert.ok(reason.includes(` ${MIC_DEADLINE_MS / 1000} seconds`), reason);
});
