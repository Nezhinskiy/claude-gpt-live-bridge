# Architecture overview

LiveBridge lets the owner of a Mac talk to an open Claude Code session. A voice model (GPT-Live,
reached through `codex app-server`) talks with the owner; the session's own Claude model does the
work. This document names the parts, what each promises, and how the messages flow. The
platform facts behind these choices are in [ADR 0001](../adr/0001-platform-findings.md).

## Components

```mermaid
flowchart LR
  subgraph Mac
    subgraph App["LiveBridge.app (menu bar)"]
      UI["Menu bar glyph and menu"]
      Bridge["Bridge actor<br/>call machine, session registry,<br/>continuity, usage meter"]
      Server["HTTP on a Unix socket<br/>(0700 run directory)"]
      Codex["RealtimeSession + JSON-RPC client"]
      Audio["Invisible WKWebView<br/>mic, voice detection, pre-roll, WebRTC"]
      Updater["Updater actor<br/>check, verify, swap"]
    end
    CodexProc["codex app-server<br/>(read-only, tools off)"]
    subgraph Engine["Claude Code session"]
      Mod["livebridge mod<br/>poll, prompts, band"]
      Claude["Claude (the session's model)"]
    end
  end
  OpenAI[("OpenAI realtime")]
  GitHub[("GitHub")]
  UI --- Bridge
  UI --- Updater
  Updater -- "release check; on Install: image, gh, claude plugin" --> GitHub
  Server --- Bridge
  Bridge --- Codex
  Bridge --- Audio
  Codex -- stdio --> CodexProc
  CodexProc -- signalling --> OpenAI
  Audio -- "WebRTC audio + data channel" --> OpenAI
  Mod -- "HTTP/1.1, 1 poll per second" --> Server
  Mod -- "prompt.submit" --> Claude
```

**`BridgeCore`** (Swift library, no UI) holds every rule, so it is tested without codex, a
microphone or Claude:

- `CallMachine`: the call's phase — `off`, `listening` (microphone and local voice detection only),
  `connecting`, `live` (a realtime session is open) — and the effects of each event. It also keeps
  `isMuted`, orthogonal to the phase: while muted the microphone is released, speech is ignored, and
  a result from Claude still opens the line. Mute closes no line. It ends the owner's speech only if
  they were speaking; then an open line's silence is counted from Mute (20 s), as if they had
  stopped speaking when they pressed it, and a line that was already quiet closes when it would have
  without Mute. A handoff whose answer is still awaited can still keep a line open, up to 120 s
  after the handoff, as without Mute. Stop and an audio failure reset it. It is pure; `Bridge` runs
  the effects in order.
- `SessionRegistry`: the joined sessions, the voice target, each session's queued and in-flight
  request, and their liveness. A session that has not polled for 5 s is dropped, and a request in
  flight for 10 minutes fails; either is reported to the voice as `[FAILED]`, unless the dropped
  session was the last one, which stops the call ([failure behaviour](#failure-behaviour)).
- `Continuity`: one conversation per Claude Code session, by session id: its last 64 lines
  (`keptLines`: the owner's speech and typing, the voice's, Claude's final answers to turns that
  were not voice requests, an answer a newer request superseded, the lines the session sent the
  voice and the brief of each request its queue took), the context loaded from it, and whether the voice is out of sync with the
  session (`missed`: a turn did not arrive; `paused`: the pause setting kept text out) with the
  decision on the turn last offered. A conversation written before these fields still decodes.
  `isCurrent` is false when the lines since the summary are more than the seed can carry
  (`initialItems`: 128 items, 8,192 estimated tokens, counted in UTF-8 bytes). Each new realtime session is seeded with the
  target's conversation, less those briefs (an open request goes in as its task), and only the
  target's open tasks (`initialItems`), so the voice does not notice it was replaced and never
  mixes two sessions' conversations; a new target closes an open line. A result from another session is spoken in the open line and kept in its
  own session's conversation. New conversation forgets the target's, removing a session forgets
  its own, and only the 20 conversations used last are kept; New conversation keeps a
  *paused* mark and the turn's decision, which the pause needs after it. A synced line (below) is
  recorded by `Bridge.sync` once `Continuity.admits` takes it: with the pause setting on and the
  call off the first line of a turn is refused and the session is marked *paused*; a Claude line
  of a turn admitted before Stop still goes in, and an owner's line refuses the turn from there
  on. A refused owner line also withholds the session's voice request in flight, whose
  answer then closes as failed with nothing of it recorded or said; a request waiting behind a
  typed turn is withheld as well, since the app cannot tell the two apart
  (`SessionRegistry.withholdAnswer`), and so are that turn's later questions and approval
  notices (`Bridge.activity`). The open line about the
  session is given an admitted line at once with `addContext`, a connecting one when it is
  connected.
- `RealtimeSession`: one ephemeral, read-only codex thread per realtime session; it refuses to go
  on unless codex reports every MCP server disabled, interrupts every codex turn and declines
  every request codex sends.
- `AnswerShaper` and `Redaction`: each delivery to the voice becomes one line, `[TAG] label:
  text`, of at most 2,000 characters, with the label cut to 120 characters, without code blocks
  or tables, and with credentials redacted.
- `UnixHTTPServer` and `Wire`: the mod's routes (below).
- `Update/`: the in-app update ([below](#update)). `AppVersion` and `Release` parse a version
  and GitHub's `releases/latest` reply strictly; `UpdatePolicy` says when a check is due and
  which copy may update; `DownloadRules` limits redirects to GitHub's hosts and the size of a
  download; `UpdateBundleCheck` reads the image's app and the programs' output; `UpdateRecord`
  and `UpdateState` are what a run leaves for the next launch; `UpdateProblem` gives each failure
  its sentence. `Updater` is the actor that runs a check or an install through
  `UpdateEnvironment`, a protocol over the network, the programs, the swap and the relaunch, so
  the tests use a fake.

**`LiveBridge`** (the app target) wires `BridgeCore` to the menu bar, to `SMAppService` for Open at
login, and to `AudioHost`: one `WKWebView` in an invisible window (one point, fully transparent,
click-through, ordered in on every Space, because WebKit holds back the microphone of a page it does
not consider visible), serving the bundled audio page under its own URL scheme. Before the page
opens the microphone, the app asks macOS for it itself (WebKit's request never shows the prompt for
this app); the prompt can stay up a while, so once macOS answers, `Bridge` looks at the call again:
a Start goes ahead only while the call is on, an Unmute only while it is on and not muted, and a
take no longer wanted does nothing and reports no refusal. The page owns the microphone, a voice
detector (−45 dBFS for 250 ms starts speech), a 2-second pre-roll and the WebRTC peer; after a
connect it plays the queued audio into the peer, dropping silence until it has caught up. Mute stops
the capture's tracks in one rule where the page acquires the microphone (`microphone.js`), so
nothing acquired after Mute survives it (no native check backs that release), and Unmute captures
again with no permission prompt. For updates,
`SystemUpdateEnvironment` is the real `UpdateEnvironment` (an ephemeral `URLSession`, `gh`,
`diskutil`, `codesign`, `ditto`, `xattr`, `claude`, `renamex_np` and the relaunch), Settings'
`UpdateSection` shows the version and the run, and the menu and `Notifier` offer an announced
release's Install.

**The mod** (`plugin/`) declares `/live`, joins the bridge under the session's title (the
desktop's own, read from Claude Code's session registry, or the folder's name while it has none)
and joins again when that title changes, polls it once a second, submits each voice request to
the session as a prompt, and posts the turn's answer back. It tells voice turns from typed and
background ones by the request marker on the prompt's last line and by the `prompt.submit`
origin. It posts every other main-loop turn to the app as synced lines (`POST /v1/sync`; a
background turn inside the follow-up window posts its answer as an update instead): the
owner's prompt at the turn's start, but only when its origin is `composer`, the only kind
observed to be a person typing ([ADR 0001](../adr/0001-platform-findings.md), item m; a Remote
Control prompt is not the owner's, its answer is Claude's), and Claude's final answer at its end.
It also posts, under the running turn whatever its kind, a keyboard answer to Claude's question
as the owner's line, and as Claude's lines the mod's own reports: a question closed with no
answer, and a permission prompt that was settled. A question Claude asks, or a permission prompt
it waits on, in any main-loop turn of a joined session goes to the app; the app says it for the
target, and for another session says it unless the turn was typed, when it only records it (a
subagent's approval has no turn and is said). A voice request that waits for the
running turn to end waits as before. It
draws a band above the prompt with the call's phase, the target, the unheard count and the
buttons Start/Stop (Mute/Unmute beside Stop, drawn only when the status carries `isMuted`, with a
`· muted` marker beside the phase) and Talk here, with the problem sentence on a row of its own.
A surface that has drawn no band for 3 s while the session is joined is asked for it again, and
`/live on` in a joined session asks every surface for it. Start makes the session the target and
starts the call; the line the app opens then asks the target for its summary when the voice would
lack part of the session (it has none, a turn did not arrive, the lines since the summary no
longer all fit the seed, or the mod does not sync), unless the pause setting is on or the session
is *paused*. The mod writes it (none for a session with no prompt yet; the last one again, with
no model call, until any main-loop turn completes, or `/clear`), with a
short note in the band while it goes. Talk here shows only while the call talks to another session,
and moves it here. When the socket does not answer, it opens `/Applications/LiveBridge.app`, where
both install routes put it, with `open -g`, and falls back to `open -g -b <bundle id>`.

## The wire

HTTP/1.1 over `~/Library/Application Support/LiveBridge/run/bridge.sock`, JSON
bodies, no other access control than the run directory's mode. The app finds that folder through
Foundation, which honours `CFFIXED_USER_HOME`; the mod builds the path from `CFFIXED_USER_HOME`
when it is set, else from `HOME`. `Wire.swift` and
`plugin/hooks/wire.ts` mirror each other, and `wire/fixtures/` holds one example of every message
that both test suites parse.

| Route | Body or reply |
|---|---|
| `POST /v1/join` | `sessionId`, `title`, `replaces` after `/clear`, `modVersion` from the mod's plugin.json, `syncs` (the mod posts sync lines) and `missed` (a turn did not arrive); an upsert that also refreshes liveness |
| `POST /v1/leave` | `sessionId`; a request it leaves open fails |
| `GET /v1/next?sessionId=` | the status and at most one piece of work: a request, a reply to Claude's question (`forRequest` names the request the turn's answer now belongs to) or a context ask |
| `POST /v1/answer` | `id`, `status` (`ok`, `failed`, `question`, `update`), `text`, `reason` |
| `POST /v1/activity` | `idle`, `working` or `approval`; `question` with `approval` is what Claude asks the owner in a main-loop turn (none: a permission prompt), `text` what Claude wrote in the step that pauses, `typedTurn` the turn's id when it is not a voice turn |
| `POST /v1/sync` | `sessionId`, `turnId`, `from` (`owner` or `claude`) and `text`: a line of a turn that is not a voice request, and the mod's keyboard-answer and settled-prompt lines under any main-loop turn, a voice turn included. Empty `text` at a turn's start only takes the turn's decision |
| `POST /v1/context` | the session's summary; the app redacts it and cuts the whole `[CONTEXT] label: …` line to 1,500 characters |
| `POST /v1/target`, `POST /v1/call` | make this session the target; Start, Stop, Mute or Unmute (`mute` and `unmute` are idempotent) |

Every reply carries the status: the phase, `isMuted`, the sessions with their labels (`Title · ab12` when
two titles are the same) and which one is the target, the minutes today, the problem sentence
and the count of unheard results. What only the app's menu shows (the minutes this call, the
target's context line and its conversation) is not on the wire.

A session the owner removed with the menu's × is gone as if it had left, and until the owner
joins it again (`/live on`, the only join that sends `"owner": true`) every call from it,
its own automatic joins included, answers `410` with `"code": "removed"`. The mod then turns itself off
for that session and logs "Removed from LiveBridge. /live on joins again." instead of joining
again, as it does after a `404` (the app restarted).

## Flows

### Handoff

The owner speaks; the line opens with the pre-roll and the voice hands the request off. Once the
request is queued for a session, in any phase of the line, the app plays a short sound
([BR-001](../bugs/BR-001.md)). The line stays open for its result up to
`CallMachine.resultWindowSeconds` (120 s) after the latest handoff, however silent it is (sound
without words still closes it after 90 s). A result from a session handed a request in that window
is given to the voice to say now (`thread/realtime/appendSpeech`, speakable text) once neither the
owner (local voice detection) nor the voice is speaking; when either was, the bridge waits until
both are silent and then a grace of 0.8 s. The window then ends and the 20 s silence rule closes the
line. A window that passes with no result closes the line once it is silent; when the result comes,
it opens the line again, as below. A line with no handoff waiting keeps the plain silence rule, so
an exchange that sends nothing to Claude costs no more than before. codex has no request that makes
the v3 voice respond, so whether it says the speakable text at once is the model's choice
([ADR 0001](../adr/0001-platform-findings.md) (b)).

```mermaid
sequenceDiagram
  actor Owner
  participant Page as Audio page
  participant Bridge
  participant Codex as codex + OpenAI
  participant Mod
  participant Claude
  Owner->>Page: speech
  Note over Page: holds the pre-roll and every new frame from here
  Page->>Bridge: speechStarted (listening → connecting)
  Bridge->>Page: makeOffer
  Bridge->>Codex: thread/start, MCP check, thread/realtime/start (initialItems)
  Codex-->>Bridge: SDP answer
  Bridge->>Page: applyAnswer, then flushPreroll (connecting → live)
  Page->>Codex: the queued speech, then live audio
  Codex-->>Bridge: handoff_request (brief + transcript)
  Bridge->>Bridge: enqueue for the target, arm the 120 s result window
  Bridge->>Owner: a short sound (queued)
  Codex-->>Owner: "On it."
  Mod->>Bridge: GET /v1/next
  Bridge-->>Mod: work: request
  Mod->>Claude: prompt.submit (brief, quoted transcript, marker)
  Claude-->>Mod: turn.complete
  Mod->>Bridge: POST /v1/answer ok
  Bridge->>Codex: appendSpeech "[RESULT] label: …" (once nobody is speaking)
  Codex-->>Owner: the result
  Bridge->>Bridge: 20 s of silence (live → listening)
```

### Silent hang-up

The realtime session is billed while open, so silence closes it. Voice detection keeps running
on the Mac, and the next speech opens a new session seeded with the target's conversation so
far. A new target closes an open line the same way, so the next speech opens it with the new
target's conversation. Every line the app opens, a reopened one included, also asks the target for
its context when the voice would lack part of the session (see the mod's Start above) and neither the pause setting is on nor the session *paused*; the line does not wait for
it, and a summary that comes while the line connects is added once it is connected, unless the
line was seeded with the same one.

```mermaid
sequenceDiagram
  actor Owner
  participant Page as Audio page
  participant Bridge
  participant Codex as codex + OpenAI
  Owner->>Page: stops talking
  Page->>Bridge: speechEnded
  Bridge->>Bridge: arm the 20 s silence timer
  Note over Bridge: speech, recognised words and the voice's own speech re-arm it (90 s while sound goes on)
  Bridge->>Bridge: silence elapsed (live → listening)
  Bridge->>Page: closePeer
  Bridge->>Codex: thread/realtime/stop
  Note over Page: the mic and voice detection stay on, nothing is sent
```

### A result while the line is closed

An answer, a question or an approval notice from the target (its result, failure or question, or a
question Claude asks or a permission prompt it waits on while it works) opens the closed line when
the target's conversation holds a turn of the owner's; a line seeded without one stays silent ([ADR
0001](../adr/0001-platform-findings.md) (b)). The bridge decides this from the registry's target and
the conversation, and passes it with the delivery. The new realtime session is seeded with the
target's conversation, starts without the pre-roll, as nobody spoke, and gets the line as context;
the voice often says it unprompted, and sometimes says nothing ([ADR
0001](../adr/0001-platform-findings.md) (n)). Until the owner or the voice speaks on such a line,
its silence is `CallMachine.firstWordSeconds` (5 s) instead of 20 s, also after another line
arrives; then the line closes, and the line chimes and waits as below. A voice that starts later is
cut off. The mod's request that brought the line does not wait for the connect, and a question or
approval the owner settles at the keyboard while its line still connects closes that line.

Any other line that arrives while the line is closed (one from a session that is not the target, a
later update) does not open it. It chimes, the notification names the session, and the line waits;
the voice gets it when the owner next speaks and says it in a reply. A connect that fails with lines
unheard chimes too. A result for a session the open line is not waiting on is added as context and
said in the voice's next reply.

```mermaid
sequenceDiagram
  actor Owner
  participant Page as Audio page
  participant Bridge
  participant Codex as codex + OpenAI
  participant Mod
  Mod->>Bridge: POST /v1/answer ok
  Bridge->>Bridge: "[RESULT] label: …" into pending (unheard 1)
  Bridge->>Owner: chime
  Owner->>Page: speech
  Page->>Bridge: speechStarted
  Bridge->>Codex: open a realtime session
  Bridge->>Page: flushPreroll
  Bridge->>Codex: appendText each pending line
  Codex-->>Owner: reply to the owner, then the result (unheard 0)
```

A result stays unheard until the voice finishes a reply that it began after the result and
that says it. A word counts when it has four letters or more and is not in a short list of
common words (English and Russian only). The reply must say two of the result's words, or the
session's label together with one of them. The label alone counts only for a result that has no
such word, which could not be heard otherwise. The handoff's own acknowledgement never counts,
nor does a reply the owner cut off before it got there. If the line closes first, the result
chimes and waits again: it may be said twice, but it is never lost.

This is the one description of the rule; the README links here.

A newer request to the same session withdraws its older unheard result, a timed-out one
included, so the voice never says a superseded answer. An answer that arrives after a newer
request is not said either: it is kept in the conversation as Claude's line and added to the open
line as context (`Bridge.keepSuperseded`). An `[APPROVAL]` notice is
withdrawn once the approval is settled.

### Question loop

An answer that ends with a question goes back to the owner, and the owner's reply is handed to
the session that asked, even if another session is the target.

```mermaid
sequenceDiagram
  actor Owner
  participant Codex as voice
  participant Bridge
  participant Mod
  participant Claude
  Claude-->>Mod: turn ends with "…?"
  Mod->>Bridge: POST /v1/answer question
  Bridge->>Codex: "[QUESTION] label: …"
  Codex-->>Owner: asks the question
  Owner->>Codex: answers
  Codex-->>Bridge: handoff_request
  Bridge->>Bridge: route to the session that asked
  Bridge-->>Mod: work: request
  Mod->>Claude: prompt.submit
```

### Later update

Work Claude starts from a voice request can finish in a later turn started by a background
task's notification (a returning background agent included). For 10 minutes after the voice
request, and until any other turn starts, each such turn's answer is posted as an update to that
request. A turn of any other origin, one the mod does not know or does not see included, closes
the window and is never sent to the voice.

```mermaid
sequenceDiagram
  actor Owner
  participant Codex as voice
  participant Bridge
  participant Mod
  participant Claude
  Claude-->>Mod: voice turn ends ("started the tests in the background")
  Mod->>Bridge: POST /v1/answer ok
  Note over Claude: later: a background task notifies, a new turn starts
  Claude-->>Mod: that turn ends
  Mod->>Bridge: POST /v1/answer update (same request id)
  Bridge->>Codex: "[UPDATE] label: …" (or chime and wait if closed)
  Codex-->>Owner: the update
  Note over Mod: a typed turn ends the follow-up window
```

### Approval notice

The bridge never answers a permission prompt. When a main-loop turn hits one, the voice says that
Claude is waiting and what Claude wrote before it, such as "I'm going to delete build/ and
re-run", and that only the owner can answer it, in Claude Code.

Both pauses of a turn, this prompt and Claude's question below, carry the text of the
main loop's model step that pauses: the engine's turn end carries only the turn's last text, and
a pause only itself, so that text would reach the voice no other way. The mod keeps it as the
step streams, since the engine may run a tool before its step ends, and takes it once: a second
pause in the same step goes without it, and so does a subagent's prompt. It goes as the
activity's `text`, and the app puts it after the notice or the question's options, with code and
tables removed, so the cut of a long line takes the text first.

```mermaid
sequenceDiagram
  actor Owner
  participant Codex as voice
  participant Bridge
  participant Mod
  participant Claude
  Claude->>Mod: classic.PermissionRequest (during a main-loop turn)
  Mod->>Bridge: POST /v1/activity approval (and the step's text)
  Bridge->>Codex: "[APPROVAL] label: Claude is waiting for your approval. Claude wrote just before asking: …"
  Codex-->>Owner: says so (a closed line opens for it, as for a result)
  Owner->>Claude: answers the prompt in Claude Code
  Claude->>Mod: classic.PostToolUse or PermissionDenied
  Mod->>Bridge: POST /v1/activity working
```

### Claude's question mid-turn

When Claude asks the owner a question during a main-loop turn (the AskUserQuestion dialog), the
dialog opens as usual and the question, with its options, goes to the voice as an `[ASKING]`
line, followed by the step's text (above). The voice explains it and talks it over from what it
knows, without handoffs; the owner's next handoff to that session is the reply. It goes out at once as `reply` work, beside the
request in flight, and the mod returns it as the dialog's free-text answer, which closes the
dialog. An answer at the keyboard that comes first withdraws the line, and a reply the session
has not polled by then goes as a request of its own.

```mermaid
sequenceDiagram
  actor Owner
  participant Codex as voice
  participant Bridge
  participant Mod
  participant Claude
  Claude->>Mod: tool.call AskUserQuestion (during a main-loop turn)
  Mod->>Bridge: POST /v1/activity approval + question (and the step's text)
  Bridge->>Codex: "[ASKING] label: question. Options: …"
  Codex-->>Owner: explains, talks it over
  Owner->>Codex: decides, or asks Claude back
  Codex-->>Bridge: handoff_request
  Bridge-->>Mod: work: reply
  Mod->>Claude: the dialog's answer (free text)
  Mod->>Bridge: POST /v1/activity working
```

### Update

Only the copy at `/Applications/LiveBridge.app` (the bundle, symlinks resolved, is that path, and
the path is not a symlink) makes an `Updater`; any other copy says so in Settings and never
checks. A check asks `https://api.github.com/repos/getLiveBridge/LiveBridge/releases/latest`
and reports `available` for a plain `vX.Y.Z` tag newer than the running version. With
**Check for updates automatically** on (`Settings.checkUpdatesAutomatically`, nil meaning on for a
release build and off for one with `LBSourceBuild`), the app asks at launch, every
`UpdatePolicy.tick` (15 minutes) and on wake whether a check is due: 24 hours since the last
one GitHub answered, or a clock that moved back; a check that did not reach GitHub (common right
after a wake) is tried again at the next tick. A newer release is announced once per version, by a
notification with an Install action and a menu item; `updates/state.json` keeps the last check's
time and the versions announced.

Install runs only from the owner's click, one run at a time (the actor's flag, and the lock file
`updates/lock` against a second instance). Programs start by absolute path except `gh` and
`claude`, which are found on the owner's shell `PATH` as `codex` is, and each has a timeout
(30 s, 120 s for `claude`):

1. `gh` is found and `gh auth status` passes, or nothing is downloaded.
2. The image is downloaded from the release URL built from the version into
   `updates/<X.Y.Z>/`, following redirects only to GitHub's asset hosts, and at most 100 MB.
3. `gh attestation verify`, pinned to `release.yml`, the tag and GitHub-hosted runners, passes,
   and its attested digest equals the image's SHA-256.
4. The image is attached read-only with `diskutil image attach`, at a mount folder of the run's
   own; its `LiveBridge.app` has the bundle id, the version and a minimum macOS this Mac meets,
   and passes `codesign --verify --deep --strict`; its CDHash is kept. It is copied with `ditto`
   to `/Applications/.LiveBridge-update-<uuid>.app`, an eject is attempted on every path, and
   the staged copy must have the same CDHash before a quarantine attribute on it is removed.
5. While any joined session has a request queued or in flight (`Bridge.hasOpenRequests`), the
   run waits (`waiting`).
6. `claude plugin marketplace update livebridge` and `claude plugin update livebridge@livebridge`
   run in the data folder; `claude plugin list --json` must then report the release's version,
   or the record carries the two commands for the owner.
7. The wait of step 5 again, then the call stops and the wait runs once more (for a request
   opened just before the stop); the staged copy is checked again (a directory, not a symlink,
   the same CDHash, `codesign` passes) and swapped with the installed app by
   `renamex_np(…, RENAME_SWAP)`. From here any launch of the path, the mod's included, starts the
   new version; the running process keeps its binary.
8. `updates/record.json` is written, a `/bin/sh` loop (`RelaunchScript`) waits for this process
   to exit and then `open`s the app, a second apart, until a process of the owner's runs the
   installed app's own executable (a `LiveBridge` built elsewhere does not count) or ten
   attempts have passed, and the app quits.

A failure before the swap, step 7's own re-check included, leaves the installed app as it was
and removes the staged copy; the image folder is removed on every path. When it comes after step
6 updated the mod, the mod stays at the new version, and the failure's sentence says so
(`UpdateProblem.modAlreadyUpdated`). Why the install waits for
the owner's click, and what that costs, is
[ADR 0002](../adr/0002-the-app-updates-itself-on-the-owners-click.md).

**At launch**, the installed copy removes every `/Applications/.LiveBridge-update-*.app` (the old
bundle, or a copy a crashed run left) and, unless `updates` is a symlink, every version folder and
the lock in it. It reads `updates/record.json`: Settings shows it until the next update, and
`LiveBridge updated to X.Y.Z` is posted once (the record is marked first). With automatic checks
on, a release announced before and newer than the running app is looked up again so the menu
keeps offering it. The bridge's socket is bound in the meantime, retrying every 200 ms for up to
10 s while the old instance still answers on it; an instance that stops removes the socket file
only if it is still the one it bound.

## Failure behaviour

- **No session joined:** Start is disabled in the menu. From the band or the socket, Start
  does nothing but report "No Claude Code session has joined: run /live on in a session, then
  start."; the sentence goes when a session joins. The last session leaving (`/live off`, the
  session closing, the menu's ×, or no poll for 5 s) stops a call that is on, a Start still
  launching codex included, as Stop does, and reports the same sentence.
- **Codex missing or signed out:** Start reports why in one sentence, in the menu and the
  band, and the call stays off. So does a `codex features list` that fails, cannot be read, or
  gives no answer within 10 s.
- **A realtime error:** the first connect reports codex's own words in one sentence, with a hint
  when they name sign-in or the plan, and the call goes back to `listening`.
- **A refusal a new line would get too:** the plan's usage limit, a plan without voice or a 429
  with no known body, recognised in codex's wording, as this path carries no code; or an `error`
  about usage on the line's data channel, which codex does not report, recognised by its code.
  The call ends, so speech does not open lines that fail, and until Start or Stop it keeps what
  waits to be said, lines that arrive meanwhile too, with a question's route. Only a spent budget
  is called a limit: the others are said as ChatGPT not allowing the voice.
- **Codex installed with npm, or found only through a shell's start-up files:** the app reads
  `PATH` from the user's own shell (at most 3 s) and starts codex with it; a codex whose runtime
  is still missing gets its own sentence.
- **The app not running:** the mod opens it; while the socket does not answer for 10 s the band
  says "bridge offline". After the app restarts, the mod joins again on its next poll; the call
  starts off.
- **Codex exits or stops answering under the app:** the next speech reports it once, and the
  speech after that starts a fresh codex. A request codex leaves unanswered past its timeout
  ends that codex as an exit does.
- **The microphone is denied, missing, busy or lost:** the call goes to `off` with the reason.
  Denied says where to allow it, and the menu offers to open that setting. Busy means it
  could not be opened, perhaps because another app holds it; a request still pending after
  10 s fails with its own sentence instead of listening to nothing. When the
  default input changes mid-call, the page takes the new one and keeps the peer.
- **Unmute cannot take the microphone** (denied, busy, missing) **or the audio page cannot be
  reached:** the call goes to `off` with the reason, as at Start.
- **The audio page cannot confirm a Mute:** the call ends, which releases the microphone, rather
  than showing Muted over an open one.
- **Local Network access blocked:** with no ICE candidate within 2 s, the call goes to `off` with a
  sentence naming the setting.
