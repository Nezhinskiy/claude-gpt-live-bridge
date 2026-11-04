# The voice knows the Claude session

Status: proposed, 2026-11-04.

## Why

The voice is the owner's way into one Claude Code session, yet it often does not know what is in
it. Asked to "look at the chat", it said it would and did nothing: it has no tool, and the only
action `codex` gives it is a handoff. It reads "the chat" as its own conversation. Context reaches
it only when the band's Start or Load context asks for a summary, so a call started from the menu,
a line reopened after silence, or a switch to another session starts from an old summary or none.
An answer that came for a session that was not the target is heard only as a chime, and after the
owner switches to it the voice neither knows that session nor says the answer.

The owner wants the voice to have the session's current context at once and to refresh it on
request, without making Claude do anything in the chat.

## What the owner sees

- Any Start (the band, the menu, the socket) and every line the app opens again give the voice
  the target's context. The line does not wait for it.
- Asked about "the chat", "the context", "what is there" or "have a look", the voice answers from
  what it has; if that does not cover it, it fetches the session's context itself and answers
  from that, in its next reply. Nothing appears in Claude Code and Claude runs no turn.
- Switching the target to another session during a call gives the voice that session's context,
  and the voice says the answers that came for it while it was not the target.
- The Conversation submenu shows a fetch as a line of its own (`Context requested`), not as a
  Task.

## Decisions

- **When a summary is written.** At a Start, at a line opened again, at a target switch and on
  the voice's request; each reuses the last summary while no turn has completed since it was
  written (the mod's rule today), so only a session that moved costs a model call. No summary
  after every turn: each is a call on the owner's Claude plan.
- **How the voice asks.** `codex` declares no client tools to the realtime voice (checked against
  `codex app-server generate-json-schema --experimental`, codex-cli 0.166.0: `thread/realtime/start`
  takes no tools), so the voice asks with a handoff whose brief is exactly `refresh context`. The
  app takes that handoff itself and never queues it for Claude. A brief that does not match goes
  to Claude as any handoff: the owner still gets an answer, at the cost of a Claude turn. This is
  a model instruction, not a control; it decides only where a request goes, never what Claude may
  do.
- **What a fetch returns.** The summary, as the `[CONTEXT]` line today, and Claude's last reply
  word for word as a new `[LAST]` line, with the open question and its options when Claude is
  waiting on one. The last reply needs no model call.
- **"The chat" is the Claude session.** The voice prompt says so: the chat, its context, what is
  there and having a look always mean the session the voice serves, never the voice's own
  conversation.

## Design

### Wire

`POST /v1/context` gains an optional `last`: Claude's last reply, with the open question when
there is one. An older mod sends no `last` and an older app ignores it. `Wire.swift`,
`plugin/hooks/wire.ts` and `wire/fixtures/` change together: `context.json` with `last`, and the
existing fixture without it.

### Mod

- On `Work.context` it sends the summary under today's cache rule and, in `last`, the final text
  of the last main-loop turn. While Claude's `AskUserQuestion` is open, the question with its
  options (`askedText`) follows that text.
- The last reply is kept in `$.store` beside the join, so a reload keeps it.

### App

- **Taking the fetch.** `Bridge.route` normalises a handoff's brief (case, whitespace, trailing
  punctuation). `refresh context` is not queued: the app asks the target for its context
  (`registry.requestContext`), marks that context as awaited by the voice, records a
  `Context requested` line, and the call machine holds the line open as after any handoff.
- **Answering it.** When `/v1/context` comes for the awaited session, the `[CONTEXT]` line and,
  when `last` is present, `[LAST] label: …` (redacted and cut by `AnswerShaper`, `[LAST]` to
  2,000 characters) go to the live line as speech (`appendSpeech`) and count as the answer that
  ends the wait. Context nobody awaited goes in quietly (`appendText`), as today. Both are kept
  in the conversation, `[LAST]` as `continuity` keeps context today.
- **Asking at the right moments.** `perform(.start)`, opening a line again, and a target change
  during a call ask the target for its context, unasked and without holding anything up. The
  Auto-context setting, which asked only on a target change, becomes this rule and goes.
- **A switch says what was held.** Answers that came for a session while it was not the target
  wait unheard (their chime is PR #27's). When that session becomes the target during a call,
  they go to the line as speech after its context.
- **The voice prompt** (`VoicePrompt.swift`): the rule on "the chat"; to fetch, hand off exactly
  `refresh context` instead of saying it will look; `[LAST]` is what Claude last wrote in the chat,
  used and read out only when the owner asks for it.

## Failures

- **No summary within 60 s.** The mod gives up as today; the app ends the wait and the voice is
  given `[FAILED] label: context not available` to say.
- **No target, or it left.** The fetch is taken and answered at once with the no-session
  sentence; nothing goes to Claude.
- **An empty session.** No summary; `[LAST]` alone when there is a last reply, otherwise a line
  to say that the session has no messages yet.
- **Two fetches at once.** The second joins the first, as the mod's sends do today; the voice
  gets one answer.

## Testing

- BridgeCore: the brief is taken in any case and punctuation; a near miss goes to Claude; a fetch
  is answered as speech and ends the wait; `[LAST]` is redacted and cut; Start, a reopened line
  and a target change ask for context; the 60 s timeout; a `/v1/context` without `last` is
  accepted; held answers are said after the context on a switch.
- Mod: `last` comes from the last turn and from an open question and survives a reload; a fetch
  with no new turn makes no model call.
- Wire: both `context` fixtures decode on both sides.
- By hand, once: `scripts/smoke.sh` with "look at the chat" ends in `refresh context` and a spoken
  answer (about a minute of the owner's realtime voice).

## Not in this

- Mute and the line timers as settings wait for the synthetic first utterance (PR #27, ADR 0001
  item (n)).
- A summary after every turn.
