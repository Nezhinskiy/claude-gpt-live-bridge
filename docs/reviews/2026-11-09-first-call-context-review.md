# Review of PR #71: load a session's context on its first call

Reviewed `3b17f01..c15471f` (branch `claude/sad-bose-05ac74` into `dev`). File and line numbers
are at `c15471f`. Report only: nothing in the PR was changed.

**Verdict: merge with fixes. No High findings.** The privacy rule in the code is correct: no path
was found where the setting's off state, or a paused session with a summary, sends a summary. The
findings are one menu state that takes a working button away, one question for the owner about the
migration, and docs that claim more than the code does.

| # | Severity | Finding | Where |
|---|---|---|---|
| 1 | Medium | A live line whose first summary was lost greys out Load context | `app/Sources/BridgeCore/Bridge.swift:398` |
| 2 | Medium | The README's recipe for keeping text from OpenAI no longer holds by default | `README.md:331`, translations |
| 3 | Medium | The site still says no summary while Pause sync is on | `site/index.html:124` |
| 4 | Medium, owner's call | An update widens for a session still marked paused with the pause off | `app/Sources/BridgeCore/Settings.swift:59-61`, `CHANGELOG.md:21-23` |
| 5 | Low | "At most a session's first" is not a limit the code has | `README.md:45`, translations |
| 6 | Low | The pause's caption states the first sentence with no exception, and branches for little | `app/Sources/LiveBridge/SettingsView.swift:63-69` |
| 7 | Low | Two SECURITY.md sentences ignore one setting state | `SECURITY.md:265`, `SECURITY.md:296` |
| 8 | Low | The `{ true }` default fails open if the wiring is lost | `app/Sources/BridgeCore/Bridge.swift:76` |
| 9 | Low | `conversation.context == nil` is dead in `contextNeed` | `app/Sources/BridgeCore/Bridge.swift:398` |
| 10 | Low | "Will the next line ask" is still assembled in two places | `app/Sources/BridgeCore/Bridge.swift:393-400`, `:426` |
| 11 | Nit | Repeated test setup and repeated doc comments | see below |

## Findings

### 1. Medium: a live line whose first summary was lost greys out Load context

`contextNeed` (`Bridge.swift:393-400`) does not look at whether a line is open. It answers
`.withTheLine` for a session with no summary even when the line for that session is already live,
and `ContextLoadState.withTheLine` is not enabled (`Menu/ContextLoads.swift`, `isEnabled`).

Sequence: the pause is on, the setting is on, the owner presses Start, and the line asks. The mod's
model fails, or the summary is dropped as stale because a paused line overtook it. The line is now
live with `context == nil`, and the menu says **Context loads with the line**, disabled.

Probed in a scratch copy, with a live line and no summary posted:

- setting on: `contextNeed == .withTheLine`
- setting off: `contextNeed == .load`

The voice then knows nothing of the session, which is the case this feature exists for. A press
would work on a live line (`Bridge.context` adds the summary at once), but none is offered. Recovery
is the silence timeout or Stop and Start. The pause-off path already had this shape; this PR extends
it to the paused case, where 0.4.2 had an enabled press. The label is also wrong for that moment:
no line is about to open.

Fix: return `.withTheLine` only when no line is open for that session (`isLineOpen`,
`lineKnowsSession`, `lineSession == id`), otherwise `.load`. Add a test for a live line with a lost
first ask. Weigh it against showing `.load` during the seconds the first ask is honestly on its way.

### 2. Medium: the README's recipe no longer holds by default

`README.md:331` still reads "For text you do not want to reach OpenAI, turn this on, press Stop,
then type". With the new default, a session with no summary sends that text in its first summary.
The exception comes two sentences later, but the recipe is what a reader follows.
`SECURITY.md:306-307` got the extra step ("and turn off **Load a session's context on its first
call** if the session may have no summary yet"); the README and the pause bullet in all six
`docs/i18n/README.*.md` did not. Add the same step to each.

### 3. Medium: the site still says no summary while Pause sync is on

`site/index.html:124` says the line asks for a summary "(not while Pause sync is on)". With the
default on, that is now false for a first summary, and it is the most public statement of the rule.
The PR does not touch `site/`. Change it to match `README.md:45`.

### 4. Medium, owner's call: an update widens for a session still marked paused

The migration keys on the pause setting only (`Settings.swift:59-61`), as the owner approved. An
owner who is past a pause is not covered:

1. On 0.4.2, the pause is on, and the owner types private text into a session with no summary.
   The session is saved as `paused`.
2. The owner turns the pause off, then updates. The file has no key and the pause is off, so the
   setting becomes `true`.
3. The next line asks over the mark (`aPausedMarkWithThePauseOffAndNoSummaryAsksForContext` pins
   this), and the summary carries that text to OpenAI. On 0.4.2 only a press could do that.

The code meets the stated rule. The stated reason does not hold for this owner: the spec says "an
update must not widen that silently", and `CHANGELOG.md:21-23` says "so nothing widens without you".

Either narrow those two sentences to say a mark left from an earlier pause is not protected, or
migrate to `false` when a stored session is paused with no summary. The second reaches across two
files at startup, so narrowing the words looks cheaper. The owner should choose.

### 5. Low: "at most a session's first" is not a limit the code has

`README.md:45` says "while **Pause sync** is on, at most a session's first", and the translations
follow. The test is `context == nil`, as the spec says ("A summary is the test, not 'the first
call'"), so **New conversation**, × then rejoining, and eviction past 20 sessions each allow another
one over a kept *paused* mark. Each press of **New conversation** can send the paused text again.
The spec and `SECURITY.md:295-298` say so; this line does not. Say "only when it has no summary".

### 6. Low: the pause's caption

With the setting on, `SettingsView.swift:63-69` reads "What you type while the call is off stays out
of the voice's conversation. After a session's first summary, context loads only from the menu." The
first sentence has no exception, and the second does not say the first summary carries that text.
The next caption says it, a few points lower. The two branches also repeat a clause and tie this
caption to a setting below it. One static sentence with the exception in it, pointing at the next
setting, would fix both. It changes the owner's copy, so it needs a look.

### 7. Low: two SECURITY.md sentences ignore one setting state

Both err towards saying more leaves, not less, so neither is a false comfort.

- `SECURITY.md:296`: "With it on, or with no pause mark, a session with no summary does get one".
  With the setting off, the pause setting on and no mark, the line asks for nothing.
- `SECURITY.md:265`: "A missed session, unlike a paused one that has a summary, loads a summary by
  itself once the setting is off" implies a paused one with no summary does. It does only with the
  new setting on, and "the setting" here means the pause.

### 8. Low: the `{ true }` default fails open

`loadsContextOnFirstCall` defaults to `{ true }` at `Bridge.swift:76`. If the `App.swift:168` wiring
were lost, the Off toggle would do nothing, with no compile error, and the app target has no tests.
Both real callers pass it already, so the default can go.

### 9. Low (redundant): `conversation.context == nil` is dead in `contextNeed`

At `Bridge.swift:398`, past the `needsContext` guard, `!hasGap && syncs` leaves only `context == nil`
or a `.paused` mark. With a summary and a mark, `pauseHoldsBackSummary` is true. So the condition can
never decide the result. Removing it survived all of `BridgeCoreTests`, and tracing the cases shows
it is an equivalent mutant, not a test gap. It predates the PR but sits in the edited expression.

### 10. Low (architecture): "will the next line ask" is assembled twice

`pauseHoldsBackSummary` is a good shared rule, and with it menu and line now agree. They still build
the decision separately: `openLine` at `:426` and `contextNeed` at `:393-400`. One predicate,
`nextLineAsks(id)` meaning `needsContext && !pauseHoldsBackSummary`, would leave `contextNeed` as
`nextLineAsks && !hasGap && syncs ? .withTheLine : .load`, and would drop its second
`registry.syncs` hop. Finding 9 goes with it, and finding 1 belongs in the same place.

Considered and not recommended: moving the rule onto `Conversation`, because it reads two settings
the type does not hold; and one three-state pause setting in place of two Bools, because the owner
asked for a separate setting and the migration is three correct lines.

### 11. Nit

- `BridgeTests.swift`: the join, `sync(a, "Private thing.")`, expect `.paused` setup repeats about
  nine times in the new tests (26 `sync` copies across the file). A `pausedSession` helper would
  hold it.
- `SettingsTests.swift`: `turningItOnUnderThePauseIsKept` repeats the file-writing lines that
  `decoded(_:)` hides.
- The first-summary rule is restated in comments at `Settings.swift:10-11` and `:13-15` and at
  `Bridge.swift:22` and `:409-410`. One home, with links from the others, fits the docs rule.

## What was traced and found sound

**Privacy.** `Bridge.swift:426` is the only automatic ask. The other routes are the press and an
older mod's `/live context`, both unchanged. With the setting off, or with a summary present,
`pauseHoldsBackSummary` reduces to the old condition. No path sends a summary in either state.

**Failed or empty first summary.** Each of these leaves `context` nil and is asked again by the next
line, and none reaches OpenAI: the mod posts nothing on failure or empty text, a whitespace POST
stores nothing (`Bridge.swift:712-720`), and a stale ask is dropped before anything is set
(`:711`). Only a summary that lands can leave, and landing closes the gate. So paused text does not
leave on every line. The repeated asks do spend a side model call each, with no backoff, which the
spec chose.

**Socket peers.** No HTTP route forgets a conversation. A same-user process could evict one or move
it with `replaces`, but `SECURITY.md` already treats such a process as able to read the transcript.

**`contextNeed`.** With the setting off it equals the old expression in every case. An older mod
stays `.load` and the line asks once, then the pause holds it back. A reopened or switched line goes
through the same rule. A summary during connect uses `heldContext` unchanged. An ask in flight is
kept and the mod joins it. A known BR-002 case remains (a re-ask within 120 s of a stale one keeps
the stale ask, which fails closed and heals on the next line).

**`Continuity`.** A first summary clears the mark, as any summary does, and zeroes the line count.
The next refused line marks the session again and the pause then holds as before
(`afterTheFirstSummaryThePauseWorksAsBefore`).

**Migration.** `decodeIfPresent ?? !pauseSyncWhileStopped`, after the `autoContext` mapping. No key
with the pause on or `autoContext: false` gives `false`; no key with the pause off, or
`autoContext: false` with an explicit `pauseSyncWhileStopped: false`, gives `true`. A stored `true`
under the pause is kept. The file is rewritten only by `SettingsStore.update`, never at launch. An
older app ignores the key; coming back from it re-migrates in the narrowing direction.

**Security review.** No finding at the confidence bar (8 of 10). `security-review` printed this
branch's own diff against `main`, so it was applied to the PR's diff by hand.

**Merge with PR #70.** Clean. No conflict markers, and no hunk in README or SECURITY.md touches the
notarization text. `check` and CodeQL are green at `c15471f`.

**Efficiency and reuse in shipped code.** Nothing. `pauseHoldsBackSummary` is synchronous and in
memory, neither caller is hot, and the closure captures only `settings`, like its neighbours.

## Mutations

22 source mutations, one at a time, against `swift test --filter BridgeCoreTests`. 21 failed tests.
The one survivor is finding 9.

| Mutation | Result |
|---|---|
| `openLine`: never held back | killed (9 tests) |
| `openLine`: no `needsContext` | killed (`aCurrentLineAsksForNothing`) |
| hold: ignores the setting | killed (9) |
| hold: ignores `context == nil` | killed (3) |
| hold: first-call rule removed | killed (11) |
| hold: pause setting only / mark only | killed (3 / 4) |
| `contextNeed`: gap is any mark | killed (1) |
| `contextNeed`: gap without over-seed / without missed | killed (1 / 2) |
| `contextNeed`: no `syncs` | killed (1) |
| `contextNeed`: no `context == nil` | **survived**, equivalent (finding 9) |
| `contextNeed`: no pause check | killed (3) |
| migration: always true / always false | killed (2 / 3) |
| migration: uses `optedOut` | killed (2) |
| migration: ignores the file's value | killed (2) |
| default off | killed (2) |
| `setContext` keeps the mark | killed (6) |
| forget drops the mark | killed (4) |
| stale ask taken | killed (8) |
| `markPaused` does not stale the ask | killed (3) |

The test harness defaults the setting off, unlike the app. That is deliberate and commented
(`BridgeTests.swift:166-167`), so the older pause tests still pin the old behaviour. The
`App.swift` wiring has no test, like its neighbours (finding 8).

## Not run or not judged

- `scripts/check.sh` was not run locally; CI's `check` passed at `c15471f`. `scripts/smoke.sh` and
  any real voice were not run, as asked.
- Translations: presence of the new setting and the changed rules was checked in all six. The
  wording was read only for `ru` and `zh-CN`.
- Set aside as the owner's decisions: first summaries carrying paused text by default, asking over a
  mark after **New conversation**, × or eviction, and no backoff on failed asks.
