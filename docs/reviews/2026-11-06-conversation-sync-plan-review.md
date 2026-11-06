# Review of the conversation sync spec and plan

- Under review: [the spec](../specs/2026-11-05-conversation-sync-design.md) and [the
  plan](../plans/2026-11-06-conversation-sync.md), both at `f6f7db1`, before any code exists.
- Read against: `origin/dev` at `0243a42`, which has Mute (PR #36) merged. Code line numbers are
  from that commit. Plan references are `plan:<line>`; the spec is cited by section.
- Skills: `superpowers:requesting-code-review` (an independent reviewer seat plus my own read),
  `stayfixed:review-plan-three-lenses`, `simplify` (four seats, report only, nothing applied) and
  `security-review` (one finder). Every finding below was traced by me in the code; what the seats
  raised and I rejected is under [Rejected](#rejected).
- Also: the engine's type file for `prompt.submit` (2.1.309) and the Claude Code hooks reference for
  what a person's denial fires.
- Not run: the build, the tests, `scripts/smoke.sh`, any voice probe. This is a reading.
- Lint: `stayfixed plan check` fails with 4 problems (M-1). `stayfixed docs check` passes.

## Verdict

**Not ready for Wave B.** 4 Critical, 14 Important, 13 Minor.

The architecture is sound and the fixes stay inside the existing tasks: the mod sends and the app
decides, the machine stays pure, one count covers the roll-off. Two things must change before
dispatch:

1. **The pause is enforced where lines are recorded, and nowhere else.** The plan's own contract
   (plan:76-77) says a paused line must never be recorded. Three legitimate flows break it (C-1,
   C-2, C-3), and in all three the paused text reaches OpenAI on the next line with nothing more
   from the owner.
2. **The spoken reply in a typed turn fails in the exact workflow this feature is for**, typing and
   talking at once (C-4), and read literally it breaks every spoken reply in a voice turn.

Three items need the owner's ruling because they change the spec: C-1 (a turn's keyboard answers),
C-4 (a spoken reply while a voice request waits), I-10 (what an `autoContext: false` owner gets).

## Findings at a glance

Verdicts are the lens skill's: **critical** (does not proceed until resolved), **fix before
dispatch** (the plan text changes), **fix in the task** (the implementer is told).

| ID | Severity | Lens | Task | Finding | Verdict |
|---|---|---|---|---|---|
| C-1 | Critical | Boundary | 3, 5 | Owner text typed after Stop into a running turn is recorded | critical |
| C-2 | Critical | Boundary | 3, 6 | New conversation or × erases `paused`; the next line summarises the paused text | critical |
| C-3 | Critical | Boundary | 3, 6, 9 | A turn the app never saw under the pause is *missed*, which auto-loads a summary | critical |
| C-4 | Critical | Premise | 7, 8, 9 | Spoken reply with a voice request waiting loses the answer; `adopted` can break a voice turn | fix before dispatch |
| I-1 | Important | Premise | 8, 9 | A prompt typed over a running turn: no step says how, and it may post twice | fix before dispatch |
| I-2 | Important | Boundary | 8, 9 | Every unknown origin becomes the owner's words | fix before dispatch |
| I-3 | Important | Premise | 7 | A non-target typed question leaves `isAsking` set | fix before dispatch |
| I-4 | Important | Oracle | 6, 9 | An equal cached summary resets the count and reports current | fix before dispatch |
| I-5 | Important | Premise | 9 | No hook reports a person's denial; the denied line is dead and the next prompt is swallowed | fix before dispatch |
| I-6 | Important | Oracle | 1 | The probe skips the riskiest cases, and its pass bar cannot separate them | fix before dispatch |
| I-7 | Important | Oracle | 5 | The seed test cannot reach its state; the after-seed case has no test | fix before dispatch |
| I-8 | Important | Premise | 6, 8 | Updating a running session hides a gap | fix before dispatch |
| I-9 | Important | Premise | 3, 8 | A background turn is decided at its end, not its start | fix before dispatch |
| I-10 | Important | Boundary | 6 | An `autoContext: false` opt-out is dropped silently at update | fix before dispatch |
| I-11 | Important | Premise | 9 | A lost voice answer notes no gap | fix in the task |
| I-12 | Important | Boundary | 10 | SECURITY.md sentences that become false are outside Task 10; the planned mitigations overclaim | fix before dispatch |
| I-13 | Important | Boundary | 5 | Pasted `.env` shapes pass the redactor; `prose` on owner lines is unstated | fix in the task |
| I-14 | Important | Premise | 3 | Seeds now sit at a limit nobody has tested past, and Cyrillic may exceed it | fix before dispatch |
| M-1 to M-13 | Minor | mixed | mixed | See [Minor](#minor) | fix in the task |

## The seven questions

### 1. Can a paused line reach the conversation or OpenAI?

Yes, by three paths. Every other path holds.

| Path | Result |
|---|---|
| `/v1/sync` of a refused turn | Holds: `admits` runs before `record` |
| `Bridge.say` for a refused turn's question or approval | Holds on the `(false, true)` edge (plan:392); see M-2 for `(true, true)` |
| A held line | Holds: Stop resets the machine (`CallMachine.swift:296`) |
| A question or `isAsking` of a refused turn | Holds if `setActivity` moves below the check: `Bridge.swift:522` runs it first today (M-2) |
| Claude's line of a refused turn | Holds, unless the decision was erased (C-2) or was never taken at the start (I-9) |
| Owner text typed after Stop into an admitted turn | **Fails:** C-1 |
| New conversation, ×, eviction | **Fails:** C-2 |
| A turn the app did not receive | **Fails:** C-3 |
| A summary in flight | A narrow window: it clears `paused` without carrying the text (M-3) |
| A later answer repeating paused text | No code can stop this; the docs must say so (I-12) |

### 2. Does a synced line land exactly once?

Yes, for ordinary lines. `sync` records and sends `.synced` with no suspension between them, and
`send` reaches `machine.handle` before its first await (`Bridge.swift:255-257`). The plan's seed
stretch reads the conversation and calls `dropSynced()` with no suspension either, once
`registry.openTasks` moves above it. So a line recorded before the stretch is in the seed and its
held copy goes; one recorded after is held only. `lineKnowsSession` is true from before the seed.

Two caveats: a cancelled `openLine` can reach `dropSynced()` after a newer line was seeded (M-4),
and the test meant to prove this cannot reach its state (I-7).

### 3. Does the one rule for roll-off hold, and does it cost needless summaries?

The arithmetic holds: the newest lines are the ones seeded, so "count since the summary ≤ talk lines
carried" is the right test, and the count survives roll-off where `lines.count` would not. Handoff
lines are excluded on both sides. It ignores `tasks` and `unheard` (`initialItems(tasks: [])`), so
open tasks can push a line out while it reads current; that is small and acceptable.

It costs fewer model summaries than today: `autoContext` defaults to true (`Settings.swift:24`), so
today every line asks. With full-length answers, expect one summary per 14 or so typed turns.

The rule has one real hole: a cached summary resets the count without carrying the lines (I-4).

### 4. Is `POST /v1/missed` with `JoinBody.syncs` the simplest correct shape?

`syncs`: yes, and the choice over `modVersion` is right. Tags reach v0.3.0, so older mods exist, and
a version floor would mark every dev build before the release as old. The plan's note at plan:328 is
stale, though: the spec no longer names `modVersion` (M-11).

`/v1/missed`: no. A `missed: true` field on `JoinBody` is simpler (M-5). It removes the route, the
body, the fixture, `BridgeLink.missed()` and the "404 means an older app" rule, which is also a
small bug: a 404 for an unknown session reads as an older app and loses the gap.

### 5. The spoken reply in a typed turn

The happy path holds: no request in flight, `poll` puts the reply in flight, the mod adopts, the
final answer closes it and is spoken. Review Focus 4 is covered by `tick` posting `failed`.

It fails with a voice request waiting, and `adopted` needs a rule for voice turns (C-4). Three
smaller gaps: `adopted` must save (M-6), an adopted turn gets no follow-up window (M-7), and the
`latest` overwrite can drop a newer queued request's answer (M-8).

### 6. Questions from a typed turn, phase by phase

| Phase | Target | Other session |
|---|---|---|
| off | recorded; `opensLine` unused; no route. `isAsking` true, so a later handoff answers it. Holds | recorded; **`isAsking` true** (I-3) |
| listening | `deliver` with `opensLine` true once an owner line exists; `isAwaitingFirstWord`. Holds | same as off |
| connecting | unheard, given on connect; `withdraw` closes a line opened only for it. Holds | same as off |
| live | added now; `says` removes it when heard. Held lines stay behind it (M-9) | same as off |

`withdraw` needs no change: the `(true, false)` edge fires for typed turns as for voice turns, and
the closed line drops its held lines, which the conversation already has. `questionRoute` holds if
the target check comes first (plan:393 says so). `opensLine` holds, but a typed line now satisfies
its `.owner` test, so every non-refused typed question opens a billed line (accepted by the spec),
and a non-owner origin can satisfy it too (I-2).

### 7. Does every behaviour have a task, and is any step readable two ways?

Spec coverage is good, with two gaps: the denied line cannot be built as written (I-5), and "every
turn" in the gap tracking misses a lost voice answer (I-11).

Steps an implementer could read two ways, each listed with its finding: how `prompt.submit` with a
`turnId` is handled (I-1), `adopted` on a voice turn (C-4), `prose` on owner lines (I-13), the
`from` of keyboard lines (M-10), whether a refused line re-marks `paused` (M-3), the menu title
during `.loaded` (M-12), and what changes in `ContextLoads.swift`, which Task 6 lists with no step.

## Critical

### C-1. Owner text typed after Stop into a running turn is recorded

**Evidence:** plan:194-196, plan:207-208 (`aSyncedTurnStaysAdmittedOnceThePauseStarts`), plan:467;
spec, "A turn's sync is decided when it starts" and "press Stop, then type"; `prompt.submit` docs: a
prompt "typed while a turn ran" fires "at Enter, with that turn's id".

**Sequence:** a typed turn starts with the call on, so it is admitted. The owner presses Stop, with
the pause on, and types the next prompt. It posts under the running turn's id, `admits` returns
true, and the text is recorded and seeded into the next line. A free-text keyboard answer takes the
same route. The plan's test pins this as intended, and plan:76-77 forbids it.

**Resolution:** the turn's decision stays for `from: claude`. A `from: owner` line also checks
`pausing` at arrival; refused, it marks `paused` and flips the turn to refused, so an answer that
may echo it stays out. Replace the test with two. **The spec's sentence covers "its keyboard
answers" too, so it needs the owner's ruling.**

### C-2. New conversation, or ×, erases `paused`

**Evidence:** plan:67 ("decision and state gone"), plan:187-189, plan:214; `Continuity.swift:103`,
`:116`; `Bridge.swift:196-200`; spec: "never after a pause"; `SECURITY.md:153-154`, which already
warns that New conversation does not stop a reload.

**Sequence:** pause on, Stop, type a secret; the session is `paused`. The owner presses New
conversation, the button the docs recommend. `forget` removes the flag with the conversation. Start:
`opensWithSummary` is true because there is no context, the mod forks the model over the whole
transcript (`context.ts:17`), and the secret reaches OpenAI. If the paused turn is still running,
its answer also arrives with no stored decision and is admitted afresh.

× then `/live on`, eviction past 20 conversations and an undecodable file reach the same state.

**Resolution:** one rule, shared with C-3:

1. While `pausesSync()` is on, no line asks for a summary; only Load context and `/live context` do.
2. `forget` clears lines and context but keeps `paused` and the turn's decision.
3. Add a test: pause, a dropped turn, New conversation, Start, no `.context`.

### C-3. A turn the app never saw under the pause counts as *missed*

**Evidence:** spec, "Out of sync has two causes" and "Older peers"; plan:197, plan:339, plan:354,
plan:479, plan:488-489.

**Sequence:** with the pause on and the call off, each of these ends in an automatic summary of the
transcript, paused text included:

- `/live off`, type, `/live on`: `turnOn` reports a gap.
- The first `/live on` in a session with turns.
- The app is down during a turn, as in a relaunch after an update.
- A session on an older mod: `paused` can never be set, so "unless paused" (plan:354) never fires,
  while the setting's caption says the turns stay out.

"The mod sends, the app decides" does not hold here: the mod picks the cause.

**Resolution:** C-2's first rule covers all four. Also, `missed` while the setting is on marks
`.paused`. Use the setting alone there, not `pausing`: the report may arrive after Start.

### C-4. The spoken reply with a voice request waiting, and `adopted` on a voice turn

**Evidence:** plan:372-373, plan:387-388, plan:395, plan:418, plan:491-492;
`SessionRegistry.swift:147-151`, `:163-179`; `register.tsx:499-504`; `turns.ts:76-77`.

**(a) The sequence.** A typed turn runs. The owner speaks request Q; `poll` puts it in flight and
its prompt waits behind the turn. Claude asks a question, which the widened guard now lets through.
The owner replies by voice. `inFlight` is Q, so the reply is not put in flight, but the mod calls
`adopted(reply.id)` regardless. The final answer posts under the reply's id, `complete` throws 409,
the band shows the false `LOST_ANSWER`, and the answer is neither spoken nor synced. The line waits
up to 120 s, billed.

The test `aReplyInAVoiceTurnLeavesTheRequestInFlightAlone` treats "something in flight" as "a voice
turn", which is exactly what this breaks. Two existing tests pin the state the plan reverses without
naming them: `aTypedTurnsQuestionStaysInClaudeCodeWhileAVoiceRequestWaits`
(`roundtrip.test.tsx:302`) and `aTypedTurnsApprovalIsNotReportedWhileAVoiceRequestWaits` (`:139`).
Plan:470 names only `refusedPromptFailsTheRequestAtOnce`.

**(b) The literal reading.** Task 9 calls `adopted` on every spoken reply and Task 8 does not make
it a no-op for a voice turn. Then every voice-turn reply replaces R's id: R's answer gets a 409 and
R ends in a false "timed out" ten minutes later. `claudesQuestionIsAnsweredByVoice` stops before the
answer, so nothing planned catches it.

**Resolution:** let the app decide, as the architecture says. `poll` still sets `inFlight` only when
it is nil, and tells the mod on the reply that it did; the mod adopts only then. That covers voice
turns, a request timed out in a long voice turn, and an older app, with one source of truth. With a
request waiting, the turn stays typed and its answer syncs as context. **That is an exception to the
spec's "a spoken reply makes the rest of the turn a voice turn", so it needs the owner's ruling.**
If the owner wants the answer spoken there too, the registry needs a second slot beside `inFlight`.

## Important

### I-1. A prompt typed over a running turn: no step, and possibly two posts

**Evidence:** plan:467-468 name tests, Step 3 (plan:487-497) says nothing; engine types: `turnId` is
"the model turn that was running when the prompt was submitted", and "the engine queues every prompt
typed mid-turn"; `register.tsx:458-459`.

`prompt.submit` fires at Enter. If the queued prompt later starts its own turn, `turn.start` posts
it again and the conversation holds it twice. If it folds into the running turn, it does not. The
types do not settle which, and the fake cannot show it. A `task-notification` or `peer` delivery
also carries a `turnId`, and the plan's negative test covers only a voice prompt.

**Resolution:** add the hook to Step 3, gated by owner origins (I-2). Observe the order with a
scratch mod, which spends no voice. If both fire, remember text posted mid-turn and skip it at the
next `turn.start`.

### I-2. Every unknown origin becomes the owner's words

**Evidence:** `turns.ts:27-32`, `:52-55`; `register.tsx:466`; ADR 0001 (m) lists `bridge`, `sdk`,
`scheduled-trigger`, `peer`, `plugin`, `unclassified`; engine types mark `isMeta` prompts.

The default was safe while typed text went nowhere. Now `typed` means `from: owner`: another agent's
message, another plugin's prompt or a scheduled prompt is recorded as `.owner`, shown as **You**,
tagged `[TYPED]`, and satisfies the `opensLine` guard, which until now needed real speech. All lines
already have `user` rank, so no control falls, but the label is false, and "yes, push it" under that
label reads as the owner's consent (`SECURITY.md:50-51`).

**Boundary sentence:** "the owner's-words label comes from `originOf`, which other prompters cannot
move because only the owner's prompts map to `typed`" is false.

**Resolution:** an allow-list of origins seen to be the owner (`composer`, plus what the desktop app
stamps, once observed). Everything else goes without `.owner`: a neutral source, or not at all. Skip
`isMeta`. Apply it to I-1's hook too.

### I-3. A non-target typed question leaves `isAsking` set

**Evidence:** plan:380, plan:393-394; `Bridge.swift:522`; `SessionRegistry.swift:128-129`, `:187`.

Task 7 strips `question` only for a refused turn. A non-target one reaches `setActivity` whole. The
owner switches target to that session and says "run the tests": `enqueue` makes it the reply and the
open dialog is answered with unrelated text, under "the owner answered by voice", for a question the
voice never put.

**Resolution:** strip `question` here too and add "registry not asking" to
`anotherSessionsTypedQuestionIsContextOnly`. The spec is silent on a question still open at a later
target switch: the seeded `[ASKING]` line invites an answer that will then queue as a new request.
Say which is wanted.

### I-4. An equal cached summary reports current when it is not

**Evidence:** `register.tsx:326`, `:496`; `aVoiceTurnKeepsTheSummaryCached`
(`context.test.tsx:175`); plan:99-100, plan:355.

Voice turns do not stale the cache. So voice lines pass the seed's limit, the next line asks, the
mod resends the old summary, and the app clears the state and resets the count. The lines lost from
the seed are in neither, the menu says `Context up to date`, and Load context is disabled: the
anti-goal, exactly.

**Resolution:** stale the cache on every completed turn, which costs a model call only when the app
asks, and reverses `aVoiceTurnKeepsTheSummaryCached`. An equal line then really means nothing
changed.

Voice small talk with no handoff is never in Claude's transcript, so no summary restores it.
Counting it triggers a summary that cannot help. Accepting that is reasonable; say so in the rule.

### I-5. No hook reports a person's denial

**Evidence:** plan:475-476, plan:494-495; ADR 0001 (i) ("Documented only… Not observed"); Claude
Code hooks reference: `PermissionDenied` "doesn't run when you manually deny a permission dialog";
`PostToolUseFailure` "doesn't fire for tool calls rejected before execution", permission denials
included; `Bridge.swift:523-542`. I read these through a summarising fetch; check the wording.

- `You denied <tool> at the keyboard` can never be written: the only event behind it is auto-mode's,
  which shows no dialog. `aDeniedPromptIsSynced` passes because the fake fires what the engine does
  not.
- After a person's "No", nothing settles the prompt. `activity` stays `approval`, the `[APPROVAL]`
  line stays queued, and the **next** prompt in that turn hits `(true, true)` and is silently not
  announced. This exists today in voice turns; widening the guard puts it in every typed turn.
- The docs leave whether `PostToolUse` fires on a denial unsaid, so "allowed" is an inference too,
  and `settles` matches by tool name alone, so a parallel call of the same tool can claim it.

**Resolution:** "You allowed" from `PostToolUse` only, and observe it on a real dialog. Drop the
denied line. Try the next main-loop step as the settle signal: `approval` still set when `turn.step`
starts means the dialog ended without the tool running. That is a hypothesis to observe, and it
spends no voice. Update ADR 0001 (i) with what the observation shows.

### I-6. The probe skips the riskiest cases, and its bar cannot separate them

**Evidence:** plan:120-128; `CallMachine.swift:91-92`; ADR 0001 (n).

It tests one case: fixed lines added at speech start, with an unrelated question. Not covered:

- **An imperative line.** A held `[TYPED] … delete the branch` may be handed off, running the work
  twice. Count a handoff as a failure.
- **Sound with no words.** `.speechStarted` fires on sound (the 90-second noise rule exists for
  this). A cough flushes held lines with no owner words to answer, the unprompted condition of (n).
- **A line opened at `.connected`**, where held lines go in after `flushPreroll`.
- **Seeded `[TYPED]` and `[CLAUDE]` lines at line open.** The voice spoke unprompted there in (n).
- **The shipped wording.** The probe's sentence differs from Task 5's.

The bar: at most 1 of 6. With a true rate of one in three, as (n) saw, 6 runs pass 35% of the time.

**Resolution:** add the imperative and sound-only cases, and use the shipped wording, before asking
the owner to spend the minutes. Report the bar as a band: 0 of 6 proceeds, 1 of 6 runs more.

### I-7. The seed test cannot reach its state

**Evidence:** plan:292-293; `BridgeTests.swift:27-34`: `open` holds **after** the items are built.

`aLineArrivingBeforeTheSeedIsAddedOnce` posts during `holdOpen`, which is after the seed, so the
line is held and added, the opposite of what it asserts. The test that would catch a wrong
`dropSynced`, a line arriving after the seed, does not exist.

**Resolution:** use `FakeVoices.setSlow()`, as `aSeededContextIsNotAddedAgainOnceTheLineConnects`
(`:1057`) does, for the before case. Add an after case with `holdOpen`: once in `added`, not in
`opens`. Mutation for both: move `dropSynced()` to `.connected`.

### I-8. Updating a running session hides a gap

**Evidence:** plan:425, plan:438; `register.tsx:439-442`.

A hot reload or resume loads a snapshot from before sync with no gap and calls `turnOn($, false)`,
so no gap is reported, and the join now says `syncs: true`. A stored context then reads current,
though that session's typed turns never arrived.

**Resolution:** a snapshot without the gap field means a gap. Assert it in `'a snapshot from before
sync loads'`.

### I-9. A background turn is decided at its end, not its start

**Evidence:** plan:194, plan:432; spec, "A turn's sync is decided when it starts".

A background turn posts no prompt, so its first line is its answer. Started under the pause and
finishing after Start, it is admitted. Started with the call on and finishing under the pause, it is
refused and marks `paused`. Both contradict the spec.

**Resolution:** post an empty line at `turn.start` to take the decision. `anEmptyLineRecordsNothing`
already fits if `admits` runs before shaping (plan:307 has that order).

### I-10. An `autoContext: false` opt-out is dropped silently

**Evidence:** plan:346; `Settings.swift:39`; `SettingsView.swift:63-64`, whose caption promises
"Otherwise only Load context in the menu or /live context sends it"; `SECURITY.md:160-162`, which
tells owners to turn it off.

An owner who followed that advice updates and gets: the key ignored, the pause off by default, typed
turns synced, automatic summaries, and no notice, at the moment more text starts leaving.

**Resolution:** map `autoContext == false` to `pauseSyncWhileStopped = true` at decode, which with
C-2's rule keeps summaries manual. Say in the CHANGELOG that typed turns now sync while the call is
on. Test the migration rather than the key being ignored. **The owner should confirm this mapping.**

### I-11. A lost voice answer notes no gap

**Evidence:** spec, "every turn since the last delivered summary"; `register.tsx:501-504`.

A voice answer the app did not take shows a note and no gap. The session stays current.
**Resolution:** `noteGap()` there, with a test.

### I-12. Task 10 misses sentences that become false, and overclaims

**Evidence:** plan:512-520; spec, "Docs in the same change".

| Location | Problem |
|---|---|
| `SECURITY.md:32-36` | "During a voice turn" no longer bounds spoken answers to a question, and a steered voice can now answer a typed turn's dialog |
| `SECURITY.md:66-78` | The peer list lacks owner-labelled lines and forcing a summary |
| `SECURITY.md:80` | The data folder now holds typed text and answers from every joined session, with no call needed |
| `SECURITY.md:126-130` | The line list omits synced lines; "data to relay" does not fit `[TYPED]` (`VoicePrompt.swift:63` too) |
| `README.md:330` | "up to the last 24 lines"; plan:228 raises it to 64 |
| `README.md:333` | "code blocks and tables removed" (I-13) |

The planned mitigations overclaim. "The pause setting with Stop" removes nothing already recorded,
and an injected `[CLAUDE]` line keeps seeding. "Removing the session" holds until `/live on`. Only
`/clear` with New conversation does what it says, and even then `/clear` carries the lines to the
new id.

Say what is stored and how long: 20 conversations of 64 lines as plain JSON under a `0700` folder,
and from the app, an ended session's conversation can be erased only by joining it again. Whether
Time Machine copies it is not tested. Also say that Claude's later answers can repeat paused text.

### I-13. Pasted credentials, and code in owner lines

**Evidence:** `Redaction.swift:21`; plan:90, plan:281; `README.md:333`.

The field rule needs the keyword directly before `:` or `=`, so `AWS_SECRET_ACCESS_KEY=…`,
`STRIPE_SECRET_KEY=sk_live_…` and `DB_PASSWORD_PROD=…` pass. Owner prompts are a new path, and they
are where a pasted `.env` goes. SECURITY.md calls the redactor a convenience, so nothing false is
claimed, but this is the accident it exists for. Plan:282 does not say whether `prose` runs on owner
lines.

**Resolution:** accept a trailing `[A-Za-z0-9_-]*` after the keyword, with those shapes tested.
State that owner lines pass `prose`, and pin both in `aSyncedLineIsRedactedAndClipped`.

### I-14. Seeds now sit at a limit nobody has tested past

**Evidence:** `Continuity.swift:76`; ADR 0001 lines 50-51 ("8,192 estimated tokens"); plan:228.

Until now seeds stayed well under the limit. Typed turns make a full seed routine: 16 full-length
lines reach it. `estimatedTokens` is characters over 4. If codex estimates by bytes, a Russian seed
counts about double there, and the owner works in Russian. Nothing says whether codex truncates or
refuses, and a refusal stops the line from opening.

**Resolution:** read codex's limit at the pinned tag, which costs nothing, and pin the estimate to
it. If that does not settle it, add one full-budget Russian seed to Task 1.

## Minor

- **M-1 Lint.** `stayfixed plan check` fails: no `**Scope:**` line, and three dead references at
  plan:144-145, because the `Create:` list wraps and the lint reads the continuation lines as
  existing files. Add the line and give each fixture its own line.
- **M-2 The `(true, true)` edge.** `Bridge.swift:522` runs `setActivity(body)` before the switch.
  The plan's check is on the `(false, true)` edge, so a question arriving while a subagent's prompt
  holds `approval` sets `isAsking` in a refused turn. Run `admits` before `setActivity`, on any body
  with `typedTurn`.
- **M-3 Refused lines and summaries.** Say whether every refused line re-marks `paused` or only the
  first (plan:195). It must be every one: a summary loaded during a refused turn clears the flag and
  the turn's answer must set it again. A summary written before the paused turn but arriving after
  it clears `paused` with nothing to re-mark: narrow, and safe for privacy, but the menu then says
  current.
- **M-4 Cancelled `openLine`.** It has no cancellation check before the seed
  (`Bridge.swift:349-359`), so a stale attempt can `dropSynced()` a newer line's hold. Add `try
  Task.checkCancellation()` first.
- **M-5 `missed` on join** (see question 4). Strip it from `#joined`, as `owner` is (`link.ts:63`),
  or each rejoin marks the session again. The spec allows this shape.
- **M-6 Saves.** `register.tsx:498` saves before posting, so `postSync` must save on a gap, and the
  race must save after `adopted`.
- **M-7 Follow-up window.** An adopted turn gets none, though its voice prompt promised background
  work is reported. Set it in `adopted`, or state it does not.
- **M-8 `latest` overwrite.** Setting `latest` to the reply's id with a newer request queued drops
  that request's answer as superseded. Set it only with `queued` empty.
- **M-9 `[ASKING]` on a live line** goes in while the typed prompt behind it stays held, so the
  voice puts a question whose context it lacks. Flush held lines before a line that will be spoken.
- **M-10 Keyboard lines' `from`.** The plan never says. `SyncSource` has no honest value for `You
  allowed Bash at the keyboard`. Say `owner` for an answer's free text; settled facts need a third
  source or a fixed choice. Also `keyboardAnswer(first.result ?? {})`: a denied call has no
  `result`, and a throw there re-enters `next(e)` through the hook's `.catch`.
- **M-11 Stale notes.** Plan:262 ("`heldContext` becomes a list") and plan:328 (`modVersion`) cite
  spec text that has changed. "Before Wave B" (plan:24) is done at `0243a42`, and this branch is 31
  commits behind `origin/dev`, so start from there.
- **M-12 Menu.** `ContextLoads.swift` is listed with no step, and the title during `.loaded` is
  open: the three-second "Context loaded" must win over `Context up to date`. A `.current` case in
  `ContextLoadState` gives the item one source for title and enabled state.
- **M-13 Tests.** `aTypedTurnsQuestionOpensTheTargetsLine` needs a prior owner line, or `opensLine`
  is false. `dropSynced()` has no machine test. `aMutedOwnerAddsNothing`,
  `aSyncedLineNeverChimesOrOpens` and `theOldAutoContextKeyIsIgnored` pass with no new logic: call
  them guards. A newer mod against an older app voices typed questions, against the spec's "carries
  on as today"; C-4's fix removes the 409 but not the voicing.

## Is the architecture elegant enough? Is anything redundant?

Yes, it is elegant enough. The split between mod and app, the pure machine, and one count for
roll-off all hold, and `Bridge.heldContext` beside `CallMachine.heldSynced` is not a duplicate: one
flushes at connect and the other at the first word. What is redundant:

- **`opensWithSummary` is derivable.** It equals `!isCurrent && outOfSync != .paused` in every case.
  Keep one stored rule and one expression. With C-2's rule, `openLine` and `needsContext` share one
  helper instead of each carrying `|| !syncs`.
- **`/v1/missed`** goes into `JoinBody` (M-5).
- **`turnCompleted(): Post | SyncLine | null`** creates the trap `aTypedTurnStillStalesTheSummary`
  exists to catch. Return `{ post, sync }` and `if (!post) staleSummary()` stays right, with the
  test and the prose rule gone.
- **`Bridge.context` needs no second path.** Always `setContext` and `save`; condition only the add
  on the line being new. That also keeps `save` from being forgotten on the equal path.
- **`renameMovesHeldLines`.** A held line's `session` is never read after it enters the hold, and
  the label in its text does not change. Rename can leave it.
- **The code-only sentence** in `forVoice` should be shared with `synced`, not copied.
- **`#turns` as a map** is unneeded if main-loop turns do not interleave, which plan:228 relies on.
  A crashed turn left in the snapshot would also make `current` wrong. At least clear stale entries
  at `turn.start`.

**Cost, not a defect:** Task 9's Step 3 packs about ten behaviours into one paragraph and one
commit, against "one logical change each". Split it by behaviour: sync posts, the gap, the widened
guards, the reply, the settle lines.

## Rejected

Raised by a seat, checked, and not taken:

| Proposal | Why not |
|---|---|
| A reply is always the request in flight, whatever was there | It replaces Q, or a voice turn's R, and loses that answer: C-4's failure, wider |
| Number the lines with `seq` instead of reporting gaps | Adds persisted counters on both sides and does not cover turns before the first join; `missed` on join is smaller |
| One `say(_:mode:)` and one hold for all lines | Moves the same state; the two holds flush at different moments. Larger than its gain now |
| Delete `syncs` | Tags reach v0.3.0, so older mods are real |
| Cache the pause decision in the mod | A reload or a background turn has no first post to carry it |
| One list for `unheard` and held lines | `unheard` drives the chime, `replyCanSay` and `says`; a silent flag touches all three |
| Cap and batch held lines | A live line closes after 20 s of silence, or 120 s awaiting a result, so the hold stays small |
| Debounce `save`; cache `isCurrent` | Human-rate writes and a walk of 64 lines: not worth the state |
| "No context" should not ask when fully synced | The spec accepts it, it is cheaper than today's every-line ask, and it covers sessions from before sync. An option for the owner, not a defect |

## What holds

Checked in the tree and correct: an undecodable file starts empty (`Bridge.swift:80`), so the
Optional fields matter; `Bridge.context` returns early on an equal line (`:560`); `Settings` ignores
an unknown key (`Settings.swift:36-46`) and `SettingsTests.swift:80` is the file the plan cites;
`AnswerShaper.maxCharacters` and `ANSWER_LIMIT` are as quoted; `flat` stops a line posing as another
tag, for session text and labels alike; `label(of:)` refuses a removed session with a 404 as
`aRemovedSessionsLineIsRefused` says; Mute's guard `(_, .speechStarted) where isMuted` sits above
the plan's new case, so `aMutedOwnerAddsNothing` holds; the permission boundary is untouched: no
`tool.check` hook, and `answerQuestion` is set only by the AskUserQuestion hook.

## Limits of this review

Nothing was run. The hooks wording came through a summarising fetch. Whether a queued prompt starts
its own turn (I-1), whether `PostToolUse` fires on a denial (I-5), and how codex treats a seed past
its limit (I-14) are open and marked so. Time Machine's handling of the data folder is untested.