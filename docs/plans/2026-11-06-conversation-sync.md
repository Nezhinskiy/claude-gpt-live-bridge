# Conversation sync: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to
> implement this plan. **The wave is the dispatch unit, not the task:** one implementer, one
> review round per wave. Inside a wave every task keeps its own failing test, verification and
> commit. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every joined session's conversation with the voice holds the owner's typed turns and
Claude's final answers; the target's open line learns them without speaking; questions and
permission prompts from any main-loop turn reach the voice; **Load context** is needed only after
a gap, and the menu shows when that is.

**Architecture:** the mod posts each main-loop turn that is not a voice request to the app
(`POST /v1/sync`) and says when one did not arrive (`POST /v1/missed`); the app decides. `Continuity`
keeps a conversation's out-of-sync state and each turn's sync decision, persisted. `CallMachine`
holds synced lines for the open line until the owner next speaks. `Bridge.openLine` loads a summary
only when the conversation needs one, and `Settings.autoContext` goes.

**Tech stack:** Swift 6 / SwiftPM (`BridgeCore`, Swift Testing), the mod in TypeScript on the Claude
Code engine (`claude plugin test`, `npm --prefix plugin run test:unit`).

**Spec:** `docs/specs/2026-11-05-conversation-sync-design.md`

**Before Wave B:** the work branch starts from `origin/dev` with PR #36 (Mute) merged: `CallMachine`,
`Bridge`, `Wire.swift` and `band.tsx` change there first. Wave A needs the owner's yes.

## Wave graph

Edges come from the tasks' Consumes/Produces.

```text
A (Task 1, probe; the owner's yes)
└─> B (Tasks 2-4: wire, Continuity, CallMachine)
    └─> C (Tasks 5-7: Bridge, settings, menu, registry)
        └─> D (Tasks 8-9: the mod)
            └─> E (Task 10: docs)
```

D consumes only the wire types from B, so C and D could run side by side in one worktree each; they
run in order, because D's engine tests are worth more against a settled wire. No wave here runs in
parallel with another in one worktree.

| Wave | Tasks | Why together |
|---|---|---|
| A | 1 | a gate on the design; touches no shipped code but the ADR |
| B | 2-4 | pure types the rest consumes |
| C | 5-7 | all in `Bridge`, each unreadable without the one before |
| D | 8-9 | the tracker and the hooks that feed it |
| E | 10 | docs, once behaviour stands |

## Execution contract

- **Final review.** One per PR, by a child reviewer session, per the owner's standing rule: the skills
  `superpowers:requesting-code-review`, `simplify` and `security-review`, findings in
  `docs/reviews/<date>-conversation-sync-review.md` on its own branch, report only. It asks: is the
  architecture elegant enough, is anything redundant? One scoped re-review after the fixes, then stop.
  No per-wave review sessions beyond subagent-driven-development's own round.
- **Lifecycle matrix**, checked before the PR opens, each with a test or a reason:

  | | call off | listening | connecting | live |
  |---|---|---|---|---|
  | typed turn | recorded | recorded | held, added at connect or first word | held until speech |
  | pause on, typed turn | dropped, *paused* | recorded | recorded | recorded |
  | typed question, target | recorded only | opens the line | given on connect | added now |
  | typed question, other session | recorded only | recorded only | recorded only | recorded only |
  | `/clear` mid-turn | decision moves with the conversation | same | same, held lines renamed | same |
  | New conversation | decision and state gone | same | line closes | line closes |
  | session removed mid-turn | later posts refused, not recorded | same | same | same |
  | app restarts mid-turn | decision persisted; failed posts give *missed* | same | same | same |
  | mod reloads mid-turn | tracker snapshot keeps the turn and the gap | same | same | same |

- **Parallelism.** Read-only seats may run beside each other and the implementer; writers of one
  worktree serialise. Only one real-voice run at a time.
- **Templates.** A fix brief lists sibling instances only to delete them or fold them into one rule.
  A security ruling names what enforces it; "the voice prompt says so" enforces nothing. The owner
  who keeps a pause on must never have a paused line recorded: that is the one refusal this feature
  owes, and no other legitimate typed turn may be dropped.
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
- A synced line goes through `AnswerShaper.line`: redacted, one line, at most 2,000 characters
  (`AnswerShaper.maxCharacters`). The mod clips to `ANSWER_LIMIT` before posting.
- Never `scripts/smoke.sh` or a real-voice run without the owner's yes.
- Conventional Commits, one logical change each. Docs never claim more than the code enforces.

## Review Focus

1. A continuity file written before this feature must still decode. A file that does not decode
   starts empty, so a required new field would erase every conversation at update. Test: Task 3.
2. A summary equal to the stored one clears out-of-sync too. `Bridge.context` returns early on an
   equal line and the mod resends its cached summary. Test: Task 6.
3. A paused turn's question or approval must not reach the conversation by `Bridge.say`, and its
   question must not leave the session asking. Test: Task 7.
4. A spoken reply that loses to the keyboard in a typed turn must not leave an adopted request
   open for ten minutes, ending in a false "timed out". Test: Task 9.
5. Lines kept but too many for codex's seed limits are forgotten as silently as lines rolled off:
   the voice must not lose them while the menu says current. Test: Task 3.

---

## Wave A — Task 1

### Task 1: Probe held lines on a real line

**The owner's yes first:** this spends realtime minutes. The controller asks in Russian, naming the
cost (6 runs of about 45 s, about 5 minutes of voice), and runs it itself; no subagent.

**Files:** Modify: `docs/adr/0001-platform-findings.md` (a new item (o) and its place in the item
range at the top). A throwaway probe build in a scratch worktree, never committed.

- [ ] **Step 1: Build the probe.** In a throwaway worktree on `dev`, patch `Bridge.audioEvent` so that
  `.speechStarted` on a live line first calls `realtime.addContext` with two fixed lines,
  `[TYPED] Example session: …` and `[CLAUDE] Example session: …`, and add those two tags and the
  sentence "use them, do not read them out" to `VoicePrompt`. Use `--fake-mic` with a WAV as in
  `scripts/smoke.sh`: a question with nothing to do with the lines, after a first exchange, so the
  session holds an owner turn.
- [ ] **Step 2: Run 6 times** and read each transcript.
- [ ] **Step 3: Decide.** Pass: in at most 1 of 6 runs the voice mentions the lines unasked. Otherwise
  stop: the design goes back to the spec with the owner, and Wave B does not start.
- [ ] **Step 4: Record.** Add item (o) to the ADR: the build, a table of the runs, the finding. Delete
  the worktree.
- [ ] **Step 5: Commit**
  `git commit -m "docs(adr): context added as the owner starts speaking (item o)"`

---

## Wave B — Tasks 2-4

### Task 2: The wire

**Files:**
- Modify: `app/Sources/BridgeCore/Wire/Wire.swift`, `plugin/hooks/wire.ts`,
  `app/Tests/BridgeCoreTests/WireTests.swift`, `plugin/tests/unit/wire.unit.ts`
- Create: `wire/fixtures/sync-typed.json`, `wire/fixtures/sync-claude.json`,
  `wire/fixtures/missed.json`, `wire/fixtures/join-syncs.json`,
  `wire/fixtures/activity-typed-question.json`

**Interfaces:**
- Produces, Swift, and the same shapes in `wire.ts`:

  ```swift
  public enum SyncSource: String, Codable, Sendable { case owner, claude }
  /// `POST /v1/sync`: a line of a turn that is not a voice request.
  public struct SyncBody: Codable, Sendable, Equatable {
    public var sessionId: SessionID
    public var turnId: String
    public var from: SyncSource
    public var text: String
  }
  /// `POST /v1/missed`: a turn of this session did not reach the app.
  public struct MissedBody: Codable, Sendable, Equatable { public var sessionId: SessionID }
  // JoinBody gains:     public var syncs: Bool?      // true from a mod that posts sync lines
  // ActivityBody gains: public var typedTurn: String? // the turn's id when it is not a voice turn
  ```

- [ ] **Step 1: Write failing tests.** Each new fixture decodes and re-encodes to itself, in
  `WireTests` and `wire.unit.ts`, in the style of the fixtures already there.
- [ ] **Step 2: Run** `cd app && swift test --filter WireTests` and `npm --prefix plugin run test:unit`.
  Expected: fail, no such types.
- [ ] **Step 3: Add the types**, the header comment's route list in both files, and the fixtures.
  Replace the sentence in `wire.ts` that says a new target's summary is the app's own setting.
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(wire): routes for synced lines and a missed turn"`

### Task 3: Continuity knows what the voice has

**Files:** Modify: `app/Sources/BridgeCore/Call/Continuity.swift`,
`app/Tests/BridgeCoreTests/ContinuityTests.swift`

**Interfaces:**
- Produces:

  ```swift
  public enum OutOfSync: String, Codable, Sendable { case missed, paused }

  // Conversation; each new stored field is Optional, so an older file decodes
  public private(set) var outOfSync: OutOfSync?
  /// A summary would tell the voice something: no context yet, a missed turn, or lines since the
  /// last summary that the seed cannot carry. Never while `paused`.
  public var opensWithSummary: Bool { get }
  /// The voice has everything: context, no gap, and the seed carries every line since the summary.
  public var isCurrent: Bool { get }

  // Continuity
  /// Whether a line of `turn` goes in. The turn's first line decides, `pausing` being the pause
  /// setting and the call's state at that moment; a refused turn marks `paused`.
  public mutating func admits(turn: String, in id: SessionID, pausing: Bool) -> Bool
  public mutating func markMissed(_ id: SessionID)  // leaves `paused` as it is
  // setContext also clears outOfSync and the count of lines since the context
  ```

- [ ] **Step 1: Write failing tests** in `ContinuityTests`:

  ```swift
  @Test func aFileFromBeforeSyncStillDecodes()  // JSON with lines, context and lastUsed only
  @Test func aPausedTurnStaysRefusedAfterThePauseEnds()
    // admits("t1", pausing: true) == false, then admits("t1", pausing: false) == false
  @Test func aSyncedTurnStaysAdmittedOnceThePauseStarts()
    // admits("t1", pausing: false) == true, then admits("t1", pausing: true) == true
  @Test func aNewTurnDecidesAgain()      // and outOfSync stays .paused until setContext
  @Test func missedDoesNotReplacePaused()
  @Test func aSummaryClearsBothCauses()
  @Test func moveCarriesTheStateAndTheTurn()  // `/clear`
  @Test func aMissedSessionOpensWithASummaryAndAPausedOneNever()
  @Test func aConversationWithNoContextOpensWithASummary()
  @Test func aConversationCurrentAfterASummaryAndAShortExchange()
  @Test func linesTheSeedCannotCarryAreNotCurrent()
    // context set, then 30 owner lines of 2,000 characters: isCurrent false, opensWithSummary true
  @Test func linesRolledOffAreNotCurrent()
    // context set, then keptLines + 1 one-word lines: isCurrent false, opensWithSummary true
  @Test func aHandoffLineCountsForNothing()
    // context set, then keptLines + 1 `.handoff` lines: isCurrent true
  ```

- [ ] **Step 2: Run** `cd app && swift test --filter ContinuityTests`. Expected: fail.
- [ ] **Step 3: Implement.** One rule covers rolled-off and unseedable lines: a stored count of lines
  with a seed role since the last `setContext`, compared with the talk lines `initialItems(tasks: [])`
  carries. `record` only counts; nothing marks `missed` on roll-off. The turn's decision is one stored
  pair (turn id, admitted): main-loop turns do not interleave. Raise `keptLines` to 64.
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(app): a conversation knows whether the voice has it all"`

### Task 4: The call machine holds synced lines

**Files:** Modify: `app/Sources/BridgeCore/Call/CallMachine.swift`,
`app/Tests/BridgeCoreTests/CallMachineTests.swift`

**Interfaces:**
- Produces: `CallEvent.synced(VoiceLine)`; `VoiceLine.Kind` cases `typed = "TYPED"` and
  `claude = "CLAUDE"`; `public mutating func dropSynced()`, for a line just seeded with them.

- [ ] **Step 1: Write failing tests:**

  ```swift
  @Test func aSyncedLineSaysNothingOnALiveLine()    // effects == []; pending unchanged; no timer
  @Test func aSyncedLineGoesInWhenTheOwnerSpeaks()
    // live, .synced(a), .synced(b), .speechStarted == [.addContext(a), .addContext(b), .armSilenceTimer(...)]
  @Test func aLineOpenedBySpeechGetsHeldLinesWhenConnected()
    // listening, .speechStarted, .synced(a), .connected contains .addContext(a) after .flushPreroll
  @Test func aLineOpenedByAResultKeepsHeldLinesUntilTheFirstWord()
    // .deliver(opensLine: true), .synced(a), .connected has no .addContext(a); .speechStarted has
  @Test func aHangUpDropsHeldLines()         // the conversation has them, and seeds the next line
  @Test func aMutedOwnerAddsNothing()        // .mute, .synced(a), .speechStarted == []
  @Test func aSyncedLineNeverChimesOrOpens() // listening: .synced(a) == [] and phase stays .listening
  @Test func renameMovesHeldLines()
  ```

- [ ] **Step 2: Run** `cd app && swift test --filter CallMachineTests`. Expected: fail.
- [ ] **Step 3: Implement.** A `heldSynced: [VoiceLine]`, filled only in `.connecting` and `.live`.
  Emptied into `.addContext` effects at `(.live, .speechStarted)`, and at `(.connecting, .connected)`
  unless `isAwaitingFirstWord`, after the pending lines. `hangUp` and `rename` handle it; `end` already
  resets. It does not touch `unheard`, `awaited` or any timer. The spec's "`heldContext` becomes a
  list" lands here instead: `Bridge.heldContext` stays one slot, for the summary.
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(app): synced lines wait for the owner's next words"`

---

## Wave C — Tasks 5-7

### Task 5: Bridge takes synced lines

**Files:** Modify: `app/Sources/BridgeCore/Bridge.swift`, `app/Sources/BridgeCore/Settings.swift`,
`app/Sources/BridgeCore/Text/AnswerShaper.swift`, `app/Sources/BridgeCore/Codex/VoicePrompt.swift`,
`app/Sources/LiveBridge/App.swift`, `app/Tests/BridgeCoreTests/BridgeTests.swift`,
`app/Tests/BridgeCoreTests/AnswerShaperTests.swift`, `app/Tests/BridgeCoreTests/SettingsTests.swift`

**Interfaces:**
- Consumes: `SyncBody`, `MissedBody` (Task 2); `Continuity.admits`, `markMissed` (Task 3);
  `CallEvent.synced`, `dropSynced()` (Task 4).
- Produces: `Settings.pauseSyncWhileStopped: Bool` (default false); `Bridge.init(pausesSync:)`;
  `AnswerShaper.synced(_ text: String, from: SyncSource, label: String, session: SessionID) -> VoiceLine?`
  (nil for text with nothing to say; Claude's code-only answer gets the sentence `forVoice` uses).

- [ ] **Step 1: Write failing tests** in `BridgeTests`, each through `handle` as the mod calls it:

  ```swift
  @Test func aTypedLineGoesIntoItsSessionsConversation()   // with the call off, nothing added
  @Test func anOtherSessionsLineStaysInItsOwnConversation()
  @Test func aSyncedLineIsSeededToTheNextLine()
    // Claude's line is in `initialItems` although its speaker is .claude
  @Test func aLiveLineGetsASyncedLineWhenTheOwnerSpeaks()  // FakeVoice.added empty, then holds it
  @Test func aLineArrivingBeforeTheSeedIsAddedOnce()
    // FakeVoice.holdOpen; a post between `requestContext` and the seed: once in `opens`, not in `added`
  @Test func aSyncedLineIsRedactedAndClipped()
  @Test func pauseOnDropsATurnWhileTheCallIsOff()          // nothing recorded, outOfSync == .paused
  @Test func pausedTurnsAnswerStaysOutAfterStart()
  @Test func aTurnFromBeforeStopFinishesInThePause()
  @Test func missedMarksTheSession()                       // survives a new Bridge on the same file
  @Test func aRemovedSessionsLineIsRefused()               // 404, nothing recorded
  @Test func anEmptyLineRecordsNothing()
  ```

  And in `SettingsTests`: `pauseSyncDefaultsOff`, and the existing `autoContext` cases go in Task 6.
- [ ] **Step 2: Run** `cd app && swift test --filter "BridgeTests|SettingsTests|AnswerShaperTests"`.
  Expected: fail.
- [ ] **Step 3: Implement.** Routes `("POST", "/v1/sync")` and `("POST", "/v1/missed")`. `pausing` is
  `pausesSync() && machine.phase == .off`. `sync(_:)`: `label(of:)`, so an unknown or removed session
  is refused; admit; shape; `record` as `.owner` or `.claude`; `send(.synced(line))` only when
  `lineKnowsSession && lineSession == id`. In `openLine`, read the conversation after the last await
  before the seed and call `machine.dropSynced()` in the same stretch, so a line lands in the seed or
  the hold, never both. Tags in `VoicePrompt`: `[TYPED]` is what the owner typed in the session and
  `[CLAUDE]` Claude's answer there: use them, do not read them out or comment on them.
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(app): typed turns reach each session's conversation"`

### Task 6: A line loads a summary only when it needs one

**Files:** Modify: `app/Sources/BridgeCore/Bridge.swift`, `app/Sources/BridgeCore/Settings.swift`,
`app/Sources/BridgeCore/Sessions/SessionRegistry.swift`,
`app/Sources/BridgeCore/Menu/MenuContent.swift`, `app/Sources/BridgeCore/Menu/ContextLoads.swift`,
`app/Sources/LiveBridge/SettingsView.swift`, `app/Sources/LiveBridge/App.swift`, the tests of each.

**Interfaces:**
- Consumes: `Conversation.opensWithSummary`, `isCurrent` (Task 3); `JoinBody.syncs` (Task 2).
- Produces: `SessionRegistry.syncs(_ id: SessionID) -> Bool`; `BridgeUpdate.needsContext: Bool`.
  `Settings.autoContext` and `Bridge.init(autoContext:)` are gone.

The spec's "Older peers" names `modVersion`; this uses `JoinBody.syncs` instead: a version floor would
be the release that ships this, and every dev build before that release commit, which reads as an old
mod, would be permanently *missed*.

- [ ] **Step 1: Write failing tests:**

  ```swift
  @Test func aLineWithNoContextAsksForASummary()
  @Test func aCurrentLineAsksForNothing()
  @Test func aMissedLineAsksForASummary()
  @Test func aPausedLineAsksForNothing()          // also with no context at all
  @Test func aModBeforeSyncAlwaysAsks()           // a join without `syncs`, a context, a Start: asks, and again next line
  @Test func anEqualSummaryStillClearsOutOfSync()  // Review Focus 2: nothing added to the line
  @Test func aSummaryClearsPaused()
  // MenuTests
  @Test func loadContextIsDisabledWhileCurrent()
  @Test func loadContextIsEnabledOutOfSync()       // for .missed, .paused and no context
  // SettingsTests
  @Test func theOldAutoContextKeyIsIgnored()       // existing line 80's file still decodes
  ```

  Change `BridgeTests`' helper: its joins send `syncs: true`, its `Bridge` loses `autoContext`, and the
  tests at `autoContext: true` go, replaced by the above. Existing tests that poll for `nil` work on a
  session with no context now see `.context`: set a context there, do not weaken the assertion.
- [ ] **Step 2: Run** `cd app && swift test --filter "BridgeTests|MenuTests|SettingsTests"`. Expected:
  fail.
- [ ] **Step 3: Implement.** `openLine` asks when `conversation.opensWithSummary`, or, for a session
  whose mod does not sync, unless paused. `Bridge.context` clears the state on an equal line and still
  skips saving a new line and `addContext`. `needsContext` is
  `target != nil && (!conversation.isCurrent || !syncs)`; `MenuContent` disables the item while false,
  titled `Context up to date`. `SettingsView`'s Context section becomes the toggle
  **Pause sync while the call is stopped** with the caption
  `Turns you type while the call is off stay out of the voice's conversation.`
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(app)!: a line loads a summary only when it needs one"`

### Task 7: Questions and approvals from typed turns

**Files:** Modify: `app/Sources/BridgeCore/Bridge.swift`,
`app/Sources/BridgeCore/Sessions/SessionRegistry.swift`, `app/Tests/BridgeCoreTests/BridgeTests.swift`,
`app/Tests/BridgeCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `ActivityBody.typedTurn` (Task 2); `Continuity.admits` (Task 3).
- Produces: a `Work.reply` polled with nothing in flight puts its request in flight, so the turn's
  final answer closes it (`POST /v1/answer` with the reply's id).

- [ ] **Step 1: Write failing tests:**

  ```swift
  @Test func aTypedTurnsQuestionOpensTheTargetsLine()
  @Test func aTypedTurnsApprovalOpensTheTargetsLine()
  @Test func anotherSessionsTypedQuestionIsContextOnly()
    // recorded; no chime, no unheard, no question route, no line opened
  @Test func anotherSessionsVoiceTurnQuestionChimesAsBefore()
  @Test func aPausedTurnsQuestionGoesNowhere()   // Review Focus 3: not recorded; registry not asking
  @Test func aSpokenReplyToATypedQuestionIsAwaited()
    // the answer with the reply's id is delivered and spoken, not a 409
  // SessionRegistryTests
  @Test func aReplyWithNothingInFlightGoesInFlight()
  @Test func aReplyInAVoiceTurnLeavesTheRequestInFlightAlone()
  ```

- [ ] **Step 2: Run** `cd app && swift test --filter "BridgeTests|SessionRegistryTests"`. Expected: fail.
- [ ] **Step 3: Implement.** In `activity`, on the `(false, true)` edge: with `typedTurn`, `admits` first;
  refused, hand the registry the body without its `question` and stop. A typed turn outside the target
  is `record(.claude, line.text, …)` with no route and no `say`. In `SessionRegistry.poll`, a reply with
  `inFlight == nil` sets `inFlight` and `latest` to the reply's id.
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(app): questions and approvals from typed turns reach the voice"`

---

## Wave D — Tasks 8-9

### Task 8: The tracker follows every main-loop turn

**Files:** Modify: `plugin/hooks/turns.ts`, `plugin/hooks/prompt.ts`, `plugin/tests/unit/turns.unit.ts`,
`plugin/tests/unit/prompt.unit.ts`

**Interfaces:**
- Consumes: `SyncSource` (Task 2).
- Produces:

  ```ts
  export type SyncLine = { turnId: string; from: SyncSource; text: string }
  // TurnTracker
  get current(): { turnId: string; isVoice: boolean } | null  // the main-loop turn running
  turnStarted(turnId, text, origin, now): SyncLine | null     // the owner's prompt of a typed turn
  turnCompleted(turnId, answer, outcome): Post | SyncLine | null
  adopted(id: RequestId): void    // a spoken reply: the rest of the running turn is a voice turn
  noteGap(): void; get hasGap(): boolean; gapReported(): void // kept in the snapshot
  // prompt.ts
  export function keyboardAnswer(result: { answers?: Record<string, string>; response?: string }): string
  ```

  `running` keeps its meaning. `Tracked.id` may be null: a typed turn, or a background turn outside the
  window. A snapshot from before this change still loads.

- [ ] **Step 1: Write failing tests** in `turns.unit.ts`:

  ```ts
  'a typed turn posts its prompt'         // turnStarted → { turnId, from: 'owner', text }
  'a typed turn posts its answer'         // turnCompleted → { turnId, from: 'claude', text }
  'a background turn outside the window posts its answer and no prompt'
  'a background turn in the window stays an update'
  'an interrupted typed turn posts nothing'
  'an adopted turn answers as a voice turn'  // Post with status ok and the reply's id; running is that id
  'current is the running turn of either kind, null after it ends'
  'the gap and the running turn survive a snapshot'
  'a snapshot from before sync loads'
  ```

  And in `prompt.unit.ts`: `keyboardAnswer` for one label, several, a free-text `response`, and neither.
- [ ] **Step 2: Run** `npm --prefix plugin run test:unit`. Expected: fail.
- [ ] **Step 3: Implement.** A voice turn in `turnStarted` returns null, as before. The `#followUp`
  reset stays where it is. `keyboardAnswer` gives `You answered at the keyboard: <answers, joined by
  "; ">`, and `Claude's question was closed at the keyboard.` when the result holds none.
- [ ] **Step 4: Run them again.** Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "feat(plugin): the tracker follows every main-loop turn"`

### Task 9: The hooks post it

**Files:** Modify: `plugin/hooks/register.tsx`, `plugin/hooks/link.ts`, `plugin/tests/fake-bridge.ts`,
`plugin/tests/roundtrip.test.tsx`, `plugin/tests/lifecycle.test.tsx`, `plugin/tests/offline.test.tsx`

**Interfaces:**
- Consumes: everything Task 8 produces; `SyncBody`, `MissedBody`, `JoinBody.syncs`,
  `ActivityBody.typedTurn` (Task 2).
- Produces: `BridgeLink.sync(line: SyncLine): Promise<boolean>`, true when the app took it;
  `BridgeLink.missed(): Promise<boolean>`, true when the app answered at all, so an older app's 404
  ends the retries.

- [ ] **Step 1: Write failing tests** in the engine tests, with `sync`, `missed`,
  `classic.PostToolUseFailure` and `classic.PermissionDenied` added to `fake-bridge.ts`:

  ```ts
  test('aTypedTurnIsSynced')                 // both lines, the prompt before `working`
  test('aTypedTurnSyncsWhileTheCallIsOff')   // the mod does not look at the call
  test('textTypedIntoARunningTurnIsSynced')  // prompt.submit with a turnId, a voice turn's too
  test('aVoicePromptIntoARunningTurnIsNotSynced')
  test('aTypedTurnsQuestionIsAsked')         // activity with `typedTurn`
  test('aTypedTurnsApprovalIsReported')      // replaces the assertion at the end of
                                             // refusedPromptFailsTheRequestAtOnce, which said the opposite
  test('aKeyboardAnswerIsSynced')            // a typed turn, and a voice turn
  test('aSpokenReplyMakesTheTurnAVoiceTurn') // its answer goes to /v1/answer with the reply's id
  test('aLateSpokenReplyClosesItsRequest')   // Review Focus 4: `failed` for the reply's id; LATE_REPLY still logged
  test('anAllowedPromptIsSynced')            // PostToolUse and PostToolUseFailure: allowed
  test('aDeniedPromptIsSynced')              // PermissionDenied: denied
  test('aFailedPostIsReportedAsMissed')      // app down for a turn; on the next good poll, one `missed`
  test('anOlderAppEndsTheRetries')           // 404 on both: one `missed`, none on later polls
  test('aTurnBeforeJoiningIsMissed')         // /live on in a session with turns posts `missed`
  test('aFreshSessionJoinsWithoutMissed')    // turns: 0
  test('aTypedTurnStillStalesTheSummary')    // Task 8 changed turnCompleted's result; `if (!post)` would stop
  test('joinSaysItSyncs')                    // syncs: true; update the join expectations
  ```

- [ ] **Step 2: Run** `claude plugin test plugin`, or the command `scripts/check.sh` uses. Expected:
  fail.
- [ ] **Step 3: Implement.** One helper, `postSync($, line)`: not joined or not taken is
  `tracker.noteGap()`. `tick`, after a good reply, and `turnOn`, after a join by the owner into a session
  with turns (a gap first), report the gap once. The `tool.call` and `classic.PermissionRequest` guards
  become `tracker.current !== null`, and each `activity('approval')` carries `typedTurn` unless
  `current.isVoice`. `answerQuestion` resolves with the `VoiceRequest`, so the race can tell a spoken
  reply from the dialog's result and call `tracker.adopted(reply.id)`. `tick`, finding no question open
  for a `reply`, posts `failed` for its id with the reason `the question was answered at the keyboard`:
  a 409 for a voice turn is harmless. `settles(e)` keeps its job; the line it adds says `You allowed
  <tool> at the keyboard.` from `PostToolUse` and `PostToolUseFailure`, `You denied <tool> at the
  keyboard.` from `PermissionDenied`. `staleSummary()` runs for every completed turn that is not a
  voice answer.
- [ ] **Step 4: Run them again, then `scripts/check.sh`.** Expected: pass, exit 0.
- [ ] **Step 5: Commit** `git commit -m "feat(plugin): typed turns, questions and approvals reach the app"`

---

## Wave E — Task 10

### Task 10: Docs, and the owner's check

**Files:** Modify: `README.md` and its six translations, `SECURITY.md`, `CHANGELOG.md`,
`docs/architecture/overview.md`, `docs/specs/2026-11-04-voice-session-context-design.md`,
`docs/specs/2026-11-05-conversation-sync-design.md`, `docs/plans/2026-11-06-conversation-sync.md`,
`docs/trail.toml`, `docs/roadmap.md` (by `stayfixed docs trail`)

- [ ] **Step 1: README and translations.** Privacy, How a call works, Settings (the setting that went,
  the one that came), the Load context item. Promise only what the code enforces.
- [ ] **Step 2: SECURITY.md.** Rewrite "A loaded context persists" and the advice after it: turning
  auto-load off no longer exists, and synced answers carry a session's text to the voice too. The
  mitigation is `/clear` with **New conversation**, removing the session, or the pause setting with
  Stop. A page Claude reads in a typed turn can now steer the voice through Claude's answer, as it could
  in a voice turn. Also list the new routes wherever the wire is enumerated.
- [ ] **Step 3: The overview, the CHANGELOG, the older spec** marked superseded where it says typed
  turns do not reach the voice and that auto-load stays on.
- [ ] **Step 4: The trail.** Set this spec and plan to `delivered`, run `stayfixed docs trail`.
- [ ] **Step 5: The owner's manual check,** asked for in Russian with the debug app and mod from the
  branch, and reported as it came out, in the PR body: two joined sessions; type in each; switch target
  without Stop and ask the voice what was typed; a question in a typed turn answered at the keyboard,
  then one answered by voice; a permission prompt in a typed turn; Stop with the pause on, type, Start,
  and confirm Load context lights up and the voice does not know the paused text.
- [ ] **Step 6: Commit** `git commit -m "docs: conversation sync"`, then `scripts/check.sh`.
