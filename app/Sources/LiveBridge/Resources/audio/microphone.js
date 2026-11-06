// The owner's microphone: the one place the audio page acquires and releases it, so that Mute
// holds. Every acquisition (Start's, a device change's, a track that ended, Unmute's) goes
// through `attach`, which acquires nothing while muted, and one generation token decides whether
// what an acquisition got may be kept: `mute` and `release` move it, so an acquisition pending
// when they land ends released and reports nothing. Pure: the page passes in what touches the
// devices.

/**
 * `acquire(isCurrent)` resolves to a capture `{ node, stop(), onEnded(handler | null) }`, or to
 * null when `isCurrent()` turned false meanwhile (it then holds nothing). `connect` and
 * `disconnect` wire a capture's node to the processor; `watchDevices(handler | null)` installs
 * or removes the device-change handler; `onLost(error)` hears a device change that found no
 * microphone.
 */
export function createMicrophone({ acquire, connect, disconnect, watchDevices, onLost }) {
  let token = 0;
  let muted = false;
  let current = null;

  function drop() {
    if (!current) return;
    current.onEnded(null);
    current.stop();
    disconnect(current.node);
    current = null;
  }

  /** Mute and Stop: the token moves first, so an acquisition pending now keeps nothing. */
  function letGo(stayMuted) {
    token++;
    muted = stayMuted;
    drop();
    watchDevices(null);
  }

  /** Takes the default input; false, holding nothing, when muted or muted meanwhile. */
  async function attach() {
    if (muted) return false;
    const mine = token;
    const isCurrent = () => token === mine;
    let next;
    try {
      next = await acquire(isCurrent);
    } catch (error) {
      if (isCurrent()) throw error;
      return false;
    }
    if (!next || !isCurrent()) {
      next?.stop();
      return false;
    }
    drop();
    current = next;
    next.onEnded(deviceChanged);
    connect(next.node);
    watchDevices(deviceChanged);
    return true;
  }

  /** The input device changed or went away: take the new default. */
  function deviceChanged() {
    attach().catch(onLost);
  }

  return {
    attach,
    mute() {
      if (!muted) letGo(true);
    },
    async unmute() {
      if (!muted) return true;
      muted = false;
      return attach();
    },
    deviceChanged,
    /** Stop: the microphone goes, and the mute with it. */
    release() {
      letGo(false);
    },
    get muted() {
      return muted;
    },
  };
}

/** A microphone request still pending after this fails, so the call never listens to nothing. */
export const MIC_DEADLINE_MS = 10000;

const sentence = {
  NotFoundError: 'No microphone is connected.',
  MicTimeoutError: `The microphone did not start within ${MIC_DEADLINE_MS / 1000} seconds. Check System Settings > Privacy & Security > Microphone, then start again.`,
};
const busy = 'The microphone could not be opened; another app may be using it.';

/** What the page posts when the microphone could not be taken. */
export function microphoneFailure(error) {
  if (error?.name === 'NotAllowedError') return { type: 'microphoneDenied' };
  return { type: 'audioFailed', reason: Object.hasOwn(sentence, error?.name ?? '') ? sentence[error.name] : busy };
}
