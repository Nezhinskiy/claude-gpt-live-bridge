# Security policy

## Supported versions

Only the latest release gets fixes. Before 1.0, that is the latest `0.x` tag.

## Reporting a vulnerability

Please report a vulnerability privately, through GitHub's
[private vulnerability reporting](https://github.com/getLiveBridge/livebridge/security/advisories/new)
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
tells the voice that a prompt is waiting.

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
    microphone indicator in the menu bar);
  - read the status, which names every joined session and its id;
  - post a `[CONTEXT]` line for any joined session. It is saved and seeds every later call with
    that session, long after the process has exited (see "A loaded context persists" below);
  - join with `replaces` set to a joined session's id, as the mod does after `/clear`, and so
    take over that session's place, its requests and its saved conversation.

  It can also read the data folder itself, every kept conversation included. Such a process can
  already do worse without LiveBridge: for example, it can add hooks to
  `~/.claude/settings.json` that run in every Claude Code session.
- **The app the mod opens.** When the socket does not answer, the mod opens
  `/Applications/LiveBridge.app`, where both install routes put it. Any administrator account of
  the Mac can replace that app, as it can do worse with `sudo`. Only if that path does not open
  does the mod ask Launch Services for the bundle id, which trusts whichever app claims it. The
  disk image's origin is checked with `gh attestation verify`, as the README's
  [Install](README.md#from-the-disk-image) says.
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

Results, questions, updates, open tasks and context summaries go to the voice as one tagged line
each, `[TAG] label: text`. Every bracket in the text becomes a parenthesis and every line break a
space. That keeps the format unambiguous, but it is not a control: each line goes in with the
rank of the owner's own words (`user`), so a session's text needs no fake tag to give the voice
orders. The voice is told to treat such text as data to relay, which is again an instruction.

The redactor that removes credential shapes from these lines (private keys, JWTs, common API
tokens, URL passwords, `password=`-style fields) is a convenience against an accidental leak. It
is a list of patterns, and it does not stop an adversary: injected text can spell out or encode a
secret.

### Residual risk, by design

- **Anything that steers the voice can start work.** Text a joined session read (a README, an
  issue, a web page, a tool's output) can reach the voice in a result, an update or a summary,
  and talk it into a handoff, including the "confirmed by voice" sentence above.
- **A handoff can hop between sessions.** The voice hands work to the target session, or to the
  session that asked the last question. So text that session A read can become a prompt in
  session B, which may run in a more permissive mode.
- **A loaded context persists.** Each session's `[CONTEXT]` line is saved in the data folder
  with that session's conversation and given to every later realtime session while that session
  is the target, across Stop and Start and app restarts, until you press **New conversation**
  with it as the target, load a new summary from it, or remove it from LiveBridge. The band's
  Start sends one, and with **Load a session's context automatically when it becomes the
  target** on in LiveBridge's Settings, a session sends a new one whenever it becomes the
  target. One injected summary can therefore steer every later call with that session. Its recent conversation is carried over
  the same way, including the lines the session sent the voice. A result from another session is
  still spoken in whatever line is open, and the voice's reply to it stays in that line's
  conversation, so one session's text can still reach the conversation about another.

Join only sessions whose input you trust, press **New conversation** with a session as the
target after it has read text you do not trust, and keep voice off for a session whose permission mode acts without
asking.

### What leaves the Mac

The list of what goes to OpenAI, and when, is in the README's
[Privacy](README.md#privacy) section. LiveBridge sends no audio or text while the line is
closed: voice detection runs on the Mac. Codex itself keeps running between lines, and opening
Settings starts another codex to list the voices; what codex sends on its own is codex's. Codex
talks to OpenAI with your ChatGPT login; LiveBridge never reads codex's credentials. The Claude
session sends its work to Anthropic as it always does. LiveBridge has no telemetry.

Notifications never carry a result, but they name its session, and a session's title is often
written from its conversation. With macOS's **Show previews** set to show on the lock screen,
that title can be read there.

### Out of scope

A compromised user account, macOS itself, codex, Claude Code and its engine, and the models'
behaviour beyond what the instructions above ask of them.
