# Does closing the voice line save the plan? (GPT-Live billing, 2026-11-04)

The question: LiveBridge closes the realtime voice line after silence and opens a new one when the
owner speaks. Is that a real saving on the owner's ChatGPT plan, or does a new session cost more
than keeping one open, for example because the realtime side caches context per session?

**Answer: closing saves quota. Losing a cache costs nothing, because the voice that LiveBridge runs
is billed by the minute of open session, silence included, not by tokens.** The current defaults
are sound; the timers can become settings with these defaults kept, as long as each setting says
what an open minute costs.

Labels: **documented** (an OpenAI page says so), **source** (read in codex), **inferred** (follows
from the two, not stated anywhere), **not documented** (looked for, not found). The codex source
read is `openai/codex` at `ba057e43758cb19beead2af9df19d10756cc4100` (main, 2026-11-04). The
constants quoted below are the same at `rust-v0.166.0`, the installed CLI. Pages were read on
2026-11-04.

## 1. What LiveBridge runs, and how it is metered

**Which model.** LiveBridge starts realtime `version: "v3"` with no `model`
(`app/Sources/BridgeCore/Codex/RealtimeSession.swift`, `start`). codex then uses its default
frameless model, `gpt-live-1-codex` (**source**: `codex-rs/core/src/realtime_conversation.rs:115-116`,
chosen at `:1641-1650`). With a ChatGPT login the call goes to the ChatGPT backend,
`https://chatgpt.com/backend-api/codex/realtime/calls`, not to `api.openai.com` (**source**:
`codex-rs/model-provider-info/src/lib.rs:86`, `codex-rs/core/src/client.rs:179`,
`codex-rs/codex-api/src/endpoint/realtime_call.rs:213-224`). The token-billed `gpt-realtime-1.5`
is codex's default only for v1 and v2, which LiveBridge does not use.

**On the ChatGPT plan** (**documented**, [Codex pricing, "How much does Voice cost?"](https://learn.chatgpt.com/docs/pricing),
the target of developers.openai.com/codex/pricing):

- "Voice in Desktop uses your existing Codex usage budget at $0.05 per minute."
- Voice and tasks share the plan's usage limits. The task model behind the voice is billed
  separately at its token rates.
- On credit billing (Business, Edu, Enterprise, and Plus or Pro spending extra credits) voice costs
  1.25 credits a minute.
- The limits are the Codex ones: a five-hour window for Plus and standard Business, no five-hour
  window on Pro at present, weekly limits that "may also apply", credits for flexible Enterprise
  and Edu. Current values and reset times are on the usage dashboard
  (`chatgpt.com/codex/settings/usage`) or `/status`.
- An OpenAI staff reply on the community forum (2026-10-24) repeats the $0.05 a minute
  ([thread](https://community.openai.com/t/gpt-live-unavailable-in-normal-chats-and-silently-falls-back-to-work-codex-quota/1393572)).

**Not documented:** how many voice minutes each plan gets, a voice-only reset window, and what a
"minute" is on the ChatGPT side. The help-center article on Codex with a ChatGPT plan could not
be fetched (403).

**What a minute is**, from the API pages for the same model (**documented**,
[GPT-Live 1](https://developers.openai.com/api/docs/models/gpt-live-1),
[voice latency and cost](https://developers.openai.com/api/docs/guides/voice-latency-cost)):
$0.05 a minute, "billed per second", not rounded up to a whole minute. Active session time covers
the owner speaking, the voice speaking, both silent, and the backend working. Muting the microphone
does not close the session. **Inferred:** the plan charge is the same meter, since it is the same
model at the same price; no ChatGPT page says so in as many words.

**A separate voice meter?** Four open codex issues from late September 2026
([#49409](https://github.com/openai/codex/issues/49409),
[#49405](https://github.com/openai/codex/issues/49405),
[#49331](https://github.com/openai/codex/issues/49331),
[#49455](https://github.com/openai/codex/issues/49455)) report voice stopping with "usage limit
reached" while the Codex weekly allowance still had 27 to 45 % left; one mentions a "voice usage
meter". OpenAI has not answered. So voice may hit a limit of its own before the shared budget runs
out; **not documented** either way.

**What LiveBridge can see.** Nothing from codex. The v3 event parser drops
`session.usage.updated` (**source**:
`codex-rs/codex-api/src/endpoint/realtime_websocket/protocol_frameless_bidi.rs:15-35`), the
realtime code reads no usage or rate limits, and the plan buckets (`account/rateLimits/read`, from
`/wham/usage`) have no voice field (**source**: `codex-rs/backend-client/src/client/rate_limit_resets.rs:130-131`,
`codex-rs/app-server-protocol/src/protocol/v2/account.rs:694-707`). LiveBridge's own
`UsageMeter` (minutes the line was open) is therefore the best measure the app has, and by the
metering above it is the billed quantity, give or take connection setup.

## 2. Caching, and what a new session pays for

**Prompt caching does not enter the voice price.** GPT-Live is billed by duration; the API pages
mention cached input only for the backend task model (**documented**,
[GPT-Live guide](https://developers.openai.com/api/docs/guides/live)). Re-sending the instructions
and the conversation to a new session costs no voice quota (**inferred** for the plan route, which
documents only the per-minute price).

Caching does exist for the token-billed realtime models (`gpt-realtime*`): automatic, best effort,
prefix-based, reported as `input_token_details.cached_tokens`, kept in memory for about 5 to 10
minutes of inactivity and up to an hour (**documented**,
[voice latency and cost, "Realtime API costs"](https://developers.openai.com/api/docs/guides/voice-latency-cost),
[prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)). Whether a new
realtime session with the same prefix hits that cache is **not documented**. None of it applies
to LiveBridge's v3 line.

**What each new line sends** (**source**, plus LiveBridge's code):

- codex's instructions are the request's `prompt` (LiveBridge's `VoicePrompt`, about 4.5 KB, plus
  up to 2,000 characters of the owner's own prompt), or codex's built-in one
  (`codex-rs/core/src/realtime_prompt.rs:5-24`).
- codex's startup context (up to 5,300 tokens of recent threads and the workspace tree,
  `codex-rs/core/src/realtime_context.rs`) is off: LiveBridge sends `includeStartupContext: false`.
- `initialItems`: the target session's `[CONTEXT]` line, open tasks and the newest conversation
  lines, at most 128 items and an estimated 8,192 tokens
  (`app/Sources/BridgeCore/Call/Continuity.swift`, enforced by codex at
  `codex-rs/core/src/realtime_conversation.rs:1616-1640`).
- Every open also makes a new ephemeral codex thread (`thread/start`) and checks its MCP servers.
  That is local work in codex, not a model call.

**Resuming a closed session is not possible through codex.** The GPT-Live API can fork a stored
session (`store: true`, `POST /v1/live/sessions/{id}/fork`), but codex's
`ThreadRealtimeStartParams` has no `store` or fork parameter; its `existingCall` transport attaches
to a call the client already made and is not a resume (**source**:
`codex-rs/app-server-protocol/src/protocol/v2/realtime.rs:193-299`,
`codex-rs/core/src/realtime_conversation.rs:1451-1468`). Re-seeding with `prompt` and
`initialItems`, as LiveBridge does, is the only way, and it is the pattern OpenAI's own guide
recommends: "Close idle sessions and resume", with an app-side inactivity timeout, local speech
detection that buffers the opening words, and restored context (**documented**,
[live conversations](https://developers.openai.com/api/docs/guides/live-conversations)).

## 3. What an idle open line costs

- **GPT-Live: the full rate.** A silent minute costs the same $0.05 as a spoken one. "Closing saves
  $0.05 per minute of idle voice time", says the cost guide, to be weighed against reconnection
  cost and the interruption (**documented**,
  [voice latency and cost](https://developers.openai.com/api/docs/guides/voice-latency-cost)).
- **Per-session overhead.** On the API, creating a WebRTC session bills 15 s while it initialises,
  credited against the session's duration, so only a session shorter than 15 s pays for time it
  did not use (**documented** for `POST /v1/live/sessions`; **not documented** for the ChatGPT
  backend route codex uses).
- **Maximum length.** GPT-Live has an `expired` close reason, but no stated limit (**not
  documented**; the token-billed Realtime API stops at 60 minutes).
- For contrast, the token-billed models charge nothing for an open connection, and with voice
  detection on, empty audio is not input (**documented**). That is where the owner's intuition
  comes from; it does not hold for GPT-Live.

**How the line stops.** On WebRTC, `thread/realtime/stop` only closes codex's sideband socket and
deliberately does not send `session.close`: "The session belongs to the frontend" (**source**:
`codex-rs/core/src/realtime_conversation/sideband.rs:195-207`). **Inferred:** billing stops when
the page's peer connection closes. LiveBridge's audio page does close it (`dropPeer` in
`app/Sources/LiveBridge/Resources/audio/audio.js`); a change that left the peer connection open
after `thread/realtime/stop` would keep the meter running.

## 4. LiveBridge's timers, priced

The timers are in `app/Sources/BridgeCore/Call/CallMachine.swift` (`silenceSeconds`,
`noiseCapSeconds`, `resultWindowSeconds`, `graceMilliseconds`); the flows are in
[the architecture overview](../architecture/overview.md#silent-hang-up). At $0.05 a minute:

| Timer | Default | What it costs at most | What closing earlier would lose |
| --- | --- | --- | --- |
| Silence after the last speech, words or reply | 20 s | about $0.017 of open silence per exchange | a thinking pause longer than the timer ends the line; the next words reopen it in about 1 s (pre-roll keeps them) |
| Sound without words (TV, music) | 90 s | $0.075 per noise episode | the same, in a noisy room |
| Result window after a handoff | 120 s | $0.10 per handoff whose result is slow | results spoken unprompted: a new session cannot speak first, so a result that comes after the close only chimes and waits ([ADR 0001](../adr/0001-platform-findings.md) (b)) |
| Grace before a held result is said | 0.8 s | nothing measurable | it does not open or close the line |

**What close-and-reopen costs.** In voice minutes, about nothing. Even if the ChatGPT route charges
the API's 15 s at creation, it is credited against the session, and no LiveBridge line that
connects lasts under 20 s, because the silence timer alone keeps it open that long (**inferred**).
Reopening the next session then costs only time not spent open. The real costs are not money:

- about 1 s from speech to a connected line (median 1.06 s to `session.started`,
  [ADR 0001](../adr/0001-platform-findings.md) (d)), covered by the 2 s pre-roll;
- the voice cannot speak first after a start, so anything that arrives while the line is closed
  waits for the owner's next words;
- the new voice knows only what `initialItems` carries (24 lines, 8,192 estimated tokens), not
  the closed session's full audio context.

**Break-even.** Keeping the line open through a gap of `g` seconds costs `g` seconds; closing costs
nothing in minutes. So closing saves whenever the owner is not about to speak, and a longer silence
timer buys only fewer reconnects. As a rough scale: an always-open line is $3 of budget an hour;
LiveBridge's 20 s tail after each exchange is under 2 cents' worth, and a slow handoff adds up to
10 cents (2 minutes).

**Uncertainty.** The plan's metering of voice minutes is inferred from the API, not stated for
ChatGPT. The backend's 15 s creation charge on the codex route is unknown (it does not change the
conclusion while every line lasts at least 15 s). A separate voice limit may exist (the issues
above). What a $0.05 minute is as a fraction of a Plus five-hour window is not published, so the
app cannot turn minutes into "percent of your limit".

## 5. Recommendation for the timer settings

Keep the defaults. Each timer is worth exposing, with the range and the line below it:

- **Hang up after silence: 20 s** (sensible range 10 to 60 s). Below 10 s a thinking pause hangs
  up mid-conversation; above 60 s it mostly pays for silence. *"The voice costs your Codex budget
  per minute the line is open, silence included (OpenAI: $0.05 a minute). A shorter wait saves
  budget; a longer one reconnects less often."*
- **Wait for Claude's answer: 2 min** (0 to 5 min). This is the one timer whose value is not a
  saving question: it decides whether a slow answer is spoken unprompted or chimes and waits.
  *"Up to this long after you hand Claude a request, the line stays open so the voice can say the
  answer as soon as it comes. Each minute is billed like talking. Set it to 0 to hear answers only
  when you next speak."*
- **Hang up on noise without words: 90 s** (30 to 180 s). Keep it above the silence timer;
  lowering it mostly helps people who work with music on.
- The 0.8 s grace is not a cost and should stay internal.

Do not offer "keep the line open" as a saving: on GPT-Live it is the most expensive setting, about
$3 of budget an hour. If the owner wants it for the voice to speak first, label it as costing that.

Follow-ups this research suggests, outside its own change:

- The menu could show the open minutes as budget ("about $0.40 of Codex budget today"), with the
  caveat that the plan's own meter is authoritative.
- Re-check the pricing page and the four codex issues before 0.3.0: a published voice allowance
  or a reported voice meter would let the app show a fraction of the limit.
