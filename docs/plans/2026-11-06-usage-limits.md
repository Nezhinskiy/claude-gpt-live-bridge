# Usage limits in the menu: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax. **The wave is the dispatch unit, not the task:** one implementer per wave, and inside a wave every task keeps its own failing test, verification and commit. No per-wave reviews: one final review per PR.

**Goal:** two text rows in the menu, Codex and Claude, showing percent used of each window the plan
reports, with reset times on hover.

**Architecture:** one value, `UsageLimits`, in `BridgeCore`. Codex fills it from
`account/rateLimits/read` on a short-lived `codex app-server`, read when the menu opens. Claude
fills it through the mod and a new `POST /v1/limits`, published in `BridgeUpdate`. `MenuContent`
turns both into `LimitRow`s; the rules are pure and tested in `BridgeCore`. The voice path,
`RealtimeSession` and codex's lifecycle do not change.

**Tech stack:** Swift 6 / SwiftPM (Swift Testing), the mod in TypeScript (`claude plugin test`,
`node --test`).

**Spec:** `docs/specs/2026-11-06-usage-limits-design.md`.

**Scope:** a change belongs to this branch iff it puts the Codex or Claude usage figures in the
menu; warnings, voice changes and anything else are not admitted.

## Wave graph

```
A (Tasks 1-2: value, Codex read) ──┬──> B (Tasks 3-4: rows, read rule) ──┬──> E (Task 10: any window) ──> D (Tasks 7-9: app, docs, by hand)
                                   └──> C (Tasks 5-6: route, mod)     ───┘
```

| Wave | Tasks | Consumes | Why it stands alone |
| --- | --- | --- | --- |
| A | 1-2 | nothing | the shape the rest uses |
| B | 3-4 | `UsageLimits` | `MenuContent` takes both readings as arguments, so it needs nothing from C |
| C | 5-6 | `UsageLimits`, `merging` | Bridge, wire and mod; shares no file with B |
| E | 10 | A, B, C | the owner's later requirement: no window is special |
| D | 7-9 | everything | the untested app target, docs, and the look at the real menu |

A, B and C landed with `fiveHour` and `week`; E replaces that shape before D uses it. D runs last.

## Global Constraints

- A failing test before each change; one behaviour, one test. Tests check behaviour, not wording of
  prompts; the row's text and tooltip are the feature, so they are asserted exactly.
- A wire change touches `app/Sources/BridgeCore/Wire/Wire.swift`, `plugin/hooks/wire.ts` and
  `wire/fixtures/` together.
- No third-party Swift packages; no runtime npm dependencies in the mod.
- No personal data: fixtures use `00000000-…` ids. Readings stay in memory, never on disk or in logs.
- Nothing says "voice limit". The rows say Codex and Claude. No icons, no logos.
- Do not change `CodexLaunch.argv`, `RealtimeSession`, or when the voice's codex starts and ends.
- Never `scripts/smoke.sh` or any real-voice run without the owner's yes; never touch `/Applications`.
- `scripts/check.sh` exits 0 before each commit (this Mac has Node 24; CI runs 26). Conventional Commits. Never write
  `Co-Authored-By: Claude`, "Generated with Claude Code" or any Claude or Anthropic attribution;
  check `git log origin/dev..HEAD --format=%B` before every push. This plan's docs land in Task 8,
  in the same PR as the code.
- Merges are expected: `fix/voice-usage-limit` and `feat/conversation-sync` touch `Bridge.swift`.

## Execution contract

- **Final review:** one per PR, in a reviewer child session, before any merge: correctness, "what
  can be deleted, who does this refuse", plus the repo's `requesting-code-review`, `simplify` and
  `security-review`. One scoped re-review after fixes, then stop.
- **Lifecycle matrix (checked in Task 9):** the menu opened with the call off, listening and live:
  the Codex row shows and the call is not disturbed; codex missing or signed out: no row, no problem
  banner; a read in flight when the menu closes: the next open shows it; the app restarted with a
  joined session: the Claude row returns without a new turn; the last session leaving: the row stays.
- **Parallelism:** read-only seats beside anything. B and C work in one worktree only in turn, or
  each in its own; writers of one worktree serialise.
- **Fix briefs:** fold sibling instances into one rule rather than adding a guard to each; keep a net
  budget.
- **Verification:** implementers paste `scripts/check.sh`'s last lines. The controller re-runs it
  only on heads it pushes, and re-derives the PR body before each push.

## Review Focus

- **Pro's unread reply:** one 10080 window in `primary` and null `secondary` shows `19% of week` only
  (Task 2 `aWeekInThePrimarySlotIsTheWeek`).
- **A blocked account with nothing to show** must not lose its row (Task 3
  `aBlockWithNoWindowStillShows`).
- **An idle session joining** must not lower fresh figures (Task 1
  `onTheSameResetTheHigherPercentStays`).
- **A window past its reset** is not shown as if current (Task 3 `aWindowPastItsResetIsLeftOut`).
- **A failed or hung read** must not stop the next one for ever (Task 4
  `aFailedReadAllowsTheNextAfterTheCooldown`, and Task 7 reads with a 10 s timeout).

---

## Wave A: Tasks 1-2

### Task 1: The reading and its merge

**Files:**
- Create: `app/Sources/BridgeCore/Limits/UsageLimits.swift`
- Test: `app/Tests/BridgeCoreTests/UsageLimitsTests.swift`

**Interfaces:**
- Produces:

```swift
public struct LimitWindow: Sendable, Equatable {
  public var usedPercent: Double
  public var resetsAt: Date?
}
public struct UsageLimits: Sendable, Equatable {
  public var fiveHour: LimitWindow?
  public var week: LimitWindow?
  public var isBlocked = false
  public var readAt: Date
  /// This reading without the windows whose reset has passed.
  public func current(at now: Date) -> UsageLimits
  /// `newer` over this one, window by window.
  public func merging(_ newer: UsageLimits) -> UsageLimits
}
```

- [ ] **Step 1: Write the failing tests** in `UsageLimitsTests`, one each:
  `aWindowPastItsResetIsDropped` (`resetsAt` before `now` gives nil, at or after keeps it, nil
  `resetsAt` keeps it); `theLaterResetWins` (either arrival order); `onTheSameResetTheHigherPercentStays`
  (old 40, new 12, same reset: 40, and `readAt` is the newer's); `aWindowWithNoResetTakesTheNewest`;
  `aMissingWindowKeepsTheHeldOne` (new `week` nil keeps the old `week`).
- [ ] **Step 2: Run:** `swift test --package-path app --filter UsageLimitsTests`. Expected: fails to
  compile, no `UsageLimits`.
- [ ] **Step 3: Implement** per the spec's rule: later `resetsAt` wins, same `resetsAt` the higher
  percent, a nil `resetsAt` on either side takes the newer. `merging` always takes the newer `readAt`.
- [ ] **Step 4: Run** the same filter. Expected: pass.
- [ ] **Step 5: Commit** `feat(app): a usage reading and how two readings combine`.

### Task 2: Reading Codex

**Files:**
- Create: `app/Sources/BridgeCore/Limits/CodexLimits.swift`
- Test: `app/Tests/BridgeCoreTests/CodexLimitsTests.swift`

**Interfaces:**
- Consumes: `UsageLimits`, `LimitWindow`; `RPCClient`.
- Produces: `CodexLimits.read(client: any RPCClient, now: Date, timeout: Duration = .seconds(10)) async throws -> UsageLimits`.

- [ ] **Step 1: Write the failing tests**, with `FakeRPC` as `SettingsTests` uses it
  (`rpc.set("account/rateLimits/read", [reply])`) and a reply built inline in the real shape:
  `{ordinaryUsageAllowed, rateLimits: {…}, rateLimitsByLimitId: {codex: {limitId: "codex", primary:
  {usedPercent: 7, windowDurationMins: 300, resetsAt: <epoch>}, secondary: {19, 10080, …}}}}`:
  - `readsBothWindowsOfTheCodexBucket`: 7 and 19, `resetsAt` as `Date`, `readAt == now`.
  - `asksWithoutResetCreditDetails`: `rpc.params(...) == [["excludeResetCreditDetails": true]]`.
  - `aWeekInThePrimarySlotIsTheWeek`: primary 19/10080, secondary null: `week` set, `fiveHour` nil.
  - `aWindowOfAnotherLengthIsIgnored`: 43200 gives neither; 285 and 315 count as five hours, 284 and
    316 do not; 9576 and 10584 count as the week (codex's ±5 %, inclusive).
  - `fallsBackToTheSingleBucket`: `rateLimitsByLimitId` null, `rateLimits.limitId` `"codex"` or absent.
  - `anotherBucketIsNotRead`: only a bucket with `limitId` `"other"`: no windows.
  - `ordinaryUsageNotAllowedIsABlock`: the field sits at the top level of the reply, beside
    `rateLimits`, not in a bucket. `false` sets `isBlocked`; `true` and null do not.
  - `aReplyThatIsNotAnObjectIsAProblem`: throws `CodexProblem`.
- [ ] **Step 2: Run:** `swift test --package-path app --filter CodexLimitsTests`. Expected: fails to
  compile.
- [ ] **Step 3: Implement** on `JSONValue`, as `Voices.list` does. Decode nothing else: `accountId`
  and the credit fields are never touched. Window length from `windowDurationMins`, ±5 % of 300 and
  of 10080; if both slots land on one length, `primary` wins. Add a `number` accessor to `JSONValue`
  only if it has none.
- [ ] **Step 4: Run** the same filter. Expected: pass.
- [ ] **Step 5: Commit** `feat(app): read the Codex usage windows from codex`.

## Wave B: Tasks 3-4

### Task 3: The rows in the menu

**Files:**
- Create: `app/Sources/BridgeCore/Menu/LimitRow.swift`
- Modify: `app/Sources/BridgeCore/Menu/MenuContent.swift` (the `Item` enum, `init`, `outline`);
  `app/Sources/LiveBridge/StatusMenu.swift` (the exhaustive switch in `fill` needs a `.limit` arm: a
  disabled native item titled with the row's text, which Task 7 replaces)
- Test: `app/Tests/BridgeCoreTests/MenuTests.swift`

**Interfaces:**
- Consumes: `UsageLimits`.
- Produces:

```swift
public struct LimitRow: Sendable, Equatable {
  public struct Figure: Sendable, Equatable { public let text: String; public let isNear: Bool }
  public let name: String          // "Codex" or "Claude"
  public let figures: [Figure]     // "7% of 5 h", "19% of week"
  public let isBlocked: Bool
  public let tooltip: String
  public var text: String          // figures, then "blocked", joined by " · "
  public static let nearPercent = 90
  public init?(name: String, limits: UsageLimits?, now: Date, calendar: Calendar, locale: Locale)
}
// MenuContent.Item: case limit(LimitRow)
// MenuContent.init gains: codexLimits: UsageLimits? = nil, claudeLimits: UsageLimits? = nil,
//   now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
```

- [ ] **Step 1: Write the failing tests** with a UTC `gregorian` calendar and `en_GB`:
  - `aRowShowsBothWindows`: figures `7% of 5 h`, `19% of week`.
  - `percentsAreRounded`: 7.5 shows `8%`.
  - `anAbsurdPercentDoesNotCrash`: 1e300 shows `100%`, -5 shows `0%`.
  - `aMissingWindowIsLeftOut`: only `19% of week`.
  - `noWindowAndNoBlockIsNoRow`: `LimitRow(...) == nil`, also for nil limits.
  - `aWindowPastItsResetIsLeftOut`: uses `current(at:)`.
  - `aFigureShowingNinetyIsNear`: 89.4 no, 89.5 yes (it shows `90%`), per figure.
  - `aBlockWithNoWindowStillShows`: `isBlocked`, no figures, `text == "blocked"`.
  - `aBlockFollowsTheFigures`: `text == "7% of 5 h · 19% of week · blocked"`.
  - `theTooltipSaysWhenEachWindowResets`, exactly:
    `"5-hour window resets at 06:04\nWeekly window resets Wed 08:01\nRead at 05:08"` for a 06:04 reset
    today and a later Wednesday.
  - `timesFollowTheLocale`: `en_US` gives `6:04 AM` and `Wed 8:01 AM`.
  - `anOldReadingSaysItsDay`: read on an earlier day, `Read at Mon 05:08`.
  - `aBlockedTooltipOpensWithTheBlock`: first line `Codex reports usage is blocked right now.`
  - `aWindowWithNoResetHasNoResetLine`.
  - `theMenuHoldsTheRowsAboveTheMinutes`: `outline` holds `[limit] Codex — 7% of 5 h · 19% of week`
    then `[limit] Claude — …`, then `---`, then the minutes line; a blocked row's line is built from
    `text`, so `[limit] Codex — blocked`.
  - `withNoRowsTheSectionIsNotThere`: today's outline tests stay as they are.
- [ ] **Step 2: Run:** `swift test --package-path app --filter MenuTests`. Expected: fails to compile.
- [ ] **Step 3: Implement.** `init?` starts from `limits?.current(at: now)`. Percent is
  `Int(min(max(usedPercent, 0), 100).rounded())`, clamped first because `Int(_:)` traps on a huge
  double and the value comes from the socket; `isNear` compares that shown number. A time on `now`'s
  calendar day reads as the time, another day as the short weekday and the time, for resets and for
  "Read at" alike, by `DateFormatter.dateFormat(fromTemplate:)` with templates `jmm` and `EEEjmm`, so
  the locale picks 12 or 24 hours, with `locale` and the calendar's zone. In `MenuContent`,
  add the rows and one `.separator` immediately before the minutes note only when there is a row.
  The early return for a menu with no bridge stays as it is, so that menu has no rows.
- [ ] **Step 4: Run** the same filter. Expected: pass, the old tests untouched.
- [ ] **Step 5: Commit** `feat(app): the menu's limit rows`.

### Task 4: When Codex is read

**Files:**
- Create: `app/Sources/BridgeCore/Limits/LimitsPoll.swift`
- Test: `app/Tests/BridgeCoreTests/LimitsPollTests.swift`

**Interfaces:**
- Consumes: `UsageLimits`.
- Produces:

```swift
public struct LimitsPoll: Sendable, Equatable {
  public static let readEvery: TimeInterval = 60
  public static let staleAfter: TimeInterval = 15 * 60
  public init()
  /// True when a read should start now; it is then under way until `finish`.
  public mutating func begin(at now: Date) -> Bool
  /// nil: the read failed, the last reading stands.
  public mutating func finish(_ reading: UsageLimits?)
  /// The last reading, nil once it is older than `staleAfter`.
  public func reading(at now: Date) -> UsageLimits?
}
```

- [ ] **Step 1: Write the failing tests:** `theFirstOpenReads`; `oneReadAtATime`;
  `aSecondOpenWithinAMinuteDoesNotRead` (59 s no, 60 s yes); `aFailedReadAllowsTheNextAfterTheCooldown`;
  `aFailedReadKeepsTheLastReading`; `aReadingOlderThanFifteenMinutesIsGone` (15 min kept, past it nil).
- [ ] **Step 2: Run:** `swift test --package-path app --filter LimitsPollTests`. Expected: fails to
  compile.
- [ ] **Step 3: Implement.** The cooldown counts from the last `begin`.
- [ ] **Step 4: Run** the same filter. Expected: pass.
- [ ] **Step 5: Commit** `feat(app): read the Codex limits at most once a minute`.

## Wave C: Tasks 5-6

### Task 5: The route and the bridge

**Files:**
- Modify: `app/Sources/BridgeCore/Wire/Wire.swift`, `plugin/hooks/wire.ts`,
  `app/Sources/BridgeCore/Bridge.swift` (the `handle` switch, `current`, `BridgeUpdate`)
- Create: `wire/fixtures/limits.json`
- Test: `app/Tests/BridgeCoreTests/WireTests.swift`, `BridgeTests.swift`, `plugin/tests/unit/wire.unit.ts`

**Interfaces:**
- Consumes: `UsageLimits.merging`.
- Produces:

```swift
public struct LimitWindowBody: Codable, Sendable, Equatable {
  public var kind: String; public var percentUsed: Double; public var resetsAt: String?
}
public struct LimitsBody: Codable, Sendable, Equatable {
  public var sessionId: SessionID; public var windows: [LimitWindowBody]
}
// BridgeUpdate gains: public var claudeLimits: UsageLimits? = nil  (a default, so MenuTests' builder
// keeps compiling and this task shares no file with Task 3)
```

```ts
export type LimitWindowBody = { kind: string; percentUsed: number; resetsAt?: string }
export type LimitsBody = { sessionId: SessionId; windows: LimitWindowBody[] }
```

- [ ] **Step 1: Add the fixture and the failing wire tests** in both languages, as the suites do for
  each file: `{"sessionId": "00000000-0000-0000-0000-000000000001", "windows": [{"kind": "five_hour",
  "percentUsed": 23.5, "resetsAt": "2026-01-01T06:00:00Z"}, {"kind": "seven_day", "percentUsed": 7}]}`.
- [ ] **Step 2: Write the failing `BridgeTests`:** `aReadingReachesTheUpdate`;
  `anUnknownKindIsIgnored` (`spend_limit` only leaves no reading); `anIdleSessionDoesNotLowerTheFigures`
  (two posts, same reset, 40 then 12: 40); `anUnjoinedSessionIsIgnored`;
  `theReadingOutlivesTheLastSession` (leave, reading stands); `aResetThatDoesNotParseIsNoReset`, also
  with fractional seconds parsing as a reset; `theStatusDoesNotChange` (`StatusReply`'s JSON has no new key).
- [ ] **Step 3: Run:** `swift test --package-path app --filter 'WireTests|BridgeTests'`. Expected:
  fails to compile.
- [ ] **Step 4: Implement.** `case ("POST", "/v1/limits")` in `handle`, a private `limits(_:)` guarded
  like `activity` (`try? await label(of:)`), `private var claudeLimits: UsageLimits?`, merged with
  `readAt: time.now`. Kinds `five_hour` and `seven_day`; a body with neither changes nothing.
- [ ] **Step 5: Run** the same filter and `npm --prefix plugin run test:unit`. Expected: pass.
- [ ] **Step 6: Commit** `feat: POST /v1/limits carries Claude's usage windows to the app`.

### Task 6: The mod sends them

**Files:**
- Modify: `plugin/hooks/link.ts`, `plugin/hooks/register.tsx`, `plugin/tests/fake-bridge.ts`
- Test: `plugin/tests/lifecycle.test.tsx`

**Interfaces:**
- Consumes: `LimitWindowBody`.
- Produces: `BridgeLink.limits(windows: readonly LimitWindowBody[]): Promise<void>`, sending nothing
  for an empty list; a new `LinkPorts` entry `joined(): void`, called by `BridgeLink.join` each time
  a join succeeds, also the ones `next` makes after the app appears or restarts.

- [ ] **Step 1: Pre-flight.** CI pins Claude Code 2.1.309 (`.github/workflows/ci.yml:32`).
  `plugin validate` passed with a `session.measure` hook on 2.1.301 and 2.1.312 (on a copy, in
  the plan's review), which bracket it; CI proves the pin itself. If it refuses, stop and report
  rather than bumping the pin.
- [ ] **Step 2: Write the failing tests:** `joiningSendsTheReading` (with `$.session.usage` answering
  windows, `/live on` posts `limits`); `anAppThatOpensLaterGetsTheReading` (`/live on` with the app
  out of reach, then the poll's join); `anAppRestartGetsTheReadingAgain` (404 on a poll, rejoin);
  `aMeasureWithRateLimitsSendsThem`; `aMeasureOfSomethingElseSendsNothing`; `anEmptyListSendsNothing`;
  `aSessionNotJoinedSendsNothing`; `aRefusedSendChangesNothing` (`limits` answers 404: no further
  `join` is posted); `aUsageThatFailsDoesNotStopJoining` (`$.session.usage` rejects, `/live on` still
  says joined). `fake-bridge.ts` gets no default usage hook, so that last test stays honest.
- [ ] **Step 3: Run:** `claude plugin test plugin`. Expected: the new tests fail.
- [ ] **Step 4: Implement.** `limits` through `#forSession`, ignoring the reply; `on('session.measure', …)`
  sends `e.rateLimits` when `e.changed` names `rateLimits`, then `next(e)`. The `joined` port
  queues `link.limits((await $.session.usage()).rateLimits)` in a `try`, through the link's work
  queue, so an engine that refuses cannot break `/live on` and a join's reply is not held up. Map engine windows field by field; omit `resetsAt` when absent.
- [ ] **Step 5: Run:** `claude plugin test plugin && npm --prefix plugin run typecheck && claude plugin
  validate plugin`. Expected: pass.
- [ ] **Step 6: Commit** `feat(plugin): send Claude's usage windows to the app`.

## Wave E: Task 10

### Task 10: Any window, of any length

The owner's requirement after Waves A and B: limits change, so a window of a new length shows. This
replaces `fiveHour` and `week` everywhere; Tasks 1 to 5's tests that name them change with it.

**Files:**
- Modify: `app/Sources/BridgeCore/Limits/UsageLimits.swift`, `CodexLimits.swift`,
  `app/Sources/BridgeCore/Menu/LimitRow.swift`, `app/Sources/BridgeCore/Bridge.swift`
- Test: `UsageLimitsTests.swift`, `CodexLimitsTests.swift`, `MenuTests.swift`, `BridgeTests.swift`

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces:

```swift
public enum LimitSpan: Hashable, Sendable {
  case minutes(Int)      // within ±5 % of 300 or 10080 it is normalised to exactly that
  case kind(String)      // a Claude kind the app does not know
  case unknown           // no duration
  public var label: String       // "5 h", "week", "30 d", "45 min", "limit", or the kind with spaces
  public var windowName: String  // "5-hour window", "Weekly window", "30-day window", "Limit"
  public var isKnown: Bool       // 300 or 10080
}
public struct LimitWindow: Sendable, Equatable {
  public var span: LimitSpan
  public var usedPercent: Double
  public var resetsAt: Date?
}
public struct UsageLimits: Sendable, Equatable {
  public static let maxWindows = 3
  public private(set) var windows: [LimitWindow]   // the init orders and caps them
  public var isBlocked: Bool
  public var readAt: Date
  public init(windows: [LimitWindow] = [], isBlocked: Bool = false, readAt: Date)
  public func current(at now: Date) -> UsageLimits
  public func merging(_ newer: UsageLimits) -> UsageLimits
}
```

- [ ] **Step 1: Rework the tests, failing first:**
  - `UsageLimitsTests`: the merge tests keyed by span; `aWindowNobodyReportsGoesAtItsReset` (held
    `.kind("x")`, a newer reading without it keeps it until `current(at:)` passes its reset);
    `windowsAreShortestFirst` (`.minutes` ascending, then `.kind`, then `.unknown`);
    `aRowHoldsThreeWithTheKnownFirst` (five windows of which 300 and 10080: both stay).
  - `LimitSpanTests`: 300 `5 h`, 240 `4 h`, 45 `45 min`, 1440 `1 d`, 43200 `30 d`, 9576, 10080 and
    10584 `week`, 9575 `7 d`; `windowName` `5-hour window`, `4-hour window`, `Weekly window`, `30-day
    window`, `45-minute window`, `Limit` for unknown, and `.kind("five_minute")` label `five minute`,
    `windowName` `Five minute window`.
  - `CodexLimitsTests`: `aWindowOfAnotherLengthIsIgnored` becomes `aWindowOfAnotherLengthShows` (240
    shows as `4 h`); `aWindowWithNoDurationShowsAsLimit`; `aWindowWithNoPercentIsLeftOut`;
    `twoOfOneLengthKeepThePrimary`; `anUnknownExtraFieldChangesNothing`;
    `noBucketMapIsTheSingleBucket` (key absent, not null).
  - `MenuTests`: figures `22% of 4 h`, `22% of limit`; the tooltip's `4-hour window resets at …`; a
    no-duration window's tooltip line `Limit resets at …`.
  - `BridgeTests`: `anUnknownKindShowsByName`; `spendLimitStaysOut`; `aKindOutsideTheAlphabetIsIgnored`
    (`Five`, `a-b`, 33 characters, empty); `aReadingHoldsAtMostThreeWindows`; `anIdleSessionDoesNotLowerTheFigures`
    stays green.
- [ ] **Step 2: Run:** `swift test --package-path app --filter 'UsageLimitsTests|LimitSpanTests|CodexLimitsTests|MenuTests|BridgeTests'`. Expected: fails to compile.
- [ ] **Step 3: Implement.** Put `LimitSpan` in `UsageLimits.swift`. Hours and days round to the
  nearest whole number. `UsageLimits.init` drops a later window of a span already held, sorts, and
  caps, known spans kept first. `CodexLimits.read` takes every window of the bucket and still throws
  only for a reply that is not an object. `Bridge` maps kinds: `five_hour`, `seven_day`, `spend_limit`
  out, the alphabet check as a pure function with the tests above.
- [ ] **Step 4: Run** `scripts/check.sh`. Expected: exit 0.
- [ ] **Step 5: Commit** `feat(app): show every window the plan reports, whatever its length`.

## Wave D: Tasks 7-9

### Task 7: The app

**Files:**
- Modify: `app/Sources/LiveBridge/App.swift`, `StatusMenu.swift`, `MenuRows.swift`; `HostedItem` if
  the hover check needs it

**Interfaces:**
- Consumes: `CodexLimits.read`, `LimitsPoll`, `LimitRow`, `MenuContent.Item.limit`,
  `BridgeUpdate.claudeLimits`.
- Produces: `AppModel.refreshLimits()` and `AppModel.codexLimits(at:) -> UsageLimits?`.

This target has no tests (the repo's rule: `BridgeCore` holds every rule), so nothing here decides.

- [ ] **Step 1:** In `AppModel`: `private(set) var limitsPoll = LimitsPoll()`. `refreshLimits()`: if
  `limitsPoll.begin(at: Date())` and `codexCwd` is set, start a `Task` that calls
  `Self.readLimits(cwd:)` and then `limitsPoll.finish`, nil on any error. `readLimits` mirrors
  `offeredVoices`: launch, `CodexLimits.read`, close, except for the search path:
  `defaultSearchPath()` runs the owner's interactive login shell, too much for every menu open, so
  the model keeps the path from the first read of the run and looks again only if codex is not found
  on it. The voice's `launchCodex` stays as it is.
- [ ] **Step 2:** In `StatusMenu`: `content` passes `codexLimits: model.codexLimits(at: Date())` and
  `claudeLimits: model.update?.claudeLimits`; `menuNeedsUpdate` calls `model.refreshLimits()` for the
  main menu only.
- [ ] **Step 3:** `LimitRowView` in `MenuRows.swift`, hosted with `HostedItem(view, enabled: false)`
  as `SentView` is, replacing Task 3's arm: name, then each figure, orange when `isNear`, joined by
  ` · `, then `blocked`. A blocked row is orange whole, name included. `MenuStyle.subtitle`, no image.
  Tooltip by `.help(row.tooltip)`; `accessibilityLabel` of the whole row. `fill` keys it
  `limit|<name>`, and `show` drops unused rows as it does the others.
- [ ] **Step 4: Check the hover in the real menu now,** before any doc promises it:
  `CFFIXED_USER_HOME=<scratch> scripts/build-app.sh --run`, open the menu, hold the pointer on the row.
  Nothing records that `.help` shows on a disabled hosted item. In order, until it shows: `enabled:
  true` on the hosted item with no action; a native item with `toolTip`. If none shows, stop and ask
  the owner; the docs do not go in first.
- [ ] **Step 5: Run:** `scripts/check.sh`. Expected: exit 0.
- [ ] **Step 6: Commit** `feat(app): show the usage limits in the menu`.

### Task 8: Docs

**Files:**
- Modify: `README.md` and the six `README.*.md`; `docs/architecture/overview.md`; `SECURITY.md`;
  `CHANGELOG.md`; `docs/specs/2026-11-06-usage-limits-design.md` (Status); `docs/trail.toml`;
  `docs/roadmap.md` (by `stayfixed docs trail`).

- [ ] **Step 1:** README, the menu bullet: add the limits after "the minutes". New bullet after the
  billing bullet (`README.md:313-316`): the rows show percent used of the 5-hour and weekly windows
  as Codex and Claude report them, resets on hover; Codex's are read when the menu opens, by a
  short-lived codex; Claude's need a joined session that has answered; which limit stops the voice
  first is not documented. Name no window as a fact of the plans: the rows show what the plan reports. Link the research note only if it has merged; else the pricing page.
  The same in all six translations.
- [ ] **Step 2:** `overview.md:136`: a row for `POST /v1/limits`, and a line on the short-lived read
  beside the voice list. `SECURITY.md`: add to the list at `:66-79` that a process running as the owner
  can post false limits, including a far-future `resetsAt` that stands until the app quits, and
  window names of `[a-z0-9_]{1,32}`, at most three a row. README's
  Privacy section and its six translations (`SECURITY.md:244` sends readers there for what goes to
  OpenAI): opening the menu makes codex read usage from OpenAI, also while the call is off.
  `README.md:293` "Nothing is sent anywhere" speaks of audio: read it, keep it true. `CHANGELOG.md`: Added, under the unreleased section.
- [ ] **Step 3:** The spec's Status to `delivered`; `docs/trail.toml`: the spec and plan from
  `"planned"` to `"delivered"`; run `stayfixed docs trail`.
- [ ] **Step 4: Run:** `scripts/check.sh`. Expected: exit 0.
- [ ] **Step 5: Commit** `docs: the usage limits in the menu`.

### Task 9: By hand

No voice is needed and none may be spent.

- [ ] **Step 1:** `CFFIXED_USER_HOME=<scratch> scripts/build-app.sh --run`, and
  `CFFIXED_USER_HOME=<scratch> claude --plugin-dir plugin` with `/live on`.
- [ ] **Step 2:** Walk the lifecycle matrix above. Screenshot the menu. Compare the figures with a
  throwaway read.
- [ ] **Step 3:** Ask the owner to look at the menu once. Record what was checked in the PR body.
