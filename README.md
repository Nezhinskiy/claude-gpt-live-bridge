<p align="center"><img src="docs/assets/logo.svg" alt="LiveBridge" width="360"></p>

# claude-gpt-live-bridge

Talk to an open Claude Code session by voice. A macOS menu bar app, **LiveBridge**, keeps a
GPT-Live voice line ready through `codex app-server` on your ChatGPT login (no API key). The
voice is the front desk: it chats, asks what you mean, and hands real work to the Claude
session through a small Claude Code mod, `livebridge`. Claude does the work with its own model,
tools and permission mode, and the voice tells you the result.

*Русская версия: [README.ru.md](README.ru.md).*

**Local by design.** No telemetry and no server of its own: LiveBridge is a bridge on your Mac
between your own codex and your own Claude Code. The app and the mod talk over a Unix socket
only your user can open, and the app listens on no network port. The only traffic that leaves
your Mac is what those two tools already send: the voice line to OpenAI through your codex,
only while it is open, and Claude's work to Anthropic through your Claude Code session.
Exactly what reaches OpenAI is listed under [Privacy](#privacy); what this does and does not
protect against is in [SECURITY.md](SECURITY.md).

> **Unofficial.** This project is not affiliated with, endorsed by or supported by Anthropic or
> OpenAI. It relies on codex's experimental realtime API, which can change with any codex
> release.

<!-- Demo: a short screen recording goes here with the v0.1.0 release. -->
**Demo:** coming with the v0.1.0 release.

## Requirements

- macOS 14 or later on Apple Silicon.
- Claude Code 2.1.289 or later (mods).
- [Codex CLI](https://github.com/openai/codex) (`codex`, tested with 0.166.0), installed with
  Homebrew (`brew install --cask codex`) or npm (`npm install -g @openai/codex`), on the `PATH` your shell sets in a Terminal window, and signed in with `codex
  login` to a ChatGPT plan that includes realtime voice. LiveBridge refuses a codex whose
  `codex features list` it cannot read, so another version may not start until LiveBridge is
  updated.
- To build the app: Xcode with a Swift 6.0 toolchain or later. The tested versions are in
  [CONTRIBUTING.md](CONTRIBUTING.md#toolchain). The built app runs on macOS 14 or later.

## Install

The mod, from this repository's marketplace:

```sh
claude plugin marketplace add Nezhinskiy/claude-gpt-live-bridge
claude plugin install livebridge@claude-gpt-live-bridge
```

The app, built from source and installed in `~/Applications`:

```sh
git clone https://github.com/Nezhinskiy/claude-gpt-live-bridge.git
cd claude-gpt-live-bridge
scripts/build-app.sh --release
```

Run `scripts/build-app.sh --release` again to upgrade. The build is signed ad hoc, so macOS
asks for the microphone again after each upgrade. To keep the permission, run
`scripts/build-app.sh --make-signing-identity` once: it asks first, then creates a self-signed
code-signing certificate in your login keychain, and later release builds are signed with it.

The first Start asks macOS for the microphone. If it was refused, the call stops with a
sentence and the menu bar menu's **Open Microphone Settings** opens Privacy & Security > Microphone,
where you allow LiveBridge. With the ad hoc signature macOS asks again after every upgrade (see
above). macOS may also ask whether LiveBridge may find devices on your local network. The voice
line needs that second permission too; without it the call stops with a sentence that says where
to allow it.

To remove everything the app keeps: `scripts/build-app.sh --uninstall`. It removes the app, its
login item and its files, and prints the two commands it leaves to you: `tccutil reset
Microphone io.github.nezhinskiy.livebridge` and `claude plugin uninstall
livebridge@claude-gpt-live-bridge`.

## Use

In the Claude Code session you want to talk to:

| Command | What it does |
|---|---|
| `/live on` | Joins LiveBridge under the session's title, and opens the app if it is not running. |
| `/live off` | Leaves LiveBridge. |
| `/live target` | Makes this session the one the voice hands work to. |
| `/live status` (or just `/live`) | One line: the call, the target, unheard results, minutes today. |
| `/live context` | Sends the voice a new summary of this session, written by the session's model. |

The command is `/live`, not `/voice`, because `/voice` is Claude Code's own voice mode. Whether a
session's summary is also sent whenever it becomes the target is not a command: it is one setting
for every session, in LiveBridge's Settings window (see below).

Then press **Start**, in the band above the prompt or in the menu bar menu, and talk. The
band's Start makes its session the target, starts the call and sends the voice the session's
summary, with "Loading context…" and then "Context sent" in the band while it goes. A new
session with no prompt yet has nothing to summarise, and when no turn has completed since the
last summary, Start sends that one again instead of asking the model for another. While the
call talks to another session, the band shows **Talk here** beside Stop. The menu bar
item opens a native macOS menu, with the system's own corners, material and shadow. Its first
row is the call: Start stays disabled there until a session has joined, and until then the menu
has **Copy /live on**, to paste into a session. The menu lists the joined sessions, five of them
with the rest under **More sessions** (click one to make it the target, and the menu stays open
as the marker moves; its × asks first, then removes it and erases its conversation, and
`/live on` in that session joins it again). It has **Load context** (it waits, as **Loading
context…**, until the target's summary arrives or a minute passes), **New conversation…** (it
asks before it erases what the voice remembers of the target and its loaded context) and a
**Conversation** submenu with the whole conversation LiveBridge keeps for the target, every
line in full, in a list that scrolls and opens at the newest line, and the context line exactly
as it was sent; then the minutes the voice line was open this call and
today, **Settings…** (⌘,) and **Quit LiveBridge** (⌘Q). Both erasing items ask first, with
Cancel as the default. When Start fails because codex is not
installed or not signed in, the problem has **How to install codex** or **How to sign in**: the
steps, and a button that copies the command to run in Terminal.

**Settings…** opens LiveBridge's Settings window:

- **Voice**: the realtime voices your codex offers (codex lists them when the window opens), or
  **Codex default**. A new voice is heard from the next time the voice line opens. If codex
  cannot list its voices, the window says why and the line keeps the voice already chosen; a
  voice codex no longer offers goes back to the default.
- **Model**: **Codex default** (the realtime model codex is set to use) or **Named model**, a
  realtime model name you type, so a newer model can be used without a LiveBridge update. Codex
  does not list its realtime models, so the name is not checked in advance: if codex refuses
  it, the line shows codex's error. Used from the next time the line opens.
- **Prompt** (empty by default): your own instructions for the voice, such as "Speak with me in
  Spanish", up to 2,000 characters. They are added after LiveBridge's own rules for the voice,
  which win where the two disagree, and apply from the next time the line opens.
- **Load a session's context automatically when it becomes the target** (off by default): one
  setting for every session, kept by the app.
- **Notify when a result is waiting** (on by default): with the chime for a result that waits
  while the line is closed, a macOS notification names the session ("Alpha has a new result —
  speak to hear it", or "2 sessions have new results"), never the result itself. A newer one
  replaces the last; clicking it opens the menu bar menu, which shows who answered. macOS asks for permission the first time
  a notification is posted; if it is refused, Settings says so and opens the Notifications
  settings.
- **Open at login** (off by default).

What the voice does:

- It answers small talk and explanations itself, and hands off anything that needs the
  repository or the session: tasks, questions about the code, decisions, corrections and stops.
- Before it hands off anything destructive or outward (delete, push, publish, send, deploy,
  pay) it repeats the request and asks "yes?". This is a habit the voice is told to keep, not a
  safeguard; [SECURITY.md](SECURITY.md) says what is one.
- It reads results back in a sentence or two, with the session's name. Code blocks and tables
  stay in the session, and credentials it recognises are redacted.
- When Claude asks a question, the voice puts it to you and sends your answer back to that
  session. Work Claude finishes later in the background is reported as an update.
- When Claude is waiting for a permission prompt, the voice says so. You answer the prompt in
  Claude Code; LiveBridge never answers it for you.

## Billing-aware by design

A realtime voice session costs while it is open, so LiveBridge opens it only while someone is
talking:

- While a call is on and nobody is talking, the microphone feeds only a voice detector on your
  Mac. Nothing is sent anywhere.
- When you start speaking, the line opens. The 2 seconds before you started are kept and sent
  first, so your first words are not lost.
- The line closes after 20 seconds of silence, or as soon as the voice has acknowledged a
  handoff. Sound without words (music, a TV) closes it after 90 seconds.
- A result that arrives while the line is closed plays a chime and waits: the band and the
  menu show it as unheard, and the voice tells you when you next speak. A result counts as
  heard only once a reply of the voice has said it ([the rule](docs/architecture/overview.md#a-result-while-the-line-is-closed));
  if the line closes first, it chimes and waits again.
- Each Claude Code session has its own conversation with the voice. It is carried over to the
  next realtime session, and across Stop and Start, so the voice remembers what you said a minute
  ago. A new target switches the conversation: an open line closes, and your next words open it
  with the new target's.
- The menu shows the minutes the line was open, as measured by the app; how your plan meters
  realtime voice is not published.

## Privacy

LiveBridge has no telemetry and listens on no network port; the mod talks to the app over a Unix
socket in a folder only your user can open. What goes to OpenAI, through codex's realtime
session:

- microphone audio while the line is open, from 2 seconds before you started speaking until it
  closes;
- the voice's instructions;
- the target session's recent conversation (up to the last 24 lines) to continue it in a new
  realtime session;
- the target session's requests still open, as their one-line briefs;
- each result, question, update and approval notice, as one line of at most 2,000 characters,
  with code blocks and tables removed. An update is Claude's answer in a later turn started by a
  background task's notification, for up to 10 minutes after a voice request and until any other
  turn starts in the session;
- a session's context summary when you load it, as one line of at most 1,500 characters. The
  menu's Conversation submenu shows that line exactly as it was sent;
- with every line above, its session's label: the Claude Code session title, or the session
  folder's name when it has none;
- the WebRTC offer, which lists the Mac's local network addresses as connection candidates.

Results, questions, updates and summaries pass through a redactor of known credential shapes
first (private keys, JWTs, common API tokens, URL passwords, `password=`-style fields). It is a
list of patterns, not a guarantee.

The codex thread that carries the voice is ephemeral and read-only, with every codex feature
turned off except where it keeps your login and how it uses your proxy, and every MCP server off; it is there only to talk.
Claude's work goes to Anthropic as your Claude Code session always does. On your Mac the app
keeps its settings, the usage meter and, for each of the 20 sessions used last, its recent conversation and
the context line last loaded from it, until you press **New conversation** with it as the target
or remove it, in `~/Library/Application Support/claude-gpt-live-bridge`.

[SECURITY.md](SECURITY.md) has the threat model: in short, anything your microphone can hear
can become a request that Claude runs under the session's own permission mode.

## Known limitations

- When your next words reopen the line, the voice sometimes answers only them and does not say
  the waiting result. The result is not lost: it stays waiting, chimes and posts a notification
  when the line closes, and goes to the voice again the next time the line opens.
- A Claude Code session that was already open before the mod loaded may need to be reopened
  before `/live` works in it.
- In the Claude desktop app, `/live` typed in a session whose Claude Code process has not
  started yet (a new session, or one just reopened) can show "/live isn't a command here." The
  command still runs. The desktop lists such a session's commands from a check it runs with hooks
  turned off, so the mod's code, which declares `/live`, does not run there; once the session is
  running, the desktop takes its list from the session itself. The mod has no fix for this: a
  static command file would be listed as `/livebridge:live`, not `/live`, and with hooks off it
  would send its text to the model instead of running the mod.
- Whether a reply has said a waiting result is judged by its words, against a list of common
  words in English and Russian only. In another language a result can count as heard when the
  voice only mentioned it.

## How it works

[docs/architecture/overview.md](docs/architecture/overview.md) describes the components and the
message flows; [ADR 0001](docs/adr/0001-platform-findings.md) records the platform facts the
design rests on.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Credits

The wire protocol between the mod and the app was inspired by
[claude-code-voice-mod](https://github.com/ldk00315-jpg/claude-code-voice-mod). No code or text
was copied from it.

## License

[MIT](LICENSE).
