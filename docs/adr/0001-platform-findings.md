# 0001. Platform findings: audio path, codex realtime, Claude Code mod API

## Context

LiveBridge is a macOS menu bar app (no Dock icon, `LSUIElement`) plus a Claude Code mod. The
app runs `codex app-server` on the user's ChatGPT login, opens an OpenAI realtime voice session
through it, and relays the voice model's handoffs to a Claude Code session through the mod.
Before any of that is built, a throwaway spike checked the platform facts the design rests on.
This record keeps what was measured, how, and what we decided from it. Items are lettered (a)
to (m) so later work can cite them.

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

Generated protocol (`codex app-server generate-ts --experimental`, 0.166.0), the methods we use:

| Kind | Methods |
|---|---|
| Client requests | `initialize` (then the `initialized` notification), `account/read`, `config/read`, `thread/start`, `mcpServerStatus/list`, `thread/realtime/start`, `thread/realtime/stop`, `thread/realtime/appendText`, `thread/realtime/appendSpeech`, `thread/realtime/appendAudio`, `thread/realtime/listVoices`, `turn/interrupt` |
| Server notifications | `thread/started`, `thread/realtime/started`, `thread/realtime/sdp`, `thread/realtime/itemAdded`, `thread/realtime/transcript/delta`, `thread/realtime/transcript/done`, `thread/realtime/outputAudio/delta`, `thread/realtime/item/started`, `thread/realtime/item/completed`, `thread/realtime/item/transcript/delta`, `thread/realtime/error`, `thread/realtime/closed`, `turn/started`, `turn/completed`, `thread/status/changed`, `mcpServer/startupStatus/updated`, `account/updated`, `warning`, `configWarning`, `remoteControl/status/changed` |
| Server requests (all declined) | `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/permissions/requestApproval`, `execCommandApproval`, `applyPatchApproval`, `item/tool/call`, `item/tool/requestUserInput`, `mcpServer/elicitation/request`, `account/chatgptAuthTokens/refresh`, `attestation/generate`, `currentTime/read` |

`thread/realtime/start` takes `threadId`, `outputModality`, and optionally `version`,
`transport` (`{type:"webrtc", sdp}`, `{type:"websocket"}` or `{type:"existingCall", callId}`),
`prompt`, `includeStartupContext`, `clientManagedHandoffs`, `delegationAckFiller`,
`initialItems` (`[{role: "user"|"developer"|"assistant", text}]`, V3 only, at most 128 items and
8,192 estimated tokens), `voice`, `model` and several rollout knobs. In the WebRTC sessions
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

**(c) Catch-up after the pre-roll: drop silent frames in the page; `appendAudio` is not usable.**
Observed.

- `thread/realtime/appendAudio` (`{threadId, audio:{data, sampleRate, numChannels,
  samplesPerChannel, itemId}}`, 6 s of 24 kHz PCM16) returned `{}` in 8 ms, then the backend
  rejected it (`thread/realtime/error`: "Invalid value: 'input_audio.append'", fixture
  `realtime-error-append-audio-unsupported.json`) and the session closed with reason `error`.
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

**(k) Errors from `thread/realtime/start`.** The call itself returns `{}` immediately; a failure
arrives afterwards as `thread/realtime/error` `{threadId, message}`, followed by
`thread/realtime/closed` with `reason: "error"`. Observed for an unsupported version: "AVAS
realtime calls require realtime v1 or v3" (fixture `realtime-error-version-unsupported.json`).
The error for a ChatGPT plan without realtime **could not be observed**: the tested account has
realtime. A `model` override is ignored on this route. `account/read` returns
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

### Claude Code mod API

**(e) Session title.** Observed against the desktop app's own session list: for each of 5
desktop sessions, the registry file `~/.claude/sessions/<pid>.json` (only `*.json` files were
read; the directory also holds `*.key` files) carried `name` equal to the sidebar title, both for
renamed sessions (`nameSource: "user"`) and for automatic titles (`nameSource` absent). The
record's `hostSessionId` is the desktop's own id; `sessionId` is the engine's session id, which
`$.session.id()` returns as "the transcript file's name" (documented; the equality is inferred).
The record shape is in `plugin/tests/fixtures/adr/session-registry-record.json`. A terminal CLI
session's record was not checked.

**(f) Launching the app.** `$.process` (both `run` and `spawn`) is one noun, documented as "CLI
only". `$.process.spawn` is known to work in a desktop Code tab session (an existing mod relies
on it there); `run` is the same noun under the same note. Observed in the CLI:
`$.process.run(["open", "-g", "-b", "<bundle id>"])` runs with no shell and resolves
`{exitCode, stdout, stderr, …}`; for an unknown bundle id, exit code 1 and the Launch Services
message (fixture `process-run-open-unknown-bundle.json`).

**(g) `$.http.fetch` over a Unix socket.** Observed: 80 sequential requests from four sessions,
median 1 ms, slowest 37 ms; three sessions started at the same time used one shared
`socketPath` and were all served. The types describe a socket as "one per session, in a private
directory"; nothing enforces it.

**(h) `$.prompt.submit`.** Observed: it resolves `{text, origin: {kind: "plugin", name}}` — no
turn id. The plugin's own `prompt.submit` hook (not the calling hook) sees the submission with
that origin, and the main-loop `turn.start` follows it.

**(i) Permission dialog.** Documented only. `tool.check` decides `allow`, `ask` or `deny`, and
an `ask` goes to the mode's decider (the dialog, the auto-mode classifier or a host), so it does
not mean a dialog is shown; its `approver` says who would answer (`person`, `host`, absent). The
settings-hook event `classic.PermissionRequest` (`tool_name`, `tool_input`, base fields incl.
`agent_id`, no `tool_use_id`) runs when a request reaches the person; `classic.Notification`
with `notification_type` reports prompts as notifications. The dialog ends with the tool running
or failing (`classic.PostToolUse`, `classic.PostToolUseFailure`, both with `tool_use_id`), with
`classic.PermissionDenied`, or with the turn ending (`turn.complete`). Not observed: the CLI could
not run a model turn here.

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
`unclassified` and others; a delivery into a running turn carries `turnId` and starts no turn.

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
- Results go to the voice with `appendText` (`role: "user"`, tagged lines). A result that arrives
  while the session is closed cannot make a fresh session speak by itself; how a call-back starts
  speaking is left open by this record and needs a separate decision.
- Realtime failures are read from `thread/realtime/error` (and `closed` with `reason: "error"`),
  not from the start call's response; a message we do not recognise is shown as is. Not logged in
  is `account/read` returning `account: null`.
- MCP isolation, fail closed, without a restart: launch with `--disable` for the tool features
  codex reports as present (including `plugins` and `apps`), read every server name with
  `config/read`, pass `config: {mcp_servers: {<name>: {enabled: false}}}` on `thread/start`, then
  require every `runtimeStatus` from `mcpServerStatus/list` (all pages) to be `disabled`; `null`
  counts as not disabled. `-c 'mcp_servers={}'` is not used.
- Logs keep metadata only: codex messages can carry the home path, the machine's network name
  (`remoteControl/status/changed`) and SDP with addresses.

### Claude Code mod API

- The session label is the `name` of the registry record whose `sessionId` equals
  `$.session.id()`, read from `*.json` files only; the folder name is the fallback.
- The mod launches the app with `$.process.run(["open", "-g", "-b", <bundle id>])`; a rejection or
  a non-zero exit counts as "not launched" and the band asks the user to open the app.
- All sessions share one socket path; polling once a second is cheap.
- The mod records its own submission at `prompt.submit` (`origin.kind == "plugin"`, its own name)
  and takes the next main-loop `turn.start` as the voice turn; it recognises a voice prompt by the
  first line of the engine framing above plus its own marker inside the text, not by the
  trailing sentence.
- A turn's origin is the `origin` of the `prompt.submit` just before its main-loop `turn.start`:
  `plugin` with our name is voice; `task-notification` and other non-person kinds are background;
  `composer`, `bridge` and `sdk` are typed.
- "Waiting for approval" is `classic.PermissionRequest` during a voice turn (or a subagent it
  started); it clears at the next `classic.PostToolUse`, `classic.PostToolUseFailure` or
  `classic.PermissionDenied` for the same tool, or at `turn.complete`. `tool.check` is not used
  for this.

## Consequences

- One microphone permission and, possibly, one Local Network permission per app identity;
  ad-hoc re-signing may ask again after an upgrade.
- Silent-frame dropping shortens pauses in the replayed part of an utterance and leaves up to
  about 0.5 to 1 s of lag until the speaker pauses; the first word is never lost.
- The call-back case (a result after the voice session hung up) has no confirmed way to make the
  voice speak first; it needs its own decision before that feature is built.
- Not yet observed, and to be checked by hand in the desktop app before release: the microphone
  path with a granted permission (and whether it avoids the Local Network prompt), which events
  fire for a permission dialog, the origin of a task-notification turn, `$.process.run` in a
  desktop Code tab session, and the realtime error on a plan without realtime.
- Fixtures under `app/Tests/BridgeCoreTests/Fixtures/adr/` and `plugin/tests/fixtures/adr/` are
  the observed messages with every id, path, address and title replaced by a placeholder, so
  parsers are tested against real shapes. A codex upgrade that changes them should change this
  record first.

## Status

Accepted, 2026-11-01. Items marked inferred or documented-only above stay open until observed.
