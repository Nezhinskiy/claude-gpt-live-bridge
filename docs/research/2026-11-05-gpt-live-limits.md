# What limits GPT-Live voice, and what happens when it runs out (2026-11-05)

Follow-up to [the billing note of 2026-11-04](2026-11-04-gpt-live-billing.md), which settles that
the line LiveBridge runs is billed per second open at a per-minute rate, silence included, from
the plan's Codex budget. This note does not repeat its facts; it asks what limits that budget
has, what the owner sees when it runs out, whether the timers changed since then pay for unused
time, and which sentences in the docs need fixing for 0.4.0.

Labels as in the first note: **documented** (an OpenAI page says so), **source** (read in codex),
**inferred** (follows from those, not stated anywhere), **not documented** (looked for, not
found). codex was read at `openai/codex` `0327a3ec34fd8fe9454eb57151a3798f127a53bf` (main,
2026-11-05); every codex path cited below has the same code at `rust-v0.166.0`, the tested CLI.
LiveBridge was read at `93ba99f`. Pages were read on 2026-11-05. Nothing here opened a voice
session.

## 1. Limits by plan

**Which plans have it** (**documented**, [Codex pricing](https://learn.chatgpt.com/docs/pricing)):
the feature table lists Voice for Plus, Pro, Business and Enterprise; Free, Go and Edu are not
listed (**not documented** for them). Desktop voice is not available with an API key.

**Same budget as coding tasks?** OpenAI's pages disagree.

- The pricing page: "Voice and tasks share your plan's usage limits", at $0.05 a minute of the
  Codex budget, or 1.25 credits a minute once a plan buys credits (**documented**; the price is in
  the first note).
- The help centre's [Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540)
  (updated about 2026-11-04) says voice used inside Codex on desktop "is metered separately",
  while tasks voice starts use the shared pool (**documented**). It may mean only that voice is
  counted per minute rather than per token (**inferred**).
- The four codex issues the first note cites (voice blocked with 27 to 49 % of the Codex allowance
  left) are still open, with no OpenAI reply and no new comments since 2026-09-30
  ([#49409](https://github.com/openai/codex/issues/49409),
  [#49405](https://github.com/openai/codex/issues/49405),
  [#49331](https://github.com/openai/codex/issues/49331),
  [#49455](https://github.com/openai/codex/issues/49455)).

So: voice spends the Codex budget, and may also have a gate of its own; which one stops it first
is **not documented**.

**Windows** (**documented**, pricing page and the
[Astra usage article](https://help.openai.com/en/articles/20001516)): the Codex budget has a
five-hour window on Plus and standard Business, none on Pro, and weekly limits that may apply. A
user's blocked voice call carried `limit_window_minutes: 10080`, the weekly window, on Pro
([#37619](https://github.com/openai/codex/issues/37619), 2026-11-03; a report, not a doc).
**Not documented:** a voice-only minute budget, daily cap or reset for Codex voice on any plan.

**Not the same as ChatGPT Voice.** [ChatGPT Voice](https://help.openai.com/en/articles/20001274-chatgpt-voice)
in chat has its own per-plan hours over a rolling 24 hours (for example Plus 3 h, Pro $100 15 h,
Business Standard 3 h then credits) and says "Voice in the desktop app has separate pricing and
limits" (**documented**). Those hours do not apply to LiveBridge's line and must not be quoted for
it.

**Concurrency.** "Only one voice chat can be active across the ChatGPT desktop app at a time"
(**documented**, [Voice in Codex](https://learn.chatgpt.com/docs/features/voice)). Whether a
LiveBridge line and the desktop app's voice block each other on one account is **not documented**
(**inferred** plausible, since both use the same backend route). The API counts `gpt-live-1`
rate limits in concurrent sessions; that is the API, not the plan.

**Maximum session length.** The API has an `expired` close reason with no stated length; its
create-session page mentions a 2-hour cap for connected (SIP) calls (**documented**,
[Live reference](https://developers.openai.com/api/reference/resources/live/methods/create)). A user
saw new Codex voice sessions report about 7,200 s remaining
([#55494](https://github.com/openai/codex/issues/55494)), so about 2 hours (**inferred**). LiveBridge
never comes near it: its longest line is the 2-minute result window, re-armed by each handoff.

**Coming in December** (**documented**,
[help article 20001625](https://help.openai.com/en/articles/20001625), updated about 2026-11-01):
the Plus, Pro and Business allowance will be shared across ChatGPT and Codex and measured in
tokens. Voice is not mentioned. The first note's per-minute price may change then; the docs
should link to OpenAI rather than repeat a figure.

## 2. Running out

### What codex sends (**source**)

**At open.** LiveBridge's `thread/realtime/start` gets an empty success reply at once; the call
itself is made later, when codex POSTs the page's SDP offer to `realtime/calls`
(`codex-rs/app-server/src/request_processors/turn_processor.rs:1256-1330` submits the op;
`codex-rs/core/src/realtime_conversation.rs:757-765` makes the call). A failure there becomes a
`thread/realtime/error` notification, `{threadId, message}`, and nothing else: no
`thread/realtime/closed`, no error code (`realtime_conversation.rs:1332-1365`,
`codex-rs/app-server/src/bespoke_event_handling.rs:623-630`,
`codex-rs/app-server-protocol/src/protocol/v2/realtime.rs:471-487`). The structured
`codexErrorInfo` that a coding turn gets (`UsageLimitExceeded`) is not on this path: the
realtime error is the error's `Display` text.

The text depends on the HTTP answer (`codex-rs/codex-api/src/api_bridge.rs:208-262`,
`codex-rs/protocol/src/error.rs:198,721-870`):

| Backend answer | `message` codex sends |
| --- | --- |
| 429, `error.type: "usage_limit_reached"` | "You’ve hit your usage limit." plus a plan-specific tail: Plus "Upgrade to Pro (…), visit https://chatgpt.com/settings/usage to purchase more credits or try again at *time*."; Pro "Visit … to purchase more credits or try again at *time*."; Business/Team/Enterprise-CBP "To get more access now, send a request to your admin or try again at *time*."; Enterprise/Edu and unknown "Try again at *time*." (or "Try again later."); Free/Go "Upgrade to Plus to continue using Codex …". A named limit other than `codex` gives "You’ve hit your usage limit for *name*. Switch to another model now, or try again at *time*."; workspace credit and spend-cap states have their own sentences ("Your workspace is out of credits. …", "You hit your spend cap …"). |
| 429, `usage_not_included` | "To use Codex with your ChatGPT plan, upgrade to Plus: …" (codex's `UsageNotIncluded` text) |
| 429, `insufficient_quota` and similar codes | "Quota exceeded. Check your plan and billing details." |
| 429, any other body | "exceeded retry limit, last status: 429 Too Many Requests" |

Which of these the realtime route returns when voice runs out is **not documented**. A Codex
desktop user did see the first row's Pro sentence ("You’ve hit your usage limit. Visit … to
purchase more credits or try again at 11:33 PM.") with `type: "usage_limit_reached"`
([#37619](https://github.com/openai/codex/issues/37619)), so a 429 at open is the likely shape.

**Mid-line.** The WebRTC call belongs to the page; codex watches it over a sideband WebSocket. A
server `error` event on that socket becomes `thread/realtime/error` with the event's `message`
(`codex-rs/codex-api/src/endpoint/realtime_websocket/protocol_frameless_bidi.rs:28`,
`protocol_common.rs:68-83`), and the conversation ends with `thread/realtime/closed`, reason
`"error"`; a socket that drops gives the mapped transport error, then `"error"`, or
`"transport_closed"` if it closed cleanly (`realtime_conversation.rs:1869-1871,1912-1934,
2377-2383,2925-2940`). Those three strings, plus `"requested"`, are the only close reasons codex
sends; the API's own close reasons (`close_requested`, `expired`, `content`, `remote_hangup`,
`connection_lost`; none is about quota) are not passed on.

**After `session.started`.** Two reports show a usage gate that fires seconds into a session:
the service sends an `error` (type `service_unavailable_error`, code `usage_check_failed`) on the
WebRTC **data channel**, not the sideband, and the call drops; codex sees only
`transport_closed` ([#55531](https://github.com/openai/codex/issues/55531),
[#55494](https://github.com/openai/codex/issues/55494); reports, not docs). The desktop app
showed "Voice chat error: Unable to verify usage availability." in the same case. Whether an
exhausted budget during a call arrives the same way is **not documented**.

### What LiveBridge does with it today (**source**, LiveBridge `93ba99f`)

1. `RealtimeSession` keeps the message as `lastError` and fails the pending open with
   `CodexProblem.realtimeError(message)` (`app/Sources/BridgeCore/Codex/RealtimeSession.swift:296-299`).
   A later `closed` reports the same error, or "The voice session closed (*reason*)." when there
   was none (`:300-305`).
2. The sentence is "Realtime voice failed (codex said: *message*)." plus a guessed hint
   (`app/Sources/BridgeCore/Codex/CodexLaunch.swift:40-55`). The hint looks for login words, or
   for the word "plan" or "realtime … not available"; none of codex's usage-limit sentences has
   either, so they get no hint. "Quota exceeded. Check your plan and billing details." does
   contain "plan", and gets "Your ChatGPT plan may not include realtime voice in Codex.", which is
   wrong for an exhausted budget.
3. `connectFailed` (at open) and `remoteClosed` (mid-line) both show the problem and hang up to
   `listening`, not `off` (`app/Sources/BridgeCore/Call/CallMachine.swift:175-177`). The sentence
   goes to the menu banner and the Claude Code band (`problem` on the status). `CodexHelp` offers
   help only for "not installed" and "not signed in"
   (`app/Sources/BridgeCore/Problem.swift`, `help`).
4. So at the limit the call stays on: the owner's next words open a new line, which fails the same
   way; an answer that opens the line fails and chimes. An attempt refused at the POST should cost
   nothing (**inferred**); one refused after `session.started` may be billed for its seconds, or
   the 15 s floor (§3). Either way the words spoken into it are lost and the same failure repeats
   until the reset.
5. The audio page acts on the data channel only until `session.started`
   (`app/Sources/LiveBridge/Resources/audio/audio.js:196-199`) and has no handler for the peer's
   connection state. A data-channel `error` such as `usage_check_failed` is therefore lost; the
   owner sees "The voice session closed (transport_closed).", or nothing until the silence timer
   closes the line if codex's sideband stays up.

So for a 429 at open the owner gets codex's own sentence, which is clear ("You’ve hit your usage
limit. … try again at *time*."), but wrapped as "Realtime voice failed", and nothing stops the
retries. For an unrecognised 429 body the owner sees "exceeded retry limit, last status: 429",
and for a gate after `session.started` only "transport_closed": neither says anything about a
limit.

### Recommendation (implemented, with changes)

PR #37 implemented this, except for the peer's connection state and the rate-limit read. It matches
with `contains`, not "starts"; says only a spent budget is a limit; ends the call on a plan without
voice too; and recognises the data channel's errors by their code.

- Recognise a limit: a `realtimeError` whose text starts "You’ve hit your usage limit", "You hit
  your spend cap", "Your workspace is out of credits" or "Quota exceeded", or contains
  "last status: 429". codex sends no code on this path, so matching its English wording is the
  only signal; keep the match in one place and test it against codex's strings.
- Say it without "failed": **"Your ChatGPT plan's usage limit is reached, so the voice is paused.
  Claude Code keeps working."** followed by codex's own sentence, which carries the reset time and
  the plan's way to get more ("… try again at 11:33 PM."). Do not call it a "voice limit": which
  limit stopped it is not known (§1).
- Keep the data channel's messages after `session.started` and pass an `error` event's `code` and
  `message` to the bridge, so a `usage_check_failed` or similar shows its own words instead of
  "transport_closed". A peer whose connection state goes `failed` or `closed` should close the
  line too.
- Stop the retries: end the call (`off`, as a Stop would) rather than hang up to `listening`, so
  speech does not open lines that fail, and chime and keep answers waiting as a failed connect
  already does. Start then tries once more.
- Do not tell the owner the plan lacks voice for a quota error: drop the "plan" hint for "Quota
  exceeded".
- Optionally, after such an error read `account/rateLimits/read` for the reset time:
  `rateLimitsByLimitId` and `ordinaryUsageAllowed`
  (`codex-rs/app-server-protocol/src/protocol/v2/account.rs:361-368`, snapshot fields
  `:694-706`). Whether a voice bucket appears there is still the first note's open follow-up.

## 3. The first-word wait and the 15 s overhead

**What runs now** (**source**). A line an answer opens arms `CallMachine.firstWordSeconds` (5 s)
when it connects (`CallMachine.swift:120,133,174`); the owner's speech, the owner's recognised
words or the voice's first transcript delta switch it to the usual 20 s. `connected` is the data
channel's `session.started` (`app/Sources/LiveBridge/Resources/audio/audio.js:191-205`), about 1 s
after the open began (median 1.06 s, [ADR 0001](../adr/0001-platform-findings.md) (d)). The
backend session exists from codex's POST, before that.

**What a silent reopened line is billed** (**inferred**). The session lives about 1 s connecting
plus 5 s, so about 6 s.

- If the API's rule holds on the codex route (15 s billed at creation, credited against the
  duration once running; first note §3), such a line pays 15 s, of which about 9 s are unused:
  about $0.0075 a time. **Not documented** for the route codex uses.
- If it does not, the line pays about 6 s, $0.005.
- Either way it pays less than before the change, when such a line waited the 20 s silence timer
  and lived at least 21 s ($0.0175).

**What changes in the first note's conclusions.**

- §4 says a line that ends by the silence timer "has been open at least 20 s", so the 15 s
  overhead never matters. That no longer holds for a reopened line nobody speaks on: it is the one
  case that may pay for unused time. The amounts are fractions of a cent, so the conclusion that
  closing saves quota stands.
- Under the 15 s rule, a first-word wait up to about 14 s (15 s less the connect) costs nothing
  more than 5 s does. In ADR 0001 (n) the voice that spoke unprompted ended its first segment
  5.4 to 7.7 s after `live`; it began speaking earlier, so most such voices beat 5 s, but the
  overview already says "a voice that starts later is cut off". If the rule is confirmed, a wait
  of about 12 s would cut off fewer voices at no extra cost; if it is not, each extra second
  costs $0.0008 per silent reopen. The settings design decides; measuring the time from `live`
  to the first `assistantSpeaking` in a few reopened lines would settle it.
- The same overhead applies to any line closed soon after it opened: a line withdrawn while it
  connects (the owner answered the question at the keyboard), a Stop, or a new target. Each may
  pay up to 15 s (**inferred**).
- `UsageMeter` counts from `connected` to the close (`app/Sources/BridgeCore/Bridge.swift:257-258`),
  so the menu's minutes leave out the connect time and any 15 s floor: they are a lower bound on
  what the plan counts.

## 4. Docs that need fixing for 0.4.0

Read at `93ba99f`: `README.md`, the six `README.*.md`, `site/index.html`, `SECURITY.md`. The
wording below describes the code as it is; if the recommendation in §2 ships, the limit
sentences change with it.

| # | Where | Now | Problem | Recommended |
| --- | --- | --- | --- | --- |
| 1 | `README.ru.md:315-316`, `README.es.md:314-315`, `README.fr.md:331-332`, `README.uk.md:311-312`, `README.hi.md:302-303`, `README.zh-CN.md:234` | "The menu shows the minutes … measured by the app; how your plan meters realtime voice is not published." | **Outdated.** OpenAI's pricing page has published it since the first note: per minute of the Codex budget. The English README already says so; the translations lag and do not link the note. | Translate the English bullet as amended in row 2, with its link to the research. |
| 2 | `README.md:302-305` | "The menu shows the minutes the line was open, as measured by the app. OpenAI prices desktop voice per minute of your Codex budget, and on its API the same model family bills silence too (details); your plan's own usage page is the authority." | **Accurate, incomplete.** The meter starts at `connected`, so it leaves out the connect and any 15 s floor (§3); nothing says what happens at the limit. | "The menu shows the minutes the line was open, counted by the app from when the voice connects, so your plan may count a little more. OpenAI prices desktop voice per minute of your Codex usage budget, and on its API the same model family bills silence too ([details](docs/research/2026-11-04-gpt-live-billing.md), [limits](docs/research/2026-11-05-gpt-live-limits.md)); your plan's own usage page is the authority." |
| 3 | `README.md:364` Known limitations, and each translation's | nothing about the limit | **Missing.** At the limit the call stays on and every speech or reopening answer tries again and fails (§2). | New item: "When your plan's usage limit is reached, the line does not open and the menu and the band show codex's message, for example "You’ve hit your usage limit … try again at *time*"; a limit that stops a line already open may show only "The voice session closed (transport_closed)." The call stays on, so each time you speak it tries again; press Stop until the limit resets. Claude Code itself keeps working." |
| 4 | `README.md:53-54,86-87`, the same two places in each translation, `site/index.html:136` | "a ChatGPT plan with / that includes realtime voice" | **Unsupported as a test the owner can apply**: no OpenAI page says "realtime voice"; the pricing page lists Voice for Plus, Pro, Business and Enterprise (§1). | "a ChatGPT plan whose Codex includes voice (Plus, Pro, Business or Enterprise, per [OpenAI's Codex pricing](https://learn.chatgpt.com/docs/pricing))". Re-check the list before each release. |
| 5 | `README.md:302-305` and the translations' row 1 | no mention of the shared budget | **Missing, and contested** (§1): the pricing page says voice and tasks share the plan's limits; the help centre says desktop voice is metered separately. | Add after the price: "Voice and Codex tasks share your plan's limits, so a long call leaves less for coding." Only if the orchestrator accepts the pricing page as the authority; otherwise say nothing about sharing. |
| 6 | `site/index.html:189` | "The line opens when you speak, closes once the talk goes quiet, and after a handoff stays open a little longer for Claude’s answer." | **Incomplete.** Claude's answer, question or approval notice also reopens a closed line, billed. | "The line opens when you speak or when Claude answers you, closes once the talk goes quiet, and after a handoff stays open a little longer for Claude’s answer." |
| 7 | `SECURITY.md:66-70` ("Every process running as your user is trusted") | lists "start a call" | **Incomplete.** A process joined as the target can also open the voice line again and again by posting an approval notice and withdrawing it (`Bridge.swift:497-521`, `opensLine` at `:430-435`), each line billed (§3: up to 15 s each). | Add to the list: "open the voice line, by starting a call or, as the target, by posting an approval notice, which spends your plan's Codex usage budget;" |
| 8 | `README.md:278`, `README.ru.md` "Бережно к оплате" | "A realtime voice session costs while it is open" / "стоит денег, пока открыта" | **Accurate**; on a plan it spends the Codex usage budget rather than extra money until credits are bought. Keep; optionally "uses your plan's Codex usage budget while it is open". | — |

Checked and correct: the 20 s, 90 s, 2 min and 5 s figures in every README and the overview match
`CallMachine` (`silenceSeconds`, `noiseCapSeconds`, `resultWindowSeconds`, `firstWordSeconds`);
"nothing is sent anywhere" while the line is closed matches the audio page, which sends audio
only while `sending` is set. The app's own help text says "a ChatGPT plan that includes realtime
voice" (`app/Sources/BridgeCore/Codex/CodexHelp.swift:20,27`); it is not a doc, but row 4 applies
to it too.

**Mute (0.4.0).** A muted line that stays open is billed like silence (first note §1, "muting
does not close the session"). Whatever Mute does, its docs should say whether the line stays open
while muted, and the README's cost sentences should not imply that muting saves minutes unless
it closes the line.

Follow-ups: the first time a limit is hit, copy the exact message from the menu (the app keeps
no log of it) and, if possible, the HTTP body from codex's own log; read
`account/rateLimits/read` at that moment; re-check the codex issues above, the pricing page and
the help-centre article before the release, and again after the December allowance change.
Unrelated to limits but on the same route: codex 0.165 and 0.166 users report a 404 from
`POST /backend-api/codex/realtime/calls` ([#57772](https://github.com/openai/codex/issues/57772),
open); if the owner sees "unexpected status 404", that is the cause, not a limit.
