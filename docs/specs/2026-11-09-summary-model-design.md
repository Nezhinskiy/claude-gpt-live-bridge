# A summary model of its own, and a voice that waits for its context

Status: approved 2026-11-12, when the owner chose it over a small fix for
[BR-003](../bugs/BR-003.md); proposed 2026-11-09, revised 2026-11-10 after the review
(`docs/reviews/2026-11-10-summary-model-spec-review.md` on branch
`review/pr74-summary-model-spec`) and the owner's answers to it. Only the `working` glyph is built;
the plan is [`docs/plans/2026-11-12-summary-model.md`](../plans/2026-11-12-summary-model.md).

## Why

When a line opens, the app asks the target session for a summary and connects without waiting
(`Bridge.openLine`). The mod writes it with `$.model.fork` (`plugin/hooks/context.ts`), which
repeats the main thread's last request, so it runs on the session's own model at the session's
own effort: Opus 5.5 on High for the owner. On a real call the owner felt about 20 s and heard the
voice answer before the context arrived. That figure is an impression: no timing is recorded
anywhere, and forks are not in the session journals.

So there are two connected changes: the summary gets a model chosen in Settings, and no line
reaches the voice before its context.

## Decisions the owner took

By voice on 2026-11-09, and in answers to the review on 2026-11-10 (O1 to O6):

- **Claude only.** "выкидываем вариант с разными провайдерами". Codex as a summariser is not built,
  so what goes to OpenAI does not change.
- **A Settings field, "Summary model":** Haiku 5.5, Sonnet 5.5, Opus 5.5 and a custom text field.
  **Pinned ids** (`claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`), not aliases; a new
  model is reached through the custom field until a release adds it.
- **Default Haiku 5.5** (O5, which replaced the earlier Sonnet default): "меняем дефолт соннета на
  хайку 5.5".
- **Always low effort**, stated in Settings.
- **On an error, the default** (O1): a summary that fails on the chosen model is written by the
  default. When the default itself fails there is no further model: a Haiku refusal leaves the
  voice without a new summary (the owner's answer to the follow-up question). O2, about re-checking
  a stored value with no fallback, fell away with O1.
- **A custom value is checked when it is saved**, with one short request: kept if it works,
  refused if not.
- **The microphone records but nothing is sent until the context is in** (owner, 2026-11-10,
  replacing "the microphone stays off on Start"): "не держать заблокированным, а писать, но
  отправлять только после загрузки контекста". It holds for Start, a target change and every line.
- **A result that arrives while the context loads waits for it**, then opens its line (O3).
- **A target change** keeps the old session's summary loading in the background and starts the new
  one's (O4); every joined session already keeps its own conversation (`Bridge.sync`), and a
  summary for a session that is not the target is stored when it lands (`Bridge.context`).
- **Polling every 0.2 s** instead of every second.
- **The floor may rise** (O6) if Claude Code 2.1.301 lacks a parameter this needs.
- **The menu bar glyph:** a turning ring while the context loads, and another animation, one that
  reads as thinking rather than loading, while Claude works.

## What the owner sees

### Settings

The Sync section gets a **Summary model** picker: Haiku 5.5, Sonnet 5.5, Opus 5.5, Custom…. Custom
shows a text field and a **Check and save** button. The caption says: "Writes the summary the voice
gets as context, always at low effort, on your Claude usage. If another model fails, Haiku 5.5
writes it instead."

One line appears under it after a summary that did not come from the chosen model, until one does,
built from the app's own record of what it asked for: "The last summary used Haiku 5.5: Opus 5.5
was refused." If no model wrote one, it says the voice got no new summary, and why.

The value is stored as one string, `summaryModel`. A settings file without the key gets
`claude-haiku-5-5`, also on an update. Text is trimmed; empty text, or text outside
`[A-Za-z0-9._:/@\[\]-]{1,128}`, is refused before any check. That keeps nonsense out of the wire and
the log. It is not a control: the engine resolves and allowlist-checks the value.

#### Checking a custom value

The app has no Claude client of its own, so a joined session's mod runs the check.

1. **Check and save** is the only trigger. Picking a list entry checks nothing, nor does saving the
   value already stored. Typing spends nothing.
2. The app hands the check to the target session if its mod says `writesSummaries`, otherwise to
   the most recently joined session whose mod does, and takes the result only from that session.
3. The mod sends `$.model.complete({ model, prompt: "Reply with OK.", effort: "low", timeoutMs:
   15000 })`, with the default token cap: a lower one saves nothing and, as low-effort thinking counts
   against it, could only produce a false `empty-reply`. Any answered text counts as working.
4. **It works:** the value is stored and takes effect on the next ask.
5. **It does not:** the value is not stored, the reason shows beside the field, the typed text stays
   for correcting, and the previous choice stays in force.

| While checking | Settings |
|---|---|
| In flight | the button says **Checking…** and is disabled |
| No session joined, or none whose mod can check | nothing is sent: "No session can check this model. Run `/live` in a session and save again." |
| The session leaves, or no reply within 20 s | "The check got no answer." |
| `api-error` of a kind that may clear (`rate_limit`, `overloaded`, `server_error`) | "Claude is busy; try again." |
| The engine refuses the model, any other `api-error`, no text, a time-out | refused, with the reason |

The check speaks for that session's Claude Code. Another session can differ (its own settings or
provider), and a value can stop working later; the fallback covers both, so a stored value is not
checked again.

### Start, a target change, and every line

1. When the call starts, or the target changes during a call, and the target lacks part of its
   session (`needsContext`, and the pause does not hold the ask back), the app asks at once, if the
   session's mod said `writesSummaries`. A session on an older mod is asked as today, when a line
   opens, so Start does not spend a fork on the session's own model before anyone speaks.
2. The microphone starts as today. The first word opens a line: the page queues everything said
   (`line.hold`), and the line waits, before the seed is built and before `voice.open`, while that
   session's summary is [in flight](#when-a-line-waits). Nothing leaves the Mac meanwhile.
3. When the summary arrives, the line opens with it in the seed, and the queue plays into it (ADR
   0001 (c)): silences are cut, speech plays at speaking speed, so the voice answers once it has
   heard what was said.
4. A result that would open a line waits the same way, then opens it and is said with the context.
   `firstWordSeconds` counts from `.connected`, as today.
5. A failure or the [limit](#the-time-limit) ends the wait: the line opens without a new summary,
   because a call the voice can have beats no call. A summary that lands later is stored as today and
   reaches the open line or the next seed.

A target change closes a waiting line as it closes a connecting one today, so words said to the old
target during its wait are dropped; words said after the change queue for the new target's line.
The old session's summary keeps loading and is stored when it lands.

Mute and Unmute work as today: the call is `.listening` or `.connecting`, never a new state.

### What shows that it is loading

- **The menu:** **Loading context…** for any summary in flight, whichever started it, with Load
  context disabled. Today that holds only for a press (`ContextLoads.pressed`), so the menu offers
  the button during a line's own request (`Bridge.contextNeed`). An empty or failed reply goes back
  to Load context and does not flash **Context loaded**, which `ContextLoads.arrived` would do today.
- **The target's band:** its own **Loading context…** note, as today (`showContext`), beside the
  call's phase.
- **The menu bar glyph:** a new badge, `loadingContext`: the three-quarter ring that turns once a
  second, which today means a session at work. It shows while the target's summary is in flight and
  the call is on, after `problem` and `approval` and before `unheard`. `working` gets a new
  animation instead: three dots between the towers that brighten one after another, like an
  ellipsis, for thinking rather than loading. Both have a still frame when motion is reduced. The
  shapes are my call; frames are shown to the owner before the code is committed. **Built ahead
  of the rest** (2026-11-11, at the owner's request): `working` draws the three dots, and the
  session row's symbol for it is `ellipsis`, not turning arrows. The ring's drawing was removed
  with it; `loadingContext` brings it back.

## Facts from the engine's types

Checked in the types Claude Code 2.1.319 lays beside the mod. The README's floor is 2.1.301; the
plan's first step that calls `complete` runs `scripts/check-floor.sh`, and if 2.1.301 lacks
`system`, `effort`, `timeoutMs` or `signal`, the floor rises to the first version with them (O6),
in the README, the CHANGELOG and every copy `claude-code-floor.test.sh` checks.

- `$.model.complete({ model, prompt, system, effort, maxTokens, timeoutMs }, { signal })` takes "an
  alias or a full model id; resolved and allowlist-checked like a `--model` value". No tools, no
  history. `maxTokens` defaults to 1024. `effort` is dropped on a model that takes none.
- It **rejects** for a request the engine refuses to send, such as a blocked model. Everything the
  provider does resolves: `isAnswered: false` with `api-error` (with `status` and an `error` kind:
  `rate_limit`, `overloaded` and `server_error` "may clear on their own", `model_not_found`,
  `invalid_request`, `authentication_failed` and `billing_error` will not), `empty-reply` or
  `aborted`. `usage` is on every arm.
- `$.session.messages({ as: "api" })` returns "the ones the next request is built from, after the
  engine's normalization (the last compaction's summary in place of what it replaced, reminders as
  text blocks); at most 4096, opening on a user one".
- **`$.model.fork` takes `effort`**, not a model. It is measured below as a fourth arm.
- Every `$` call is an op event other hooks in the session can read, rewrite, refuse or answer
  (`OpEventOf`). `model.complete` carries the whole prompt, so the transcript; `model.fork` carries
  only its request, the prompt and effort.

Not verified, and the comparison will show: what a Haiku refusal comes back as (expected
`empty-reply`), and whether an unknown id is rejected by the engine or answered as `api-error`.

## The summary

### How the setting reaches the mod

On the ask itself: `GET /v1/next` answers `{"kind":"context","model":"claude-opus-5-5",
"fallbackModel":"claude-haiku-5-5"}`. The default lives in the app alone, so it travels on the ask.
The effort is not on the wire: `low` is a constant in the mod.

| Wire change | Who sends it | Meaning |
|---|---|---|
| `Work.context.model?: string` | app | the model to write this summary with; absent from an older app |
| `Work.context.fallbackModel?: string` | app | the default, used if `model` fails; absent when `model` is the default |
| `JoinBody.writesSummaries?: true` | mod | writes with the model asked, answers every context ask with `POST /v1/context` (an empty summary when it has none), runs model checks |
| `ContextBody.failures?: [{ reason, status?, error? }]` | mod | one per attempt that wrote nothing, in order: with a summary, the fallback wrote it; with `summary: ""`, nothing did |
| `ContextBody.stats?` | mod | the [timing log](#the-timing-log) |
| `Work.checkModel: { id, model }` | app | check this model; only to a mod that said `writesSummaries` |
| `POST /v1/model-check: { sessionId, id, ok, reason?, status?, error? }` | mod | the check's result; taken only from the session it was handed to, with its `id` |

`reason` is one of `model-refused`, `api-error`, `empty-reply`, `timed-out`; the app writes its own
sentences from it and from `error`, and shows nothing the mod wrote. No model name comes back over
the socket: the app knows what it asked for.

`Wire.swift`, `plugin/hooks/wire.ts` and `wire/fixtures/` change together. `Work.context` gains
associated values and `Work` a case, so every `switch` on `Work` changes. Fixtures: an ask with a
model and a fallback, a join with `writesSummaries`, a summary with stats, a summary the fallback
wrote, a failed summary, a check to run and both results of one. `CallPhase` and `StatusReply` do
not change. A new band also learns to draw an unknown phase as `connecting`, so the next phase needs
no mapping: an older band's `PHASE[status.call]` throws on one.

### Versions

- **A mod older than the app** ignores `model` and `fallbackModel` and keeps writing with
  `$.model.fork`, sends no `writesSummaries`, so it is asked only when a line opens, no line waits
  for it, and it is never sent a check. The setting has no effect on it; Settings already lists
  sessions on an older mod.
- **An app older than the mod** sends no `model`: the mod forks as today and posts nothing when it
  has no summary. Writing with `complete` there would need the default in the mod as well, a second
  home for one fact, for a pair that lasts until the app updates, so the fork stays for that case
  alone. The app's decoder ignores fields it does not know.

### The transcript

A new pure module, `plugin/hooks/transcript.ts`, builds the text from `$.session.messages({ as:
"api" })`, which already puts the last compaction's summary in place of what it replaced:

- each message's role and its text blocks, with `<system-reminder>` text removed;
- an assistant's `tool_use` blocks as tool names alone; no `tool_result`, thinking or image blocks.
  Tool output is the bulk of a long session, mostly not what a voice needs, and where secrets sit;
- a message longer than 6,000 characters keeps its start and end around a marker;
- **trimmed to 120,000 characters:** the first user message the engine returns (at most 4,000) for
  the goal, then the newest messages backwards until the budget is spent, with a marker saying how
  many were left out. After a compaction the first message is its summary. Without one, in a session
  of more than 4096 messages, it is only the oldest the engine returns, not the session's first.

**Does it fit?** By construction, with no count before sending; the engine offers no token count. A
token rarely covers less than a character, so 120,000 characters stay under the smallest window in
play (200,000 tokens for `haiku` on Bedrock, Vertex or Foundry, per the research note). A custom
model with a smaller window, or an emoji-only transcript, ends in `api-error` and the fallback. The
number is a first guess for the comparison to check.

**What leaving the fork costs.** A fork reads the session's prompt cache; `complete` shares nothing
with it and pays for its whole input every time. No cache mark is set: trimming from the tail shifts
the text, and a fallback on another model reads no other model's cache.

The instructions go in `system` and the transcript in `prompt`, marked as data. `maxTokens` is
4096, a cap and not a target, as low-effort thinking counts against it. The reply is not cut, for the
reason `context.ts` gives: the app redacts first and caps after.

### When it fails

The mod tries `model` once. On a failure it tries `fallbackModel` once, at once, with the same
transcript, and only if the ask named one, so never when `model` is the default.

| What happened on `model` | Falls back? | `reason` |
|---|---|---|
| The engine refuses the model (`complete` rejects): blocked, perhaps unknown | yes | `model-refused` |
| `api-error`: a bad id, a window too small, an overload | yes | `api-error`, with `status` and `error` |
| `empty-reply`, including a refusal with no text | yes | `empty-reply` |
| `aborted`, or its time ran out | no: the time is spent | `timed-out` |
| No turn yet, or no text in the transcript | no model call | `summary: ""`, no `failures` |

A refusal that comes back as ordinary text would pass as a summary; that is unverified.

**The fallback stays inside the wait.** The limit is not extended for it. A refused model or a bad id
fails in about a second, so the fallback normally fits; if the limit passes first, the line opens and
the summary, when it lands, is stored as any late one is. The mod's own 60 s bounds both attempts,
each `timeoutMs` being what is left of it.

**The default fails too, or there is no fallback:** the mod posts `summary: ""` with `failures`. The
line opens without a new summary. The next line asks again, as `needsContext` still holds, which also
covers a session with an older summary and a gap. The mod's `NO_SUMMARY` line stays. Empty and failed
replies are posted only when the ask carried `model`, so an older app never sees one; its `context`
route already tolerates an empty summary and closes the ask.

The mod's cached summary (`summary` in `register.tsx`) is keyed by the model asked for. A second ask
while one is in flight joins it (`sending ??=`) and gets what the first model writes, so a change of
model takes effect at the next ask that finds none in flight.

## Waiting

### When a line waits

One Bridge function decides it for every line, whatever opened it. A line waits while all of these
hold:

1. Its session has a summary ask in flight: asked at Start, at a target change, by Load context, or
   by this line (`pauseHoldsBackSummary` and `needsContext` decide an ask, unchanged).
2. That session's mod said `writesSummaries`.
3. In this call the session has not already ended a wait without a summary (no summary from any
   model, or the limit), so a persistent failure does not hold every line.

It ends at the first `POST /v1/context` from that session that answers the open ask, whatever it
carries; at the limit; when the session drops (5 s without a poll); or when the line is cancelled
(Stop, a target change). A post that `Bridge.context` ignores, one asked for before the latest gap or
forget (`takeSummaryAsk`), does not end it, and only a reply with no summary, or the limit, counts for
rule 3. The wait's end is decided before that guard returns.

The review's third rule, a 3 s deadline for the mod to take the ask, is dropped: a polling session
takes it within one poll, one that stops polling is dropped within 5 s, and the registry keeps no
record of when an ask was taken.

### Where the wait sits

In `Bridge.openLine`, after `makeOffer` and before the seed is built and `voice.open` is called. The
machine is `.connecting`, which arms no silence timer, and Stop cancels the attempt. The audio page
needs no change: it queues from the first word and plays only after `flushPreroll`, at `.connected`.

This is chosen over holding `flushPreroll` on a line already open:

- the line is billed from `voice.open`, and this project closes the line to stop paying for silence;
  an open line would pay for the whole wait;
- the summary lands in the seed, not in a later `addContext`;
- a line that waited while `.live` would need the silence timer held off, since a result's line
  closes after 5 s.

The cost: the connect comes after the summary, so the owner waits for the summary plus `voice.open`
and `applyAnswer`. The offer waiting is harmless: the page's `RTCPeerConnection` has no ICE server,
and codex first sees the offer at `voice.open`.

### The time limit

One limit, counted from the ask, so a line opened late in a summary's run waits only for the rest of
it. It comes from the [comparison](#the-comparison-one-off-asks-first) and is not a number yet: twice
the slowest run of the default model on the session measured, at least 10 s, at most 30 s.

The research note's own estimate for Sonnet low at 100k input is 6 to 8 s, but the same source
measures the average end-to-end time of a single request at low effort as **21.4 s for Sonnet 5.5
and 23.8 s for Haiku 5.5**, near today's felt 20 s, and Haiku's first token at 100k input as 15.5 s
against Sonnet's 3.0 s. Those are a third party's numbers for its own prompts, unverified on the
mod's path. If the default's run on the mod's path is over the cap, the numbers go back to the owner
before the wait is built.

### Polling every 0.2 s

The ask reaches the mod on its poll (`POLL_MS`, 1 s today). The target session polls every 200 ms;
others stay at 1 s, since only the target gets the ask that matters here. One timer at 200 ms skips
ticks for a session that is not the target. A fast tick skips `follow` (the title still follows at
the 1 s cadence: `follow` reads the session's id and its registry record) and does not rewrite an
unchanged band, so five ticks a second cost five socket round trips and nothing else.

This takes at most 0.8 s off the wait, about 0.4 s on average; the rest is the model. The summary
comes back by `POST` at once.

## The timing log

`POST /v1/context` carries `stats: { durationMs, transcriptChars, inputTokens, outputTokens,
cacheReadTokens, cacheWriteTokens }` for the attempt that wrote it. The app adds the model it asked
for (the fallback when `failures` has one entry), how long the ask took to answer and how long the
line waited, and writes one line to the unified log (`Logger`, category `summary`): numbers and the
model's id, no text and no session id. It is local: no file is kept and nothing is sent, so "no
telemetry" holds.

## The comparison (one-off, asks first)

One real long session, with one throwaway mod outside the repository running today's fork, the fork
at `low`, Haiku 5.5 low and Sonnet 5.5 low, on a `--fork-session` copy so the original is untouched.
It records duration, the four token counts and the text, and tries the 120,000 budget against the
fork's summary by reading them. It costs about 3 to 4 ordinary Opus turns in a long session, more if
the copy's first turn finds the cache cold.

It runs only after the owner agrees at that moment, as do `scripts/smoke.sh` and any real-voice
probe. It checks the default and sets the limit; it does not choose the default.

## Evidence

The research note `summary-model-research.md` (side-session notes, 2026-11-09; a subagent's reading,
not re-checked) found no benchmark of summary quality for Haiku 5.5 or Sonnet 5.5, the speeds above,
and that Haiku's safety classifiers can refuse with no server fallback. It recommended Sonnet with
medium confidence; the owner chose Haiku.

Claude Code's documents (`amazon-bedrock`, `model-config`, read through Context7 by the reviewer on
2026-11-10) say that since 2.1.200 an Anthropic model id passed as `--model` maps to the provider's
own id, to an inference profile found at startup, or to the `modelOverrides` setting. So a pinned id
should resolve on Bedrock, Vertex and Foundry where the provider offers that model and the
organisation allows it, and fail where it does not; unverified on a real provider. Today's fork works
wherever the session works, so where the provider lacks the pinned default, an update turns a working
summary into none: the README's known limitations and the CHANGELOG say so.

## Why not Codex

A Codex summary would have run in the app, the one side with codex, so the mod would have sent the
transcript over the socket (body limit 131,072 bytes) for a throwaway read-only thread with
`turn/start`'s `effort: "low"`. `model/list` does list the models (checked live on codex 0.166.0: 8
models, each with its reasoning efforts). It would have sent nearly the whole conversation to OpenAI,
where today only a redacted summary of at most 1,500 characters goes. The owner dropped it.

## Security

No permission prompt is touched, and the model has no tools. The summary still passes the app's
redactor and its 1,500-character cap before OpenAI sees it, and the pause still does not keep paused
text out of it.

- **Where the transcript goes.** To the model through the session's own client: Anthropic on the
  first-party API, wherever the session's own requests go on Bedrock, Vertex or Foundry. On the way,
  any other mod in the session sees it in the `model.complete` event and may rewrite it or answer in
  its place. Those mods are the owner's, so this is no new adversary, but the docs do not claim that
  only the model sees it. Today's fork exposes only its prompt there.
- **What the transcript holds.** A current mod with a current app leaves tool results, thinking and
  system reminders out; text that quotes them stays, as does anything pasted. An older app or mod
  sends the whole request, as the fork does today. It is a reduction, not a property.
- **The check takes a local process's word**, like the other routes SECURITY.md lists. A process that
  joins with `writesSummaries` and makes itself the target is handed the check with its `id`, and can
  make Settings accept a value that does not work. The fallback then writes the summary; no
  permission or data is reached. It is not a control.
- **A joined process that never answers an ask** can hold a line's speech on the Mac up to the limit,
  once per call (rule 3).

SECURITY.md's list of what such a process can do gains the last two. A check sends only "Reply with
OK." and the model's id.

## Documents that change with the code

- `README.md`: line 45 ("the session's own model" becomes the model set in Settings), lines 316-317
  ("which holds the text the session read"), the Settings section, the "whole transcript" sentences,
  the known limitation about a provider without the pinned default; translations under `docs/i18n/`
  and `site/index.html` follow.
- `SECURITY.md`: the "whole transcript" sentences, worded as the reduction above, and the list's two
  new lines.
- `docs/architecture/overview.md`: the Start sequence, the wait, and the route table's
  `POST /v1/model-check`.
- `plugin/hooks/wire.ts`: the route list in its header.
- `Bridge.context(_:)`'s comment, "the mod never sends one" of an empty summary.
- `plugin/hooks/context.ts`'s comment.
- `CHANGELOG.md`: summaries now use Haiku 5.5 by default, on an update too, the provider limitation,
  and the floor if it rises.

## Not in this change

Other providers, a sound when the line opens after a wait, a model list fetched from the engine, a
retry on the same model, re-checking a stored value.

## Implementation order

Step one, which spends nothing: `summarize` reports duration and token use, `POST /v1/context`
carries `stats`, and the app logs them, with nothing else changing. Then the comparison (when the
owner agrees), the setting, transcript and fallback with the floor run, the model check, the wait and
its early asks, the glyph, and the 200 ms poll. The plan follows the spec's approval.
