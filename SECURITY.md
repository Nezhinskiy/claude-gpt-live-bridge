# Security policy

## Supported versions

Only the latest release gets fixes. Before 1.0, that is the latest `0.x` tag.

## Reporting a vulnerability

Please report a vulnerability privately, through GitHub's
[private vulnerability reporting](https://github.com/Nezhinskiy/claude-gpt-live-bridge/security/advisories/new)
for this repository; do not open a public issue. Say what an attacker can do, what they need
first, and how to reproduce it. You should hear back within a week. Once a fix is released, the
advisory is published with credit to you unless you ask otherwise.

## Threat model

LiveBridge is a menu bar app plus a Claude Code mod on one Mac, for one user. It turns speech
into prompts for a Claude Code session, so its security comes down to who can put words into
that session and what leaves the Mac.

### Who can drive the bridge

- **Other users of the Mac are kept out.** The mod talks to the app over HTTP on a Unix socket,
  `~/Library/Application Support/claude-gpt-live-bridge/run/bridge.sock`. The `run` folder and the
  data folder above it are created at mode `0700`, or tightened back to it at every start; a
  symlink or a folder another user owns is refused. That folder's permission is the bridge's one
  access control: there is no listening TCP port, no shared secret and no peer check.
- **Every process running as your user is trusted.** Any of them can open the socket, join as a
  session, start a call, read the status and the last lines of the conversation, or post a fake
  answer for the voice to read out. A process running as you can already do worse, such as
  typing into Claude Code itself.
- **Other plugins in the same Claude Code engine are trusted.** They share the engine with the
  mod and can see or submit the same prompts. Install only plugins you trust.

### What the microphone can do

- **Anything audible to the microphone can become a request**: a TV, a call on speaker, another
  person in the room. The voice hands requests to the target session, where Claude runs them
  **under that session's own permission mode, auto mode included**. LiveBridge adds no tool
  guard and never answers a permission prompt; a prompt the session's mode would show still
  appears in Claude Code, and the voice only tells you that one is waiting.
- **The one extra step** is the voice's own confirmation: before it hands off anything
  destructive or outward (delete, push, publish, send, deploy, pay), it repeats the request and
  waits for a spoken "yes", and the prompt Claude receives asks it to confirm in text first unless
  the request says you confirmed by voice. Both are instructions to language models, not
  enforcement. If the session runs in a mode that does not ask before acting, keep voice off, or
  the microphone away from other voices.
- The prompt marks speech as data: the transcript is quoted as recognised speech, and a request
  id that speech cannot forge ties each answer to its request. Speech-recognition errors pass
  through as heard.

### What the voice model can do

The voice runs on a codex thread that is ephemeral and read-only (`sandbox_mode="read-only"`,
`approval_policy="never"`, web search off, notifications off), with every codex feature that
runs tools, reads files, browses or installs turned off at launch. The app checks that codex
reports every configured MCP server disabled before each session, and closes the session if one
starts; it interrupts every codex turn on the thread at once and declines every request codex
sends. These checks fail closed: if codex cannot list its features, reports an MCP server that
is not disabled, leaves a configured server out of its report, or answers in a shape this
version does not read, the call does not start.

Results, open tasks and context summaries are added to the voice as one tagged line each, with
every bracket neutralised and line breaks removed, so a session's text cannot pose as another
delivery. Each goes in with the rank of the owner's own words (`user`), never as an instruction
to the voice (`developer`), and the prompt treats them as data to relay. The voice still reads
them as the owner's turn, so a session's text could try to steer it.

**Residual risk, by design.** Claude skips its own text confirmation when a request says the
owner already confirmed it by voice, and the voice writes that sentence itself. Anything that can
steer the voice can therefore produce it: text a joined session read (a README, an issue, a web
page, a tool's output) that reaches the voice through a result, an update or a summary, or
anything audible to the microphone. The voice is told to hand such a request off only after a
spoken yes, but that is an instruction, not enforcement. Join only sessions whose input you trust, and keep
voice off for a session whose permission mode acts without asking.

### What leaves the Mac

Through codex's realtime session, to OpenAI: microphone audio while the line is open (from 2 s
before speech starts until it closes), the voice's instructions, the recent conversation (up to
24 lines), the briefs of requests still open, each result, question, update and approval notice
(at most 2,000 characters, code blocks and tables removed), and a session's context summary when
you load it (at most 1,500 characters), each line with its session's label (the session title,
or its folder's name), and the WebRTC offer with the Mac's local addresses as connection
candidates. Results and summaries pass through a redactor of known
credential shapes first (private keys, JWTs, common API tokens, URL passwords, `password=`-style
fields). It is a list of patterns, not a guarantee. Nothing is sent while the line is closed:
voice detection runs on the Mac.

Codex talks to OpenAI with your ChatGPT login; LiveBridge never reads codex's credentials. The
Claude session sends its work to Anthropic as it always does. LiveBridge has no telemetry.

### Out of scope

A compromised user account, macOS itself, codex, Claude Code and its engine, and the models'
behaviour beyond what the instructions above ask of them.
