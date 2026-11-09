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
| `scripts/` | `check.sh` (every check CI runs but the floor run), `check-mod.sh` (the mod's engine-facing half), `check-floor.sh` (that half on the lowest Claude Code the README promises), `build-app.sh` (build, install, uninstall, package), `smoke.sh` (end to end). |
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
  mod's development dependencies, TypeScript, `@types/node` and fast-check, with `npm ci`.
- Claude Code, for the mod's engine-facing half (below).

Dependabot (`.github/dependabot.yml`) proposes weekly updates of the workflows' pinned actions
and the mod's development dependencies, each version a week after its release; CI passes before
one is merged. It leaves the two Claude Code lockfiles under `.github/` alone, as its header says.

## Checks

```sh
scripts/check.sh
```

It runs `swift format lint --strict`, the Swift build and tests, the shell and audio-page
tests, the type check and unit tests of the mod's pure modules, and, when `claude` is on your
`PATH`, the type check of the mod's engine-facing files, `claude plugin validate` and `claude
plugin test`. Without `claude` the script says that half was not checked and still passes; CI
installs Claude Code (the version `.github/claude-code` pins, by hash; to move it, change that
folder's `package.json` and run `npm install --package-lock-only` there) on the Xcode 27 macOS
runner and runs the same script, which fails there if `claude` is missing.

CI then runs the engine-facing half again on the lowest Claude Code the README promises, so the
mod's type check, validation and tests must pass on that version; a need none of them reach still
passes. To run it yourself, after `check.sh` has installed the mod's dev dependencies:

```sh
scripts/check-floor.sh
```

It reads the version from the `Claude Code` line under Requirements in `README.md`, the number's
home, and installs it in `.github/claude-code-floor` with `npm ci` from that folder's lockfile,
pinned by hash. To change the floor, change that line, set the same version in that folder's
`package.json` and run `npm install --package-lock-only` there; `check.sh` fails until every copy
says the same.

The end-to-end smoke test drives the real codex and spends your ChatGPT plan's realtime voice;
the header of `scripts/smoke.sh` says how much and what a pass is:

```sh
scripts/smoke.sh
```

It builds the debug app, plays a WAV made with `say` as the microphone, and stands in for a
Claude Code session with `app/Tests/Smoke/fake-session.mjs`. The voice is a language model, so
a run can fail on its wording; if a check fails, run it again before reading much into it, and
report the rate if it keeps failing.

## Releasing

The app and the mod share one version. The release commit sets it in `app/Support/Info.plist`
and `plugin/.claude-plugin/plugin.json`, moves `.claude-plugin/marketplace.json`'s `ref` to the
new tag `v<version>` (the mod is installed and updated from that tag), and renames
`CHANGELOG.md`'s Unreleased section to the version; `check.sh` fails when the three versions
differ (`scripts/tests/release-guards.test.sh` for the `ref`).

Push the tag right after the release pull request merges: until it exists, the marketplace on the
default branch names a tag that does not, and installing or updating the mod fails. Pushing the
tag `v<version>` runs `.github/workflows/release.yml` on a GitHub-hosted macOS runner, in the
`release` environment, once the owner approves the run: it refuses a tag that does not match
`Info.plist` or the marketplace's `ref`, and fails when a secret below is missing. It builds and
signs the app with the owner's Developer ID (`scripts/build-app.sh --package-app`), has Apple
notarize it and staples the ticket (`scripts/notarize.sh`), does the same for the disk image
built from it (`--package-dmg`), attests the stapled image, and creates the tag's Release with
`LiveBridge.dmg` and its attestation, `LiveBridge.dmg.sigstore.json`, attached. The app's
in-app update verifies that attestation pinned to this workflow, the tag and GitHub-hosted
runners ([SECURITY.md](SECURITY.md#what-an-update-installs)), so a release built any other way
does not install. Without an Apple account, `scripts/build-app.sh --package` still builds the
image from the same source, with the app signed ad hoc, the image unsigned and nothing
notarized.

Approve a release run only when its commit is the release merge on `main`: the approval screen
does not show the workflow, and a `v*` tag on any other commit runs that commit's own
`release.yml` with the Developer ID. A tag ruleset that lets only the owner create `v*` tags
narrows who can start such a run.

On release day, once the Release exists, move the tap's cask
([getLiveBridge/homebrew-tap](https://github.com/getLiveBridge/homebrew-tap)) to the new
version. For the first release after 0.4.2, also drop its caveat that the app is signed ad hoc,
not notarized, and needs **Open Anyway**.

### The release environment (once, by the owner)

The Apple Developer Program's account holder does this; nothing of it is in the repository.

1. **The certificate.** In Xcode, Settings > Accounts > the team > Manage Certificates > + >
   **Developer ID Application**. In Keychain Access, under My Certificates, export
   "Developer ID Application: …" with its private key as a `.p12`, with a strong password.
2. **The notary key.** In App Store Connect, Users and Access > Integrations > App Store
   Connect API > **Team Keys**, generate a key with the Developer role. Download its
   `AuthKey_<id>.p8` (it downloads only once) and note its Key ID and the Issuer ID above the
   list.
3. **The environment.** In the repository's Settings > Environments, create `release`. Under
   Deployment branches and tags choose Selected branches and tags and add the tag rule `v*`;
   tick Required reviewers and add yourself (leave Prevent self-review off).
4. **The secrets**, as environment secrets of `release`, from the folder holding the two files:

   ```sh
   base64 -i developer-id.p12 | gh secret set MACOS_CERTIFICATE --env release --repo getLiveBridge/LiveBridge
   gh secret set MACOS_CERTIFICATE_PASSWORD --env release --repo getLiveBridge/LiveBridge
   base64 -i AuthKey_<id>.p8 | gh secret set NOTARY_KEY --env release --repo getLiveBridge/LiveBridge
   gh secret set NOTARY_KEY_ID --env release --repo getLiveBridge/LiveBridge
   gh secret set NOTARY_ISSUER_ID --env release --repo getLiveBridge/LiveBridge
   ```

   `gh secret set` without a pipe asks for the value, so it stays out of the shell's history.
   Keep the `.p12` and the `.p8` somewhere safe, or delete them; a new certificate or key means
   setting its secrets again.

## Running the app while you work

```sh
scripts/build-app.sh --run                      # debug build, then open it
scripts/build-app.sh --run --fake-mic say.wav   # the WAV plays as the microphone
scripts/build-app.sh --run --call-stats         # the voice's numbers, one CSV per call
CFFIXED_USER_HOME=/tmp/lb scripts/build-app.sh --run   # keep its files out of your home
/usr/bin/log stream --info --predicate 'subsystem == "com.getlivebridge.livebridge"'
```

`claude --plugin-dir plugin` loads the mod from the working tree. The mod follows
`CFFIXED_USER_HOME` to the socket as the app does, so `CFFIXED_USER_HOME=/tmp/lb claude
--plugin-dir plugin` talks to the app started with the same variable.

### Reading `--call-stats`

For when the voice breaks up: was it the network? While a line is open, a debug build started
with `--call-stats` adds a row once a second to a CSV in
`~/Library/Application Support/LiveBridge/debug/call-stats/`, one file per call. Started from a
terminal, it prints the file's path there. It holds the time and numbers from WebKit's
`getStats()` only: no audio, no transcript, no session names, and nothing leaves the Mac. A release
build compiles all of this out; `scripts/tests/release-guards.test.sh` looks for its names.

Only one copy of the app can hold the bridge's socket, and the mod of a joined session reopens
`/Applications/LiveBridge.app` when it cannot reach it. So with an installed copy running, start
the debug build first and then quit the installed copy: the debug build waits up to 10 s for the
socket. The other way round, the installed copy comes back and takes the socket, the call goes
through it, and no file is written.

Note the time of the glitch and find its row. `line` changes when the line reopens, and the
counters restart with it. All columns but `jitter` are running totals, so compare a row with the
one before, and ignore a line's first row, where concealment is only start-up.

- `packetsLost` jumping at that moment points to the network.
- `packetsDiscarded`, `jitter`, or `concealedSamples` minus `silentConcealedSamples` rising without
  loss means audio arrived late or not at all: the network or the server, which these numbers
  cannot separate.
- Clean numbers rule out delivery of the incoming audio. That leaves what the server generated and
  the local audio output (Bluetooth, echo cancellation), which these numbers cannot separate either.

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
