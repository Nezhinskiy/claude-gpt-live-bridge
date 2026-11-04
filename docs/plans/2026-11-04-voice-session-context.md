# The voice knows the Claude session: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the voice gets the target session's context at every Start, reopened line and target
change, fetches it itself with a `refresh context` handoff the app answers without Claude, and
reads "the chat" as the Claude session.

**Architecture:** the wire's `ContextBody` gains an optional `last`; the mod keeps Claude's last
reply and open question and posts them with the summary; the app takes the `refresh context`
handoff in `Bridge.route`, asks the target for context, and speaks the arriving `[CONTEXT]` and
`[LAST]` lines as the answer that ends the wait. Start, `openLine` and every retarget ask for
context; the Auto-context setting goes.

**Tech stack:** Swift 6 / SwiftPM (`BridgeCore`, Swift Testing), the mod in TypeScript on the
Claude Code engine (`claude plugin test`).

**Spec:** `docs/specs/2026-11-04-voice-session-context-design.md`

## Global Constraints

- A wire change touches `app/Sources/BridgeCore/Wire/Wire.swift`, `plugin/hooks/wire.ts` and
  `wire/fixtures/` together (AGENTS.md).
- A failing test before each change; one behaviour, one test; tests do not check prompt wording.
- No third-party packages; fixtures use `/Users/example`, `Example session`, `00000000-…` ids.
- The fetch brief is exactly `refresh context`; `[LAST]` is cut to 2,000 characters
  (`AnswerShaper.maxCharacters`); the fetch waits 60 s.
- Never add `Co-Authored-By: Claude` or any Claude attribution to commits or PRs.
- `scripts/check.sh` exits 0 before each commit (on Node 24 it needs PR #18's glob, which is on `dev`).

## Review Focus

- A brief that is `Refresh context.` or `refresh  context!` is taken; `refresh the context` and
  `refresh context and run the tests` go to Claude (Task 4 tests both).
- A fetch while the call is not live (the line closed after silence) still gets the context in
  and says it when the line opens (Task 4: a fetch is a handoff, so it reopens the line as an
  answer does under PR #27; test that the awaited context is spoken after `.connected`).
- A Start with no Claude turn yet must not overwrite the stored context with nothing (Task 3:
  an empty `summary` is not stored).
- A `/v1/context` that comes after the 60 s timeout said "context not available" must not be
  spoken as a late answer (Task 4: the awaited mark is cleared at the timeout; the late context
  goes in quietly).
- A reload of the mod between a turn and a fetch still posts the last reply (Task 2: `last` is
  read back from `$.store`).

---

### Task 1: `ContextBody.last` on the wire

**Files:**
- Modify: `app/Sources/BridgeCore/Wire/Wire.swift:115-118`, `plugin/hooks/wire.ts:54`,
  `plugin/hooks/link.ts:112`
- Create: `wire/fixtures/context-last.json`
- Test: `app/Tests/BridgeCoreTests/WireTests.swift:12-23`, `plugin/tests/unit/wire.unit.ts:59`

**Interfaces:**
- Produces: Swift `ContextBody { sessionId: SessionID; summary: String; last: String? }` (nil is
  omitted when encoded); TS `ContextBody = { sessionId: SessionId; summary: string; last?: string }`;
  `BridgeLink.context(summary: string, last?: string): Promise<boolean>`.

- [ ] **Step 1: Add the fixture and its test entries.** `context-last.json`:
  `{"sessionId":"00000000-0000-0000-0000-000000000001","summary":"Goal: tidy the example project.","last":"Two folders hold build output. Which name should the folder get? Options: build: the default; out: shorter."}`.
  In `WireTests.roundTrips` add `"context-last": roundTrip(ContextBody.self)`; in
  `wire.unit.ts` make `SHAPES['context']` `{ sessionId: S, summary: S, last: optional(S) }`.
- [ ] **Step 2: Run** `swift test --filter WireTests` in `app/` and the mod's unit tests
  (`scripts/check.sh` runs them). Expected: FAIL, `last` is not a field.
- [ ] **Step 3: Add the field** on both sides and `last` to `link.context`, sent only when given.
- [ ] **Step 4: Run** both again. Expected: PASS, `context.json` (no `last`) still round-trips.
- [ ] **Step 5: Commit** `feat(wire): a context may carry Claude's last reply`.

### Task 2: the mod posts Claude's last reply and open question

**Files:**
- Modify: `plugin/hooks/register.tsx` (`turn.complete` 452-467, the `AskUserQuestion` hook
  473-485, `writeAndPost` 303-314, `save`/`session.start`)
- Test: `plugin/tests/context.test.tsx`

**Interfaces:**
- Consumes: `link.context(summary, last?)` (Task 1).
- Produces: every context post carries `last` when the session has a last reply; a session with
  no turn and no last reply posts `{ summary: '' }` (Task 3 reads an empty summary as "nothing").

- [ ] **Step 1: Write the failing tests** in `context.test.tsx`:
  - `aContextCarriesClaudesLastReply`: after `$.turn.complete({ ...DONE, turnId: 't1', answer: 'Three files.' })`
    a `world.work.push({ kind: 'context' })` poll posts `{ ...SUMMARY, last: 'Three files.' }`.
  - `anOpenQuestionFollowsTheLastReply`: with an `AskUserQuestion` open (any turn, typed
    included), `last` is `'Three files.\n\n' + askedText(ASKED)`; after `world.answerDialog`, the
    next post has no question.
  - `theLastReplySurvivesAReload`: after a turn, `$.session.start` again with the same `world.stored`;
    the next context post carries the same `last`.
  - `anEmptySessionPostsAnEmptySummary`: with `world.turns = 0` and no turn, a context poll
    posts `{ sessionId: ID, summary: '' }` and makes no fork (`world.forks === 0`).
- [ ] **Step 2: Run** `claude plugin test plugin`. Expected: the four FAIL.
- [ ] **Step 3: Implement.** Keep `lastReply` (main loop's `e.answer` when non-empty) and
  `openQuestion` (set from `askedText(e.questions)` before the hook's early return, cleared in
  its `finally` and when the call settles). Store `lastReply` under `last:${sessionId}` in
  `$.store` beside the join, read it in `session.start`, delete it where the join key is deleted.
  `writeAndPost` posts `link.context(text, last)` where `last` is `lastReply` plus the open
  question, and posts `''` as the summary instead of returning `'empty'` before posting.
- [ ] **Step 4: Run** `claude plugin test plugin`. Expected: PASS, existing context tests too.
- [ ] **Step 5: Commit** `feat(mod): a context brings Claude's last reply and open question`.

### Task 3: the app keeps and seeds `[LAST]`

**Files:**
- Modify: `app/Sources/BridgeCore/Call/CallMachine.swift:6-21` (`VoiceLine.Kind`),
  `app/Sources/BridgeCore/Bridge.swift:468-479` (`context`),
  `app/Sources/BridgeCore/Call/Continuity.swift` (`Conversation`, `initialItems`, `setContext`)
- Test: `app/Tests/BridgeCoreTests/BridgeTests.swift`, `ContinuityTests.swift`

**Interfaces:**
- Produces: `VoiceLine.Kind.last` (raw `"LAST"`, not in `answers`); `Conversation.last: String?`;
  `Continuity.setContext(_ line: String, last: String?, for: SessionID)`; `initialItems` puts the
  `[LAST]` line right after `[CONTEXT]`. `Bridge.context` returns the two lines it built
  (`(context: VoiceLine?, last: VoiceLine?)`) for Task 4.

- [ ] **Step 1: Write the failing tests:**
  - `lastReplyIsRedactedCutAndKept` (BridgeTests): a `/v1/context` with a 3,000-character `last`
    holding a secret stores a `[LAST] Example session: …` line of at most 2,000 characters with
    the secret redacted; `lines()` show it beside `[CONTEXT]`.
  - `theLastReplySeedsTheNextLine` (ContinuityTests): `initialItems` begins `[CONTEXT]…`, `[LAST]…`.
  - `anEmptySummaryLeavesTheKeptContext` (BridgeTests): after a context `"Goal A"`, a post with
    `summary: ""` and no `last` leaves `"[CONTEXT] Example session: Goal A"` kept.
  - `aLiveLineGetsTheLastReplyQuietly` (BridgeTests): on a live line for that session, the
    `[LAST]` line goes to `voice.added`, not `voice.spoken`.
- [ ] **Step 2: Run** `swift test --filter "BridgeTests|ContinuityTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the kind, the field (Codable, so an old `continuity.json` decodes
  with `last` nil), and `Bridge.context`: an empty summary stores nothing and adds nothing.
- [ ] **Step 4: Run** the same filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(app): keep and seed Claude's last reply as a [LAST] line`.

### Task 4: the app answers `refresh context` itself

**Files:**
- Create: `app/Sources/BridgeCore/Call/ContextFetch.swift`
- Modify: `app/Sources/BridgeCore/Bridge.swift` (`route` 413, `realtimeEvent` 352-360,
  `context`), `app/Sources/BridgeCore/Call/CallMachine.swift` (a `.fetchAnswered` event),
  `app/Sources/BridgeCore/Call/Continuity.swift` (a `.fetch` speaker)
- Test: `app/Tests/BridgeCoreTests/ContextFetchTests.swift`, `BridgeTests.swift`, `CallMachineTests.swift`

**Interfaces:**
- Consumes: Task 3's lines from `Bridge.context`.
- Produces: `enum ContextFetch { static let brief = "refresh context"; static func isFetch(_ brief: String) -> Bool; static let timeoutSeconds = 60 }`;
  `Conversation.Line.Speaker.fetch` (name `"Context"`, text `"requested"`, role nil, never seeded);
  `CallEvent.fetchAnswered(SessionID)` removes the session from `awaited`.

- [ ] **Step 1: Write the failing tests:**
  - `ContextFetchTests.theBriefIsTakenInAnyCaseAndPunctuation`: `isFetch` is true for
    `"refresh context"`, `"Refresh context."`, `"  REFRESH   context!"`; false for
    `"refresh the context"`, `"refresh context and run the tests"`, `""`.
  - `BridgeTests.aFetchNeverReachesClaude`: `voice.emit(.handoff(…brief "Refresh context."))`
    on a live line queues no request (the next poll has no `request` work), asks the target for
    context (the poll returns `.context`), and records a `Context: requested` line, no `Task` line.
  - `BridgeTests.anAwaitedContextIsSpokenAndEndsTheWait`: after the fetch, a `/v1/context` with
    `last` puts `[CONTEXT]` then `[LAST]` in `voice.spoken`, and the result window does not
    close the line on its account (advance 120 s with the session polling: still live).
  - `BridgeTests.aFetchNobodyAnswersFailsAfterAMinute`: advance 60 s with no context: `voice.spoken`
    gets `[FAILED] Example session: context not available`; a context posted after it goes to
    `voice.added`.
  - `BridgeTests.aFetchWithNoTargetFailsAtOnce`: with no session joined, the fetch gives the
    existing `[FAILED] LiveBridge: no Claude Code session is joined.` and nothing else.
  - `BridgeTests.aFetchOnAnEmptySessionSaysSo`: an awaited `/v1/context` with `summary: ""` and
    no `last` speaks `[CONTEXT] Example session: the session has no messages yet.`
  - `BridgeTests.aFetchWhileTheLineIsClosedIsSaidWhenItOpens` (Review Focus): the line closed
    after silence, the fetch's context arrives, and after the line opens again the context is
    spoken.
  - `CallMachineTests` row `fetchAnsweredEndsTheWait`: given a live machine awaiting `s`,
    `.fetchAnswered(s)` leaves `awaited` empty and emits nothing.
- [ ] **Step 2: Run** `swift test --filter "ContextFetchTests|BridgeTests|CallMachineTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.** In `route`, before `enqueue`, `ContextFetch.isFetch(request.brief)`
  marks `awaitingContext = (session, deadline)`, calls `registry.requestContext(for:)`, records
  the `.fetch` line, and returns the session so `.handedOff` still holds the line. A timer of
  `timeoutSeconds` delivers the failed line and clears the mark. `Bridge.context` for the awaited
  session sends `.deliver` for its lines (so an awaited session hears them as speech, and a
  closed line holds them as an answer under PR #27), then `.fetchAnswered`, and clears the mark.
- [ ] **Step 4: Run** the same filter, then `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(app): the voice fetches the session's context without Claude`.

### Task 5: context at every Start, reopened line and retarget

**Files:**
- Modify: `app/Sources/BridgeCore/Bridge.swift` (`perform` 100-110, `openLine` 291),
  `app/Sources/BridgeCore/Sessions/SessionRegistry.swift` (82-84, `retarget` 267),
  `app/Sources/BridgeCore/Settings.swift` (10, 21, 25, 35), `app/Sources/LiveBridge/App.swift:152`,
  `app/Sources/LiveBridge/SettingsView.swift:55-60`, `README.md` and its translations where they
  name the Auto-context setting
- Test: `BridgeTests.swift`, `SessionRegistryTests.swift:250-264`, `SettingsTests.swift`

**Interfaces:**
- Produces: `SessionRegistry.init(time:)` (no `autoContext`); `retarget` always sets `wantsContext`.

- [ ] **Step 1: Write the failing tests:**
  - `BridgeTests.aMenuStartAsksForContext`: `perform(.start)` with a target makes the next poll
    return `.context`.
  - `BridgeTests.aReopenedLineAsksForContext`: after the line closes and opens again, the next
    poll returns `.context`.
  - `SessionRegistryTests.aNewTargetIsAskedForContext`: `setTarget` makes that session's next
    poll `.context` (replacing the two autoContext rows).
  - `SettingsTests`: an old settings file with `"autoContext":true` still decodes.
- [ ] **Step 2: Run** `swift test --filter "BridgeTests|SessionRegistryTests|SettingsTests"`. Expected: FAIL.
- [ ] **Step 3: Implement**, removing `autoContext` from `Settings`, the registry, `App.swift`
  and the Settings view's Context section; docs that name the toggle say context now always loads.
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(app): every Start, reopened line and target change loads context`.

### Task 6: the voice prompt

**Files:**
- Modify: `app/Sources/BridgeCore/Codex/VoicePrompt.swift:18-70`
- Test: `app/Tests/BridgeCoreTests/VoicePromptTests.swift`

- [ ] **Step 1: Write the failing test** `thePromptNamesTheFetchTheBridgeTakes`: `VoicePrompt.composed(owner: nil)`
  contains `ContextFetch.brief`, so the prompt and `ContextFetch` cannot drift apart.
- [ ] **Step 2: Run** `swift test --filter VoicePromptTests`. Expected: FAIL.
- [ ] **Step 3: Edit the prompt:** "the chat", its context, what is there and having a look mean
  the Claude session the voice serves, never this conversation; when the lines it has do not
  cover such a question, hand off exactly `\(ContextFetch.brief)` instead of saying it will look;
  `[LAST]` joins the tag list as what Claude last wrote in the chat, used, and read out only
  when the owner asks for it.
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(app): the voice reads "the chat" as the Claude session`.

### Task 7: a switch says what was held (after PR #27 is on `dev`)

**Files:**
- Modify: `app/Sources/BridgeCore/Call/CallMachine.swift` (`.connected`, as PR #27 leaves it)
- Test: `CallMachineTests.swift`, `BridgeTests.swift`

**Interfaces:**
- Consumes: PR #27's per-session handling of `pending` (read its `CallMachine` first; this task
  starts only once #27 is merged into `dev` and this branch is rebased on it).

- [ ] **Step 1: Write the failing tests:**
  - `CallMachineTests` row `aSwitchSaysTheNewTargetsHeldAnswers`: pending `[RESULT]` lines for
    `s2` while `s1` was the target; `.connected` for a line on `s2` gives `.speak` for them
    (after any `addContext`), and `s1`'s pending lines stay pending.
  - `BridgeTests.switchingToASessionSaysItsAnswer`: an answer for the non-target `s2` chimes; the
    owner makes `s2` the target; once the line is open again, the answer is in `voice.spoken`
    and the context request for `s2` went out.
- [ ] **Step 2: Run** `swift test --filter "CallMachineTests|BridgeTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** in `.connected`: the new line's session's pending lines are spoken,
  the rest stay.
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(app): a switch to a session says the answers it held`.

### Task 8: docs and the end-to-end check

**Files:**
- Modify: `docs/architecture/overview.md` (the context flow, the wire table row for
  `/v1/context`, the voice's tags), `README.md` and its six translations (the "look at the chat"
  behaviour, where the band and menu are described), `CHANGELOG.md` (Unreleased),
  `docs/specs/2026-11-04-voice-session-context-design.md` (status `delivered`), `docs/trail.toml`
  (both documents `delivered`), then `stayfixed docs trail`

- [ ] **Step 1: Update the docs** to say only what Tasks 1-7 enforce.
- [ ] **Step 2: Run** `scripts/check.sh`. Expected: exit 0.
- [ ] **Step 3: By hand, with the owner's yes:** `scripts/smoke.sh` once; "look at the chat" ends
  in a `refresh context` line in the Conversation and a spoken answer.
- [ ] **Step 4: Commit** `docs: the voice knows the Claude session`.
