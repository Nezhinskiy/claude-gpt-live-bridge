# Conversation sync

Status: approved, 2026-11-06.

## Why

The owner works with a Claude Code session two ways at once: by voice through LiveBridge, and at
the keyboard. Today only the voice half reaches the voice. A turn the owner types, and Claude's
answer to it, never reach the voice, except as part of a summary the next line may load
(`plugin/hooks/turns.ts`, `TurnTracker.turnCompleted` drops an untracked turn). A question Claude
asks, or a permission prompt it waits on, reaches the voice only inside a voice turn
(`register.tsx`, the `tracker.running !== null` guards). And when the owner answers Claude's
question at the keyboard, the app only drops the question (`Bridge.activity`, `withdraw`): the
voice never learns what was chosen.

So the voice and Claude can hold different contexts, and nothing shows it. The owner then speaks
to a voice that does not know what was just discussed. That is the problem this solves.

Success, in the owner's words: several sessions, switch between them, type into them, talk to
them, and each stays in sync on its own; the voice always knows what was written and discussed;
**Load context** is never needed unless the owner chose to pause the sync.

It also answers R-6 and R-9 of the PR #34 review (`docs/reviews/2026-11-05-pr34-review.md` on
`review/pr34`): R-6 is closed as superseded (the opener hold it relied on was reverted in #34);
R-9's real gap was that the voice is not told the keyboard answer, which this spec closes.

## Goals

- Every joined session's conversation with the voice holds the owner's typed turns and Claude's
  final answers to them, as it already holds voice turns.
- The target's open line learns them as they happen, as context: the voice knows, and says
  nothing unprompted.
- Claude's questions and permission prompts in the target are said by the voice whatever started
  the turn, typed or voice. The owner may be away from the Mac while LiveBridge is on.
- An answer given at the keyboard to Claude's question reaches the voice as context.
- A target switch carries the new target's full synced conversation, with no summary to load.
- **Load context** is needed only after a gap in the sync, and the menu shows when that is.

## Non-goals

- **Claude's text in the middle of a turn** ("starting, checking the tests") is not synced; only
  the turn's final answer is.
- **Answering a permission prompt by voice.** LiveBridge never answers one
  ([SECURITY.md](../../SECURITY.md)); the voice announces it, the owner answers at the keyboard.
  Voice-only use with no prompts at all remains the session's own permission mode, with the risks
  SECURITY.md states.
- **Speaking a typed turn's final answer**, unless the owner answered its question by voice
  (Decisions).
- **Subagent turns** and tool output are not synced.

## Anti-goals

Anything implicit or rough: the owner must never have to wonder whether the voice knows. A voice
that interrupts keyboard work to comment on what was typed, or a sync that silently misses turns
while the menu says it is current, is a failure even if every line technically arrives.

## What the owner sees

- While a session is joined, what the owner types in it and Claude's final answer go into that
  session's conversation with the voice. If that session is the target and its line is open, the
  voice has them by the time the owner next speaks; otherwise the next line seeded with that
  conversation has them.
- **By default the sync runs always**, also while the call is stopped: a stopped call keeps
  writing to the conversations on the Mac. Nothing leaves the Mac until a line opens with that
  session ([What leaves the Mac](#what-leaves-the-mac)).
- **Settings gains "Pause sync while the call is stopped", off by default.** For text the owner
  does not want to reach OpenAI: press Stop, then type. With it on, turns typed while the call is
  off are not recorded, and the session is marked out of sync.
- **Load context** in the menu is enabled only when the target is out of sync or has never had a
  context; otherwise it is disabled, because the voice is already current. `/live context` keeps
  working always (an explicit request).
- **The setting "Load context automatically when a line opens" is removed.** A line loads a
  summary by itself only when its session has never had one, or is out of sync for a reason other
  than the pause; never after a pause, because the summary is written from the whole transcript
  and would carry the paused text to the voice. After a pause, the owner decides with Load context.
- Claude's question in the target, from any main-loop turn, is said by the voice and opens a
  closed line, as a voice turn's question does today; the owner may answer it by voice or at the
  keyboard. A permission prompt is announced the same way, with what Claude wrote in its step.
- Answering Claude's question at the keyboard drops the question from the voice's queue, as now,
  and adds a context line with the answer ("You answered at the keyboard: …"). Settling a
  permission prompt at the keyboard adds a line that it was settled, and whether it was allowed or
  denied where the mod can tell that reliably.

## Decisions

- **Context, not speech, for synced turns.** A synced line never opens a line, never chimes and
  never counts as unheard. Only questions and permission prompts are spoken, as today.
- **On a live line, synced lines wait for the owner's next words** (my call, from the anti-goal).
  codex's `appendText` is the only way to add context, and the voice has said appended text
  unprompted (ADR 0001 (b); in (n), 3 of 4 runs once the session held an owner turn). So a synced
  line that arrives while the line is open is kept and added when the owner next starts speaking,
  before the voice answers them; a line opened later is seeded with it, as history. The plan
  starts with a short probe of this on a real line, with the owner's yes (it spends realtime
  minutes): if the voice still comments on the held lines, the design comes back here.
- **Questions and permission prompts outside the target** (my call, from "sync without opening a
  call"): from a typed turn they are recorded as context only, with no chime and no unheard count;
  from a voice turn they keep today's behaviour.
- **A turn's sync is decided when it starts** (my call). The call state and the pause setting at
  the turn's start decide for its prompt, its keyboard answers and its final answer alike, so a
  paused prompt never has its answer synced after Start, and a turn typed while the call was on
  stays synced if it finishes after Stop.
- **A spoken reply makes the rest of the turn a voice turn** (the owner's decision). When the owner
  answers a typed turn's question by voice, the voice hands it off and the line waits for a result
  (up to 120 s, billed); so the mod then tracks that turn as a voice turn, and its final answer is
  spoken like any voice turn's. Answered at the keyboard, the turn stays typed and its answer is
  context: the owner is at the Mac.
- **Text typed into a running turn** (a `prompt.submit` with a `turnId`, voice turns included) is
  the owner's words and is synced as a typed owner line (my call).
- **The kept window.** When synced lines push a conversation's oldest line out of the kept window
  while the session's summary predates that line, the session is marked *missed*, so the next line
  loads a fresh summary itself (my call): the voice never silently forgets turns while the menu
  says it is current.
- **The mod sends, the app decides.** The mod posts every main-loop turn that is not already a
  voice request's answer, whatever the call state; the app applies the pause setting and records
  out-of-sync. The mod needs no setting of the app's.
- **Out of sync has two causes,** and they differ only in whether a line may load a summary
  itself:
  - *missed*: a turn the app did not receive (the app was not running, the session was not joined,
    a post failed, the mod predates sync). A line may load a summary itself.
  - *paused*: the owner's pause setting dropped a turn. Only Load context, or `/live context`,
    loads one.
  A loaded summary clears both. The flag persists with the conversation across app restarts.
- **Redacted and clipped.** Each synced line goes through the existing redactor
  (`Text/Redaction.swift`) and is clipped to at most 2,000 characters (my call; the builder may
  tune it against codex's `initialItems` limits in `Continuity`, 128 items and about 8,192
  tokens). A typed line is marked as typed, so the voice can tell it from speech.
- **Older peers.** A newer mod against an older app gets an unknown route and carries on as today.
  An older mod against a newer app (no sync support, known from `modVersion` on join, #32) leaves
  its session permanently *missed*, so its lines load a summary as they do now.
- **No change to the permission boundary.** The approval notice from a typed turn is a notice; the
  mod still declares no `tool.check` hook.

## Design

### Mod

- `turn.start` / `turn.complete`: a main-loop turn that is not a voice request (`typed`, or a
  `background` turn outside the follow-up window, whose answer today goes nowhere) is posted to
  the app: the owner's prompt text for a typed turn (not for background, whose prompt is not the
  owner's words), and Claude's final answer when the turn completes with an answer. Posting the
  prompt at the turn's start lets an open line know before Claude finishes.
- The guards on the AskUserQuestion `tool.call` and `classic.PermissionRequest` hooks widen from
  "a voice turn is running" to "a main-loop turn is running and the session is joined". The race
  between a spoken reply and the keyboard stays as it is for questions.
- When the keyboard wins the AskUserQuestion race, the mod posts the answer as a synced line.
  When a permission prompt settles (`PostToolUse` / `PostToolUseFailure`), it posts that it was
  settled, with allowed or denied only where the hook tells it reliably.
- The mod tracks whether every turn since the last delivered summary reached the app. When one did
  not (no link, a refused post), it tells the app the session is *missed*, on the next successful
  post or on join.
- The summary cache (`summary`, `staleSummary`) stays: the app still asks for a summary when a
  line needs one.

### Wire

One new route, mod to app, for a synced line: the session, who it is from (the owner typing, or
Claude), and its text; and a way to say the session missed a turn (a field on that route or on
join, the builder's choice). New fixtures for each shape, `/Users/example`, `Example session`,
`00000000-…` ids. `Wire.swift`, `plugin/hooks/wire.ts` and `wire/fixtures/` change together.
`StatusReply` tells the mod nothing new, unless the builder needs the target's out-of-sync state
for the band.

### App

- A synced line is recorded in its session's conversation (`Bridge.record`, `Continuity`): owner
  lines as the owner's (marked typed), Claude's as Claude's. It is not an unheard result
  (`initialItems` must include it, unlike an unheard `.claude` line).
- If its session is the open line's, it is kept and added with `addContext` when the owner next
  starts speaking (see Decisions), whether the line is `connecting` or `live`; `heldContext`
  becomes a list, not one slot. A line opened later is seeded with it.
- With the pause setting on and the call `off`, a synced line is dropped and its session marked
  *paused*.
- `openLine` requests a summary only when the session has no context or is *missed* (and not
  *paused*); `Settings.autoContext` and its toggle in `SettingsView` go, and decoding an old
  settings file ignores the key.
- The menu's Load context item (`StatusMenu`, `ContextLoads`) is enabled only when the target is
  out of sync or has no context.
- Continuity's `keptLines` (24) was sized for voice turns; synced typed turns will push voice
  lines out sooner. The builder revisits it within codex's limits.

### What leaves the Mac

While the call is on, the target's synced lines go to OpenAI with the line, like Claude's answers
to voice requests already do. Every other session's synced lines go when a line opens with it as
the target. Nothing is sent while no line is open, as today. The owner accepted this: Claude
already repeats much of the same text in its answers to voice requests.

## Docs in the same change

README (Privacy, How a call works, Settings, the Load context item) and its six translations;
`SECURITY.md`: "A loaded context persists" and the advice after it are rewritten, since turning
off auto-load no longer stops a session's text from reaching the voice: synced answers carry it
too. The mitigation is `/clear` and **New conversation**, removing the session from LiveBridge, or
the pause setting with Stop. A page Claude reads in a typed turn can now steer the voice through
Claude's answer, as it already could in a voice turn. `docs/architecture/overview.md`; and the
2026-11-04 voice-session-context spec is marked superseded where it says typed turns do not reach
the voice and that auto-load stays on.

## Left to the builder

The wire route's name and the *missed* signal's shape; the clip length; how the typed marker is
worded; `keptLines`; whether allowed or denied is reliably known from the hooks; the menu's wording
for a disabled Load context.
