# Connect the voice over TCP

Status: in progress, 2026-11-10; revised that day after the review
(`docs/reviews/2026-11-10-voice-transport-review.md` on branch `review/pr79-voice-transport`).

## Why

On 2026-11-09 the voice broke up for minutes at a time. A debug build's call statistics (PR #72,
`--call-stats`) showed 40 to 52% of the incoming audio packets lost, while pings to the router,
1.1.1.1 and the media server lost nothing. The media server's answer offers four UDP host
candidates on port 3478 and two passive TCP host candidates on port 443, and negotiates only
`transport-cc`: no NACK and no RED, so a lost packet is lost for good.

Two debug experiments in `AudioHost.applyAnswer` moved the line to TCP on real calls:

| Experiment | Result |
|---|---|
| UDP candidates removed from the answer | Connected over TCP 443 (2026-11-09): 0 of 28,213 packets lost in 10 minutes |
| UDP candidates' priority lowered to 1000 | WebKit chose TCP, with UDP still in the answer (2026-11-10) |

By ear, on a poor connection TCP turns speech breaking apart into short pauses between phrases,
which the owner prefers. UDP stays the default: on a good connection it has the least delay. The
loss figure is from the removal; the shipped way, lowering the priority, was seen once to choose
TCP and has no loss figure of its own.

## What the owner sees

Settings, in the Voice section, has **Connect over TCP**, off by default, with the caption: if the
voice breaks up on a poor connection, turn this on; the line prefers TCP, which can turn breakups
into short pauses, and can still fall back to UDP. An open voice line reconnects.

- With no line open (the call off, or listening), the change is saved and the next line uses it.
- With a line connecting or open, the switch first asks: the current line closes now and opens
  again over the chosen transport, and what the voice is saying is cut off. **Reconnect** saves the
  setting and reopens the line at once; **Cancel** leaves both the setting and the line as they
  were. The trade-off is in the caption only.
- The reopened line is a new realtime session that continues the conversation, as any line does
  (the same seed: the session's recent lines, context and open tasks). Everything else about the
  call stays as it was: a result the line was waiting for is still awaited and said when it
  comes, results not yet heard stay, and the silence and first-word waits are those of the line
  before. The words of the cut-off reply leave the menu, since no final text comes for them.
- Nothing in the app shows which transport a line actually took (see No statistics).

## Decisions

- **A line is reopened, not switched.** WebRTC picks the transport once, when the line connects.
  Moving an open line would need an ICE restart, a second offer and answer with the media server,
  and the codex protocol the app uses has no such call: `thread/realtime/start` takes one offer
  and gives one answer ([ADR 0001](../adr/0001-platform-findings.md)). The owner chose closing
  and reopening the line at once, behind a confirmation, over waiting for the line to close by
  itself.
- **A reconnect changes the transport and nothing else.** `CallEvent.reconnect` keeps what is
  awaited and unheard and every timer state, and clears only what belonged to the cut-off reply
  (the voice speaking, an unfinished acknowledgement). It gives one effect,
  `reopenRealtime(preroll:)`, with the pre-roll while the owner is speaking. The bridge runs it as
  one step: it closes the line, then opens it again only if the call is still connecting with no
  other attempt under way, so a Stop, a new target or a second reconnect during the close opens
  nothing. (The first version reused the hang-up and the "a result opened this line" path, which
  forgot awaited results and let a Stop during the close open a line; the review found both.)
- **The bridge decides, the window only asks.** The window asks only when its last status shows a
  line connecting or open. The bridge's reconnect does nothing unless a line is connecting or
  open at that moment, so a line that closed while the question was up is not opened again. The
  question is a courtesy, not a control: a wrong guess either way costs one line.
- **TCP is preferred, not forced.** The answer's UDP candidates keep their place with priority
  1000, the value tested, so TCP pairs rank above them. They are not removed, so if no TCP pair
  connects ICE can still use UDP. That fallback is not verified (below).
- **An answer with no TCP candidate is not touched.** It goes to WebKit byte for byte as it came,
  exactly as with the setting off, so the setting cannot stop such a line connecting. A unit test
  holds this.
- **The rewrite is pure and in `BridgeCore`.** `Bridge` reads the setting once per line, right
  before it applies the answer, and passes the rewritten answer to the audio page. Its tests check
  what reaches `applyAnswer` both ways. Only `a=candidate:` lines whose transport is `udp` (any
  case) change, and in them only the priority; every other line, and the line endings (`\r\n` or
  `\n`), stay as they were. No `#if DEBUG` code is on this path.

## No statistics

The README and SECURITY.md promise no telemetry. This change adds no `getStats` call, counter or
log to a release build, so the app cannot show which transport a line took; the README's known
limitations say so. The debug-only `--call-stats` gains an `onTcp` column, read from the selected
candidate pair's local candidate (1 for TCP, 0 for UDP), compiled out of a release like the rest
of it. (Superseded 2026-11-12: `--call-stats` became debug mode, off by default and in every
build, which keeps the `onTcp` column; see
[the Settings and menus design](2026-11-11-settings-toolbar-and-menus-design.md).)

## Privacy wording

The README's Settings section describes the switch as a preference, not a guarantee. Its Privacy
section adds that with **Connect over TCP** on the audio still goes to OpenAI's media server, and
may go over TCP (port 443 in the answers seen) instead of UDP: the port is the server's choice,
not LiveBridge's. The offer is unchanged: it lists the same local candidates either way.

## Not verified without a real call

- That a line with the setting on connects over TCP in the shipped code path, not only in the
  debug experiment, and what it then loses. Check: one call with the setting on with debug mode on
  (formerly a debug build with `--call-stats`), reading `onTcp` and the loss columns. Watch also for a line that moves back
  to UDP mid-call (`onTcp` going to 0), which an ICE agent may do when a TCP pair stalls.
- The UDP fallback when the answer has a TCP candidate but no TCP pair connects. Check: one call
  with outbound TCP to port 443 blocked by a temporary `pf` rule for the media server's address;
  the line should connect over UDP, maybe after a few seconds. The page gives up after 10 s.
- That **Reconnect** during a live line reopens it cleanly on real codex. The unit tests cover the
  bridge's steps against a fake codex and audio page, a Stop, a new target and an open in flight
  during it included.
- The Settings switch, its confirmation, and that **Cancel** draws the switch back: the alert
  shows only with a line open.

Each of these spends realtime minutes, so none runs without the owner's go-ahead.

## Migration

A settings file without the key reads as off, so every update keeps UDP.
