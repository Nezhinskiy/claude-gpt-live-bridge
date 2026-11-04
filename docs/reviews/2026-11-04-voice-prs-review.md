# Review: PRs #24, #27 and #28 (the voice path), before merge into `dev`

Reviewed 2026-11-04. Nothing on the PR branches was changed or pushed.

| PR | Branch | Head | Base read against |
|---|---|---|---|
| [#24](https://github.com/getLiveBridge/LiveBridge/pull/24) | `fix/question-carries-turn-text` | `0ca5705` | `e853430` (merge base; `origin/dev` is now `a680968`) |
| [#27](https://github.com/getLiveBridge/LiveBridge/pull/27) | `claude/voice-speaks-first` | `06bf205` | `origin/dev` `a680968` |
| [#28](https://github.com/getLiveBridge/LiveBridge/pull/28) | `fix/voice-promises-without-handoff` | `4325625` | `origin/dev` `a680968` |

Each PR went through three skills:

1. `superpowers:requesting-code-review`: one reviewer per PR, given only the diff and its
   requirements. Tagged **CR** below.
2. `simplify`: four angles (reuse, simplification, efficiency, altitude), each over all three
   diffs. Tagged **SIM**. Report-only here: no fix was applied.
3. `security-review`: one pass over all three diffs, with each candidate re-traced as the
   false-positive filter. Tagged **SEC**.

Line numbers are on each PR's head. Findings that several sources raised are listed once, under
the source that raised them first, with the others named. Every Important finding was checked
against the code by the coordinator; the ones a reviewer confirmed with a throwaway probe test
are marked so.

**Combined build.** The three heads, merged into a scratch copy of `origin/dev` in the order
#27, #28, #24, give three small textual conflicts (below). Resolved by keeping both sides,
`scripts/check.sh` exits 0: Swift 289 tests, mod unit 24, engine 54, both validations.

## Verdicts

| PR | Ready? | Why, in one line |
|---|---|---|
| #24 | With fixes | The bug is real and caught at the right hook, but the text travels on the wrong channel (a separate `[UPDATE]`), so it outlives its question and doubles the chime. |
| #27 | No | Two state bugs break the README's billing promise, the connect now blocks the mod's HTTP calls, and the README does not list every line that opens the microphone. |
| #28 | With fixes | The tick is the right response and sits at the right point, but the docs promise more than the code does (no tick while connecting), and the prompt rewording has no measured effect. |

## Architecture: elegant enough, and is anything redundant?

**#28 is elegant; #27 is not yet; #24 is close.**

- **#28** adds one effect where the machine already decides sounds. The bridge sends
  `.handedOff(session)` only after `registry.enqueue` accepted the request
  (`Bridge.swift:415-420`), so the tick marks exactly the event BR-001 needs, and the rule stays
  in the table test. The only redundancy is in the prompt and the docs (#28 SIM-2, SIM-3).
- **#27 keeps copies of facts that other components own.**
  - `machine.target` is a public copy of `registry.target`. `say` refreshes it before each
    delivery, so it is valid only for the instant after `say` sets it (#27 SIM-1).
  - `awaited` now outlives a hang-up. It has become a second record of the registry's open
    requests, and it needs `isWindowOpen` to stay apart from the window it used to mean.
  - The "settle the wait" rule is copied into two of the three `.deliver` branches. The third
    one, `.connecting`, missed it, and that gap is #27 CR-1.
  - A deeper form is short: the bridge decides "this line opens a closed line" from the
    registry and passes it with the event, `.deliver(line, opensLine: Bool)`. `awaited` can then
    go back to meaning "this line's handoffs". That deletes `target`, the persistence, the
    listening branch's bookkeeping, and the reason for `isWindowOpen`.
- **#24 special-cases one of the two places where a turn pauses for the owner.** A permission
  prompt loses its preceding text the same way. The text also travels as a separate `update`
  answer, a second mechanism next to the activity line it introduces. Carrying the text inside
  the `[ASKING]` line (and the `[APPROVAL]` line) is one rule with one lifetime (#24 SIM-1).

Redundancy across the PRs:

- The overview, the README and BR-001 all restate the tick's rationale (#28 SIM-3).
- "1 of 4" appears three times for #27 (#27 SIM-5).
- The prompt now says "you cannot look yourself" twice (#28 SIM-2).

---

## PR #24: what Claude wrote before its question reaches the voice

### requesting-code-review (CR)

The reviewer ran `claude plugin test plugin` on the head: 51 pass. What holds:

- **Order.** The update reaches the app before the `[ASKING]` activity. Both posts are awaited
  in turn, and the app answers only after `registry.complete` and `deliver` have run.
- **The request stays open.** `SessionRegistry.complete` keeps an `update` from closing it, and
  `VoiceLine.Kind.answers` is false for `.update`.
- **Failures are safe.** `link.answer` returns null or false and never throws, so the question
  still goes out.
- **The main test checks behaviour.** `theTextBeforeClaudesQuestionGoesToTheVoiceFirst` fails
  when the post is disabled.

**CR-1. Important. Two of the diff's rules are untested.**
- In a scratch copy the reviewer removed the clear (`register.tsx:468`, `stepText = ''`) and the
  subagent filter (`:437`, `e.agentId === undefined`). All 51 tests still passed.
- AGENTS.md asks for one test per behaviour.
- Fix: a test where a second question after a step with no text posts no update, and a test
  where a subagent's step leaves the main loop's text alone.

**CR-2. Important. `aQuestionWithNoTextBeforeItGoesAlone` passes without the fix.**
- `plugin/tests/roundtrip.test.tsx:132-142`. `stepText` starts as `''`, so the test never
  exercises the overwrite. It also does not check that the activity still goes out.
- Fix: first a step with text and a tool use but no question, then an empty step and the
  question. Expect no update, and the `[ASKING]` activity.

**CR-3. Minor. The premise "`turn.complete` carries only the last text" is unverified.**
- The overview states it as fact (`overview.md:316-317`).
- If `turn.complete.answer` is instead the turn's last non-empty text, then a question that
  ends the turn says the same text twice: as the update, then as the result.
- Fix: confirm the engine's semantics. Or remember the posted text and skip an identical final
  answer, which is a rule for `TurnTracker` (SIM-3).

**CR-4. Minor. A step that is only code or a table sends a noise line.**
- `AnswerShaper.forVoice` turns such a step into "the answer is code or a table only; it is in
  the session". The voice would get that before every such question.
- Fix: skip the post when the shaped text has no prose. Taking SIM-1 makes this moot, because
  the question carries the text.

**CR-5. Minor. The hook's `.catch` would open a second dialog if the new await ever threw.**
- `register.tsx:462-480`. `answered = next(e)` has already run when the update is posted. A
  throw would reach a `.catch` that calls `next(e)` again.
- It cannot happen today, because `link.answer` does not throw. Still, this PR adds the first
  await before the race. Add a guard or a comment.

**CR-6. Minor. Docs.**
- `overview.md:317` is 125 columns wide; the reflow stopped at the new sentence.
- "goes just before it" promises an order that rests only on the await order.
- The "Later update" section and the wire table (`overview.md:119`) still describe `update`
  only as a background follow-up.

**CR-7. Minor. Test details.**
- `model()` returns `stopReason: 'tool_use'` with `toolUses: []`, which is inconsistent.
- `for await (const _ of stream)` leaves an unused variable.
- The first test reads `answer` and `activity` from separate queues, so it does not check the
  "update before activity" order that the docs describe.

The rebase onto current `dev` (one trivial conflict) is in the cross-PR section.

### simplify (SIM)

**SIM-1. Important. The text belongs inside the `[ASKING]` line, not in a separate `update`
answer.** Altitude and efficiency raised this; CR agreed.
- `plugin/hooks/register.tsx:471-472` posts `update`, then `activity('approval', askedText(...))`.
- Problems:
  - They are two lines with two lifetimes. An answer at the keyboard withdraws only
    `.approval` and `.asking` (`Bridge.swift:460`). The `[UPDATE]` stays unheard, chimes at
    hang-up, and is said on the next line, after its question is gone.
  - On a closed line (or a session that is not the target) one question chimes twice and posts
    two notifications. On a live line it gives two `speak`s.
  - It changes what `update` means. Today the overview's "Later update" section and the
    README (`README.md:307`) define it as a report after the request was answered. Now it also
    means a note before a question. With #27, an `update` from the awaited target opens a
    closed line, while #27's docs say "a later update" chimes.
  - The `[ASKING]` line waits for a second HTTP round trip.
- Fix: put the text in the activity's `question` string. It is a free string, so this needs no
  wire change. Put the question and options first and the preceding text after them, or cap
  the preceding text, so `AnswerShaper`'s 2,000-character cut never drops the options. The
  question is then withdrawn as one line.

**SIM-2. Important. A permission prompt pauses a turn the same way and still loses its text.**
Altitude raised this.
- `register.tsx:483-487` posts only "Claude is waiting for your approval".
- Text like "I'm going to delete build/ and re-run" before a permission prompt is the case where
  the owner most needs it. A later fix would add a second special case beside this one.
- Fix: one rule. Every report that pauses the turn for the owner carries the text of the step
  that paused it. `[APPROVAL]` then needs a text field on the activity body: a wire change,
  touching `Wire.swift`, `wire.ts` and `wire/fixtures/` together. If that is out of scope here,
  file it as a follow-up and say so in the PR.
- Do not send every step's text. The prompt keeps progress silent, and with #27 each update
  from the target would open a billed line.

**SIM-3. Minor. The rule lives in the wiring, not in `TurnTracker`.** Reuse raised this.
- `register.tsx:466-471` builds `{ id, status: 'update', text }` by hand. `TurnTracker`
  (`plugin/hooks/turns.ts:107`) already builds this shape for background turns. AGENTS.md
  keeps rules in the pure `hooks/*.ts` modules, which `turns.unit.ts` can test without the
  engine.
- Fix: keep the step text per turn in `TurnTracker`, and add a method that returns the line,
  or the text to fold into `[ASKING]` once SIM-1 is taken. `register.tsx` then only posts.
- `link.answer({ ...post, text: clip(post.text, ANSWER_LIMIT) })` now appears at lines 447
  and 471.

**SIM-4. Minor. The test's `model()` helper is a second engine fake.** Reuse raised this.
- `plugin/tests/roundtrip.test.tsx:99-112` fakes `turn.step` outside `fakeWorld`
  (`plugin/tests/fake-bridge.ts`). `fakeWorld` is where the other engine answers are faked
  (`turn.start`, `model.fork`, `tool.call`).
- Fix: add `on('turn.step', …)` to `fakeWorld`, reading a field such as `world.stepText`. Plan
  Task 2 will need a step in `context.test.tsx` too.

**SIM-5. Minor. The `turn.step` hook adds a generator layer to every model step.** Efficiency
raised this.
- `register.tsx:435-439`: `yield* next(e)` adds one await to every streamed item of every step,
  including subagent steps and sessions that never joined. The body itself is a string
  assignment.
- Fix, only if the hook API allows a plain function: return `next(e)` and read
  `stream.result`. Not verified against the engine's types. If only the generator form is
  allowed, this is fine as is.

No simplification finding on state: `stepText` duplicates nothing. The engine's `turn.complete`
carries only the last text, and `TurnTracker` holds only ids and origins. The reset at line 468
is needed: it stops a second question in the same step from posting the text again.

### security-review (SEC)

No High or Medium finding. Traced:

- The text is sent only for the main loop (`agentId === undefined`).
- It is sent only during a voice turn (`tracker.running !== null`).
- It is always the asking step's own text, because `turn.step` overwrites `stepText` before the
  tool call.
- It is clipped to 32,000 characters, then redacted and cut to 2,000 by `AnswerShaper`.

**SEC-1. Minor (Low, confidence 8). The README's privacy list no longer describes what is
sent.**
- `README.md:307` defines an update as "Claude's answer in a later turn started by a background
  task's notification". OpenAI now also gets Claude's text from the middle of a voice turn, the
  step that asks a question.
- Fix: widen that sentence in the README, and in its six translations. Taking SIM-1 makes it
  part of the `[ASKING]` line instead, which the README should then describe.

---

## PR #27: a result for a handed-off request opens the closed line

### requesting-code-review (CR)

**CR-1. Important. An answer that arrives while the line is `.connecting` never leaves
`awaited`, so every later update from that session opens a billed line.** SIM (reuse,
simplification, efficiency) and SEC raised it too. A reviewer confirmed it with two probe tests
on the head.
- Where: `app/Sources/BridgeCore/Call/CallMachine.swift:164-166`. `(.connecting, .deliver)`
  appends the line but does not do `if result.kind.answers { awaited.remove(session) }`. The
  `.listening` (`:158-159`) and `.live` (`:174-178`) branches do.
- Before this PR the gap was harmless, because `hangUp()` cleared `awaited`. Now the entry
  lasts until Stop.
- Reached two ways:
  - An `[APPROVAL]` reopens the line (an approval keeps the wait), and the result lands while
    the line connects.
  - The owner starts speaking as the result lands.
- Effect: every later `[UPDATE]` from that session opens the microphone line, billed, though
  the README and the ADR say an update chimes. On a live line those updates are `speak`-ed
  instead of added as context.
  - Probe: `closedWaiting + [deliver(approval), fromAlpha, .connected, said(…), .silenceElapsed]`
    leaves `awaited == {alpha}`, then `deliver(update)` gives `[.openRealtime]`, not `[.chime]`.
- Fix: settle the wait once for every `.deliver`, before the phase switch, or in one helper
  that all three branches call. Add a table row for each of the two paths.

**CR-2. Important. Erasing the target's conversation does not end the wait. The reopened line
is then seeded with nothing and most likely stays silent.**
- Where: `app/Sources/BridgeCore/Bridge.swift:165-169` (`newConversation`). It sends
  `.conversationChanged` only while the line is open, and since commit 3 that event no longer
  touches `awaited`.
- After **New conversation** while the line is closed, the awaited answer opens a line with
  empty `initialItems`. That is item (b)'s case: a fresh session with no user turn does not
  speak.
- Result: at least 20 s billed, then the chime anyway. This contradicts the ADR decision
  ("seeded as usual with the target's conversation, which holds the request") and
  `overview.md:207-213`.
- Fix: a `CallMachine.stopAwaiting(_:)`, or an event of its own, called from
  `forgetConversation`, with a test. It must be separate from `conversationChanged`, which means
  "close the open line". Commit 2 joined the two, and commit 3 reverted both.

**CR-3. Important. A delivery that opens the line now holds the mod's HTTP request, and the
Claude Code hook, for the whole connect.**
- The chain: `/v1/answer` (`Bridge.swift:211-213`) and `/v1/activity`, then `deliver`, then
  `say` (`:385-389`), then `send`. `send` runs `.openRealtime`, which goes through
  `attempt { openLine() }` (`:119-124`, `:243`). `openLine` can launch codex, make the offer,
  open the voice and apply the answer.
- Before this PR a closed-line delivery only chimed.
- Effect: the mod awaits these posts before `next(e)`:
  - in `classic.PermissionRequest` (`plugin/hooks/register.tsx`), so the permission prompt's
    hook chain waits about 1 s, longer when codex relaunches or the connect fails slowly;
  - in `turn.complete`.
  The mod's fetch has no timeout. A sweep delivery (a timeout) also blocks the sweep loop.
- Fix: start an attempt opened by a delivery without awaiting it in the request path, keeping
  the `connecting` bookkeeping. Add a BridgeTests case with a slow fake `open` that asserts
  `/v1/activity` returns first.

**CR-4. Important. The README does not say that approval and question notices open the billed
microphone line.** SEC (Low, confidence 9) and SIM (efficiency) raised it too.
- `CallMachine.swift:156-163` opens the line for any line from the awaited target:
  `[APPROVAL]`, `[ASKING]`, `[UPDATE]`. The test row `anApprovalOpensTheLineAndKeepsTheWait`
  makes this intended.
- The README's billing section (`README.md:272`, `:283-288`) and its privacy list (`:304`) say
  only "Claude's answer" opens it. README is the one home for both promises. SECURITY.md hands
  the list to it.
- Also a product question for the owner. An `[APPROVAL]` cannot be acted on by voice:
  LiveBridge never answers a permission prompt. The approval keeps the wait, so a request with
  N permission prompts more than 20 s apart costs N+1 billed reopenings.
- Fix: either list every kind in the README, or reopen only for `kind.answers` and `.asking`
  and let `.approval` chime as before. The second is recommended.

**CR-5. Important. The README translations were not updated.**
- `README.{es,fr,hi,ru,uk,zh-CN}.md` still say a closed-line result only chimes (for example
  `README.hi.md:285`). They lack the new privacy clause and the new limitation.
- The recent user-facing changes (5b13eee, 8ca5b24, ce1207d) updated the translations in the
  same change.
- #28 has the same gap for the tick and its limitation; this is listed once here.

**CR-6. Minor. The PR body is stale.**
- It says the wait ends with a new target or an erased conversation, and that the bridge sends
  `conversationChanged` while the line is closed.
- Commit 3 (`06bf205`) reverted all three. At head the wait outlives a target change
  (`theWaitOutlivesATargetChange`), and erase does not end it (CR-2).
- The body is the review record and may become the squash message. Rewrite it.

**CR-7. Minor. `anApprovalOpensTheLineAndKeepsTheWait` does not test "keeps the wait".**
- `CallMachineTests.swift`: the row asserts only the effects of `.connected`, which would be the
  same if the approval had cleared `awaited`.
- Fix: split it. Add a row that delivers `fromAlpha` after the approval's line has closed and
  expects `[.openRealtime]`.
- No BridgeTests case covers an approval that opens the line through `activity()`.

**CR-8. Minor. The 2 s pre-roll is sent on a line nobody spoke on.**
- `theReopenedLineGetsTheResult` expects `.flushPreroll`. The audio page's `makeOffer` drains the
  pre-roll into the line.
- The README discloses it (`README.md:304`), so the docs are not wrong. But room audio from
  before the line existed serves no purpose there.
- Fix: skip the drain for a line a result opened, and drop that README clause.

**CR-9. Minor. A line from an awaited session that is not the target is now spoken on the
target's live line.**
- `CallMachine.swift:173-181`: `awaited` now persists, so Beta, awaited since an earlier line,
  takes the `speak` path on Alpha's live line instead of `addContext`.
- `overview.md:221-222` still says "a result for a session the open line is not waiting on is
  added as context".
- Either way is defensible, since the owner did hand Beta the request. Decide, then make the
  overview say it.

**CR-10. Minor. Docs drift.**
- `docs/adr/0001-platform-findings.md:366-367` (Consequences) still says a result after a
  hang-up is heard only once the owner speaks. Point it to the new decision, as line 390 does.
- `overview.md:211`: "about 5 to 8 s after connecting". Item (n) measured the *end* of the first
  segment ("so speech began earlier"). Say "within about 8 s".
- `overview.md:218`: "the chime and the notification name the session". A chime names nothing.
- `CallMachine.swift:71-72`: the type's first sentence still says "speech opens it". Name the
  second opener.
- `CHANGELOG.md` has no `[Unreleased]` entry for a user-visible billing and behaviour change.
- The ADR around line 389 and `overview.md:147-148` were edited without reflowing (over 100
  columns).

### simplify (SIM)

**SIM-1. Important. `machine.target` is a copy of `registry.target`, valid only right after
`say` sets it.** Raised by all four angles and by CR.
- Where: `CallMachine.swift:100-101` (`public var target`), `Bridge.swift:387`.
- Problems:
  - It is stale between deliveries. `setTarget`, `/v1/target` and `followTarget()` do not update
    it.
  - The pure machine gets an input outside its events, held only by a comment. The other
    `.deliver` (`Bridge.swift:357`) skips `say`; that is harmless only because its line has no
    session.
  - Every table row gains a `target:` argument.
  - `say` and `openLine` (`:293`) each await `registry.target`. The two reads can differ, and
    the line would then open with the new target's conversation and the old target's line.
  - It adds an actor hop, and a point where the actor can re-enter, on every delivery.
- Fix: carry the decision in the event, `.deliver(line, opensLine: Bool)` (or
  `isTarget: Bool = false`). `say` computes it from the registry: the line's session is
  `registry.target` and has an open request, or this delivery closed one. The stored var goes
  away.

**SIM-2. Important. The result window and `awaited` no longer describe the same set, so a stale
wait keeps a later line open for 120 s.** Simplification and efficiency raised this.
- Where: `CallMachine.swift:218`, `if isWindowOpen, !awaited.isEmpty, !isSoundOn`.
- Scenario: the owner hands Alpha a long task, switches to Beta and hands Beta a quick request.
  Beta answers in about 10 s. Alpha, still in `awaited` from the earlier line, keeps silence
  from closing Beta's line until the window ends at 120 s.
- Cost: about 80-100 s of billed line per such exchange. Before this PR it closed 20 s after
  Beta answered.
- Fix: replace the Bool with `windowSessions: Set<SessionID>`, the sessions handed off in this
  window. Hold while `!windowSessions.isDisjoint(with: awaited)`. Or take the Architecture
  section's deeper form, where `awaited` is scoped to the line again.

**SIM-3. Minor. A notice withdrawn before its line connects still opens a silent line.**
- Where: `Bridge.swift:461` withdraws `.approval` and `.asking` when the owner answers at the
  keyboard. If that notice opened the line, `openRealtime` is already running.
- Cost: a connect plus about 20 s billed with nothing to say, and no chime.
- Fix: when a withdraw leaves a result-opened line with nothing pending, close it. If CR-4 stops
  approvals from opening the line, this applies only to `.asking`.

**SIM-4. Minor. `isOpenedByResult` exists only so that a failed connect chimes.**
- Where: `CallMachine.swift:107-109`, `:162`, `:249-254`. It stays true through `.live`, where
  `phase == .live` already covers it.
- Simpler: chime in `hangUp` whenever `!pending.isEmpty`. This is a small behaviour change for
  the owner: a failed connect opened by speech would chime again. It closes a real gap: results
  that arrived while the line was connecting do not chime today when the connect fails. If the
  current behaviour must stay exact, keep the flag and say in its comment that it is for
  `.connecting`.

**SIM-5. Minor. A silent reopen is billed for the full 20 s.**
- `CallMachine.swift:167-169` arms the plain 20 s silence on `.connected`. Item (n) has 1 of 4
  reopenings silent, while the voice spoke within about 5-8 s in the others.
- Cheaper: when a result opened the line and the voice has not spoken yet, arm a shorter first
  timer, about 12 s. Fall back to 20 s once `assistantSpeaking` arrives.
- Docs: "1 of 4" is written three times (`README.md:357`, the ADR decision, item (n)). The
  README and the decision should link to item (n).

### security-review (SEC)

No High or Medium finding. Traced and holding:

- **No cross-session seeding.** Every delivery with a session goes through `say`. `openLine`
  seeds only `registry.target`'s conversation.
- **Nothing opens after Stop.** `(_, .stop)` and `audioFailed` reset the machine (`end`,
  `self = CallMachine()`), and `(.off, _)` ignores deliveries.

The two Low findings (confidence 8 and 9) are CR-1 and CR-4 above: the microphone opens for
lines the README says only chime. CR-8 (the pre-roll) is disclosed. SECURITY.md stays literally
true: it hands the "what goes to OpenAI" list to the README.

---

## PR #28: BR-001, the tick, and the reworded rule

### requesting-code-review (CR)

**CR-1. Important. The README and the CHANGELOG promise more than the code does.**
- `README.md:284-285`: "If the voice says it is looking and no tick follows, nothing was sent to
  Claude". `CHANGELOG.md:11-12`: "with no tick you know nothing was sent".
- But `.handedOff` is handled only in `.live` (`CallMachine.swift:178`). In `.connecting` or
  `.listening` it falls through to `[]`, while `Bridge.route` has already enqueued the request.
  The test "a handoff that lands as the voice hangs up" (`BridgeTests.swift:573`) shows that
  case is real.
- The tick also means "queued for the session's next poll", which the overview says correctly
  (`overview.md:142`). The README and the CHANGELOG say "reaches" and "sent".
- Fix: emit `.confirmHandoff` for a session in every phase except `.off`, keeping the result
  window `.live`-only, and add rows for `.connecting` and `.listening`. Then say "queued" in the
  README and the CHANGELOG.

**CR-2. Important. BR-001 cites ADR 0001 item (n), which exists only on #27's branch.**
- Where: `docs/bugs/BR-001.md:8` (`source:`), `:26`, `:94`, and the PR body. The probe's method,
  the run transcripts and the "3 of 10" figure all rest on it.
- If #28 lands before #27, the pointer dangles.
- Fix: merge #27's ADR commit first (see the merge order), or restate the probe's method in
  BR-001.

**CR-3. Important. The prompt rewording has no measured benefit, and it adds an unmeasured
risk.** Altitude raised this too.
- Where: `app/Sources/BridgeCore/Codex/VoicePrompt.swift:37-42`, commit `6fd3b26`, typed `fix`.
- BR-001 calls 2 of 20 against 3 of 20 chance. The new text adds "When you answer from what you
  already have, no handoff is needed", which pushes toward answering without Claude. It drops
  "Never answer such a request with words alone". BR-001 says it did not measure whether that
  keeps requests that need Claude from reaching it.
- AGENTS.md: a model instruction is not a control.
- Fix: ship the tick alone, and keep or revert the wording as its own change with a measurement
  of the risk it adds. If it stays, retype the commit, or say in the CHANGELOG that the change
  is neutral. Also trim it (SIM-2) and answer the plan question in the cross-PR section.

**CR-4. Important. The tick plays outside the audio page while the microphone streams, and
this ships unverified.** Altitude and efficiency raised this too.
- Where: `app/Sources/LiveBridge/AudioHost.swift:80`, `NSSound("Tink")`.
- WebRTC echo cancellation (`audio.js`, `echoCancellation: true`) knows only the page's own
  output. The tick is the first sound the app plays while the line is open. If the microphone
  hears it:
  - local voice detection may start a `speechStarted` that moves the silence rule to the 90 s
    noise cap;
  - the server's voice detection may take it for the owner and cut the acknowledgement.
- BR-001 says so honestly. The README and the CHANGELOG state the tick flatly.
- Fix: one real-microphone run before this reaches `main`, or a known-limitation line. The
  fallback BR-001 names is the right one: play the tick through the audio page's output path.

**CR-5. Minor. ADR 0001 (b) still says "5 of 5 runs delegated" after the rule.**
- `docs/adr/0001-platform-findings.md:140-144`. BR-001 shows that was luck: about 1 in 5 fail.
- Fix: add a one-line pointer to BR-001.

**CR-6. Minor. Race in `handoffToASessionIsConfirmedBySound`.**
- `BridgeTests.swift:345-351` waits for the poll and then reads `audio.calls` once. `route`
  enqueues before `send(.handedOff)` reaches the audio, so the poll can win.
- Fix: `eventually { … count == 1 }`, and a negative case: with no session joined, no tick
  plays.

**CR-7. Minor. BR-001's pointers are stale on arrival, and the entry holds too much.**
- `BR-001.md:15` quotes the paragraph that starts "A handoff is the only way anything reaches
  Claude", which this PR rewrites. "With the current rule" (`:94`) now means A, while the shipped
  prompt is B. Name the commits: A is `20649ff`, B is `6fd3b26`.
- The vendor survey is unsourced ("sources not re-read here"). Link it or cut it to one line.
- The (b) numbers repeat ADR 0001 (b). Link them instead.
- The tick is appended under "Suggested fix: a hypothesis". A separate "Mitigation" paragraph
  would read more clearly. `open` is the right status.
- `stayfixed bugs check` passes on the head tree, and the index row matches.

**CR-8. Minor. Smaller doc points.**
- `CHANGELOG.md:17` "now says it may answer from what it already knows" misdescribes the diff:
  `VoicePrompt.swift:31` already said that.
- The overview's handoff sequence diagram (`overview.md:172`) has no tick step. The prose at
  `:141-146` is now one long sentence.
- The README has a setting for the chime's notification and none for the tick. Note whether the
  tick follows it.

### simplify (SIM)

**SIM-1. Minor. `chime()` and `confirmHandoff()` are parallel one-line `NSSound` calls.**
- `AudioSide.swift:41-43`, `AudioHost.swift:78-80`, `FakeAudio`. A third sound would touch five
  places.
- Simpler: `AudioSide.play(_ cue: AudioCue)`. Keep the two `CallEffect` cases: `.chime` also
  calls `notifyWaiting()`.
- Optional. It matters more if CR-4 moves the tick into the audio page.

**SIM-2. Minor. The new prompt paragraph repeats two others.**
- "you cannot look, check, find out or change anything yourself" repeats the "You see nothing"
  paragraph (`VoicePrompt.swift:23-29`, "only Claude can").
- "When you answer from what you already have, no handoff is needed" repeats `:31`, "Answer
  yourself only what … already cover".
- The file says "Each paragraph is one rule" (`:3`). This one now holds three.
- It also clashes with the destructive-action paragraph (`:49`). That paragraph has the voice
  say "I'll delete X, yes?" before any handoff, while this one forbids saying "I will" without
  a handoff.
- Fix: cut the paragraph to its one new rule: never claim an action unless you hand it off in
  the same turn, before you speak, except to ask the owner to confirm it.

**SIM-3. Minor. The tick's rationale has three homes.**
- `README.md:284-285` (a billing bullet that is not about billing), the README's known
  limitations (`:352-356`), and `overview.md:141-144`.
- Fix: keep the known-limitations entry, which links BR-001. Drop the billing bullet and the
  overview's parenthesis, and link instead. The README's "about one request in five" (`:353`)
  should link BR-001 for the measurement.

The tick itself is at the right altitude. It sits where the chime is decided, right after the
registry accepts the request, so it stays in the table test. Matching the voice's words would
not work in every language. codex's `flushTranscriptTailOnSessionEnd` is worth a probe later as
a recovery path, not as a replacement: it is untried with `clientManagedHandoffs`, it arrives
only when the line ends, and it would turn small talk into prompts.

### security-review (SEC)

No finding.
- The destructive/outward rule ("yes?" before a handoff) is unchanged.
- The tick is local and sends nothing.
- No personal data: only `/tmp/lbprobe.*`, `~/.codex/...` and "Example session". A grep for the
  owner's name, email and `/Users/<name>` is empty.

---

## Across the three PRs

### Merge conflicts

Measured with `git merge-tree` on the pushed heads:

| Merge | Result |
|---|---|
| #24 onto current `dev` | **conflict** in `plugin/hooks/register.tsx`: #23's `drawnAt` and #24's `stepText` were added on the same line. Trivial: keep both. #24 must be rebased or merged with `dev` first. |
| #27 onto `dev` | clean |
| #28 onto `dev` | clean |
| #24 + #27 | clean |
| #24 + #28 | conflict in `CHANGELOG.md` `[Unreleased]`: both add sections. Keep both. |
| #27 + #28 | conflicts in `CallMachine.swift` (the `(.live, .handedOff)` branch) and in `README.md` (the closed-line bullet) |

#27 + #28 is the only one that needs thought:

- **`CallMachine`:** the right result is `isWindowOpen = true` (#27) and
  `return [.confirmHandoff, .armResultWindow(…)]` (#28).
- **`README.md`:** keep #28's tick bullet, then #27's closed-line bullet. Do **not** keep #28's
  copy of the old "A result that arrives later … plays a chime" line: #27 replaced it.
- **`overview.md` merges without a conflict, but the result needs care.** #28's Handoff
  paragraph and #27's "when the result comes, it opens the line again" land in the same
  paragraph. Reflow it.

Merged that way, all three together pass `scripts/check.sh`.

### Do #27 and #28 overlap?

In text, yes; in design, no.

- Both edit `(.live, .handedOff)` and the overview's Handoff and closed-line sections. They read
  the same request lifecycle: queued (the tick, the window), then answered (the reopen).
- #28 attaches to the right point.
- #27 is the one that duplicates the lifecycle, by keeping `awaited` past a hang-up. If #27
  takes its SIM-1 (the bridge decides from the registry), both are driven by the registry:
  acceptance makes the tick, and an answering delivery closes the request.
- One behavioural interaction: #28 CR-1 (no tick outside `.live`) and #27 both concern what
  happens while the line is not live. Fix #28 CR-1 in the merged machine.
- #24 interacts with #27: #24's mid-turn `[UPDATE]` from the awaited target opens a closed line
  under #27, while #27's docs say an update chimes. #24 SIM-1 (fold the text into `[ASKING]`)
  removes the interaction.

### #28's prompt rule and the voice-context plan

The plan (`docs/plans/2026-11-04-voice-session-context.md` on `origin/docs/voice-context-spec`,
`e256607`) has Task 3 edit `VoicePrompt.swift:18-70`:

- the rule on "the chat";
- "to fetch, hand off exactly `refresh context`, in English";
- `[LAST]` joins the tag list;
- a typed turn's question waits at the keyboard.

How #28's rule fits:

- **The two agree on intent.** #28 says the voice "cannot look, check, find out … yourself" and
  must hand off before it says it is looking. The spec says that asked about "the chat", the
  voice answers from what it has, or fetches. The fetch is a handoff (`refresh context`), so
  "handing off is the only thing you can do" stays true. The voice saying "let me check the
  chat" and then fetching in the same turn is exactly what #28 asks for.
- **They overlap in the same paragraphs.** Task 3 adds a fetch rule next to a paragraph that
  #28 rewrote, and next to the two older paragraphs that #28 repeats (#28 SIM-2). Task 3's line
  numbers (18-70) predate #28, which moves the handoff paragraph to lines 37-42.
- **Recommendation:** merge #28 first, trimmed per SIM-2 to its one new rule. Task 3 then
  rebases onto it. The "You see nothing" and "Answer yourself only" paragraphs are where "the
  chat" and the fetch belong, and they are the paragraphs #28 duplicates. So when Task 3
  rewrites them, it should absorb #28's "you cannot look yourself" clause rather than add a
  fourth statement of it.
- **X-1. Important. One real conflict: the tick and the fetch.**
  - Plan Task 3 makes `RealtimeSession` turn `refresh context` into its own
    `RealtimeEvent.contextFetch`. That event never reaches `CallEvent.handedOff`, so under #28
    a fetch plays no tick.
  - The owner hears "let me check the chat" with no tick. The README (#28) tells them that means
    nothing was sent, though the fetch happened.
  - Decide what the tick means before Task 3 is built. Either:
    - (a) the tick confirms every handoff the app acted on, the fetch included. Task 3's
      `fetchAsked` then emits `.confirmHandoff`, and the README says "the voice's request was
      taken". Recommended: it keeps one positive signal for one failure mode.
    - (b) the tick confirms only what reached Claude, and the README says a fetch is silent.
  - Either way it is one line in Task 3 and one test row (`fetchAskedIsConfirmed` or its
    opposite). The plan should add it.
- **X-2. Minor. #27 and the plan.**
  - The plan's spec defers "the switch's held answers" to a spec of its own with #27.
  - Task 4 ("every line the app opens loads context") makes a line that a result opened ask for
    context too. After a typed turn, that costs a summary fork per reopening.
  - Task 4's `openingALineAsksForContext` should name the reopen case explicitly. Its line
    numbers in `Bridge.swift` predate #27.
- **X-3. Minor. #24 and the plan.**
  - Plan Task 2 consumes #24's `stepText` as it is, and the plan's work branch
    (`feat/voice-session-context`, Task 1 done so far) already merges #24.
  - If #24 takes SIM-1 and SIM-3 (the text in `[ASKING]`, kept in `TurnTracker`), Task 2's
    `lastText()` must read it from the tracker.
  - Settle #24's shape now, before Task 2 is built on it.

### Merge order

**#24 → #28 → #27**, each after its fixes. #27's ADR commit can go first on its own.

1. **#24 first, because the voice-context work already builds on it.**
   - Rebase on `dev`: one line, `drawnAt` beside `stepText`.
   - Fix CR-1 and CR-2 (the tests), and decide SIM-1 (the text inside `[ASKING]`) before plan
     Task 2 uses it.
   - It is independent of #27 and #28 except for a `CHANGELOG.md` conflict. Merged before #27,
     it can never send a mid-turn `[UPDATE]` that #27 would reopen a line for, provided SIM-1
     is taken.
2. **#27's ADR commit `e84fba6`** (item (n), docs only), if #27 is not ready by the time #28
   is. BR-001 cites item (n) (#28 CR-2). Cherry-pick it to `dev`, or let #28 restate the probe.
3. **#28: small and closest to ready.**
   - Fix CR-1 (the tick in every phase, "queued" in the docs), CR-3 (decide the prompt), CR-4
     (a known-limitation line, or one real-microphone run) and CR-6.
   - Merging it before plan Task 3 gives Task 3 the prompt to rebase onto, and settles X-1
     there.
4. **#27 last, since it needs the most work.**
   - Fix CR-1, CR-2 and CR-3, and decide CR-4 (approvals).
   - Do the simplification (SIM-1, SIM-2) in the same change: it removes the state that CR-1
     and SIM-2 come from.
   - Rebased on #28, it resolves the `CallMachine` and `README.md` conflict as described above.

The voice-context branch then merges `dev`. It will conflict with #27 and #28 in
`CallMachine.swift`, `Bridge.swift` and `VoicePrompt.swift`, because the plan's line numbers
predate them.

## Counts

| PR | Source | Critical | Important | Minor |
|---|---|---|---|---|
| #24 | CR | 0 | 2 | 5 |
| #24 | SIM | 0 | 2 | 3 |
| #24 | SEC | 0 | 0 | 1 |
| #27 | CR | 0 | 5 | 5 |
| #27 | SIM | 0 | 2 | 3 |
| #27 | SEC | 0 | 0 (its two Low findings are #27 CR-1 and CR-4) | 0 |
| #28 | CR | 0 | 4 | 4 |
| #28 | SIM | 0 | 0 | 3 |
| #28 | SEC | 0 | 0 | 0 |
| Cross-PR | | 0 | 1 | 2 |
| **Total** | | **0** | **16** | **26** |

42 findings: #24 has 4 Important and 9 Minor, #27 has 7 and 8, #28 has 4 and 7, and the
cross-PR section has 1 and 2.
