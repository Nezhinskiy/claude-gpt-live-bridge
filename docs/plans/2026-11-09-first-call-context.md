# First-call context: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. One wave, one implementer: the tasks share `Bridge.swift` and its tests.

**Goal:** a line that opens for a session with no summary asks for one despite the pause, under a
new setting on by default, migrated off for owners with the pause on.

**Architecture:** one new field in `Settings`, read by `Bridge` through a closure beside
`pausesSync`. One private rule in `Bridge` says whether the pause holds the next line's summary
back; `openLine` and `contextNeed` both use it, so the menu cannot disagree with the line.

**Tech stack:** Swift 6 / SwiftPM (BridgeCore, Swift Testing).

**Spec:** `docs/specs/2026-11-09-first-call-context-design.md`.

## Global constraints

- A failing test before each change; one behaviour, one test; tests check behaviour, not wording.
- No wire change, so `Wire.swift`, `wire.ts` and `wire/fixtures/` stay as they are.
- `scripts/check.sh` exits 0 before each commit. Conventional Commits. No Claude attribution.
- Do not run `scripts/smoke.sh`: it spends the owner's realtime minutes.

## Review focus

Each has a test in the task named.

1. A summary asked for on the first line, then a Stop and paused typing before it lands: it was
   written across a refused turn, so it is ignored (the existing stale ask, Task 2).
2. After the first summary lands, paused typing then a line: no ask, and the menu offers the press
   (Task 2, Task 3).
3. A pause mark kept across **New conversation**: the next line asks (Task 2).
4. A line for a new target, under the pause, with no summary: it asks for that target (Task 2).
5. A file with `pauseSyncWhileStopped: false` and an old `autoContext: false`: the explicit value
   wins, so the new setting is on (Task 1).

## Wave A: Tasks 1-4

### Task 1: the setting and its migration

**Files:** modify `app/Sources/BridgeCore/Settings.swift`; test `SettingsTests.swift`.

**Produces:** `Settings.loadContextOnFirstCall: Bool`, default `true`.

- [ ] Tests, each failing to compile first: defaults on; a file with no key and no pause gets
  `true`; a file with the pause on gets `false`; a file with `autoContext: false` gets `false`; a
  file with `autoContext: false, pauseSyncWhileStopped: false` gets `true`; a saved value wins over
  the migration; a change is kept across a restart.
- [ ] In `init(from:)`: `decodeIfPresent(...) ?? !pauseSyncWhileStopped`, after the pause is decoded.
- [ ] `swift test --filter SettingsStoreTests`; `check.sh`; commit `feat(settings): ...`.

### Task 2: the line asks

**Files:** modify `Bridge.swift`, `App.swift`; test `BridgeTests.swift`.

**Consumes:** `Settings.loadContextOnFirstCall`.
**Produces:** `Bridge.init(loadsContextOnFirstCall: @escaping @Sendable () -> Bool = { true })`, and
`private func pauseHoldsBackSummary(of id: SessionID) -> Bool`:
false when the setting is on and `continuity[id].context == nil`; otherwise
`pausesSync() || continuity[id].outOfSync == .paused`.

- [ ] `BridgeTests.init(loadsContextOnFirstCall: Bool = false)`: the setting off is today's behaviour,
  so the rest of the suite pins it.
- [ ] Failing tests: first line under the pause asks; a *paused* session with no summary asks; with
  a summary and paused, no ask; setting off, no ask; a missed session with no summary asks;
  after the first summary the pause works as before; a stale first summary is ignored; New
  conversation with a mark asks; a new target asks; a reopened line with no summary asks again.
- [ ] `openLine`: `if let session, !pauseHoldsBackSummary(of: session), await needsContext(session)`.
- [ ] `App.swift`: pass `{ settings.current.loadContextOnFirstCall }`.
- [ ] `swift test --filter BridgeTests`; `check.sh`; commit `feat(bridge): ...`.

### Task 3: the menu says so

**Files:** modify `Bridge.swift`, `Menu/ContextLoads.swift` (the doc comment); test `BridgeTests.swift`.

- [ ] Failing tests with the setting on: pause on, no summary: `.withTheLine`; *paused* with no
  summary: `.withTheLine`; *paused* with a summary: `.load`; a missed session with no summary:
  `.load`. Existing tests pin the setting off.
- [ ] `contextNeed`: a gap is `outOfSync == .missed || isOverSeed`; `.withTheLine` when there is no
  gap, the mod syncs, there is no summary and `!pauseHoldsBackSummary(of: id)`.
- [ ] `swift test --filter BridgeTests`; `check.sh`; commit `feat(menu): ...`.

### Task 4: the toggle and the documents

**Files:** modify `SettingsView.swift`, `SECURITY.md`, `README.md`, `docs/i18n/README.*.md`,
`docs/architecture/overview.md`, `CHANGELOG.md`.

- [ ] Toggle in Sync, with its caption; the pause's caption depends on the setting, because "only
  from the menu" is true only with it off, or after the first summary.
- [ ] Documents say what the spec's "What the owner sees" and "What it costs" say, each fact in its
  home. `docs/specs/2026-11-05-conversation-sync-design.md` is not edited.
- [ ] `stayfixed docs trail --check`; `check.sh`; commit `docs: ...`.
