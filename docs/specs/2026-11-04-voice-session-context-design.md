# The voice knows the Claude session

Status: delivered in part, 2026-11-05. Line-open context and the rule that "the chat" is the
Claude Code session shipped. The fetch (`refresh context`), the `[LAST]` line and the wire field
`last` were taken out after six real smoke runs: the voice never sent `refresh context`, because
on GPT-Live the handoff brief codex reports (`input_transcript`, from the server's
`delegation.created` item) was the owner's own words verbatim every time, so a prompt rule cannot
make the voice send a fixed brief. That part is kept on branch `feat/voice-context-fetch`. The
shipped "the chat" rule sends a question the voice's lines do not cover to Claude as an ordinary
handoff, a Claude turn, not the fetch. Revised
on 2026-11-04 after a design, simplify and security review
(`docs/reviews/2026-11-04-voice-context-review.md` on `review/voice-context`).

## Why

The voice is the owner's way into one Claude Code session, yet it often does not know what is in
it. Asked to "look at the chat", it said it would and did nothing: it has no tool, and the only
action `codex` gives it is a handoff. It reads "the chat" as its own conversation. Context reaches
it only when the band's Start or Load context asks for a summary, so a call started from the menu
or a line reopened after silence starts from an old summary or none.

The owner wants the voice to have the session's current context at once and to refresh it on
request, without making Claude do anything in the chat.

## What the owner sees

- Every line the app opens (a Start's first line, a line reopened after silence, the line after a
  target switch) gives the voice the target's context, unless **Load context automatically** is
  off. The line does not wait for it.
- Asked about "the chat", "the context", "what is there" or "have a look", the voice answers from
  what it has; if that does not cover it, it fetches the session's context itself and answers
  from that, in its next reply. Claude runs no turn. The band shows "Loading context…" while the
  summary is written, as it does today.
- An older mod or app works as before: the new wire field is optional.

## Decisions

- **When a summary is written.** When a line opens (Start, reopen, switch) and on the voice's
  fetch. The mod reuses its last summary until a turn completes whose answer did not go to the
  voice (a typed turn, `/clear`): the voice already heard a voice turn's `[RESULT]`. So a line
  reopened after a voice turn costs no model call. No summary after every turn.
- **Load context automatically stays, on by default.** It decides whether a line opening asks for
  the summary; it is the owner's way to keep summaries off OpenAI unless asked. The fetch works
  either way, since the owner's own question triggers it.
- **How the voice asks.** `codex` declares no client tools to the realtime voice (checked against
  `codex app-server generate-json-schema --experimental`, codex-cli 0.166.0:
  `thread/realtime/start` takes no tools), so the voice asks with a handoff whose brief is exactly
  `refresh context`, in English. `RealtimeSession` recognises it where it parses codex's handoff
  item and emits its own event; it never reaches `route`, the question's route or Claude. A brief
  that does not match goes to Claude as any handoff. This is a model instruction, not a control;
  it decides only where a request goes.
- **What a fetch returns.** The summary, as the `[CONTEXT]` line today, and Claude's last reply
  as a `[LAST]` line: shaped as results are (code blocks and tables removed, redacted, one line),
  its end kept within 2,000 characters, with Claude's open question and options when one is
  waiting. `[LAST]` goes only in answer to a fetch: it is spoken, and neither stored, seeded into
  a later line, nor appended quietly. A typed turn's reply reaches OpenAI only this way, when the
  owner asked.
- **"The chat" is the Claude session.** The voice prompt says so, and says that a question from a
  typed turn waits at the keyboard: a spoken reply cannot answer it.

## Design

### Wire

`POST /v1/context` gains an optional `last`. The mod clips it to 8,000 characters at a line
break before posting (the socket takes 131,072 bytes). `Wire.swift`, `plugin/hooks/wire.ts` and
`wire/fixtures/` change together: a new `context-last.json` beside `context.json`.

### Mod

- It keeps in memory, like its summary, Claude's last main-loop reply (`turn.complete`'s answer,
  or, while `AskUserQuestion` is open, the step text Claude wrote when it asked) and the open
  question (`askedText`), typed turns included. `/clear` clears both.
- On `Work.context` it posts the summary (or `''` when there is none or it failed) with `last`.
  An empty session with no last reply posts nothing, as today.
- The band's Start no longer asks for context itself: the line it opens does.

### App

- **The fetch.** `RealtimeEvent.contextFetch` comes from `RealtimeSession` for a brief whose
  words are `refresh context`. The bridge asks `registry.target` for its context with a fetch
  deadline (`SessionRegistry`, beside `wantsContext`), records nothing in the conversation, and
  tells the call machine a fetch is awaited for that session (`CallEvent.fetchAsked`), which
  holds the line open. With no target, it answers at once with the existing no-session line.
- **The answer.** `/v1/context` for a session with a fetch due builds the `[CONTEXT]` line as
  today (stored, seeded later) and, when `last` is present, the `[LAST]` line (not stored). Both
  go to the machine as `CallEvent.fetchAnswered([VoiceLine])`, which speaks them on a live line
  for that session (held while the owner speaks, said after the grace) and ends the fetch's wait;
  they never enter `unheard` or `awaited`. An empty summary keeps the stored context.
- **The timeout.** `sweep()` fails a fetch whose deadline passed (`ContextLoads.timeout`, 60 s)
  with `[FAILED] label: context not available`, spoken as the fetch's answer. A session that
  leaves, a target change, Stop and a closed line drop the fetch; context that comes after is
  routine.
- **Routine context.** `openLine` asks the target for context when Load context automatically is
  on. Context for the line's session that arrives while the line connects is added once it is
  connected; a context line equal to the stored one is not added or saved again.
- **The voice prompt** (`VoicePrompt.swift`): the rule on "the chat"; to fetch, hand off exactly
  `refresh context`; `[LAST]` is Claude's last reply in the chat, said in answer to the fetch; a
  typed turn's question waits at the keyboard.

## Failures

- **No summary within 60 s.** The mod gives up at the same 60 s and posts nothing, so the voice
  gets `[FAILED] label: context not available`, even when Claude's last reply was at hand.
- **The summary failed.** With a `last`, the voice gets `[LAST]` alone; without one,
  `[FAILED] label: context not available`.
- **No target.** The existing `[FAILED] LiveBridge: no Claude Code session is joined.`
- **An empty session.** The mod posts nothing; the fetch fails after 60 s as above.
- **Two fetches at once.** The second joins the first in the mod; the app keeps one deadline.

## Testing

- BridgeCore: the brief is taken in any case, punctuation, quotes and backticks; a near miss goes
  to Claude; a fetch with a question open keeps the question's route; a fetch while Claude works
  on a handoff to the same session keeps that wait; the fetch's answer is spoken and is not
  unheard; `[LAST]` drops a fenced block, is redacted and keeps its end; the 60 s timeout; a stale
  fetch is dropped on a target change and on the session leaving; `openLine` asks only with the
  setting on; context that arrives while connecting reaches the line.
- Mod: `last` from the last turn, from the question step, and from an open typed-turn question;
  `last` is clipped; a voice turn leaves the summary cached; `/clear` clears `last`.
- Wire: both `context` fixtures round-trip on both sides.
- By hand, once: `scripts/smoke.sh` gains a "look at the chat" case that passes on a
  `refresh context` handoff the fake session never receives (about a minute of the owner's
  realtime voice).

## Not in this

- Saying the answers held for a session when the owner switches to it: it reworks how unheard
  lines are kept per session and lands with PR #27 in a spec of its own.
- Mute and the line timers as settings, which wait for the synthetic first utterance (PR #27,
  ADR 0001 item (n)).
- A summary after every turn.
