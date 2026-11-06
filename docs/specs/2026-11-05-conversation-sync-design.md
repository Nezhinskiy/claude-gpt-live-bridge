# Conversation sync

Status: delivered in part, 2026-11-06. Open checks, which only the owner can run: a typed prompt
in the real desktop app, to settle the origin the mod reads (inferred, not observed); a real model
on this branch (every Claude text in the manual check was canned); Load context in the real menu
(never seen); and whether the voice announces a permission prompt on a live line (Goals; counts in
[ADR 0001](../adr/0001-platform-findings.md) (n)).

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
- The target's open line learns them as they happen, as context. The voice may repeat them; it must
  never fall behind.
- Claude's questions and permission prompts in the target are given to the voice to say whatever
  started the turn, typed or voice, and the voice may say them. Nothing makes it: a prompt on a
  live line went unannounced in the runs counted in ADR 0001 (n). The owner may be away from the
  Mac while LiveBridge is on, so this is a goal the code does not enforce.
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

Anything implicit or rough: the owner must never have to wonder whether the voice knows. A sync
that silently misses turns while the menu says it is current is a failure even if every line
technically arrives. A voice that opens a closed line to comment on what was typed is one too; on a
line already open, repeating it is fine (the owner's decision, 2026-11-06).

## What the owner sees

- While a session is joined, what the owner types in it and Claude's final answer go into that
  session's conversation with the voice. If that session is the target and its line is open, the
  voice gets them at once, and may say so; otherwise the next line seeded with that conversation
  has them.
- **By default the sync runs always**, also while the call is stopped: a stopped call keeps
  writing to the conversations on the Mac. Nothing leaves the Mac until a line opens with that
  session ([What leaves the Mac](#what-leaves-the-mac)).
- **Settings gains "Pause sync while the call is stopped", off by default.** For text the owner
  does not want to reach OpenAI: press Stop, then type. With it on, nothing the owner types while
  the call is off is recorded, a prompt typed into a running turn included, and the session is
  marked out of sync. While the setting is on, no line loads a summary by itself either: only
  Load context or `/live context` does.
- **Load context** in the menu is enabled only when the target is out of sync or has never had a
  context; otherwise it is disabled, because the voice is already current. `/live context` keeps
  working always (an explicit request).
- **The setting "Load context automatically when a line opens" is removed.** A line loads a
  summary by itself only when its session has never had one, or is out of sync for a reason other
  than the pause; never after a pause, and never while the pause setting is on, because the summary
  is written from the whole transcript and would carry the paused text to the voice. After a pause,
  the owner decides with Load context. **New conversation** and removing a session keep the mark.
  An owner who had turned that setting off gets the pause setting on at update, so summaries stay
  by hand; the changelog says that turns typed while the call is on now sync (my call).
- Claude's question in the target, from any main-loop turn, is given to the voice and opens a
  closed line, as a voice turn's question does today; the voice may say it, and the owner may
  answer it by voice or at the keyboard. A permission prompt is given the same way, with what
  Claude wrote in its step. On a live line, for the line's own session, both go as speakable text
  (`.speak`, `appendSpeech`), whoever started the turn, as a result does; whether the voice says
  them is the model's choice.
- Answering Claude's question at the keyboard drops the question from the voice's queue, as now,
  and adds a context line with the answer ("You answered at the keyboard: …"). Settling a
  permission prompt at the keyboard adds a line that it was settled, and that it was allowed where
  the mod can tell. No hook reports a person's denial, so a denial is only "settled".

## Decisions

- **Context, not delivery, for synced turns.** A synced line never opens a line, never chimes and
  never counts as unheard. Only questions and permission prompts are delivered to be said, as today.
- **On an open line, a synced line goes in at once** (the owner's decision, 2026-11-06). If the
  owner talks to the voice and types to Claude at the same time, the voice must not fall behind; it
  may repeat. codex's `appendText` is the only way to add context, and the voice reacts to appended
  text (ADR 0001 (o): a filler in 3 of 6 runs while the owner spoke, the lines said aloud in 3 of 3
  on sound alone, and a fragment at connect in 3 of 3). That is accepted. Holding lines for the
  owner's next words failed its probe. While a line connects, its lines wait for the
  connect; a line opened later is seeded with them, as history.
- **Questions and permission prompts outside the target** (my call, from "sync without opening a
  call"): from a typed turn they are recorded as context only, with no chime and no unheard count;
  from a voice turn they keep today's behaviour. A question still open when its session becomes the
  target is in the seed, and the owner may answer it by voice, as a target's own question. A change
  of target, by the menu or by `POST /v1/target`, ends a question's route and takes another
  session's waiting question off the line's queue, so it is not said on the new target's line and
  the reply reaches no wrong session; it stays recorded for that session's seed. A pause at the
  plan's limit keeps its route, as the target did not change.
- **A turn's sync is decided when it starts** (my call). The call state and the pause setting at
  the turn's start decide for its prompt, its keyboard answers and its final answer alike, so a
  paused prompt never has its answer synced after Start, and a turn typed while the call was on
  stays synced if it finishes after Stop. One exception, from "press Stop, then type": what the
  owner types after Stop with the pause on is dropped even into a turn that started synced, and
  the rest of that turn stops syncing, as its answer may repeat it. The own turn of a prompt typed
  into a running turn keeps that turn's decision.
  A voice turn holds nothing of the owner's until the owner types into it, so its start refuses
  nothing and marks nothing, whatever the call: only what was typed under the pause is dropped, and
  its answer goes as an answer, past the turn's decision. A voice turn typed into so is refused like
  any other, and its answer may repeat the text too: the request the turn names closes as failed,
  with its text neither recorded nor said. A request that only waits behind the turn is not its
  own and keeps its answer. A turn whose `start` never arrived has no decision, and its prompt may
  be the paused text: while the session is *paused*, a line of Claude's opening it stays out.
- **A spoken reply makes the rest of the turn a voice turn** (the owner's decision). When the owner
  answers a typed turn's question by voice, the voice hands it off and the line waits for a result
  (up to 120 s, billed); so the mod then tracks that turn as a voice turn, and its final answer is
  spoken like any voice turn's. With another voice request already waiting behind that turn, the
  answer is spoken as an update to it. Either way the turn's later lines name that request. Answered
  at the keyboard, the turn stays typed and its answer is context: the owner is at the Mac.
- **Text typed into a running turn** (a `prompt.submit` with a `turnId`, voice turns included) is
  the owner's words and is synced as a typed owner line (my call).
- **Only the owner's words are the owner's** (my call). A prompt from another agent, plugin or
  schedule is not recorded as the owner's: only origins the mod takes to be the owner's are, and
  that is `composer` alone (`OWNER` in `plugin/hooks/turns.ts`). In a terminal and a host's
  message marked `human` it was observed; **in the desktop app it is inferred**, from transcripts
  that stamp the owner's text `human`, and never observed. If the desktop app arrives as `sdk`,
  nothing typed there is recorded, no gap is marked and the menu says the context is current; one
  typed prompt there, read in the mod's origin, settles it. The turn's answer is synced all the
  same.
- **The kept window.** When the lines since the session's summary no longer all reach the voice,
  rolled off the kept window or past what codex's seed limits carry, the next line loads a fresh
  summary itself and the menu says the session is out of sync (my call): the voice never silently
  forgets turns while the menu says it is current.
- **The mod reports facts, the app decides policy.** Every main-loop turn opens with a `start`, a
  voice turn's included, and every line and activity names its turn. The mod posts a turn's answer
  as a line unless it is a voice request's, whatever the call state; the app applies the pause
  setting and records out-of-sync. The mod needs no setting of the app's.
- **Out of sync has two causes,** and they differ only in whether a line may load a summary
  itself:
  - *missed*: a turn the app did not receive (the app was not running, the session was not joined,
    a post failed). A line may load a summary itself. A mod that predates sync is not
    marked; see Older peers.
  - *paused*: the owner's pause setting dropped a turn, or a turn was missed while the setting was
    on. Only Load context, or `/live context`, loads one.
  A loaded summary clears both, unless the app asked for it before the latest gap or New
  conversation: that one is ignored, as it does not cover the gap and may hold what was forgotten.
  A summary nobody asked for (`/live context`) cannot be dated, and is taken, unless an older ask is
  still open. So a `/live context` summary written across a turn the app refused (Stop, then typing
  under the pause) can clear the *paused* mark, and the paused text may be in it; the mod drops a
  summary only across a gap it notes itself, and a refused line answers 200. Accepted, as the chain
  needs the pause on, a line, Stop and typing all inside one summary. The flag persists
  with the conversation across app restarts.
- **Redacted and clipped.** Each synced line goes through the existing redactor
  (`Text/Redaction.swift`), loses its code and tables as an answer does, and is clipped to at most
  2,000 characters (my call; the builder may tune it against codex's `initialItems` limits in
  `Continuity`, 128 items and about 8,192 tokens). A typed line is marked as typed, so the voice can
  tell it from speech.
- **Older peers.** A newer mod against an older app gets an unknown route and carries on as today.
  An older mod against a newer app (its join does not say it syncs) is not marked at all: the
  app asks the registry whether the session syncs (`Bridge.needsContext`, `SessionRegistry.syncs`),
  so each of its lines loads a summary as it does now. It reports only its voice turns and names
  no turn, so what it reports is said as ever, and no pause refuses it.
- **No change to the permission boundary.** The approval notice from a typed turn is a notice; the
  mod still declares no `tool.check` hook.

## Design

### Mod

- `turn.start` / `turn.complete`: a main-loop turn that is not a voice request (`typed`, or a
  `background` turn outside the follow-up window, whose answer today goes nowhere) is posted to
  the app: the owner's prompt text for a typed turn (not for background, whose prompt is not the
  owner's words), and Claude's final answer when the turn completes with an answer. Posting the
  prompt at the turn's start lets an open line know before Claude finishes. Every main-loop turn
  opens with a `start`, which takes its decision, so the app has a real turn.
- The guards on the AskUserQuestion `tool.call` and `classic.PermissionRequest` hooks widen from
  "a voice turn is running" to "a main-loop turn is running and the session is joined". The race
  between a spoken reply and the keyboard stays as it is for questions. A spoken reply tells the
  mod which request the turn's answer now belongs to; the app decides that.
- When the keyboard wins the AskUserQuestion race, the mod posts the answer as a synced line.
  When a permission prompt settles, it posts that it was settled: allowed when that very run of the
  tool ran (same tool, input and agent), and otherwise only settled, once the next model step or the
  end of the loop that asked shows the dialog is gone. The app has one activity row for what waits,
  and the mod holds every open prompt, so it posts `working` only when nothing else waits, no
  `approval` while Claude's question is open, which would take the question back, and `working`
  first when a question opens over a prompt, as the app says what waits only on a change to
  `approval`.
  That line is the mod's report (`report`), not the owner's typing, so it goes as Claude's and
  never refuses a turn under the pause. So does a question closed with no answer; a keyboard answer
  to Claude's question is the owner's (`typed`). So does a turn that ends without an answer
  (interrupted, refused, an error, or an empty answer), under the turn's decision, so the voice
  does not take the work for pending; a voice turn closes its request as failed instead, and posts
  no second line. A plain No at a permission dialog, or a cancelled question, therefore gives two
  report lines: that it was settled or closed, then that the turn ended without an answer.
- The hooks' posts to the app go in the order the hooks ran, in a queue of their own, and a hook
  waits for them at most 200 ms: the app answers a line once the open line took it, up to 20 s with
  codex stuck, and typing must not wait for that. Not through the link's `serial`: the app drops a
  session that stops polling after 5 s, so a held line must leave the poll running.
- The mod tracks whether every turn since the last delivered summary reached the app. When one did
  not (no link, a refused post, a lost voice answer, a turn before joining, a turn while the mod was
  off, a question or permission notice the app did not take), its next join says the session is
  *missed*.
- The summary cache (`summary`, `staleSummary`) stays, but goes stale with every completed turn and
  every gap: a summary the app asks for has to hold what the conversation could not carry. A summary
  still being written when the mod notes a gap is not posted either: `/live context` has no ask for
  the app to date, so only the mod can drop it.

### Wire

One new route, mod to app, for a synced line: the session, its `turn`, its `kind`, and its text;
and on join, whether the session syncs at all and whether it missed a turn. Every main-loop line and
activity carries `turn: { id, request? }`: the turn, and the voice request its answer belongs to, if
one does; an activity between turns has none, and neither has a released mod's. `kind` is what the
line is: `start`, a turn's first word, which takes its decision and is the only kind with no text;
`typed`, the owner's words, the only kind that refuses a turn; `answer`, Claude's final answer;
`report`, the mod's own line. Speaker and tag follow from it: `[TYPED]` as the owner's, or `[CLAUDE]`
as Claude's.
A reply work item names the request its turn's answer belongs to. New fixtures for each shape, `/Users/example`, `Example session`,
`00000000-…` ids. `Wire.swift`, `plugin/hooks/wire.ts` and `wire/fixtures/` change together.
`StatusReply` tells the mod nothing new, unless the builder needs the target's out-of-sync state
for the band.

### App

- A synced line is recorded in its session's conversation (`Bridge.record`, `Continuity`): owner
  lines as the owner's (marked typed), Claude's as Claude's. It is not an unheard result
  (`initialItems` must include it, unlike an unheard `.claude` line).
- If its session is the open line's, it goes in with `addContext` at once on a `live` line, and on
  connect for a `connecting` one, which `CallMachine` keeps; `heldContext` stays the summary's one
  slot. A line opened later is seeded with it.
- An answer under a request a newer one superseded is not said, and the mod is told it was taken,
  so it is a synced line of Claude's, unless it failed or its request is withheld.
- With the pause setting on and the call `off`, a line of a turn with no voice request behind it
  is dropped, as is a `typed` line of any turn, and its session marked *paused*.
- `openLine` requests a summary only when the session has no context or is *missed* (and not
  *paused*); `Settings.autoContext` and its toggle in `SettingsView` go, and decoding an old
  settings file maps the key: `autoContext: false` becomes the pause setting on
  (`Settings.init(from:)`), as "What the owner sees" says.
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
too. The mitigation is `/clear` with **New conversation**; removing a session holds until it joins again; the pause
setting with Stop keeps new text out and removes nothing already recorded. The docs also say what is
stored and for how long, and that Claude's later answers can repeat paused text. A page Claude reads in a typed turn can now steer the voice through
Claude's answer, as it already could in a voice turn. `docs/architecture/overview.md`; and the
2026-11-04 voice-session-context spec is marked superseded where it says typed turns do not reach
the voice and that auto-load stays on.

## Left to the builder

The clip length; how the typed marker is
worded; `keptLines`; the menu's wording for a disabled Load context.
