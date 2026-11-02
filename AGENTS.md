# LiveBridge

LiveBridge lets you talk to an open Claude Code session by voice. It has two halves: a macOS
menu bar app (Swift, `app/`) that runs a GPT-Live voice line through `codex app-server`, and a
Claude Code mod, `livebridge` (TypeScript, `plugin/`), that joins a session to the app with
`/live on` and turns the voice's handoffs into prompts. They talk HTTP over a Unix socket. This
file is loaded into every agent session, so it stays short (at most 300 lines and 3,000 words,
the status section at most 50 lines); detail lives in the documents it links to.

## Layout

- `app/`: the SwiftPM package. `BridgeCore` holds every rule and is tested without codex, a
  microphone or Claude; `LiveBridge` is the menu bar app and its hidden audio page.
- `plugin/`: the mod. `hooks/register.tsx` is the wiring; the other `hooks/*.ts` modules are pure.
- `wire/fixtures/`: one JSON example of every message between the mod and the app.
- `scripts/`: `check.sh`, `smoke.sh`, `build-app.sh`.
- `docs/`: the [architecture](docs/architecture/overview.md), [ADRs](docs/adr/), and the
  stayfixed scaffold ([CONTRIBUTING.md](CONTRIBUTING.md#stayfixed) says what each file is for).

## Build and test

- `scripts/check.sh` runs every check CI runs and must exit 0 before a commit. Without `claude`
  on `PATH` it skips the mod's engine-facing half and says so; CI does not skip it.
- `scripts/smoke.sh` drives the real codex end to end and spends about a minute of realtime voice
  on your ChatGPT plan, so run it for changes to the voice path, not for every change.
  The voice is a language model, so one failed run is not proof of a regression.
- `scripts/build-app.sh --run` builds and opens the debug app; `claude --plugin-dir plugin`
  loads the mod from the working tree. The toolchain is in
  [CONTRIBUTING.md](CONTRIBUTING.md#toolchain).

## Rules

- A failing test before the change that makes it pass; one behaviour, one test. Tests check
  behaviour, not the wording of prompts.
- No third-party Swift packages in shipped targets and no runtime npm dependencies in the mod.
- A wire change touches `Wire.swift`, `plugin/hooks/wire.ts` and `wire/fixtures/` together.
- LiveBridge never answers a Claude Code permission prompt; that prompt is the one control
  against unwanted actions ([SECURITY.md](SECURITY.md)). Docs never claim more than the code
  enforces, and a model instruction is not a control.
- No personal data: fixtures use `/Users/example`, `Example session` and `00000000-…` ids.
- One fact, one home ([documentation policy](docs/architecture/documentation.md)): link to it
  instead of copying it, and fix the docs in the same change as the code.
- Conventional Commits, one logical change each.

## Current status

- 0.1.0, the first release, is being prepared. Its open items are the README's
  [known limitations](README.md#known-limitations).
<!-- stayfixed:harness:begin -->
## stayfixed

This repository is initialised with stayfixed. `stayfixed.toml` names its document paths and
its note store. `docs/bug-reports.md` is a generated index over `docs/bugs/` — never edit it by hand;
`stayfixed bugs index` renders it. `docs/roadmap.md` carries the design-and-plan trail between its
markers, which `stayfixed docs trail` rewrites; specs live under `docs/specs/` and plans under
`docs/plans/`. Each gate runs advisory until it enforces: `stayfixed adopt promote` enforces the
gates that pass, and `stayfixed assess` says which would.
<!-- stayfixed:harness:end -->
