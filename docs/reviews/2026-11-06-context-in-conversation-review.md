# Review: a loaded summary in the conversation (PR 47)

Reviewed: `feat/context-in-conversation` at `fa0fcb0`, against `dev` at `f4ec846`. Report only;
nothing in the PR was changed.

## Verdict

**Fix first, docs only.** The code is correct and needs no change. One sentence in `SECURITY.md`
is now false, and `docs/architecture/overview.md` describes the seed wrongly. Both are one commit
of a few lines, and neither needs another code review.

## How it was checked

- The three skills, scaled to a small change: `superpowers:requesting-code-review`, `simplify`
  (its four angles) and `security-review` all ran in this one session, not as separate agents.
- `swift test` on a scratch copy of `fa0fcb0`: 606 tests passed, the PR's 601 and 5 throwaway
  probes. `scripts/check.sh` was not run here. CI's `check` job was still pending when this was
  written.
- `LineView` and `TranscriptView`, copied unchanged into a scratch program, rendered to a PNG at
  the menu's 320 points with a long summary between ordinary lines. The layout is right: the mark
  sits above, the text wraps, all of it muted, and the other rows are unchanged. That is not the
  real `NSMenu` or `ScrollingItem`.
- The probes and the render are in the shared notes folder, under `pr47-review-proofs/`.

## Blocks a release

### 1. `SECURITY.md:276` says a new summary replaces the old one

> a load of a new summary replaces the old one but keeps the lines

The PR makes the old summary one of those lines. It stays in `continuity.json` and in the menu
until it rolls off or the conversation is forgotten (probe `oldSummariesStayInLinesAfterANewOne`).
It no longer reaches the voice, so the voice half of the sentence holds; the file and menu half
does not.

This matters most where `SECURITY.md:269-271` warns that a `/live context` summary can carry paused
text: an owner who loads a clean summary to displace that one still has the old text on disk and in
the menu, while the document says it was replaced. **New conversation** and × do erase it.

It blocks only because of the rule that docs never claim more than the code enforces, and because
this is the security document. The behaviour itself is fine and matches what the owner asked for.

Suggested wording:

> a load of a new summary replaces the old one for the voice and keeps the lines, the old summary
> among them, until it rolls off

`SECURITY.md:209` wants the same fact, in its list of what the file holds: the session's
`[CONTEXT]` line and the summaries loaded before it.

## Fix in the same commit, does not block alone

### 2. `docs/architecture/overview.md:60-67` is out of date

The `keptLines` list has no summary line, and "seeded with the target's conversation, less those
briefs" now reads as if the summary line went into the seed as well. The code leaves it out. It
should say "less those briefs and summaries", and the list should name them.

## Does not block

### 3. `README.md:444-445` and its six translations

"its recent conversation (up to 64 lines …) and the context line last loaded from it" is still
literally true, as earlier summaries count among the 64 lines, but a reader will take it to mean
only the last summary is kept. Worth a clause, and it can follow the release.

### 4. `README.uk.md:250` uses the wrong word

The new clause says `підсумок`. The rest of that README says `резюме` for a summary, nine lines'
worth, including `README.uk.md:263` beside it. It is one word. The other five translations use
their file's own term.

### 5. Two comments are behind the code

- `Conversation.initialItems` (`Continuity.swift`): "A handoff line is the menu's only" now holds
  for a summary line too.
- `BridgeUpdate.conversation` (`Bridge.swift`): "every line the app keeps" now has one exception,
  the summary `shownLines` adds.

### 6. Going back to an older build wipes the file, paused marks included

The PR body says an older app "starts with no conversations". More exactly: `Bridge.init` turns a
failed decode into an empty `Continuity`, and the next `save()` writes that over the file, so the
loss is permanent and takes the paused marks with it. The updater does not reach this, but
**the debug build and the installed app share one data folder** (`Paths.dataDir`). Trying a 0.4.1
debug build and then opening an installed 0.4.0 empties it. Adding a `Speaker` case has always
done this (`be17a77` added `handoff` the same way). A decoder that drops an unknown speaker's line
would end the class; that is its own change.

### 7. One look at the real menu

The PR says the layout was not seen, and the render above covers `LineView` only. Opening the
Conversation submenu once on the release build is enough.

## What was asked, answered

- **Can a `.context` line reach the voice twice?** No. Only `initialItems` builds a seed, and it
  skips a line with no role. Past that, `lines` has one reader in the app (`opensLine`, which
  wants `.owner`) and `BridgeUpdate.conversation` goes only to the menu. The summary goes in once,
  as the `context` note.
- **`isCurrent` and `linesSinceContext`?** Unchanged. `record` counts only lines with a role, and
  `setContext` resets the count to 0. The summary line takes one of the 64 places, but it is older
  than every line counted, so it only displaces a line from before the summary. The boundary probe
  checks 62 to 66 lines after a summary; `isCurrent` turns false at 65, as it did.
- **`setContext` and `shownLines`?** Correct. The newest `.context` line, if any is kept, always
  holds `context`, because a line is recorded whenever `context` changes. So the guard never hides
  the current summary or shows two.
- **Every `Speaker` switch?** `name` and `role` are the only two, and both are exhaustive.
- **New conversation, ×, `move`?** `afterForgetting` builds a new `Conversation`, so the line and
  the context go together; `move` carries the struct whole. Both probed.
- **`keptLines` roll-off?** The summary goes first once its line rolls off, as tested. A summary
  equal to the stored one adds no line, so if it comes back after a roll-off it still shows first.
  That needs identical text after 64 lines, and is harmless.
- **A 0.4.0 file?** It decodes with no migration: the summary shows first, `isCurrent` holds, the
  seed is unchanged, and the next new summary sits in place (probe `file040`, on a hand-written
  file of 0.4.0's shape).
- **`LineView`?** Sound. `Text(String)` is verbatim, so a summary cannot inject markdown or a link.
  The `[CONTEXT] Alpha:` prefix stays under the **Loaded context** mark; that is what keeps
  `README.md:411`'s "exactly as it is sent" true, so it should stay.
- **CHANGELOG and the English README?** Accurate. "Shown whole" means the whole stored line, which
  `Bridge.maxContext` caps at 1,500 characters. "Where it was loaded" has the two exceptions above,
  too small to spell out.
- **Translations?** All six carry the clause, correctly placed, with **Loaded context** left in
  English as the menu shows it. Finding 4 is the only slip.
- **Leftovers?** No `What was sent`, `SentView`, `sentCharacters` or `.sent(` outside the
  CHANGELOG entry that retires it.

## Is the architecture elegant enough? Is anything redundant?

Yes, it is elegant enough. A `Speaker` case with no seed role is the mechanism `handoff` already
set, so the voice's path did not change at all. `shownLines` is three lines, and the same guard
covers roll-off and the 0.4.0 file, which is why no migration exists. The PR removes more than it
adds in the sources.

Nothing is redundant enough to change. The summary is stored twice, as `context` and as a line, but
that is required: the voice needs `context` after the line rolls off. `line != context` in
`setContext` and `isNew` in `Bridge.context` compare the same two strings, and having `setContext`
return the answer would save one line and is not worth a change now. The `BridgeUpdate.context`
helper in `Support.swift` keeps over a dozen existing assertions readable, and it is test-only.

## Security

No finding. No new input, wire field or file: the text was already redacted and saved. The
retention change is finding 1, a documentation defect and not a vulnerability.

## Efficiency

No finding. `shownLines` scans at most 64 lines for each update, and the extra disk use is bounded
by the same 64 lines of at most 1,500 characters.
