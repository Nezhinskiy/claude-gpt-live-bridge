# Load a session's context on its first call

Status: delivered, 2026-11-09.

Supersedes one rule of the [conversation sync design](2026-11-05-conversation-sync-design.md),
which stays as the record of that decision: that no line loads a summary while **Pause sync while
the call is stopped** is on or the session is marked *paused*. That rule now holds only for a
session that has a summary, or with this setting off.

## Why

The owner started a call in an old chat with the pause on and got no context: the voice knew
nothing of the session, and only **Load context** would have told it. The pause is about what is
typed while the call is off. A first call with no context defeats the call, and the owner wants it
to load by default, with the pause applying after that first load.

## What the owner sees

Settings, in the Sync section, has **Load a session's context on its first call**, on by default.

- A line that opens for a session the voice has no summary for (`continuity[session].context ==
  nil`) asks that session for its context even if the pause is on or the session is marked
  *paused*. That covers a new session, an old chat joined for the first time, a chat after **New
  conversation** (its summary is gone) and a session the 20-session limit pushed out.
- Every line goes by the same rule: Start, a line reopened by speech, one opened by an answer or an
  approval notice, one for a new target.
- Once a summary exists, everything works as before: the pause governs what follows it.
- With the setting off, behaviour is exactly as before.
- The menu says **Context loads with the line** for a session the next line will ask, when the only
  thing that used to stop that line was the pause. A session with a gap (`missed`), too many lines
  for the seed or a mod that does not sync keeps **Load context** enabled, as before: a press need
  not wait for a line.

## Decisions

- **A summary is the test, not "the first call".** A call with no summary is what the owner wants
  covered, and it needs no new state: a first ask that produced nothing is asked again by the next
  line.
- **It goes over a *paused* mark too.** An old chat is often marked before its first call, because
  the pause was on while the owner typed in it. A setting that stopped at the mark would miss the
  case that started this.
- **It is a separate setting.** It widens what reaches OpenAI, so it can be turned off on its own.

## What it costs

A summary is written from the whole transcript and goes to OpenAI, so the first summary carries
text typed under the pause, and clears the *paused* mark (`Conversation.setContext`) as any summary
does. The pause no longer holds that summary back while the setting is on. SECURITY.md says so.

## Migration

A settings file with no value for the new key gets `true`, unless the pause is on after the legacy
mapping (`pauseSyncWhileStopped`, including an old `autoContext: false`); then it gets `false`.
Those owners chose that context loads only from the menu, and an update must not widen that
silently. Fresh installs and everyone without the pause get `true`. The changelog says that someone
with the pause on can turn the new setting on in Settings.

## What this does not change

The wire, the mod (it answers every ask the same and knows nothing of the pause), what the pause
records, and **Load context**.
