# The voice knows the Claude session: implementation plan

> **Delivered in part (2026-11-05).** Line-open context and the "the chat" rule shipped. The
> fetch (`refresh context`), `[LAST]` and the wire field `last` were taken out after six real
> smoke runs showed the voice's handoff brief is the owner's words verbatim, so the voice never
> sent the fetch; they are kept on branch `feat/voice-context-fetch`. See the
> [spec's status](../specs/2026-11-04-voice-session-context-design.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Dispatch by wave: a wave's tasks share no file and may run in parallel; a wave starts when the one before it is reviewed.

**Goal:** every line the app opens gives the voice the target's context; the voice fetches it
itself with a `refresh context` handoff the app answers without Claude, hearing Claude's last
reply as `[LAST]`; the voice reads "the chat" as the Claude session.

**Architecture:** `ContextBody` gains an optional `last`. The mod keeps Claude's last reply and
open question in memory and posts them with the summary. `RealtimeSession` turns the
`refresh context` handoff into its own event; the registry keeps the fetch's deadline beside
`wantsContext` and `sweep()` fails it; the call machine speaks a fetch's answer on a path of its
own that never touches `awaited` or `unheard`. `openLine` asks for context when Load context
automatically is on (now by default).

**Tech stack:** Swift 6 / SwiftPM (`BridgeCore`, Swift Testing), the mod in TypeScript on the
Claude Code engine (`claude plugin test`).

**Spec:** `docs/specs/2026-11-04-voice-session-context-design.md`

**Before Wave 1:** the work branch starts from `origin/dev` with PR #24's branch
(`origin/fix/question-carries-turn-text`: the text of the step that asks a question) merged in,
or from `dev` once #24 is merged there. Task 2 uses its `stepText`.

## Global Constraints

- A wire change touches `app/Sources/BridgeCore/Wire/Wire.swift`, `plugin/hooks/wire.ts` and
  `wire/fixtures/` together (AGENTS.md).
- A failing test before each change; one behaviour, one test; tests do not check prompt wording.
- Docs change in the same task as the behaviour they describe; SECURITY.md never claims more
  than the code enforces.
- The fetch brief is exactly `refresh context`; `[LAST]` keeps its end within 2,000 characters
  (`AnswerShaper.maxCharacters`); the mod clips `last` to 8,000 characters at a line break; the
  fetch waits `ContextLoads.timeout` (60 s).
- Never add `Co-Authored-By: Claude` or any Claude attribution to commits or PRs.
- `scripts/check.sh` exits 0 before each commit.

## Review Focus

- A fetch asked while Claude still works on a handoff to the same session must not end that
  wait, and Claude's result must not end the fetch's (Task 3,
  `aFetchAndAHandoffKeepTheirOwnWaits`).
- A fetch with Claude's question open must leave the question's route alone, so the owner's next
  reply still answers it (Task 3, `aFetchKeepsTheQuestionsRoute`).
- A fetch's answer must not count as unheard, chime, or be re-added to a reopened line (Task 3,
  `aFetchsAnswerIsNotUnheard`).
- A stale fetch must not speak another session's context into a new line (Task 3,
  `aTargetChangeDropsTheFetch`).
- A reply full of code must reach the voice as prose with its conclusion, not a cut code block
  (Task 3, `lastDropsCodeAndKeepsTheEnd`).

---

## Wave 1

### Task 1: `ContextBody.last` on the wire

**Files:**
- Modify: `app/Sources/BridgeCore/Wire/Wire.swift:115-118`, `plugin/hooks/wire.ts:54`
- Create: `wire/fixtures/context-last.json`
- Test: `app/Tests/BridgeCoreTests/WireTests.swift:12-23`, `plugin/tests/unit/wire.unit.ts:54`

**Interfaces:**
- Produces: Swift `ContextBody { sessionId; summary: String; last: String? }` (nil omitted);
  TS `ContextBody = { sessionId: SessionId; summary: string; last?: string }`.

- [ ] **Step 1:** add `context-last.json`
  (`{"sessionId":"00000000-0000-0000-0000-000000000001","summary":"Goal: tidy the example project.","last":"Two folders hold build output."}`),
  `"context-last": roundTrip(ContextBody.self)` in `WireTests.roundTrips`, and `last: optional(S)`
  in `SHAPES['context']`.
- [ ] **Step 2:** run `swift test --filter WireTests` and `npm run typecheck:pure` in `plugin/`.
  Expected: FAIL (`last` is not a field).
- [ ] **Step 3:** add the field on both sides.
- [ ] **Step 4:** run both again. Expected: PASS; `context.json` still round-trips.
- [ ] **Step 5:** commit `feat(wire): a context may carry Claude's last reply`.

## Wave 2 (Task 2 and Tasks 3-4 in parallel; Tasks 3 and 4 in series)

### Task 2: the mod posts Claude's last reply and open question

**Files:**
- Modify: `plugin/hooks/register.tsx` (`turn.complete` 452-467, the `AskUserQuestion` hook
  473-485 as PR #24 leaves it, `writeAndPost` 303-314, `staleSummary` 254, `startHere` 369-373,
  `follow` 179), `plugin/hooks/link.ts:112`, `plugin/hooks/turns.ts:22-25` and
  `register.tsx:442` comments
- Test: `plugin/tests/context.test.tsx`, `plugin/tests/fake-bridge.ts` (export `ASKED`, moved
  from `roundtrip.test.tsx:95`)

**Interfaces:**
- Consumes: Task 1's `ContextBody.last`.
- Produces: `BridgeLink.context(summary: string, last?: string): Promise<boolean>`; every
  context post carries `last` when there is one; a post with `summary: ''` means "no summary".

- [ ] **Step 1: Write the failing tests** in `context.test.tsx`:
  - `aContextCarriesClaudesLastReply`: after `$.turn.complete({ ...DONE, turnId: 't1', answer: 'Three files.' })`
    in a typed turn, a `{ kind: 'context' }` poll posts `{ ...SUMMARY, last: 'Three files.' }`.
  - `anOpenQuestionComesWithTheTextThatAskedIt`: with PR #24's step text `'Two folders.'` and an
    `AskUserQuestion` open in a typed turn, `last` is `'Two folders.\n\n' + askedText(ASKED)`;
    after `world.answerDialog('build')` the question is gone from the next post.
  - `aLongLastReplyIsClipped`: a 20,000-character answer posts a `last` of at most 8,000
    characters that ends at a line break.
  - `aVoiceTurnKeepsTheSummaryCached`: after one context post, a voice turn completes; the next
    context post makes no fork (`world.forks` unchanged). A typed turn then makes one.
  - `aFailedSummaryStillSendsTheLastReply`: with `world.forkFails = 'api-error'`, the post is
    `{ sessionId: ID, summary: '', last: 'Three files.' }`.
  - `clearForgetsTheLastReply`: after `/clear` the next post has no `last`.
- [ ] **Step 2:** run `claude plugin test plugin`. Expected: the six FAIL.
- [ ] **Step 3: Implement.** In-memory `lastReply` (main loop's non-empty `e.answer`) and
  `openQuestion` (set at the hook's top, typed turns included, cleared in a `finally` on both the
  early-return path and the voice path); `lastText()` joins them, preferring PR #24's `stepText`
  while a question is open, clipped to 8,000 at the last `\n`. `staleSummary()` runs only for a
  turn `tracker.turnCompleted` posts nothing for, and on `/clear` (which also clears both).
  `writeAndPost` posts `link.context(summary or '', lastText())` and posts `''` when the summary
  failed; an empty session with no `lastText()` still returns `'empty'` without posting
  (register.tsx:288 stays). `startHere` drops `void contextAsked($)`. Fix the two comments that
  say a typed turn's answer never reaches the voice: it does, as `last`, when the owner fetches.
- [ ] **Step 4:** run `claude plugin test plugin`. Expected: PASS, existing tests included.
- [ ] **Step 5:** commit `feat(mod): a context brings Claude's last reply and open question`.

### Task 3: the voice fetches context, and hears `[LAST]`

**Files:**
- Modify: `app/Sources/BridgeCore/Codex/RealtimeSession.swift` (`RealtimeEvent` 4-14, `handoff`
  327-342), `app/Sources/BridgeCore/Sessions/SessionRegistry.swift` (`requestContext` 161,
  `sweep` 213-220, `drop`), `app/Sources/BridgeCore/Call/CallMachine.swift` (events, a
  `fetching: SessionID?` field, `words` 274 made internal), `app/Sources/BridgeCore/Bridge.swift`
  (`realtimeEvent` 352-360, `context` 468-479, the sweep at 481-484),
  `app/Sources/BridgeCore/Text/AnswerShaper.swift` (the prose step of `forVoice` 8-26 as its own
  function), `app/Sources/BridgeCore/Codex/VoicePrompt.swift:18-70`, `SECURITY.md` (:107,
  :122-123, Residual risk), `README.md` Privacy (:294-317) and its six translations
- Test: `BridgeTests.swift`, `CallMachineTests.swift`, `SessionRegistryTests.swift`,
  `RealtimeSessionTests.swift` (or the file that tests `handoff` parsing), `AnswerShaperTests.swift`

**Interfaces:**
- Consumes: Task 1's `ContextBody.last`.
- Produces: `RealtimeEvent.contextFetch`; `RealtimeSession.fetchBrief = "refresh context"`;
  `SessionRegistry.requestContext(for:fetch: Date?)` and a fetch-failed `Delivery` from
  `sweep()`; `CallEvent.fetchAsked(SessionID)` and `CallEvent.fetchAnswered([VoiceLine])`;
  `VoiceLine.Kind.last` (raw `"LAST"`, not in `answers`); `AnswerShaper.prose(_:)`.

- [ ] **Step 1: Write the failing tests:**
  - `theFetchBriefIsItsOwnEvent` (handoff parsing): `refresh context`, `Refresh context.`,
    `` `refresh context` `` and `"REFRESH  context!"` give `.contextFetch`; `refresh the context`
    and `refresh context and run the tests` give `.handoff`.
  - `BridgeTests.aFetchNeverReachesClaude`: after `.contextFetch` the target's next poll is
    `.context`, no `request` work is queued, and no conversation line is recorded.
  - `BridgeTests.aFetchsAnswerIsSpoken`: a `/v1/context` with `last` then puts the `[CONTEXT]`
    and `[LAST] Example session: …` lines in `voice.spoken`; the band's unheard count stays 0
    (`aFetchsAnswerIsNotUnheard`).
  - `BridgeTests.aFetchAndAHandoffKeepTheirOwnWaits`: a handoff to `s`, then a fetch; the
    context answers the fetch, the line stays open past 20 s of silence, and Claude's result is
    then spoken.
  - `BridgeTests.aFetchKeepsTheQuestionsRoute`: with `[ASKING]` open on `s1` and target `s2`, a
    fetch asks `s2`, and the next handoff still goes to `s1`.
  - `BridgeTests.aFetchNobodyAnswersFailsAfterAMinute`: polling every second, 60 s pass:
    `voice.spoken` gets `[FAILED] Example session: context not available`; a context after it
    goes to `voice.added`.
  - `BridgeTests.aTargetChangeDropsTheFetch`: a fetch on `s1`, then target `s2`; `s1`'s late
    context is not spoken.
  - `BridgeTests.aSummaryOnlyFailureSpeaksTheLastReply`: an awaited post with `summary: ""` and a
    `last` speaks `[LAST]` alone and keeps the stored `[CONTEXT]`.
  - `AnswerShaperTests.lastDropsCodeAndKeepsTheEnd`: a reply with a fenced `.env` block holding
    `ghp_…` and 3,000 characters of prose gives a line of at most 2,000 characters, without the
    block, ending with the prose's last sentence.
  - `CallMachineTests`: rows `fetchAnsweredSpeaksOnALiveLine` (`.speak` per line, no change to
    `pending`) and `fetchAnsweredWhileTheOwnerSpeaksIsHeld` (said after the grace).
- [ ] **Step 2:** run `swift test`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** `handoff` checks `CallMachine.words(brief) == ["refresh", "context"]`
  after stripping quotes and backticks, and emits `.contextFetch`. `realtimeEvent` handles it:
  no target gives the existing no-session line; else `requestContext(for: target, fetch: now + ContextLoads.timeout)`
  and `send(.fetchAsked(target))`. `context` builds `[LAST]` with `AnswerShaper.prose`, redaction
  and an end-keeping cut, and sends `.fetchAnswered` when the registry says a fetch was due (then
  clears it); an empty summary stores nothing. `sweep` returns the failed fetch as a `Delivery`
  that the bridge sends as `.fetchAnswered([failed line])`. The machine clears `fetching` on
  `.fetchAnswered`, Stop, `.conversationChanged` and a closed line; while `fetching` is set the
  silence timer does not close the line. Prompt: the rule on "the chat"; hand off exactly
  `\(RealtimeSession.fetchBrief)`, in English; `[LAST]` joins the tag list; a typed turn's
  question waits at the keyboard. SECURITY.md and README Privacy: `[LAST]` is sent only on the
  owner's fetch, as one shaped line of at most 2,000 characters, and is not kept.
- [ ] **Step 4:** run `swift test`. Expected: PASS.
- [ ] **Step 5:** commit `feat(app): the voice fetches the session's context without Claude`.

### Task 4: every line the app opens loads context

**Files:**
- Modify: `app/Sources/BridgeCore/Bridge.swift` (`openLine` 291, `context`'s live check 476),
  `app/Sources/BridgeCore/Settings.swift` (default `autoContext = true` at 21 and 35),
  `app/Sources/BridgeCore/Sessions/SessionRegistry.swift:267` (`retarget` no longer asks),
  `app/Sources/LiveBridge/App.swift:152`, `SettingsView.swift:55-60` (label "Load context
  automatically when a line opens"), `README.md:242` and its translations, `SECURITY.md:141-147`
- Test: `BridgeTests.swift`, `SessionRegistryTests.swift:250-264`, `SettingsTests.swift`

**Interfaces:**
- Consumes: Task 3's `context` and registry.
- Produces: `openLine` calls `registry.requestContext(for: lineSession, fetch: nil)` when
  `settings.autoContext`; `SessionRegistry.init(time:)` loses `autoContext`.

- [ ] **Step 1: Write the failing tests:**
  - `BridgeTests.openingALineAsksForContext`: the target's next poll after `perform(.start)` and
    after a reopened line is `.context`; with the setting off it is not.
  - `BridgeTests.contextThatArrivesWhileConnectingReachesTheLine`: posted during `.connecting`,
    it is in `voice.added` once connected.
  - `BridgeTests.anUnchangedContextIsNotAddedAgain`: the same summary posted twice adds once.
  - `SettingsTests.loadContextAutomaticallyIsOnByDefault`: `Settings()` and a file without the key.
  - Rewrite `becomingTargetWithAutoContextAsksForContext` (SessionRegistryTests.swift:250-264) as
    `becomingTargetAsksForNothing`.
- [ ] **Step 2:** run `swift test`. Expected: FAIL.
- [ ] **Step 3: Implement** as in Interfaces; hold a connecting line's context and add it at
  `.connected`; skip `addContext` and `save` when the line equals the stored one.
- [ ] **Step 4:** run `swift test`. Expected: PASS.
- [ ] **Step 5:** commit `feat(app): every line the app opens loads context`.

## Wave 3

### Task 5: the smoke case and the docs

**Files:**
- Modify: `scripts/smoke.sh` (:9, :24), `app/Tests/Smoke/fake-session.mjs` (:118-119, send
  `last`), `docs/architecture/overview.md` (context flow, the `/v1/context` row, the tags,
  :93-96), `CHANGELOG.md` (Unreleased), the spec's status and `docs/trail.toml` (`delivered`),
  then `stayfixed docs trail`

- [ ] **Step 1:** add a "look at the chat" smoke case that passes when the voice hands off
  `refresh context`, the fake session receives no request, and a `[LAST]` line is spoken.
- [ ] **Step 2:** update the docs to what Tasks 1-4 enforce; run `scripts/check.sh`. Expected: exit 0.
- [ ] **Step 3: By hand, with the owner's yes:** run `scripts/smoke.sh` once (about a minute of
  realtime voice). Expected: both cases pass.
- [ ] **Step 4:** commit `docs: the voice knows the Claude session`.

---

## Review rulings

The review (`docs/reviews/2026-11-04-voice-context-review.md` on `review/voice-context`) was
checked against the tree; these were decided:

- Accepted and built in: R1, R2 (a fetch has its own path), R3, R10 and S6 (the switch's held
  answers leave this plan for a spec with PR #27), R4, R5 (replaced tests), R6 and R9 and S13
  (no test that already passes), R7 and S5 (no store key), R8 and S2 (asked in `openLine` only,
  `retarget` unchanged), R11 (after PR #24, `finally` on both paths), R12, R13, R14, R15, S1 (the
  registry's sweep, `ContextLoads.timeout`), S7 and X3 (`RealtimeSession` recognises the fetch),
  S8, S9 in part (a failed summary posts `''` with `last`; an empty session still posts nothing
  and fails after 60 s), S11 (no new speaker; no menu line for a fetch), S12, S14 (no prompt
  test), S17 (waves), X1 (`[LAST]` only on a fetch; Load context automatically kept as the
  opt-out, on by default), X2, X4, X5, X6, and every Minor plan fix.
- Adapted: S3. A reopen asks for context, but the mod reuses its summary after a voice turn,
  so a reopen costs a model call only after a typed turn; an unchanged line is not added again.
- Not taken: S4 (`[LAST]` repeating a voice turn's `[RESULT]` matters little now that it goes
  only on a fetch), S15, S16 (they overturn approved decisions).
