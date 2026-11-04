# Does closing the voice line save the plan? (GPT-Live billing, 2026-11-04)

The question: LiveBridge closes the realtime voice line after silence and opens a new one when the
owner speaks. Is that a real saving on the owner's ChatGPT plan, or does a new session cost more
than keeping one open, for example because the realtime side caches context per session?

**Answer: closing saves quota. Losing a cache costs nothing, because the voice LiveBridge runs is
billed per second of open session at a per-minute rate, silence included, not by tokens.** The
current timer defaults are sound.

Labels: **documented** (an OpenAI page says so), **source** (read in codex), **inferred** (follows
from those, not stated anywhere), **not documented** (looked for, not found). codex was read at
`openai/codex` `ba057e43758cb19beead2af9df19d10756cc4100` (main, 2026-11-04); the two model
constants are the same at `rust-v0.166.0`, the installed CLI. Pages were read on 2026-11-04.

## 1. What LiveBridge runs, and how it is metered

**Which model** (**source**). LiveBridge starts realtime `version: "v3"` with no `model`
(`app/Sources/BridgeCore/Codex/RealtimeSession.swift`, `start`). Unless the owner's codex config
sets `experimental_realtime_ws_model`, codex then uses `gpt-live-1-codex`
(`codex-rs/core/src/realtime_conversation.rs:115-116`, chosen at `:1641-1650`). With a ChatGPT
login the call goes to `https://chatgpt.com/backend-api/codex/realtime/calls`, not to
`api.openai.com` (`codex-rs/model-provider-info/src/lib.rs:86`, `codex-rs/core/src/client.rs:179`,
`codex-rs/codex-api/src/endpoint/realtime_call.rs:213-224`).

**The plan's price** (**documented** for ChatGPT Voice in the desktop app,
[Codex pricing, "How much does Voice cost?"](https://learn.chatgpt.com/docs/pricing)):
"Voice in Desktop uses your existing Codex usage budget at $0.05 per minute." Voice and tasks
share the plan's limits: a five-hour window for Plus and standard Business, none on Pro at present,
weekly limits that "may also apply"; on credit billing voice is 1.25 credits a minute. Values and
reset times are on `chatgpt.com/codex/settings/usage` or `/status`. An OpenAI staff reply about the
same app repeats the figure
([forum, 2026-10-24](https://community.openai.com/t/gpt-live-unavailable-in-normal-chats-and-silently-falls-back-to-work-codex-quota/1393572)).

**Inferred:** the same price applies to LiveBridge's line. No page names `codex app-server`
realtime; the evidence is that the page is Codex's own pricing, that voice there draws on the
Codex budget, and that codex's v3 default is a GPT-Live model on the Codex backend.

**What a minute is.** The API page for `gpt-live-1`, the API model of the same family, bills
"$0.05 per minute, billed per second", not rounded up, and counts the owner speaking, the voice
speaking, both silent and the backend working; muting does not close the session (**documented**,
[GPT-Live 1](https://developers.openai.com/api/docs/models/gpt-live-1),
[voice latency and cost](https://developers.openai.com/api/docs/guides/voice-latency-cost)). That
the plan meters `gpt-live-1-codex` the same way is **inferred**. **Not documented:** voice minutes
per plan, a voice-only reset window, and what a "minute" is on the ChatGPT side (the help-center
article on Codex plans returned 403).

**A separate voice meter?** Four open codex issues
([#49409](https://github.com/openai/codex/issues/49409),
[#49405](https://github.com/openai/codex/issues/49405),
[#49331](https://github.com/openai/codex/issues/49331),
[#49455](https://github.com/openai/codex/issues/49455)) report voice stopping with "usage limit
reached" while the Codex allowance still had 27 to 49 % left; one mentions a "voice usage meter".
A comment on #49331 points at [#49322](https://github.com/openai/codex/issues/49322) (usage shown
doubled). So either voice has a limit of its own or the accounting has a bug; OpenAI has not
answered (**not documented**).

**What LiveBridge can see.**

- codex passes on no usage: its v3 parser drops `session.usage.updated` (**source**:
  `codex-rs/codex-api/src/endpoint/realtime_websocket/protocol_frameless_bidi.rs:15-35`).
- The page's own data channel does carry it: on this login `session.usage.updated` reports
  `usage.audio_duration_ms` ([ADR 0001](../adr/0001-platform-findings.md) (b)). Whether that is
  the plan's meter is **not documented**; the API's field is `usage.seconds`.
- `account/rateLimits/read` has no named voice field, but `rate_limits_by_limit_id` is an open map
  keyed by metered limit id (**source**: `codex-rs/app-server-protocol/src/protocol/v2/account.rs:367-368`),
  so a voice bucket could appear there under its own id.
- `UsageMeter` counts the minutes the line was open, as the app measures them.

## 2. Caching, and what a new session pays for

**Prompt caching does not enter the voice price.** GPT-Live is billed by duration; the API pages
mention cached input only for the backend task model (**documented**,
[GPT-Live guide](https://developers.openai.com/api/docs/guides/live)). Sending the instructions and
the conversation to a new session again therefore costs no voice quota (**inferred** for the plan).
Caching applies to the token-billed `gpt-realtime*` models, which LiveBridge does not use.

**What each new line sends** (**source**, plus LiveBridge's code):

- the instructions: LiveBridge's `VoicePrompt` (about 4.5 KB) plus up to 2,000 characters of the
  owner's prompt, sent as `prompt` (`codex-rs/core/src/realtime_prompt.rs:5-24`);
- no codex startup context: LiveBridge sends `includeStartupContext: false`;
- `initialItems`: the target's `[CONTEXT]` line, open tasks and newest conversation lines, at most
  128 items and an estimated 8,192 tokens (`app/Sources/BridgeCore/Call/Continuity.swift`, enforced
  at `codex-rs/core/src/realtime_conversation.rs:1616-1640`);
- locally, a new ephemeral codex thread: LiveBridge reads `config/read` and starts the thread with
  every configured MCP server disabled, then checks that codex reports them disabled
  (`app/Sources/BridgeCore/Codex/RealtimeSession.swift`, `establish`). No model call.

**A closed session cannot be resumed through codex.** The GPT-Live API can fork a stored session
(`store: true`, `POST /v1/live/sessions/{id}/fork`), but codex's `ThreadRealtimeStartParams` has no
`store` or fork parameter, and its `existingCall` transport attaches to a call the client already
made (**source**: `codex-rs/app-server-protocol/src/protocol/v2/realtime.rs:193-299`,
`codex-rs/core/src/realtime_conversation.rs:1451-1468`). Seeding a new session with `prompt` and
`initialItems`, as LiveBridge does, is the only way, and it is the pattern OpenAI's guide
recommends: "Close idle sessions and resume" (**documented**,
[live conversations](https://developers.openai.com/api/docs/guides/live-conversations)).

## 3. What an open line costs

- **Silence costs the full rate.** "Closing saves $0.05 per minute of idle voice time", to be
  weighed against reconnection cost and the interruption (**documented**,
  [voice latency and cost](https://developers.openai.com/api/docs/guides/voice-latency-cost)).
- **Per-session overhead.** On the API, creating a WebRTC session bills 15 s while it initialises,
  "credited against duration charges once the session starts running" (**documented** for
  `POST /v1/live/sessions`; **not documented** for the route codex uses). Read plainly, only a
  session shorter than 15 s pays for time it did not use (**inferred**).
- **Maximum length.** GPT-Live has an `expired` close reason but no stated limit (**not
  documented**).
- **How billing stops.** On WebRTC, `thread/realtime/stop` only closes codex's sideband socket and
  does not send `session.close`: "The session belongs to the frontend" (**source**:
  `codex-rs/core/src/realtime_conversation/sideband.rs:195-207`). So billing stops when the page's
  peer connection closes (**inferred**). The audio page closes it (`dropPeer` in
  `app/Sources/LiveBridge/Resources/audio/audio.js`); a change that left it open would keep the
  meter running.

## 4. LiveBridge's timers, priced

The timers are in `app/Sources/BridgeCore/Call/CallMachine.swift`; the flows are in
[the architecture overview](../architecture/overview.md#silent-hang-up). At $0.05 a minute:

| Timer | Default | What it costs, about | What a shorter value loses |
| --- | --- | --- | --- |
| Silence after the last speech, words or reply | 20 s | $0.017 per exchange | a longer thinking pause ends the line; the next words open it again |
| Sound without words (TV, music) | 90 s | $0.075 per noise episode | the same, in a noisy room |
| Result window after a handoff (re-armed by each handoff) | 120 s | $0.10 per handoff whose result is slow | the result spoken on the open line; on `dev` a result after the close chimes and waits |
| Grace before a held result is said | 0.8 s | nothing | it does not open or close the line |

**Closing and reopening costs about nothing in voice minutes.** Even if the codex route charges
the API's 15 s at creation, a line that ends by the silence timer has been open at least 20 s
(**inferred**). Keeping the line open through a gap costs the gap; closing costs only the next
connect. What closing does cost is not money: about 1 s from speech to a connected line (median
1.06 s, [ADR 0001](../adr/0001-platform-findings.md) (d)), covered by the 2 s pre-roll; and the new
voice knows only what `initialItems` carries (24 lines, 8,192 estimated tokens). A longer silence
timer buys fewer reconnects, nothing else. For scale, a line kept open always costs $3 of budget an
hour.

What a minute is as a fraction of a Plus five-hour window is not published, so the app cannot turn
minutes into "percent of your limit".

## 5. What this means for the timer settings

Input for the settings design, which decides: keep the defaults, and expose each timer with a
line that says the line is billed per minute open (linking here rather than quoting a price that
will drift).

- **Hang up after silence: 20 s**, sensibly 10 to 60 s. Below 10 s a thinking pause hangs up
  mid-conversation; above 60 s it mostly pays for silence.
- **Wait for Claude's answer: 2 min**, 0 to 5 min. It decides whether a slow answer is said on the
  open line or later, not only what it costs.
- **Hang up on noise without words: 90 s**, 30 to 180 s, kept above the silence timer.
- The 0.8 s grace is not a cost and stays internal.

Do not offer "keep the line open" as a saving: it is the most expensive setting.

Follow-ups: log `audio_duration_ms` from the data channel next to `UsageMeter` and compare the
two; read `rate_limits_by_limit_id` while a line is open to see whether a voice bucket appears;
re-check the pricing page and the four codex issues before 0.3.0.
