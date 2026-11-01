<p align="center"><img src="docs/assets/logo.svg" alt="LiveBridge" width="360"></p>

# claude-gpt-live-bridge

Talk to an open Claude Code session by voice. A macOS menu bar app, **LiveBridge**, keeps a
GPT-Live voice line ready through `codex app-server` on your ChatGPT login (no API key). The
voice is the front desk: it chats, asks what you mean, and hands real work to the Claude
session through a small Claude Code mod, `livebridge`. Claude does the work with its own model,
tools and permission mode, and the voice tells you the result.

*Русская версия: [README.ru.md](README.ru.md).*

> **Unofficial.** This project is not affiliated with, endorsed by or supported by Anthropic or
> OpenAI. It relies on codex's experimental realtime API, which can change with any codex
> release.

<!-- Demo: a short screen recording goes here with the v0.1.0 release. -->
**Demo:** coming with the v0.1.0 release.

## Requirements

- macOS 14 or later on Apple Silicon.
- Claude Code 2.1.289 or later (mods).
- [Codex CLI](https://github.com/openai/codex) (`codex`, tested with 0.166.0) on your login
  shell's `PATH`, signed in with `codex login` to a ChatGPT plan that includes realtime voice.
- To build the app: Xcode with Swift 6 (tested with Xcode 27 and Swift 6.4).

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

On the first call macOS asks for the microphone, and may ask whether LiveBridge may find devices
on your local network. The voice line needs that second permission too; without it the call
stops with a sentence that says where to allow it.

To remove everything the app keeps: `scripts/build-app.sh --uninstall`. It removes the app, its
login item and its files, and prints the two commands it leaves to you: `tccutil reset
Microphone io.github.nezhinskiy.livebridge` and `claude plugin uninstall
livebridge@claude-gpt-live-bridge`.

## Use

In the Claude Code session you want to talk to:

| Command | What it does |
|---|---|
| `/voicemod on` | Joins LiveBridge under the session's title, and opens the app if it is not running. |
| `/voicemod off` | Leaves LiveBridge. |
| `/voicemod target` | Makes this session the one the voice hands work to. |
| `/voicemod status` | One line: the call, the target, unheard results, minutes today. |
| `/voicemod context` | Sends the voice a short summary of this session, written by the session's model. |
| `/voicemod context auto` / `manual` | Sends that summary whenever the session becomes the target, or only on request. |

Then press **Start**, in the band above the prompt or in the menu bar popover, and talk. The
popover lists the joined sessions (click one to make it the target), shows the last lines of the
conversation and exactly what context was sent, and has **New conversation**, **Open at login**
(off by default) and the minutes the voice line was open today.

What the voice does:

- It answers small talk and explanations itself, and hands off anything that needs the
  repository or the session: tasks, questions about the code, decisions, corrections and stops.
- Before it hands off anything destructive or outward (delete, push, publish, send, deploy,
  pay) it repeats the request and asks "yes?".
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
  popover show it as unheard, and the voice tells you when you next speak. A result counts as
  heard only once the voice has replied after it; if the line closes first, it chimes and waits
  again.
- The conversation is carried over to the next session, and across Stop and Start, so the voice
  remembers what you said a minute ago.
- The popover shows the minutes the line was open, as measured by the app; how your plan meters
  realtime voice is not published.

## Privacy

LiveBridge has no telemetry and listens on no network port; the mod talks to the app over a Unix
socket in a folder only your user can open. What goes to OpenAI, through codex's realtime
session:

- microphone audio while the line is open, from 2 seconds before you started speaking until it
  closes;
- the voice's instructions;
- the recent conversation (up to the last 24 lines) to continue it in a new session;
- the requests still open, as their one-line briefs;
- each result, question, update and approval notice, as one line of at most 2,000 characters
  with code blocks and tables removed and recognised credentials redacted. An update is Claude's
  answer in a later turn started by a background task's notification, for up to 10 minutes
  after a voice request and until any other turn starts in the session;
- a session's context summary when you load it (at most 1,500 characters, redacted the same
  way). The popover shows exactly what was sent.

The codex thread that carries the voice is ephemeral and read-only, with every codex tool and
MCP server turned off; it can only talk. Claude's work goes to Anthropic as your Claude Code
session always does. On your Mac the app keeps the recent conversation and the usage meter in
`~/Library/Application Support/claude-gpt-live-bridge`.

[SECURITY.md](SECURITY.md) has the threat model: in short, anything your microphone can hear
can become a request that Claude runs under the session's own permission mode.

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
