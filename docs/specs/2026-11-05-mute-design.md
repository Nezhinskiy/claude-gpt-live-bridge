# Mute

Status: delivered, 2026-11-05; revised the same day after the review
(`docs/reviews/2026-11-05-mute-review.md` on branch `review/mute`).

## Why

Stop ends the call: Claude's answers then only chime, and the voice cannot say them. The owner
wants to stop being heard for a while (a phone call, a colleague at the desk) while the call goes
on, so an answer from Claude still opens the line and is said.

## What the owner sees

- While the call is on, the band above the prompt and the menu's call card show **Mute** beside
  **Stop**; while muted, **Unmute**. The phase stays what it is (Listening, Connecting, Live, in
  its colour) with a muted marker beside it, for example `Live · muted`. Muted and listening, the
  menu's card says the line opens when Claude answers, and waiting results ask the owner to
  unmute and speak.
- Muted, LiveBridge holds no microphone, and macOS's microphone indicator shows it.
- What was said before Mute: on a line already opening or open for it (the audio page holds a
  peer), speech already said when the owner presses Mute still reaches the voice; nothing after
  it does. With no peer, Mute drops what the page kept (the 2 s pre-roll, and a speech start the
  muted call ignores), so an Unmute soon after never sends audio from before Mute. In the moment
  between the owner's first word and the page's peer (while codex starts), Mute drops those words
  too, and the line opens empty.
- The call goes on: an answer, question or approval notice from the target still opens the closed
  line and the voice says it (as since 0.3.0). A result held while the owner was speaking is said
  after the usual grace. A line that is open when the owner mutes closes as it would
  without Mute.
- **Unmute** takes the microphone again and waits for it, as Start does, up to the page's 10 s
  microphone deadline; until it is back, the menu, and the band that pressed it, may still show
  Muted. Speech then opens the line as before. A failed Unmute ends the call with its reason.
- **Stop** ends the call and the mute with it; the next **Start** begins unmuted.

## Decisions

- **Only the microphone.** Muting does not silence the voice: answers are still said, which is the
  point. Silence is what Stop is for. (The owner chose this over a do-not-disturb mode.)
- **The microphone is released, not ignored.** The capture's tracks stop. Unmute captures again
  with no permission prompt (the grant stands); the first fraction of a second after Unmute may
  be lost.
- **What enforces it.** One rule in the audio page, where the microphone is acquired (below). The
  macOS indicator is how the owner sees it: off means LiveBridge captures nothing. The Muted label
  alone proves nothing. No native check backs the page: the media-capture delegate grants every
  microphone request from the page's own main frame, muted or not (a deny there while muted was
  considered and not taken; the plan's review rulings say why).
- **Not a control against local processes.** Mute protects against being heard by accident. Any
  process running as the owner can unmute through the socket, as it can start a call
  ([SECURITY.md](../../SECURITY.md)).
- **Two explicit actions, not a toggle.** `mute` and `unmute` are separate and idempotent, so the
  band and the menu pressing at once cannot undo each other.
- **Where.** The band and the menu's call card. No global hotkey for now.

## Design

### Wire

- `CallAction` gains `mute` and `unmute` (`POST /v1/call`, as Start and Stop). A new fixture
  `call-mute.json`.
- `StatusReply` gains `isMuted`. The app always sends it: `public var isMuted = false` with the
  synthesized `Codable`, since the app is the only producer and never decodes a status it did not
  write. The mod types it optional (`isMuted?: boolean`): absent means an app without Mute.
  `next-reply.json` carries `true`, the other `next-*` fixtures `false`.
- `Wire.swift`, `plugin/hooks/wire.ts` and `wire/fixtures/` change together.

### App

- `CallMachine` keeps `isMuted`, orthogonal to the phase. `.mute` while the call is on and
  unmuted sets it and returns `.muteMicrophone` followed by what `.speechEnded` returns: speech
  ends at Mute, so on a live line the silence timer re-arms at 20 s, and a result held while the
  owner spoke gets its grace. `.unmute` while muted clears it and returns `.unmuteMicrophone`. A
  second Mute or Unmute does nothing, and both do nothing while the call is off. `.speechStarted`
  while muted is ignored in every phase. Stop and an audio failure reset the machine, the mute
  with it.
- `Bridge` performs the two actions as call events, runs the two effects on `AudioSide`'s
  `muteMicrophone()` and `unmuteMicrophone()`, and its status carries `isMuted`.
- `AudioHost`: `muteMicrophone()` calls `LB.mute()`; `unmuteMicrophone()` calls `LB.unmute()` and,
  when the page cannot be reached, reports a failure as `startListening()` does.
- `StatusPresentation` knows `isMuted`, and derives the second action (`mute`, or `unmute` while
  muted; none while off) where it derives Start/Stop. Muted and listening, the headline is
  "Muted — line closed" and the detail "The line opens when Claude answers you."; connecting and
  live keep their headline with " · muted" after it. The card's unheard line while muted reads
  "N unheard — unmute and speak to hear". The menu row draws the second button beside Start/Stop.

### The audio page

- **One rule where the microphone is acquired.** A new pure module, `microphone.js`, owns the
  capture and one generation token. Every capture goes through its `attach`: `listen`'s first,
  a device change or a track that ended, and Unmute. `attach` acquires nothing while muted. After
  each await it checks the token, and if the token moved it releases what it got and reports
  nothing. `mute()` bumps the token first, so an acquisition already pending (Start's, Unmute's,
  a device change's) ends released. Then it stops the tracks, disconnects the input, and removes
  the device-change and track-ended handlers. A mute that comes before `listen` is recorded, and
  `listen` then starts muted. Stop releases the microphone and resets the mute.
- `audio.js` keeps `fake` (the `--fake-mic` flag) in module state, so Unmute and device changes
  use the WAV in a debug run. `LB.mute()` mutes the microphone, gives the voice detector a fresh
  start, and with no peer resets the line's audio: pre-roll emptied, nothing held or queued. It
  posts one `level` 0. While muted, the processor skips detection and the pre-roll: it outputs
  silence and still plays the held queue into an open line. The `AudioContext` keeps running,
  because a result can open a line while muted. `LB.unmute()` unmutes the microphone. A failure
  goes through `failMicrophone`, which `listen` shares: a refusal posts `microphoneDenied`, any
  other failure `audioFailed` with its sentence.

### Mod

- `bandStatus` carries `isMuted` when the status has it. `drawBand` draws **Mute** / **Unmute**
  beside **Stop** only when the call is on and the status carries `isMuted`. It keeps the phase
  label and its colour, and while muted adds a `· muted` marker beside it. `BandActions` gains
  `mute` and `unmute`, which post `link.call('mute' | 'unmute')`.

## Failures

- **Unmute cannot take the microphone** (the permission was revoked while muted, another app holds
  it, the device went away): the page reports it as at Start, `microphoneDenied` or `audioFailed`
  with its sentence. The call then ends with that reason, as `.audioFailed` ends it; Start again.
- **The audio page cannot be reached at Unmute:** `AudioHost` reports it as at Start; the call
  ends.
- **An older mod with a newer app:** it shows only Start/Stop; the menu still mutes.
- **A newer mod with an older app:** the status has no `isMuted`, so the band draws no Mute. The
  older app would refuse `mute` with a 400, which `link.call` does not show.
- **A local process unmutes:** possible, as above; Mute is not a control against it.

## Testing

- BridgeCore: `CallMachine` rows for Mute and Unmute in each phase, a repeated Mute or Unmute,
  speech ignored while muted (listening and live), a result opening the line while muted, Mute on
  a live line re-arming 20 s and giving a held result its grace, Mute while connecting then
  connected arming 20 s. `Bridge`: `/v1/call` mute and unmute reach the audio side and the
  status; mute, stop, start listens unmuted. The presentation and the menu outline show
  Mute/Unmute and the muted strings.
- `AudioJSTests`: `microphone.test.mjs` drives the module with a deferred acquisition: an
  acquisition pending at Mute leaves no live capture (from Start, from Unmute, from a device
  change); a device change while muted acquires nothing; a mute before the first attach is kept;
  release clears the mute; a failed Unmute rejects with its error; the failure mapping.
  `preroll.test.mjs`: nothing recorded before a reset reaches the line.
- Mod: the band draws Mute/Unmute and the muted marker from `isMuted`, keeps the phase, and its
  buttons post the actions; a status without `isMuted` draws no Mute.
- Wire: `call-mute.json` and a muted status round-trip on both sides.
- By hand: the microphone indicator goes off on Mute and comes back on Unmute; Start then Mute at
  once keeps it off; while muted, plugging or unplugging a headset keeps it off.
