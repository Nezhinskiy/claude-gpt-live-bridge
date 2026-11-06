# Conversation sync: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to
> implement this plan. **The wave is the dispatch unit, not the task:** one implementer, one
> review round per wave. Inside a wave every task keeps its own failing test, verification and
> commit. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every joined session's conversation with the voice holds the owner's typed turns and
Claude's final answers; the target's open line learns them at once; questions and
permission prompts from any main-loop turn reach the voice; **Load context** is needed only after
a gap, and the menu shows when that is.

**Scope:** `app/`, `plugin/`, `wire/fixtures/` and the docs that describe them. Not the site, not
the band's visibility, not usage-limit handling.

**Architecture:** the mod posts each main-loop turn that is not a voice request to the app
(`POST /v1/sync`) and says on its next join when one did not arrive; the app decides. `Continuity`
keeps a conversation's out-of-sync state and each turn's sync decision, persisted. `CallMachine`
adds a synced line to a live line at once, and to a connecting one on connect. `Bridge.openLine` loads a summary
only when the conversation needs one, and `Settings.autoContext` goes.

**Tech stack:** Swift 6 / SwiftPM (`BridgeCore`, Swift Testing), the mod in TypeScript on the Claude
Code engine (`claude plugin test`, `npm --prefix plugin run test:unit`).

**Spec:** `docs/specs/2026-11-05-conversation-sync-design.md`

**Before Wave B:** the work branch starts from `feat/conversation-sync`, which holds `origin/dev`
with Mute. Wave A is done: see Task 1.

## Wave graph

Edges come from the tasks' Consumes/Produces.

```text
A (Task 1, probe: done)
└─> B (Tasks 2-4: wire, Continuity, CallMachine)
    └─> C (Tasks 5-7: Bridge, settings, menu, registry)
        └─> D (Tasks 8-10: the mod)
            └─> E (Task 11: docs)
```

D consumes only the wire types from B, so C and D could run side by side in one worktree each; they
run in order, because D's engine tests are worth more against a settled wire.

| Wave | Tasks | Why together |
|---|---|---|
| A | 1 | a gate on the design; done, and it changed the design |
| B | 2-4 | pure types the rest consumes |
| C | 5-7 | all in `Bridge`, each unreadable without the one before |
| D | 8-10 | the tracker and the hooks that feed it |
| E | 11 | docs, once behaviour stands |

## Execution contract

- **Final review.** One per PR, by a child reviewer session, per the owner's standing rule: the skills
  `superpowers:requesting-code-review`, `simplify` and `security-review`, findings in
  `docs/reviews/<date>-conversation-sync-review.md` on its own branch, report only. It asks: is the
  architecture elegant enough, is anything redundant? One scoped re-review after the fixes, then stop.
  No per-wave review sessions beyond subagent-driven-development's own round.
- **Lifecycle matrix**, checked before the PR opens, each with a test or a reason:

  | | call off | listening | connecting | live |
  |---|---|---|---|---|
  | typed turn | recorded | recorded | added at connect | added at once |
  | pause on, typed turn | dropped, *paused* | recorded | recorded | recorded |
  | pause on, typed into a running turn | dropped, turn refused | recorded | recorded | recorded |
  | pause on, no context or *missed* | no summary | no summary | no summary | no summary |
  | typed question, target | recorded only | opens the line | given on connect | added now |
  | typed question, other session | recorded only | recorded only | recorded only | recorded only |
  | `/clear` mid-turn | decision moves with the conversation | same | same | same |
  | New conversation | lines go; *paused* and the decision stay | same | line closes | line closes |
  | session removed mid-turn | later posts refused; *paused* stays | same | same | same |
  | app restarts mid-turn | decision persisted; failed posts give a gap | same | same | same |
  | mod reloads mid-turn | snapshot keeps the turn and the gap | same | same | same |

  Eviction past `keptConversations` loses a *paused* mark; with the setting still on, no summary
  loads, and with it off the owner has ended the pause. Accepted.
- **Parallelism.** Read-only seats may run beside each other and the implementer; writers of one
  worktree serialise. Only one real-voice run at a time.
- **Templates.** A fix brief lists sibling instances only to delete them or fold them into one rule.
  A security ruling names what enforces it; "the voice prompt says so" enforces nothing. The owner
  who keeps a pause on must never have a paused line recorded, and no line may load a summary while
  the setting is on: those are the refusals this feature owes, and no other legitimate typed turn may
  be dropped.
- **Verification.** `scripts/check.sh` on Node 24 exits 0 before each commit. The controller
  re-verifies only heads it pushes or merges, and checks `git log origin/dev..HEAD --format=%B` before
  every push: **never `Co-Authored-By: Claude`, "Generated with Claude Code" or any Claude or Anthropic
  attribution** in commits, tags or PR bodies; put this rule in every brief.

## Global Constraints

- A wire change touches `app/Sources/BridgeCore/Wire/Wire.swift`, `plugin/hooks/wire.ts` and
  `wire/fixtures/` together. Fixtures use `/Users/example`, `Example session`, `00000000-…` ids.
- A failing test before each change; one behaviour, one test; tests do not check prompt wording.
- LiveBridge never answers a Claude Code permission prompt; the mod declares no `tool.check` hook.
- No third-party Swift packages in shipped targets and no runtime npm dependencies in the mod.
- A synced line goes through `AnswerShaper.prose`, then `AnswerShaper.line`: no code or tables,
  redacted, one line, at most 2,000 characters (`AnswerShaper.maxCharacters`). The mod clips to
  `ANSWER_LIMIT` before posting.
- Never `scripts/smoke.sh` or a real-voice run without the owner's yes.
- Conventional Commits, one logical change each. Docs never claim more than the code enforces.

## Review Focus

1. A continuity file written before this feature must still decode. A file that does not decode
   starts empty, so a required new field would erase every conversation at update. Test: Task 3.
2. Press Stop with the pause on and type into a turn that started synced: nothing of it is recorded,
   and the turn's answer stays out. Test: Task 3 and Task 5.
3. A pause survives New conversation and ×: the next line asks for no summary of that transcript.
   Test: Task 6.
4. A spoken reply that loses to the keyboard in a typed turn must not leave an adopted request
   open for ten minutes, ending in a false "timed out". Test: Task 10.
5. Lines kept but too many for codex's seed limits are forgotten as silently as lines rolled off:
   the voice must not lose them while the menu says current. Test: Task 3.

---

## Wave A — Task 1

### Task 1: Probe held lines on a real line

**Done, 2026-11-06:** 12 real-voice runs, recorded in ADR 0001 (o). It failed its bar: on sound with
no words the voice spoke added lines in 3 of 3. The owner then decided that on an open line the voice
may repeat what was typed, and must not fall behind, so nothing is held for the owner's words. It
also settled the seed's limit: codex counts UTF-8 bytes over 4, and refuses a start past the limit.

- [x] **Step 1: Read codex's limit.**
- [x] **Step 2: Build the probe,** a throwaway never committed.
- [x] **Step 3: Run four cases.**
- [x] **Step 4: Decide:** back to the owner.
- [x] **Step 5: Record** in the ADR.

---

## Wave B — Tasks 2-4

### Task 2: The wire

**Files:**
- Modify: `app/Sources/BridgeCore/Wire/Wire.swift`
- Modify: `plugin/hooks/wire.ts`
- Modify: `app/Sources/BridgeCore/Sessions/SessionRegistry.swift`
- Modify: `app/Tests/BridgeCoreTests/WireTests.swift`
- Modify: `plugin/tests/unit/wire.unit.ts`
- Modify: `wire/fixtures/next-reply.json`
- Create: `wire/fixtures/sync-typed.json`
- Create: `wire/fixtures/sync-claude.json`
- Create: `wire/fixtures/join-syncs.json`
- Create: `wire/fixtures/activity-typed-question.json`

**Interfaces:**
- Produces, Swift, and the same shapes in `wire.ts`:

  ```swift
  public enum SyncSource: String, Codable, Sendable { case owner, claude }
  /// `POST /v1/sync`: a line of a turn that is not a voice request. Empty `text`, at a turn's
  /// start, takes the turn's decision and records nothing.
  public struct SyncBody: Codable, Sendable, Equatable {
    public var sessionId: SessionID
    public var turnId: String
    public var from: SyncSource
    public var text: String
  }
  // JoinBody gains:     public var syncs: Bool?      // true from a mod that posts sync lines
  //                     public var missed: Bool?     // a turn of this session did not arrive
  // ActivityBody gains: public var typedTurn: String? // the turn's id when it is not a voice turn
  // Work.reply becomes: case reply(VoiceRequest, forRequest: RequestID)
  //   the request the turn's answer belongs to: the one in flight once this reply goes out
  ```

- [ ] **Step 1: Write failing tests.** Each new fixture decodes and re-encodes to itself, in
  `WireTests` and `wire.unit.ts`, in the style of the fixtures already there; `next-reply.json` carries
  `forRequest`.
- [ ] **Step 2: Run** `cd app && swift test --filter WireTests` and `npm --prefix plugin run test:unit`.
  Expected: fail, no such types.
- [ ] **Step 3: Add the types**, the header comment's route list in both files, and the fixtures.
  `SessionRegistry.poll` passes `session.inFlight?.id ?? reply.id` as `forRequest`. Replace the sentence
  in `wire.ts` that says a new target's summary is the app's own setting.
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(wire): synced lines, and what a join and a reply now say"`

### Task 3: Continuity knows what the voice has

**Files:** Modify: `app/Sources/BridgeCore/Call/Continuity.swift`,
`app/Tests/BridgeCoreTests/ContinuityTests.swift`

**Interfaces:**
- Produces:

  ```swift
  public enum OutOfSync: String, Codable, Sendable { case missed, paused }

  // Conversation; each new stored field is Optional, so an older file decodes
  public private(set) var outOfSync: OutOfSync?
  /// The voice has everything: a context, no gap, and the seed carries every line since the summary.
  public var isCurrent: Bool { get }

  // Continuity
  /// Whether a line of `turn` goes in. A turn's first line decides, and later lines keep that
  /// decision, except that an owner's line while `pausing` refuses the turn from there on.
  /// `pausing`: the pause setting is on and the call is off. Every refused line marks `paused`.
  public mutating func admits(
    turn: String, from: SyncSource, in id: SessionID, pausing: Bool) -> Bool
  /// `asPaused`: the pause setting is on, so the gap may hold text meant to stay out.
  public mutating func markMissed(_ id: SessionID, asPaused: Bool)  // never replaces `paused`
  // setContext clears outOfSync and the count of lines since the context
  // forget drops lines and context, and keeps `paused` and the turn's decision
  ```

- [ ] **Step 1: Write failing tests** in `ContinuityTests`:

  ```swift
  @Test func aFileFromBeforeSyncStillDecodes()  // JSON with lines, context and lastUsed only
  @Test func aRefusedTurnStaysRefusedAfterThePauseEnds()
    // admits("t1", .owner, pausing: true) == false, then admits("t1", .claude, pausing: false) == false
  @Test func aTurnFromBeforeThePauseKeepsClaudesAnswer()
    // admits("t1", .owner, pausing: false), then admits("t1", .claude, pausing: true) == true
  @Test func theOwnerTypingAfterStopRefusesTheTurn()   // Review Focus 2
    // admits("t1", .owner, pausing: false), then ("t1", .owner, pausing: true) == false,
    // then ("t1", .claude, pausing: false) == false; outOfSync == .paused
  @Test func aNewTurnDecidesAgain()      // and outOfSync stays .paused until setContext
  @Test func everyRefusedLineMarksPaused()  // a summary mid-turn clears it; the next refused line sets it
  @Test func missedDoesNotReplacePaused()
  @Test func missedUnderThePauseIsPaused()  // markMissed(asPaused: true)
  @Test func aSummaryClearsBothCauses()
  @Test func moveCarriesTheStateAndTheTurn()  // `/clear`
  @Test func forgetKeepsAPauseAndItsDecision()  // Review Focus 3; a missed session forgets it
  @Test func noContextIsNotCurrent()
  @Test func currentAfterASummaryAndAShortExchange()
  @Test func linesTheSeedCannotCarryAreNotCurrent()    // Review Focus 5
    // context set, then 30 owner lines of 2,000 characters
  @Test func linesRolledOffAreNotCurrent()   // context set, then keptLines + 1 one-word lines
  @Test func aHandoffLineCountsForNothing()  // context set, then keptLines + 1 `.handoff` lines: current
  @Test func aRussianSeedStaysUnderCodexsLimit()
    // 30 Cyrillic lines of 2,000 characters: the items' UTF-8 bytes over 4 stay within maxTokens
  ```

- [ ] **Step 2: Run** `cd app && swift test --filter ContinuityTests`. Expected: fail.
- [ ] **Step 3: Implement.** One rule covers rolled-off and unseedable lines: a stored count of lines
  with a seed role since the last `setContext`, compared with the talk lines `initialItems(tasks: [])`
  carries. `record` only counts; nothing marks `missed` on roll-off. Voice small talk counts too,
  though no summary restores it: accepted. The turn's decision is one stored pair (turn id, admitted):
  main-loop turns do not interleave. Raise `keptLines` to 64. `estimatedTokens` counts
  `text.utf8.count`, as codex does: past the limit codex refuses the line.
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(app): a conversation knows whether the voice has it all"`

### Task 4: The call machine takes synced lines

**Files:** Modify: `app/Sources/BridgeCore/Call/CallMachine.swift`,
`app/Tests/BridgeCoreTests/CallMachineTests.swift`

**Interfaces:**
- Produces: `CallEvent.synced(VoiceLine)`; `VoiceLine.Kind` cases `typed = "TYPED"` and
  `claude = "CLAUDE"`; `public mutating func dropSynced()`, for a line just seeded with them.

- [ ] **Step 1: Write failing tests:**

  ```swift
  @Test func aSyncedLineGoesIntoALiveLineAtOnce()
    // live, .synced(a) == [.addContext(a)]; pending unchanged; no timer armed
  @Test func aConnectingLineTakesSyncedLinesWhenConnected()
    // listening, .speechStarted, .synced(a), .connected contains .addContext(a) after .flushPreroll
  @Test func aLineOpenedByAResultTakesThemTooWhenConnected()
  @Test func dropSyncedForgetsThem()        // connecting, .synced(a), dropSynced(), .connected has no .addContext(a)
  @Test func aHangUpDropsThem()             // the conversation has them, and seeds the next line
  ```

  Guards, which pass with the new case alone: `aSyncedLineNeverChimesOrOpens`,
  `aMutedLineStillTakesSyncedLines`.
- [ ] **Step 2: Run** `cd app && swift test --filter CallMachineTests`. Expected: fail.
- [ ] **Step 3: Implement.** `.live`: return `[.addContext(line)]`. `.connecting`: append to a
  `connectingSynced: [VoiceLine]`, emptied into `.addContext` effects at `.connected`, after the pending
  lines. `hangUp` empties it and `end` already resets. `rename` leaves it: a line's `session` is not read
  after this. It touches neither `unheard`, `awaited` nor any timer: the voice's own speech arms the
  silence, as for any reply. `Bridge.heldContext` stays one slot, for the summary.
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(app): an open line takes synced lines at once"`

---

## Wave C — Tasks 5-7

### Task 5: Bridge takes synced lines

**Files:**
- Modify: `app/Sources/BridgeCore/Bridge.swift`
- Modify: `app/Sources/BridgeCore/Settings.swift`
- Modify: `app/Sources/BridgeCore/Text/AnswerShaper.swift`
- Modify: `app/Sources/BridgeCore/Text/Redaction.swift`
- Modify: `app/Sources/BridgeCore/Codex/VoicePrompt.swift`
- Modify: `app/Sources/LiveBridge/App.swift`
- Test: `app/Tests/BridgeCoreTests/BridgeTests.swift`
- Test: `app/Tests/BridgeCoreTests/AnswerShaperTests.swift`
- Test: `app/Tests/BridgeCoreTests/RedactionTests.swift`
- Test: `app/Tests/BridgeCoreTests/SettingsTests.swift`

**Interfaces:**
- Consumes: `SyncBody`, `JoinBody.missed` (Task 2); `Continuity.admits`, `markMissed` (Task 3);
  `CallEvent.synced`, `dropSynced()` (Task 4).
- Produces: `Settings.pauseSyncWhileStopped: Bool` (default false); `Bridge.init(pausesSync:)`;
  `AnswerShaper.synced(_ text: String, from: SyncSource, label: String, session: SessionID) -> VoiceLine?`
  (nil for text with nothing to say; Claude's code-only answer gets `forVoice`'s sentence, shared, not
  copied).

- [ ] **Step 1: Write failing tests** in `BridgeTests`, each through `handle` as the mod calls it:

  ```swift
  @Test func aTypedLineGoesIntoItsSessionsConversation()   // with the call off, nothing added
  @Test func anOtherSessionsLineStaysInItsOwnConversation()
  @Test func aSyncedLineIsSeededToTheNextLine()
    // Claude's line is in `initialItems` although its speaker is .claude
  @Test func aLiveLineGetsASyncedLineAtOnce()              // in FakeVoice.added, no speech needed
  @Test func aLineBeforeTheSeedIsSeededOnly()
    // FakeVoices.setSlow, as aSeededContextIsNotAddedAgainOnceTheLineConnects does: in `opens`, not `added`
  @Test func aLineAfterTheSeedIsAddedOnly()
    // FakeVoice.holdOpen: in `added`, not in `opens`. Mutation for both: move dropSynced() to .connected
  @Test func aSyncedLineIsRedactedClippedAndCodeFree()     // an owner line and a Claude line
  @Test func aPausedTurnIsDroppedWhileTheCallIsOff()       // nothing recorded, outOfSync == .paused
  @Test func aPausedTurnsAnswerStaysOutAfterStart()
  @Test func aTurnFromBeforeStopKeepsItsAnswerInThePause()
  @Test func theOwnerTypingAfterStopIsDropped()            // Review Focus 2, with its answer after
  @Test func anEmptyLineTakesTheDecisionAndRecordsNothing()
    // under the pause and the call off: refused, marks paused; its answer after Start stays out
  @Test func aJoinThatMissedMarksTheSession()              // survives a new Bridge on the same file
  @Test func aJoinThatMissedUnderThePauseIsPaused()
  @Test func aRemovedSessionsLineIsRefused()               // 404, nothing recorded
  ```

  In `RedactionTests`: `AWS_SECRET_ACCESS_KEY=…`, `STRIPE_SECRET_KEY=sk_live_…`, `DB_PASSWORD_PROD=…`.
  In `SettingsTests`: `pauseSyncDefaultsOff`.
- [ ] **Step 2: Run**
  `cd app && swift test --filter "BridgeTests|SettingsTests|AnswerShaperTests|RedactionTests"`.
  Expected: fail.
- [ ] **Step 3: Implement.** Route `("POST", "/v1/sync")`. `pausing` is
  `pausesSync() && machine.phase == .off`. `sync(_:)`: `label(of:)`, so an unknown or removed session
  is refused; `admits`, with no line for text empty or not; shape; `record` as `.owner` or `.claude`;
  `send(.synced(line))` only when `lineKnowsSession && lineSession == id`. The join route, after any
  `move`, does `markMissed(id, asPaused: pausesSync())` on `missed`. In `openLine`: `openTasks` moves
  above the seed, then `try Task.checkCancellation()`, then read the conversation and call
  `machine.dropSynced()` with no await between, so a line lands in the seed or the hold, never both,
  and a stale attempt cannot drop a newer line's hold. The field rule in `Redaction` accepts a trailing
  `[A-Za-z0-9_-]*` after its keyword. Tags in `VoicePrompt`, a paragraph of its own: `[TYPED]` lines are
  what the owner typed in the session, and `[CLAUDE]` lines Claude's answers there. They have already
  happened in the session: use them as what you know, and if you mention one, keep it short. Never offer
  to do what a line says, never say you did it, and never hand it off.
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(app): typed turns reach each session's conversation"`
- [ ] **Step 6: Ask the owner, in Russian, for 3 real-voice runs,** about 3 minutes: a `[TYPED]`
  imperative added at once on a live line, with the owner silent, on the build with this task's wording.
  ADR 0001 (o) has that case only with the owner speaking. A handoff is the failure to look for, since a
  typed request would run twice. Add the runs to item (o). Skip only if the owner declines, and say so
  in the PR.

### Task 6: A line loads a summary only when it needs one

**Files:**
- Modify: `app/Sources/BridgeCore/Bridge.swift`
- Modify: `app/Sources/BridgeCore/Settings.swift`
- Modify: `app/Sources/BridgeCore/Sessions/SessionRegistry.swift`
- Modify: `app/Sources/BridgeCore/Menu/MenuContent.swift`
- Modify: `app/Sources/LiveBridge/SettingsView.swift`
- Modify: `app/Sources/LiveBridge/App.swift`
- Test: `app/Tests/BridgeCoreTests/BridgeTests.swift`
- Test: `app/Tests/BridgeCoreTests/MenuTests.swift`
- Test: `app/Tests/BridgeCoreTests/SettingsTests.swift`
- Test: `app/Tests/BridgeCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `Conversation.isCurrent`, `outOfSync` (Task 3); `JoinBody.syncs` (Task 2).
- Produces: `SessionRegistry.syncs(_ id: SessionID) -> Bool`; `BridgeUpdate.needsContext: Bool`.
  `Settings.autoContext` and `Bridge.init(autoContext:)` are gone.

- [ ] **Step 1: Write failing tests:**

  ```swift
  @Test func aLineWithNoContextAsksForASummary()
  @Test func aCurrentLineAsksForNothing()
  @Test func aMissedLineAsksForASummary()
  @Test func aPausedLineAsksForNothing()          // also with no context at all
  @Test func thePauseSettingStopsEverySummary()
    // setting on: no context, or missed, or a mod that does not sync: no `.context`; Load context still asks
  @Test func aPauseSurvivesNewConversation()      // Review Focus 3: pause, a dropped turn, New conversation, Start, no `.context`
  @Test func aPauseSurvivesRemovingTheSession()   // ×, /live on, Start
  @Test func aModBeforeSyncAlwaysAsks()           // a join without `syncs`, a context, a Start: asks, and again next line
  @Test func anEqualSummaryStillClearsOutOfSync() // nothing added to the line
  @Test func aSummaryClearsPaused()
  // MenuTests
  @Test func loadContextIsDisabledWhileCurrent()  // titled "Context up to date"
  @Test func loadContextIsEnabledOutOfSync()      // for .missed, .paused and no context
  @Test func loadedOutranksUpToDate()             // .loaded keeps "Context loaded" for its 3 s
  // SettingsTests
  @Test func anOldOptOutBecomesThePause()         // {"autoContext":false} → pauseSyncWhileStopped == true
  @Test func anOldOptInLeavesThePauseOff()        // {"autoContext":true}
  ```

  Change `BridgeTests`' helper: its joins send `syncs: true`, its `Bridge` loses `autoContext`, and the
  tests at `autoContext: true` go, replaced by the above. Existing tests that poll for `nil` work on a
  session with no context now see `.context`: set a context there, do not weaken the assertion.
- [ ] **Step 2: Run** `cd app && swift test --filter "BridgeTests|MenuTests|SettingsTests"`. Expected:
  fail.
- [ ] **Step 3: Implement.** One helper:
  `needsContext(id) = !continuity[id].isCurrent || !(await registry.syncs(id))`. `openLine` asks when
  `!pausesSync() && continuity[session].outOfSync != .paused && needsContext`. `BridgeUpdate.needsContext`
  is the helper for the target. `Bridge.context` always calls `setContext` and `save`; only the add to
  the line depends on the line being new. `MenuContent`: `.ready` with `!needsContext` is disabled, titled
  `Context up to date`; every other state as it is. `Settings.init(from:)` reads an old `autoContext`
  only to set `pauseSyncWhileStopped` when that key is absent. `SettingsView`'s Context section becomes
  the toggle **Pause sync while the call is stopped** with the caption `What you type while the call is
  off stays out of the voice's conversation, and context loads only from the menu or /live context.`
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(app)!: a line loads a summary only when it needs one"`

### Task 7: Questions and approvals from typed turns

**Files:** Modify: `app/Sources/BridgeCore/Bridge.swift`,
`app/Sources/BridgeCore/Sessions/SessionRegistry.swift`, `app/Tests/BridgeCoreTests/BridgeTests.swift`,
`app/Tests/BridgeCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `ActivityBody.typedTurn`, `Work.reply(_, forRequest:)` (Task 2); `Continuity.admits` (Task 3).
- Produces: a reply polled with nothing in flight goes in flight, so `forRequest` is its own id and the
  turn's final answer closes it. With a request in flight, `forRequest` is that request.

- [ ] **Step 1: Write failing tests:**

  ```swift
  @Test func aTypedTurnsQuestionOpensTheTargetsLine()   // after an owner line, or `opensLine` is false
  @Test func aTypedTurnsApprovalOpensTheTargetsLine()   // same
  @Test func anotherSessionsTypedQuestionIsContextOnly()
    // recorded; no chime, no unheard, no question route, no line opened
  @Test func aQuestionStillOpenAtASwitchIsAnswerable()
    // the same question, then setTarget: the seed has it, and the next handoff is its reply
  @Test func anotherSessionsVoiceTurnQuestionChimesAsBefore()
  @Test func aRefusedTurnsQuestionGoesNowhere()   // not recorded; the registry is not asking
  @Test func aRefusedTurnIsCheckedWhilePausedOnAnotherPrompt()
    // activity already `approval` (a subagent's prompt): a question in a refused turn sets no asking
  @Test func aSpokenReplyToATypedQuestionIsAwaited()
    // the answer with the reply's id is delivered and spoken, not a 409
  // SessionRegistryTests
  @Test func aReplyWithNothingInFlightGoesInFlight()    // forRequest == reply.id
  @Test func aReplyLeavesARequestInFlightAlone()        // forRequest == that id; its answer still closes it
  @Test func aReplyLeavesLatestToANewerQueuedRequest()
  ```

- [ ] **Step 2: Run** `cd app && swift test --filter "BridgeTests|SessionRegistryTests"`. Expected: fail.
- [ ] **Step 3: Implement.** In `activity`, before `setActivity`: any body with `typedTurn` runs
  `admits(from: .claude)`; refused, hand the registry the body without its `question` and stop. On the
  `(false, true)` edge a typed turn outside the target is `record(.claude, line.text, …)` with no route
  and no `say`; `isAsking` stays, because the seed carries the question and the voice may put it after a
  switch. In `SessionRegistry.poll`, a reply with `inFlight == nil` sets `inFlight`, and `latest` only
  when `queued` is empty.
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(app): questions and approvals from typed turns reach the voice"`

---

## Wave D — Tasks 8-10

### Task 8: The tracker follows every main-loop turn

**Files:** Modify: `plugin/hooks/turns.ts`, `plugin/hooks/prompt.ts`, `plugin/tests/unit/turns.unit.ts`,
`plugin/tests/unit/prompt.unit.ts`, `docs/adr/0001-platform-findings.md`

**Interfaces:**
- Consumes: `SyncSource` (Task 2).
- Produces:

  ```ts
  export type TurnOrigin = 'voice' | 'owner' | 'other' | 'background'  // 'other' replaces 'typed'
  export type SyncLine = { turnId: string; from: SyncSource; text: string }
  // TurnTracker
  get current(): { turnId: string; isVoice: boolean } | null  // the main-loop turn running
  turnStarted(turnId, text, origin, now): SyncLine | null
    // owner: the prompt. other, or background outside the window: Claude's empty line, which takes
    // the turn's decision. voice, or background in the window: null
  turnCompleted(turnId, answer, outcome): { post: Post | null; sync: SyncLine | null }
  takeLostTurn(): boolean
    // once: a turn completed unseen, or still held when the next started, which is evicted
  replied(replyId: RequestId, forRequest: RequestId | undefined, now: number): void
    // no-op with no turn, a voice turn, or an older app's undefined. forRequest === replyId: the rest
    // of the turn is a voice turn, with its follow-up window. Otherwise: an update to forRequest
  // prompt.ts
  export function keyboardAnswer(result: { answers?: Record<string, string>; response?: string } | undefined): { from: SyncSource; text: string }
    // `from` is 'owner' for a real answer and 'claude' for a question closed with none
  ```

  `running` keeps its meaning. `Tracked.id` may be null: a turn with no voice request behind it. A
  snapshot from before this change still loads.

- [ ] **Step 1: Observe, which spends no voice.** With a scratch mod that logs events, in `claude` under
  `tmux` and in the desktop app, answer and add to ADR 0001 (i) and (m): (a) the `origin.kind` of a typed
  prompt on each surface, and whether a slash command's prompt carries `isMeta`; (b) for a prompt typed
  during a running turn, whether `prompt.submit` fires at Enter, and whether it then starts a turn of its
  own, or folds in; (c) after **No** at a permission dialog, with and without feedback, which of
  `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, the next `turn.step` and `turn.complete` fire.
  If a dialog cannot be driven, ask the owner, in Russian, to press No once. Later steps follow what this
  shows; a result that contradicts them goes back to the controller.
- [ ] **Step 2: Write failing tests** in `turns.unit.ts`:

  ```ts
  'an owner turn posts its prompt'         // turnStarted → { turnId, from: 'owner', text }
  'an owner turn posts its answer'         // turnCompleted → { post: null, sync: { from: 'claude', text } }
  'only an observed origin is the owner'   // peer, sdk, scheduled-trigger, another plugin, unclassified: other
  'an other turn takes its decision and posts its answer, not its prompt'
  'a turn with no origin seen is other'
  'a background turn outside the window posts its answer and no prompt'
  'a background turn in the window stays an update'
  'an interrupted turn posts nothing'
  'replied makes the rest of the turn a voice turn'  // Post ok under the reply's id; running is that id; follow-up set
  'replied with another request in flight makes the answer its update'
  'replied changes nothing in a voice turn'  // Post under R, not the reply's id
  'replied changes nothing without forRequest'
  'current is the running turn of either kind, null after it ends'
  'a snapshot from before sync loads'
  ```

  And in `prompt.unit.ts`: `keyboardAnswer` for one label, several, a free-text `response`, an empty
  result, and undefined.
- [ ] **Step 3: Run** `npm --prefix plugin run test:unit`. Expected: fail.
- [ ] **Step 4: Implement.** `originOf` maps an allow-list of origins from Step 1 to `owner`; everything
  else that is not voice or background is `other`, which keeps today's job of ending the follow-up
  window. `keyboardAnswer` gives `You answered at the keyboard: <answers, joined by "; ">`, and
  `Claude's question was closed at the keyboard.` when the result holds none.
- [ ] **Step 5: Run them again.** Expected: pass.
- [ ] **Step 6: Commit** `git commit -m "feat(plugin): the tracker follows every main-loop turn"`

### Task 9: Posting turns, and the gap

**Files:** Modify: `plugin/hooks/register.tsx`, `plugin/hooks/link.ts`, `plugin/tests/fake-bridge.ts`,
`plugin/tests/roundtrip.test.tsx`, `plugin/tests/lifecycle.test.tsx`, `plugin/tests/offline.test.tsx`,
`plugin/tests/context.test.tsx`

**Interfaces:**
- Consumes: Task 8's tracker; `SyncBody`, `JoinBody.syncs`, `JoinBody.missed` (Task 2).
- Produces: `BridgeLink.sync(line: SyncLine): Promise<boolean>`, true when the app took it;
  `BridgeLink.noteGap(): void`, which makes the next poll join again with `missed: true`, stripped from
  `#joined` as `owner` is and cleared once a join is taken; `get hasGap(): boolean`.

- [ ] **Step 1: Write failing tests,** with `sync` added to `fake-bridge.ts`:

  ```ts
  test('anOwnerTurnIsSynced')                // both lines, the prompt before `working`
  test('aTurnSyncsWhileTheCallIsOff')        // the mod does not look at the call
  test('anOtherTurnPostsNoOwnerLine')
  test('textTypedIntoARunningTurnIsSynced')  // prompt.submit with a turnId, a voice turn's too
  test('aPromptIsNotPostedTwice')            // per Step 1 of Task 8, if the engine fires both
  test('aVoicePromptIntoARunningTurnIsNotSynced')
  test('aDeliveryThatIsNotTheOwnersIsNotSynced')  // task-notification, peer, isMeta
  test('aFailedPostMeansAMissedJoin')        // app down for a turn; the next join says missed, once
  test('aLostVoiceAnswerMeansAMissedJoin')
  test('aTurnBeforeJoiningIsMissed')         // /live on in a session with turns
  test('aFreshSessionJoinsWithoutMissed')    // turns: 0
  test('aSnapshotFromBeforeSyncIsAGap')      // a reload resumes, and the join says missed
  test('aGapSurvivesAReload')                // saved after the failed post
  test('joinSaysItSyncs')                    // syncs: true; update the join expectations
  test('everyCompletedTurnStalesTheSummary') // replaces aVoiceTurnKeepsTheSummaryCached
  ```

- [ ] **Step 2: Run** `claude plugin test plugin`, or the command `scripts/check.sh` uses. Expected:
  fail.
- [ ] **Step 3: Implement.** One helper, `postSync($, line)`: not joined or not taken is
  `link.noteGap()` and a `save`. `save` writes `{ ...tracker.snapshot(), hasGap: link.hasGap }`; a saved
  snapshot without `hasGap` is a gap. `turnOn`, for the owner's join into a session with turns, notes a
  gap first. `prompt.submit` with a `turnId` and an owner origin, and no `isMeta`, posts under that turn.
  `staleSummary()` runs for every completed turn, and `summary` then means nothing has happened since,
  so an equal line in the app is really equal. `join` sends `syncs: true`.
- [ ] **Step 4: Run them again, then `scripts/check.sh`.** Expected: pass, exit 0.
- [ ] **Step 5: Commit** `git commit -m "feat(plugin): every main-loop turn reaches the app, or says it did not"`

### Task 10: Questions, replies and settled prompts

**Files:** Modify: `plugin/hooks/register.tsx`, `plugin/tests/fake-bridge.ts`,
`plugin/tests/roundtrip.test.tsx`

**Interfaces:**
- Consumes: `tracker.current`, `tracker.replied`, `keyboardAnswer` (Task 8); `postSync` (Task 9);
  `ActivityBody.typedTurn`, `Work.reply`'s `forRequest` (Task 2).

- [ ] **Step 1: Write failing tests,** with `classic.PostToolUseFailure` and `classic.PermissionDenied`
  added to `fake-bridge.ts` only as Task 8's Step 1 shows them firing:

  ```ts
  test('aTypedTurnsQuestionIsAsked')         // activity with `typedTurn`
  test('aTypedTurnsApprovalIsReported')
  test('aTypedTurnsQuestionIsAskedWhileAVoiceRequestWaits')
    // flips aTypedTurnsQuestionStaysInClaudeCodeWhileAVoiceRequestWaits (roundtrip.test.tsx:302)
  test('aTypedTurnsApprovalIsReportedWhileAVoiceRequestWaits')
    // flips aTypedTurnsApprovalIsNotReportedWhileAVoiceRequestWaits (:139), and the last assertion of
    // refusedPromptFailsTheRequestAtOnce changes the same way
  test('aKeyboardAnswerIsSynced')            // a typed turn, and a voice turn
  test('aSpokenReplyMakesTheTurnAVoiceTurn') // its answer goes to /v1/answer with the reply's id
  test('aSpokenReplyInAVoiceTurnKeepsItsRequest')  // the answer under R; the test the old one stopped short of
  test('aSpokenReplyWithARequestWaitingIsAnUpdate') // status update under forRequest; no LOST_ANSWER
  test('aLateSpokenReplyClosesItsRequest')   // Review Focus 4: `failed` for the reply's id; LATE_REPLY still logged
  test('anAllowedPromptIsSynced')
  test('aNoAtTheDialogSettlesAtTheNextStep') // no tool ran, a main step starts: `working`, a settled line
  test('theNextPromptIsAnnouncedAfterANo')   // the bug this closes: `approval` no longer sticks
  test('aPromptOpenAtTheTurnsEndIsSettled')
  ```

- [ ] **Step 2: Run** `claude plugin test plugin`. Expected: fail.
- [ ] **Step 3: Implement.** The `tool.call` and `classic.PermissionRequest` guards become
  `tracker.current !== null`, and each `activity('approval')` carries `typedTurn` unless
  `current.isVoice`. `answerQuestion` resolves with the reply work item, so the race can tell a spoken
  reply from the dialog's result: a reply calls `tracker.replied` and saves; the dialog's result posts
  `keyboardAnswer(first.result)`, with the `from` it gives, in every turn. `tick`, finding no question open for a
  `reply`, posts `failed` for its id with the reason `the question was answered at the keyboard`: a 409
  for a voice turn is harmless. `settles(e)` keeps its job. Lines are `from: 'claude'`, the mod's report
  and not the owner's typing:
  `You allowed <tool> at the keyboard.` from a settling `PostToolUse` or `PostToolUseFailure`;
  `The permission prompt for <tool> was settled at the keyboard.` when a main `turn.step` starts or
  `turn.complete` comes with `approval` still set by the main loop, which also posts `activity('working')`.
  `PermissionDenied` settles with no line: it is auto-mode's.
- [ ] **Step 4: Run them again, then `scripts/check.sh`.** Expected: pass, exit 0.
- [ ] **Step 5: Commit** `git commit -m "feat(plugin): questions and approvals from any main-loop turn"`

---

## Wave E — Task 11

### Task 11: Docs, and the owner's check

**Files:**
- Modify: `README.md` and its six translations
- Modify: `SECURITY.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/architecture/overview.md`
- Modify: `docs/specs/2026-11-04-voice-session-context-design.md`
- Modify: `docs/specs/2026-11-05-conversation-sync-design.md`
- Modify: `docs/trail.toml`
- Modify: `docs/roadmap.md` (by `stayfixed docs trail`)

- [ ] **Step 1: README and translations.** Privacy, How a call works, Settings (the setting that went,
  the one that came), the Load context item, `README.md:330`'s "last 24 lines", and `:333`'s statement of
  what is removed from a line. Promise only what the code enforces.
- [ ] **Step 2: SECURITY.md.** Rewrite "A loaded context persists" and the advice after it. Also:

  | Where | What changes |
  |---|---|
  | `:32-36` | "During a voice turn" no longer bounds spoken answers; a steered voice can answer a typed turn's dialog |
  | `:66-78` | the peer list gains owner-labelled lines and forcing a summary |
  | `:80` | the data folder now holds typed text and answers from every joined session, with no call needed |
  | `:126-130` | the line list gains synced lines; "data to relay" does not fit `[TYPED]` |

  The mitigations, as far as each goes: `/clear` with **New conversation** ends what the voice carries,
  though `/clear` carries the lines to the new id until New conversation; removing a session holds until
  it joins again; the pause with Stop keeps new text out and removes nothing already recorded. Say what is
  stored and how long: 20 conversations of 64 lines as plain JSON in a `0700` folder, whether Time Machine
  copies it not tested. Say that Claude's later answers can repeat paused text. A page Claude reads in a
  typed turn can now steer the voice through Claude's answer, as it could in a voice turn.
- [ ] **Step 3: The overview, the older spec** marked superseded where it says typed turns do not reach
  the voice and that auto-load stays on, and **the CHANGELOG**: typed turns now sync while the call is on;
  an owner who had turned auto-load off gets the pause on; a mod and an app from before this keep working.
- [ ] **Step 4: The trail.** Set this spec and plan to `delivered`, run `stayfixed docs trail`.
- [ ] **Step 5: The owner's manual check,** asked for in Russian with the debug app and mod from the
  branch, and reported as it came out, in the PR body: two joined sessions; type in each; switch target
  without Stop and ask the voice what was typed; a question in a typed turn answered at the keyboard,
  then one answered by voice; a permission prompt in a typed turn, allowed and refused; Stop with the
  pause on, type a new prompt and into a running turn, Start, and confirm Load context lights up and the
  voice does not know the paused text.
- [ ] **Step 6: Commit** `git commit -m "docs: conversation sync"`, then `scripts/check.sh`.

---

## Review outcome, 2026-11-06

The review is the file of that date on branch `claude/review-conversation-sync-plan-1ce6e7`. Its findings are folded into the tasks above, except:

| Finding | Ruling |
|---|---|
| C-4's exception to "a spoken reply makes the rest of the turn a voice turn" | Not needed: with a request waiting, the answer posts as an `update` to it, which `complete` already takes, so no second slot and no exception |
| I-3, strip `question` for a non-target typed turn | Rejected: the voice could then not answer a question it can see after a switch, and the reply would queue behind the blocked turn. The seed carries the `[ASKING]` line, so this is the target's own flow |
| `#turns` as a map | Left: `current` is set at each `turnStarted`; a stale `running` entry predates this |
| M-13, a newer mod voicing typed questions against an older app | Accepted as is: mod and app ship together, and the owner hears a question either way |
