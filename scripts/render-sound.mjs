// Renders the app's two sounds into app/Sources/LiveBridge/Resources/audio, synthesized here from
// damped sines, so they owe nothing to any other sound.
//
// The two are one story told from each end, and the three dots are Claude thinking:
//
// - handoff.wav, played when the app queues a request the voice handed off (BR-001): codex sends
//   (a soft lift), then Claude starts to think (three dots, fading).
// - chime.wav, played when an answer reaches the call and when a result waits with the line closed:
//   Claude has thought (the same three dots, growing), then Claude sends (a ringing note). Claude's
//   send is a different sound from codex's.
//
//   node scripts/render-sound.mjs
import { writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const RATE = 44100
const PEAK = 0.32

/** A damped sine of `f` Hz: 2 ms attack, decay constant `decay` s, an optional lift to `f * rise`
 *  over the first 30 ms, and an optional body two octaves down. */
function tap(seconds, f, decay, { rise = 1, body = 0 } = {}) {
  const out = new Float64Array(Math.round(seconds * RATE))
  let phase = 0
  for (let i = 0; i < out.length; i++) {
    const t = i / RATE
    phase += (2 * Math.PI * f * (1 + (rise - 1) * Math.min(1, t / 0.03))) / RATE
    const envelope = Math.min(1, t / 0.002) * Math.exp(-t / decay)
    out[i] = (Math.sin(phase) + body * Math.sin(phase / 4)) * envelope
  }
  return out
}

/** Sums `[samples, start seconds, gain]` tracks. */
function mix(tracks) {
  const end = Math.max(...tracks.map(([s, at]) => Math.round(at * RATE) + s.length))
  const out = new Float64Array(end)
  for (const [s, at, gain] of tracks) {
    const start = Math.round(at * RATE)
    s.forEach((v, i) => (out[start + i] += v * gain))
  }
  return out
}

const dot = (f, gain) =>
  mix([
    [tap(0.09, f, 0.016, { rise: 1.12, body: 0.25 }), 0, gain],
    [tap(0.07, f * 2.25, 0.008), 0, 0.18 * gain],
  ])
/** Three dots, 90 ms apart, from `at` seconds: Claude thinking. */
const thinking = (gains, at = 0) => gains.map((gain, k) => [dot(1046, gain), at + k * 0.09, 1])

/** Ends `sound` over 5 ms, for one whose tail would otherwise stop on a click. */
function fadedOut(sound) {
  const samples = Math.round(0.005 * RATE)
  for (let i = 0; i < samples; i++) sound[sound.length - 1 - i] *= i / samples
  return sound
}

/** Writes `sound`, scaled to `PEAK`, as a 16-bit mono WAV in the app's audio folder. */
function write(name, sound) {
  const top = Math.max(...sound.map(Math.abs))
  const data = Buffer.alloc(sound.length * 2)
  sound.forEach((v, i) => data.writeInt16LE(Math.round((v / top) * PEAK * 32767), i * 2))
  const header = Buffer.alloc(44)
  header.write('RIFF', 0)
  header.writeUInt32LE(36 + data.length, 4)
  header.write('WAVEfmt ', 8)
  header.writeUInt32LE(16, 16) // PCM chunk size
  header.writeUInt16LE(1, 20) // PCM
  header.writeUInt16LE(1, 22) // mono
  header.writeUInt32LE(RATE, 24)
  header.writeUInt32LE(RATE * 2, 28)
  header.writeUInt16LE(2, 32)
  header.writeUInt16LE(16, 34)
  header.write('data', 36)
  header.writeUInt32LE(data.length, 40)
  const file = fileURLToPath(
    new URL(`../app/Sources/LiveBridge/Resources/audio/${name}.wav`, import.meta.url),
  )
  writeFileSync(file, Buffer.concat([header, data]))
  console.log(`rendered ${file}`)
}

write(
  'handoff',
  mix([
    [tap(0.16, 620, 0.032, { rise: 1.5, body: 0.3 }), 0, 1],
    [tap(0.12, 1396, 0.02), 0.06, 0.35],
    ...thinking([0.5, 0.42, 0.34], 0.2),
  ]),
)
write(
  'chime',
  fadedOut(mix([...thinking([0.34, 0.42, 0.5]), [tap(0.55, 1396, 0.1, { body: 0.25 }), 0.27, 1]])),
)
