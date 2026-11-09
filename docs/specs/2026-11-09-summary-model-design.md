# A summary model of its own, and a voice that waits for its context

Status: proposed, 2026-11-09. Nothing here is built; product code waits for the owner's approval.

## Why

When a line opens, the app asks the target session for a summary and connects without waiting
(`Bridge.openLine`). The mod writes it with `$.model.fork` (`plugin/hooks/context.ts`), which
repeats the main thread's last request, so it runs on the session's own model at the session's
own effort: Opus 5.5 on High for the owner. On a real call the owner felt about 20 s and heard the
voice answer before the context arrived. That figure is an impression: no timing is recorded
anywhere, and forks are not in the session journals.

So there are two connected changes: the summary gets a faster model chosen in Settings, and the
voice does not start on an empty context.

## Decisions the owner took

By voice, 2026-11-09, the last word replacing the earlier ones:

- **Claude only.** "выкидываем вариант с разными провайдерами". The transcript stays with
  Anthropic. Codex as a summariser is not built, so what goes to OpenAI does not change: the
  README's list of it and the pause's meaning stand (the wording fixes are under
  [Documents](#documents-that-change-with-the-code)).
- **A Settings field, "Summary model":** Haiku 5.5, Sonnet 5.5, Opus 5.5 and a custom text field,
  "на случай выхода новых моделей". Default Sonnet 5.5.
- **Always low effort**, stated in Settings.
- **On an error, the default.** "Лучше просто в случае ошибки переключаться на дефолт." A summary
  that fails on the chosen model is written by the default instead.
- **A custom value is checked when it is saved.** "делать короткий запрос для проверки
  работоспособности, либо оставаться, либо не принимать его."
- **On Start the call loads the context first:** the owner presses Start, sees that it is loading,
  the microphone stays off and voice input is blocked until the summary is in, and then the voice
  chat begins. Polling for this goes every 0.2 s instead of every second.

**Pinned versions, confirmed by the owner.** The list holds pinned ids (`claude-haiku-5-5`,
`claude-sonnet-5-5`, `claude-opus-5-5`), not aliases that follow the latest version, which was an
earlier wish. A new model is reached through the custom field until a release adds it to the list.

## What the owner sees

### Settings

The Sync section gets a **Summary model** picker: Haiku 5.5, Sonnet 5.5, Opus 5.5, Custom…. Custom
shows a text field and a **Check and save** button. The caption says: "Writes the summary the voice
gets as context, always at low effort, on your Claude usage. If this model fails, Sonnet 5.5 writes
it instead."

Under it, one line appears after a summary that did not come from the chosen model, until one does:
"The last summary used Sonnet 5.5: claude-example was refused." If the default failed too, the line
says the voice got no new summary, and why.

The value is stored as one string, `summaryModel`. A settings file without the key gets
`claude-sonnet-5-5`. Text is trimmed; empty text, or text outside `[A-Za-z0-9._:/@\[\]-]{1,128}`,
is refused before any check. That keeps nonsense out of the wire and the log. It is not a control:
the engine resolves and allowlist-checks the value.

#### Checking a custom value

The setting lives in the app, and `$.model.complete` lives in the mod: the app has no Claude client
of its own. So a joined session's mod runs the check.

1. **Check and save** is the only trigger. Picking a list entry checks nothing, nor does saving the
   value already stored or a value from the list. Typing spends nothing.
2. The app picks the target session if its mod says `writesSummaries`, otherwise the most recently
   joined session whose mod does.
3. The mod sends one request: `$.model.complete({ model, prompt: "Reply with OK.", effort: "low",
   maxTokens: 256, timeoutMs: 15000 })`. The cap leaves room for low-effort thinking, which counts
   against it. Any answered text counts as working. It costs a few tokens of the owner's usage.
4. **It works:** the value is stored and takes effect on the next ask.
5. **It does not:** the value is refused, Settings says why beside the field, the typed text stays
   for correcting, and the previous choice stays in force.

| While checking | Settings |
|---|---|
| In flight | the button says **Checking…** and is disabled |
| No session is joined, or none has a mod that can check | refused at once, nothing is sent: "No session can check this model. Run `/live` in a session and save again." |
| The session leaves, or no reply within 20 s | refused: "The check got no answer." |
| A refused model, an API error, no text, a time-out | refused, with the reason |

The check speaks for that session's Claude Code, which is the one a summary would run on if it were
the target. Another session can differ (its own settings or provider), and a value can stop working
later. The fallback below covers both, so a stored value is not checked again.

### Start

1. The owner presses Start in the band or the menu.
2. If a summary is really coming ([the rule](#when-the-call-waits)), the band's phase and the menu
   say **Loading context…**, with Stop on offer. The microphone is not started, so nothing is
   heard, no pre-roll is kept and macOS's prompt has not appeared yet.
3. When the summary arrives, the microphone starts and the phase is Listening as today. The first
   word opens a line whose seed already holds the summary, so that line asks for nothing.
4. If no summary is coming, or none can come, Start behaves as it does today.

A summary that failed, or the [time limit](#the-time-limits), also ends the loading: the call goes
on without a new summary, because a call the voice can have beats no call. A summary that lands
after the limit is stored as today and reaches the next line's seed, or the open line.

Stop during the loading ends the call. Start during it does nothing (`connecting` is set). An
answer that arrives meanwhile chimes and waits for the owner's first word, as a line that does not
open one does today. Changing the target ends the loading, and the new target's first line waits
by the rule below.

### A line opened later

A line can still need a summary once the microphone is on: a new target with none, a gap, more
lines than the seed carries. A line opened by speech then waits too: everything said queues on the
audio page, as it already does while a line connects, and the line is not opened until the summary
arrives or its limit passes. A line opened by a result does not wait: nobody spoke, and it has only
`firstWordSeconds` to be answered.

The menu shows **Loading context…** and disables Load context for any request in flight, whichever
started it. Today that holds only for a press (`ContextLoads.pressed`), so the menu offers the
button during a line's own request (`Bridge.contextNeed`).
An empty or failed reply goes back to Load context and does not flash **Context loaded**, which
`ContextLoads.arrived` would do today.

## Facts from the engine's types

Checked in the types Claude Code 2.1.319 lays beside the mod. The lowest version the README
promises is 2.1.301, and CI's floor run is what will check these calls there.

- `$.model.complete({ model, prompt, system, effort, maxTokens, timeoutMs }, { signal })` takes "an
  alias or a full model id; resolved and allowlist-checked like a `--model` value". No tools, no
  history. `maxTokens` defaults to 1024. `effort` is dropped on a model that takes none.
- It **rejects** for a request the engine refuses to send, such as a blocked model. Everything the
  provider does resolves: `isAnswered: false` with `api-error` (and `status`), `empty-reply` or
  `aborted`. `usage` is on every arm.
- `$.session.messages()` returns the newest 4096 entries of the main conversation as `{ role, text,
  toolUses }`, a user row adding `toolResults`.
- **`$.model.fork` does take `effort`** (`$.model.fork({ prompt, effort: "low" })`), which the
  brief for this work had the other way round. It takes no model. On a model with per-message
  effort it still reads the session's cache; elsewhere the first fork at a new level writes the
  whole conversation again. It is measured below as a fourth arm. It is not offered in Settings,
  as the owner's list does not include it.

Not verified, and the comparison below will show: whether `messages()` holds text from before a
compaction, and what a Haiku refusal comes back as (expected `empty-reply`).

## The summary

### How the setting reaches the mod

On the ask itself: `GET /v1/next` answers `{"kind":"context","model":"claude-sonnet-5-5"}`. The
ask is the only moment the mod needs the value, so no new route and no value kept in the mod. The
effort is not on the wire: `low` is a constant in the mod.

| Wire change | Who sends it | Meaning |
|---|---|---|
| `Work.context.model?: string` | app | the model to write this summary with; absent from an older app |
| `Work.context.fallbackModel?: string` | app | the default, to use if `model` fails; absent when `model` is the default |
| `JoinBody.writesSummaries?: true` | mod | this mod writes with the model asked, answers every context ask with `POST /v1/context` (an empty summary when it has none), and runs model checks |
| `ContextBody.failure?: { model, reason, status? }` | mod | why `model` wrote nothing. With a summary: the fallback wrote it. With `summary: ""`: there is none |
| `Work.checkModel: { id, model }` | app | check this model; handed out like a context ask, only to a mod that said `writesSummaries` |
| `POST /v1/model-check: { sessionId, id, ok, reason?, status? }` | mod | the result of that check; an unknown or stale `id` is ignored |
| `ContextBody.stats?` | mod | the [timing log](#the-timing-log) |
| `StatusReply.isLoadingContext?: true` | app | the call is loading its context; absent otherwise |

`Wire.swift`, `plugin/hooks/wire.ts` and `wire/fixtures/` change together, with a fixture for an
ask with a model and fallback, a join with `writesSummaries`, a summary with stats, a summary the
fallback wrote, a failed summary, a status that is loading, a check to run and both results of one.
The default lives in the app alone, which is why it travels on the ask.

`CallPhase` gets no new value. An older band does `PHASE[status.call]`, so an unknown phase would
throw when it draws. On the wire a loading call says `connecting`, which is what an older band
should show, and `isLoadingContext` tells a new band and the menu the rest.

### Versions

- **A mod older than the app** ignores `model` and `fallbackModel` and keeps writing with
  `$.model.fork`, and sends no `writesSummaries`, so **no wait applies to it**, its Start is today's
  Start, and it is never sent a check. The setting has no effect on it; Settings already lists
  sessions on an older mod.
- **An app older than the mod** sends no `model`: the mod forks as it does today, and posts nothing
  when it has no summary. So an ask with no `model` keeps today's whole behaviour, and `fork` stays
  in the mod for that case alone. The app's decoder ignores the fields it does not know.

### The transcript

`complete` has no history, so a new pure module, `plugin/hooks/transcript.ts`, builds the text from
`$.session.messages()`:

- each row's role and `text`, with `<system-reminder>` blocks removed;
- an assistant's tool uses as names alone, and no tool results. Tool output is the bulk of a long
  session, it is mostly not what a voice needs, and it is where secrets sit;
- a row longer than 6,000 characters keeps its start and end around a marker;
- **trimmed to 120,000 characters:** the first user row (at most 4,000) for the session's goal,
  then the newest rows backwards until the budget is spent, with a marker saying how many were
  left out. Subagents' conversations are not included.

**Does it fit?** By construction, with no count before sending. The engine offers no token count
for this, and a character budget needs none: a token rarely covers less than a character, so
120,000 characters stay under the smallest window in play (200,000 tokens for `haiku` on Bedrock,
Vertex or Foundry, per the [research note](#evidence)). A session can outgrow any model's window
and the budget does not move. A custom model with a smaller window, or an emoji-only transcript,
ends in `api-error` and the fallback. The number is a first guess, to be checked by the
comparison.

**The cost of leaving the fork.** A fork reads the session's prompt cache; `complete` shares
nothing with it and pays for its whole input every time. No cache mark is set, because trimming
from the tail shifts the text, and a write costs more than a read saves for a summary asked for
rarely.

The instructions go in `system` and the transcript in `prompt`, marked as data. `maxTokens` is
4096: a cap, not a target, as low-effort thinking counts against it. The reply is not cut, for the
reason `context.ts` gives: the app redacts first and caps after.

### When it fails

The mod tries `model` once. On a failure it tries `fallbackModel` once, at once, with the same
transcript, and only if the ask named one (so never when `model` is the default).

| What happened on `model` | Falls back? | Reported as |
|---|---|---|
| The engine refuses the model (`complete` rejects): blocked, unknown | yes | `failure.reason: "model-refused"` |
| `api-error`: bad id, window too small, overload | yes | `"api-error"`, with `status` |
| `empty-reply`, including a refusal with no text | yes | `"empty-reply"` |
| `aborted`, or its time ran out | no | `"timed-out"`: the time is already spent |
| No turn yet, or no text in the transcript | no model call | `summary: ""`, no `failure` |

A refusal is expected to arrive as `empty-reply`; that is unverified, and a refusal that comes back
as ordinary text would pass as a summary.

**The fallback stays inside the wait.** The limits are not extended for it and the call does not
wait twice. Refused models and bad ids fail in about a second, so the fallback normally fits. If the
limit passes first, the call goes on and the summary, when it lands, is stored as any late one is.
The mod's own 60 s (`timeoutMs` for each attempt being what is left of it) bounds both attempts.

**What the mod posts.** A summary from the fallback carries `failure` naming the chosen model and
why, so the owner can see it: the line under the Settings field and the timing log. `stats.model` is
the model that wrote it. The chosen model stays selected and is tried first on the next ask.

**If the default fails too**, or there is no fallback, the mod posts `summary: ""` with `failure`.
The app ends the wait, and the voice still gets its line with no new summary. The next line asks
again, since `context` is still nil. The mod's `NO_SUMMARY` line stays. If the mod dies or its
session closes, the limit or the session's drop ends the wait.

Empty and failed replies are posted only when the ask carried `model`, so an older app never sees
one. The app's `context` route already tolerates an empty summary and closes the ask.

The mod's cached summary (`summary` in `register.tsx`) is keyed by the model asked for, so a change
of model writes a new one.

## Waiting

### When the call waits

All of these, for the Start and for a line opened by speech alike:

1. An ask was made for this Start or line: the pause does not hold it back and the voice lacks part
   of the session (`pauseHoldsBackSummary`, `needsContext`, unchanged).
2. The session's mod said `writesSummaries`.
3. The mod takes the ask: if `GET /v1/next` has not handed it over within 3 s, the wait ends.
4. The same session has not already ended a wait with no summary in this call, so a persistent
   failure does not delay every line.

It ends at the first `POST /v1/context` from that session, whatever it carries, or on Stop, a target
change, the session dropping, or the limit.

### Where the wait sits

**On Start, before the microphone.** The ask goes out at the press, while codex launches, so the
two overlap. `CallMachine` keeps `phase == .listening` with a new `isLoadingContext`: `.start`
with a wait emits no `.startLocalVAD`, and a new `.contextSettled` event emits it. Speech cannot
arrive; a delivery appends and chimes but cannot open a line. No line is open, so nothing is billed.

**On a later line, in `Bridge.openLine`, after `makeOffer` and before the seed is built and
`voice.open` is called.** The queue needs no change: `audio.js` queues from the first word
(`line.hold`) and plays only after `flushPreroll`, which the machine emits at `.connected`.

This is chosen over holding `flushPreroll` on a line already open:

- the line is billed from `voice.open`, and this project closes the line to stop paying for silence;
  an open line would pay for the whole wait;
- the summary lands in the seed, not in a later `addContext`, so the voice has it from its first
  item;
- the machine needs no state for it: `.connecting` already arms no silence timer, and `Stop` already
  cancels the attempt. A line that waited on `.live` would need the silence timer held off, since a
  result's line closes after 5 s.

What it costs: the connect comes after the summary, not beside it, so the owner waits for the
summary plus `voice.open` and `applyAnswer`. The offer's ICE candidates wait through the limit,
which the real-voice check must confirm is harmless; the limit is capped partly for that.

After the wait, what was said plays in real time with silences cut (ADR 0001 (c)), so a long
sentence said during the wait is heard by the voice at speaking speed.

### The time limits

They come from the [comparison](#the-comparison-one-off-asks-first), and are not numbers yet.

- **Start:** twice the slowest Sonnet 5.5 low run, at least 10 s, at most 30 s. The owner is
  watching a loading state and has asked for no voice until it is in.
- **A later line:** 1.5 times that run, at most 15 s. The owner has already spoken.

The research note's estimate for Sonnet low at 100k input is 6 to 8 s. That is an unverified
reading of a third party's numbers, and the limits are not set from it.

### Polling every 0.2 s

The ask reaches the mod on its poll (`POLL_MS`, 1 s today). The target session polls every 200 ms.
Other joined sessions stay at 1 s: only the target gets the ask that matters here, and each poll
costs a socket round trip and a band write. One timer at 200 ms skips ticks for a session that is
not the target. A tick that changes nothing must not rewrite the band, or five writes a second would
redraw it.

This takes at most 0.8 s off the wait, and on average about 0.4 s. The rest is the model. The summary
itself comes back by `POST` at once and is not polled for, and the app starts the microphone on
arrival.

## The timing log

`POST /v1/context` carries `stats: { model, durationMs, transcriptChars, inputTokens, outputTokens,
cacheReadTokens, cacheWriteTokens }`, `model` being `session` for a fork. The app adds how long the
ask took to answer and how long the call waited, and writes one line to the unified log (`Logger`,
category `summary`), numbers and the model's name only, no text and no session id. It is local: no
file is kept and nothing is sent, so "no telemetry" holds.

## The comparison (one-off, asks first)

One real long session, with one throwaway mod outside the repository running today's fork, the fork
at `low`, Sonnet 5.5 low and Haiku 5.5 low, on a `--fork-session` copy so the original is untouched.
It records duration, the four token counts and the text, and tries the 120,000 budget against the
fork's summary by reading them. It costs about 3 to 4 ordinary Opus turns in a long session, more
if the copy's first turn finds the cache cold.

The owner is near a weekly limit, so **it runs only after the owner agrees at that moment**, and
`scripts/smoke.sh` or a real-voice probe likewise. It checks the default, it does not choose it.
If Sonnet does not beat today's fork, that goes back to the owner.

## Evidence

The research note `summary-model-research.md` (side-session notes, 2026-11-09; a subagent's reading,
not re-checked) found no benchmark of summary quality for Haiku 5.5 or Sonnet 5.5, a first token
at 100k input of 15.5 s for Haiku and 3.0 s for Sonnet at low effort (Artificial Analysis), and
that Haiku's safety classifiers can refuse with no server fallback. It recommends Sonnet with
medium confidence, which is the owner's default. Pinned ids and aliases may also resolve differently
on Bedrock, Vertex and Foundry, where a pinned first-party id can fail. The default fails there too, and the voice goes without a
new summary.

## Why not Codex

Recorded so the question need not be re-derived. A Codex summary would have run in the app, the
one side with codex, so the mod would have sent the transcript over the socket (body limit 131,072
bytes), for a throwaway read-only thread with `turn/start`'s `effort: "low"`. `model/list` does
list the models (checked live on codex 0.166.0: 8 models, each with its reasoning efforts). It
would have sent nearly the whole conversation to OpenAI, where today only a redacted summary of at
most 1,500 characters goes. The owner dropped it.

## Security

No permission prompt is touched, and the model has no tools. The transcript goes to Anthropic
through the session's own client, as the session's own requests do; it now may go to a different
model than the session's. The summary still passes the app's redactor and its 1,500-character cap
before OpenAI sees it. The pause still does not keep paused text out of a summary: the transcript
holds it. A check sends only "Reply with OK." and the model's name.

`POST /v1/model-check` takes a local process's word, like the other routes SECURITY.md lists: one
that guesses the check's `id` can make Settings accept a value that does not work. The fallback then
writes the summary; no permission or data is reached. It is not a control, and SECURITY.md's list of
what such a process can do gains this line.

## Documents that change with the code

- `README.md`: line 44 ("the session's own model" becomes the model set in Settings), Settings
  section, the "whole transcript" sentences; `SECURITY.md` likewise, saying the summary is written
  from the session's text without tool output, and may carry paused text. Translations under
  `docs/i18n/` and `site/index.html` follow.
- `docs/architecture/overview.md`: the Start sequence, the context routes, the wait.
- `CHANGELOG`: summaries now use Sonnet 5.5 by default, on an update too.

## Not in this change

Other providers, a sound when the microphone opens (the owner may want one; the band and menu are
the only signs), a model list fetched from the engine, a retry on the same model, re-checking a
stored value.

## Implementation order

Step one, which spends nothing: `summarize` reports duration and token use, `POST /v1/context`
carries `stats`, and the app logs them, with nothing else changing. Then the comparison (when the
owner agrees), the setting, transcript and fallback, the model check, the Start wait and the later line's wait with the limits
filled in, and the 200 ms poll. The plan follows the spec's approval.
