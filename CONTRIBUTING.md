# Contributing

Thanks for helping. Issues and pull requests are welcome; for anything larger than a fix, open
an issue first so we can agree on the shape.

## Layout

| Path | What it is |
|---|---|
| `app/` | The SwiftPM package: `BridgeCore` (pure logic, tested without codex, a microphone or Claude) and `LiveBridge` (the menu bar app and its hidden audio page). |
| `plugin/` | The Claude Code mod `livebridge`. `hooks/register.tsx` is wiring only; the other `hooks/*.ts` modules are pure. |
| `wire/fixtures/` | One JSON file per message between the mod and the app: the shared oracle both sides test against. |
| `scripts/` | `check.sh` (every check CI runs), `build-app.sh` (build, install, uninstall), `smoke.sh` (end to end). |
| `docs/` | [Architecture](docs/architecture/overview.md) and [ADRs](docs/adr/). |

## Checks

```sh
scripts/check.sh
```

It runs `swift format lint --strict`, the Swift build and tests, the shell and audio-page
tests, the mod's type check and unit tests, and, when `claude` is on your `PATH`, `claude plugin
validate` and `claude plugin test`. CI runs the same script on the Xcode 27 macOS runner, where
`claude` is absent. You need Xcode 16 or later with Swift 6 (CI uses Xcode 27.2; before Xcode
26 the popover builds without Liquid Glass) and Node 26; the script installs the mod's one
development dependency, TypeScript, with `npm ci`.

The end-to-end smoke test drives the real codex and opens one or two short realtime voice
sessions on your ChatGPT plan, about a minute of voice:

```sh
scripts/smoke.sh
```

It builds the debug app, plays a WAV made with `say` as the microphone, and stands in for a
Claude Code session with `app/Tests/Smoke/fake-session.mjs`. The voice is a language model, so
a run can fail on its wording; if a check fails, run it again before reading much into it, and
report the rate if it keeps failing.

## Running the app while you work

```sh
scripts/build-app.sh --run                      # debug build, then open it
scripts/build-app.sh --run --fake-mic say.wav   # the WAV plays as the microphone
CFFIXED_USER_HOME=/tmp/lb scripts/build-app.sh --run   # keep its files out of your home
/usr/bin/log stream --info --predicate 'subsystem == "io.github.nezhinskiy.livebridge"'
```

`claude --plugin-dir plugin` loads the mod from the working tree.

## Conventions

- One behaviour, one test, and a failing test before the change that makes it pass.
- No third-party Swift packages in shipped targets and no runtime npm dependencies in the mod.
- Changes to the wire touch `Wire.swift`, `plugin/hooks/wire.ts` and `wire/fixtures` together.
- No personal data anywhere: fixtures use `/Users/example`, `Example session` and
  `00000000-…` ids.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat`, `fix`,
  `docs`, `test`, `build`, `chore`, …), one logical change each.
- Write for a reader who has not seen the code: short sentences, the reason before the detail.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
