# Review: the voice knows the Claude session (spec and plan)

Reviewed 2026-11-04, before execution:

- spec: [docs/specs/2026-11-04-voice-session-context-design.md](../specs/2026-11-04-voice-session-context-design.md)
- plan: [docs/plans/2026-11-04-voice-session-context.md](../plans/2026-11-04-voice-session-context.md)

The tree was `origin/docs/voice-context-spec` at `445a70f`, on `origin/dev` at `a680968`. PR #24
(`turn.step`) and PR #27 (`CallMachine`) were read as unmerged diffs. Nothing in the spec or plan
was changed.

The review has three parts:

1. `superpowers:requesting-code-review`: soundness, completeness, and whether each premise holds
   in the tree.
2. `simplify`: reuse, simplification, efficiency and altitude.
3. `security-review`: data exposure, misrouting and the permission-prompt rule.

Each finding is listed once, under the part where it belongs most, and the other parts link to it.
Every file:line was read in the tree. A claim the reviewers could not verify is marked as such.

## Architecture: elegant enough, and is anything redundant?

Not yet. The goal is sound and small:

- the voice gets the session's context when a line opens;
- it can refresh that context without Claude;
- it reads "the chat" as the Claude session.

The design reaches this by adding a parallel mechanism next to each existing one, rather than
extending the one that is there:

- **Three clocks for one wait.** The mod gives up after `CONTEXT_TIMEOUT_MS` (60 s,
  `plugin/hooks/register.tsx:27`). The menu tracks a pending context with its own 60 s timeout
  (`ContextLoads.timeout`, `app/Sources/BridgeCore/Menu/ContextLoads.swift:27-47`). The plan
  then adds `ContextFetch.timeoutSeconds`, a Bridge `awaitingContext` mark, a timer task and a
  `.fetchAnswered` event (S1).
- **Two waits in one set.** The fetch reuses `CallMachine.awaited`, which already means "a Claude
  request is open". That is the cause of both Critical findings (R1, R2).
- **Three call sites for one rule.** Context is asked for in `perform(.start)`, `openLine` and
  `retarget`, and the band's `startHere` still asks too. `openLine` alone covers every case
  (S2).
- **The same text sent twice.** After a voice turn, `[LAST]` repeats the `[RESULT]` and `[ASKING]`
  lines the conversation already holds (S4).
- **New files and keys that the code already has an equivalent for.**
  - `ContextFetch.swift` holds one constant and one normaliser; `CallMachine.words` already folds
    case (S8).
  - A `last:${id}` store key needs its own deletes; the joined record already persists (S5).
  - A tuple return exists only because Tasks 3 and 4 split one function (S12).
- **Scope that is not this goal.** Task 7 rests on an unmerged PR and changes every reconnect, not
  only switches (S6).

A shape that does the same job with less:

1. The wire gains an optional `last`, clipped in the mod (R13).
2. `RealtimeSession` classifies the fetch where it parses the handoff, as its own `RealtimeEvent`
   case. `route` is left untouched, and so are its `questionRoute` and `withdraw` (S7, X3).
3. The registry records "context asked for by the voice" with a deadline beside `wantsContext`.
   Its existing one-second `sweep()` fails the fetch as a `.failed` delivery, the way it already
   fails stuck requests. That removes the timer, the mark and the timeout constant (S1).
4. The call machine gets one field for the awaited fetch and one effect that speaks its answer.
   That effect never enters `awaited` or `unheard` (R1, R2).
5. Context is asked for in `openLine`, at most once per new turn (S2, S3).
6. `[LAST]` goes to the voice only in answer to a fetch. It is not seeded or stored, and it is not
   sent for a voice turn whose `[RESULT]` the voice already has (X1, S4).
7. Task 7 moves to its own spec, which lands with PR #27 (S6).

That shape drops `ContextFetch.swift`, the `.fetchAnswered` event, the timer, the tuple, the store
key and Task 7's special case. It also removes R1, R2, X3 and X4 by construction.

---

## 1. Soundness, completeness, premises (`superpowers:requesting-code-review`)

What holds:

- **Line references.** Almost every file:line in the plan points where it says: Wire.swift:115-118,
  wire.ts:54, link.ts:112, register.tsx 303-314, 452-467 and 473-485, CallMachine.swift:6-21,
  Bridge.swift 100-110, 291, 352-360, 413 and 468-479, SessionRegistry.swift 82-84 and 267,
  Settings.swift 10/21/25/35, App.swift:152, SettingsView.swift:55-60 and VoicePrompt.swift:18-70.
- **Fixture naming.** `context-last.json` satisfies the rule on both sides. The TS regex
  `(-[a-z]+)?\.json$` maps it to `SHAPES['context']`, and Swift's `roundTrips` keys must equal the
  fixture set.
- **`scripts/check.sh`** runs the mod's unit tests (line 18).
- **Time is testable.** BridgeCore has a clock abstraction (`TimeSource`, `TestTime.advance`), so
  a fetch timeout can be tested.
- **`last` is never stale.** The summary cache and the `sending ??=` join in register.tsx:283 are
  reused correctly, and `last` is read at post time, so a cached summary does not freeze it.

### Critical

**R1. A fetch shares `CallMachine.awaited` with a real Claude request to the same session.**

- Where: plan Task 4, Step 3 and Interfaces; `app/Sources/BridgeCore/Call/CallMachine.swift:96`,
  `:158-165`, `:175-179`.
- Problem: `awaited` is one `Set<SessionID>`. The likeliest fetch is "what's in the chat?" asked
  while Claude still works on an earlier handoff, so `awaited` already holds that session.
  - If the context comes first, `.fetchAnswered(A)` removes A. The line stops waiting for Claude:
    silence closes it after 20 s, and Claude's result then only chimes.
  - If Claude's result comes first, `if result.kind.answers { awaited.remove(session) }`
    (`:162`) removes A. The context's `.deliver` then takes the branch that is not awaited,
    `return [.addContext(result), armSilence()]` (`:160`). The fetch's answer goes in quietly,
    not as speech, which breaks the spec's "go to the live line as speech".
  - The Bridge's `awaitingContext` mark cannot fix this: the machine's `awaited` decides between
    speaking and adding.
- Fix: track the fetch in the machine apart from `awaited`, for example
  `awaitingFetch: SessionID?`, with its own event that returns `.speak` effects. A Claude result
  and a fetch answer must not end each other's wait.

**R2. Fetch answers delivered through `.deliver` enter `unheard` and behave as unheard results.**

- Where: plan Task 4 Step 3 ("sends `.deliver` for its lines"); CallMachine.swift:163-164 and
  `hangUp()` at `:241` (`phase == .live && !pending.isEmpty ? [.chime] : []`); Bridge.swift:84 and
  :269; `ResultNotice`.
- Problem: `[CONTEXT]` and `[LAST]` would then:
  - count in the band's unheard total;
  - make `hangUp()` chime;
  - post "X has a new result — speak to hear it";
  - be re-added to every reopened line by `.connected` (`pending.map { .addContext($0) }`,
    `:153`), next to the copy `initialItems` already seeds.
- A line leaves `unheard` only when `says()` finds its distinctive words in a reply. The voice is
  told to read `[LAST]` out only when asked, so `[LAST]` will usually stay until the next handoff
  withdraws it.
- Fix: speak a fetch's answer through the dedicated path of R1, which never touches `unheard`.

### Important

**R3. Task 4's closed-line case depends on PR #27, but only Task 7 is gated on it.**

- Where: plan Review Focus bullet 2; Task 4 test `aFetchWhileTheLineIsClosedIsSaidWhenItOpens`;
  Step 3 ("a closed line holds them as an answer under PR #27").
- Problem: on `dev`, `hangUp()` clears `awaited` (CallMachine.swift:233-241), a delivery while
  listening only chimes (`:146-148`), and `.connected` adds pending lines with `addContext`, not
  `speak` (`:153`). So the test's "the context is spoken" fails on `dev`. Under PR #27 it fails
  too, because `.connected` still adds those lines quietly.
- The test cannot be set up as written. With a fetch awaited, silence only sets `isSilenceDue`
  (`:200-203`), and the 60 s fetch timer fires before the 120 s window ends. Only a remote close
  from codex closes that line.
- PR #27 sets `machine.target` only inside `say()`, so a `.deliver` sent straight from
  `Bridge.context` must set it as well.
- Fix: gate Task 4, or at least this test, on PR #27. Describe the case as a remote close, and
  decide whether the reopened line speaks the answer or adds it.

**R4. `anAwaitedContextIsSpokenAndEndsTheWait` asserts something the machine contradicts.**

- Where: plan Task 4 Step 1 ("advance 120 s with the session polling: still live").
- Problem: once the wait ends, `.deliver` arms the 20 s silence timer. `(.live, .silenceElapsed)`
  with `awaited` empty then closes the line (CallMachine.swift:200-205). See also the existing
  `anUnansweredHandoffClosesTheLineAfterTheWindow`.
- Fix: assert that the line closes after about 20 s of silence, not that the window holds it.

**R5. The `fetchAnsweredEndsTheWait` row cannot observe what its name says.**

- Where: plan Task 4 Step 1; `app/Tests/BridgeCoreTests/CallMachineTests.swift:6-13`.
- Problem: `Transition` compares only `phase`, `effects` and `pending`, never `awaited`. Once the
  case exists, an unhandled `default: return []` passes the row ("emits nothing") without
  clearing anything, so the test cannot fail.
- Fix: follow the event with `.silenceElapsed`, which closes the line only if the wait ended, or
  write a separate `@Test` on `machine.awaited`. This goes away with R1's fix.

**R6. Task 2 edits the wrong function for the empty session, and breaks three existing tests.**

- Where: plan Task 2 Step 3 ("posts `''` … instead of returning `'empty'` before posting") and
  Step 4 ("existing context tests too"); `plugin/hooks/register.tsx:288`, `:309`, `:362`.
- Problem:
  - With no turns, `deliverContext` returns `'empty'` at `if (!(await hasTurns($))) return
    'empty'` (`:288`), before `writeAndPost` runs. Changing `writeAndPost` alone cannot make
    `anEmptySessionPostsAnEmptySummary` pass.
  - `aNewSessionHasNoContextToLoad` (`plugin/tests/context.test.tsx:51-61`) expects
    `take('context')` to be `[]`, and `onlyNothingToForkIsNothingToSummarise` (`:180`) expects no
    post.
  - `liveContextAsksTheModelEachTime` needs the `'empty'` outcome for "Nothing to summarise yet."
    (`:362`).
- Fix: name line 288, keep the `'empty'` outcome after posting, and list the three tests to
  rewrite. Or see S9 and post nothing.

**R7. `theLastReplySurvivesAReload` passes without `$.store`.**

- Where: plan Task 2 Step 1.
- Problem: calling `$.session.start` again within one test keeps the module's variables, so an
  in-memory `lastReply` passes the test.
- Fix: seed the store as `reloadResumesPolling` does
  (`plugin/tests/lifecycle.test.tsx:14-21`), with `fakeWorld(on, { 'joined:ID': …, 'last:ID': … })`
  and one `session.start`. Or drop the store key and this test (S5).

**R8. Task 5 breaks registry and bridge tests the plan does not list.**

- Where: plan Task 5 Test list; `app/Sources/BridgeCore/Sessions/SessionRegistry.swift:106`
  (`if target == nil { retarget(body.sessionId) }`).
- Problem:
  - Once `retarget` always sets `wantsContext`, the first join owes a context poll. That breaks
    SessionRegistryTests:109 (`oneRequestInFlightPerSession`), :146 and :162, and BridgeTests:293
    (`poll(a) == nil` after `a` joined first).
  - "Replacing the two autoContext rows" is wrong: there is one test,
    `becomingTargetWithAutoContextAsksForContext` (SessionRegistryTests.swift:250-264).
  - SettingsTests lines 12, 20, 27, 39 and 59 build `Settings(…, autoContext: …)` and must be
    edited.
- Fix: list these tests, or adopt S2, which leaves `retarget` alone.

**R9. Two of Task 4's and Task 5's "failing tests" already pass today.**

- Where: plan Task 5 `SettingsTests` row; Task 4 `aFetchWithNoTargetFailsAtOnce`.
- Problem:
  - An old file with `"autoContext":true` already decodes in `anOlderSettingsFileLeavesUpdateChecksUnset`
    (SettingsTests.swift:69).
  - With no target, `route` already returns nil, and `realtimeEvent` already delivers
    `[FAILED] LiveBridge: no Claude Code session is joined.` (Bridge.swift:355-359).
- Fix: label both as regression guards rather than red-then-green tests, or drop them (S13).

**R10. Task 7's premise does not exist on the event, and the change widens past a switch.**

- Where: plan Task 7; spec "A switch says what was held"; CallMachine.swift:151-153.
- Problem:
  - `CallEvent.connected` carries no session, so the machine cannot know it has "a line on
    `s2`". PR #27's `machine.target` is set only in `say()`.
  - Speaking the target's pending lines at `.connected` changes every reopen. That includes a line
    the owner's own speech opens: `isSoundOn` is true there, and the machine's rule is to hold
    lines and say them after the grace period.
  - "After its context" cannot be met: the new target's context usually comes after `.connected`.
- Fix: see S6.

**R11. Task 2 conflicts with PR #24 in the same hook, and misses the early-return path.**

- Where: plan Task 2 Step 3; `plugin/hooks/register.tsx:473-485`; PR #24's `turn.step`.
- Problem:
  - While a question is open, the plan sends the previous turn's final `e.answer` plus
    `askedText`. With PR #24, the step text Claude wrote when it asked is the reply that belongs
    to the question. The plan would pair a stale answer with a new question.
  - Both PRs edit the same `AskUserQuestion` hook.
  - The plan sets `openQuestion` "before the hook's early return". That return
    (`tracker.running === null`, the typed turns the plan wants included) has no `finally`, so
    nothing would clear it.
- Fix: order the plan after PR #24 and use its step text while a question is open. Wrap the
  early-return path in its own `try`/`finally`.

**R12. A summary failure loses `[LAST]` and costs a silent, billed minute.**

- Where: spec Failures ("No summary within 60 s"); `plugin/hooks/register.tsx:303-314`.
- Problem: on an API error, `writeAndPost` catches and returns `'failed'` and posts nothing. The
  app does not learn of the failure. It keeps the line open for its full 60 s, although the
  failure was known within about a second, and `[LAST]` needs no model call (spec "What a fetch
  returns").
- Fix: post `last` even when the summary fails, with a way to say "summary failed" rather than
  "empty". Or accept the wait and document it.

**R13. `last` is not cut before it crosses the socket.**

- Where: plan Task 2 Step 3; `plugin/hooks/link.ts:112`;
  `app/Sources/BridgeCore/Server/UnixHTTPServer.swift:21` (`maxBodyBytes = 131_072`).
- Problem: Claude's last reply can be tens of kilobytes of code. A body over the limit gets a 413
  and the whole post fails, summary included. The mod logs NO_SUMMARY, and the voice says "context
  not available" after 60 s. Answers are already cut, as `clip(post.text, ANSWER_LIMIT)`
  (register.tsx:458).
- Fix: clip `last` in the mod, and say so in the spec. Cut after the last whole line and well
  above the app's 2,000 characters, so the mod's cut cannot split a PEM block that the app's
  redactor needs whole (X2).

**R14. Context that arrives while the line is connecting is lost for that line.**

- Where: `app/Sources/BridgeCore/Bridge.swift:476` (`if machine.phase == .live, lineSession == …`).
- Problem: Task 5 asks for context on every `openLine`, so the answer routinely arrives while the
  line is still `.connecting`, and it is dropped from that line. Nothing is lost when the summary
  is cached and unchanged; a changed one is lost until the next reopen.
- Fix: queue the context line until `.connected`, or let the machine take it as a non-answering
  pending line that `.connected` adds.

**R15. The by-hand check cannot run as written.**

- Where: plan Task 8 Step 3; spec Testing; `scripts/smoke.sh:9`, `:24`;
  `app/Tests/Smoke/fake-session.mjs:118-119`.
- Problem: `smoke.sh` hard-codes the utterance "Please list the files in this folder." and passes
  on "exactly one handoff". The fake session answers context without `last`. No task changes
  either file.
- Fix: add a step that gives `smoke.sh` a "look at the chat" case, whose pass condition is a
  `refresh context` handoff that never reaches the fake session's queue, and teach
  `fake-session.mjs` to send `last`.

### Minor

- **Task 1 Step 2.** If Step 1 adds `last: optional(S)` to `SHAPES`, `npm run test:unit` passes,
  because Node strips types. Only `typecheck:pure` fails, through the
  `fields<Wire.ContextBody>` key mismatch, so the step should name that command. Also, the
  context shape is at `plugin/tests/unit/wire.unit.ts:54`; line 59 is `'target'`.
- **Spec Wire contradicts itself.** "`context.json` with `last`, and the existing fixture without
  it". The plan's separate `context-last.json` follows the `activity` / `activity-question`
  precedent, so the spec should be fixed to match.
- **Task 6 does not compile as written.** `VoicePrompt.composed(owner: nil)` passes nil, but
  `owner` is a `String` (VoicePrompt.swift:10). Use `""`.
- **`ASKED` is not exported.** Task 2's tests need it, but it is a non-exported `const` in
  `plugin/tests/roundtrip.test.tsx:95`. Move it or export it.
- **The brief's normaliser is too narrow.** The voice may wrap the brief in backticks or quotes,
  as the prompt shows it, or translate it, since the prompt says to answer in the owner's
  language. The prompt should say "exactly, in English", and the normaliser should also strip
  surrounding quotes and backticks.
- **`[LAST]` is sent two contradictory ways.** On a fetch it goes in by `appendSpeech`, which
  makes it speakable, while the prompt says to read it out only when asked. State which is
  meant.
- **`/clear`** must also reset the in-memory `lastReply`, not only delete the store key
  (register.tsx:179-180).
- **"Nothing appears in Claude Code" is not quite true.** The band still shows "Loading context…"
  during a fetch (register.tsx:290). Say so in the spec, or skip the band's note for a fetch.
- **`aFetchNobodyAnswersFailsAfterAMinute`** must poll the session every second, as the 120 s test
  does, or the session expires after 5 s and the test measures something else.
- **Spec bullets with no test.**
  - "Two fetches at once join" has no test.
  - "An empty summary with a `last` gives `[LAST]` alone" has no test.
  - "A fetch with no new turn makes no model call" is covered only by the existing
    `startAgainWithNoNewTurnAsksTheModelForNothing`.
- **Commit order leaves a broken step.** Between Task 2's commit (the mod posts `''`) and Task 3's
  (the app ignores an empty summary), the app stores an empty `[CONTEXT] label: ` line over the
  kept one. Swap or merge the two tasks.

---

## 2. Reuse, simplification, efficiency, altitude (`simplify`)

### Important

**S1. The fetch's wait is a second mechanism, beside the two that exist.**

- Where: plan Task 4 Interfaces and Step 3 (`ContextFetch.timeoutSeconds`, `awaitingContext =
  (session, deadline)`, its timer, `.fetchAnswered`).
- Already in the tree:
  - `ContextLoads` (`app/Sources/BridgeCore/Menu/ContextLoads.swift:27-47`) is the pure,
    per-session "pending from the ask until `/v1/context` or 60 s".
  - The registry already times out stuck requests in `sweep()`
    (SessionRegistry.swift:213-220), which the bridge runs every second (Bridge.swift:71-75,
    :481-484).
  - The mod already gives up after its own 60 s (register.tsx:27). The app's timer starts first,
    so it always fires first.
  - The Bridge mark also needs clearing by hand on timeout, arrival, `/clear` rename and leave
    (X4).
- Fix: keep the fetch's deadline in `SessionRegistry` beside `wantsContext`
  (SessionRegistry.swift:62, :161). Have `sweep()` return a `.failed` delivery, "context not
  available", once it passes. Reuse `ContextLoads.timeout` as the one constant. `.fetchAnswered`
  then has no job; the machine needs only R1's fetch field.

**S2. Context is asked for at three call sites when `openLine` covers them all.**

- Where: spec "Asking at the right moments"; plan Task 5 (`perform` 100-110, `openLine` 291,
  `retarget` 267); register.tsx:369-372 (`startHere` calls `contextAsked` itself).
- Problem:
  - `openLine` (Bridge.swift:291-295) is the one place a line binds to a session. A Start's first
    line, every reopened line, and every in-call retarget pass through it: a retarget during a
    call closes the line by `followTarget` → `.conversationChanged`, and the next speech reopens
    it.
  - Asking in `retarget` as well means a summary model call while no call is running. That
    happens on every app restart's first join, on menu clicks, and when a target leaves and
    `drop` retargets (SessionRegistry.swift:274).
  - README.md:242 gives exactly that cost as the reason the setting is off by default.
  - A band Start already asks three times: from `startHere`, from `/v1/target` → `retarget`, and
    from `perform(.start)`. The join absorbs it, but that is three code paths for one rule.
- Fix: ask in `openLine`, and optionally once at `launch` for a head start. Leave `retarget` as it
  is while still removing the setting, and drop `void contextAsked($)` from `startHere`. This also
  removes R8.

**S3. A reopened line costs a model call after almost every voice turn, and sends its context
twice.**

- Where: spec Decisions "When a summary is written"; plan Task 5 (`openLine`), Task 3
  (`aLiveLineGetsTheLastReplyQuietly`); CallMachine.swift:105 (`silenceSeconds = 20`);
  register.tsx:254 (`staleSummary` on every main-loop `turn.complete`); Bridge.swift:468-479.
- Problem:
  - The line closes after 20 s of silence and reopens at the next speech. A voice turn usually
    completes between the two, so with about a dozen handoffs an hour that is about a dozen
    transcript forks an hour on the owner's Claude plan, against about one today. That is the
    "summary after every turn" the spec rules out, done lazily. It is also mostly redundant,
    because the voice has already heard that turn's `[RESULT]`.
  - Even with a cached summary, the answer arrives about a second after `openLine` has seeded the
    stored `[CONTEXT]`. `Bridge.context` then appends the same text again with `addContext`,
    rewrites continuity.json, and flashes the band's loading and sent states. With `[LAST]` that
    is up to about 3,500 characters (about 900 realtime input tokens) more on every reopen.
- Fix:
  - On a reopen, ask only when a turn the voice did not hear has completed since the last context.
    The app already sees `activity idle` for every main-loop turn (register.tsx:465), and knows
    which of them answered a voice request.
  - In `Bridge.context`, skip `addContext` and `save` when the new line equals the stored one.
  - The efficiency counts are estimates from the timers, not measurements.

**S4. `[LAST]` repeats what the conversation already holds after a voice turn.**

- Where: spec Design/Mod; plan Task 2 and Task 3 (`initialItems`); Bridge.swift:385-388 (`say`
  records every line as a `.claude` line), :448-451 (`[ASKING]`); Continuity.swift:13 (the
  8,192-token budget).
- Problem: for a voice turn, Claude's reply is already kept as the `[RESULT]` line and its open
  question as `[ASKING]`. Seeding `[LAST]` repeats up to 2,000 characters on every reopen, and
  pushes older lines out of codex's budget.
- Fix: send `last` only for a turn whose answer did not go to the voice. `tracker.turnCompleted`
  already tells the two kinds apart, since it returns null for a typed turn. Whether typed turns
  should go at all is X1.

**S5. Task 2 adds a store key the existing record already covers.**

- Where: plan Task 2 Step 3 (`last:${sessionId}` in `$.store`); register.tsx:38-39, :59-63, :76-78,
  :162, :180, :242.
- Problem:
  - A second key needs its own delete at each of the three places the join key is deleted, and a
    second store write on every turn.
  - The summary cache is kept in memory on purpose (:59-63). The plan does not say why a verbatim
    reply may be stored when a summary is not.
  - After a reload, a new summary covers the last turn anyway.
- Fix: put the clipped `last` in the record `save()` already writes under the join key, so the
  existing deletes cover it, and clear it in `staleSummary()` on `/clear`. Or keep it in memory
  like `summary`, which also removes `theLastReplySurvivesAReload` (R7) and its Review Focus
  bullet.

**S6. Task 7 is outside this goal, and the fix belongs one level down.**

- Where: spec "A switch says what was held"; plan Task 7; PR #27.
- Problem:
  - The goal is "context at once, refresh on request". Task 7 is a separate `.connected`
    behaviour, blocked on an unmerged PR, and it keeps the plan from being finished.
  - As a special case for switches, it sits on PR #27's `machine.target` side channel, which goes
    stale between deliveries (R10).
- Fix: move it, with its spec section, to a spec of its own that lands with PR #27. The deeper
  change there is to keep unheard lines per session:
  - `.connected(SessionID?)` carries `lineSession`;
  - every connect speaks that session's held answers, held until the grace period when the
    owner is speaking;
  - other sessions' lines stay pending and chime;
  - the same parameter replaces PR #27's `machine.target`.

**S7. The fetch is recognised in the wrong layer.**

- Where: spec "Taking the fetch"; plan Task 4 Step 3 ("In `route`, before `enqueue`");
  `app/Sources/BridgeCore/Codex/RealtimeSession.swift:327` (`handoff` parsing);
  VoicePrompt.swift:43-46.
- Problem:
  - `route` exists to choose a session for a Claude request. Matching a magic brief inside it
    tangles the fetch with `questionRoute` and `withdraw` (X3).
  - The prompt tells the voice to write every handoff as a self-contained brief with a kind and a
    goal, which works against an exact short phrase.
- Fix: classify the handoff where codex's item is parsed, as its own `RealtimeEvent` case
  (`.contextFetch`). `realtimeEvent` then handles it beside `.handoff`, and `route` stays as it
  is. If the brief is ever made more robust, a tag-like prefix such as `[BRIDGE] context` fits
  the `[TAG]` convention the voice already reads, but the exact phrase is acceptable for a first
  cut.

### Minor

- **S8. `ContextFetch.swift` and `ContextFetchTests` are a file pair for one string and one
  normaliser.**
  - `CallMachine.words` (CallMachine.swift:274-277, now `private`) already folds case and
    diacritics and splits on non-letters. `words(brief) == ["refresh", "context"]` does the job.
  - Put the constant beside the parser of S7, and let VoicePrompt interpolate it.
  - The near-miss cases fit in the bridge or realtime test.
- **S9. The empty session is special-cased in three places.** The mod posts `''` (Task 2), the
  app keeps the old context (Task 3), and the app speaks its own sentence (Task 4). Make `summary`
  optional on the wire, so that absent means none, the same way Task 1 makes `last` optional. Or
  answer a fetch on an empty session with the existing "context not available". Either removes
  one sentence and one test, and with it the `'empty'` change of R6.
- **S10. `.fetchAnswered`** exists only because `.context` is not an answering `Kind`
  (CallMachine.swift:20). It disappears with R1's dedicated path.
- **S11. The `.fetch` speaker is a new persisted `Codable` case.** An older app (a downgrade)
  then fails to decode continuity.json and starts with an empty conversation (Bridge.swift:63-66).
  Either decode unknown speakers leniently, or record nothing: the spoken answer is recorded
  anyway. The spec's menu line `Context requested` would need the first option.
- **S12. Work that belongs together is split across tasks.**
  - Task 1's `link.context` change is not tested by Task 1's wire tests; move it to Task 2.
  - Tasks 3 and 4 both reshape `Bridge.context`, and the tuple return exists only because of that
    split; merge them.
  - Task 5's README and translation edits and Task 8's are one pass over the same seven files.
- **S13. Some tests repeat existing ones.**
  - The SettingsTests `autoContext:true` row repeats `anUnreadableOlderOrNewerFileReads`
    (SettingsTests.swift:52-63), which already decodes a file with a removed key.
  - `aFetchWithNoTargetFailsAtOnce` already passes (R9).
- **S14. Task 6's test is a drift guard, not a failing test.** It checks that the prompt contains
  a constant. Once the prompt interpolates the constant, the test cannot fail, and it sits close
  to AGENTS.md's "tests do not check prompt wording". Fold the prompt edit into the fetch task and
  drop the test.
- **S15. Folding `[LAST]` into `[CONTEXT]` would be simpler, but is not recommended.** One line
  would be simpler: one `Conversation.context`, one delivery, no new `Kind` or tuple. It would,
  however, put the verbatim reply into every seeded line, which X1 argues against. Keep the line
  separate only if X1's "fetch answer only" is adopted, since that is where the separate line
  earns its place.
- **S16. Dropping the fetch for a first cut is possible, but it overturns an approved decision.**
  With context at every line open and the prompt's rule on "the chat", the root symptom is mostly
  fixed without the fetch. Posting `last` on every `turn.complete` would remove Task 4 entirely.
  But it sends every typed reply to OpenAI as it happens, which is worse for X1, and the owner
  approved the fetch. It is recorded for the owner to weigh, not recommended.
- **S17. The plan has no waves.** Its eight tasks would run as eight dispatches. A cut by shared
  context:
  - W1: Task 1, the wire on both sides.
  - W2, run in parallel because they share no file:
    - the mod (Task 2);
    - the app (Tasks 3, 4 and 6 merged, then Task 5, in series because they share
      Bridge.swift).
  - W3: Task 8.
  - Task 7 moves out (S6).
  That is about four dispatches instead of eight, with the wave-dispatch rule stated in the plan's
  header.

---

## 3. Security (`security-review`)

Each candidate from the security seat was checked against the code before it was kept. One
candidate was dropped as too speculative: the claim that the mod's cut defeats PEM redaction. It
is folded into R13's fix instead.

### Important

**X1. Claude's verbatim replies from typed turns now leave the Mac, unasked, and there is no way
to turn that off.**

- Where:
  - spec Decisions "What a fetch returns" and Design/Mod ("the final text of the last main-loop
    turn");
  - plan Task 2 (`lastReply` from any main-loop `e.answer`; `openQuestion` set "before the hook's
    early return", so typed turns too), Task 3 (`initialItems` seeds `[LAST]`; a live line gets
    it by `appendText`) and Task 5 (Auto-context removed).
- Today:
  - A typed turn's answer is kept from the voice by design: "A turn with no origin seen is
    treated as typed: its answer never reaches the voice" (register.tsx:442), and "its answer is
    never sent to the voice" (`plugin/hooks/turns.ts:22-25`).
  - The architecture says a typed turn's questions "stay in Claude Code"
    (`docs/architecture/overview.md:93-96`).
  - Context leaves only when the owner presses the band's Start or Load context, because
    Auto-context is off by default (Settings.swift:21, :35).
- After the change:
  - Every Start, reopened line and target change sends Claude's last reply verbatim, typed turns
    and their AskUserQuestion options included.
  - It goes to OpenAI with the owner's rank (`appendText` sends `"role": "user"`,
    RealtimeSession.swift:218-219).
  - It is stored in continuity.json and seeded into every later line with that session.
  - "Used and read out only when the owner asks" is a model instruction: by then the text has
    already left the Mac.
- It also widens injection. Today the path into the voice carries results of voice turns, shaped
  by `forVoice`, and a summary a model wrote. The change adds the verbatim output of typed turns,
  kept and seeded.
- Example: the owner types "summarise this issue" about an attacker's GitHub issue, then picks
  that session as the target in the menu. Claude's reply, carrying the injected text, is appended
  to the line and seeded into every later call. It can steer the voice into a handoff about that
  content without the owner saying a word of it. SECURITY.md's residual risk already allows this
  for summaries; this makes it automatic and verbatim.
- Fix:
  - Send `[LAST]` only in answer to a `refresh context` fetch, which the owner's own question
    triggers. Speak it, and neither seed it, store it, nor append it quietly.
  - Decide explicitly whether a typed turn's reply may go at all, and say so in the spec.
  - If automatic context stays, keep an off switch for it. The setting being removed is today's
    only opt-out.

**X2. `[LAST]` would keep code blocks and tables, against README's promise.**

- Where: spec "Answering it" ("redacted and cut by `AnswerShaper`"); plan Task 3;
  `app/Sources/BridgeCore/Text/AnswerShaper.swift:8-26` (`forVoice`), `:32-40` (`line`);
  Bridge.swift:470.
- Problem:
  - `Bridge.context` builds its line with `AnswerShaper.line`, which only flattens, redacts and
    cuts. Only `forVoice` removes fenced code and table rows.
  - README Privacy promises results with "code blocks and tables removed".
  - Code blocks are where `.env` files and config dumps appear, and the redactor is a pattern list
    that is a convenience, not a control (SECURITY.md "What session text can do").
  - Not verified in full: the security seat reports that Redaction.swift's rules miss some token
    shapes (`sk_live_…`, `AIza…`, `npm_…`, `glpat-…`). This was not re-checked here, and it
    predates the change.
  - Redaction runs before the cut (`cap(Redaction.redact(flat(body)), …)`, AnswerShaper.swift:37),
    so a secret that straddles 2,000 characters is still redacted whole.
- Fix: shape `[LAST]` through `forVoice`'s prose step, giving `forVoice` a kind or pulling that
  step out, and add a test with a fenced `.env` block. `cap()` keeps the beginning while a reply's
  conclusion is usually at its end, so consider keeping the end instead.

**X3. A fetch inside `route` would eat the question's route, and send the owner's next reply to
another session.**

- Where: plan Task 4 Step 3 ("In `route`, before `enqueue`"); Bridge.swift:413-421.
- Problem: `route` begins `let route = questionRoute; questionRoute = nil`, then tries
  `[route, target]` and calls `machine.withdraw { $0.session == id }`. A check placed inside that
  loop does three things:
  - it fetches session A, the one that asked the question, not the target the spec names;
  - it clears the route, so the owner's spoken reply to A ("yes, delete them") goes to target B as
    a new prompt, and B may run in a more permissive mode (SECURITY.md "A handoff can hop between
    sessions");
  - it withdraws A's unheard results.
- Claude Code's permission prompt still gates whatever B then does, so this is misrouting, not a
  bypass.
- Fix: recognise the fetch before `route` (S7). Always fetch `registry.target`, leave
  `questionRoute` and `withdraw` alone, and test it with a question open.

**X4. A fetch's answer can be spoken into another session's line.**

- Where: plan Review Focus bullet 2 (the fetch survives a closed line); Task 4 Step 3 (nothing
  clears the mark except the answer and the timeout); CallMachine.swift:153; Bridge.swift:299
  ("only the session's own conversation, context and open tasks: never another session's").
- Problem:
  - The awaited mark lives on across a target change, Stop, a closed line, and the session
    leaving.
  - Session A's context and verbatim `[LAST]` then arrive by `.deliver` into `pending`.
  - `.connected` adds every pending line to the new line, whatever its session
    (`pending.map { .addContext($0) }`), so A's text enters B's line. That breaks the rule
    `openLine` states for itself.
  - A stale mark also makes the next routine context, from Task 5, be spoken unprompted.
  - A timer that fires after the session left delivers `[FAILED]` under a label that is gone.
  - A second fetch needs a generation counter, so the first timer does not fail it.
- Fix: clear the mark on Stop, on `.conversationChanged`, on a retarget and when the session
  leaves. Treat context as a fetch's answer only while `lineSession == body.sessionId`. With S1,
  the registry already forgets a session that leaves.

**X5. Several documents become false, and two of them are in no task.**

- Where: plan Task 5 and Task 8 file lists. AGENTS.md: "Docs never claim more than the code
  enforces … fix the docs in the same change as the code".
- These become false or incomplete:
  - `SECURITY.md:107` says a process can post "a `[CONTEXT]` line"; now a `[LAST]` too, which is
    spoken.
  - `SECURITY.md:122-123` lists the tagged lines, without `[LAST]`.
  - `SECURITY.md:141-147`, "A loaded context persists", names the setting that goes and
    describes when context loads.
  - SECURITY.md's "Residual risk" says nothing about typed-turn output now reaching the voice.
  - README.md's Privacy list (:294-317) has no last reply. It should add a line like "Claude's
    last reply, as one line of at most 2,000 characters …", with when it is sent.
  - `README.md:242` and its six translations describe the setting.
  - `docs/architecture/overview.md:93-96` says typed turns and their questions stay in Claude
    Code.
  - Comments: `plugin/hooks/turns.ts:22-25`, `plugin/hooks/register.tsx:442`,
    `plugin/hooks/wire.ts:36-38` ("is the app's own setting"), and
    `plugin/tests/context.test.tsx:148`.
- SECURITY.md is in neither Task 5 nor Task 8.
- Fix: add SECURITY.md and README Privacy to the task that changes the behaviour, not to the final
  docs task, so that no commit leaves them false. Then list the comments.

### Minor

- **X6. A typed turn's question cannot be answered by voice, and the voice is not told so.**
  `[LAST]` would read out the options of a typed turn's open AskUserQuestion. The spoken answer
  cannot answer that dialog: `answerQuestion` is set only in a voice turn
  (register.tsx:474-476), and `isAsking` is false (SessionRegistry.swift:130). So the reply
  becomes a queued prompt behind the open dialog. This is safe, but the owner believes they
  answered. The prompt or the `[LAST]` text should say that the question waits at the keyboard.

### Checked and found safe

- **The permission prompt.** The plan adds no path that answers anything.
  - AskUserQuestion is answered only through `answerQuestion`, set only in a voice turn.
  - Capturing `openQuestion` does not change that.
  - `classic.PermissionRequest` only reports, and leaves AskUserQuestion out
    (register.tsx:487-495).
  - The app answers nothing on Claude's behalf: a fetch's answer is the mod's own summary and
    reply, labelled with the session.
  - "LiveBridge never answers a Claude Code permission prompt" holds.
- **The diversion fails safe.** A `refresh context` brief that is swallowed runs nothing, and a
  near miss goes to Claude as an ordinary handoff, under the permission prompt.
- **Tag forgery.** `AnswerShaper.flat` turns every bracket into a parenthesis and every line break
  into a space (AnswerShaper.swift:43-55), so a `last` holding `\n[RESULT] other: …` stays inside
  its own line. As SECURITY.md says, this is not a control.
- **Socket identity.** `/v1/context`'s `sessionId` is not tied to the connection, so any process
  of the user's can post a `last` for any session, and it would be spoken as a fetch's answer.
  This is the documented trust model (the folder's `0700` mode, SECURITY.md "Who can drive the
  bridge"), so it is no new gap; `last` adds 2,000 spoken characters to it.
- **Logging.** The app logs only the call phase and whether there is a problem (App.swift:385-386),
  so neither `last` nor the summary reaches a log.

---

## Counts

| Source                              | Critical | Important | Minor |
| ----------------------------------- | -------: | --------: | ----: |
| `superpowers:requesting-code-review` |        2 |        13 |    11 |
| `simplify`                          |        0 |         7 |    10 |
| `security-review`                   |        0 |         5 |     1 |
| **Total**                           |    **2** |    **25** |  **22** |
