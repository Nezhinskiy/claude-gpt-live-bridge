# Settings in two tabs, and the silence before the line closes

Status: delivered, 2026-11-10. Amended after the PR #80 review (below).

## Why

OpenAI bills the realtime line by the minute while it is open, silence included, so the line closes
after 20 s of silence (`CallMachine.silenceSeconds`) and opens again when the owner speaks, with
the 2 s pre-roll. The owner asked whether 2 to 3 s would do. It would not: normal thinking pauses
run 3 to 8 s, and a reopen costs 2 to 4 s before the voice answers, with a risk of a silent or
fragmentary first reply ([ADR 0001](../adr/0001-platform-findings.md): a reopened line connects in
about 1 to 2 s, the voice starts 1 to 2 s after that, and the "voice finished" event comes 0.6 to
2 s after its audio ends). The owner chose to make the pause a setting, 20 s by default, so that
each owner trades minutes against reopens for themselves, up to a line that never closes, as in
ChatGPT.

The Settings window is one long form, and two settings are on their way (a summary model, in the
[summary model design](2026-11-09-summary-model-design.md) under review, and a choice of UDP or TCP
for the voice). The owner wants it split into two tabs.

## What the owner sees

### Two tabs

The window has two tabs, **Voice** and **General**, chosen by the owner:

| Voice | General |
|---|---|
| Voice | Sync (the summary model joins it) |
| Prompt | Notifications: **Notify when a result is waiting** |
| Line: the silence below (the UDP/TCP choice joins it) | **Open at login** |
| Sounds: **Play sounds for requests and answers** | Updates |

Everything the owner hears during a call is on **Voice**. Today's Notifications section splits: its
sound toggle goes to **Voice**, its notification toggle stays under **General**.

- The window first opens on **Voice**, then on the tab last shown. A notice's **Install** opens it
  on **General**, where the update is.
- The tabs are SwiftUI's `TabView` with `tabItem` labels, so they take the keyboard (Full Keyboard
  Access) and VoiceOver reads each tab by its name.

### The line's three timers

The **Line** section has three number fields, each with a stepper and an "s" after it, each a whole number of seconds
from 0 to 300, and each keeping today's value as its default:

| Field | Default | What it counts |
|---|---|---|
| **Silence before the line closes** | 20 | silence since the last speech, recognised words or reply (`silenceSeconds`) |
| **Wait for a first word on a line a result opened** | 5 | a line a result opened, until the owner or the voice speaks on it (`firstWordSeconds`) |
| **Sound without words before the line closes** | 90 | sound the Mac's voice detection hears that gives no recognised words (`noiseSeconds`) |

- A value outside 0 to 300 becomes the nearer end, and text that is not a number goes back to the
  value before.
- **0 switches the silence or the noise timer off; a first-word wait of 0 waits the silence**
  (amended, below). With all three at 0, nothing about quiet closes the line: it stays
  open until the owner presses Stop, the call ends or OpenAI closes it, as in ChatGPT. A line OpenAI
  closes is handled as today: the next speech opens a new one.
- Warnings, which keep the value: silence from 1 to 9 s closes the line inside ordinary pauses;
  sound without words from 1 to 9 s can cut the owner off mid-sentence, as speech counts as sound
  without words until it is recognised; a first-word wait from 1 to 3 s can cut off a voice
  that starts about 2 s after the connect (amended, below).
- Under the fields, always: the line is billed by the minute while it is open, silence included.
- A timer turned on starts at once on a quiet open line (amended, below); any other change applies
  the next time a timer is armed. A timer already counting is not moved, so a change never cuts
  the line mid-sentence.
- The 2 minutes after a handoff (`resultWindowSeconds`), during which silence does not close the
  line, stay as they are.

## Decisions

- **Fields from 0 to 300, not a list of choices** (the owner). 300 s is a ceiling the owner set.
- **The first-word wait and the noise cap are settings too** (the owner), with the same range.
- **0 switches off only its own timer** (follows from the above, amended for the first word): an owner who wants a line that
  never closes for quiet sets all three to 0.
- **Short values warn and are kept** (my call, against the first brief's "do not let it go below
  what the voice needs"). The owner set the range at 0 to 300; a refusal would stop only them, and
  the warning gives the reason.
- **The machine gets the values at each event, not at each line** (my call). `CallMachine` stays
  pure: `Bridge` hands it the current values before each event, as it reads the other settings
  through closures.
- **A plain `TabView` in the existing window** (my call), not a SwiftUI `Settings` scene: the app is
  an AppKit menu bar app with its own `SettingsWindow`, which a notice must open programmatically,
  and macOS 14 offers no supported way to open a `Settings` scene from AppKit.

## Amendments after review

The PR #80 review found two cases the design above left open; the owner decided both on
2026-11-10.

- **A first-word wait of 0 waits as long as the silence** instead of switching that timer off. A
  line a result opens usually opens while the owner is away, and the voice stays silent on about 4
  in 14 of them, so a 0 there alone kept the line open, billed and listening, with no bound. With
  all three at 0 the line still never closes for quiet. A wait of 1 to 3 s warns: the voice often
  starts about 2 s after the connect.
- **A timer turned on starts at once on a quiet open line.** The decision "a change applies the
  next time a timer is armed" left a line whose silence was 0 open until someone spoke, after the
  owner turned it back on. Now a change arms the silence when the line is live, nothing counts and
  no result is overdue (`CallEvent.timeoutsChanged`). A timer already counting is still not
  moved, so a change never cuts the line mid-sentence.
- A value read from the file is kept in 0 to 300 (`Timeouts.clamped`), as the field keeps it.
- The noise hang-up message no longer names 90 s.

## Migration

A settings file without a field gets its default (20, 5 and 90 s), so nothing changes for anyone who
has not touched them. A hand-edited value outside 0 to 300 reads as the nearer end.

## Documentation

- The README's opening paragraph and its Billing section say "after 20 seconds of quiet", "90
  seconds" and "the usual 20 seconds": each says the line closes after the silence set in Settings,
  and the Settings section describes the tabs and the three fields with their defaults. It is the one
  home of the defaults.
- `docs/architecture/overview.md` names the settings instead of "20 s", "5 s" and "90 s" and links to
  the README for the values.
- The README's translations under `docs/i18n/` get the same changes.
- CHANGELOG, Unreleased: the setting and the tabs.

## Not in scope

- The summary model and the UDP/TCP choice: their own changes add them to the sections named above.
- A per-session pause, or a pause that adapts to the owner.
