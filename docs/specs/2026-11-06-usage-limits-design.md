# Usage limits in the menu

Status: delivered in part, 2026-11-06. What remains is the lifecycle cases that were not seen in the
real menu: a call live, codex missing or signed out, a read in flight when the menu closes, and an
app restart with a joined session (pull request #40 lists which were and were not walked). The data
below was read that day on the owner's Plus login with codex 0.166.0, spending no voice. The wider research:
[`docs/research/2026-11-05-gpt-live-limits.md`](../research/2026-11-05-gpt-live-limits.md).

## Why

The owner wants to see how much of the Codex and Claude limits is left, so that running out does
not come as a surprise. Codex comes first; Claude is the same glance, so it is built with it. This
is a glance in the menu, nothing more: the app does not warn on its own (the owner chose this).

OpenAI and Anthropic change their limits and have done so before, so nothing here is built around
exactly a 5-hour and a weekly window (the owner's requirement). The rows show the windows the plan
reports, whatever they are; a window of a new length shows rather than vanishes.

## What the owner sees

A section of two rows above the minutes:

```
Codex   7% of 5 h · 19% of week
Claude  40% of 5 h · 22% of week
```

- Each row is text only, with no icon: the product's name and one figure per window, percent
  **used**, rounded to a whole number. The owner tried icons and logos and chose none.
- Windows are listed shortest first, up to three a row. Labels come from the window's length: `week`
  within ±5 % of 10080 minutes, `N h` for a whole number of hours under a day (`5 h`, `4 h`), `N d`
  from a day up (`30 d`), `N min` for anything else under a day (`45 min`, and `90 min`, not
  `2 h`). The tooltip's name follows (`90-minute window`). With no length the label is `limit`. A Claude kind the app does not know shows
  by name, underscores as spaces. Beyond three, the windows of known length stay first.
- A window showing 90 % or more is drawn orange. The figure says it too, so status does not rest
  on colour alone.
- Hovering a row shows when each window resets, by the window's own length (`5-hour window`,
  `Weekly window`, `4-hour window`, `30-day window`), then when the figures were read:

  ```
  5-hour window resets at 06:04
  Weekly window resets Wed 08:01
  Read at 05:08
  ```

  A time today shows as the time, on another day within six days as the short weekday and the
  time, and further off, either way, as the date and the time (`13 Nov at 08:01` in en_GB), for
  resets and "Read at" alike, in the Mac's locale and time zone.
- If codex says ordinary usage is not allowed right now (`ordinaryUsageAllowed: false`), the Codex
  row is orange, ends with the word `blocked`, and its tooltip opens with "Codex reports usage is
  blocked right now." The figures may be well under 100 % then: `account.rs` tells clients not to
  infer it from percentages. This row shows even with no window to show (`Codex  blocked`).
- A window the source does not report is simply absent (`Codex  19% of week`). A row with no
  window and no block is not shown; with neither row the section is not shown. So a plan without a 5-hour window
  shows its other windows; an API-key login, a missing codex, a reply of a shape this version does
  not understand, or a Claude session that has not answered yet shows no error and no figure.

Nothing here says "voice limit". Which limit stops the voice first is not documented, so the rows
name the product whose figures they are, and no doc may say more.

## What the data is

**Codex.** `account/rateLimits/read` (experimental API) answers on the voice's own locked-down argv
in about 0.5 s, about 2.2 s with `codex features list`, start and initialise.

- The Plus reply has `ordinaryUsageAllowed: true` at its top level and one bucket,
  `rateLimitsByLimitId.codex`, with `primary` {`usedPercent` 7, `windowDurationMins` 300, `resetsAt`
  epoch seconds} and `secondary` {19, 10080, …}. No voice bucket appears on this account.
- The row is the `codex` bucket: `rateLimitsByLimitId.codex`, else the single-bucket `rateLimits`
  if its `limitId` is `codex` or absent; with neither, no figures. Other buckets are per-model
  quotas and are not merged in, so the row is ordinary Codex usage. A block on another bucket shows
  only if codex reports it through `ordinaryUsageAllowed`.
- Slots are not meanings. codex passes the backend's primary and secondary through and labels them
  by length, ±5 % (`codex-rs/tui/src/chatwidget/rate_limits.rs:109-145` at `rust-v0.166.0`). Either
  may be null. A Pro report shows a 10080 window on its limit
  ([openai/codex#37619](https://github.com/openai/codex/issues/37619)). So every window of the bucket
  with a usable `usedPercent` shows, labelled **by its length**, never by slot. Two of one label keep
  `primary`. Pro's actual reply was not read; this rule is what makes that safe.
- The reply also carries `accountId`, plan, and reset-credit ids. Only the window fields and
  `ordinaryUsageAllowed` are decoded; `excludeResetCreditDetails: true` skips the credit lookup.

**Which window the voice draws on: not proved.** One strong hint: the current 5-hour window started
at 01:04:41, the second a 20.8 s voice line closed (`usage.json`). That window then showed 7 %, far
more than 21 s of voice, so something else used it too. The feature does not depend on the answer.

**Claude.** The engine gives a mod `rateLimits: [{kind, percentUsed, resetsAt?}]`: `$.session.usage()`
on request, and the `session.measure` event after each main-thread turn and when a window moves a
whole point. `kind` is `five_hour`, `seven_day` or a gateway's `spend_limit`. The list is empty off a
subscription and before the first reading. It exists only in a Claude Code session, so the Claude
row needs a joined session that has answered once.

## Design

**The value.** `BridgeCore` gets one shape for both sources: a list of windows, each with its span
(a length in minutes, a kind by name, or unknown), `usedPercent` and `resetsAt?`, kept shortest
first and at most three, and when it was read. It is held in memory only and never written to disk
or logs. A reply of an unexpected shape never crashes: a missing or renamed field gives that window
or that row nothing, and a read that fails is a failed read.

**Reading Codex.** A short-lived `codex app-server`, started for the read and closed after it, as
Settings' voice list does (`offeredVoices` in `App.swift`), except that the search path, which
costs a login shell, is kept for the run as soon as codex is found on it, before it is launched, so
a signed-out user does not rerun the shell at each read. The sequence (launch, read, close on success
and on failure) is `CodexLimits.readOnce` in `BridgeCore`, tested there. Why not the voice's own codex: it runs
only from Start to Stop, and the owner looks at the limit before a call too. Its lifecycle and
`RealtimeSession` do not change, so the voice path is untouched; a read during a call is a second
process on the same lockdown argv.

- When: each time the menu opens, at most once a minute (a clock moved back does not stop the reads), one read at a time. The menu shows the last
  reading at once and the new one replaces it when it arrives, a few seconds later at worst. A
  reading older than 15 minutes is gone, so after a quiet quarter of an hour the row is not there
  when the menu opens and appears when the read lands. No
  background reads (the owner chose the menu only).
- A failed read leaves the last reading until it is 15 minutes old (codex's own staleness limit),
  then it goes.

**Reading Claude.** The mod sends what the engine gives, the app keeps the latest:

- New route `POST /v1/limits`: `{sessionId, windows: [{kind, percentUsed, resetsAt?}]}`. The wire
  change touches `Wire.swift`, `plugin/hooks/wire.ts` and `wire/fixtures/` together.
- `five_hour` is 300 minutes and `seven_day` is 10080. `spend_limit` stays out. Any other kind shows
  by name. A kind is a string from the socket that now reaches the menu, so only
  `[a-z0-9_]{1,32}` with at least one character other than `_` is accepted and the rest are
  ignored.
- The mod sends once on joining (from `$.session.usage()`) and on `session.measure` when `rateLimits`
  changed, only while joined. An empty list is not sent. A failed send is dropped; the next one
  corrects it.
- Several sessions share one account as a rule, so they feed one reading, keyed by window: the
  later `resetsAt` wins, and on the same `resetsAt` (resets within a minute count as one) the
  higher percent wins and that window is kept whole, as use within a window only grows. A window nobody reports any more goes at its reset; a Codex read replaces the whole
  reading. A window with no `resetsAt` takes the newest, except that a known reset is kept against
  an undated report (the window keeps the old reset and the higher percent); a held window with no
  reset that a report does not mention is dropped, and one that stays is dropped 15 minutes after the
  reading, as it has no reset to wait for. `$.session.usage()` reports the last
  response and has no timestamp, so an idle session joining would otherwise put old, lower figures
  over fresh ones. "Read at" is when the held reading last changed or was confirmed by an arrival: one of its windows
  taken, or matching what is held in percent and reset. An arrival that lost everywhere confirms
  nothing, so it does not move "Read at".
  A session on another account mixes with this one; accepted.
- The reading outlives the sessions: when the last one leaves, the row stays until each window's
  reset, with "Read at" showing its age. Nothing needs clearing on leave, removal or the sweep. It
  goes when the app quits, as it is held in memory only.
- Published through `BridgeUpdate`; `StatusReply`, the poll and the band do not change.
- A mod from before this route sends nothing and the row stays away. A new mod with an old app gets
  a 404, ignored like any failed send.

**Past its reset.** A window whose `resetsAt` has passed says nothing about the new window, so it is
left out until a new reading comes. A window with no `resetsAt` is left out 15 minutes after the
reading it came from, the same number as Codex's own staleness limit. Held windows that have expired are dropped before a new report is merged, so they take
no slot from a live one. That matters for Claude, whose readings arrive only with a turn.

**The menu.** `MenuContent` gets a limit item carrying the row's parts, tooltip and which windows are
near the limit; `outline` prints it for the tests. All rules are pure and tested there. The
threshold is one constant, 90. A row is an enabled native `NSMenuItem` with `toolTip`: on a disabled
hosted row SwiftUI's `.help` did not show in the real menu. So a row highlights under the pointer,
and a click only closes the menu, which the owner accepted.

## Docs

- README and its six translations: the rows show the windows the plan reports, what each row
  needs, and that which limit stops the voice is not documented. No doc names the two windows as a
  fact of the plans. Fix the translations' outdated minutes bullet
  only if this change touches that sentence.
- `docs/architecture/overview.md`: the short-lived read and the new route. `SECURITY.md` if it lists
  routes or what codex is asked; say that opening the menu makes codex read usage from OpenAI, also
  while the call is off. Check every "nothing is sent" sentence stays true: it speaks of audio.

## Not in this change

Warnings, notifications, a badge on the glyph, a reset timer that counts down, credits, the
reset-credit offer, spend limits, and showing limits in the band or `/live status`.
