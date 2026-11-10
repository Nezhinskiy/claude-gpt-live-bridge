# Settings tabs and the line's timers: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. One wave, one implementer:
> the tasks share `CallMachine.swift`, `Bridge.swift` and `SettingsView.swift`.

**Goal:** the line's silence, first-word wait and noise cap become settings (0 to 300 s, 0 off,
defaults 20, 5 and 90 s), and the Settings window splits into **Voice** and **General** tabs.

**Architecture:** `CallMachine.Timeouts` holds the three values and their defaults; the machine
keeps one and arms (or cancels) the silence timer from it. `Settings` keeps three flat keys, each
decoded with its default, and gives them as a `Timeouts`. `Bridge` reads them through a closure,
beside `pausesSync`, and hands them to the machine before each event. `SettingsView` becomes a
`TabView` of two forms.

**Tech stack:** Swift 6 / SwiftPM (BridgeCore, Swift Testing), SwiftUI on macOS 14.

**Spec:** `docs/specs/2026-11-10-settings-tabs-and-silence-design.md`.

## Global constraints

- A failing test before each change; one behaviour, one test; tests check behaviour, not wording.
- No wire change, so `Wire.swift`, `wire.ts` and `wire/fixtures/` stay as they are.
- `scripts/check.sh` exits 0 before each commit. Conventional Commits. No Claude attribution.
- Do not run `scripts/smoke.sh`: it spends the owner's realtime minutes.

## Review focus

1. A file without the keys decodes to 20, 5 and 90 s (Task 1).
2. A value of 0 cancels a timer already armed, so a line whose timer was counting does not close
   (Task 2).
3. A change of the setting reaches the next armed timer and leaves the one counting (Task 3).

## Wave A: Tasks 1-5

### Task 1: the settings and their defaults

**Files:** `app/Sources/BridgeCore/Settings.swift`, `app/Sources/BridgeCore/Call/CallMachine.swift`;
test `SettingsTests.swift`.

- [ ] Test: `Settings()` has 20, 5 and 90 s; a file with only `voice` decodes to the same.
- [ ] Add `CallMachine.Timeouts` (`silence`, `firstWord`, `noise`, `range = 0...300`) and three
      `Settings` fields, `silenceSeconds`, `firstWordSeconds`, `noiseSeconds`, decoded with
      `decodeIfPresent ?? default`, and `Settings.timeouts`.

### Task 2: the machine arms from its timeouts

**Files:** `CallMachine.swift`; test `CallMachineTests.swift`.

- [ ] Test: a machine with silence 45 arms 45 s after speech ends; first word 7 arms 7 s on a line a
      result opened; noise 33 arms 33 s while sound goes on; each at 0 gives `cancelSilenceTimer`.
- [ ] `public var timeouts = Timeouts()`; `armSilence()` reads it; a 0 gives
      `.cancelSilenceTimer`. The static constants go; the table's rows read the defaults.

### Task 3: the bridge reads the setting

**Files:** `Bridge.swift`, `app/Sources/LiveBridge/App.swift`; test `BridgeTests.swift`.

- [ ] Test: with silence set to 7, a live line closes 7 s after the owner stops speaking; with it at
      0, it stays open past 300 s.
- [ ] `timeouts: @Sendable () -> CallMachine.Timeouts` (default `{ .init() }`), set on the machine
      before each `handle`; `.cancelSilenceTimer` cancels the armed one. The app passes
      `settings.current.timeouts`.

### Task 4: the window's tabs and fields

**Files:** `SettingsView.swift`, `UpdateSection.swift`, `App.swift`. No test: no rule lives here.

- [ ] `TabView` of **Voice** (Voice, Prompt, Line, Sounds) and **General** (Sync, Notifications,
      General, Updates); a `settingsTab` on the model, set to General by a notice's Install.
- [ ] Three `TextField(value:format:)` with a `Stepper`, clamped to `Timeouts.range`, the warnings
      and the billing caption.

### Task 5: documents

- [ ] README (opening, Billing, Settings), `docs/architecture/overview.md`, the six translations,
      CHANGELOG Unreleased.
