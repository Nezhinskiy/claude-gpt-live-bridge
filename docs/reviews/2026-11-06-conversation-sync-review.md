# Review of PR 42: conversation sync

- Pull request: [getLiveBridge/LiveBridge#42](https://github.com/getLiveBridge/LiveBridge/pull/42),
  `claude/feat-conversation-sync-build-28f2bd` → `dev`, 54 commits, 56 files, head `c482d4b`,
  reviewed against the merge base `f9059d5`. Findings only; nothing was fixed and the PR's branch
  was not touched. `dev` has since gained PR 39, which this review did not look at.
- Spec: `docs/specs/2026-11-05-conversation-sync-design.md`. Plan:
  `docs/plans/2026-11-06-conversation-sync.md`.
- Verdict: **merge after fixes.** 0 Critical, 11 Important, 36 Minor. The sync's core is sound and
  the permission boundary holds. What stops the merge is one defect class (the route of a question
  across a target change), a gap the menu does not show (a turn the owner interrupts), a summary
  that clears a gap it does not cover, false "You allowed" lines, a stall on long unbroken text, and
  three docs that claim more than was seen. R-1 needs the owner's ruling.

## How this was checked

- **Independent readers:** one each for the app, the mod, security, and docs with wire and tests,
  plus `simplify`'s four. I read the code behind every Important finding and reran what follows.
- **Rerun by me at `c482d4b`:**
  - Swift: 549 tests pass.
  - 11 app probes, each stating the expected behaviour: all 11 fail as predicted. Ten are findings;
    `p8` is a limit `SECURITY.md` already states.
  - 7 mod reproductions on the engine test harness: each logged the outcome below. The harness feeds
    scripted events, so they prove the mod's logic given those events, not the engine's order.
  - Redaction, timed through the real `AnswerShaper.synced` in a release build (R-7).
  - The one mutation behind R-11.
- **Reported by a reader, not rerun by me:** mod unit 65 and engine 155 all passing; 110 mutations,
  99 caught (11 survivors in R-11, R-42 and R-43).
- CI at this head: `check`, CodeQL and Swift analysis pass.
- **Not done:** no voice, no `scripts/smoke.sh`, no desktop app, nothing in `/Applications`. So
  every "said" below is what was handed to codex, not what was heard.
- Proofs are in `pr42-review-proofs/` in the shared notes folder, not in the repo:
  `ProbeTests.swift` and `TimingProbeTests.swift` (add to `app/Tests/BridgeCoreTests/`),
  `repro.test.tsx` (add to `plugin/tests/`).

Line numbers are at `c482d4b`. CONFIRMED means run or traced line by line; PLAUSIBLE means the logic
is traced but the trigger, usually an engine order, was not observed.

## Is it elegant? Is anything redundant?

**In its layers, yes. In its central concept, not yet.** The pure tracker, the pure `CallMachine`,
`Continuity.admits` as one gate, seed-or-hold, and "the mod holds no setting of the app's" are
right. The monotone `nil < missed < paused` is clean.

The spec's main rule is about turns ("a turn's sync is decided when it starts"), but the app has no
real turn. Voice turns are invisible to it, and `activity` names a turn only sometimes. Four
weaknesses follow from that, and they explain most findings:

1. **Turn identity is missing from the wire.** One fact, "this turn is refused", has two homes:
   `Conversation.turn` and `inFlight.isWithheld`. The second is reached by guessing, with 17
   references across `Bridge` and `SessionRegistry`. The PR says the app "cannot tell them apart
   without a wire change". Cost: R-13, R-18, and "a request waiting behind a typed turn is withheld
   too".
2. **`from` carries three meanings:** who wrote it, whether it may refuse a turn, and, with empty
   text, "take the decision". That is why "You allowed …" goes tagged `[CLAUDE]`, which the voice
   prompt defines as Claude's answers, and why `keyboardAnswer` picks the sender from the content.
3. **`questionRoute` has no owner.** About nine write sites and an implicit rule. R-1, R-2, R-15,
   R-16 and R-17 are one defect class.
4. **A summary has no time.** `setContext` clears everything without knowing what it covers (R-5).

**Recommended wire change, one move, and free now:** `SyncBody` and `typedTurn` are unreleased
(`[Unreleased]`, last release 0.3.0). After release the shape has to stay compatible.

- Every main-loop line and activity carries `turn: { id, request? }`; the mod already holds both.
- `from` becomes `kind: start | typed | answer | report`. Only `typed` refuses; only `start` has no
  text; speaker and tag derive from it.
- Goes: `isAnswerWithheld`, the `hasOpenRequest` guess, the second check in `activity`, the
  `typedTurn` helper. Stays: `isWithheld` and `.dropped`, as the request's life is the registry's.
- About 100 to 150 lines touched, likely a net deletion; `Wire.swift`, `wire.ts` and 3 or 4 fixtures
  change together. It is an estimate; nobody built it.

"The mod sends, the app decides" is the right direction, stated loosely. It should read "the mod
reports facts, the app decides policy": today the mod picks `from: 'claude'` to steer `admits`, and
`withholdAnswer` infers which turn a line belongs to.

### What could go

About 110 of the 731 added source lines and 400 to 500 of the 2,616 added test lines, by hand count.
Most of the bulk is tests: 3.6 test lines per source line. Ordered by what is worth doing.

No behaviour change:

- **S-1.** `turns.ts:101`: `get running` has no production reader since this PR; only 9 test
  assertions keep it alive. About 8 lines.
- **S-2.** `turns.ts:34,109,113,167,182,232`: the `#turns` Map never holds more than one entry
  (`turnStarted` clears it first). `#turn | null` removes `#latest` and three `linesUnder ?? turnId`
  fallbacks. About 8 lines.
- **S-3.** `turns.ts:86,120-128,181,225`, `register.tsx:85`: `#isTurnLost`, `takeLostTurn` and
  `noteLostTurn` carry a value across one statement, beside `link.hasGap`. `turnStarted` and
  `turnCompleted` can return it. About 14 source and 30 test lines.
- **S-4.** `Bridge.swift:625-668`: `activity` has `var body`, `var isRefused`, two `setActivity`
  calls and a 13-line `if/else` differing in kind and head. About 15 lines.
- **S-5.** `Bridge.swift:702-730`, `AnswerShaper.swift:32-44`: shape-then-add appears twice, and
  `addSynced(as:)` takes a speaker the source implies. About 9 lines.
- **S-6.** `register.tsx:93`: `save` and `trySave` can be one function; six store-failure tests (82
  lines) test it site by site. It also closes R-21. About 5 source and 55 test lines. It changes one
  thing: a failed store no longer surfaces from `/live on`.
- **S-7.** `register.tsx:48-50,549-555,576-579`: `lastOrigin` and `lastPrompt` move together: one
  `lastSubmit`. `plugin/hooks/turns.ts:19`: `SyncLine` restates `SyncBody` by hand, so a wire change
  compiles without touching it: `Omit<SyncBody, 'sessionId'>`, as `link.ts` does elsewhere.
- **S-8.** `MenuContent.swift:142-146`: "Context up to date" is spliced in beside
  `ContextLoadState`, which owns every other title and enabled state of that item. Add a `.current`
  case.

Needs a ruling, as a sentence of the spec or a behaviour changes:

- **S-9.** Two holds for "context waiting for connect": `heldContext` and `seededContext` in
  `Bridge`, `connectingSynced` in the machine. Sending a summary through `.synced` removes the first
  two and about 14 lines. Two summaries during one connect would then both go; the spec's
  "`heldContext` stays the summary's one slot" changes.
- **S-10.** `turns.ts:36,166-168,184-187`: prompts are matched to turns by text, though ADR 0001 (m)
  says a prompt with its own turn has a `turn.start` and no second `prompt.submit`. So null origin
  is the signal, and `#typed`, `entered` and R-24 go, and queued slash commands are claimed. Risk:
  this leans on a terminal-only observation. About -20 lines.
- **S-11.** `Continuity.swift:62,100-106,181`: `forget` builds a tombstone to keep `turn` and
  `paused`. A `syncState` map beside `conversations` lets `forget` forget, and stops eviction
  dropping a paused mark. About 40 lines touched.

Tests (project rule: one behaviour, one test), about 280 lines:

- Same steps: `aQueuedRequestIsNotMarked` and `aWithheldSupersededRequestLeavesTheNewerOneTheLatest`
  (`SessionRegistryTests.swift:353,419`).
- Subset: `missedUnderThePauseIsPaused` within `missedDoesNotReplacePaused`.
- Same path twice, one layer up: `aWithheldSupersededAnswerIsDropped` / `…StaysOut`;
  `aWithheldRequestClosedTakesNoUpdate` / `anUpdateAfterAWithheldAnswerIsRefused`;
  `withNothingOpenTheFollowUpEnds` / `anUpdateFromABackgroundTurnTypedIntoIsRefused`;
  `theOwnerTypingAfterStopRefusesTheTurn` / `…IsDropped`;
  `aTurnFromBeforeThePauseKeepsClaudesAnswer` / `aTurnFromBeforeStopKeepsItsAnswerInThePause`;
  `aRefusedTurnStaysRefusedAfterThePauseEnds` / `aPausedTurnsAnswerStaysOutAfterStart`.
- Tracker twins in `turns.unit.ts` and `roundtrip.test.tsx`, about 80 lines; four tests of one line
  in `limits.test.tsx:61`, about 40 lines. Setup: 29 `BridgeTests(pausesSync: true)`, 41 `/live on`.

Reuse is good: little was re-implemented. Efficiency: R-7 and R-47; nothing else matters at this
rate.

## Findings

### Important

**R-1. A kept route overrides the owner's choice of target.**
`Bridge.swift:183-187,339-343,549-552`. CONFIRMED, `p1`, `p2`. The owner's ruling is needed.

- `setTarget` keeps `questionRoute` while the question waits, and `route()` sends the next handoff
  there, whatever it says. Nothing re-reads the route once the question has been said.
- Scenario: Alpha's typed turn asks a question. The owner picks Beta in the menu. Beta's line is
  given Alpha's `[ASKING]`. The owner says something meant for Beta. It goes to Alpha as the
  dialog's free-text answer, while the menu shows Beta. In `p2` the question was said, `unheard` is
  0, and the next unrelated request becomes a voice turn in Alpha.
- The PR's ruling states the cost as "Beta's line hears Alpha's question once". The real cost is one
  spoken request acting in the wrong session, unseen.
- A one-slot route cannot tell a reply from a new request, so one of the two directions must lose.
- **Resolution, recommended:** a change of target ends the route and takes the waiting question off
  the queue. It is already recorded, so it is in Alpha's seed, and the spec covers the rest: "A
  question still open when its session becomes the target is in the seed". It reverses this PR's
  ruling, hence the owner's call. A pause at the plan's limit keeps its route, rightly: there the
  target did not change.

**R-2. `POST /v1/target` never ends a route.** `Bridge.swift:262-263`. CONFIRMED, `p7`. Listed in
the PR's deferred minors; graded too low.

- Scenario: Alpha's question is said and leaves the queue. The owner uses the band's target button,
  `/live target`, or the band's Start, which posts a target too. On Beta's line a spoken request
  goes to Alpha as a new voice turn, with no question pending at all.
- The route can live until the next handoff or Stop. The menu's choice and the band's now behave
  differently. The same code is at the base; the PR left it on purpose.
- **Resolution:** the route posts through the same path as `setTarget`, whatever R-1 rules.

**R-3. A typed turn's question or notice on an open line is added, not given to say.**
`CallMachine.swift:232-236`. Path CONFIRMED, `p10`; the effect on speech is PLAUSIBLE.

- The spec says a question from any main-loop turn is said "as a voice turn's question does today".
  A voice turn's session is `awaited`, so it gets `.speak` (`appendSpeech`). A typed turn's is not,
  so it falls into the `.addContext` branch. The plan's matrix says "added now", so spec and plan
  disagree.
- Scenario: Claude asks for a permission in a typed turn while the line is open. The notice goes in
  as context, and `spoken` stays empty. Manual line 6 failed exactly here: said before the keyboard
  answer 0 of 2, and once 9 s late. The PR files that as the model's behaviour, but one code path
  the app could change was not tried. `speak` may not help, as the model still chooses.
- **Resolution:** `.speak` for `.asking` and `.approval` on a live line, whoever started the turn,
  then rerun lines 5 and 6.

**R-4. A turn the owner interrupts leaves no line and no gap, and the menu says up to date.**
`turns.ts:230-232`, `register.tsx:610-615`, pinned by `an interrupted turn posts nothing`
(`turns.unit.ts:147`). CONFIRMED.

- `aborted`, `refusal`, `error`, and an empty answer all post no line, and none notes a gap. `Esc`
  is ordinary use.
- Scenario: the owner types "rename X", Claude works for three minutes, the owner presses Esc. The
  voice holds only the prompt, and implies the work is pending or done. The menu reads **Context up
  to date**, "because the voice already has the conversation" (`README.md:244-248`). That is the
  spec's named failure: "A sync that silently misses turns while the menu says it is current".
- The spec's non-goal covers text in the middle of a turn, not the fact that the turn ended.
- **Resolution:** a turn that ends without an answer posts a short line as Claude's ("That turn was
  interrupted." or the like), under the turn's decision. No summary is needed.

**R-5. A summary written before a gap clears the gap.** `Continuity.swift:87-91`,
`Bridge.swift:687-688`, `register.tsx:84-87,284-286,380-387`. CONFIRMED, `p3`, `p11`, and mod
reproductions C and D.

- `setContext` clears `outOfSync` and zeroes the count, with no idea when the summary was written. A
  summary runs up to 60 s.
- Scenario 1: pause on. The owner presses Load context, then Stop, and types. The turn is refused
  and marked paused. The older summary lands, and `outOfSync` goes nil. The menu says Context up to
  date, and the voice has neither that turn nor its answer. With the mark gone the turn is
  unprotected: if the setting goes off and the seed outgrows the window, a line auto-loads a summary
  of the paused text.
- Scenario 2: a summary is cached, the owner's line gets a 503, the mod rejoins with `missed`, the
  app asks for context. No new fork runs (`forks` stays 1); the cached text is posted and clears the
  mark with the prompt still lost. A gap does not stale the summary.
- Scenario 3 (`p11`): a summary in flight lands after New conversation and restores a summary of
  what was just forgotten.
- **Resolution:** a gap stales the mod's summary, and `/v1/context` clears only what it can cover:
  the app stamps each ask with a recorded-line position and refuses or ignores a summary from before
  the latest mark or forget.

**R-6. The settled line claims "You allowed" falsely, and can silence a prompt still open.**
`register.tsx:458-462,475-477,483-488,592`. Logic CONFIRMED, reproductions A and B; the engine's
order after a subagent's No was not observed. The parallel case is in the PR's deferred minors;
graded too low.

- `settles` matches by tool name and agent. `promptGone` returns while `approval.agent` is set.
- Scenario 1: in a typed turn, subagent a1 asks to run `rm -r build`, and the owner says No. No hook
  reports it, so nothing posts and the app's row stays `approval`. a1's next `ls`, allowed by a rule
  with no dialog, fires `classic.PostToolUse`. The mod posts "You allowed Bash at the keyboard." The
  voice then holds the opposite of what happened. Until then a main-loop question falls into the
  `(true, true)` arm and no line is said for it (R-19).
- Scenario 2: Claude reads `/etc/hosts` (prompts) and `./a` (does not) in one step. `./a` finishes,
  and the mod posts "You allowed Read" and `working`. The app withdraws `[APPROVAL]` with the dialog
  still open. This is not only Bash, and it silences the notice for an owner away from the Mac,
  which the deferred note omits.
- This does not answer a prompt. It is a false report about one.
- **Resolution:** `tool_input` is on both hooks: match on it. Hold `approval` in the tracker, keyed
  by agent, so it is unit-testable and in the snapshot.

**R-7. Redaction stalls on long unbroken runs, and all typed text now goes through it.**
`Redaction.swift:21`, reached from `AnswerShaper.swift:40`, `Bridge.swift:703`. CONFIRMED by timing.

- Through the real `AnswerShaper.synced`, in a release build: 2,000 hex characters 0.29 s, 8,000
  4.65 s, 16,000 18.67 s; 32,000 characters of prose 0.02 s. It is quadratic, so 32,000 hex
  characters, the mod's clip, is about 75 s by extrapolation.
- The run needs the rule's class: hex or base64url outside a code fence. Ordinary base64 is broken
  up by `+` and `/`, so this is rare.
- The quadratic is at the base, on voice answers. This PR adds a second `*`, which a reader measured
  as much worse on keyword-dense runs, and sends every typed line through it, with the call off too.
- Scenario: the owner pastes a 16 KB hex dump into a prompt. The regex runs on the `Bridge` actor,
  so every session's poll, the sweep and the line wait 19 s. `turn.start` and `prompt.submit` await
  `postSync`, and the mod sets no timeout on it, so the owner's turn does not start either.
- **Resolution:** a reader's form, unbuilt here, measured about 0.4 ms on 32 KB and matched on 12
  samples: drop the leading `*` (the prefix is outside the match anyway) and bound the trailing one
  to `{0,64}`. Keep a test with a long run.

**R-8. "Delivered" says more than was seen.** `docs/specs/2026-11-05-conversation-sync-design.md:3`,
`docs/trail.toml:14-15`, `docs/roadmap.md:37,40`. CONFIRMED.

- The status gives one caveat, the desktop app. The PR body also has line 6 failed on the
  announcement, line 5's spoken answer not checked, Load context never seen in the menu, no real
  model on this branch, and F1's fix and the merge of #40 and #41 not checked by voice. Lines 5 and
  6 are the spec's own goals.
- Scenario: after merge the PR's table is gone. A reader of the roadmap sees plain "delivered" and
  no open item. The repo already says "delivered in part" for two specs.
- **Resolution:** "delivered in part", with the open checks named in the status line, and the two
  new counts in ADR 0001 (below).

**R-9. "Is said by the voice" states a delivery as an outcome.** `README.md:311-312`,
`CHANGELOG.md:15-16`, `docs/architecture/overview.md:373,395`, spec lines 33-34, 82-84. CONFIRMED.

- `Bridge.opensLine` (`:509-514`) opens a line only for the target, and only if the conversation
  holds an owner line; otherwise `CallMachine.swift:208` chimes. With the call off it is only
  recorded.
- Measured, in the PR body only: said before the keyboard answer 0 of 2; on a prompt-opened line
  with nobody speaking, the voice spoke first 0 of 3. ADR 0001 keeps the older 3 of 4.
  `README.md:443` covers only Claude's answer.
- Scenario: the owner leaves the Mac trusting the voice to announce prompts, and Claude waits
  unannounced. The spec makes that exact promise: "The owner may be away from the Mac".
- **Resolution:** say the voice is given it and may say it, with the counts in ADR 0001 (n) and a
  known limitation. R-3 may improve the numbers; it does not change the sentence.

**R-10. "It knows what you type" rests on an unobserved origin in the desktop app.**
`README.md:304-305`, `CHANGELOG.md:11`, `SECURITY.md:164-166`, `turns.ts:45`. Doc gap CONFIRMED; the
failure PLAUSIBLE.

- Only `composer` is the owner. ADR 0001 (m) says the desktop app was not observed; the claim is
  inferred from transcripts stamped `human`. A host's unmarked message is `sdk`.
- Scenario, if the desktop arrives as `sdk`: nothing typed is recorded, no gap is marked, and the
  menu says Context up to date. The pause weakens too: text typed into a running turn is not posted
  (`register.tsx:558`), so the turn stays admitted. It is not in the README's known limitations,
  which the roadmap uses as the open-items list, nor in the ADR's "check by hand" list (`:614`).
- **Resolution:** add it to both until one run in the desktop app settles it. That run is the
  cheapest check left: see "Still open".

**R-11. Nothing tests that a synced line stays off another session's open line.**
`Bridge.swift:729`. CONFIRMED: I ran the mutation.

- With `lineSession == line.session` removed, so any session's typed text goes to the open line, all
  172 `BridgeTests` pass. `anOtherSessionsLineStaysInItsOwnConversation` has the call off.
- Scenario: a refactor breaks that guard, and B's typed text goes to OpenAI on A's line with a green
  suite. The docs promise "only when a line opens with it as the target".
- **Resolution:** one test: a live line on A, `/v1/sync` for B, nothing added.

### Minor

App flows:

**R-12. A turn the app never saw is admitted, even in a session marked paused.**
`Continuity.swift:162-165`. CONFIRMED, `p4`. Pause on, call off, and the owner's post fails (app
down, or `/live on` mid-turn). The join marks `paused`. The owner presses Start. The turn's answer
goes in as `[CLAUDE]` and onto the live line. `SECURITY.md:225` discloses "does not hold", so this
is not higher, but the spec says "a paused prompt never has its answer synced after Start", and the
paused mark is a signal the code ignores. **Resolution:** a Claude line with no decision for its
turn stays out while the session is paused.

**R-13. A voice request is withheld after the pause is over.** `Bridge.swift:707`. CONFIRMED, `p5`.
A turn is refused; the owner presses Start and speaks a request, which waits behind that turn; the
owner types one more line into the turn with the call on. The new request closes as "[FAILED] …
while the sync was paused", which is false. Fails safe. Goes with the wire change above.

**R-14. `/clear` during connect seeds an empty line.** `Bridge.swift:393,404,409`. CONFIRMED, `p9`.
The local `session` goes stale after `continuity.move`, so the seed is `[]` while the menu shows the
conversation and says current. Inherited, and a short window, but it is the anti-goal.

**R-15. A failed microphone leaves the route.** `Bridge.swift:216-218`. CONFIRMED, `p6`.
`.audioFailed` passes neither `perform(.stop)` nor `.endCodex`. The next handoff after Start goes to
the old session. Inherited.

**R-16. A session that left keeps its question.** `Bridge.swift:248-250,732-734,552-553`. CONFIRMED
by trace. Alpha closes with a typed question open. A typed turn has no request, so no "session left"
is said, and neither `leave` nor the sweep clears the route or the `[ASKING]`. The voice still asks
it, and the reply falls through to the target as a new request. The PR widens this to every typed
question.

**R-17. One route slot loses the earlier of two questions.** `Bridge.swift:50,563,660`. CONFIRMED by
trace. Non-target Alpha asks in a voice turn; target Beta asks in a typed turn; the owner replies to
Alpha, and it answers Beta's dialog. When Beta's closes, the route clears instead of restoring.

**R-18. A subagent's approval in a typed turn is taken for a voice turn's.** `register.tsx:658`,
`Bridge.swift:656`. CONFIRMED by trace. No `typedTurn` goes with it. In a non-target typed turn it
chimes and counts as unheard, which the spec forbids. In a refused turn its bare notice is recorded,
against `Bridge.swift:621-624`, and `README.md:313`'s "has none of this".

**R-19. One activity slot for two waits.** `register.tsx:471,659`, `SessionRegistry.swift:241`,
`Bridge.swift:642`. CONFIRMED, reproduction N for the post. With a main question open, a subagent's
prompt sets `isAsking` false; its settling posts `working`, which withdraws the open question, and a
spoken reply becomes a request queued behind the blocked turn. The other way round, a question while
the row is `approval` reaches nobody. Voice turns had this at the base; the PR widens it to every
turn.

Mod flows:

**R-20. A reply is not bound to its question.** `register.tsx:236-269,631`. Logic CONFIRMED,
reproduction G; timing PLAUSIBLE. The reply to Q1 is in the poll's response, the keyboard answers
Q1, and Q2 opens before `tick` reaches `:268`. Q1's words answer Q2, and the turn becomes a voice
turn.

**R-21. `tick` saves with `save`, not `trySave`, after a join says a gap.** `register.tsx:238`.
CONFIRMED, reproduction E. A store failure throws before the work is dispatched, and work is handed
out once: the request vanishes and stays in flight until the timeout. The class fix round 1 fixed.

**R-22. "At the keyboard" claims a source the mod cannot know.** `register.tsx:476,643-644`,
`prompt.ts:80`. PLAUSIBLE. ADR 0001 (i) says these hooks also run when a host answers, and another
hook may auto-allow. So the owner may have seen nothing, or used a phone. A host's answer also posts
`from: owner`, which under the pause refuses the turn: safe, but not the owner's words.

**R-23. A prompt that is not `composer` does not refuse a running turn.** `register.tsx:558`,
`turns.ts:45`. CONFIRMED by trace. A turn is admitted, then Stop with the pause on. A Remote Control
prompt goes in with no line posted, so the turn stays admitted and its answer, which may repeat it,
is recorded. The README's limit says only "not recorded as your words". Worse if R-10 is real.

**R-24. A queued prompt that matches no turn takes a fresh decision.** `turns.ts:184-187,203-205`,
`SECURITY.md:218-221`. Tracker CONFIRMED, engine order PLAUSIBLE. `SECURITY.md` names slash commands
as the only exception. A voice turn starting in between also wipes the remembered prompt: its own
turn got `{turnId: 't2', from: 'claude', text: ''}`, so after Start its answer is admitted. S-10
removes it.

**R-25. A reload at an open question loses `answerQuestion`.** `register.tsx:55,268-274`. PLAUSIBLE.
A spoken reply closes as "answered at the keyboard" with the dialog still open, and a real keyboard
answer may never post, with no gap. The deferred list has this for `approval` only.

**R-26. Typing now waits on codex.** `register.tsx:97,559,582,615,644`, `Bridge.swift:309`,
`RealtimeSession.swift:48`. Path CONFIRMED; delay PLAUSIBLE. The reply to `/v1/sync` waits for
`appendText`, up to 20 s if codex is stuck, and `prompt.submit` and `turn.start` wait for that
reply. **Resolution:** post the sync line without holding the hook, in order, through `serial`.

**R-27. A question or notice that does not reach the app leaves no mark.** `link.ts:130-132`.
CONFIRMED by reading. `activity` discards its result, so a failed post notes no gap. The spec lists
only turns.

**R-28. Turns run while the mod was off are not seen.** `register.tsx:527-531`. PLAUSIBLE, as it
depends on whether disabling fires `session.end`. With the key stored and `hasGap: false`, the join
says nothing.

Privacy and docs:

**R-29. The session title carries paused text past the pause.** `register.tsx:249`,
`SessionRegistry.swift:119`, `AnswerShaper.swift:70`, `SECURITY.md:202-245`. CONFIRMED by trace. The
poll follows the title whatever the pause says, and `line` puts it in every line, unredacted.
Scenario: pause on, the owner types a private first prompt, the desktop writes a title from it, and
after Start every line sends up to 80 characters of it. `SECURITY.md:210`'s list omits this, and
`:359` itself says a title is often written from the conversation. The label predates this PR; the
broken promise is new.

**R-30. The "exact" list of what reaches OpenAI is incomplete.** `README.md:370-381`,
`site/index.html:185`, `SECURITY.md:328`. CONFIRMED. The list stops at "Claude's final answer to
each typed turn". The code also sends answers to `other` and `background` turns, tool names in the
mod's notes, and superseded voice answers. An owner reading only Privacy sees no scheduled turn's
answer.

**R-31. Smaller reaches of the pause.** `SECURITY.md:213,225-227`, `turns.ts:168,240`,
`register.tsx:81`. Text typed as permission-dialog feedback reaches no hook, so the turn is not
refused (PLAUSIBLE). Text typed into a running turn sits in the mod's store until the next turn,
under the pause too, and "What the voice keeps" covers only the data folder (CONFIRMED). A gap under
the setting marks *paused*, not the *missed* the doc says: the safe direction (CONFIRMED).

**R-32. The record-only rule is wider than "a turn you typed".** `README.md:312-313`,
`overview.md:142`, `CHANGELOG.md:16-17`, `Bridge.swift:656`. CONFIRMED. It applies to any non-voice
turn, so a scheduled turn's question in another session gets no chime.

**R-33. `CHANGELOG.md:76-77` says "every time".** CONFIRMED.
`anAnswerAfterNewConversationOnlyChimes` pins a case where the line does not open, and F1's fix was
not checked by voice. Deferred; graded a little low.

**R-34. The spec contradicts itself.** Spec lines 197-198 say decoding ignores the old key; line 80
and `Settings.swift:45-49` map it. Lines 145-146 say "permanently *missed*"; nothing marks it, and
`Bridge.swift:375-378` uses `syncs`. A later reader takes the wrong one. CONFIRMED.

**R-35. Remote Control is stated as fact.** `README.md:449`, `SECURITY.md:167`. PLAUSIBLE. Mapping
`bridge` to Remote Control was not observed. If it arrives as `composer` it is recorded as the
owner's.

**R-36. "May mention them" is mild.** `README.md:306-307`. CONFIRMED. ADR 0001 (o) records "Done,
the module is renamed…" and "I'll take a look." with no request polled: the voice claiming work. The
spec accepts it, but a reader of the README expects no false claims of work. Name it as a limit.

**R-37. The PR body lists the older mod's empty `ok` as "in the docs".** `CHANGELOG.md:82-84` says
fixed, unqualified. It is in no doc. The voice says "code or a table only" for it. CONFIRMED.

**R-38. One fact, several homes.** The causes of needing a summary are in `README.md:223-225`,
`:244-247`, CHANGELOG, overview and two specs; the pause's rules in four files; 64, 20, 128 and
8,192 likewise. First drift: `overview.md:70` says New conversation keeps the mark; `SECURITY.md`
says × too.

Wire:

**R-39. A newer mod on an older app does not "carry on as today".** Spec line 144,
`CHANGELOG.md:20-21`. Traced at the base, not run. An older app ignores `typedTurn`, so typed
questions are spoken, in other sessions too. A spoken reply goes with nothing in flight, so the line
can wait up to 120 s, billed, for no result. The plan accepted this; the spec and changelog did not
change.

**R-40. No fixture for two shapes that behave differently.** Empty `text` on a sync line, and a
reply without `forRequest`. A change there goes unseen by the fixture tests. CONFIRMED.

**R-41. `wire.ts:6-7` says 410 for a removed session; `/v1/sync` answers 404.** Harmless, as the
next poll gets 410. CONFIRMED.

Tests:

**R-42. Mutations that survive.** CONFIRMED by a reader's run. No save after an activity's decision
(`Bridge.swift:632`); a route set with the call off (`:660`); New conversation closing the open line
(`:200`, pre-existing, and `SECURITY.md`'s advice leans on it); a pre-sync file's count
(`Continuity.swift:72`); a gap noted during a join (`link.ts:87`); a claimed turn closing the
follow-up (`turns.ts:196`); `approval = null` at the turn's end (`register.tsx:613`).

**R-43. Tests that pass for the wrong reason.** `aPermissionPromptOutsideATurnIsNotReported` passes
with its guard removed, most likely because `typedTurn(null)` throws into `.catch`. The `isError`
branch at `register.tsx:643` changes nothing.

**R-44. The mod's pause tests run against a TypeScript copy of `admits`** (`fake-bridge.ts`), so a
change to `Continuity.admits` leaves them green; and hook order is scripted, so no test pins the
engine's. Task 8 was a one-off.

**R-45. `anOlderAppWithNoSyncRouteTakesTheTurnAsBefore` is thin.** It checks working and idle only:
no gap, no rejoin, no typed question. So R-39 is untested.

**R-46. Several behaviours in one test.** At least seven, among them
`aSyncedLineIsRedactedClippedAndCodeFree`, `needsContextHoldsForEachCause`,
`forgetKeepsAPauseAndItsDecision`. Five assertions pin line wording ("code or a table only" twice,
"allowed" three times).

Efficiency:

**R-47. Each synced line saves `continuity.json` twice.** `Bridge.swift:706`, then `addSynced`'s
`record`. An owner's turn goes from 0 saves to 4. A reader measured 0.7 ms to 12 ms a save, so CPU
does not matter; at 4 turns a minute it writes 2 to 20 MB a minute. **Resolution:** in `sync`, save
only on the paths that do not reach `addSynced`.

## The checks asked for

**`questionRoute` across a target change.** Sound for Stop, ×, a keyboard answer, a reply consumed
by a handoff, `/clear`, and a pause at the limit (kept only with a question pending). Not sound
across a target change: R-1, R-2, and the leftovers R-15, R-16, R-17.

**The withheld request and `Completion`.** Sound. A reader's mutations of the withholding code were
all caught. `.ok`, `.question` and `.failed` all close as failed with none of the text, and `latest`
clears. `.update` is dropped. Timeout, session left and restart leak nothing. Questions and
approvals in that turn stay out, and `isAsking` stays false, so no reply reaches them.

| Result | Status to the mod | Said | Recorded | Gap |
| --- | --- | --- | --- | --- |
| Delivery, call on | 200 | yes | yes | no |
| Delivery, call off | 200 | no | yes | no |
| Superseded | 200 | no | `[CLAUDE]` | no |
| Superseded, failed | 200 | no | no, holds no answer | no |
| Dropped | 200 | no | no | no; `paused` already set |
| Unknown or stale id | 409 or 404 | no | no | yes, the mod notes one |

Its faults are over-reach: R-13, and a request waiting behind a typed turn, which the PR discloses.

**`POST /v1/sync`.** The three move together: every new field and route is in `Wire.swift`,
`wire.ts` and `wire/fixtures/`, tested on both sides, with example ids only. `Work.reply.forRequest`
is required in Swift and optional in TypeScript, for older apps, which is right. Gaps: R-39 to R-41.

What a local client can do: any process running as you can call it, as with every route;
`label(of:)` checks only that the session is joined. It gives **no route to Claude**: `/v1/sync`
creates no `Work`, and Claude receives text only through a voice handoff. It can feed `addContext`
on an open line, record lines with no call running, and persist up to 64 lines. `/v1/context` and
`/v1/activity` could already put any text at `user` rank, persist it and open a closed line. New for
such a process: the `[TYPED]` label reads as the owner's, a `.owner` line satisfies `opensLine`, and
a `from: owner` post under the pause fails a voice request in flight. `SECURITY.md` lists the first;
the other two are trivial for a process that already runs as you. The body is capped at 131,072
bytes, and `from` is an enum. Every text path goes through `AnswerShaper.line`, redacted before the
cut, apart from the title (R-29). Brackets and line breaks are neutralised: a run of `[RESULT]`,
`［TYPED］`, `⟦FAILED⟧` and others gave only parenthesised text on one line. `SECURITY.md` rightly
says this is not a control.

**LiveBridge never answers a permission prompt.** Holds in the code. There is no `tool.check` hook
and no decision field. The widened `classic.PermissionRequest` returns `next(e)` untouched, and
every `classic.*` hook does. `tool.call` returns its own result only for a spoken reply, only inside
AskUserQuestion, only for the main loop. A permission activity carries no `question`, so `isAsking`
goes false, and a later handoff is an ordinary request that goes in as a new prompt. So an
`[APPROVAL]` line's text cannot produce an answer. `SECURITY.md`'s carve-out for questions is
stated, and this PR extends it to typed turns. One limit: ADR 0001 (m) says a voice prompt delivered
mid-turn was not observed, so "the terminal does not take it as an answer" is inferred from the
engine's design.

**Docs must not claim more than the code enforces.** R-8, R-9, R-10 are the Important ones; R-23,
R-24 and R-29 to R-38 the rest. `SECURITY.md` is honest on what matters most: the voice prompt
"enforces nothing", a page can steer the voice while you type, and a steered voice can answer a
typed turn's dialog. The loop is wider than before, since a typed turn's answer now reaches the
voice live, and it says so. Nothing stops a handoff with no owner speech: `Bridge.route` has no such
check, and the 3 runs in ADR 0001 (o) tested `[TYPED]` lines, not `[CLAUDE]` or injected text. The
translations carry every changed passage and state nothing differently; they inherit R-9, R-10 and
R-4's sentence. That is a reader's check, not a native speaker's.

**The PR's deferred minors.** Graded too low: `settles` (R-6), `POST /v1/target` (R-2), and "every
time" (R-33). The rest stand. The `isCurrent` one, tasks not counted, is real but narrow.

## The three passes

- **`superpowers:requesting-code-review`:** with fixes. Four independent readers; findings verified.
- **`simplify` (report only):** reuse: little. Simplification: S-1 to S-11. Efficiency: R-7, R-47.
  Altitude: the design section above.
- **`security-review`:** no finding at the skill's bar of exploitability. R-29 and R-30 are privacy
  promises in docs, not vulnerabilities. No new route reaches Claude, and the permission prompt is
  unaffected.

## Still open: what only the owner can do

- **A real run in the desktop app:** one typed prompt, then read the mod's origin. It settles R-10.
- **Voice, after R-3:** lines 5 and 6 of the manual table, and F1's fix.
- **Load context in the real menu**, which was never seen: macOS refused accessibility.
- **A real model on this branch.** All of Claude's text in the manual check was canned.

## Verdict

**Merge after fixes.** In order:

1. The owner rules on R-1, then R-1 and R-2.
2. R-4, R-5, R-6, R-7, the code that keeps the voice honest.
3. R-3, then the voice lines it needs.
4. R-11, one test.
5. R-8, R-9, R-10, words, with the status taken back to "delivered in part".

The wire change above is worth deciding before release, while the shape is free. It is not a
condition of this merge, but R-13 and R-18 go with it. S-1 to S-8 and the duplicate tests are the
cheap way to take about 150 lines off while those files are open.

## Re-review at `677dbf9`

Scope: `git diff c482d4b..677dbf9`, past PR 39's files: 14 source files, +557 -320, and 17 test
files, +1305 -481. Report only.

**Verdict: not ready. Three things block, all small: Re-1, Re-2, Re-3.** Nothing is Critical. The
fix round did what it set out to do: R-1 to R-7 and R-11 hold, and the wire change is the right
one. The blockers are one defect from the PR, a test gap on the moved route, and docs that now claim
more than the code does.

### How this was checked

- Swift 581 pass on an export of `677dbf9`. On a copy, mod unit 70 and engine 176 pass.
  `check` passes in CI at this head, and CodeQL's Swift analysis was still running when read.
- My probes, ported to the new wire: `p1`, `p2`, `p3`, `p4`, `p5`, `p6`, `p7`, `p9`, `p10`, `p11`
  now pass. `p8` still fails: eviction loses a paused mark, a limit `SECURITY.md` states.
- `repro.test.tsx`, unchanged, on the harness: all fixed. A says "settled", not "allowed". B claims
  nothing. C and D write a fresh summary after a gap. E keeps the poll's work. G fails the reply
  and leaves the second question open. N sends no activity under an open question.
- Redaction, through `AnswerShaper.synced`: 16 KB of hex takes 0.00 s, down from 18.67 s, and
  128 KB takes 0.04 s. The worst text found at the mod's 32,000 limit is `eyJ-` repeated, 1.23 s,
  then a PEM header repeated, 0.45 s. So the PR's 1.2 s and 0.4 s are right.
- Mutations of the new lines: Swift 47 of 66 caught, mod 45 of 50. R-11's mutation is now caught
  by `anOtherSessionsLineStaysOffTheOpenLine`.
- Two independent readers, given the code and not this review, one on the app and wire and one on
  the mod and the removed tests. I reran their probes. Each finding says if it was only read.
- Not run: voice, `scripts/smoke.sh`, the desktop app, `/Applications`. One reader made a single
  `claude -p --model haiku` call to compare real hook payloads, which spent a few tokens; nobody
  asked for that, and it is disclosed here.

### What the fix round settled

| Finding | State at `677dbf9` |
|---|---|
| R-1, R-2 | Fixed, for the menu and `POST /v1/target` by one path (`pickTarget`). `p1`, `p2`, `p7` pass. A waiting question leaves the queue and stays recorded for its session's seed. |
| Route at a pause | A pause keeps a route only while its question waits (`CallMachine.pause`). Behaviour right; its test cannot fail (Re-2). |
| R-3 | Fixed: the voice is given it to say (`p10`). The owner's rerun shows it did not change line 6, which the PR says plainly. |
| R-4 | Fixed: a `report` line for every non-voice turn with no answer. |
| R-5 | Fixed for the app's own asks (`p3`, `p11`). The corner is in Re-5. |
| R-6, R-19 | Fixed: prompts held by agent, tool and input. Reproductions A, B and N agree. |
| R-7, R-47 | Fixed, see the timings above. |
| R-11 | Fixed. |
| R-12, R-13, R-18, R-40, R-41 | Closed by the wire change. `p5` passes. |
| R-15, R-16, R-17 | Fixed; R-17 by half, as the PR says. |
| S-1 to S-8 | All done, checked in the code. |

**The wire.** `Wire.swift`, `wire.ts` and the fixtures agree. An older mod works as the spec says:
`git show origin/main:plugin/hooks/register.tsx` reports only voice turns, with no `turn`, so
nothing refuses it, and `syncs` false keeps asking for a summary. The exception is Re-1.

**Permission prompts.** The boundary holds. No hook in `plugin/hooks` returns a decision, a
`report` line cannot refuse or answer anything, and `AskUserQuestion` stays the only tool a spoken
reply can resolve.

**A local client on the socket.** Nothing new of weight. `kind: typed` with `turn.request` lets a
peer withhold a request under the pause, and `POST /v1/target` lets it drop a waiting question.
Both are within what a same-user peer could already do. Redaction's bound leaves a key name over
64 characters past the keyword unmasked, which is fine.

### Important

**Re-1. A spoken reply can create a request nothing answers.** `SessionRegistry.swift:169`,
`plugin/hooks/turns.ts:250`. CONFIRMED, by a reader's probe and its control, rerun here. New in this
PR, not in this round: `main` has no such line, and my first review missed it.
Scenario: a voice turn runs past the 10-minute request timeout, as a long turn does, then Claude
asks and the owner answers by voice. `poll` finds nothing in flight, so the reply becomes the
request in flight. `replied` returns at once because the turn is a voice turn, so the turn's answer
still goes under the timed-out request and gets 409. The phantom then holds every later voice
request in that session for up to 10 minutes, with nothing said. The control, with the request
still in flight, passes. The tracker should take the new id when `forRequest` is not its own. A
released mod has no `replied`, and fails the same way against this app (traced, not run). An app
restart mid-turn should do the same (not run).

**Re-2. The route moved into `CallMachine`, and its tests do not hold it.** `CallMachine.swift:178`,
`BridgeTests.swift:1120,1135`, `Bridge.swift:640,653`. CONFIRMED by mutation, repeated serially.
`CallMachineTests` has no route test at all. These survive all 581 tests:

- Dropping `line.asks`: any result routes the next handoff to its session, the wrong-session bug
  this round closed.
- `endSaidQuestionRoutes()` removed from `pause`. `aQuestionAlreadySaidLeavesNoRoute` cannot fail:
  `poll(a) != nil` at `:1135` is met by a `.context` poll before the handoff lands, and then
  `poll(b) == nil` passes too. It must expect `.request(request(2))`.
- `.first` for `.last`, no dedupe, popping one route instead of all, no `rename`: the stack's own
  rules, and the survival of a route across `/clear`.
- `Bridge.swift:653` without `turn.request == nil`: a voice turn's question in a non-target session
  from today's mod would be recorded only. The spec says it keeps today's behaviour, and every test
  of that path sends no `turn`, which only a released mod does.
- `Bridge.swift:640` deciding on `working` and `idle` too, which could leave a settled question
  unwithdrawn.

These are this review's focus and the fix for R-1, so a pure test of each belongs in this PR. It
is about 40 lines.

**Re-3. The docs promise the behaviour the round removed.** `SECURITY.md:218-219`,
`CHANGELOG.md:25-27`, `README.md:273-274`. CONFIRMED, `n5`. See "The pause" below. `SECURITY.md`
says a waiting request "is withheld as well", the changelog says "(or waiting behind it)", and the
README says typing fails a request "in flight in that session", which is what a waiting request is.
`n5`: a request polled before Stop, a refused typed turn, and its answer quoting the paused text is
recorded with the call off. AGENTS.md: docs never claim more than the code enforces. Also still open
from the first review, and the orchestrator's to apply with this: R-9 (`README.md:301,311`,
`CHANGELOG.md:16`), R-10 (`README.md:304`), and R-29's line, which the PR says the docs must carry
and `SECURITY.md` does not.

### The pause and a waiting request

Consistent with the setting's promise once Re-3 is fixed. `SECURITY.md:212` already says a later
turn's answer can quote paused text, and that is what this is: the session holds the text, whatever
the voice was told. The difference from a later request is real, though. A later request is one
the owner makes after the pause; a waiting one was made before the text was typed, so its answer
arrives unasked and goes into the seed with the call off. I would keep the new behaviour: the old
one cost a false failure (R-13). The docs should state that difference in one sentence.

### Is R-5's corner described truthfully?

Mostly, and it reaches a little further. Rerun as `n1` and `n2`.

- The PR's "a 60 s window on an explicit command" is true.
- `docs/specs/2026-11-05-conversation-sync-design.md:168` says the chain needs "a line, Stop and
  typing". It does not: `n1` needs only the pause on, the call off, and typing during the owner's
  own `/live context`.
- It is also narrower than stated: a refused turn's later line marks `paused` again, so the mark
  stays cleared only if the turn's last line lands before the summary.
- It reaches further than the paused mark: `n2`, a `/live context` crossing **New conversation**,
  brings back what was forgotten. The spec's general sentence covers this, but neither the PR nor
  `SECURITY.md:228` says so.

Accepting the corner is reasonable. These are Re-5, words only.

### The removed tests

No behaviour lost its only test to the deletions. A reader mapped all 19 to the test that still
pins each (8 Swift, 9 tracker, 2 limits) and mutated each line; the table is in the proofs folder.
The PR's claim holds. Five more went in the same round with successors or with their getter: four
`aSnapshotThatFails…` and `onlyARunningVoiceTurnIsRunning`.

Two near misses:

- A rename, not a deletion, lost one: `aRefusedClaudeLineWithholdsNoAnswer` became
  `aRefusedStartWithholdsNoAnswer`, so nothing pins `body.kind == .typed` at `Bridge.swift:706`
  against `answer` or `report` (Re-11).
- `aWeekOnlyListIsSent` was the only guard of `register.tsx:599`'s `five_hour` gate, for a line
  that does not exist today. Harmless.

### The PR's rejections

| Finding | Rejection | My view |
|---|---|---|
| R-24 | Narrow | Agree on the code. `SECURITY.md:221-222` names slash commands only; a voice turn starting in between does the same. One clause. |
| R-25 | Unobserved | Agree: a wrong guess withdraws a live question. |
| R-29 | A change of its own | Agree it need not be fixed here, but the docs must list it, which is Re-3. |
| R-42 | Taste | Half. The route-while-off mutant is now caught. `activity no decision save` still survives, and the rest moved into Re-2. |
| R-44 | Price of the harness | Agree. `fake-bridge.ts` tracks the rewritten `admits` line for line at this head. |
| R-45 | Taste | Agree. The new mod's only extra against an older app is an unknown field. |
| R-46 | Taste | Mild disagreement: AGENTS.md says one behaviour, one test, so it is a rule. The three named tests remain. Not a blocker. |

### Minor

**Re-4. A second ask keeps the first's clock and stale bit.** `Continuity.swift:118-125`. CONFIRMED,
`n3` and a reader's probes. An ask lives 120 s and the mod gives up at 60 s. Ask, gap, the mod drops
its send, press again at 70 s: the fresh summary is ignored, a model call is spent, and the menu
says Loading until it times out. Asks at 0 s and 100 s, gap at 125 s, summary at 130 s: taken,
though asked before the gap. `/live context` meanwhile says "Sent a summary" for one the app
dropped.

**Re-5. R-5's corner is worded too narrowly and too widely.** See above.

**Re-6. An ask is not saved.** `Bridge.swift:178`. CONFIRMED by probe. Press Load context, restart,
type under the pause: the summary finds no ask, is taken and clears `paused`.

**Re-7. A held summary is lost across `/clear`.** `Bridge.swift:419`. CONFIRMED by probe. This
round's `lineSession` comparison: `heldContext.session` keeps the old id, so the line never gets the
summary while the stored context says it has.

**Re-8. A hook saves between reading state and taking its queue slot.** `register.tsx:499,704`.
CONFIRMED on the harness, probes P1 and P2; engine timing not observed. A question's hook can run
inside that save: the bare `approval` or a `working` then lands last and takes the question back,
so a spoken reply queues behind the blocked turn. Take the slot first, then save.

**Re-9. `/live off` can be undone by a save in flight.** `register.tsx:90-93`. CONFIRMED on the
harness, P3. A regression from `6ee807c`: the key is read, `turnCount` is awaited, then `set` writes
back a key the leave deleted, and a reload joins with no owner action. Read the count first.

**Re-10. A fresh ask joins a send a gap ended.** `register.tsx:389`. CONFIRMED on the harness, P4.
`sending` stays set until the dead send returns, so the ask fails with "could not summarise".

**Re-11. Which request a refusal withholds.** `Bridge.swift:706`, `SessionRegistry.swift:204`.
CONFIRMED by probe and mutation. See the near miss above. Also, a typed turn that names R0 after a
spoken reply withholds R0, whose own answer then fails, where the spec's "the request the turn names
closes" and "only waits behind keeps its answer" collide. Pick one sentence.

**Re-12. A lost question can note no gap.** `Bridge.swift:637`, `link.ts:134`. Read, not run. An app
just restarted answers `activity` 200 for a session it does not know, so the mod takes it as
delivered. `6f893e8`'s "the app did not take it" holds only for an unreachable app.

**Re-13. A reload drops queued posts with no gap.** `register.tsx:614,648-649`. Traced, not run. The
snapshot is saved before the post is queued. The old code lost posts the same way, in a shorter
window.

**Re-14. `classic.PermissionDenied` is unpinned.** `register.tsx:716-722`. CONFIRMED. Rewritten this
round, no `save` after `promptRan`, and a no-op of the handler fails no test; neither does removing
the `PostToolUseFailure` settle at `:713`, or dropping `nothingWaits()`.

**Re-15. The snapshot stores whole tool inputs.** `turns.ts:153`. Read. A large Write or a command
with a secret sits in the mod's store until the prompt settles, and past the store's cap the
`.catch` hides the failure. A hash matches as well. The input is in the session's transcript anyway.
A prompt with its input rewritten keeps the row on `approval` through the run and then says
"settled", as the PR says; one reader's real run saw Edit, Write and Bash inputs byte-identical on
both hooks, so it takes a real rewrite.

**Re-16. `hasOpenRequest` ignores `reply`.** `SessionRegistry.swift:81`. CONFIRMED by probe, new in
this PR. A reply to a typed turn's question, not yet polled, and the session leaves: no failure is
said, and by reading the line then waits out its 120 s.

**Re-17. Other mutations that survive.** Waiting approvals of a dropped session (both ways); an auto
ask not noted, so R-5's fix is pinned for the menu only; `askLife` halved; `lineKnowsSession` in
`addSynced` and in `onOwnLine`; `tasks` by the old session; `promptGone` once; step text over a
question; a saved snapshot's `at(-1)`. One mod survivor is equivalent: `post` and `sync` are never
both set.

### Is it elegant? Is anything redundant?

**Yes, more than at `c482d4b`.** The app has a real turn now, which was the root of most findings:
`typedTurn`, `isAnswerWithheld`, the `hasOpenRequest` guess and `activity`'s second check are gone,
and a refusal names exactly its request. The route in the pure machine is at the right height. The
wire cost net +39 lines, so my "likely a net deletion" was wrong, and the result is still worth it.

One piece has the old disease: the summary has no date. `SummaryAsk`, `askLife` and the stale bit
are about 35 lines of guessing which ask a summary answers, and Re-4, Re-5, Re-6 and the corner all
come from that. The same cure as the turn: while the wire is free, the app puts a generation in
what the mod reads, bumped at each gap and forget, and the mod echoes in `ContextBody` the value it
read when it started writing. That dates `/live context` too, and all of the above goes. **Worth
deciding before release, not a condition of this merge.**

Redundant, small:

- `sync`'s `guard admitted, await addSynced(…) else { save(); return }` hides a plain `if`.
- `pause` carries `questionRoutes` around `end` as it does `unheard`; `end` could keep both.
- `.deliver` has two facts the bridge computes. Fine for now; a third wants a struct.

Nothing large is left to remove. The two queues, `inOrder` and `serial`, earn their place: the
comment's reason is right.

### Verdict at `677dbf9`

**Not ready. Fix in this order:**

1. Re-1, a few lines in the tracker and a test.
2. Re-2, about 40 lines of tests, one of them correcting a test that cannot fail.
3. Re-3 with R-9, R-10 and R-29's line, words.

Worth taking with those, as each is a line or two: Re-8, Re-9, Re-6, Re-7. The rest can follow.

Still open and the owner's alone, unchanged: one typed prompt in the real desktop app (R-10), a real
model on this branch, Load context in the real menu, and the voice's announcement of a permission
prompt, 0 of 3 before the keyboard answer.
