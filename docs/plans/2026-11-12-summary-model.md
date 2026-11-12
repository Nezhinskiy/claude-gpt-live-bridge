# A summary model of its own, and a voice that waits for its context: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to
> implement this plan. **The wave is the dispatch unit:** one implementer per lettered wave, not one
> per task, and one final review per PR, not per wave. Inside a wave every task keeps its own failing
> test (where it has one), its own verification and its own commit. Steps use checkbox (`- [ ]`)
> syntax for tracking. The gate is run by the controller, never by a subagent, and only after the
> owner agrees at that moment.

**Goal:** the summary the voice gets is written by a model chosen in Settings (Haiku 5.5 by
default, always at low effort, with a fallback), every ask is answered, and no line reaches the
voice before its context, as the spec describes.

**Architecture:** the app puts the chosen model and the default on each context ask; a mod that
says `writesSummaries` writes with `$.model.complete` over a trimmed transcript, falls back once,
and always answers, with `failures` and `stats`. The Bridge decides in one place whether a line
waits for an ask in flight, and the menu, the band and the menu bar glyph show the load.

**Tech Stack:** Swift 6 (SwiftUI, AppKit, Swift Testing) in `app/`; TypeScript on Claude Code's
plugin engine in `plugin/` (`claude plugin test`); JSON fixtures in `wire/fixtures/`.

**Spec:** [`docs/specs/2026-11-09-summary-model-design.md`](../specs/2026-11-09-summary-model-design.md).
It closes [BR-003](../bugs/BR-003.md) for a current app with a current mod: `complete` needs no
snapshot of the main thread, and every ask is answered.

## Waves

| Wave | Tasks | Branch | Depends on |
|---|---|---|---|
| A | 1-2 | `feat/summary-stats` | `dev` |
| gate | — | none (results go into the spec) | the owner's go-ahead |
| B | 3-5 | `feat/summary-model` | A merged, the gate done |
| C | 6-7 | `feat/summary-model` (same PR as B) | B |
| D | 8-9 | `feat/summary-model-check` | C merged |
| E | 10-11 | `feat/summary-wait` | C merged, the gate's limit |
| F | 12-13 | `feat/summary-wait` (same PR as E) | E |

```
dev ── A ── gate ── B ── C ──┬── D (model check)
                             └── E (the wait) ── F (glyph, 200 ms poll)
```

Edges come from the Interfaces blocks: B consumes A's `SummaryStats`; C consumes B's wire
(`Work.context(model:fallbackModel:)`, `ContextBody.failures`); D and E consume C's
`SummaryModel`, `JoinBody.writesSummaries` and `Bridge`'s ask; E consumes the gate's limit; F consumes E's
`summariesInFlight`. D and E share no import and can run at once in separate worktrees.

Four PRs: A; B+C; D; E+F. Dispatches: 6 implementers, 4 final reviews, 4 scoped re-reviews, and
the gate by the controller.

## Global Constraints

- No third-party Swift packages; no runtime npm dependency in the mod.
- A wire change touches `app/Sources/BridgeCore/Wire/Wire.swift`, `plugin/hooks/wire.ts` and
  `wire/fixtures/` together, and `WireTests` and the mod's roundtrip test read every new fixture.
- Fixtures use `00000000-…` ids and `Example session` only.
- Pinned ids: `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`. Default
  `claude-haiku-5-5`. Effort is always `low`, a constant in the mod, never on the wire.
- Settings text, exactly: caption "Writes the summary the voice gets as context, always at low
  effort, on your Claude usage. If another model fails, Haiku 5.5 writes it instead."; check
  messages as in the spec's table.
- Accepted custom text: trimmed, `^[A-Za-z0-9._:/@\[\]-]{1,128}$`; refused before any check.
- Nothing the mod wrote is shown by the app; no model name comes back over the socket.
- The timing log is one line to the unified log (subsystem `com.getlivebridge.livebridge`,
  category `summary`): numbers and the model id, no text, no session id.
- A mod older than the app, and an app older than the mod, behave as the spec's Versions section
  says; the fork stays only for an ask with no `model`.
- LiveBridge never answers a Claude Code permission prompt; the summary model has no tools.
- Docs change in the same PR as the code, translations under `docs/i18n/` and `site/index.html`
  included, per the spec's "Documents that change with the code".
- Conventional Commits; no AI attribution anywhere; `scripts/check.sh` exits 0 before every commit.

## Review Focus

1. **A target on an older mod** (no `writesSummaries`): no line waits, it is asked when a line
   opens, as today. Task 10's `anOlderModIsNeverWaitedFor`.
2. **A target change while a summary is in flight:** the waiting line closes, the old summary is
   stored when it lands, the new target is asked. Task 10's `aTargetChangeEndsTheWaitAndAsksTheNew`.
3. **Stop during a wait:** nothing reaches codex, `voice.open` is never called. Task 10's
   `stopDuringTheWaitOpensNothing`.
4. **A summary that lands after the limit:** stored, and added to the open line. Task 10's
   `aLateSummaryReachesTheOpenLine`.
5. **A settings file from 0.5.x** (no `summaryModel`) and a stored custom value that later fails:
   the first loads as Haiku; the second falls back on every ask. Task 6's
   `aFileFromBeforeItGetsHaiku`, Task 4's `aFailedModelFallsBackOnce`.

---

## Wave A — Tasks 1-2: timing only, nothing else changes

### Task 1: `stats` on the wire, and the app's timing log

**Files:** `Wire.swift`, `wire.ts`, `wire/fixtures/context-stats.json`, `Bridge.swift`
(`context(_:)`), new `app/Sources/BridgeCore/Call/SummaryLog.swift`; tests `WireTests.swift`,
new `SummaryLogTests.swift`, the mod's roundtrip test.

**Interfaces — produces:**
- `public struct SummaryStats: Codable, Sendable, Equatable { durationMs: Int; transcriptChars:
  Int?; inputTokens: Int; outputTokens: Int; cacheReadTokens: Int; cacheWriteTokens: Int }`,
  same names in `wire.ts`.
- `ContextBody.stats: SummaryStats?`.
- `enum SummaryLog { static func line(stats: SummaryStats?, model: String?, askedFor: TimeInterval,
  waited: TimeInterval?) -> String }`: `key=value` pairs, `model=` the id or `fork`, durations in ms.

- [ ] **Step 1:** failing tests: `WireTests.aSummaryCarriesItsStats` decodes `context-stats.json`
  and round-trips it; `SummaryLogTests.theLineHoldsNumbersAndTheModelOnly` asserts the line for a
  given stats value contains `model=claude-haiku-5-5`, `inputTokens=`, `askMs=` and no `Alpha`
  when the summary text is "Alpha …"; `aSummaryWithoutStatsStillLogsTheAsk`.
- [ ] **Step 2:** implement; `Bridge.context(_:)` computes `askedFor` from the open ask's time
  before `takeSummaryAsk`, and logs through `Logger(subsystem: Paths.bundleID, category:
  "summary")` with every value `privacy: .public`. Until Task 6, `model` is nil (`fork`).
- [ ] **Step 3:** `swift test --filter "WireTests|SummaryLogTests"` and `claude plugin test plugin`
  pass; commit `feat: carry a summary's timing on the wire and log it`.

### Task 2: the mod measures what it writes

**Files:** `plugin/hooks/context.ts`, `plugin/hooks/register.tsx` (`writeAndPost`),
`plugin/tests/context.test.tsx`, `plugin/tests/fake-bridge.ts` (a fork's `usage`).

**Interfaces — consumes:** `SummaryStats` (Task 1). **Produces:** `summarize($):
Promise<{ text: string; stats?: SummaryStats }>`; `link.context(text, stats?)`.

- [ ] **Step 1:** failing test `aSummaryPostsItsStats`: on the mocked clock a fork of 2,000 ms
  with usage `{input: 900, output: 120, cacheRead: 800, cacheWrite: 0}` posts `stats` with those
  numbers and `durationMs: 2000`, `transcriptChars` absent (a fork reads no text).
- [ ] **Step 2:** implement, from the fork reply's `usage`; the clock is `$.clock`.
- [ ] **Step 3:** `claude plugin test plugin` passes, `scripts/check.sh` exits 0; commit
  `feat(mod): report how long a summary took and what it cost`.

## The gate — the comparison (controller only, owner's go-ahead first)

Per the spec's "The comparison": one throwaway mod outside the repository, on a `claude
--fork-session` copy of one real long session, four arms (today's fork, the fork at `low`,
`claude-haiku-5-5` low, `claude-sonnet-5-5` low), each recording duration, the four token counts
and the text, with the transcript built by the rules of Task 3 at 120,000 characters.

- [ ] Ask the owner, with the spec's cost estimate; run nothing before a yes.
- [ ] Write the results into the spec's "The time limit" section: the limit is twice Haiku's
  slowest run, clamped to 10 … 30 s; whether 120,000 characters fit; what a Haiku refusal and an
  unknown id came back as. If Haiku's run is over 30 s, stop and take the numbers to the owner.
- [ ] Commit `docs: record the summary model comparison`.

## Wave B — Tasks 3-5: the mod writes with the chosen model

### Task 3: the wire for model, fallback, failures and `writesSummaries`

**Files:** `Wire.swift`, `wire.ts` (and its header's route list), fixtures
`next-context-model.json`, `join-writes-summaries.json`, `context-fallback.json`,
`context-failed.json`; every `switch` on `Work` in the app; `WireTests.swift`, roundtrip test.

**Interfaces — produces:**
- `Work.context(model: String? = nil, fallbackModel: String? = nil)`; JSON
  `{"kind":"context","model":…,"fallbackModel":…}`, keys absent when nil.
- `JoinBody.writesSummaries: Bool?`.
- `struct SummaryFailure: Codable { enum Reason: String { modelRefused = "model-refused",
  apiError = "api-error", emptyReply = "empty-reply", timedOut = "timed-out" }; reason: Reason;
  status: Int?; error: String? }`; `ContextBody.failures: [SummaryFailure]?`.
- The same in `wire.ts`, names unchanged.

- [ ] **Step 1:** failing tests: each new fixture decodes and round-trips in both `WireTests` and
  the mod's roundtrip test; `anAskWithNoModelEncodesAsBefore` (the old `next-context.json` still
  equals `Work.context()`).
- [ ] **Step 2:** implement; the registry still hands `.context()` (Task 6 fills it).
- [ ] **Step 3:** both suites pass; commit `feat: let a context ask name a model and a summary
  name its failures`.

### Task 4: `transcript.ts` and `summarize` on `complete`

**Files:** new `plugin/hooks/transcript.ts`, `plugin/hooks/context.ts`; new
`plugin/tests/unit/transcript.test.ts`, `plugin/tests/context.test.tsx`, `fake-bridge.ts` (a
`complete` that answers per model).

**Interfaces — consumes:** Task 3's types, Task 2's stats. **Produces:**
- `export function transcriptText(messages: readonly ApiMessage[], budget = 120_000): string`,
  constants `MESSAGE_CAP = 6_000`, `FIRST_CAP = 4_000`.
- `export async function summarize($, ask: { model?: string; fallbackModel?: string }):
  Promise<{ text: string; failures: SummaryFailure[]; stats?: SummaryStats }>`: no `model` forks
  as today; a `model` calls `$.model.complete({ model, system: PROMPT, prompt: <transcript as
  data>, effort: 'low', maxTokens: 4096, timeoutMs })`, then `fallbackModel` once if named, the
  two inside one 60 s budget, by the spec's "When it fails" table.

- [ ] **Step 1:** failing unit tests in `transcript.test.ts`: `remindersToolResultsAndThinkingAreLeftOut`,
  `aToolUseIsItsNameAlone`, `aLongMessageKeepsItsStartAndEnd` (6,001 chars → start, marker, end),
  `theGoalThenTheNewestUntilTheBudget` (first message ≤ 4,000, then newest backwards, a marker with
  the count left out, total ≤ budget).
- [ ] **Step 2:** failing tests in `context.test.tsx`: `aNamedModelWritesWithComplete` (the call's
  `model`, `effort: 'low'`, `maxTokens: 4096`; no fork); `aFailedModelFallsBackOnce` (for each of
  a rejection → `model-refused`, `api-error` 529 `overloaded`, `empty-reply`: the fallback writes,
  `failures` has one entry); `aTimeOutDoesNotFallBack` (`aborted` → `timed-out`, no second call);
  `noFallbackWhenTheModelIsTheDefault`; `bothFailingGivesNoTextAndTwoFailures`.
- [ ] **Step 3:** run `scripts/check-floor.sh`. If 2.1.301 lacks `system`, `effort`, `timeoutMs`
  or `signal` on `complete`, raise the floor to the first version that has them in the README,
  the CHANGELOG and every copy `claude-code-floor.test.sh` checks, in this task.
- [ ] **Step 4:** implement; the 60 s budget comes from `$.clock`, each `timeoutMs` what is left.
- [ ] **Step 5:** suites pass; commit `feat(mod): write the summary with the model the app names`.

### Task 5: every ask is answered, and the mod says so when it joins

**Files:** `plugin/hooks/register.tsx` (`contextAsked`, `deliverContext`, `writeAndPost`, the
summary cache, the join body), `plugin/hooks/link.ts` (`context` body), `plugin/tests/context.test.tsx`.

**Interfaces — consumes:** Tasks 3-4. **Produces:** joins carry `writesSummaries: true`;
`contextAsked($, ask)` takes the work's `model`/`fallbackModel`.

- [ ] **Step 1:** change `nothingToForkIsNoFailure`'s premise and add failing tests:
  `anAskWithAModelIsAlwaysAnswered` (no turns → `summary: ""` and no `failures`; both models fail
  → `summary: ""` with two `failures` and the `NO_SUMMARY` line); `anAskWithoutAModelIsAsBefore`
  (fork, nothing posted on nothing-to-fork); `theCacheIsKeptPerModel` (a second ask for another
  model writes again); `aJoinSaysItWritesSummaries`.
- [ ] **Step 2:** implement. `context.ts`'s header comment and `Bridge.context(_:)`'s "the mod
  never sends one" change with it.
- [ ] **Step 3:** `claude plugin test plugin` and `scripts/check.sh` pass; commit
  `feat(mod): answer every context ask`.

## Wave C — Tasks 6-7: the setting and the ask

### Task 6: `summaryModel` in Settings and on the ask

**Files:** `Settings.swift`, new `app/Sources/BridgeCore/SummaryModel.swift`,
`SessionRegistry.swift` (`wantsContext` carries the ask), `Bridge.swift` (init, `askForContext`,
`context(_:)`), `App.swift` (passes the setting); tests `SettingsTests.swift`, new
`SummaryModelTests.swift`, `BridgeTests.swift`.

**Interfaces — consumes:** Task 3's wire. **Produces:**
- `enum SummaryModel { static let `default` = "claude-haiku-5-5"; static let listed: [(id:
  String, name: String)]` (Haiku 5.5, Sonnet 5.5, Opus 5.5 in that order);
  `static func accepted(_ text: String) -> String?` (trimmed, the regex); `static func name(_ id:
  String) -> String` (the listed name, else the id) }.
- `Settings.summaryModel: String`, decoded with `?? SummaryModel.default`.
- `Bridge(… summaryModel: @escaping @Sendable () -> String …)`; each ask sends
  `.context(model: m, fallbackModel: m == SummaryModel.default ? nil : SummaryModel.default)` to a
  mod that said `writesSummaries`, and `.context()` to any other.
- `SessionRegistry.writesSummaries(_ id:) -> Bool`, `requestContext(for:model:fallbackModel:)`.
- `struct SummaryReport: Equatable { asked: String; failures: [SummaryFailure]; wrote: Bool }`
  and `var line: String?`: nil when the chosen model wrote it; "The last summary used Haiku 5.5:
  Opus 5.5 was refused." when the fallback did; "The voice got no new summary: <name> <why>."
  when none did. `<why>` per reason: `model-refused` "was refused", `api-error` "returned an
  error (<error>)", `empty-reply` "wrote nothing", `timed-out` "ran out of time".
- `Bridge.lastSummary: SummaryReport?`, set by `context(_:)` from a post that answers an ask.

- [ ] **Step 1:** failing tests: `aFileFromBeforeItGetsHaiku`; `customTextIsTrimmedAndChecked`
  (`" claude-x-1 "` → `"claude-x-1"`; `""`, `"a b"`, 129 chars, `"x;rm"` → nil);
  `anAskNamesTheModelAndTheDefault` and `theDefaultHasNoFallback` (registry hand-out for a
  `writesSummaries` mod); `anOlderModGetsAPlainAsk`; `theReportSaysWhichModelWrote` (the three
  shapes of `line`).
- [ ] **Step 2:** implement; `Bridge.context(_:)` passes the asked model to `SummaryLog`.
- [ ] **Step 3:** `swift test` passes; commit `feat: send the summary model chosen in Settings`.

### Task 7: the picker in Settings' Context tab, and the docs

**Files:** `app/Sources/LiveBridge/SettingsView.swift` (Context tab), `App.swift`; README (line
45, lines 316-317, the Settings section, the "whole transcript" sentences, a known limitation for
a provider without the pinned default), `SECURITY.md` ("whole transcript", worded as the spec's
reduction), `CHANGELOG.md`, `docs/i18n/README.*.md`, `site/index.html`.

**Interfaces — consumes:** Task 6.

- [ ] **Step 1:** a **Summary model** picker under Load context in the Context tab: the three
  listed names and **Custom…**; the caption from Global Constraints; under it `lastSummary?.line`
  when non-nil. Custom… shows the field disabled with "Custom models come in a later update." until
  Wave D (Task 9 replaces it).
- [ ] **Step 2:** docs as listed; CHANGELOG: summaries use Haiku 5.5 by default, on an update
  too; the provider limitation; the floor if Task 4 raised it.
- [ ] **Step 3:** `scripts/build-app.sh --run`: the picker shows and saves; screenshot for the PR;
  `scripts/check.sh` exits 0; commit `feat(app): choose the summary model in Settings`.

## Wave D — Tasks 8-9: checking a custom model

### Task 8: the check on the wire and in the mod

**Files:** `Wire.swift`, `wire.ts`, fixtures `next-check-model.json`, `model-check-ok.json`,
`model-check-failed.json`; `register.tsx`; `link.ts` (`modelCheck`); tests as in Task 3, and
`context.test.tsx`.

**Interfaces — produces:** `Work.checkModel(id: String, model: String)` (`"kind":"checkModel"`);
`struct ModelCheckBody { sessionId; id: String; ok: Bool; reason: SummaryFailure.Reason?; status:
Int?; error: String? }` at `POST /v1/model-check`.

- [ ] **Step 1:** failing tests: fixtures round-trip; `aCheckSendsOneShortRequest` (`complete`
  with `prompt: "Reply with OK."`, `effort: 'low'`, `timeoutMs: 15000`, no `maxTokens`);
  `anyTextIsOk`; `aRejectionIsModelRefused`; `anApiErrorCarriesItsKind`.
- [ ] **Step 2:** implement; commit `feat: check a summary model through a joined session`.

### Task 9: the app's check and the Custom… field

**Files:** `SessionRegistry.swift` (hand-out of a check, the route), `Bridge.swift`, new
`app/Sources/BridgeCore/ModelCheck.swift`, `SettingsView.swift`, `App.swift`; `SECURITY.md` (the
check takes a local process's word), `docs/architecture/overview.md` (route table); tests
`BridgeTests.swift`, new `ModelCheckTests.swift`.

**Interfaces — produces:** `Bridge.checkModel(_ model: String) async -> ModelCheckResult`;
`enum ModelCheckResult: Equatable { case works, noSession, noAnswer, busy, refused(String) }` with
`message: String?` from the spec's table. The session: the target if it `writesSummaries`, else
the most recently joined one that does; the result is taken only from it with the same `id`; 20 s
or its drop is `noAnswer`.

- [ ] **Step 1:** failing tests: `noSessionThatCanCheck` (nothing sent); `theTargetChecksFirst`;
  `aResultFromAnotherSessionIsIgnored`; `noAnswerIn20Seconds` (mocked time);
  `aRateLimitIsBusy`; `aRefusalKeepsTheOldValue` (Settings unchanged).
- [ ] **Step 2:** Custom… field and **Check and save** (disabled with **Checking…** in flight;
  picking a list entry or saving the stored value checks nothing); the reason beside the field.
- [ ] **Step 3:** `scripts/build-app.sh --run`, a check with a joined session; screenshot;
  `scripts/check.sh`; commit `feat(app): check a custom summary model before saving it`.

## Wave E — Tasks 10-11: the line waits for its context

### Task 10: one decision, the wait in `openLine`, early asks

**Files:** new `app/Sources/BridgeCore/Call/SummaryWait.swift`, `Bridge.swift` (`perform(.start)`'s
launch, `pickTarget`, `openLine`, `context(_:)`, dropped sessions, Stop);
`docs/architecture/overview.md` (Start and the wait), `SECURITY.md` (a process that never answers
holds speech up to the limit, once per call); tests `BridgeTests.swift`, new `SummaryWaitTests.swift`.

**Interfaces — consumes:** Task 6's ask and `writesSummaries`; the gate's limit. **Produces:**
`struct SummaryWait { static let limit: TimeInterval` (the gate's value); `mutating func asked(_:at:)`,
`answered(_:hadSummary:)`, `endedWithout(_:)`, `newCall()`; `func waits(for:writesSummaries:at:)
-> Date?` (the deadline, nil for no wait) }; `Bridge.summariesInFlight: Set<SessionID>` in what
the app reads for the menu.

- [ ] **Step 1:** failing `SummaryWaitTests` for the spec's three rules and its end conditions:
  `noAskNoWait`, `anOlderModIsNeverWaitedFor`, `aWaitThatEndedEmptyIsNotRepeatedThisCall`,
  `theLimitCountsFromTheAsk`, `aNewCallWaitsAgain`.
- [ ] **Step 2:** failing `BridgeTests`: `startAsksAtOnceForAWritingMod`,
  `theLineOpensAfterTheSummaryWithItInTheSeed`, `theLimitOpensTheLineWithoutIt`,
  `aResultWaitsLikeSpeech`, `stopDuringTheWaitOpensNothing`,
  `aTargetChangeEndsTheWaitAndAsksTheNew`, `aLateSummaryReachesTheOpenLine`,
  `aDroppedSessionEndsTheWait`, `aPostForAnOlderAskDoesNotEndTheWait`.
- [ ] **Step 3:** implement: the wait sits after `makeOffer` and before the seed and `voice.open`;
  the phase stays `.connecting`; the page is unchanged.
- [ ] **Step 4:** `swift test`; commit `feat: open a line only once its context is in`.

### Task 11: the menu and the band show the load

**Files:** `ContextLoads.swift`, the app's menu wiring, `plugin/hooks/band.tsx` (an unknown phase
draws as `connecting`); README, CHANGELOG, translations; tests `MenuTests.swift`, `band.test.tsx`.

- [ ] **Step 1:** failing tests: `anyAskInFlightShowsLoading` (Load context disabled);
  `anEmptyReplyGoesBackToLoadContext` (no **Context loaded**); `anUnknownPhaseDrawsAsConnecting`.
- [ ] **Step 2:** implement; docs; `scripts/check.sh`; commit `feat: show a summary loading
  whatever asked for it`.

## Wave F — Tasks 12-13: the glyph and the 200 ms poll

### Task 12: `loadingContext`

**Files:** `StatusPresentation.swift` (`Badge.loadingContext`, precedence after `problem` and
`approval`, before `unheard`), `StatusItem.swift` (the three-quarter ring turning once a second,
brought back from `git show eaab732^:app/Sources/LiveBridge/StatusItem.swift`, a still frame when
motion is reduced), `MenuRows.swift` if a row shows it; tests `StatusPresentationTests.swift`.

- [ ] **Step 1:** failing `loadingContextShowsWhileTheTargetsSummaryIsInFlight` and its precedence.
- [ ] **Step 2:** implement; render the frames as a GIF and **show the owner before committing**.
- [ ] **Step 3:** commit `feat(app): turn a ring while the context loads`.

### Task 13: the target polls every 200 ms

**Files:** `plugin/hooks/link.ts` (`POLL_MS = 200`, other sessions skip to every fifth tick),
`register.tsx` (`follow` every fifth tick; the band not rewritten unchanged); tests
`lifecycle.test.tsx`, `offline.test.tsx`.

- [ ] **Step 1:** failing tests: `theTargetPollsFiveTimesASecond`, `othersPollOnceASecond`,
  `aFastTickDoesNotFollowTheTitle`, `anUnchangedBandIsNotRewritten`; the offline and drop timings
  stay as they are.
- [ ] **Step 2:** implement; `claude plugin test plugin`; `scripts/check.sh`; commit
  `feat(mod): poll five times a second while this session is the target`.

## Execution contract

- **Implementer briefs** carry: report a mismatch between this plan and the tree instead of
  guessing; paste each verification's output; focused tests while iterating, one `scripts/check.sh`
  before each commit; no line numbers taken from this plan; nothing written outside the wave's
  worktree but a scratch folder in the session scratchpad; never kill by a name pattern; no nested
  subagents; no AI attribution.
- **Final review:** one per PR: a correctness seat and a "what can be deleted, and whom does this
  refuse" seat; a security seat only for D (a local process's word) and E (holding speech). Findings
  without replacement text; one scoped re-review, then stop.
- **Real models and real voice:** the gate, `scripts/smoke.sh` after E, and any probe that spends
  the owner's plan run only when the owner says yes at that moment.
- **Verification:** the controller re-runs `scripts/check.sh` only on a head it pushes, waits for
  CI before reporting, and re-derives each PR body before pushing. Nothing is pushed or merged
  without the owner's go-ahead.
- **Parallelism:** D and E in separate worktrees once C is merged; one `scripts/check.sh` per
  worktree at a time.
- **BR-003:** set `status: fixed` and `fixed_in` when the B+C PR merges.
