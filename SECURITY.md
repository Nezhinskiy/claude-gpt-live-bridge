# Security policy

## Supported versions

Only the latest release gets fixes. Before 1.0, that is the latest `0.x` tag.

## Reporting a vulnerability

Please report a vulnerability privately, through GitHub's
[private vulnerability reporting](https://github.com/getLiveBridge/LiveBridge/security/advisories/new)
for this repository; do not open a public issue. Say what an attacker can do, what they need
first, and how to reproduce it. You should hear back within a week. Once a fix is released, the
advisory is published with credit to you unless you ask otherwise.

## Threat model

LiveBridge is a menu bar app plus a Claude Code mod on one Mac, for one user. It turns speech
into prompts for a Claude Code session, so its security comes down to who can put words into
that session and what leaves the Mac. This section says which parts are controls and which are
only conveniences. An instruction to a language model is never counted as a control.

### The one control against unwanted actions

**Claude Code's own permission prompt.** A voice request reaches Claude as a prompt in the
target session, and Claude runs it **under that session's own permission mode, auto mode
included**. Whatever that mode would ask before a tool runs, it still asks, and only you can
answer, at your keyboard in Claude Code. LiveBridge has no code that answers a permission
prompt: the mod declares no `tool.check` hook, and its `classic.PermissionRequest` hook only
tells the voice that a prompt is waiting, with what Claude's main loop wrote in the step that
asks for it. The voice may not say so ([ADR 0001 (n)](docs/adr/0001-platform-findings.md)), so that
notice is no control and no promise.

A question Claude asks you while it works (the AskUserQuestion dialog) is not a permission prompt:
Claude asks for your input, not for leave to run a tool. In any main-loop turn of a joined session,
one you typed included, the mod reports it to the app. For the target the app gives it to the voice
to say, which the voice may do, and a spoken reply, given before you answer at the keyboard, answers
the dialog as free text; the app sends the next handoff to the session that asked last, which after
a target switch is not the target. So a steered voice can answer the dialog of a turn you typed, not
only of a voice turn. That gives speech no reach it did not have, since it already reaches Claude as
a request, and whatever Claude then does still passes the permission prompt. The mod does not tell a
reply you spoke from one an injected line talked the voice into: nothing but your answer at the
keyboard, given first, stands between them.

In a mode that acts without asking, nothing else stands between what the microphone hears and
what Claude does. For such a session, keep voice off, or keep the microphone away from other
voices.

### What the microphone can do

- **Anything audible to the microphone can become a request**: a TV, a call on speaker,
  another person in the room. Speech-recognition errors pass through as heard.
- **The voice's confirmation is UX, not a control.** Before it hands off anything destructive
  or outward (delete, push, publish, send, deploy, pay), the voice is told to repeat the request
  and wait for a spoken "yes". The prompt Claude receives asks it to confirm such an action in
  text first, unless the request says the owner already confirmed by voice. Both are
  instructions to language models. The voice writes the "confirmed by voice" sentence itself, so
  anything that can steer the voice can write it too.
- **The transcript quoting is a convenience.** The prompt quotes the recognised speech as data
  and tells Claude to use it only to resolve names and ambiguity. That keeps side talk from being
  taken as a request. It does not stop an adversary: the instruction Claude acts on is the
  voice's brief, which is the voice model's rewrite of that same speech. The request id on the
  prompt's last line ties each answer to its request; it is there for correctness, not security.

### Who can drive the bridge

- **Other users of the Mac are kept out.** The mod talks to the app over HTTP on a Unix socket,
  `~/Library/Application Support/LiveBridge/run/bridge.sock`. The `run` folder and
  the data folder above it are created at mode `0700`, or set back to it at every start (a
  symlinked folder is followed, and the folder it names is set to `0700`). That folder's mode is
  the bridge's one access control: there is no listening TCP port, no shared secret and no peer
  check.
- **Every process running as your user is trusted.** Any of them can open the socket and:
  - join as a session, make itself the target, and receive every handoff the voice makes;
  - answer those handoffs with any text, which the voice then reads out;
  - start a call, which turns on the microphone under LiveBridge's permission (macOS shows its
    microphone indicator in the menu bar), and unmute a muted call, which takes it again. Mute
    releases the microphone, so while muted LiveBridge captures nothing and the indicator shows
    it; that protects against being heard by accident, and is not a control against these
    processes;
  - open the voice line, by starting a call or, as the target, by posting an approval notice, which
    spends your plan's Codex usage budget. Withdrawing the notice closes that line and a new notice
    opens another, each billed like any open line;
  - read the status, which names every joined session and its id;
  - post a `[CONTEXT]` line for any joined session. It is saved and seeds every later call with
    that session, long after the process has exited (see "What the voice keeps" below);
  - post sync lines for any joined session, labelled as typed by you (`[TYPED]`) or as Claude's
    (`[CLAUDE]`). They are saved and seed later calls the same way, and go to the open line when
    that session is the target. The app takes the label on the process's word;
  - join a session as one that missed a turn, or that does not sync, which makes the next line
    that session opens ask it for a fresh summary, and for a session whose mod writes summaries
    also the next Start or target change to it during a call, before a line to it opens (while
    the pause setting is on or the session is marked paused, only one with no summary yet,
    below; after it answers a numbered ask with no summary, only once the app records a sync line
    of that session, or at the next Start), and so makes it write one;
  - join with `writesSummaries`, make itself the target and never answer the summary ask, which
    holds what you say on the Mac, unsent, for up to 10 seconds from the ask while the line waits
    for that summary. The line then opens without it, and no later line of that call waits for
    that session id; joining again under a new id and making itself the target holds the next line
    the same way. That bound is for a process that never answers, not one per call: one that
    answers each ask, with any text, just before the limit, or that ends each wait by joining again
    as one that missed a turn, is asked again by the next line, so it can hold every line of the
    call, each for up to 10 seconds from that line's ask;
  - take Settings' check of a custom **Summary model**, with the check's id, and post its
    result. The check goes to the target if its mod writes summaries, else to the latest joined
    session whose mod does, and the app takes a result only under that session's id and the
    check's id. A process can be that session, by joining with `writesSummaries` and making
    itself the target, or it can poll `GET /v1/next` with that session's id, which the status
    names, without joining: a poll that comes before the mod's takes the check, and the mod never
    sees it. Either way it can answer that any model works, and Settings saves that model. It
    cannot change the id saved, which is the one you typed, and it must win that poll to answer a
    check that went to a session it is not. Haiku 5.5 then writes a summary that model fails to
    write, except when its request runs out of the time the mod allows a summary, as one to a
    model whose requests hang does: then no model writes it, and the line opens without that
    summary. No permission or data is reached. The check carries only the model's id, and the mod
    asks that model only "Reply with OK.";
  - join with `replaces` set to a joined session's id, as the mod does after `/clear`, and so
    take over that session's place, its requests and its saved conversation;
  - post false usage limits for a joined session. The menu then shows them, with a `resetsAt` as
    far ahead as it likes, which stands until that time (or until the app quits) because the later
    reset wins; a window with no `resetsAt` goes 15 minutes after the reading. The reading is one
    value shared by every session, and it outlives the session that sent it. The percent is not
    checked on the way in and is clamped to 0 to 100 only for display. Window names are only
    accepted as `[a-z0-9_]{1,32}` with a character other than `_`, and a row shows at most three
    windows, so this can mislead the owner but add no rows.

  It can also read the data folder itself. That folder now holds what you typed in every joined
  session and Claude's answers to it, as well as the voice's calls, and it fills without a call
  (see "What the voice keeps" below). Such a process can
  already do worse without LiveBridge: for example, it can add hooks to
  `~/.claude/settings.json` that run in every Claude Code session.
- **The app the mod opens.** When the socket does not answer, the mod opens
  `/Applications/LiveBridge.app`, where both install routes put it. Any administrator account of
  the Mac can replace that app, as it can do worse with `sudo`. Only if that path does not open
  does the mod ask Launch Services for the bundle id, which trusts whichever app claims it. The
  disk image's origin is checked with `gh attestation verify`, as the README's
  [Install](README.md#from-the-disk-image) says. LiveBridge itself replaces the app at that path
  with a release, and only when you click **Install**
  ([What an update installs](#what-an-update-installs)).
- **Other plugins in the same Claude Code engine are trusted.** They share the engine with the
  mod and can see or submit the same prompts. Install only plugins you trust.

### What the voice model can do

The voice runs on a codex thread that is ephemeral and read-only (`sandbox_mode="read-only"`,
`approval_policy="never"`, web search off, notifications off). The control is that the thread
has **no tools**:

- **Every codex feature is off except an allow-list.** At launch the app runs
  `codex features list` and turns off every feature it reports, except those in
  `CodexLaunch.allowed`: `secret_auth_storage` (where codex keeps your login) and
  `respect_system_proxy` / `system_proxy_fallback` (how codex reaches OpenAI behind a proxy).
  None of them runs anything. A feature listed at stage `removed` is skipped, because
  `--disable` no longer changes it. A feature a later codex adds under a new name is off too, as
  long as `codex features list` reports it.
- **Every MCP server is off.** The app turns off every server codex's configuration names when
  it starts the thread, then requires codex to report each one disabled before every session.
  That check belongs to the voice's thread. The short-lived codex that reads your usage starts no
  thread and is not covered by it: in the one run seen, with an empty home, it started no MCP
  server, but LiveBridge does not enforce that.

The rest only narrows what is left. The app interrupts every codex turn it sees start, declines
every request codex sends (approvals, tool calls, input requests and the rest), and closes the
session if codex later reports a server starting or ready. The interrupt races codex's own
start of the turn, so it is not counted as a control.

The checks above fail closed. The call does not start if codex cannot list its features, lists
them in a shape this version does not read, or gives no answer within 10 seconds. It also does
not start if codex reports an MCP server that is not disabled, or leaves a configured server out
of its report.

What is not a control here: the read-only sandbox does not limit reading, so a codex turn that
did run a command could read any file your user can read. The thread's instruction to "never
act" is a model instruction.

### What session text can do

Results, questions, updates, approval notices, open tasks, context summaries and synced lines go
to the voice as one tagged line each, `[TAG] label: text`. Every bracket in the text becomes a
parenthesis and every line break a space. That keeps the format unambiguous, but it is not a
control: each line goes in with the rank of the owner's own words (`user`), so a session's text
needs no fake tag to give the voice orders. The voice is told to treat such text as data to
relay, which is again an instruction.

A synced line is either `[TYPED]`, what you typed in the session, or `[CLAUDE]`, Claude's final
answer to a turn. "Data to relay" does not fit a `[TYPED]` line, which is meant to read as what
you said, so the voice prompt tells the voice to use it as what it knows and never to hand it
off. That paragraph of the voice prompt enforces nothing: a model instruction is not a control.
What the app does enforce is smaller. A line is cut to one line of at most 2,000 characters
(`AnswerShaper.line`); its fenced code blocks and table rows are removed from the prose, and what
you typed that was only code or a table becomes a sentence saying so (`AnswerShaper.synced`); and
the redactor runs on it. The label `[TYPED]` is put on by the app when a mod says the line is
yours. The mod says so for a prompt whose origin is `composer`, text typed into a running turn
included, and for an answer to Claude's question that did not come by voice. That a prompt typed
in the Claude desktop app arrives as `composer` is inferred from its transcripts and was not
observed: if it arrives as `sdk`, nothing typed there is recorded, no gap is marked, and the pause
reaches less ([known limitations](README.md#known-limitations),
[ADR 0001 (m)](docs/adr/0001-platform-findings.md)). A prompt of another origin, from another
agent, a plugin, a schedule or a host, is not recorded as yours, though Claude's answer to it is.
That `bridge` is Remote Control is the type's wording and was not observed; if it arrives as
`composer` it is recorded as yours. "At the keyboard" in these lines is the mod's wording, not
something it knows: the hooks also run when a host answers, and another hook may allow a tool
([ADR 0001 (i)](docs/adr/0001-platform-findings.md)), so you may have seen nothing, and a host's
answer counts as yours, which under the pause refuses the turn. The mod's own notes go as
Claude's, so they never refuse a turn under the pause; an answer to Claude's question does. They
are: that you allowed a tool, only for the run that was asked about (same tool, input and agent);
that a prompt was settled, which a subagent's prompt also gets at its next step or end; that a
question was closed with no answer; and that a turn ended without an answer ("The turn was
interrupted.", "The turn ended with an error.", "The model refused the request.", "Claude ended
the turn without an answer."). A plain No at a permission dialog or a cancelled question gives two
such lines: settled or closed, then the turn ended without an answer.

The redactor that removes credential shapes from these lines (private keys, JWTs, common API
tokens, URL passwords, `password=`-style fields) is a convenience against an accidental leak. It
is a list of patterns, and it does not stop an adversary: injected text can spell out or encode a
secret. It also does not make a synced line safe to send: anything you type that is not one of
those shapes goes to OpenAI as typed, personal text included.

### Residual risk, by design

- **Anything that steers the voice can start work.** Text a joined session read (a README, an
  issue, a web page, a tool's output) can reach the voice in a result, a question, an update, an
  approval notice, a summary, a synced line or Claude's answer to a turn you typed, and talk it into a
  handoff, including the "confirmed by voice" sentence above. A page Claude reads while you type
  to it can steer the voice through Claude's answer, as it could in a voice turn.
- **A handoff can hop between sessions.** The voice hands work to the target session, or to the
  session that asked the last question. So text that session A read can become a prompt in
  session B, which may run in a more permissive mode.
- **What the voice keeps.** Each session's conversation with the voice is saved in the data folder
  as plain JSON: your typed text and Claude's final answers to turns that were not voice requests,
  an answer a newer voice request superseded (kept unsaid and added to the open line as context),
  the voice's and your spoken lines, the briefs of the requests the voice handed off, the lines the
  session sent the voice (results, questions, updates, approval notices), and the session's
  `[CONTEXT]` line with the summaries loaded before it. It holds at most 64 lines for each of the 20 sessions used last
  (`Conversation.keptLines`, `Continuity.keptConversations`), longer for none of them. A session
  that has left keeps its lines until 20 others have been used since; to erase them sooner, [join it
  again and press **New conversation**](README.md#privacy). The folder is `0700`; whether Time
  Machine or another backup copies it has not been tested. The sync fills it **with no call
  running**: while a session is joined, what you type in it and Claude's answers are recorded, and
  the next line opened with that session gives them to OpenAI. Claude already repeats much of the
  same text in its answers to voice requests; what is new is that your own typing, and Claude's
  answers to turns you typed, go too. The mod also keeps a snapshot of each
  joined session in Claude Code's plugin store, `~/.claude/plugins/store/livebridge_*.json`, outside
  the data folder. In plain JSON it holds text typed into a running turn until the next turn, under
  the pause too, and the whole tool input of every open permission prompt until the prompt settles:
  a Write's content, or a command with a secret in it, which the session's transcript holds as well
  (`TurnTracker.snapshot`, `register.tsx`). `/live off`, the session's end, `/clear` and removing the
  session in the app delete its key. Whether `claude plugin uninstall` removes the file was not run:
  Claude Code's documentation of what it deletes does not name it
  ([Uninstall](README.md#uninstall)).
- **The pause keeps new text out and removes nothing.** With **Pause sync while the call is
  stopped** on and the call stopped, what you type is not recorded, a prompt typed into a running
  turn included, and the session is marked *paused* (`Continuity.admits`, `Bridge.sync`). Typing
  also refuses the rest of a turn that began synced: Claude's later lines of it stay out too.
  While
  the setting is on, no line loads a summary by itself (`Bridge.pauseHoldsBackSummary`), and none
  does for a session marked paused after the setting is off again, with one exception. With **Load
  a session's context on its first call** on, which is the default unless the pause was on when you
  updated to it, a line that opens for a session with no summary asks for one, under the pause or
  the mark, and for a session whose mod writes summaries so do Start and a target change to it
  during the call, before a line to it opens. The pause does not hold that summary back: it is
  written from the session's transcript, paused text included, goes to OpenAI, and clears the
  *paused* mark, so a Start and a Stop with nothing said can clear it. A current mod with a current
  app leaves tool results, thinking and system reminders out of what the summary model reads, but
  text that quotes them stays, as does anything pasted and every text block of a user message,
  which holds the output of a `!` command typed in the session if Claude Code stores it as user
  text, so this is a reduction, not a property; an
  older app or mod sends the whole request. Otherwise only **Load
  context** loads one, and it carries the same text. An
  older mod's `/live context` does too; the last point below says what that can do.
  What the pause does not do:
  - It removes nothing already recorded, in the data folder or in a line that is open.
  - It cannot stop Claude's later answers from repeating paused text: a Claude line of a turn
    admitted before Stop goes in until you type into it, and a later turn's answer can quote the
    paused text. That answer then goes to the voice as any does.
  - Typing under the pause into a turn that runs a voice request withholds that request, since its
    answer may repeat what you typed: the answer closes as failed with a plain reason, nothing of it
    is recorded or said, and that turn's later questions and approval notices stay out too
    (`SessionRegistry.withholdAnswer`, `Bridge.sync`, `Bridge.activity`). A refused `typed` line
    withholds exactly the request its turn names; one a spoken reply tied the turn to is named, so
    it is withheld, and its own later answer fails. A request that only waits behind that turn is
    not its own and keeps its answer, which may quote the paused text, as Claude has it in the
    transcript. Unlike a later request, which you make after the pause, it was made before you
    typed, so its answer arrives unasked and goes into the seed with the call off. A voice turn
    holds nothing of yours: its start refuses nothing and marks nothing under the pause, and only a
    `typed` line into it is refused. An older mod posts no turn and no sync of its own turns: its
    lines go to the voice as ever and no pause refuses them.
  - A prompt typed while Claude streams its final text starts a turn of its own, which keeps the
    decision of the turn it was typed into; a slash command queued behind a turn takes a
    decision of its own, so the pause reaches less far there.
  - Eviction past the 20 sessions loses the paused mark and the summary. With the pause setting
    still on, no summary loads unless **Load a session's context on its first call** is on; with
    the pause setting off, you have ended the pause.
  - It does not hold if the app was not running or the mod could not post: a turn the app did not
    receive marks the session *missed*, or *paused* while the setting is on
    (`Continuity.markMissed`), and so do a question or permission notice the app did not take and
    turns that ran while the mod was off. A missed session loads a summary by itself once the pause setting is
    off; a paused one does not, unless it has no summary and **Load a session's context on its first
    call** is on. A turn whose `start` never arrived has no decision: while the
    session is *paused*, a line of Claude's opening it stays out (`Continuity.admits`).
  - The session title is not touched by the pause. The poll follows it whatever the setting says,
    and `AnswerShaper.line` puts it in every line, unredacted, so paused text the title was written
    from can go out on every line after Start, up to 80 characters.
  - A prompt whose origin is not `composer` refuses nothing: it goes in with no line posted, so a
    turn admitted before Stop stays admitted, and its answer, which may repeat that prompt, is
    recorded. So may text typed as feedback at a permission dialog, which as far as the hooks show
    reaches none of them; that was not run.
  - A summary nobody asked for can reach past the pause and past a forget. From 0.4.2 the mod sends
    a summary only when the app asks for one, but the app still takes one it did not ask for that
    carries no ask's number, as it cannot date it (`Bridge.context`): mods update separately from the app, so a session on an older
    mod can send one with `/live context`. It takes no more than the pause on, the call off and
    typing during that command to clear the *paused* mark, and the paused text may be in that
    summary; one written across **New conversation** brings back what was forgotten
    ([BR-002](docs/bugs/BR-002.md)). This is accepted, as a 60 second window on an explicit command.
    An older mod since 0.4.2 can land there too, for about a second: the reply to a second ask that
    came after a poll took the first and before that summary landed finds no ask open. A current
    mod with a current app echoes the ask's number, and the app refuses a numbered summary that
    finds no ask open, or another ask open.
- **Ending what the voice carries.** The saved context and conversation go when you press **New
  conversation** with the session as the target, or remove it with ×, or when 20 sessions used since
  push them out (which also loses a paused mark); a load of a new summary replaces the old one for
  the voice and keeps the lines, the old summary among them, until it rolls off. Neither **New conversation** nor × withdraws a result the voice has not said yet:
  a hang-up keeps it and the next connect adds it again, and only **Stop** clears those. That is
  true of results. A waiting question of another session leaves the queue and its route ends when
  you change the target; a session that leaves or is removed with × takes its waiting question and
  approval notice off the queue and its route ends; a failed microphone ends a route as Stop does.
  Those lines stay recorded. `/clear` gives the session a new id and carries its lines and context
  to it, so `/clear` ends nothing until **New conversation** follows. Removing a session holds until
  you join it again, since the mod's own joins are refused (`410`). **New conversation** and × keep
  the *paused* mark, so with **Load a session's context on its first call** off the next line asks
  for no summary of that transcript. With it on, or with the pause setting off and no pause mark, a session with no summary
  does get one from the next line, or, if its mod writes summaries, from the next Start or target
  change to it during a call, written from the session's transcript (the reduction above),
  any paused text included.
- **A result from another session** is still spoken in whatever line is open, and the voice's
  reply to it stays in that line's conversation, so one session's text can still reach the
  conversation about another.

Join only sessions whose input you trust. After a session has read text you do not trust,
`/clear` it, press **Stop**, then press **New conversation** with it as the target, and do not
press **Load context** for it until you want the transcript's summary. To keep what you type out of the
voice, press Stop first and turn on **Pause sync while the call is stopped**, and turn off **Load a
session's context on its first call** if the session may have no summary yet; what you typed
before that stays recorded. Keep voice off for a session whose permission mode acts without
asking.

### What an update installs

The app replaces itself in `/Applications` with a release that a reply from GitHub names, and
only when you click **Install**: in Settings, in the menu bar menu or in the notification that
announces the release. A check, automatic or from Settings, only reads which release is the
latest (and, for a release the automatic check announces, runs `gh auth status`); nothing
downloads or installs without that click. Only the copy at `/Applications/LiveBridge.app` checks
or installs: the running bundle, symlinks resolved, must be that path, and the path must not be
a symlink. The click is what keeps a release from reaching a Mac by itself; the checks below
decide what may be installed
([ADR 0002](docs/adr/0002-the-app-updates-itself-on-the-owners-click.md) records why). Nothing
installs unless each passes:

- **The release.** The reply's tag must be `vX.Y.Z` with plain integers (no suffix, sign or
  leading zero) and newer than the running version, so an update never installs an older or the
  same version. The image's address is built from that version under
  `https://github.com/getLiveBridge/LiveBridge/releases/download/`, never taken from the reply.
  The requests send no credentials or cookies, follow a redirect only over https to GitHub's own
  hosts (`api.github.com` for the check; `github.com`, `objects.githubusercontent.com` and
  `release-assets.githubusercontent.com` for the image), and an image over 100 MB is refused.
- **Its origin.** `gh` must be installed and signed in, or nothing is downloaded. Then

  ```sh
  gh attestation verify <image> --repo getLiveBridge/LiveBridge \
    --signer-workflow getLiveBridge/LiveBridge/.github/workflows/release.yml \
    --source-ref refs/tags/vX.Y.Z --deny-self-hosted-runners --format json
  ```

  must pass, and the digest it attests must equal the downloaded image's SHA-256. This proves
  that the image was built by `release.yml` from tag `vX.Y.Z` of this repository, on a
  GitHub-hosted runner, and was not changed since, in transit or on GitHub. It does not prove
  that anyone reviewed the code at that tag: anyone who can push a tag to this repository can
  produce a release that passes. It also rests on the `gh` found on your shell's `PATH`, which a
  process running as you could replace, as it could do worse (above).
- **The app inside.** The image is attached read-only and must hold `LiveBridge.app` with the
  bundle identifier `com.getlivebridge.livebridge`, the release's version, when it names one an
  `LSMinimumSystemVersion` this Mac meets, and a signature that passes
  `codesign --verify --deep --strict`. Releases after 0.4.2 are signed with LiveBridge's
  Developer ID, but this check names no signer and would pass an ad hoc signature as readily,
  so it proves only that the bundle is whole as signed, not who signed it: it is not an origin
  check. Its CDHash is
  recorded, and the copy staged in `/Applications` must still have it, be a directory and not a
  symlink, and pass `codesign` again at the moment of the swap.
- **The swap.** The staged copy is exchanged with the installed app in one
  `renamex_np(…, RENAME_SWAP)` call in the same folder, so there is never a moment without an app
  at the path. A failure before the swap leaves the installed app as it was and removes the
  staged copy and the image. When it comes after the mod was updated, the mod stays at the new
  version, and the failure says so.

**An updated app skips Gatekeeper's first-launch block.** The download sets no quarantine
attribute (the app does not set `LSFileQuarantineEnabled`), and one found on the staged copy is
removed from that copy alone, after its CDHash matched. It follows that macOS does not stop the
new version's first launch to ask, as it does for a first install from the disk image; this has
not yet been observed on a real update. Either way, the checks above are the gate, not
Gatekeeper's notarization check.

**The mod is fetched with git and is not attested.** `claude plugin marketplace update
livebridge` and `claude plugin update livebridge@livebridge` fetch it over HTTPS from this
repository, at the tag the marketplace names (each release commit pins it to its own tag). A
tag is only as fixed as the repository's push rights keep it, and nothing checks the mod's
origin beyond that. The app then requires the installed mod's version to equal the release's,
and otherwise shows you the two commands to run.

**LiveBridge never runs `claude` with `-y` or `--accept-command`.** A command that asks for a
person's confirmation is a Claude Code prompt, which LiveBridge never answers. Such a command
fails or times out after 120 seconds, and Settings shows the commands for you to run. They run
in the app's data folder, so no project's settings apply to them.

A build from source (`scripts/build-app.sh --release`, marked `LBSourceBuild` in its
`Info.plist`) checks by itself only once you turn that on, and **Install** asks before it
replaces the build with the release image. No build has a switch that skips the attestation. A
debug build reads `LIVEBRIDGE_RELEASES_URL`, when set, in place of the GitHub API address, for
testing; `scripts/check.sh` fails if a release binary contains that name.

**The microphone prompt after an update.** Releases up to 0.4.2 were signed ad hoc, so macOS
asks for the microphone again at the first **Start** after an update from one of them, or after
an update that replaces a build from source. Later releases are signed with LiveBridge's
Developer ID, whose designated requirement names the team rather than one build, so the
permission should follow from one release to the next; that has not yet been observed. Expect the prompt
then, at the very first Start, and after a rebuild from source signed ad hoc. LiveBridge does
not otherwise reset the permission, so a prompt at another time is worth a second look.

### What leaves the Mac

The list of what goes to OpenAI, and when, is in the README's
[Privacy](README.md#privacy) section. LiveBridge sends OpenAI no audio or text while the line
is closed: voice detection runs on the Mac. Codex itself keeps running between lines, and opening
Settings starts another codex to list the voices, and opening the menu starts a short-lived one
that reads your Codex usage from OpenAI, also while the call is off; what codex sends on its own
is codex's. Codex
talks to OpenAI with your ChatGPT login; LiveBridge never reads codex's credentials. The Claude
session sends its work to Anthropic as it always does, and so does the summary the voice gets as
context, also while the line is closed: a mod of this release, asked at Start, at a change of
target, when a line opens or on **Load context**, sends the transcript, cut to 120,000
characters, to the summary model through Claude Code, on your Claude usage; an older mod, asked
when a line opens or on **Load context**, forks the session's own model over the whole request.
Settings' check of a custom **Summary model** sends one short request the same way. LiveBridge has no telemetry. The menu's
**Feedback & Support** links, **Report a Bug…**, **LiveBridge Website** and **Star LiveBridge on
GitHub**, only open the repository's bug form, getlivebridge.com and the repository's page in your
browser; the app sends nothing. Its other items stay on the Mac: **Debug Mode** writes the voice's
network numbers to a local file ([Settings](README.md#settings)), and **Uninstall LiveBridge…**
moves the app and its files to the Trash ([Uninstall](README.md#uninstall)).

For updates, the app itself makes two kinds of request, and no others: the release check and the
image download below. It also runs `gh` and `claude` for the requests listed below; what `gh`
and `claude` send on their own besides is theirs, as with codex.

- **The release check**, the app's own:
  `GET https://api.github.com/repos/getLiveBridge/LiveBridge/releases/latest`, without
  credentials or cookies. It shows GitHub your Mac's IP address and LiveBridge's user agent.
  With **Check for updates automatically** on, it runs when a check is due (a day after the last
  one, or the clock moved back before it; asked at launch, every 15 minutes and on wake) and
  once at launch while a release it announced is newer than the running app; **Check for
  update** in Settings, and an Install from a notification posted before a relaunch, send it
  too.
- **`gh auth status`**, when the automatic check finds a release not announced before and before
  every install, under your own GitHub login.
- After you click **Install**: the image download from `github.com`, the app's own, without
  credentials or cookies (GitHub counts downloads); `gh attestation verify`, which fetches the
  image's attestation from GitHub under your login and Sigstore's trust root from Sigstore; and
  `claude plugin marketplace update` and `claude plugin update`, which fetch this repository
  with git.

Notifications never carry a result, but they name its session, and a session's title is often
written from its conversation. With macOS's **Show previews** set to show on the lock screen,
that title can be read there.

### Out of scope

A compromised user account, macOS itself, codex, Claude Code and its engine, GitHub, Sigstore
and the `gh` CLI that an update's checks rely on, and the models' behaviour beyond what the
instructions above ask of them.
