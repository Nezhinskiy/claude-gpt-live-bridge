# Review: a summary model of its own, and a voice that waits for its context

Reviewed: PR #74, `docs/specs/2026-11-09-summary-model-design.md` at `85a67e1`
(`claude/elastic-euclid-30332e` → `dev`), with its `docs/trail.toml` and `docs/roadmap.md` entries.
Reviewed against `dev` at `1086064` and the engine types Claude Code 2.1.319 writes beside the mod
(`plugin/.claude-plugin/types/claude-code/index.d.ts`, git-ignored, so cited by symbol). Read only:
no model call, no real-voice run, nothing in `/Applications`.

Method: `superpowers:requesting-code-review` (one independent reviewer given the code, not these
findings), `simplify` (reuse, simplification, efficiency and altitude, one reviewer each, report
only), `security-review` (on the proposed design; the diff itself is prose, which that skill's rules
exclude). Every finding below was checked against the code or the types by the author of this file;
a reviewer's suggestion that did not survive is listed as declined, with the reason. The
independent reviewer found F1 to F4, F9 and F13 on its own, and added F20 to F23.

Spec line numbers are of the spec at `85a67e1`.

## Verdict

**Not ready to plan from.** One blocker: the spec records a fallback between models that the owner's
decision, as relayed to this review, rules out (F1). Three gaps in the wait would each surface as a
bug in the first build (F2 to F4), two more need a sentence each (F20, F21), and the evidence for
the limits leaves out the number that matters most (F5). The rest is accuracy, simplification and documentation. The
registration in `trail.toml` and `roadmap.md` is correct.

What is good: the spec checks itself against the engine's types and says what it did not verify;
it keeps an older mod and an older app on today's behaviour by construction; it puts the later
line's wait before `voice.open`, so the wait is not billed; it keeps `CallPhase` unchanged for older
bands; it cuts tool output from the transcript, which sends less than today's fork; the comparison
and every paid run wait for the owner.

## Findings, most severe first

Numbered in the order found; the table is in order of severity.

| # | Severity | Where (spec) | In short |
|---|---|---|---|
| F1 | Blocker | 28-29, 46-51, 82-83, 150-153, 208-242, 359-360 | A fallback to Sonnet 5.5 contradicts "no fallback between models" |
| F2 | Important | 262-266 | Unmute during Start's loading takes the microphone, or ends the call |
| F3 | Important | 99-101, 266 | A result during Start's loading opens a line today; the spec assumes it only chimes |
| F4 | Important | 262 | A summary that lands before `.start` is lost to the machine; the wait runs to its limit |
| F5 | Important | 292-297, 333-337 | The evidence leaves out the measured end-to-end time, which puts the line limit in doubt |
| F6 | Medium | 336-339, 363-370 | Pinned ids map to the provider's ids since 2.1.200; where a provider lacks the model, no README line says so |
| F7 | Medium | 67-79, 155, 213-216 | The check refuses a working model on a passing overload; the result drops the error kind |
| F8 | Medium | 352-361 | Security understates the check's spoofing and leaves out `model.complete` hooks |
| F9 | Medium | 99 | "Start does nothing (`connecting` is set)" is untrue in the spec's own design |
| F10 | Medium | 253 | Wait rule 3 (3 s hand-over) repeats the registry's 5 s drop and the limit |
| F20 | Medium | 254-257 | A stale summary's post ends the wait and, by rule 4, disarms every later wait in the call |
| F21 | Medium | 170-172, 262 | Whether Start asks a session on an older mod is unsaid; if it does, Start costs a fork |
| F11 | Low | 157, 164-166 | `StatusReply.isLoadingContext` has almost no reader |
| F12 | Low | 174-176 | `$.model.fork` is kept as a second summary path for an older app alone |
| F13 | Low | 282-283 | The ICE caveat is moot: the page uses no ICE server |
| F14 | Low | 137-138, 187 | `messages({ as: "api" })` answers the compaction question; 4096 rows is not the session's start |
| F15 | Low | 67-69 | The check's 256-token cap saves nothing and risks a false `empty-reply` |
| F16 | Low | 313-317, 153 | Model names from the socket reach the log and Settings unchecked |
| F17 | Low | 363-370 | The documents list misses four places |
| F18 | Low | 99-102, 104-110 | A target change during a later line's wait drops what was said; unstated |
| F19 | Low | 235-236, 241 | Two small accuracy points for the builder |
| F22 | Low | 301-305 | A 200 ms tick also reads the session's registry file and follows its title |
| F23 | Low | 120-121 | No answer for a floor run that finds `complete`'s options missing on 2.1.301 |

### F1. Blocker: the fallback contradicts the owner's decision as relayed

The decisions handed to this review say "always at low effort, with no fallback between models".
The spec's first commit (`f942454`) said the same at its line 28, "**No fallback** from one model to
another". Eight minutes later `85a67e1` reversed it, quoting the owner: "Лучше просто в случае ошибки
переключаться на дефолт." (spec 28-29). This review cannot tell which word is the owner's last, so
the owner must say.

The fallback is not a detail: it carries the `fallbackModel` field (150-151), half the meaning of
`ContextBody.failure` (153), the Settings caption and line (46-51), the "When it fails" section
(208-242), and two arguments elsewhere: that a stored value need not be checked again because the
fallback covers it (82-83), and that a spoofed check is harmless because the fallback writes the
summary (359-360). Without the fallback:

- `fallbackModel` and the two-attempt timing go; `failure` stays, to say why there is no summary;
- the Settings line becomes "The last summary failed: <model>, <reason>";
- a stored custom value that later stops working leaves every call without a new summary, waiting
  once per call by rule 4 (254-255), until the owner changes it; lines 82-83 and 359-360 must be
  rewritten on that basis.

The PR body also states the fallback as a decision ("On an error, the default"), so it changes with
the spec.

### F2. Important: Unmute during Start's loading takes the microphone, or ends the call

The spec keeps the microphone off during the loading by not emitting `.startLocalVAD` (262-266),
and says nothing of Mute and Unmute. Mute and Unmute are handled in any phase but `.off`, so
during the loading Mute then Unmute emits `.unmuteMicrophone` (`CallMachine.swift:205-213`).
`Bridge.run` lets it through, since `phase != .off` (`Bridge.swift:323-326`, `mayTakeMicrophone`
at 345). On the page, `LB.unmute()` calls `mic.unmute()`, which calls `attach()` and acquires the
input (`microphone.js:70-74`, 37-58): macOS's prompt and indicator appear before the summary, the
opposite of the owner's decision. `listen` has not run, so `pump` is undefined and
`connect: (node) => node.connect(pump)` (`audio.js:111`) throws, `failMicrophone` runs `stop()`, and
the call ends with a microphone failure. This was traced in the code, not run.

Fix in the spec: while loading, the machine records Mute and Unmute and emits no microphone effect;
`.contextSettled` then emits `.startLocalVAD`, which already listens muted when muted
(`Bridge.swift:316-318`). One test.

### F3. Important: a result during Start's loading opens a line today

The spec says an answer that arrives during the loading "chimes and waits for the owner's first word"
(99-101) and "a delivery appends and chimes but cannot open a line" (266), as if it followed from
`.listening`. It does not: `(.listening, .deliver)` with `opensLine` true emits
`.openRealtimeForResult` (`CallMachine.swift:221-227`), and `opensLine` holds for the target's answer
whenever its conversation has a line of the owner's (`Bridge.swift:547-551`), the usual case on a
second call. The voice would then speak before the context is in, which the owner's decision rules
out. The spec must state the new machine rule (in `.listening` while loading, a delivery appends
and chimes) and its test. Whether the owner prefers that, or the result's line to open at once,
is question O3 below. If it only chimes, the spec should also say whether `.contextSettled` opens
the line for a result that would have opened it, so the owner who walked away still hears the answer
once the context is in.

### F4. Important: a summary that lands before `.start` is lost to the machine

The ask goes out at the press, while codex launches (262), and `.start` is sent only after
`controller()` returns (`Bridge.launch`, `Bridge.swift:162-172`). A cold codex launch can take
longer than a cached or failed summary: the summary or `failure` then arrives while the machine is
`.off`, where `.contextSettled` does nothing (`(.off, _): return []`, `CallMachine.swift:200`), and
the following `.start` waits to the limit for a summary that already came. The spec should say that
`.start` carries whether the context is already settled (the Bridge knows: no open ask, or the
session ended a wait), so a settled context emits `.startLocalVAD` at once.

### F5. Important: the evidence leaves out the measured end-to-end time

The spec cites first-token times (335) and the research note's derived estimate of 6 to 8 s for
Sonnet low at 100k input (296-297). The same note measures the average end-to-end time of single
requests at low effort as **21.4 s for Sonnet 5.5 and 23.8 s for Haiku 5.5** (Artificial
Analysis, `summary-model-research.md` section 3), close to today's felt 20 s. Its likely cause for the slow
first tokens is thinking (section 3), which Claude Code does not let a request turn off
(section 4). The figure is a third party's, for its own prompts, and unverified on the mod's path. If that holds on the
mod's path, the Start limit (at most 30 s) means 20 to 30 s of a Start with the microphone off, and
the later line's limit (at most 15 s) passes on most lines, so the later-line wait would cost up to
15 s and rarely deliver. The comparison decides, as the spec says (290-297, 329), but the spec
should cite the end-to-end figure next to the estimate, and say what happens if Sonnet low is near
20 s: then the default and the limits go back to the owner before the wait is built, not after.

### F6. Medium: what a pinned id does on Bedrock, Vertex and Foundry, and the README line it needs

The spec says a pinned first-party id "can fail" off the first-party API, and the default with it
(337-339). Claude Code's documents say more (code.claude.com, `amazon-bedrock` and `model-config`,
read 2026-11-10 through Context7): since 2.1.200, an Anthropic model id passed as `--model` is
mapped to the provider's built-in id, to an inference profile found at startup, or to the
`modelOverrides` setting; before 2.1.200 it went to Bedrock as written. The README's floor is
2.1.301, and `complete` resolves "like a `--model` value". So `claude-sonnet-5-5` should resolve on
those providers where they offer Sonnet 5.5 and the organisation allows it, and fail where they do
not. Unverified on a real provider; the spec should state the rule, not "can fail".

Today's fork works wherever the session works, so where the provider lacks the pinned model, an
update turns a working summary into none. The owner confirmed pinned ids (36-38), so this is not a
reopening, but the README's known limitations and the CHANGELOG line (370) must say it, and the
documents list (363-370) does not include it.

### F7. Medium: the check conflates a passing overload with a bad model

The table at 74-79 refuses on any API error. The engine's result carries the error's kind beside
`status`: `error: ModelApiError` (`ModelCompleteResult`, `api-error` arm), where `rate_limit`,
`overloaded` and `server_error` "may clear on their own" and `model_not_found`,
`invalid_request`, `authentication_failed` and `billing_error` will not. The wire at 153 and 155
carries only `status`. Carry `error` on `POST /v1/model-check` and `ContextBody.failure`, and have
Settings say "try again" for the three passing kinds rather than calling the model refused.

### F8. Medium: Security understates the check's spoofing and leaves out `model.complete` hooks

- "One that guesses the check's `id`" (358-359): no guess is needed. A local process that joins
  with `writesSummaries: true` and makes itself the target, both of which SECURITY.md already
  lists, is the session the check is handed to (65-66), with its `id`. The sentence should say so.
- `$.model.complete` fires the engine's `model.complete` hook (`ModelCompleteInput`): any other mod
  in the session sees the whole transcript as `e.prompt`, may rewrite it, and may answer without
  sending it. Today's `$.model.fork` sends no such event that the types document. Those mods are
  the owner's own, so this is no new adversary, but "the transcript goes to Anthropic through the
  session's own client" (352-353) claims more than the code enforces, and the README's privacy
  section would inherit it.
- "The transcript stays with Anthropic" (22) holds on the first-party API only; on Bedrock, Vertex
  or Foundry it goes where the session's own requests go. Say that.
- The planned SECURITY.md wording, "the summary is written from the session's text without tool
  output" (366-367), would claim more than the code enforces. The cut lives only in the new
  `transcript.ts`, on an ask that names a model: with an app older than the mod, or a mod older than
  the app, the fork still sends the whole request, tool output included (`context.ts:17`). Even on
  the new path an assistant's text often quotes tool output and a user's row can hold a paste. Word
  it as a reduction on the current pair, not as a property: "a current mod with a current app leaves
  tool results and system reminders out; text that quotes them stays, and an older app or mod sends
  the whole transcript".
- The check's `reason` from the mod is shown beside the field (71-72), so it gets the same length
  and character check as F16; and the spec should say whether `POST /v1/model-check` takes a result
  only from the session the check was handed to.
- SECURITY.md's list gains one more line besides the check's: a joined process that never answers
  can hold a Start's microphone off up to the limit, once per call (rule 4). It is not a control
  question, only a line in the list.

### F9. Medium: "Start during it does nothing (`connecting` is set)" is untrue

In the spec's own design the loading is a machine state after `.start` (262-266). `launch()` has
returned by then, so `connecting` is nil (`Bridge.attempt`, `Bridge.swift:151-159`). Start does
nothing because the machine is not `.off` (`Bridge.swift:141`). The sentence reads as if the wait
sat in the attempt, an earlier design; a builder following it would test the wrong guard. Fix the
reason.

### F10. Medium: wait rule 3 repeats the 5 s drop and the limit

Rule 3 ends the wait when `GET /v1/next` has not handed over the ask within 3 s (253). A session
that stops polling is dropped after 5 s, which ends the wait (257; `SessionRegistry.swift:58`), and
a session that polls hands the ask over within one poll (`SessionRegistry.poll`, 160-186: a reply
or a queued request goes first, one per poll, 0.2 s each for the target). So rule 3 saves at most 2 s
in a case the drop already ends, at the cost of a second timer and its tests. It also has nothing to
read today: `wantsContext` is a flag that `poll` clears without recording when
(`SessionRegistry.swift:80`, 184-185), so rule 3 needs new registry state the spec does not name.
Drop it, or name that state and the case the drop and the limit do not cover.

### F11. Low: `StatusReply.isLoadingContext` has almost no reader

The target's band already shows "Loading context…" from the mod's own state while the mod writes
(`band.tsx:16`, 57-58; `register.tsx` `deliverContext` calls `showContext($, 'loading')`). The app's
menu reads the Bridge, not the wire. The field's only reader is the band of a session that is not
the target, which already shows `connecting` (164-166). Drop the field, or name that reader.

### F12. Low: `$.model.fork` is kept as a second summary path for an older app

The fork stays in the mod "for that case alone", an app older than the mod (174-176). The mod could
instead use `complete` with its own default when the ask names no model: one summary path, at the
cost of the default's id in two places, which `AGENTS.md`'s one-fact-one-home rule counts against
it. The author's call; the spec should say which it chose and why.

### F13. Low: the ICE caveat is moot

The spec asks the real-voice check to confirm that an offer's ICE candidates survive the wait
(282-283). The page creates `new RTCPeerConnection()` with no ICE server (`audio.js:190`), so the
offer holds host candidates only, nothing is allocated on a server, and the remote side first sees
the offer at `voice.open`, after the wait. Drop the caveat and the cap's "partly for that".

### F14. Low: the compaction question is answerable, and 4096 rows is not the start

- `messages({ as: "api" })` is documented as "the ones the next request is built from, after the
  engine's normalization (the last compaction's summary in place of what it replaced)" (`ApiMessage`).
  Building the transcript from that form settles the "not verified" point at 137-138; the rows form
  says nothing either way.
- Both forms return at most the newest 4096 entries, so in a long session "the first user row ...
  for the session's goal" (187) is the 4096th from the end, not the first. Say so, or take the goal
  from the compaction summary when there is one.

### F15. Low: the check's 256-token cap saves nothing

A cap is not a cost: the reply to "Reply with OK." spends what it spends. The spec itself notes that
low-effort thinking counts against the cap (68-69), and in Claude Code thinking cannot be turned off
(research note, section 4), so a low cap can only add a false `empty-reply`. Use the default 1024.

### F16. Low: model names from the socket reach the log and Settings unchecked

`stats.model` and `failure.model` come from any local process (153, 156) and go into the unified log
line (313-317) and the Settings line (49-51). Apply the same `[A-Za-z0-9._:/@\[\]-]{1,128}` check the
setting gets (53-56), or show the app's own record of the model it asked for. Not a control; it keeps
nonsense out of the log, as line 55 says of the setting.

### F17. Low: the documents list misses four places

Besides those at 363-370:

- `README.md:316-317`, "which holds the text the session read": the new transcript leaves tool
  output out;
- `plugin/types/index.d.ts` `BandStatus`, if `isLoadingContext` stays (F11);
- `plugin/hooks/wire.ts:1-9`, the route list in the header, gains `POST /v1/model-check`;
- `docs/architecture/overview.md`'s route table (around line 195) gains the same route;
- the doc comment on `Bridge.context(_:)` (`Bridge.swift:703-707`), "the mod never sends one" of an
  empty summary, which a `writesSummaries` mod now does.

And the README sentence named as "line 44" (365) is at line 45.

### F18. Low: a target change during a later line's wait drops what was said

A new target cancels the attempt (`Bridge.swift:27-29`), and `closePeer` clears the page's queue
(`audio.js` `closePeer`, `line.clear()`), so words said to the old target during its wait are lost.
That is today's behaviour while a line connects, now for up to 15 s longer. Say it in the spec.

### F19. Low: small accuracy points

- 235-236, "since `context` is still nil": the next line asks because `needsContext` holds
  (`Bridge.swift:385-388`), which also covers a session with an older summary and a gap.
- 241 and `register.tsx` `contextAsked`: a second ask with a different model joins the summary on
  its way (`sending ??=`), which the first model writes. Harmless; say that a change of model takes
  effect at the next ask that finds none in flight.
- 215-216: an unknown model sits under `model-refused` (the engine rejects) in one row and a bad id
  under `api-error` in the next. Which one an unknown id gives is unverified; say so, as the spec does
  for a refusal.

### F20. Medium: a stale summary's post ends the wait and disarms the rest of the call

The wait ends at "the first `POST /v1/context` from that session, whatever it carries" (257). A
summary asked for before a gap or a forget is ignored (`Bridge.context(_:)` returns at the
`takeSummaryAsk` guard, `Bridge.swift:715`; `Continuity.swift:134-136`), yet it would still end the
wait, and rule 4 (254-255) would then count the session as having ended a wait with no summary, so
no later line in that call waits, although the next ask would succeed. The spec should say whether
an ignored post ends the wait (it should not, or the limit decides), and that only a post with no
summary, or a `failure`, counts for rule 4. The wait's end must sit before the guard either way.

### F21. Medium: whether Start asks a session on an older mod is unsaid

Today only a line that opens asks (`Bridge.swift:426-428`); the spec moves an ask to the press
(262). It says no wait applies to an older mod (170-172), not whether the press asks it. If it does,
pressing Start on an older mod's session costs a fork on the session's own model and effort, Opus
5.5 at High for the owner, before anyone speaks and even if nobody does. Say that the press asks
only a session whose mod said `writesSummaries`, and that an older mod's line asks as today.

### F22. Low: a 200 ms tick costs more than a round trip and a band write

Every tick also runs `follow`, which reads the session's id and its record in the registry file
for the title (`register.tsx:241-247`, called at 274), and writes the band through `update` (281).
At 200 ms that is five file reads a second for the whole call. The spec should count it, and have a
fast tick skip `follow` (a title can follow at the 1 s cadence) as well as an unchanged band.

### F23. Low: no answer for a floor run that finds `complete`'s options missing

The calls are checked against 2.1.319 only; the floor run on 2.1.301 "is what will check these
calls there" (120-121). If `complete` lacks `system`, `effort`, `timeoutMs` or `signal` on 2.1.301,
the README's floor must rise, which is the owner's call (O6). Name that now, and run the floor
check in the plan's first step that calls `complete`.

## Simplification and redundancy

Is the architecture elegant enough? Mostly. The split is sound: the setting and the wait in the app,
the model call in the mod, the choice carried on the ask. Placing the later line's wait before
`voice.open` rather than on an open line is the right call. What makes it heavier than it needs to
be is, in order of weight: the fallback (F1, if the owner confirms none, about a quarter of the
spec goes), wait rule 3 (F10), `isLoadingContext` on the wire (F11) and the second summary path
(F12).

One more, for the author to weigh: the "when the call waits" test (248-255) serves both the Start
wait and the later line's. The spec should say it is one Bridge function used by both, so a change to
it lands once.

Suggestions from the `simplify` reviewers that this review declines:

- **Drop the model check and rely on the fallback**: reopens the owner's decision.
- **Gate on `modVersion` instead of `writesSummaries`**: the repository's pattern is a capability
  flag (`JoinBody.syncs`), and a version compare misreads development builds.
- **Fold the check into a context ask with a dry-run flag**: mixes two answers on one route and
  makes `POST /v1/context` carry a result that is not a summary.
- **A long poll instead of the 200 ms poll**: the owner chose the 200 ms poll, and the mod's
  serial queue (`register.tsx`, "a held poll would outlast the engine's patience") makes a held
  `GET /v1/next` a larger change.
- **A real `CallPhase.loadingContext`**: older bands are already installed and throw on it
  (`band.tsx:42`); the spec's mapping is the compatible one. Making the new band tolerate an unknown
  phase is still worth one line, so the next phase needs no mapping.
- **Model the Start wait in the Bridge instead of the machine**: with the machine `.off` during the
  wait, a result is dropped (`CallMachine.swift:200`); the spec's machine state keeps it.
- **A smaller `maxTokens` for the summary, or 16 for the check**: a cap is not a cost (F15), and
  thinking counts against it.
- **Cache marks on the transcript**: the spec's reasoning holds; the tail moves, and a fallback on
  another model reads no other model's cache.
- **Use `fork({ effort: "low" })` as the default**: the owner's list does not include it; the
  comparison measures it, and the spec sends it back to the owner if it wins (330).
- **Log through `$.ui.log`**: that writes into the session's transcript, not a log.
- **Reuse PR #72's `--call-stats`**: it samples the audio peer, debug builds only.

## Plan-readiness

A builder can plan from this spec once F1 is settled and F2 to F4 are written into it. The time
limits are rules, not numbers, until the comparison runs; the plan can carry them as constants to
fill in, as the spec intends.

### Questions only the owner can answer

O1. **Откат на модель по умолчанию.** В решениях, переданных на ревью, сказано «без перехода с
модели на модель». Спецификация в последнем коммите делает обратное: если выбранная модель не
справилась, сводку пишет Sonnet 5.5, со ссылкой на ваши слова «Лучше просто в случае ошибки
переключаться на дефолт». Что верно: переход на Sonnet 5.5 при ошибке или никакого перехода (тогда
звонок идёт без новой сводки, а в настройках видно, почему)?

O2. **Если перехода нет:** сохранённая своя модель может позже перестать работать (её убрали,
сменился провайдер). Достаточно строки в настройках, или проверять сохранённое значение снова,
например при каждом запуске приложения?

O3. **Ответ Claude во время загрузки контекста при Start.** Сейчас такой ответ сам открывает
голосовую линию и голос его произносит. Спецификация предлагает во время загрузки только звонок, а
ответ подождёт вашего первого слова. Так и оставить, или ответ может открыть линию сразу, ещё без
сводки?

O4. **Смена цели во время загрузки при Start.** Спецификация в этом случае заканчивает загрузку и
включает микрофон, а первая линия новой сессии уже ждёт сводку по правилу для поздних линий. Или
загрузку нужно начать заново для новой сессии, с выключенным микрофоном?

O5. **Если Sonnet 5.5 на low окажется близко к нынешним 20 с** (замер в заметке исследования даёт
21,4 с от запроса до ответа): ждать ли столько при каждом первом Start сессии, или выбрать другую
модель по умолчанию до того, как строить ожидание?

O6. **Нижняя версия Claude Code.** Если на 2.1.301 у `$.model.complete` не окажется нужных
параметров (`effort`, `timeoutMs`, `system`), можно ли поднять минимальную версию в README до той,
где они есть?

### Points a builder can settle

- F2: the machine records Mute and Unmute while loading and emits no microphone effect.
- F4: `.start` knows whether the context is already settled.
- F20: which posts end a wait, and which count for rule 4.
- F21: the press asks only a `writesSummaries` mod.
- F22: a fast tick skips `follow` and an unchanged band.
- F7: carry `error` on the check's result and on `failure`.
- F9, F10, F11, F13, F15, F19: as each finding says.
- F14: build the transcript from `messages({ as: "api" })` or say why not.
- F16: check model names from the socket.
- F23: the floor run on 2.1.301 runs in the first step that calls `complete`.
- Wire: `Work.context` gains associated values in `Wire.swift`, so every `switch` on `Work` changes;
  the fixture list at 159-161 already names the new examples.
