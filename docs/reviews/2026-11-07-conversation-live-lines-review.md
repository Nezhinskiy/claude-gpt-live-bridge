# Review: Conversation shows a line as it is spoken (PR 49)

Reviewed: `claude/conversation-live-lines-f7e8a8` at `df40ae9`, against `dev` at `49ec0b6`. Report
only; nothing in the PR was changed. Line numbers are at `df40ae9`.

## Verdict

**With fixes. Nothing blocks a release.** The design holds: a growing line is never saved, never
seeds the voice, never reaches the wire, and every stated call rule still holds in the code. Three
things should be fixed before the merge:

1. nothing guards the claim that the owner's words leave the call alone;
2. one close path leaves growing words behind, with a one-line fix that was tried;
3. the owner's next sentence loses its first words, which no document says.

The real menu during a call is still unseen, by the PR and by this review. One real call with
Conversation open should come before a release.

Is the architecture elegant enough? Mostly. `GrowingLines` is small and kept in the right place,
apart from `Conversation`. Its lifetime is what is not elegant: one reset in `send`, one guard in
`grow`, and a display in `current` that trusts `followTarget` to keep the two sessions equal. Finding
2's fix removes most of that. Is anything redundant? `grow` and half its guard, a second trim, and
one rule told in four documents (findings 8 and 10).

## How it was checked

- **Skills.** `superpowers:requesting-code-review` ran as one reviewer agent, `simplify` as its four
  agents (report only), and `security-review` as one agent. The review below also rests on a trace
  done by hand.
- **Tests.** At `df40ae9`, 264 tests of the three suites that matter passed, and the reviewer agent
  ran all 619 and `swift format lint --strict`, both clean. CI's `check` is green. `scripts/check.sh`
  and `scripts/smoke.sh` were not run here.
- **Mutations.** 20 hand mutations, each run against those three suites (see below).
- **Probes.** 5 throwaway tests of the orderings. They state what happens today and are not proposed
  tests.
- **Evidence.** The frames in `~/.codex/logs_2.sqlite`, read for times, roles and frame types only.
- **Proofs.** The probes, the mutation script and its log are in the shared notes folder, under
  `pr49-review-proofs/`.

## Important

### 1. "Call behaviour does not change" has no guard for the owner's words

`app/Sources/BridgeCore/Bridge.swift:496`, `app/Tests/BridgeCoreTests/RealtimeSessionTests.swift:318`

The old test said the owner's delta is not an event. That line had to go when `.userSpeaking` became
one, and no `Bridge` test took its place. Three mutants of the owner's case pass all 264 tests:

| Mutant | What it would do in a call |
|---|---|
| `.userSpeaking` also sends `.speechStarted` | A delta that trails the owner's voice sets `isSoundOn` after `speechEnded`, so a quiet line runs to the 90 s noise cap, not the 20 s silence, and the owner pays for the rest |
| `.userSpeaking` also sends `.userTranscribed` | The silence timer re-arms on every word |
| `.userSpeaking` also sends `.assistantSpeaking` (the reviewer agent's) | `isVoiceSpeaking` goes true, which holds back an awaited result |

The code is right today. But this is the PR's one stated promise about the call, and a later edit
can break it with everything green. The voice's side is pinned (removing its `send` fails 5 tests),
apart from an empty delta (mutant M13), which keeps its machine event by no test.

**Fix:** a `Bridge` test that a stream of owner deltas neither moves the silence hang-up nor delays a
result arriving among them.

### 2. A line closed by `withdraw` keeps its words, and they join the next line

`app/Sources/BridgeCore/Bridge.swift:296`, `:561`

The only reset is in `send`, on the rule that the phase changes there. `Bridge.withdraw` runs
`machine.withdraw` directly, and that can go from `.connecting` to `.listening`
(`CallMachine.swift:313`).

Failure, from probe `probeWithdrawnLineKeepsItsWordsIntoTheNextLine`:

1. A question opens the line and it connects.
2. A delta arrives, and the question is settled in Claude Code. The line closes.
3. The menu still shows `Voice: Late` on a closed line.
4. The owner speaks: `send` sees `.connecting`, so nothing resets, and the next line's words join on
   as `Voice: Late New`.

**Reach is narrow.** It needs a delta while connecting, and nothing here shows codex sends one on a
line a result opened. The effect is display only. It ranks here because the PR body and
`overview.md` say a growing line ends when the line closes, which is not what the code enforces.

**Fix, tried on a scratch copy:** move the line `if !isLineOpen { growing = GrowingLines() }` from
`send` into `changed()`, right after `followTarget()`. `withdraw` already ends in `changed()`. All
268 tests passed, probes included, and the stale words were gone in both steps. It also lets
`grow` go (finding 8).

### 3. The owner's next sentence loses its first words, and no document says so

`app/Sources/BridgeCore/Call/GrowingLines.swift:29`, `docs/architecture/overview.md:89-91`

`finish` drops everything that speaker has growing. The PR body and `overview.md` give this as a
limit for replies only. It is as true of the owner, and more likely there: the voice is unlikely to start a
new reply inside the 2 s before its last `done`, but the owner's `done` reached the menu 1.7 to 3.5 s
after they stopped (ADR 0001 (r)), so a short pause between two sentences is enough.

Failure, from probe `probeOwnersSecondSentenceLosesItsFirstWords`:

| Event | Menu |
|---|---|
| `" First."`, `" Second one"` | `You: First. Second one` |
| `done` "First." | `You: First.` (the words the owner just said are gone) |
| `" goes on"` | `You: First.`, `You: goes on` |

How often codex splits a turn this way was not measured. This is the owner watching the words they
just said vanish, in the feature that exists to show them.

**Fix:** at least say "a line", not "a reply", in `overview.md` and the PR. Better, if it is cheap:
when the growing text starts with the final text, keep what follows it. The deltas can differ from
the final text, so fall back to today's clear.

## Minor

### 4. A blank delta takes a place in the order

`app/Sources/BridgeCore/Call/GrowingLines.swift:20-25`, `app/Tests/BridgeCoreTests/BridgeTests.swift:2122`

`add` opens an entry for `""`; `lines` hides it but its slot stays. After `assistantSpeaking("")`,
then `userSpeaking(" Hi")`, then `assistantSpeaking(" Hello")`, the menu shows
`Voice: Hello`, `You: Hi`: the answer above the question, until the owner's final text. That breaks
the type's "in the order they started".

The comment says codex can send such a delta after a final text, which is the moment it would
matter. No ADR records that, and none of the 173 deltas in the log is blank, so this ranks low. The
reproductions feed the blank in by hand.

**Fix:** `add` opens no entry for whitespace, and ADR 0001 (r) records where the claim comes from.

### 5. A reply cut off with no final text sits below the owner, then joins the next reply

`app/Sources/BridgeCore/Call/GrowingLines.swift:21-22`

From probe `probeCutOffReplySitsBelowTheOwnerAndJoinsTheNextReply`: the voice says
`The first option is`, the owner cuts in, and the owner's final text gives `You: Stop.`,
`Voice: The first option is`. The next reply then shows as `Voice: The first option is Sure`, until
its own final text.

The PR body says such words stay; it does not give the order or the join. Whether codex sends a
`done` for a cut-off reply is not known: the log holds no cut-off, and the machine's tests assume one
comes. The real call in the Recommendations should settle it.

### 6. PR 43 needs two merge fixes, not one

`app/Sources/BridgeCore/Bridge.swift:504-507`, and `BridgeTests.swift:753` in PR 43

The PR body names the conflict in `realtimeEvent`. The second merges without a conflict and then does
not compile: PR 43's `aFinishedReplyReachesTheAudioSide` calls `voice.emit(.assistantSpeaking)` with
no words.

On a scratch merge, with `await audio.voiceFinished()` kept after `send`, the old `.assistantSpeaking`
case dropped, and `"Hello"` added to that test, all 635 tests passed. The two PRs do not otherwise
interact.

### 7. The menu renders on every delta when closed too, not only when open

`app/Sources/LiveBridge/StatusMenu.swift:79-90`

The PR body speaks of the open menu. `observe` and `show` run whatever the menu's state, and every
delta now changes `MenuContent`, so the guard at `:89` no longer stops anything. Each delta sets
`rootView` on the card, the rows and the transcript, about 3 times a second for the voice and 5 for
the owner.

The rest of the cost is fine:

- No disk write per delta; `save()` runs only on a final line.
- Whole-conversation work is capped by `keptLines` at 64.
- `publish` keeps only the newest update, so a slow main actor drops some.
- A rough benchmark outside a real menu put the transcript at a few milliseconds, and a `LimitRow`'s
  `DateFormatter`s at about 2.4 ms a build, which is older code.

**Fix, if a real call shows a cost:** render only while the menu is open. `menuNeedsUpdate` already
renders on opening.

### 8. `grow`'s guard: one half can go and the other asks the wrong thing

`app/Sources/BridgeCore/Bridge.swift:520`

The spot-check confirms the PR's stated exception: removing `lineSession != nil` fails nothing. It
also has no effect that reaches the menu, as a line with no session stops in `followTarget` before
anything is published. `isLineOpen` is needed only by the owner's case, as the voice's goes on to
`send`. And while connecting, `lineSession` is still the last line's until `lineKnowsSession` goes
true, which is what `followTarget` and `say` ask.

**Fix:** with finding 2's move, delete `grow` and call `growing.add` in the two cases. A late word is
then wiped by its own event's `changed()`. Keeping `grow`, ask `lineKnowsSession`.

`Bridge.swift:122` could say the same thing out loud, `target == lineSession ? growing.lines : []`,
so the display no longer rests on a target change hanging up. A home on `CallMachine`, reset in
`hangUp`, would be purer and would make the rule testable without `eventually`. It costs a payload on
`.assistantSpeaking` across 17 test mentions, and finding 2's one line gets most of the benefit.

### 9. The CHANGELOG's headline is stronger than the evidence for the owner's words

`CHANGELOG.md:11`, `docs/adr/0001-platform-findings.md:424`

"no longer runs a step behind the call" holds for the voice. For the owner, ADR 0001 (r) is careful:
how far the first delta trails was not measured. Its own figures hint at a real lag. If the 0.77 s
from last delta to `done` holds generally, the 1.7 to 3.5 s after speech means the last delta trails
the owner's voice by about 0.9 to 2.7 s. Those come from different calls, so this is a hint, not a
measure. The README warns only that the voice's words run ahead.

**Fix:** say the owner's words show as soon as codex transcribes them, which can still be a moment
after they are said.

### 10. Wording and one fact in four places

- `docs/architecture/overview.md:86`: "moves a line to `Continuity`". Nothing moves: the final text
  is recorded and the growing words are thrown away.
- `README.md:242`: "the final text replaces them when the line ends". Everywhere else "the line" is
  the connection, as it is in the next sentence, so this reads as replaced at hang-up.
- The rule that a growing line is never saved and never seeds the voice is told in
  `GrowingLines.swift:5-6`, `overview.md:87`, ADR 0001 `:611-612` and the README. The documentation
  policy gives one fact one home; `overview.md` is its home, and the ADR bullet can link to it.
- `GrowingLines.lines` trims text `LineView` trims again (`MenuRows.swift:236`). Only the emptiness
  test is needed for the menu, though `BridgeUpdate` carrying clean text is defensible, and four tests
  read it.

### 11. The six translated READMEs were not updated

`README.ru.md:249` and its siblings

Recent changes to the same paragraph went to all seven files (`8248100`, `eee4fa1`). This PR changed
`README.md` only, so the others still say Conversation shows what LiveBridge keeps, with no word of
the growing text.

### 12. The voice's `done` range is a little wider than stated

`docs/adr/0001-platform-findings.md:417`, PR body

The PR gives 1.83 to 2.06 s after the voice's last delta. The log holds five such replies: 2.00, 1.73,
2.04, 1.83 and 2.06 s, so 1.73 to 2.06 s. It changes nothing.

## The orderings asked about

| Ordering | Result |
|---|---|
| The voice's first words before the owner's final text | Right, and tested: the owner's line goes above |
| A reply starting before the last reply's final text | As the PR says: first words gone until its own final text |
| The same for the owner | Finding 3 |
| A line closing before its final text | Right: the words go and nothing is kept, in `send`. One path misses (finding 2) |
| The owner cutting the voice off | Finding 5; whether a `done` comes is unknown |
| A second call opening after a close | Right, and tested; late deltas of the old thread stop at `RealtimeSession`'s `threadId` guard |
| A change of target mid-line | Right, and tested: `followTarget` hangs up before `current` is read |
| `/clear` mid-line | Right, and tested: `lineSession` follows the new id |
| New conversation mid-line | Right by reading: it shares the reset. No test says so directly |

## Whether the tests can fail

The PR's claim holds. Every rule in the code was removed in turn, and a test failed each time: both
`finish` calls, the reset, `isLineOpen`, the order, the trim, the empty filter, the one-per-speaker
merge, both `.userSpeaking` and `.assistantSpeaking` paths, the `delta` field, and a growing line
being recorded. The stated exception, `lineSession != nil`, survives as stated.

What did survive is what the claim does not cover: the unwanted additions in finding 1, the empty
delta in M13, and M20, which moves the owner's `finish` after `send` and so publishes a moment of
double line. M20 is not a stated rule.

## Docs against the code

- ADR 0001 (r)'s table is right. Every time in it matches the log, shifted by 35 s, with 8 owner
  deltas over 1.72 s, 0.77 s to the owner's `done` and 1.83 s to the voice's. "A few a second" is
  right: about 3.3 a second across one long reply.
- The film-take figures (1.7 to 3.5 s, 0.6 to 0.96 s, 20.8 s) could not be redone: the film folders
  hold the finished video, not the marks. They agree with each other.
- The CHANGELOG's note that this was not seen in the real menu is plain and correct.
- No wire change: `Wire.swift`, `plugin/hooks/wire.ts` and `wire/fixtures/` are untouched, and
  `StatusReply` has no conversation field.
- No personal data. ADR 0001 (r) quotes one line of real speech from a call, harmless, and the owner's
  to keep.

## Security

No findings. Delta text ends in `Bridge.growing`, which only `Bridge.swift:122` reads. It does not
reach `Continuity`, the seed, `addContext`, `speak`, the audio page, the wire, logs, notifications or
a permission decision. `LineView` passes a `String`, so `Text` takes no Markdown. That last point
comes from SwiftUI's documented overloads, not from a compile test. No third-party package was added.

## Not verified

- Anything in a real menu or a real call. In particular:
  - the open submenu resizing as a line wraps;
  - `item.submenu = nil` (`StatusMenu.swift:144`) on an open submenu, when the first line of a new
    conversation closes before its final text, which empties it.
- Keeping to the end while a line grows was checked by reading only (`ScrollingItem.show` and `fit`).
- Why two of the seven replies in the log have no `done`. Their frames stop within 1.8 s of the last
  delta, before the roughly 2 s a `done` takes, so the session seems to have ended first. If that is
  common, the words that vanish at a close are a larger part of what the owner sees. Which close it
  was is not known.

## Declined to judge

- Whether a growing line should look different from a final one: a design choice.
- Words vanishing at Stop: the requirement says they do, and the README says so.
- A voice final arriving before the owner's, and stored `Task` or `Claude` lines landing above a line
  that started earlier: both are the ordering by final text that predates this PR.
- An empty final text clears the words shown and keeps nothing (probe
  `probeEmptyFinalTextEmptiesTheLine`): no evidence codex sends one.
- A queued delta of the old line landing on the next connecting line: the queue drains faster than
  the owner can speak again.
- Two `changed()` per voice delta (`Bridge.swift:503`, `:514`), and the meter defeating the
  no-change check while live (`UsageMeter.swift:69-73`): both predate this PR, and both are cheap.
- `isVoiceSpeaking` staying true if a blank delta really follows a final text: predates this PR.

## Follow-up outside this PR

ADR 0001 (r) now records that `~/.codex/logs_2.sqlite` keeps the tail of each realtime session, delta
text included. Neither the README's privacy section nor `SECURITY.md` names that file. It is codex's
behaviour, not LiveBridge's, but a privacy-minded owner may want a line about it.
