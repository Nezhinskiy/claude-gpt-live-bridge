# Mute

Status: proposed, 2026-11-05.

## Why

Stop ends the call: Claude's answers then only chime, and the voice cannot say them. The owner
wants to stop being heard for a while (a phone call, a colleague at the desk) while the call goes
on, so an answer from Claude still opens the line and is said.

## What the owner sees

- While the call is on, the band above the prompt and the menu's call card show **Mute** beside
  **Stop**; while muted, **Unmute**, and the band's phase reads **Muted**.
- Muted, LiveBridge releases the microphone: macOS's microphone indicator goes off. The owner's
  speech does not open the line and does not reach the voice.
- The call goes on: an answer, question or approval notice from the target still opens the closed
  line and the voice says it (as since 0.3.0). A line that is open when the owner mutes stays open
  until the usual silence rule closes it.
- **Unmute** takes the microphone again; speech opens the line as before. **Stop** ends the call
  and the mute with it; the next **Start** begins unmuted.

## Decisions

- **Only the microphone.** Muting does not silence the voice: answers are still said, which is the
  point. Silence is what Stop is for. (The owner chose this over a do-not-disturb mode.)
- **The microphone is released, not ignored.** The capture's tracks stop, so the indicator is the
  proof that nobody listens. Unmute captures again, with no permission prompt (the grant stands);
  the first fraction of a second after Unmute may be lost.
- **Where.** The band and the menu's call card. No global hotkey for now.

## Design

### Wire

- `CallAction` gains `mute` and `unmute` (`POST /v1/call`, as Start and Stop). A new fixture
  `call-mute.json`.
- `StatusReply` gains `isMuted`, sent by the app always; a mod reads it as false when absent (an
  older app). `Wire.swift`, `plugin/hooks/wire.ts` and `wire/fixtures/` change together.

### App

- `CallMachine` keeps `isMuted`. `.mute` while the call is on sets it, clears `isSoundOn` (re-arming
  the silence timer on a live line, so a line the owner was speaking on closes as usual) and
  emits `.muteMicrophone`; `.unmute` clears it and emits `.unmuteMicrophone`. Both are ignored
  while the call is off. `.speechStarted` while muted is ignored. Stop resets the machine, mute
  included; the audio side's stop releases the microphone anyway.
- `AudioSide` gains `muteMicrophone()` and `unmuteMicrophone()`; `AudioHost` calls `LB.mute()` and
  `LB.unmute()`.
- `audio.js`: `mute()` stops the stream's tracks and detaches the input from the processor,
  keeping the `AudioContext`, the processor and any peer; it empties the pre-roll and ends any
  speech in progress. `unmute()` runs the existing `attachInput`. The track-ended and
  device-change handlers, which re-acquire the microphone today, do nothing while muted.
- `Bridge.status` carries `isMuted`; `StatusPresentation` and `CallCard` add the second action
  (`mute` or `unmute`) while the call is on; the menu row renders it beside Start/Stop.

### Mod

- `bandStatus` carries `isMuted`; `drawBand` draws **Mute** / **Unmute** beside **Stop** while the
  call is on, and the phase label **Muted** while muted. `BandActions` gains `mute` and `unmute`,
  which post `link.call('mute' | 'unmute')`.

## Failures

- **Unmute cannot take the microphone** (another app holds it exclusively, the device went
  away): the existing `microphoneDenied` / `audioFailed` paths report it, as at Start.
- **An older mod with a newer app:** it shows only Start/Stop; the menu still mutes.

## Testing

- BridgeCore: `CallMachine` rows for mute and unmute in each phase, speech ignored while muted, a
  result opening the line while muted, Stop clearing the mute; `Bridge` posts `/v1/call` mute and
  the audio side gets `muteMicrophone`; `StatusPresentation`/menu outline show Mute/Unmute.
- `AudioJSTests`: `mute()` stops the tracks and empties the pre-roll; the track-ended handler does
  not re-acquire while muted; `unmute()` attaches a new input.
- Mod: the band draws Mute/Unmute and Muted from `isMuted`, and its buttons post the actions;
  a status without `isMuted` reads as unmuted.
- Wire: `call-mute.json` and a status with `isMuted` round-trip on both sides.
- By hand: the microphone indicator goes off on Mute and comes back on Unmute.
