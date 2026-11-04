# Contributing

Thanks for helping. Issues and pull requests are welcome; for anything larger than a fix, open
an issue first so we can agree on the shape. The issue forms ask for what a report needs (your
macOS, LiveBridge commit, Claude Code and codex versions, and what the band or menu showed), and
the pull request template asks what changed, why, how you tested it, and whether
`scripts/check.sh` passed. Report a vulnerability privately, as [SECURITY.md](SECURITY.md)
says, not in an issue. Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Layout

| Path | What it is |
|---|---|
| `app/` | The SwiftPM package: `BridgeCore` (pure logic, tested without codex, a microphone or Claude) and `LiveBridge` (the menu bar app and its invisible audio page). |
| `plugin/` | The Claude Code mod `livebridge`. `hooks/register.tsx` is wiring only; the other `hooks/*.ts` modules are pure. |
| `wire/fixtures/` | One JSON file per message between the mod and the app: the shared oracle both sides test against. |
| `scripts/` | `check.sh` (every check CI runs), `build-app.sh` (build, install, uninstall, package), `smoke.sh` (end to end). |
| `docs/` | [Architecture](docs/architecture/overview.md) and [ADRs](docs/adr/); the rest is the stayfixed scaffold (below). |

## Where to start

Small first changes: an open issue labelled
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22),
or one of the README's [known limitations](README.md#known-limitations). The larger directions
are in the README's [roadmap](README.md#roadmap-and-help-wanted). For each, read the
[architecture overview](docs/architecture/overview.md) first, then the files below.

### Windows and Linux

The contract a port must keep is [the wire](docs/architecture/overview.md#the-wire):
`app/Sources/BridgeCore/Wire/Wire.swift`, `plugin/hooks/wire.ts` and the fixtures in
`wire/fixtures/`, which both test suites parse. What is tied to macOS:

- `app/Sources/LiveBridge/`: the AppKit menu bar app (`App.swift`, `StatusItem.swift`,
  `StatusMenu.swift`, `SettingsView.swift`, `Notifier.swift`), the login item
  (`LoginItem.swift`, on `SMAppService`) and the WKWebView that hosts the audio page
  (`AudioHost.swift`).
- `app/Sources/LiveBridge/Resources/audio/`: the audio page, which owns the microphone, the voice
  detector, the pre-roll and the WebRTC peer. Its pure modules are tested in
  `app/Tests/AudioJSTests`, which `scripts/check.sh` runs.
- `app/Sources/BridgeCore/Audio/MicrophoneAccess.swift`: macOS's microphone permission.
- `app/Sources/BridgeCore/Server/UnixHTTPServer.swift`: the socket server, on Apple's Network
  framework. `app/Sources/BridgeCore/Paths.swift`: where the app keeps its files and its socket.
- In the mod, `plugin/hooks/wire.ts` builds the socket path under `~/Library/Application Support`
  and `plugin/hooks/link.ts` opens the app with macOS's `open`.

The rules a port could reuse are in `BridgeCore`: `Call/CallMachine.swift`,
`Sessions/SessionRegistry.swift`, `Call/Continuity.swift` and `Text/` (the answer shaper and the
redactor), with their tests in `app/Tests/BridgeCoreTests`.

### Other agents as the worker

The Claude Code adapter is the mod in `plugin/`: `hooks/register.tsx` wires it to Claude Code's
mod API (the `/live` command, `prompt.submit`, the band), `hooks/link.ts` talks to the app and
runs the one-second poll, `hooks/prompt.ts` and `hooks/turns.ts` decide which turns answer a
voice request and what each posts back, and `hooks/title.ts` reads the session's title from
Claude Code's session registry. An adapter for another agent speaks the same wire: it joins, polls
`GET /v1/next` and posts its answers, activity and context, on the routes listed under
[the wire](docs/architecture/overview.md#the-wire).
`app/Tests/Smoke/fake-session.mjs`, a plain Node script that plays a session for the smoke test,
is the smallest example of that side; `plugin/tests/fake-bridge.ts` plays the app in the mod's
tests. The voice's instructions, in `app/Sources/BridgeCore/Codex/VoicePrompt.swift`, name
Claude Code.

### Other voice providers

The codex side is `app/Sources/BridgeCore/Codex/`. `RealtimeSession.swift` declares the
`RealtimeControlling` protocol and implements it over `codex app-server` (`JSONRPCClient.swift`,
`CodexLaunch.swift`); `Voices.swift` lists the voices for Settings, and `CodexHelp.swift`
explains a missing or signed-out codex. `Bridge` takes a factory for the controller, wired in
`app/Sources/LiveBridge/App.swift`, and `FakeVoice` in
`app/Tests/BridgeCoreTests/BridgeTests.swift` is a minimal implementation to start from. A
provider reports the voice's handoffs, utterances and close as `RealtimeEvent`s. `open` takes
the audio page's WebRTC offer and returns the answer, so a provider without a WebRTC offer and
answer also needs changes to the audio page.

## Toolchain

- A Swift 6.0 toolchain or later, the tools version `app/Package.swift` declares. It is tested
  with Xcode 27 and Swift 6.4 (CI uses Xcode 27.2); older Xcode versions are untested. Liquid
  Glass needs Xcode 26 or later; with an older Xcode the menu's buttons fall back to bordered
  capsules and the app shows only its classic icon.
- Node 26, for the mod's checks and the audio page's tests. `scripts/check.sh` installs the
  mod's development dependencies, TypeScript and `@types/node`, with `npm ci`.
- Claude Code, for the mod's engine-facing half (below).

Dependabot (`.github/dependabot.yml`) proposes weekly updates of the workflows' pinned actions
and the mod's development dependencies, each version a week after its release; CI passes before
one is merged.

## Checks

```sh
scripts/check.sh
```

It runs `swift format lint --strict`, the Swift build and tests, the shell and audio-page
tests, the type check and unit tests of the mod's pure modules, and, when `claude` is on your
`PATH`, the type check of the mod's engine-facing files, `claude plugin validate` and `claude
plugin test`. Without `claude` the script says that half was not checked and still passes; CI
installs Claude Code (a pinned version) on the Xcode 27 macOS runner and runs the same script,
which fails there if `claude` is missing.

The end-to-end smoke test drives the real codex and opens one or two short realtime voice
sessions on your ChatGPT plan, about a minute of voice:

```sh
scripts/smoke.sh
```

It builds the debug app, plays a WAV made with `say` as the microphone, and stands in for a
Claude Code session with `app/Tests/Smoke/fake-session.mjs`. The voice is a language model, so
a run can fail on its wording; if a check fails, run it again before reading much into it, and
report the rate if it keeps failing.

## Releasing

The app and the mod share one version (`check.sh` holds them equal). Pushing the tag
`v<version>` runs `.github/workflows/release.yml` on a GitHub-hosted macOS runner: it refuses a
tag that does not match `Info.plist`, builds the image with `scripts/build-app.sh --package`,
attests it, and creates the tag's Release with `LiveBridge.dmg` attached.

## Running the app while you work

```sh
scripts/build-app.sh --run                      # debug build, then open it
scripts/build-app.sh --run --fake-mic say.wav   # the WAV plays as the microphone
CFFIXED_USER_HOME=/tmp/lb scripts/build-app.sh --run   # keep its files out of your home
/usr/bin/log stream --info --predicate 'subsystem == "com.getlivebridge.livebridge"'
```

`claude --plugin-dir plugin` loads the mod from the working tree. The mod follows
`CFFIXED_USER_HOME` to the socket as the app does, so `CFFIXED_USER_HOME=/tmp/lb claude
--plugin-dir plugin` talks to the app started with the same variable.

## Conventions

- One behaviour, one test, and a failing test before the change that makes it pass.
- No third-party Swift packages in shipped targets and no runtime npm dependencies in the mod.
- Changes to the wire touch `Wire.swift`, `plugin/hooks/wire.ts` and `wire/fixtures` together.
- No personal data anywhere: fixtures use `/Users/example`, `Example session` and
  `00000000-…` ids.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat`, `fix`,
  `docs`, `test`, `build`, `chore`, …), one logical change each.
- Write for a reader who has not seen the code: short sentences, the reason before the detail.

## stayfixed

The repository uses stayfixed, a documentation and process tool, to keep its process
documents in one shape. Its files are:

| Path | What it is for |
|---|---|
| `stayfixed.toml` | The project's settings: names, the base branch, where notes are kept. |
| `.stayfixed/manifest.json` | A record of the files stayfixed wrote, so an upgrade keeps hand edits. Do not edit it. |
| `AGENTS.md` (the marked region) | Instructions for coding agents; stayfixed rewrites only the region between its markers. |
| `docs/roadmap.md`, `docs/roadmap-history.md`, `docs/trail.toml` | Where the project is now and what comes next; closed phases; the index of design and plan documents. |
| `docs/specs/`, `docs/plans/` | Design and plan documents, when a change is big enough to need one. |
| `docs/bugs/`, `docs/bug-reports.md`, `docs/runbooks/bug-reports.md` | The bug ledger: one file per entry, a generated index (do not edit it by hand), and how to file and close an entry. |
| `docs/adr/0000-template.md` | The template for a new ADR. |
| `docs/architecture/documentation.md` | Where each kind of fact belongs, so each has one home. |

You do not need stayfixed to contribute: the files are plain Markdown and TOML. With it,
`stayfixed docs check` checks the documents' budgets and links.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
