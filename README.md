<p align="center"><b>English</b> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.hi.md">हिन्दी</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.ru.md">Русский</a> · <a href="README.uk.md">Українська</a></p>

<p align="center"><img src="site/assets/icon.png" alt="LiveBridge app icon" width="144"></p>

<h1 align="center">LiveBridge</h1>

<p align="center"><strong>Talk to an open Claude Code session by voice.</strong></p>

<p align="center">
  <a href="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml"><img src="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B%20%C2%B7%20Apple%20Silicon-lightgrey.svg" alt="Platform: macOS 14+ on Apple Silicon">
</p>

<p align="center">
  <a href="https://getlivebridge.com">getlivebridge.com</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#install">Install</a> ·
  <a href="#use">Use</a> ·
  <a href="#billing-aware-by-design">Billing</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="#known-limitations">Limitations</a> ·
  <a href="#roadmap-and-help-wanted">Help wanted</a> ·
  <a href="#contributing">Contributing</a>
</p>

LiveBridge is a macOS menu bar app that keeps a GPT-Live voice line ready through
`codex app-server` on your ChatGPT login (no API key). The voice is the front desk: it chats,
asks what you mean, and hands real work to your Claude Code session through a small Claude Code
mod, `livebridge`. Claude does the work with its own model, tools and permission mode, and the
voice tells you the result.

<p align="center"><img src="site/assets/demo.gif" alt="Talking to a Claude Code session through LiveBridge" width="100%"></p>

**Local by design.** No telemetry and no server of its own: LiveBridge is a bridge on your Mac
between your own codex and your own Claude Code. The app and the mod talk over a Unix socket
only your user can open, and the app listens on no network port. Besides what those two tools
already send (the voice line to OpenAI through your codex, only while it is open, and Claude's
work to Anthropic through your Claude Code session), the app's only traffic of its own is for
[updates](#updating): an automatic check with GitHub for a new release (daily, and at launch
while one it announced is not installed), which you can turn off; the same check when you press
**Check for update**; `gh auth status` when a new release is announced; and the download, its
verification and the mod's update when you click **Install**. [Privacy](#privacy) lists exactly
what reaches OpenAI and names the requests the app makes to GitHub; [SECURITY.md](SECURITY.md)
says what this does and does not protect against.

> **Unofficial.** Not affiliated with, endorsed by or supported by Anthropic or OpenAI. It relies
> on codex's experimental realtime API, which can change with any codex release.

## Quick start

You need macOS 14+ on Apple Silicon, Claude Code 2.1.289+, and
[codex](https://github.com/openai/codex) signed in (`codex login`) to a ChatGPT plan with
realtime voice; to build the app yourself, also Xcode with Swift 6.0+. The details are under
[Requirements](#requirements).

```sh
# 1. The mod, from this repository's marketplace
claude plugin marketplace add getLiveBridge/LiveBridge
claude plugin install livebridge@livebridge

# 2. The app, built from source, installed in /Applications and opened
git clone https://github.com/getLiveBridge/LiveBridge.git
cd livebridge
scripts/build-app.sh --release
```

3. In the Claude Code session you want to talk to, type `/live on`.
4. Press **Start** in the band above the prompt, allow the microphone, and talk.

Rather not build it? Each [release](https://github.com/getLiveBridge/LiveBridge/releases/latest)
has the app as a disk image, built and attested by GitHub Actions;
[From the disk image](#from-the-disk-image) says how to check it and open it. The mod is
installed the same way either way.

If `/live` is not found in a session that was already open, reopen the session
([why](#known-limitations)). Updating, permissions, keeping the microphone permission across
rebuilds and uninstalling are under [Install](#install).

## Requirements

- macOS 14 or later on Apple Silicon.
- Claude Code 2.1.289 or later (mods).
- [Codex CLI](https://github.com/openai/codex) (`codex`, tested with 0.166.0), installed with
  Homebrew (`brew install --cask codex`) or npm (`npm install -g @openai/codex`), on the `PATH`
  your shell sets in a Terminal window, and signed in with `codex login` to a ChatGPT plan that
  includes realtime voice. LiveBridge refuses a codex whose `codex features list` it cannot
  read, so another version may not start until LiveBridge is updated.
- To build the app: Xcode with a Swift 6.0 toolchain or later. The tested versions are in
  [CONTRIBUTING.md](CONTRIBUTING.md#toolchain). The built app runs on macOS 14 or later.

## Install

The mod comes from this repository's marketplace (the [Quick start](#quick-start) commands),
which names the latest release's tag, so the mod you install is that release's. The app goes in
`/Applications` either way: from the disk image, or built from source. Either way it is signed
ad hoc and not notarized.

### From the disk image

1. Download
   [LiveBridge.dmg](https://github.com/getLiveBridge/LiveBridge/releases/latest/download/LiveBridge.dmg)
   from the latest release.
2. Check it with the [GitHub CLI](https://cli.github.com), in the folder you saved it to:

   ```sh
   gh attestation verify LiveBridge.dmg --repo getLiveBridge/LiveBridge \
     --signer-workflow getLiveBridge/LiveBridge/.github/workflows/release.yml \
     --source-ref refs/tags/vX.Y.Z --deny-self-hosted-runners
   ```

   with `vX.Y.Z` the release's tag, as its page names it. This passes only for an image that
   this repository's [release workflow](.github/workflows/release.yml) built from that tag, on a
   GitHub-hosted runner, and that has not changed since. It is the image's one proof of origin:
   the ad hoc signature names no one. It does not prove that anyone reviewed the code.
3. Open it and drag LiveBridge to Applications.
4. On first launch macOS blocks the app until you allow it under System Settings > Privacy &
   Security > **Open Anyway**.

### From source

`scripts/build-app.sh --release` builds the app, installs it in `/Applications` (your account
must be able to write there, as an administrator's can) and opens it. Run it again to rebuild.
The build is signed ad hoc, so macOS asks for the microphone again after each rebuild. To keep
the permission, run `scripts/build-app.sh --make-signing-identity` once: it asks first, then
creates a self-signed code-signing certificate in your login keychain, and later release builds
are signed with it.

The marketplace pins the mod to the last release's tag, so an app built from the default branch
runs with that release's mod. To match them, build the release's tag (`git checkout vX.Y.Z`), or
load the working tree's mod with `claude --plugin-dir plugin`.

A build from source checks for updates by itself only if you turn that on in Settings.
Installing an update replaces it with the release's image, which is signed ad hoc, so the
self-signed certificate no longer applies; **Install** says so and asks first.

### Updating

LiveBridge updates itself and its mod when you click **Install**, and never on its own. Only
the copy at `/Applications/LiveBridge.app` updates; any other copy says so in Settings.

- **Check for updates automatically**, in Settings (on by default, off for a build from
  source): once a day, the app asks GitHub which release is the latest. A newer one is
  announced once, with a notification whose **Install** installs it, and the menu bar menu
  offers **Install LiveBridge X.Y.Z…** until it is installed, asking GitHub again at each launch
  to keep that item. **Check for update** in Settings asks at once.
- **Install** needs the [GitHub CLI](https://cli.github.com) signed in (`gh auth login`);
  without it, Install downloads nothing and links to the release page. It downloads the
  release's image, checks it with the same `gh attestation verify` as above, then checks the
  app inside it, and installs nothing unless every check passes. It waits while Claude is still
  on a voice request, updates the mod with `claude plugin marketplace update livebridge` and
  `claude plugin update livebridge@livebridge`, stops the call, puts the new app in place in one
  step and opens it.
- Afterwards Settings says which version it updated from. If the mod could not be updated, it
  shows those two commands for you to run. Claude Code sessions already open keep the old mod
  until they restart.
- The update's download sets no quarantine attribute, so macOS should not block the updated
  app's first launch as it blocked the first download; this follows from the code and has not
  yet been observed. The checks above are what stands in its place
  ([SECURITY.md](SECURITY.md#what-an-update-installs)). macOS does ask for the microphone again
  at the first **Start** after an update, because each release is signed ad hoc.

To update by hand instead, run `/live off` in every session (the mod reopens the app at
`/Applications` whenever the app stops answering), quit LiveBridge, install the newer image as
above and run the two `claude plugin` commands.

### Permissions

The first Start asks macOS for the microphone. If it was refused, the call stops with a
sentence and the menu bar menu's **Open Microphone Settings** opens Privacy & Security >
Microphone, where you allow LiveBridge. With the ad hoc signature macOS asks again at the first
Start after every update or rebuild (see above). macOS may also ask whether LiveBridge may find
devices on your local network. The voice line needs that second permission too; without it the
call stops with a sentence that says where to allow it.

### Uninstall

From a clone, `scripts/build-app.sh --uninstall` removes `/Applications/LiveBridge.app`,
however it was installed, its login item and every file it keeps, and prints the two commands
it leaves to you: `tccutil reset Microphone com.getlivebridge.livebridge` and
`claude plugin uninstall livebridge@livebridge`.

Without a clone, turn off **Open at login** in LiveBridge's Settings, quit LiveBridge, and run
the same steps in Terminal:

```sh
rm -rf /Applications/LiveBridge.app ~/Library/Application\ Support/LiveBridge \
  ~/Library/{Caches,WebKit}/com.getlivebridge.livebridge \
  ~/Library/HTTPStorages/com.getlivebridge.livebridge{,.binarycookies} \
  ~/Library/Preferences/com.getlivebridge.livebridge.plist
tccutil reset Microphone com.getlivebridge.livebridge
claude plugin uninstall livebridge@livebridge
```

Neither removes a copy named `/Applications/.LiveBridge-update-….app`, which an update stopped
mid-install can leave behind. The app removes such copies at its next launch; after an
uninstall, delete one by hand if it is there.

## Use

### Commands

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
for every session, in LiveBridge's [Settings](#settings) window.

### The band and the menu

Press **Start**, in the band above the prompt or in the menu bar menu, and talk.

- **The band's Start** makes its session the target, starts the call and sends the voice the
  session's summary ([details](docs/architecture/overview.md#components)). While the call talks
  to another session, the band shows **Talk here**. If the band is not there in a joined
  session, `/live on` brings it back.
- **The menu bar menu** has the call, the joined sessions (click one to make it the target),
  **Load context**, the target's **Conversation** as LiveBridge keeps it (with a **Task** line
  for each request the voice handed to Claude), the minutes, **Settings…** and
  **Quit LiveBridge**.
- **New conversation…** erases the target's conversation and its loaded context, and a
  session's × removes it and erases its own; both ask first. The voice starts afresh from the
  next time the line opens, and `/live on` in a removed session joins it again.

### Settings

**Settings…** opens LiveBridge's Settings window:

- **Voice**: one of the realtime voices your codex offers, which codex lists when the window
  opens, or **Codex default**. It is heard from the next time the line opens.
- **Prompt** (empty by default): your own instructions for the voice, such as "Speak with me in
  Spanish", up to 2,000 characters. They are added after LiveBridge's own rules for the voice,
  which win where the two disagree, and apply from the next time the line opens.
- **Load a session's context automatically when it becomes the target** (off by default): one
  setting for every session, kept by the app.
- **Notify when a result is waiting** (on by default): with the chime for a result that waits
  while the line is closed, a macOS notification names the session ("Alpha has a new result —
  speak to hear it"), never the result itself. Clicking it opens the menu bar menu.
- **Open at login** (off by default).
- **Updates**: the running version, **Check for update**, **Check for updates automatically**
  and what the last update did ([Updating](#updating)).

### What the voice does

- It answers small talk and explanations itself, and hands off anything that needs the
  repository or the session: tasks, questions about the code, decisions, corrections and stops.
- Before it hands off anything destructive or outward (delete, push, publish, send, deploy,
  pay) it repeats the request and asks "yes?". This is a habit the voice is told to keep, not a
  safeguard; [SECURITY.md](SECURITY.md) says what is one.
- It reads results back in a sentence or two, with the session's name. Code blocks and tables
  stay in the session, and credentials it recognises are redacted.
- When Claude asks a question, the voice puts it to you and sends your answer back to that
  session. So it does with a question Claude asks while it works (the dialog with options): the
  voice tells you about it, explains the options in its own words and talks them over with you
  for as long as you like, without asking Claude. What you decide, an option or a question back
  to Claude, answers the dialog; you can still answer it at the keyboard instead. Work Claude
  finishes later in the background is reported as an update.
- When Claude is waiting for a permission prompt, the voice says so. You answer the prompt in
  Claude Code; LiveBridge never answers it for you.

## Billing-aware by design

A realtime voice session costs while it is open, so LiveBridge opens it only while someone is
talking, or while Claude's answer to a request you just made may still come:

- While a call is on and nobody is talking, the microphone feeds only a voice detector on your
  Mac. Nothing is sent anywhere.
- When you start speaking, the line opens. The 2 seconds before you started are kept and sent
  first, so your first words are not lost.
- The line closes after 20 seconds of silence. Sound without words (music, a TV) closes it after
  90 seconds.
- When the voice hands a request to Claude (a handoff), the line stays open for up to 2 minutes
  after that handoff, billed like any open line, and the voice says Claude's answer once nobody
  is talking. A later handoff starts the 2 minutes again; an exchange that sends nothing to
  Claude closes after the usual 20 seconds of silence.
- A result that arrives later, while the line is closed, plays a chime and waits: the band and
  the menu show it as unheard, and the voice tells you when you next speak
  ([when it counts as heard](docs/architecture/overview.md#a-result-while-the-line-is-closed)).
- Each Claude Code session has its own conversation with the voice. It is carried over to the
  next realtime session, and across Stop and Start, so the voice remembers what you said a minute
  ago. A new target switches the conversation: an open line closes, and your next words open it
  with the new target's.
- The menu shows the minutes the line was open, as measured by the app. OpenAI prices desktop
  voice per minute of your Codex budget, and on its API the same model family bills silence too
  ([details](docs/research/2026-11-04-gpt-live-billing.md)); your plan's own usage page is the
  authority.

## Privacy

LiveBridge has no telemetry and listens on no network port; the mod talks to the app over a Unix
socket in a folder only your user can open. What goes to OpenAI, through codex's realtime
session:

- microphone audio while the line is open, from 2 seconds before you started speaking until it
  closes;
- the voice's instructions: LiveBridge's own rules, then your Settings **Prompt** if you wrote
  one;
- the target session's recent conversation (up to the last 24 lines) to continue it in a new
  realtime session;
- the target session's requests still open, as their one-line briefs;
- each result, question, update and approval notice, as one line of at most 2,000 characters,
  with code blocks and tables removed. An update is Claude's answer in a later turn started by a
  background task's notification, for up to 10 minutes after a voice request and until any other
  turn starts in the session;
- the target session's context summary, as one line of at most 1,500 characters. It is saved
  when it is loaded and sent every time the line opens while that session is the target, across
  Stop and Start and app restarts. The menu's Conversation submenu shows that line exactly as it
  is sent;
- with every line above, its session's label: the Claude Code session title, or the session
  folder's name when it has none;
- the WebRTC offer, which lists the Mac's local network addresses as connection candidates.

Results, questions, updates and summaries pass through a redactor of known credential shapes
first (private keys, JWTs, common API tokens, URL passwords, `password=`-style fields). It is a
list of patterns, not a guarantee.

The codex thread that carries the voice is ephemeral and read-only, with every codex feature
turned off except where it keeps your login and how it uses your proxy, and every MCP server
off; it is there only to talk. Claude's work goes to Anthropic as your Claude Code session
always does.

For updates the app talks to GitHub. With **Check for updates automatically** on, once a day
(and at each launch while a release it announced is not installed) it asks GitHub's API, without
credentials, which release is the latest; GitHub sees your Mac's IP address. **Check for update**
in Settings sends the same request when you press it. When the automatic check finds a newer
release, the app runs `gh auth status` to say whether the image can be verified. Only when you
click **Install** does it download the image and run `gh attestation verify` and
`claude plugin`, which reach GitHub, and Sigstore for `gh`'s trust root, under your own logins.
[SECURITY.md](SECURITY.md#what-leaves-the-mac) lists each request.

On your Mac the app keeps its settings, the usage meter, when it last checked for an update and
which versions it announced, what the last update did and, for each of the 20 sessions used
last, its recent conversation and the context line last loaded from it, in
`~/Library/Application Support/LiveBridge`. A session's lines go when you press **New
conversation** with it as the target or remove it with ×. A session that has left keeps them
until 20 sessions used since push them out; to erase them sooner, run `/live on` in it again and
press **New conversation**. Uninstalling removes them all.

[SECURITY.md](SECURITY.md) has the threat model: in short, anything your microphone can hear
can become a request that Claude runs under the session's own permission mode.

## Known limitations

- A result that arrives while the line waits for it goes to the voice as text to say; codex has
  no call that makes the voice speak at once, so the model decides when. In testing it spoke
  within a few seconds. If it does not, the result stays unheard: the voice says it after your
  next words, or it chimes when the line closes.
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
- Whether a reply has said a waiting result is judged by its words, with a list of common words
  in English and Russian only
  ([the rule](docs/architecture/overview.md#a-result-while-the-line-is-closed)). In another
  language a result can count as heard when the voice only mentioned it.

## How it works

[docs/architecture/overview.md](docs/architecture/overview.md) describes the components, the
wire between the mod and the app, and the message flows;
[ADR 0001](docs/adr/0001-platform-findings.md) records the platform facts the design rests on.

## Roadmap and help wanted

LiveBridge today is one Mac app, one worker (Claude Code) and one voice provider (codex on a
ChatGPT login). The three meet at narrow seams, and each direction below is open to
contributors. Issues for them carry the
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
label; [CONTRIBUTING.md](CONTRIBUTING.md#where-to-start) points to the files to read first.

- **Windows and Linux.** The menu bar app, its audio page and the socket server are tied to
  macOS; the wire between the mod and the app, and the mod itself, are portable. A port starts
  with an app for the new platform that speaks the same wire.
- **Other agents as the worker**, such as Codex CLI, Hermes Agent or Gemini CLI: each needs its
  own adapter that speaks the same wire as the Claude Code mod.
- **Other voice providers**, such as the OpenAI Realtime API with your own API key or Google's
  Gemini Live API: each would be another implementation of the app's realtime protocol.

## Contributing

Contributions are welcome. For anything larger than a fix, open an issue first so the shape can
be agreed before the work starts. Good places to begin are the
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
issues, the [known limitations](#known-limitations) and the directions
[above](#roadmap-and-help-wanted).

- [CONTRIBUTING.md](CONTRIBUTING.md): the layout, the toolchain, the checks (`scripts/check.sh`)
  and the conventions.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md): how we treat each other here.
- [SECURITY.md](SECURITY.md): report a vulnerability privately, not in a public issue.
- [CHANGELOG.md](CHANGELOG.md): what changed in each release.

## Credits

The wire protocol between the mod and the app was inspired by
[claude-code-voice-mod](https://github.com/ldk00315-jpg/claude-code-voice-mod). No code or text
was copied from it.

## License

[MIT](LICENSE).
