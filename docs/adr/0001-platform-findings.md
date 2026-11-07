# 0001. Platform findings: audio path, codex realtime, Claude Code mod API

## Context

LiveBridge is a macOS menu bar app (no Dock icon, `LSUIElement`) plus a Claude Code mod. The
app runs `codex app-server` on the user's ChatGPT login, opens an OpenAI realtime voice session
through it, and relays the voice model's handoffs to a Claude Code session through the mod.
Before any of that is built, a throwaway spike checked the platform facts the design rests on.
This record keeps what was measured, how, and what we decided from it. Items are lettered (a)
to (q) so later work can cite them.

Tested on: macOS 27.0.1 (Apple Silicon), Swift 6.4.2, `codex-cli 0.166.0` (realtime `v3`,
`outputModality: "audio"`, ChatGPT plan with realtime), Claude Code 2.1.309. The codex realtime
API is experimental and undocumented; any of this can change with a codex release.

Method:

- A minimal menu bar app (activation policy `.accessory`, `LSUIElement`, ad-hoc signed, started
  with `open`) kept one `WKWebView` in a window that is never shown. The page was served by a
  `WKURLSchemeHandler` under `livebridge-audio://app/`, and a small Swift JSON-RPC relay carried
  the page's requests to `codex app-server` over stdio and every codex line back to the page.
  Every message was logged with a millisecond timestamp.
- The microphone was replaced by WAV files made with `say -o` and played through WebAudio into a
  `MediaStreamAudioDestinationNode`, so the round trip was proven by events, not by ear: peer
  connection `connected`, a `handoff_request` item, assistant transcript events and inbound RTP
  bytes. Real `getUserMedia` was tried once with a short timeout.
- Each realtime session lasted 10 to 25 seconds and was stopped with `thread/realtime/stop`.
- Mod questions were probed with a 20-line scratch mod run by `claude -p --plugin-dir`, against
  a Unix-socket HTTP server, and read from the bundled `claude-code.d.ts` types. Turns that need
  the model could not run in that environment (the CLI's own login had expired and was not
  renewed), and an interactive terminal session stopped at a folder-trust dialog the spike did
  not accept. Each answer below says whether it was **observed**, **documented** in the types,
  or **inferred**.

Generated protocol (`codex app-server generate-ts --experimental`, 0.166.0), the methods the app
uses:

| Kind | Methods |
|---|---|
| Client requests | `initialize` (then the `initialized` notification), `account/read`, `config/read`, `thread/start`, `mcpServerStatus/list`, `thread/realtime/start`, `thread/realtime/stop`, `thread/realtime/appendText`, `thread/realtime/appendSpeech`, `thread/realtime/listVoices`, `turn/interrupt` |
| Server notifications the app reads | `thread/realtime/sdp`, `thread/realtime/itemAdded`, `thread/realtime/transcript/delta`, `thread/realtime/transcript/done`, `thread/realtime/error`, `thread/realtime/closed`, `turn/started`, `mcpServer/startupStatus/updated`; every other notification is ignored |
| Server requests (every one declined) | `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/permissions/requestApproval`, `execCommandApproval`, `applyPatchApproval`, `item/tool/call`, `item/tool/requestUserInput`, `mcpServer/elicitation/request`, `account/chatgptAuthTokens/refresh`, `attestation/generate`, `currentTime/read` |

The findings below also cite `thread/realtime/appendAudio`, which the spike tried and the app
does not use.

`thread/realtime/start` takes `threadId`, `outputModality`, and optionally `version`,
`transport` (`{type:"webrtc", sdp}`, `{type:"websocket"}` or `{type:"existingCall", callId}`),
`prompt`, `includeStartupContext`, `clientManagedHandoffs`, `delegationAckFiller`,
`initialItems` (`[{role: "user"|"developer"|"assistant", text}]`, V3 only, at most 128 items and
8,192 estimated tokens, an estimate of UTF-8 bytes over 4, and past either limit codex refuses the
start: see (o)), `voice`, `model` and several rollout knobs. In the WebRTC sessions
observed, `thread/realtime/item/*` and `outputAudio/delta` never arrived; everything came as
`itemAdded`, `transcript/*`, `sdp`, `started`, `error` and `closed`.

### Audio path

**(a) WebRTC from a hidden `WKWebView` in an `LSUIElement` app: yes, with two conditions; the
microphone grant is still pending.** Observed in 14 sessions.

- The custom-scheme page is a secure context: `isSecureContext`, `navigator.mediaDevices`,
  `getUserMedia`, `RTCPeerConnection` and `AudioWorkletNode` are all present.
- The page's offer (one audio track, data channel `oai-events`, ICE gathered before sending) goes
  to `thread/realtime/start`; the answer arrives in `thread/realtime/sdp` and is applied with
  `setRemoteDescription`. The peer connection reaches `connected`, the data channel opens, the
  remote track plays, inbound RTP bytes and audio energy rise. The answer is ICE-lite with UDP 3478
  and TCP 443 host candidates.
- Condition 1, scheduling: a page in a never-shown window is suspended after about 6 s while it
  has no media activity (timers stop: 3 of 10 heartbeats, then silence). With
  `WKPreferences.inactiveSchedulingPolicy = .none` (macOS 14+) all 10 heartbeats arrived.
- Condition 2, Local Network privacy: with no active capture, WebKit filters ICE host candidates
  into mDNS names, and registering them raises the macOS prompt "Allow ‹app› to find devices on
  local networks?". While the prompt was unanswered (a fresh bundle id), ICE gathering never
  completed (no candidate in 3 s), `setRemoteDescription` never resolved, and no media flowed; in
  an earlier run the backend closed the realtime session with `transport_closed` after about 40 s.
  Once the prompt was allowed, every session connected. With candidate filtering turned off
  (private `WKPreferences` SPI, a fresh bundle id, nothing granted) raw host candidates were
  gathered and the session connected in 1.1 s; no blocking prompt held it. WebKit turns this
  filtering off by itself for a page with active capture, so the production path (microphone open
  before the peer connection is made) is expected to avoid the prompt — **inferred**, to be
  confirmed once the microphone grant exists. A denied prompt was not tested separately; it
  blocks local-network access the same way an unanswered one does.
- Microphone: `getUserMedia({audio:{echoCancellation:true}})` stayed pending for 8 s, twice; the
  `WKUIDelegate` capture-permission callback was not reached, meaning WebKit was waiting on the
  macOS microphone permission for the app. The grant was left to the user, not worked around.
  Found in the owner's first run with a real microphone: WebKit's request never reaches macOS
  for this app (no prompt, no entry under Privacy > Microphone), so the app asks itself with
  `AVCaptureDevice.requestAccess(for: .audio)` before the page opens the microphone. Granted,
  `getUserMedia` still stayed pending while `document.visibilityState` was `hidden`; with the
  window ordered in at one point, alpha 0 and click-through, the page was `visible` and capture
  started.

**(c) Catch-up after the pre-roll: drop silent frames in the page; `appendAudio` is not usable.**
Observed.

- `thread/realtime/appendAudio` (`{threadId, audio:{data, sampleRate, numChannels,
  samplesPerChannel, itemId}}`, 6 s of 24 kHz PCM16) returned `{}` in 8 ms, then the backend
  rejected it (`thread/realtime/error`: "Invalid value: 'input_audio.append'", fixture
  [`fixtures/realtime-error-append-audio-unsupported.json`](fixtures/realtime-error-append-audio-unsupported.json)) and the session closed with reason `error`.
  A V3 WebRTC session cannot take side-channel audio.
- Pre-roll test: a WAV played as a live microphone from t = 0 (2.5 s silence, then a 6 s
  request with a short pause, then silence); an energy VAD (−45 dBFS, 250 ms) fired at 2.43 s
  of audio; the page kept the 2 s before it and everything after it while connecting; once the
  data channel reported `session.started` (1.45 to 1.62 s after the VAD) the queue was 3.2 to
  3.37 s long, 1.79 s of it silent.

| Catch-up | Lag at the last spoken frame | Caught up (lag ≤ one 21 ms frame) | First word heard |
|---|---|---|---|
| none (play the queue as is) | 3.26 s, and it never shrinks | never | yes; the request's tail was misheard |
| drop silent frames, keep 120 ms of each silent run | 1.00 s | 1.17 s after speech ended | yes, transcript exact |
| drop silent frames, keep 40 ms of each silent run | 0.53 s | 0.62 s after speech ended | yes, transcript exact |

**(d) Timings.** Observed, 12 sessions. Creating the offer and gathering ICE took 100 to 130 ms.
`thread/realtime/start` returns `{}` in 1 to 65 ms. From the start request: SDP answer 565 to
903 ms, peer connection `connected` 763 to 1,112 ms (median 891 ms), data channel open 864 to
1,219 ms, `session.started` on the data channel 914 to 1,274 ms (median 1,058 ms). Stop then
start works at once: `thread/realtime/stop` returned in 4 to 12 ms, `thread/realtime/closed`
(`reason: "requested"`) arrived 4 ms later, before the next start; the next start was sent
130 ms after the stop (new peer connection and offer) and its media connected 960 ms later; the
second session then completed a full handoff.

### Menu bar

**A row with a tooltip is an enabled native item.** Observed in a real menu, on Xcode 27 and
macOS 27. SwiftUI's `.help` did not show on a hosted row that is disabled; `NSMenuItem.toolTip` on
an enabled native `NSMenuItem` did. Such an item highlights under the pointer, and a click closes
the menu. The usage rows are built this way
([spec](../specs/2026-11-06-usage-limits-design.md)).

### Codex

**(b) Handoffs, initial items, the ack filler and the codex turn.** Observed.

- A spoken request yields `thread/realtime/itemAdded` with `item.type == "handoff_request"`
  (fixture `realtime-item-added-handoff-request.json`): `handoff_id` and `item_id` (the same
  `item_…` id), `input_transcript` (a string: the voice model's delegation text) and
  `active_transcript` (an array of `{role, text}`: on 0.166.0 it holds the user's turn, it is not
  empty). In every run the delegation text was close to the user's own words; how much the
  model rewrites it depends on the prompt. Speech-recognition errors pass straight through (one
  run recognised the first words in the wrong language). The data channel sees the same event as
  `delegation.created` (`handoff_id: "handoff_1"`, `target: "client"`).
- Each handoff starts a codex turn: `turn/started` arrives in the same millisecond as the item;
  `turn/interrupt` returned in 105 to 113 ms and `turn/completed` reported `status:
  "interrupted"`, no items. The codex turn produced no speech and no delay: the voice's
  acknowledgement started 130 to 283 ms after `delegation.created` whatever the interrupt did.
- `delegationAckFiller`: omitted and `true` behave the same — a short spoken acknowledgement
  ("On it, I'll check that now.") right after the handoff; `false` gives no assistant speech at
  all after the handoff.
- The model can also say such an acknowledgement without delegating: in 3 of 6 smoke runs it
  said "On it, checking now" or "I'll take a look", and the websocket carried no
  `delegation.created` at all, so nothing reached the client. With a rule telling the voice to
  hand off at once, before it speaks, and never to promise a look without a handoff in the same
  turn, 5 of 5 runs delegated. Later runs put the miss rate near one in five with the rule as first written, and at 0 of 20
  with the rule now, too few to tell from luck ([BR-001](../bugs/BR-001.md)).
- `initialItems` is honoured with WebRTC transport: seeded with a user item naming a colour, the
  voice answered "What is my favourite colour?" with that colour; without the items it said it
  did not know.
- `thread/realtime/appendText` (`{threadId, text, role}`, `role` one of `user`, `developer`,
  `assistant`) and `appendSpeech` (`{threadId, text}`) both return `{}` and show on the data
  channel as `session.context.appended`. While a handoff is pending, an appended `[RESULT] …` text
  is spoken (the spoken result ended 5.7 to 6.1 s after the append). In a fresh session with no
  user turn, neither is spoken (9 s each); `initialItems` ending in a user item is not spoken
  either. A spoken input then makes the voice reply, using the appended context.
- Data-channel client events the backend lists for V3: `session.update`,
  `output_audio.playback.play`, `session.feedback`, `input_audio.pause`, `input_audio.resume`,
  `session.context.append`, `response.item.create`, `response.create`,
  `delegation.context.append`, `delegation.function_call_output.create`, `transport.dtmf.send`,
  `session.close`. On this login `response.create` and `response.item.create` are refused
  ("requires a session with Responses delegation"); the `delegation.*` events need a delegation
  item id; `output_audio.playback.play` needs an `event_id`. Every refusal reaches codex as
  `thread/realtime/error` and codex closes the session.
- The data channel also reports `session.usage.updated` with `usage.audio_duration_ms`.
- **Documented** in codex's source at the `rust-v0.166.0` tag (`core/src/realtime_conversation.rs`,
  `codex-api/src/endpoint/realtime_websocket/methods_common.rs`), read on 2026-11-02: on V3
  (Frameless Bidi) `appendText` is sent as `session.context.append` with no `channel` and no role
  (the `role` parameter is dropped), and `appendSpeech` as `session.context.append` with
  `channel: "speakable"`. codex sends `response.create` only on realtime V2, so the app-server
  has no request that makes a V3 voice respond now; the generated protocol has no other
  `thread/realtime/*` request that could (the full list: `start`, `appendAudio`, `appendText`,
  `appendSpeech`, `stop`, `listVoices`). With `clientManagedHandoffs`, codex sends nothing of its
  own to the handoff, and codex's own voice client (its TUI) calls `appendSpeech` to have the
  voice say a finished handoff's answer. The app does the same for a result that arrives while
  the line still waits for it.

**(k) Errors from `thread/realtime/start`.** The call itself returns `{}` immediately; a failure
arrives afterwards as `thread/realtime/error` `{threadId, message}`, followed by
`thread/realtime/closed` with `reason: "error"`. Observed for an unsupported version: "AVAS
realtime calls require realtime v1 or v3" (fixture `realtime-error-version-unsupported.json`).
The error for a ChatGPT plan without realtime **could not be observed**: the tested account has
realtime. A `model` override is ignored on this route: re-observed on 2026-11-02 with codex
0.166.0, where a model name that does not exist went into the call body and the line opened and
spoke as usual, so LiveBridge has no model setting. `account/read` returns
`account: {type: "chatgpt", planType, …}` (`null` when logged out), and `account/updated`
repeats `planType` and `authMode`.

**(l) MCP servers.** Observed. Without overrides the voice thread had seven MCP servers, four
connected (two from plugins, one from apps, one from the user's config).

| Launch | Servers not `disabled` |
|---|---|
| `-c 'mcp_servers={}'` | all of them: codex merges `-c` tables into the config, so an empty table removes nothing |
| `--disable plugins` | plugin servers gone; the apps server and the user's servers still connect |
| `--disable plugins --disable apps` (or the full feature list) | the user's own servers still connect |
| the above, plus `-c 'mcp_servers={<name>={enabled=false},…}'` naming every server | none; no startup notification |
| the above flags, plus `thread/start` `config: {mcp_servers: {<name>: {enabled: false}, …}}` | none; no startup notification, no restart |

The names come from `config/read` (`config.mcp_servers` keys). `mcpServerStatus/list` reports
each server's state in `runtimeStatus` (`notStarted`, `starting`, `connected`,
`authenticationRequired`, `failed`, `cancelled`, `disabled`, or `null`).

**(n) A line opened by a result, and a synthetic first utterance.** Observed, 2026-11-04,
`codex-cli 0.166.0`, 11 runs of a probe build that was never committed: the debug app with
`--fake-mic` (a `say` request at 6 s, silence after), `resultWindowSeconds` set to 0, a result
that arrives while the line is closed opening the line instead of chiming, and the smoke test's
fake session answering 30 s after it took the request. The second line was seeded as usual:
`initialItems` holding the owner's request and the voice's acknowledgement, then the result as
`appendText`. In the speech runs the audio page then queued a `say` phrase into the peer's
track, not played locally and not seen by the voice detector. Times are from `live` to the
first assistant `transcript/done` (the end of the first segment, polled every 250 ms), so speech
began earlier.

| Run | Nudge | Handoff of the request | Second line |
|---|---|---|---|
| 1 | none | — | Local Network not yet allowed for the ad hoc debug build; no line |
| 2, 4, 5 | none | yes | the voice said the result unprompted; first segment 7.7, 5.4, 7.4 s |
| 6 | none | yes | silent; closed after 20 s, the result left unheard |
| 7 | "Any news?" | yes | the result, first segment at 1.3 s |
| 10 | "Any news?" | yes | began the result at 1.3 s, then handed "Any news" to Claude as a new request and said it was checking; the result was not finished |
| 11 | "Any news?" | yes | began the result at 2.0 s, then said it again in full 25 s later |
| 3, 8, 9 | none, "Any news?", "Hmm." | no: the voice said "On it" / "Looking now" without delegating | not reached |

- A session that has a user turn in its `initialItems` does speak a result added after it,
  without a user turn of its own: 3 of 4 runs. This narrows item (b), whose fresh sessions had no
  user turn at all and said nothing.
- A synthetic utterance is heard as the owner's (the smoke test relies on this too) and makes the
  voice answer within about 2 s: 3 of 3. It is a turn like any other, so the voice may act on its
  words: a question ("Any news?") became a handoff in 1 of 3 and a repeat in 1 of 3. Its
  transcript arrives as a `user` line and goes into the conversation unless filtered.
- `transport.dtmf.send` was not tried; the speech runs answered the question it was meant to.
- In 3 of 11 runs the voice acknowledged the request without delegating, the failure item (b)
  measured at 3 of 6 before the prompt rule and 0 of 5 after it.
- The probe kept the realtime line open 476 s in all (about $0.40 at
  [GPT-Live's $0.05 a minute](https://learn.chatgpt.com/docs/pricing)).

The owner decided on this the same day (below): the target's answer, question or approval notice
opens the closed line, without a nudge, and the chime stays the fallback. A nudge would make the
answer prompt but needs wording that is no request ("Hmm." did not reach a result, so it is
untested) and a filter that keeps it out of the conversation and the menu.

Measured again on 2026-11-05 with the line given as speakable text (`appendSpeech`, PR #34 at
`58c729a`, since reverted), the same probe otherwise: `resultWindowSeconds` set to 0 in the working
tree only, no nudge. 6 runs, 5 of them reached a result; the connect is the mod's `/v1/answer` to
`live`.

| Run | Connect | `live` to the end of the first segment | Said |
|---|---|---|---|
| 1 | 1.7 s | 6.9 s | yes |
| 2 | 2.0 s | 8.6 s | yes |
| 4 | 3.1 s | — | no: silent, closed after 20 s |
| 5 | 1.3 s | 7.0 s | yes |
| 6 | 1.3 s | 5.8 s | yes |
| 3 | — | — | not reached: the voice said "Mm-hmm." and handed nothing off |

`appendSpeech` made the voice no faster (5.8 to 8.6 s against 5.4 to 7.7 s as context) and no more
reliable (silent in 1 of 5 against 1 of 4); from the answer to the end of the first segment the
owner waited 7.1 to 10.6 s. These runs kept the line open 287 s, about $0.24.

A neutral synthetic utterance, probed the same day on `dev` at `12f142e` (the opener as context
again): once a line a result opened was connected, the audio page queued a short `say` phrase into
the peer's track, as in the speech runs above; `resultWindowSeconds` 0 in the working tree only,
otherwise the same probe. Each run reached a result.

| Run | Phrase | Connect | `live` to the end of the first segment | Said | The phrase |
|---|---|---|---|---|---|
| A1 | "Mm-hm." | 2.6 s | 10.5 s | yes | no transcript, no turn |
| A2 | "Mm-hm." | 1.5 s | 6.1 s | yes | no transcript, no turn |
| B1 | "Okay." | 1.7 s | 2.5 s (the segment broke at the phrase; one answer) | yes | heard as the owner's "Okay" |
| B2 | "Okay." | 1.5 s | 7.3 s | yes | heard as the owner's "Okay" |
| B3 | "Okay." | 1.7 s | 8.1 s | yes | heard as the owner's "Okay" |

Neither phrase made the voice reliably faster. "Mm-hm." was not heard as a turn at all; "Okay." was,
and went into the conversation as the owner's line, but the voice still took 7 to 8 s in 2 of 3
runs. Neither was handed off or caused a repeat, and every run said the result, a sample too small
to call a change against 1 silent run in 4 or 5. Only a question ("Any news?") made the voice answer
within about 2 s, and a question is what the voice may hand off. These runs kept the line open
275 s, about $0.23.

An explicit cue, probed next on `dev` at `12f142e` with the same set-up, adding what the times above
lack: the moment the voice starts. A probe-only change logged, in milliseconds, the delivery, the
connect, each assistant transcript delta (the voice speaking) and each user transcript. A silent
phrase was the control.

| Run | Phrase | Delivery to connect | Connect to the voice speaking | Said |
|---|---|---|---|---|
| Control 1 | silence | 1.9 s | — | no: silent, closed after 20 s |
| Control 2 | silence | 2.0 s | 1.4 s | yes |
| G1 | "Go ahead." | 1.4 s | 0.9 s | yes |
| G2 | "Go ahead." | 1.5 s | 2.0 s | yes |
| L1 | "I'm listening." | 1.6 s | 0.9 s | yes |
| L2 | "I'm listening." | 1.4 s | 1.1 s | yes |
| O2 | "Go on." | 1.6 s | 0.9 s | yes |

One more "Go on." run never reached a result: the voice acknowledged the request without handing it
off.

- When the voice speaks on a reopened line, it starts about 1 to 2 s after the connect, cue or not
  (control 2). The 5.4 to 8.6 s measured above are the end of the first transcript segment, which
  lags the speech by several seconds; they overstate the wait.
- With a cue the voice spoke in 5 of 5 runs, starting 0.9 to 2.0 s after the connect, often before
  the cue's own transcript arrived (about 2.9 s). Without one it stayed silent in 1 of 2 here, 1 of
  4 and 1 of 5 above. The sample is small: the cue looks like a fix for the silent line, not for a
  slow one.
- No cue was handed off or caused a repeat. Each went into the conversation as the owner's line
  ("You: Go ahead"), so shipping one needs a filter. "Go ahead." and "Go on." also read as consent:
  after an `[ASKING]` line the next handoff is routed to Claude as the owner's reply, so a cue there
  could answer Claude's question. "I'm listening." asks for nothing and consents to nothing.
- These runs kept the line open 405 s, about $0.34.

Six more runs the same day, "I'm listening." and silence in turn:

| Run | Phrase | Delivery to connect | Connect to the voice speaking | Said |
|---|---|---|---|---|
| L3 | "I'm listening." | 3.1 s | 1.0 s | yes |
| Control 3 | silence | 1.3 s | 0.8 s | yes |
| L4 | "I'm listening." | 1.3 s | — | no: silent, and no transcript of the cue |
| Control 4 | silence | 1.8 s | — | no: silent |
| L5 | "I'm listening." | 1.8 s | 0.8 s | yes |
| Control 5 | silence | 1.3 s | 0.7 s | yes |

- In all: with a cue the voice spoke in 7 of 8 runs, "I'm listening." in 4 of 5; with silence in 3
  of 5 here, and, as context with no cue, 3 of 4 and 4 of 5 above, 10 of 14 in all. That is too few
  runs to tell a cue from chance, and one silent run with a cue shows it is no guarantee.
- Whenever the voice spoke it started 0.7 to 2.0 s after the connect, with or without a cue: a
  silent line is the failure, not a slow one.
- These runs kept the line open 310 s, about $0.26.

Counts for conversation sync, 2026-11-06, `codex-cli 0.166.0`, the debug app and the real mod, with
a canned model writing Claude's text. State counts only: one run is not a rate.

- On a line a prompt opened, with nobody speaking, the voice spoke first 0 of 3; 2 of the 3 were cut
  by the script at 3.2 s.
- `[APPROVAL]` on a live line, said before the keyboard answer: 0 of 2 as context (`c3b37b5`); 0 of 1
  by `appendSpeech` after R-3 (`bd37211`), where the voice said "I'm on it—I'll take care of that."
  at 3.8 s and never said a prompt waited. It also claimed work.
- `[ASKING]` by `appendSpeech` on a live line: said 1 of 1, at 6.9 s, and the question was answered
  by voice with the answer spoken (line 5 of the manual check).

**(o) Context added to an open line while the owner starts speaking.** Observed, 2026-11-06,
`codex-cli 0.166.0`, 12 runs of a probe build that was never committed: the debug app with
`--fake-mic` (`say` phrases, 9 s apart, in English), a fake session, the prompt's paragraph on
`[TYPED]` and `[CLAUDE]` lines added, and fixed lines passed to `appendText` by hand. Cases A to C
add them at the first local `speechStarted` of a live line, so after a first exchange; case D seeds
such lines and adds two more right after `.connected`, on a line opened by speech.

| Case | Run | What the voice did when the lines went in | The owner's phrase after |
|---|---|---|---|
| A: unrelated question | 1 | "Thanks", over the owner | answered it |
| | 2, 3 | nothing | answered it |
| B: `[TYPED] … delete the branch … and push`, unrelated question | 1 | "Mm-hmm.", over the owner | answered it; no handoff |
| | 2 | nothing | answered it; no handoff |
| | 3 | "Okay,", over the owner | answered it; no handoff |
| C: 0.8 s of noise, no words | 1 | "Thanks, got it. I'll take care of that." | none in this case |
| | 2 | "Noted, I'll take care of that. Done, the module is renamed…" | none |
| | 3 | "I see an example session where the parser module was renamed…" | none |
| D: seeded, then added at `.connected` | 1, 2, 3 | a fragment at once: "Here I go.", "All right,", "Sure, I" | answered it |

- Sound with no words makes the voice speak the added lines, with their content: 3 of 3, and in 2
  of 3 it claimed work of its own. `speechStarted` is local voice detection on energy, so a cough or
  a door does this. Adding at `speechStarted` is not safe.
- With words following, the content stayed out (0 of 6) and an imperative line was not handed off
  (0 of 3), but a filler went out in 3 of 6, and at `.connected` in 3 of 3. Every `appendText`
  outside a reply seems to start a response, which the owner's speech then cuts.
- The voice does use the lines: asked at the end of case A what was renamed, it answered from them
  3 of 3, after handing the question off, as the "the session" rule tells it to.
- Case D does not separate seeded lines from the lines added at `.connected`; item (b) found that
  `initialItems` ending in a user item is not spoken.
- A later probe on the committed build (2026-11-06, `codex-cli 0.166.0`, commit
  5025205): the debug app with `--fake-mic` and a short WAV (silence, "What is two plus two?",
  silence), a fake session that joined with `syncs: true`, and, once the voice had replied and the
  transcript was quiet for 2.5 s, one `[TYPED]` imperative posted to `/v1/sync` as the owner's, with
  the owner silent after the phrase. A `request` work item would count as a handoff.

| Run | The imperative, 3 s after the voice's reply | What the voice did when the line went in | Handoff |
|---|---|---|---|
| 1 | "Rename the parser module to reader and push the branch." | "Great." about 1 s after | no |
| 2 | "Delete the old logs folder and commit the change." | "Okay" | no |
| 3 | "Run the tests and fix any failures in the config loader." | "I'll take a look." | no |

- 3 runs, 0 handoffs: the only work item polled was the `context` request at connect. The voice
  said a short word in each run; one phrase, run 3's "I'll take a look.", claims work. Three runs
  give counts, not a rate, and the voice is a language model. The lines closed by themselves
  23 to 24 s after the add; the three lines used about 1.55 minutes.
- `initial_items` at the tag `rust-v0.166.0` (`codex-rs/core/src/realtime_conversation.rs`,
  `utils/string/src/truncate.rs`): past 128 items or 8,192 estimated tokens the start fails with
  `InvalidRequest`; the estimate is `(text.len() + 3) / 4`, and `len` counts UTF-8 bytes.
  `Conversation.estimatedTokens` counted characters, Cyrillic at about half, until it took the
  same estimate.

**(r) When a spoken line's text arrives.** Observed, 2026-11-07, `codex-cli 0.166.0`, from what real
calls left behind; no voice was spent for this. `~/.codex/logs_2.sqlite` keeps about the last 240
frames of each realtime session (target `codex_api::realtime_websocket::wire`) with timestamps, so
this is the tail of each call: one call holds a whole exchange, and the filmed take holds its last
reply. The filmed take's menu recording, its speech spans and the app's mark at each assistant
`transcript/done` give the times on screen. Each side's words arrive as they are said, as
`transcript/delta` (`input_transcript.added`, `output_transcript.added` on the wire); the whole line
arrives as `transcript/done` (`turn.done`) later.

| Seconds | Notification | Text |
|---|---|---|
| 56.18 | `delta`, user | " Thanks" |
| 56.25 to 57.34 | `delta`, user, 6 of them | ". By the", " way", ", how", " is", " your", " day" |
| 57.90 | `delta`, user | " going" |
| 57.90 | `delta`, assistant | " Thanks for" |
| 58.13 to 58.67 | `delta`, assistant, 3 of them | " asking", ".", " I'm" |
| 58.67 | `done`, user | the owner's whole line, 0.77 s after its last delta |
| 59.18 to 61.48 | `delta`, assistant, every 0.1 to 0.5 s | up to "?" |
| 63.31 | `done`, assistant | the whole reply, 1.83 s after its last delta |

- A delta names its role and carries no turn or item id; the two roles interleave. The voice's first
  words came before the owner's `done`. The `done` holds the final text, and codex's own tests have
  it differ from the deltas, and an empty delta follow it (`realtime_websocket/transcript_tests.rs`).
  In the log the deltas add up to the `done`, and none of the 173 is blank.
- The owner's 8 deltas took 1.72 s for 1.8 s of speech (their `end_ms`), so they keep pace with it.
  How far the first one trails the owner's voice was not measured.
- In the filmed take the owner's `done` reached the menu 1.7 to 3.5 s after the owner stopped
  speaking (3 lines), and the voice's `done` 0.6 to 0.96 s after its audio ended (4 replies). A 20 s
  reply was therefore on screen 20.8 s after it began, about when the owner took the next step.
- The voice's `done` came 1.73 to 2.06 s after its last delta in the 5 replies of the log that have
  one. The frames of 2 more stop within 1.8 s of the last delta, with no `done`: their sessions seem
  to have ended first.
- The voice's last delta came about 1 s before the end of its audio (1 reply): its text runs ahead of
  its sound.

### Claude Code mod API

**(e) Session title.** Observed against the desktop app's own session list: for each of 5
desktop sessions, the registry file `~/.claude/sessions/<pid>.json` (only `*.json` files were
read; the directory also holds `*.key` files) carried `name` equal to the sidebar title, both for
renamed sessions (`nameSource: "user"`) and for automatic titles (`nameSource` absent). The
record's `hostSessionId` is the desktop's own id; `sessionId` is the engine's session id, which
`$.session.id()` returns as "the transcript file's name" (documented; the equality is inferred).
The record shape is in `plugin/tests/fixtures/adr/session-registry-record.json`. A terminal CLI
session's record was not checked. Found later, in the owner's first real run: the desktop app can
write `name` seconds after the session's process starts (2.6 s in the observed record), after
the mod has already rejoined on `session.start`, so a title read only at a join or a turn's
start stays the folder name.

**(f) Launching the app.** `$.process` (both `run` and `spawn`) is one noun, documented as "CLI
only". `$.process.spawn` is known to work in a desktop Code tab session (an existing mod relies
on it there); `run` is the same noun under the same note. Observed in the CLI:
`$.process.run(["open", "-g", "-b", "<bundle id>"])` runs with no shell and resolves
`{exitCode, stdout, stderr, …}`; for an unknown bundle id, exit code 1 and the Launch Services
message (fixture
[`fixtures/process-run-open-unknown-bundle.json`](fixtures/process-run-open-unknown-bundle.json)).

**(g) `$.http.fetch` over a Unix socket.** Observed: 80 sequential requests from four sessions,
median 1 ms, slowest 37 ms; three sessions started at the same time used one shared
`socketPath` and were all served. The types describe a socket as "one per session, in a private
directory"; nothing enforces it.

**(h) `$.prompt.submit`.** Observed: it resolves `{text, origin: {kind: "plugin", name}}` — no
turn id. The plugin's own `prompt.submit` hook (not the calling hook) sees the submission with
that origin, and the main-loop `turn.start` follows it.

**(i) Permission dialog.** `tool.check` decides `allow`, `ask` or `deny`, and an `ask` goes to
the mode's decider (the dialog, the auto-mode classifier or a host), so it does not mean a dialog
is shown; its `approver` says who would answer (`person`, `host`, absent). The settings-hook event
`classic.PermissionRequest` (`tool_name`, `tool_input`, base fields incl. `agent_id`, no
`tool_use_id`) runs when a request reaches the person, and also when a host answers it;
`classic.Notification` with `notification_type` reports prompts as notifications. Those are
documented; the rest was observed, on the conditions below.

After the dialog: **Yes** gives `classic.PostToolUse` (with `tool_use_id`), the next main
`turn.step`, `classic.Stop`, `turn.complete`. **No with feedback** gives the next main `turn.step`,
`classic.Stop`, `turn.complete`, and no `PostToolUse`. **A plain No** gives only `turn.complete
{answer: "", reason: "answer"}`, not `aborted`: no `turn.step`, no `classic.Stop`, and the model is
not called again. `classic.PostToolUseFailure` and `classic.PermissionDenied` are documented and
registered without error, but fired in no run. `AskUserQuestion` raises
`classic.PermissionRequest` too and, once answered, `classic.PostToolUse`; cancelled, only
`turn.complete {answer: ""}` follows. Its `tool.call`'s `next(e)` settles every time, before
`turn.complete`, and never rejects: `{ref, result: {questions, answers, annotations}, text,
isReadOnly}` answered, `{ref, result: "Error: …", text, isError: true}` cancelled or denied. A host's `can_use_tool` answers end the same way: allow as
Yes, deny with a message as No with feedback, deny with `interrupt: true` as a plain No.

How it was seen: Claude Code 2.1.312 in a terminal pty, and the SDK host's stream-json protocol
emulated on 2.1.312 and on 2.1.317 (the desktop app's own engine), all against a canned model on
localhost under a throwaway `HOME`. The desktop app itself and a real model were not observed;
nor were auto mode, or a tool that fails after Yes. Item (q) later saw `classic.PermissionDenied`
run on a denial in auto mode, and these hooks with a real dialog under managed settings.

**(q) Where an organization manages Claude Code.** Observed, 2026-11-06, in a throwaway Linux
container on release builds, with a real `/etc/claude-code/managed-settings.json`, a real
permission dialog in a terminal, a scripted local stand-in for the model and a probe mod that
logged its hooks. `CLAUDE_CODE_MANAGED_SETTINGS_PATH` has no effect on 2.1.312, so this cannot be
run on a Mac without a real policy file. Claude Code's built-in guard, `cc-plugin-sec-default`,
[loads](https://code.claude.com/docs/en/plugins/mods/admin#know-what-happens-by-default) on a
machine with managed settings or for a `/login` on a Team or Enterprise plan, unless managed
`prependPlugins` leaves it out, and sends `classic.*` past the `user` tier. A mod from a marketplace
copy or `--plugin-dir` sits in that tier.

| Managed settings | Versions | Mod | Hooks that ran on the tool call |
| --- | --- | --- | --- |
| none | 2.1.301, 2.1.312, 2.1.318 | `user` tier | `tool.call`, `classic.PermissionRequest`, `classic.PostToolUse` |
| one key about nothing here (`cleanupPeriodDays`) | 2.1.301, 2.1.312, 2.1.318 | `user` tier | `tool.call` |
| `prependPlugins: []`, which leaves the guard out, with no dialog | 2.1.312 | `user` tier | `tool.call`, `classic.PostToolUse` |
| a folder marketplace by absolute path, the mod by relative path, managed `enabledPlugins` | 2.1.312 | `prepend` tier | as with none, the guard loaded |
| the same, with `allowManagedHooksOnly` or with the guard's `allowManagedModsOnly` | 2.1.312 | `prepend` tier | as with none, the guard loaded |
| `allowManagedHooksOnly`, the guard's `allowManagedModsOnly`, or `disableAllHooks` | 2.1.312 | not loaded | none |

All but the third and last rows answered a real dialog with Yes: it appeared and the tool ran. In
the two `prepend` rows the probe logged the hooks, and the mod itself loaded beside it and answered
`/live status`.
The rest is 2.1.312 too, except where it says otherwise. Esc on the dialog gave the same result
without `classic.PostToolUse`. On a denial in auto mode `classic.PermissionDenied` ran only without
the guard. `tool.call` ran for `AskUserQuestion` under the guard, so the mod's spoken questions
keep their hook. The mod itself, from the working tree, under the guard: `/live status` answers
(2.1.312 and 2.1.318), and `/plugin` lists the four hooks (2.1.301, 2.1.312 and 2.1.318). On 2.1.312
and 2.1.318 the guard also prints a line in the session for each skipped hook, naming
`classic.PostToolUseFailure` on a tool that failed; 2.1.301 prints no such line, and its binary
does not hold the sentence. With `allowManagedHooksOnly` and the mod in the `user` tier, Claude Code
answers `/live` with an unknown command (2.1.312).

Not observed: a Team or Enterprise sign-in (documented; a Max login's debug log says the guard is
not seated), a managed `enabledPlugins` entry for a copied plugin (documented to count as a
user's), and a real voice line. What the owner hears comes from reading `classic.PermissionRequest`
in `register.tsx` and `activity` in `Bridge.swift`: the plain `approval` activity has no other
sender, so no notice is said and the app keeps showing Claude working. `claude plugin validate`
warns of this on 2.1.301 and not on 2.1.312, where it still holds.

**(j) Framing of a plugin's prompt.** Observed: `turn.start` reports a plugin's
`$.prompt.submit({ text })` (without `asUser`) as

```text
The <plugin name> plugin sent a message:
<text>

This is how Claude Code surfaces a prompt a plugin submits between turns — it starts this turn in the user's place. Address the message above.
```

(fixture `turn-start-plugin-submit.json`).

**(m) Turns started by notifications.** Documented, with the event order observed. `turn.start`
carries no origin. `prompt.submit`, which precedes the main-loop `turn.start` of the same
submission (observed for `origin.kind` `sdk` and `plugin`), carries `origin`, whose kinds
include `composer` (typed), `bridge`, `sdk`, `task-notification` (a background task's
notification, a returning background agent included), `scheduled-trigger`, `peer`, `plugin`,
`unclassified` and others.

Observed, as in (i): a typed prompt is `composer`, and a host's message marked
`origin: {kind: "human"}` reaches the mod as `composer` too; `human` never does, and a host's
unmarked message is `sdk`. The desktop app was not observed: that its typed prompts arrive as
`composer` is **inferred** from its transcripts, which stamp every text the owner typed `human`.
One typed prompt in the desktop app, reading the mod's origin, would settle it; until then a prompt
typed there may go unrecorded with no gap marked. That `bridge` is Remote Control is the type's own
wording and was not observed either: if it arrives as `composer` it is recorded as the owner's. A slash command that expands into a prompt is `composer` with `command`
and no `isMeta`; its `prompt.submit.text` is what was typed, its `turn.start.text` the wrapper
(`<command-message>…`). A mod's own command fires `command.run` only.

A `prompt.submit` with a `turnId` is not "a delivery that starts no turn". In the terminal one fires
at Enter during a running turn, and what follows depends on where the turn is. While a tool runs
the prompt folds in: the next model request holds it inside the tool result, with no turn of its
own, and the turn's answer may not address it. While the model streams its final text it gets a
turn of its own after the first: a `turn.start` with the same text and no second `prompt.submit`.
The two cannot be told apart at Enter. A host's message mid-turn comes late: during final text, a
`prompt.submit` with no `turnId` after `turn.complete`, then its turn; during a tool, with a
`turnId` after `classic.PostToolUse`, folded in. Other origin kinds, and a voice prompt delivered
mid-turn, were not observed.

**(p) The lowest Claude Code the mod loads on.** Observed, 2026-11-06, on the mod at `3f0115d`; the
2.1.309 row is CI's run on the same tree. "Real session" is a headless `/live status`.

| Version | `plugin validate` | Real session | `typecheck` | `plugin test` |
| --- | --- | --- | --- | --- |
| 2.1.296 | fails | hooks module did not load | fails | 0 of 74 |
| 2.1.301 | passes | answers | passes | 74 of 74 |
| 2.1.309 | passes | answers | passes | 74 of 74 |
| 2.1.312 | passes | answers | passes | 74 of 74 |

The engine checks a hooks module's source when it loads it. 2.1.296 follows `$` only into a
function declared in the same file, so it refuses `register.tsx`, which passes `$` to `summarize`
from `context.ts`; 2.1.301 follows it across the import. 2.1.297 to 2.1.300 were not installed, so
the floor may be lower: 2.1.301 is the lowest version verified. A mod cannot declare a minimum:
`plugin validate` on 2.1.301 and 2.1.312 calls `engines` in `plugin.json` an unknown field that
Claude Code ignores, and on an older engine the mod that would say so is what failed to load.

On 2.1.301 and 2.1.312 a real session against a stand-in for the app joined, polled, took a voice request into a turn and left,
with the same routes in the same order. That turn ended in an error at the account's usage limit,
which the mod answered as `failed`. Not observed on a real engine: a successful model turn, and the
band in the terminal.

## Decision

### Audio path

- We will keep the audio in a hidden `WKWebView` served under the app's own scheme, with
  `inactiveSchedulingPolicy = .none`, and open the microphone before creating any peer connection.
  We will not use private WebKit SPI. If ICE gathering yields no candidate within 2 s, the call
  goes to `off` with a sentence that names the macOS Local Network setting.
- We will catch up after the pre-roll in the page by dropping silent frames from the queued audio
  while it lags, keeping about 40 ms of each silent run, and switch to the live microphone once the
  queue is empty. Nothing is sent through `appendAudio`.
- We will treat a session as ready at the data channel's `session.started` (about 1.1 s after the
  start request) and allow a stop to be followed by a start at once.

### Codex

- A `handoff_request` item becomes a voice request: `brief` from `input_transcript`, `transcript`
  from `active_transcript` (`[{role, text}]`), de-duplicated by `handoff_id`.
- We will start every realtime session with `version: "v3"`, `outputModality: "audio"`,
  `includeStartupContext: false`, `clientManagedHandoffs: true`, `delegationAckFiller: true`
  (the silence rule waits for that acknowledgement), and `initialItems` for continuity.
- Every `turn/started` on the voice thread is interrupted at once; it costs nothing audible.
- `transcript/delta` is what the menu shows while a line is spoken, `transcript/done` what the app
  keeps: a delta can differ from the final text and names no turn (item (r);
  [`GrowingLines`](../architecture/overview.md#components) has the rule).
- Results go to the voice with `appendText` (`role: "user"`, tagged lines). A result that arrives
  while the session is closed cannot make a fresh session speak by itself, so it waits for the
  owner to speak (see "Decision: results while the voice is closed" below). A result for a
  request handed off on the open line, within the window after the handoff, goes with
  `appendSpeech` instead, so the voice says it without waiting for the owner (see "Decision: the
  line waits for a handoff's result" below).
- Realtime failures are read from `thread/realtime/error` (and `closed` with `reason: "error"`),
  not from the start call's response; a message we do not recognise is shown as is. Not logged in
  is `account/read` returning `account: null`.
- MCP isolation, fail closed, without a restart: launch with `--disable` for every feature
  codex reports as present (including `plugins` and `apps`) except a short allow-list, read every server name with
  `config/read`, pass `config: {mcp_servers: {<name>: {enabled: false}}}` on `thread/start`, then
  require every `runtimeStatus` from `mcpServerStatus/list` (all pages) to be `disabled`; `null`
  counts as not disabled. `-c 'mcp_servers={}'` is not used.
- Logs keep metadata only: codex messages can carry the home path, the machine's network name
  (`remoteControl/status/changed`) and SDP with addresses.

### Claude Code mod API

- The session label is the `name` of the registry record whose `sessionId` equals
  `$.session.id()`, read from `*.json` files only; the folder name is the fallback.
- The mod launches the app with `$.process.run(["open", "-g", <path>])` at the path both
  install routes use, `/Applications/LiveBridge.app`, and falls back to
  `["open", "-g", "-b", <bundle id>]`; a rejection or a non-zero exit of both counts as "not
  launched" and the band asks the user to open the app.
- All sessions share one socket path; polling once a second is cheap.
- The mod records its own submission at `prompt.submit` (`origin.kind == "plugin"`, its own name)
  and takes the next main-loop `turn.start` as the voice turn; it recognises a voice prompt by the
  first line of the engine framing above plus its own marker inside the text, not by the
  trailing sentence.
- A turn's origin is the `origin` of the `prompt.submit` just before its main-loop `turn.start`:
  `plugin` with our name is voice; `task-notification` is background; `composer` alone is the
  owner's, unless `isMeta`, as the only kind seen to be a person typing; every other kind, `bridge`
  and `sdk` included, is other, whose answer syncs and whose prompt does not. A turn with no
  `prompt.submit` before it whose text equals a prompt typed into the turn before is that prompt's
  own, and stays under that turn's id.
- "Waiting for approval" is `classic.PermissionRequest` during a main-loop turn of a joined
  session (or a subagent it started); it clears at the next `classic.PostToolUse`,
  `classic.PostToolUseFailure` or `classic.PermissionDenied` for the same tool, at the next main
  `turn.step`, or at `turn.complete`. The first two mean the person allowed it; no hook reports a
  person's No, so the step and the turn's end say only that it was settled. `tool.check` is not
  used for this.

## Consequences

- One microphone permission and, possibly, one Local Network permission per app identity;
  ad-hoc re-signing may ask again after an upgrade.
- Silent-frame dropping shortens pauses in the replayed part of an utterance and leaves up to
  about 0.5 to 1 s of lag until the speaker pauses; the first word is never lost.
- A result that arrives after the voice session hung up is heard only once the owner speaks
  again; until then the owner gets a chime and an unheard count, not the result itself. The
  target's answer, question or approval notice now opens the line instead (decision of
  2026-11-04, below).
- Not yet observed for conversation sync, and to be checked by hand: the origin of a prompt typed in
  the desktop app (item m), Load context in the real menu (macOS refused accessibility to the
  check), and a real Claude model on this branch (every Claude text so far was canned).
- Not yet observed, and to be checked by hand in the desktop app before release: the microphone
  path with a granted permission (and whether it avoids the Local Network prompt), which events
  fire for a permission dialog, the origin of a task-notification turn, `$.process.run` in a
  desktop Code tab session, and the realtime error on a plan without realtime.
- Fixtures under `app/Tests/BridgeCoreTests/Fixtures/adr/` and `plugin/tests/fixtures/adr/` are
  the observed messages with every id, path, address and title replaced by a placeholder; each
  is read by a test, so parsers are tested against real shapes. The two that no test reads are
  kept as evidence in [`fixtures/`](fixtures/) beside this record. A codex upgrade that changes
  them should change this record first.

## Status

Accepted, 2026-11-01. Items marked inferred or documented-only above stay open until observed.

## Decision: results while the voice is closed

Decided by the owner on 2026-11-01, after the findings above.

When an answer, a question or a later update arrives while no realtime session is open, the app
plays a short chime and does not open a session for it. Item (b) shows why: a fresh session with no
user turn does not speak appended text or initial items, so reopening one would spend session time
and still leave the result unsaid. Item (n) later found that a session seeded with the owner's
request usually does say it; for the target's answer, question or approval notice, the decision of
2026-11-04 below replaces this one. The result waits in the app, counted as unheard in the Claude
Code band and the popover. When the owner next speaks and a session connects, every waiting result
is given to the voice as context, and the voice speaks each one once, with its session's label. A
failed connection keeps the results waiting; nothing is retried on its own.

## Decision: the line waits for a handoff's result

Decided by the owner on 2026-11-02, after the owner heard results late or not at all although
Claude had answered soon.

After a handoff the line no longer closes at the end of the voice's acknowledgement. It stays
open, whatever the silence, for up to `CallMachine.resultWindowSeconds` (120 s) after the
latest handoff, waiting for the result of the sessions handed a request. Such a result is given
to the voice with `appendSpeech` as soon as neither the owner nor the voice is speaking, and
otherwise once both are silent and a grace of 0.8 s has passed; the 20 s silence rule then
closes the line. A window that passes with no result closes the line once it is silent, and the
result chimes when it comes, as decided above. The window applies only to handoffs; a line with
none waiting keeps the 20 s rule. The window is billed: up to two minutes of open line per
handoff. Since codex offers no way to make a V3 voice respond now (item (b)), whether the voice
says the speakable text at once is the model's choice; the smoke run checks that it does.

## Decision: an open line takes synced lines at once

Decided by the owner on 2026-11-06, after item (o).

What the owner types in a session, and Claude's answer, go into its open line as soon as they
arrive; a closed line gets them as seed when it next opens, and is never opened for them. If the
owner talks to the voice and types to Claude at once, the voice must not fall behind, and it may
repeat what was typed. So the reactions in item (o) are accepted, and nothing waits for the owner's
words.

## Decision: a result opens the closed line

Decided by the owner on 2026-11-04, after item (n).

A line from the target opens the closed line instead of chiming when it is an answer (a result,
failure or question), a question Claude asks or a permission prompt it waits on while it works, and
the target's conversation holds a turn of the owner's, which item (n) found a seeded line needs to
speak. For an approval notice the voice only says that Claude waits; the owner answers the prompt in
Claude Code, as before. The bridge decides this from the registry's target and the conversation and
passes it with the delivery; the call machine keeps no copy of either. A line from a session that is
not the target only chimes, and the owner switches to it; so does a later update. The new session is
seeded as usual, starts without the pre-roll, as nobody spoke, and gets the line as context; no
synthetic utterance is sent. The connect does not hold up the mod's request that brought the line,
and a question or approval settled at the keyboard while its line still connects closes it. When the
opened line closes with the line still unsaid (item (n)), it chimes and waits, as decided on
2026-11-01; so does a connect that fails. The result window is unchanged. Each opening is billed
like any open line: the connect, the voice's words and the silence before it closes. Amended on
2026-11-05, after item (n) timed when the voice starts on such a line: in the 10 timed runs where it
spoke it started 0.7 to 2.0 s after the connect, and in the 3 of them without a cue, as in use, 0.7
to 1.4 s. Until the owner or the voice speaks on the line, its silence is
`CallMachine.firstWordSeconds` (5 s) instead of 20 s, also after another line arrives; then it
closes and chimes, and a voice that would have started later is cut off.
