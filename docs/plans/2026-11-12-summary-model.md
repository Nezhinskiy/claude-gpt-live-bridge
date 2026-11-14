# A summary model of its own, and a voice that waits for its context: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to
> implement this plan. **The wave is the dispatch unit:** one implementer per lettered wave, not one
> per task, and one final review per PR, not per wave. Inside a wave every task keeps its own failing
> test, its own verification and its own commit. Steps use checkbox (`- [ ]`) syntax for tracking.
> The gate is run by the controller, never by a subagent, and only after the owner agrees at that
> moment. Revised 2026-11-12 after the plan review (`2026-11-12-summary-model-plan-review.md`,
> findings I-1 to I-9, R-1 to R-3, M-1 to M-9).

**Goal:** the summary the voice gets is written by a model chosen in Settings (Haiku 5.5 by
default, always at low effort, with a fallback to Haiku), every ask is answered, and no line reaches
the voice before its context, as the spec describes.

**Architecture:** the app records each ask with the model it named and puts that model and the
default on the ask; a mod that says `writesSummaries` writes with `$.model.complete` over a trimmed
transcript, falls back once, and always answers, with `failures` and `stats`. One record, the
session's open ask in `Continuity`, is what the menu, the wait and the glyph read.

**Tech Stack:** Swift 6 (SwiftUI, AppKit, Swift Testing) in `app/`; TypeScript on Claude Code's
plugin engine in `plugin/` (`claude plugin test`, `node --test` for pure modules); JSON fixtures in
`wire/fixtures/`.

**Spec:** [`docs/specs/2026-11-09-summary-model-design.md`](../specs/2026-11-09-summary-model-design.md).
For a current app with a current mod it closes [BR-003](../bugs/BR-003.md): `complete` needs no
snapshot of the main thread, every ask is answered, and a failure shows in the band and in Settings.
An older app with a current mod still forks and stays as BR-003 describes; the entry says so when it
closes.

## Waves

| Wave | Tasks | Branch | Depends on |
|---|---|---|---|
| A | 1 | `feat/summary-ask-timing` | `dev` |
| B | 2-4 | `feat/summary-model` | A merged |
| C | 5-6 | `feat/summary-model` (same PR as B) | B |
| gate | — | none (results go into the spec) | B+C merged and installed, the owner's go-ahead |
| D | 7-8 | `feat/summary-wait` | the gate's limit |
| E | 9-10 | `feat/summary-wait` (same PR as D) | D |
| F | 11-12 | `feat/summary-model-check` | E merged |

```
dev ── A ── B ── C ── gate ── D ── E ── F
```

Edges, from the Interfaces blocks: B consumes nothing of A but rebases on it (both touch
`Bridge.context(_:)`); C consumes B's wire (`Work.context(model:fallbackModel:)`, `SummaryFailure`,
`JoinBody.writesSummaries`); D consumes C's recorded ask (`Continuity` asks with a model) and the
gate's limit; E consumes D's `summariesInFlight`; F consumes C's `SummaryModel` and B's
`writesSummaries`. D, E and F all edit `Bridge.swift`, `BridgeTests.swift`, `SECURITY.md` and
`docs/architecture/overview.md`, so they run one after another (M-1).

Four PRs: A; B+C; D+E; F. Dispatches: 6 implementers, 4 final reviews, 4 scoped re-reviews, and the
gate by the controller.

## Global Constraints

- No third-party Swift packages; no runtime npm dependency in the mod.
- A wire change touches `app/Sources/BridgeCore/Wire/Wire.swift`, `plugin/hooks/wire.ts` and
  `wire/fixtures/` together; `WireTests` and the mod's roundtrip test read every new fixture.
- Fixtures use `00000000-…` ids and `Example session` only.
- Pinned ids `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`; default
  `claude-haiku-5-5`, in the app alone. Effort is always `low`, a constant in the mod, never on the
  wire.
- Settings caption, exactly: "Writes the summary the voice gets as context, always at low effort,
  on your Claude usage. If another model fails, Haiku 5.5 writes it instead."
- Custom text: trimmed, `^[A-Za-z0-9._:/@\[\]-]{1,128}$`, refused before any check; a stored value
  that fails it loads as the default (M-3).
- **The app shows no text a local process wrote** (I-3): an `error` kind is shown only if it is
  one of `rate_limit`, `overloaded`, `server_error`, `model_not_found`, `invalid_request`,
  `authentication_failed`, `billing_error`; any other value shows as "an error". There is no
  `status` field on the wire.
- **Logs** (I-4, M-8): the app's lines about summaries are `Logger` `.debug` lines (subsystem
  `com.getlivebridge.livebridge`, category `summary`), written by the `LiveBridge` target from what
  `Bridge` reports; numbers and a model as its listed name or `custom`, never a custom string, a
  session id or text. CONTRIBUTING says the lines exist and how to stream them.
- Version pairs behave as the spec's Versions section says; the fork stays only for an ask with no
  `model`, and is deleted in the first mod release after the app that sends `model` has been the
  oldest supported app for one release; the CHANGELOG's Deprecated section says so (M-6).
- LiveBridge never answers a Claude Code permission prompt; the summary model has no tools.
- Docs change in the same PR as the code, `docs/i18n/README.*.md` and `site/index.html` included.
  The plan names the sentences to change by quoting them, never by line number (M-7).
- Conventional Commits; no AI attribution anywhere; `scripts/check.sh` exits 0 before every commit.

## Review Focus

1. **A target on an older mod** (no `writesSummaries`): no line waits; it is asked when a line opens,
   as today. Task 7's `anOlderModIsNeverWaitedFor`.
2. **A target change while a summary is in flight,** from the menu, the band or the registry after
   a drop: the waiting line closes, the old summary is stored when it lands, the new target is asked.
   Task 7's `aTargetChangeEndsTheWaitAndAsksTheNew`, `aRetargetAfterADropAsksTheNewTarget`.
3. **Stop or Reconnect during a wait:** Stop opens nothing; Reconnect waits again for the same ask.
   Task 7's `stopDuringTheWaitOpensNothing`, `aReconnectDuringTheWaitWaitsForTheSameAsk`.
4. **A gap while a summary is written:** the stale answer is posted and ignored, and the fresh ask is
   not blocked behind it. Task 4's `aGapDuringTheWriteStillPosts`, Task 5's `aFreshAskReplacesAStaleOne`.
5. **A settings file from 0.5.x, or a hand-edited bad value:** both load as Haiku. Task 5's
   `aFileFromBeforeItGetsHaiku`, `aBadStoredValueGetsHaiku`.

---

## Wave A — Task 1: how long an ask takes, measured by the app

The reader is BR-003's unexplained eight minutes and the gate (I-6). No wire change.

### Task 1: the ask's time to answer

**Files:** `Continuity.swift` (an accessor for the open ask's `at`), `Bridge.swift` (`context(_:)`
reports, an init parameter), new `app/Sources/BridgeCore/Call/SummaryLog.swift`, `App.swift` (writes
the line); `CONTRIBUTING.md` (where the lines are and how to stream them); tests new
`SummaryLogTests.swift`, `BridgeTests.swift`.

**Interfaces — produces:**
- `struct SummaryTiming: Sendable, Equatable { askedFor: TimeInterval; stale: Bool; hadSummary: Bool;
  model: String?; stats: SummaryStats? }` (`model` and `stats` nil until Wave B/C fill them).
- `enum SummaryLog { static func line(_ timing: SummaryTiming) -> String }`: `key=value` pairs,
  durations in ms, `model=` the listed name, `custom`, or `fork` when nil.
- `Bridge(… reportsSummary: @escaping @Sendable (SummaryTiming) -> Void = { _ in } …)`, called by
  `context(_:)` for every post that finds an ask, before `takeSummaryAsk` clears it.

- [ ] **Step 1:** failing tests: `SummaryLogTests.theLineHoldsNumbersAndTheModelNameOnly` (a custom
  id `arn:aws:bedrock:eu-west-1:123456789012:x` logs as `model=custom`, the line has no `1234`);
  `aLineWithoutAModelSaysFork`; `BridgeTests.aSummaryReportsHowLongItsAskTook` (ask at t, post at
  t+7 s → `askedFor == 7`); `aStaleAnswerIsReportedAsStale`.
- [ ] **Step 2:** implement; `App.swift` writes `Logger(subsystem: Paths.bundleID, category:
  "summary").debug(...)` with the line `privacy: .public` (it holds no free text).
- [ ] **Step 3:** CONTRIBUTING: one paragraph beside "Reading debug mode's numbers" with
  `log stream --level debug --predicate 'subsystem == "com.getlivebridge.livebridge" AND category == "summary"'`.
- [ ] **Step 4:** `swift test --filter "SummaryLogTests|BridgeTests"`, `scripts/check.sh`; commit
  `feat: log how long a summary ask takes to be answered`.

## Wave B — Tasks 2-4: the mod writes with the chosen model, and answers every ask

### Task 2: the wire for model, fallback, failures, stats and `writesSummaries`

**Files:** `Wire.swift`, `wire.ts` (and its header's route list), fixtures
`next-context-model.json` (a model and a fallback), `join-writes-summaries.json`,
`context-stats.json`, `context-fallback.json`, `context-failed.json`; every `switch` on `Work` in the
app; `WireTests.swift`, `plugin/tests/roundtrip.test.tsx`.

**Interfaces — produces** (same names in `wire.ts`):
- `Work.context(model: String? = nil, fallbackModel: String? = nil)`; JSON
  `{"kind":"context","model":…,"fallbackModel":…}`, keys absent when nil.
- `JoinBody.writesSummaries: Bool?`.
- `struct SummaryFailure: Codable { enum Reason: String { modelRefused = "model-refused",
  apiError = "api-error", emptyReply = "empty-reply", timedOut = "timed-out" }; reason: Reason;
  error: String? }`; `ContextBody.failures: [SummaryFailure]?`.
- `struct SummaryStats: Codable { durationMs: Int; transcriptChars: Int; inputTokens: Int;
  outputTokens: Int }`; `ContextBody.stats: SummaryStats?` (I-6: no cache fields, none optional).

- [ ] **Step 1:** failing tests: each new fixture decodes and round-trips in both suites;
  `anAskWithNoModelEncodesAsBefore` (`next-context.json` equals `Work.context()`).
- [ ] **Step 2:** implement; the registry still hands `.context()` (Task 5 fills it).
- [ ] **Step 3:** both suites pass; commit `feat: let a context ask name a model and a summary name
  its failures`.

### Task 3: `transcript.ts`, and `summarize` on `complete`

**Files:** new `plugin/hooks/transcript.ts` (added to `plugin/tsconfig.pure.json`'s `include`),
`plugin/hooks/context.ts`; new `plugin/tests/unit/transcript.unit.ts` (I-7), `plugin/tests/context.test.tsx`,
`plugin/tests/fake-bridge.ts` (a `complete` that answers per model, and `session.messages`).

**Interfaces — consumes:** Task 2's types. **Produces:**
- In `transcript.ts`, a local structural type, no import from `'claude-code'`: `type TranscriptMessage
  = { role: 'user' | 'assistant'; content: string | readonly { type: string; text?: string; name?:
  string }[] }`; `export function transcriptText(messages: readonly TranscriptMessage[], budget =
  120_000): string`; `MESSAGE_CAP = 6_000`, `FIRST_CAP = 4_000`.
- `export async function summarize($, ask: { model?: string; fallbackModel?: string }, deadline:
  number): Promise<{ text: string; failures: SummaryFailure[]; stats?: SummaryStats }>`. No `model`
  forks as today, with no stats. A `model` calls `$.model.complete({ model, system: PROMPT, prompt:
  <transcript marked as data>, effort: 'low', maxTokens: 4096, timeoutMs: deadline - now })`, then
  `fallbackModel` once if named, by the spec's "When it fails" table. `deadline` is the one 60 s
  budget (I-1), set by the caller.

- [ ] **Step 1:** failing unit tests: `remindersToolResultsAndThinkingAreLeftOut`,
  `aToolUseIsItsNameAlone`, `aLongMessageKeepsItsStartAndEnd` (6,001 chars → start, marker, end),
  `theGoalThenTheNewestUntilTheBudget` (first ≤ 4,000, then newest backwards, a marker with the
  count left out, total ≤ budget). `npm run test:unit` runs them.
- [ ] **Step 2:** failing tests in `context.test.tsx`: `aNamedModelWritesWithComplete` (`model`,
  `effort: 'low'`, `maxTokens: 4096`; no fork; `stats` from `usage` and the clock);
  `aFailedModelFallsBackOnce` (a rejection → `model-refused`; `api-error` `overloaded`;
  `empty-reply`: the fallback writes, one failure); `aTimeOutDoesNotFallBack` (the fake `complete`
  holds until its `timeoutMs` passes on the mocked clock, then answers `aborted` → `timed-out`, no
  second call); `noFallbackWhenTheModelIsTheDefault`; `bothFailingGivesNoTextAndTwoFailures`.
- [ ] **Step 3:** run `scripts/check-floor.sh`. If 2.1.301 lacks `$.model.complete` with `system`,
  `effort`, `maxTokens` or `timeoutMs`, or `$.session.messages({ as: 'api' })`, raise the floor to
  the first version that has them, in the README, the CHANGELOG and every copy
  `claude-code-floor.test.sh` checks. Nothing else counts for the floor (I-8).
- [ ] **Step 4:** implement; suites and `npm run test:unit` pass; commit `feat(mod): write the
  summary with the model the app names`.

### Task 4: every ask is answered, a failure shows in the band, and the join says so

**Files:** `plugin/hooks/register.tsx` (`contextAsked`, `deliverContext`, `writeAndPost`, the cache,
the join body, `showContext`), `plugin/hooks/link.ts` (`context` body), `plugin/types/index.d.ts`
(the band's `context` gains `'failed'`), `plugin/hooks/band.tsx` (draws it), `plugin/hooks/context.ts`
(its header comment), `plugin/tests/context.test.tsx`, `band.test.tsx`.

**Interfaces — consumes:** Tasks 2-3. **Produces:** joins carry `writesSummaries: true`;
`contextAsked($, ask)` with the work's `model`/`fallbackModel`; the cache holds `{ model, text,
failures }`.

- [ ] **Step 1:** failing tests, one per exit, each naming what is posted (I-1):
  `noTurnsPostsEmptyWithoutFailures`; `bothModelsFailingPostsEmptyWithTwoFailures` (and the
  `NO_SUMMARY` line, and the band's `failed` note); `theDeadlinePostsTimedOut` (the outer
  `CONTEXT_TIMEOUT_MS` race no longer applies to an ask with a model: one budget);
  `aGapDuringTheWriteStillPosts` (the post is sent; the app ignores it as stale);
  `aThrowWhileReadingTheTranscriptPostsEmpty`; `anAskAfterAGapDoesNotJoinTheDoomedSend`.
  And: `anAskWithoutAModelIsAsBefore` (fork; nothing posted on `nothing-to-fork`; the test
  `nothingToForkIsNoFailure` stays as the older-app case); `aCachedFallbackSummaryKeepsItsFailures`
  (Opus asked, Haiku wrote; the next Opus ask replays text and failures, no stats) (I-2);
  `aJoinSaysItWritesSummaries`.
- [ ] **Step 2:** implement. `context.ts`'s header ("written by the session's own model over its own
  transcript") becomes true of `complete`.
- [ ] **Step 3:** `claude plugin test plugin`, `scripts/check.sh`; commit `feat(mod): answer every
  context ask, and show a failed one in the band`.

## Wave C — Tasks 5-6: the setting, the recorded ask, and the docs

### Task 5: `summaryModel`, and an ask that records its model

**Files:** `Settings.swift`, new `app/Sources/BridgeCore/SummaryModel.swift`, `Continuity.swift`
(`SummaryAsk` gains the models; a stale ask is replaced), `SessionRegistry.swift`, `Bridge.swift`
(init, `askForContext`, `context(_:)`), `App.swift`; tests `SettingsTests.swift`, new
`SummaryModelTests.swift`, `BridgeTests.swift`, `ContinuityTests.swift`.

**Interfaces — consumes:** Task 2's wire, Task 1's `SummaryTiming`. **Produces:**
- `enum SummaryModel { static let `default` = "claude-haiku-5-5"; static let listed: [(id: String,
  name: String)]` (Haiku 5.5, Sonnet 5.5, Opus 5.5); `static func accepted(_ text: String) ->
  String?`; `static func name(_ id: String) -> String` (the listed name, else "Custom model") }.
- `Settings.summaryModel: String`, decoded through `accepted`, else the default.
- `Bridge(… summaryModel: @escaping @Sendable () -> String …)`. To a mod that said
  `writesSummaries` an ask is `.context(model: m, fallbackModel: m == default ? nil : default)`;
  to any other, `.context()`.
- `SummaryAsk` gains `model: String?` and `fallbackModel: String?`, recorded when asked (M-4).
  `noteSummaryAsk` replaces an ask that is stale (I-1).
- `SessionRegistry.writesSummaries(_ id:) -> Bool`, `requestContext(for:model:fallbackModel:)`.
- `struct SummaryReport: Equatable { asked: String; fallback: String?; failures: [SummaryFailure];
  wrote: Bool }`, `var line: String?`: nil when the asked model wrote it; "The last summary used
  Haiku 5.5: Opus 5.5 was refused." when the fallback did; when none did, "The voice got no new
  summary: " and each failed model in turn, joined by ", then ". Per reason: `model-refused` "was
  refused", `api-error` "returned an error (<kind>)" for a known kind and "returned an error"
  otherwise, `empty-reply` "wrote nothing", `timed-out` "ran out of time".
- `Bridge.lastSummary: SummaryReport?`, set only by an answer to an ask that named a model (I-2).

- [ ] **Step 1:** failing tests: `aFileFromBeforeItGetsHaiku`; `aBadStoredValueGetsHaiku`;
  `customTextIsTrimmedAndChecked` (`" claude-x-1 "` → `"claude-x-1"`; `""`, `"a b"`, 129 chars,
  `"x;rm"` → nil); `anAskNamesTheModelAndTheDefault`; `theDefaultHasNoFallback`;
  `anOlderModGetsAPlainAsk`; `aFreshAskReplacesAStaleOne`; `theReportSaysWhichModelWrote` (the
  three shapes, and both models named when both fail); `anUnknownErrorKindIsNotShown` (`"<b>hi"` →
  "returned an error"); `anOlderModsAnswerLeavesTheReportAlone`; `theLogNamesTheAskedModel`.
- [ ] **Step 2:** implement; commit `feat: send the summary model chosen in Settings`.

### Task 6: the picker, and the documents

**Files:** `app/Sources/LiveBridge/SettingsView.swift` (the Context tab's `Section("Sync")`),
`App.swift`; README, `SECURITY.md`, `CHANGELOG.md`, `docs/i18n/README.*.md`, `site/index.html`;
the comments on `Settings.loadContextOnFirstCall` and `Bridge.pauseHoldsBackSummary`.

**Interfaces — consumes:** Task 5. No Custom… entry here: it comes whole in Wave F (R-1).

- [ ] **Step 1:** a **Summary model** picker in `Section("Sync")`, under "Load a session's context
  on its first call": the three listed names; the caption from Global Constraints; under it
  `lastSummary?.line` when non-nil.
- [ ] **Step 2:** sentences to change (M-2, M-7):
  - Settings caption "It is written from the whole transcript, paused text included, and goes to
    OpenAI.", and the two comments that say "written from the whole transcript": the summary is
    written from the transcript without tool output, thinking or reminders, paused text included.
  - README "the line asks the session's own model for a" summary: the model set in Settings.
  - README "transcript by itself, which holds the text the session read": what the trimmed
    transcript holds.
  - README and SECURITY.md sentences "written from the whole transcript": the spec's reduction.
  - README known limitations: a provider without the pinned default gets no summary.
  - CHANGELOG: summaries use Haiku 5.5 by default, on an update too; the provider limitation; the
    floor if Task 3 raised it; the fork's deprecation (Global Constraints).
  - BR-003: `status: partially fixed`, with the scope: fixed for a current app with a current mod;
    an older app with a current mod still forks; the voice is not told of a failure (I-9).
- [ ] **Step 3:** `scripts/build-app.sh --run`: the picker shows and saves; screenshot for the PR;
  `scripts/check.sh`; commit `feat(app): choose the summary model in Settings`.

## The gate — the real mod, measured (controller only, the owner's go-ahead first)

After B+C are merged and installed (I-5): no throwaway mod, nothing re-implemented.

- [ ] Ask the owner, with the cost: about three summaries on Haiku over one long session's
  transcript, and one resumed session.
- [ ] On a `claude --fork-session` copy of one real long session, with the installed app and the
  current mod and Haiku 5.5 chosen: three Load context presses, each read from the Task 1 log line
  (`askedFor`) and the post's `stats`.
- [ ] The resume case: resume a session that has turns, `/live`, Load context before any turn ends;
  a summary must arrive (`$.session.messages({ as: 'api' })` returns the history before the first
  turn), else stop and report.
- [ ] One refusal probe: set a custom id that does not exist by editing `settings.json` (Wave F's
  field does not exist yet) and press Load context; record what came back.
- [ ] Write into the spec's "The time limit": the limit is twice the slowest of the three runs,
  clamped to 10 … 30 s; whether 120,000 characters fit; the resume result; the refusal's shape. If a
  run is over 30 s, stop and take the numbers to the owner. Commit `docs: record the summary model
  measurements`.

## Wave D — Tasks 7-8: the line waits for its context

### Task 7: one decision, the wait in `openLine`, early asks

**Files:** new `app/Sources/BridgeCore/Call/SummaryWait.swift`, `Bridge.swift` (`perform(.start)`'s
launch, every target change, `openLine`, `context(_:)`, dropped sessions, Stop, `reconnect`);
`docs/architecture/overview.md` (Start and the wait), `SECURITY.md` (a process that never answers
holds speech up to the limit, once per call); tests `BridgeTests.swift`, new `SummaryWaitTests.swift`.

**Interfaces — consumes:** Task 5's recorded ask and `writesSummaries`; the gate's limit.
**Produces:** `struct SummaryWait { static let limit: TimeInterval` (the gate's value); `mutating func
endedWithout(_ id: SessionID)`; `mutating func newCall()`; `func deadline(for id: SessionID, ask:
SummaryAsk?, writesSummaries: Bool) -> Date?` (nil: no wait) }. The ask in flight is `Continuity`'s
open, non-stale ask (R-3): `SummaryWait` keeps only rule 3's set. `Bridge.summariesInFlight:
Set<SessionID>` derives from the same asks. `SummaryTiming` gains `waited: TimeInterval?`, how long
the line waited, and `SummaryLog` writes it.

- [ ] **Step 1:** failing `SummaryWaitTests`: `noAskNoWait`, `anOlderModIsNeverWaitedFor`,
  `aWaitThatEndedEmptyIsNotRepeatedThisCall`, `theLimitCountsFromTheAsk`, `aNewCallWaitsAgain`,
  `aStaleAskIsNotWaitedFor`.
- [ ] **Step 2:** failing `BridgeTests`: `startAsksAtOnceForAWritingMod`,
  `theLineOpensAfterTheSummaryWithItInTheSeed`, `theLimitOpensTheLineWithoutIt`,
  `aResultWaitsLikeSpeech`, `stopDuringTheWaitOpensNothing`, `aTargetChangeEndsTheWaitAndAsksTheNew`,
  `aRetargetAfterADropAsksTheNewTarget` (M-5), `aReconnectDuringTheWaitWaitsForTheSameAsk`,
  `aLateSummaryReachesTheOpenLine`, `aDroppedSessionEndsTheWait`,
  `aPostForAnOlderAskDoesNotEndTheWait`.
- [ ] **Step 3:** implement: the wait sits after `makeOffer` and before the seed and `voice.open`;
  the phase stays `.connecting`; the page is unchanged. `swift test`; commit `feat: open a line only
  once its context is in`.

### Task 8: the menu and the band show the load

**Files:** `ContextLoads.swift` (keeps only the brief **Context loaded**; its own `pressedAt` and
60 s go, R-3), the app's menu wiring, `plugin/hooks/band.tsx` (an unknown phase draws as
`connecting`); README, CHANGELOG, translations; tests `MenuTests.swift`, `band.test.tsx`.

- [ ] **Step 1:** failing tests: `anyAskInFlightShowsLoading` (from `summariesInFlight`, Load
  context disabled); `anEmptyReplyGoesBackToLoadContext` (no **Context loaded**);
  `anUnknownPhaseDrawsAsConnecting`.
- [ ] **Step 2:** implement; docs; `scripts/check.sh`; commit `feat: show a summary loading whatever
  asked for it`.

## Wave E — Tasks 9-10: the glyph and the 200 ms poll

### Task 9: `loadingContext`

**Files:** `StatusPresentation.swift` (`Badge.loadingContext`, after `problem` and `approval`, before
`unheard`), `StatusItem.swift` (the three-quarter ring turning once a second, from
`git show eaab732^:app/Sources/LiveBridge/StatusItem.swift`, a still frame when motion is reduced);
tests `StatusPresentationTests.swift`.

- [ ] **Step 1:** failing `loadingContextShowsWhileTheTargetsSummaryIsInFlight` and its precedence.
- [ ] **Step 2:** implement; render the frames as a GIF and **show the owner before committing**;
  commit `feat(app): turn a ring while the context loads`.

### Task 10: the target polls every 200 ms

The owner chose it (spec, "Polling every 0.2 s"); kept despite R-2. The gate's and Task 1's numbers
say what it saves, in the PR body.

**Files:** `plugin/hooks/link.ts` (`POLL_MS = 200`; a session that is not the target polls on every
fifth tick), `register.tsx` (`follow` on every fifth tick; an unchanged band is not rewritten); tests
`lifecycle.test.tsx`, `offline.test.tsx`.

- [ ] **Step 1:** failing tests: `theTargetPollsFiveTimesASecond`, `othersPollOnceASecond`,
  `aFastTickDoesNotFollowTheTitle`, `anUnchangedBandIsNotRewritten`; offline and drop timings unchanged.
- [ ] **Step 2:** implement; `claude plugin test plugin`; `scripts/check.sh`; commit `feat(mod): poll
  five times a second while this session is the target`.

## Wave F — Tasks 11-12: a custom model, checked before it is saved

The owner chose a custom field with a check (spec, "Decisions"); kept despite R-1, and built whole
here, with no placeholder before it.

### Task 11: the check on the wire and in the mod

**Files:** `Wire.swift`, `wire.ts`, fixtures `next-check-model.json`, `model-check-ok.json`,
`model-check-failed.json`; `register.tsx`; `link.ts` (`modelCheck`); tests as in Task 2 and
`context.test.tsx`.

**Interfaces — produces:** `Work.checkModel(id: String, model: String)` (`"kind":"checkModel"`);
`struct ModelCheckBody { sessionId; id: String; ok: Bool; reason: SummaryFailure.Reason?; error:
String? }` at `POST /v1/model-check`.

- [ ] **Step 1:** failing tests: the fixtures round-trip; `aCheckSendsOneShortRequest` (`prompt:
  "Reply with OK."`, `effort: 'low'`, `timeoutMs: 15000`, no `maxTokens`); `anyTextIsOk`;
  `aRejectionIsModelRefused`; `anApiErrorCarriesItsKind`.
- [ ] **Step 2:** implement; commit `feat: check a summary model through a joined session`.

### Task 12: the app's check and the Custom… field

**Files:** `SessionRegistry.swift`, `Bridge.swift`, new `app/Sources/BridgeCore/ModelCheck.swift`,
`SettingsView.swift`, `App.swift`; `SECURITY.md` (the check takes a local process's word),
`docs/architecture/overview.md` (route table), README Settings and translations; tests
`BridgeTests.swift`, new `ModelCheckTests.swift`.

**Interfaces — produces:** `Bridge.checkModel(_ model: String) async -> ModelCheckResult`; `enum
ModelCheckResult: Equatable { case works, noSession, noAnswer, busy, refused(SummaryFailure.Reason,
kind: String?) }` with `message: String?` built by the app from the spec's table and Global
Constraints' known kinds. The session: the target if it `writesSummaries`, else the most recently
joined one that does; the result is taken only from it with the same `id`; 20 s or its drop is
`noAnswer`.

- [ ] **Step 1:** failing tests: `noSessionThatCanCheck` (nothing sent); `theTargetChecksFirst`;
  `aResultFromAnotherSessionIsIgnored`; `noAnswerIn20Seconds`; `aRateLimitIsBusy`;
  `aRefusalKeepsTheOldValue`; `anUnknownErrorKindIsNotShown`.
- [ ] **Step 2:** **Custom…** in the picker with a text field and **Check and save** (disabled, as
  **Checking…**, in flight; picking a list entry or saving the stored value checks nothing); the
  reason beside the field.
- [ ] **Step 3:** `scripts/build-app.sh --run`, a check with a joined session; screenshot;
  `scripts/check.sh`; commit `feat(app): check a custom summary model before saving it`.

## Execution contract

- **Implementer briefs** carry: report a mismatch between this plan and the tree instead of
  guessing; paste each verification's output; focused tests while iterating, one `scripts/check.sh`
  before each commit; no line numbers taken from this plan; nothing written outside the wave's
  worktree but a scratch folder in the session scratchpad; never kill by a name pattern; no nested
  subagents; no AI attribution.
- **Final review:** one per PR: a correctness seat and a "what can be deleted, and whom does this
  refuse" seat; a security seat for B+C (the transcript leaves through `complete`), D+E (holding
  speech) and F (a local process's word). Findings without replacement text; one scoped re-review,
  then stop.
- **Real models and real voice:** the gate, `scripts/smoke.sh` after D+E, and any probe that spends
  the owner's plan run only when the owner says yes at that moment.
- **Verification:** the controller re-runs `scripts/check.sh` only on a head it pushes, waits for CI
  before reporting, and re-derives each PR body before pushing. Nothing is pushed or merged without
  the owner's go-ahead.
- **One writer per worktree;** one `scripts/check.sh` per worktree at a time.
