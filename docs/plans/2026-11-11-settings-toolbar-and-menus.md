# Settings in a toolbar, Quick Settings, Feedback & Support, and a debug mode: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to
> implement this plan. **The wave is the dispatch unit:** one implementer per lettered wave, not one
> per task, and one final review per PR, not per wave. Inside a wave every task keeps its own failing
> test (where it has one), its own verification and its own commit. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** the four-tab toolbar Settings window, the Quick Settings and Feedback & Support submenus,
and a debug mode that records the call's statistics in every build, as the spec describes.

**Architecture:** the window becomes an `NSTabViewController` in the toolbar style hosting one SwiftUI
`Form` per tab. The menu's pure model, `MenuContent`, gains a checkmark item and the two submenus and
takes the settings it shows. The call-statistics recorder leaves `#if DEBUG`; its page script reads
only while the app has switched it on, which follows a new setting.

**Tech Stack:** Swift 6, SwiftUI and AppKit (macOS 14), Swift Testing, JavaScriptCore for the page
script's tests.

**Spec:** [`docs/specs/2026-11-11-settings-toolbar-and-menus-design.md`](../specs/2026-11-11-settings-toolbar-and-menus-design.md)

## Waves

| Wave | Tasks | Branch | Depends on |
|---|---|---|---|
| A | 1 | `feat/settings-toolbar` | `dev` |
| B | 2-3 | `feat/menu-submenus` | `dev` |
| C | 4-5 | `feat/debug-mode` | A and B merged into `dev` |

```
dev ──┬── A (Settings window) ──┐
      └── B (menu submenus) ────┴── C (debug mode)
```

A and B share no import: A touches `SettingsView.swift` and `AppModel.settingsTab`; B touches
`MenuContent`, `StatusMenu` and new `AppModel` methods. Both add to the README, `CHANGELOG.md` and the
translations; the second to merge resolves that conflict by keeping both. C's Task 5 edits A's General
tab and B's Feedback & Support submenu, so it starts from `dev` with both merged.

## Global Constraints

- No third-party Swift packages; no new runtime npm dependency.
- One behaviour, one test; a failing test before the change that makes it pass. A SwiftUI or AppKit
  layout with no testable seam is verified by `scripts/build-app.sh --run` and a screenshot, said so
  in the PR.
- Settings' controls, captions and warnings move as they are; nothing is reworded (spec).
- LiveBridge never answers a Claude Code permission prompt; nothing here touches the mod or the wire.
- Fixtures and tests use `/Users/example`-style data only.
- Docs change in the same PR as the code: the README's sections, `CHANGELOG.md`'s Unreleased section,
  and the same sections of every `docs/i18n/README.*.md`.
- Conventional Commits; no AI attribution anywhere.
- `scripts/check.sh` exits 0 before the PR.

## Review Focus

1. **Connect over TCP from Quick Settings during a call:** the confirmation alert must appear after the
   menu closes (a modal from inside menu tracking hangs or is lost), and Cancel must leave the item
   unchecked. Task 3 routes it through `StatusMenu.later`.
2. **Settings and Quick Settings drifting apart:** a switch changed in one must show at once in the
   other, both ways. Task 2 builds the items from the `Settings` value given; Task 3 reads
   `model.settings.current` inside the observed `content()`.
3. **A settings file from 0.5.0** (no `debugMode` key) must load with debug mode off and every other
   value kept. Task 4's decoding test.
4. **The audio page reloading** (its web content process can be killed): the statistics switch must
   follow the setting again after the reload, or a reload silently stops or starts recording. Task 5
   applies it in `didFinish`.
5. **Debug mode turned off mid-call** must close the file at once and write nothing more, even for a
   sample already in flight. Task 4's script test and Task 5's `endCall` on the off switch.

## Wave A — Task 1

### Task 1: Settings window with four tabs in a toolbar

**Files:**
- Modify: `app/Sources/LiveBridge/SettingsView.swift`, `app/Sources/LiveBridge/App.swift`
  (`settingsTab`'s default)
- Docs: `README.md` (§ Settings), `CHANGELOG.md`, `docs/i18n/README.*.md` (§ Settings)

**Interfaces:**
- Produces: `enum SettingsTab: CaseIterable { case general, voice, line, context }`;
  `SettingsView(model: AppModel, tab: SettingsTab)`, whose body is that tab's `Form`; Wave C adds a
  Debug section to the General form.

- [ ] **Step 1:** Split today's two forms into four, per the spec's table: **General** = Notifications,
  Login, Updates; **Voice** = Voice, Prompt, Sounds; **Line** = today's Line section (three timers and
  Connect over TCP, with the `cancelledReconnects` redraw); **Context** = today's Sync section's two
  toggles. Each tab is a `Form` with `.formStyle(.grouped)`. `listVoices()` runs on Voice's appear;
  the notification-status refresh (`.task` and `didBecomeActive`) on General's.
- [ ] **Step 2:** `SettingsWindow` hosts an `NSTabViewController` with `tabStyle = .toolbar`, one
  `NSTabViewItem` per `SettingsTab.allCases` with label `General`, `Voice`, `Line`, `Context` and
  image `NSImage(systemSymbolName:)` of `gearshape`, `waveform`,
  `antenna.radiowaves.left.and.right`, `text.bubble`. The window title stays `LiveBridge Settings`
  (the tab controller would otherwise set it to the tab's label). Each tab's
  `NSHostingController` sizes the window to its form (`sizingOptions = .preferredContentSize`), width
  480.
- [ ] **Step 3:** Selection follows `AppModel.settingsTab` both ways: `show()` selects it; the tab
  controller's selection writes it. `settingsTab` defaults to `.general`; the existing
  `settingsTab = .general` before an install stays.
- [ ] **Step 4:** Verify: `scripts/build-app.sh --run`; open Settings; each tab shows its sections;
  the window's height follows the tab; Tab and arrows move between tabs with Full Keyboard Access;
  VoiceOver reads each tab's name; a notice's Install opens on General. Screenshot each tab for the PR.
- [ ] **Step 5:** Docs: § Settings says four tabs and lists each tab's settings under it (move the
  existing bullets, do not reword them; Connect over TCP and the timers go under **Line**, Pause sync
  and Load context under **Context**). CHANGELOG: replace the Unreleased "two tabs" bullet with the
  four tabs. Same in each translation.
- [ ] **Step 6:** `scripts/check.sh` exits 0; commit `feat(app): put Settings' four tabs in a toolbar`.

## Wave B — Tasks 2-3

### Task 2: the menu model's submenus and switches

**Files:**
- Modify: `app/Sources/BridgeCore/Menu/MenuContent.swift`, `app/Sources/BridgeCore/Update/Release.swift`
- Test: `app/Tests/BridgeCoreTests/MenuTests.swift`

**Interfaces:**
- Produces:
  - `MenuContent.Switch: CaseIterable` with cases in menu order `connectsOverTCP, confirmHandoffs,
    notifyResults, pauseSyncWhileStopped, loadContextOnFirstCall`, and `var title: String`:
    `Connect over TCP`, `Play sounds for requests and answers`, `Notify when a result is waiting`,
    `Pause sync while the call is stopped`, `Load a session's context on its first call`;
    `func isOn(in settings: Settings) -> Bool`.
  - `MenuContent.Item.toggle(Switch, isOn: Bool)`.
  - `Command` gains `reportBug` and `website` (no key equivalent).
  - `Release.bugReportForm` = `<repositoryPage>/issues/new?template=bug_report.yml`;
    `Release.website` = `https://getlivebridge.com`.
  - `MenuContent.init(settings: Settings, update:…)`: `settings` is the first parameter, required.

- [ ] **Step 1: Failing tests** in `MenuTests.swift`:
  - `theFootIsQuickSettingsSettingsFeedbackAndQuit`: with a bridge and no update, the items after the
    limits are, in order: `submenu("Quick Settings")`, `command(.settings, "Settings…")`, `separator`,
    `submenu("Feedback & Support")`, `separator`, `command(.quit, "Quit LiveBridge")`; and no
    `command(.starOnGitHub)` outside the submenu. With an update, its install item comes first.
  - `quickSettingsShowEachSwitchAsSet`: with `Settings(pauseSyncWhileStopped: true, connectsOverTCP:
    true)`, the Quick Settings items are the five toggles in `Switch.allCases` order with `isOn`
    `[true, true, true, true, true]`; with `Settings()`, `[false, true, true, false, true]`.
  - `feedbackAndSupportHoldsTheLinks`: its items are `command(.reportBug, "Report a Bug…")`,
    `command(.website, "LiveBridge Website")`, `command(.starOnGitHub, "Star LiveBridge on GitHub")`.
  - `withoutABridgeQuickSettingsAreStillThere`: the bridgeless menu's foot holds the same Quick
    Settings submenu.
  - `theBugFormIsTheBugTemplate` in `ReleaseTests.swift`: `Release.bugReportForm.absoluteString ==
    "https://github.com/getLiveBridge/LiveBridge/issues/new?template=bug_report.yml"`.
  Update existing tests that build `MenuContent` to pass `settings: Settings()`, and
  `withoutABridgeOnlyTheProblemAndTheFooterAreLeft` to the new foot.
- [ ] **Step 2:** Run `cd app && swift test --filter MenuTests` (and `ReleaseTests`): the new tests fail.
- [ ] **Step 3:** Implement the interfaces above; the foot is built once and used by both the bridged
  and the bridgeless menu.
- [ ] **Step 4:** The same filtered runs pass.
- [ ] **Step 5:** Commit `feat: give the menu model Quick Settings and Feedback & Support`.

### Task 3: render the submenus and wire the switches

**Files:**
- Modify: `app/Sources/LiveBridge/StatusMenu.swift`, `app/Sources/LiveBridge/App.swift`
- Docs: `README.md` (§ The band and the menu, § Settings' opening paragraph), `CHANGELOG.md`,
  `docs/i18n/README.*.md`

**Interfaces:**
- Consumes: Task 2's `Switch`, `Item.toggle`, `Command.reportBug`, `Command.website`,
  `Release.bugReportForm`, `Release.website`.
- Produces: `AppModel.set(_ switch: MenuContent.Switch, on: Bool)`.

- [ ] **Step 1:** `StatusMenu.content()` passes `settings: model.settings.current`. `fill` renders
  `.toggle` as a native item keyed `toggle|<switch>`, title `switch.title`, `state` `.on`/`.off`, action
  `toggle(_:)` with the switch as `representedObject`. A submenu that holds a toggle shows its state
  column (`showsStateColumn = true`); the rest keep it hidden as today.
- [ ] **Step 2:** `toggle(_:)` calls `later { model.set(switch, on: !wasOn) }`, so Connect over TCP's
  confirmation opens after the menu has closed. `AppModel.set` routes `connectsOverTCP` to
  `setConnectsOverTCP`, `notifyResults` to `setNotifyResults`, the rest to `settings.update`.
- [ ] **Step 3:** `reportBug` opens `Release.bugReportForm`, `website` opens `Release.website`.
- [ ] **Step 4:** Verify: `scripts/build-app.sh --run`; each Quick Settings item flips its Settings
  switch and the reverse, with Settings open beside the menu; Connect over TCP during a call asks,
  Cancel leaves it unchecked, OK reconnects; the three links open their pages. Screenshot both submenus
  for the PR.
- [ ] **Step 5:** Docs: the menu bullet lists the new foot (Quick Settings with its five switches,
  Settings…, Feedback & Support with its three items, Quit) in place of the root Star item; § Settings
  says the five switches are also in Quick Settings. CHANGELOG Unreleased, Added: the two submenus;
  Changed: Star moved into Feedback & Support. Same in each translation.
- [ ] **Step 6:** `scripts/check.sh` exits 0; commit `feat(app): show Quick Settings and Feedback &
  Support in the menu`.

## Wave C — Tasks 4-5

### Task 4: the setting, the switchable page script, and the release guard

**Files:**
- Modify: `app/Sources/BridgeCore/Settings.swift`, `app/Sources/BridgeCore/Audio/CallStats.swift`,
  `scripts/tests/release-guards.test.sh`
- Test: `app/Tests/BridgeCoreTests/SettingsTests.swift`, `app/Tests/BridgeCoreTests/CallStatsTests.swift`

**Interfaces:**
- Produces: `Settings.debugMode: Bool` (default `false`, `init(… debugMode: Bool = false)`);
  `CallStats.switchScript(on: Bool) -> String`, the JavaScript the app evaluates to turn the reading on
  or off; `CallStats`, `CallStatsLog` and `CallStats.pageScript` in every build.

- [ ] **Step 1: Failing tests:**
  - `SettingsTests.debugModeIsOffInAFileFromBeforeIt`: decoding today's fixture JSON without
    `debugMode` gives `debugMode == false` and keeps the other values; `debugModeRoundTrips`: encode
    `Settings(debugMode: true)` and decode it equal.
  - In the page-script suite (`CallStatsTests.swift`, fake timers): `nothingIsReadUntilSwitchedOn` —
    after `pageScript`, a fake peer, and running the timers, no message is posted;
    `switchedOnItReadsOnceASecond` — after `switchScript(on: true)`, running the timer posts one sample;
    `switchedOffItStopsAtOnce` — on, run, then `switchScript(on: false)`, run again: no new sample,
    including for a `getStats()` that resolves after the switch.
- [ ] **Step 2:** `cd app && swift test --filter "SettingsTests|CallStats"`: the new tests fail.
- [ ] **Step 3:** Add `debugMode` (decoded with `decodeIfPresent … ?? false`). In `CallStats`, remove
  `#if DEBUG` and the header comment's "debug builds only" reason; the page script keeps a flag, off
  until `switchScript(on: true)`, checked before `getStats()` and again before posting.
- [ ] **Step 4:** The filtered runs pass.
- [ ] **Step 5:** `release-guards.test.sh`: remove the `getStats packetsLost callStats` loop and its
  sentence in the header comment; the `LIVEBRIDGE_RELEASES_URL` and marketplace guards stay. Run it:
  exit 0. Commit message body says why: the README's promise is that nothing leaves the Mac, and debug
  mode writes a local file, off by default, which `debugModeIsOffInAFileFromBeforeIt` and the script
  tests now guard.
- [ ] **Step 6:** Commit `feat: let every build record the call's statistics, switched by a setting`.

### Task 5: the recorder follows the setting; General's Debug section and the menu's items

**Files:**
- Modify: `app/Sources/LiveBridge/CallStatsRecorder.swift`, `app/Sources/LiveBridge/AudioHost.swift`,
  `app/Sources/LiveBridge/App.swift`, `app/Sources/LiveBridge/SettingsView.swift`,
  `app/Sources/LiveBridge/StatusMenu.swift`, `app/Sources/BridgeCore/Menu/MenuContent.swift`,
  `scripts/build-app.sh` (usage text), `.github/ISSUE_TEMPLATE/bug_report.yml`
- Test: `app/Tests/BridgeCoreTests/MenuTests.swift`
- Docs: `README.md` (§ Settings General, § Privacy, the `--call-stats` mention in § Known
  limitations), `CONTRIBUTING.md` (§ Running the app, § Reading `--call-stats`), `CHANGELOG.md`,
  `docs/i18n/README.*.md`

**Interfaces:**
- Consumes: Task 4's `Settings.debugMode`, `CallStats.switchScript(on:)`; Wave B's Feedback & Support
  and `Item.toggle`; Wave A's General form.
- Produces: `MenuContent.Switch.debugMode` (title `Debug Mode`, not in Quick Settings);
  `Command.showDebugFiles` (title `Show Debug Files…`); `AppModel.setDebugMode(_ on: Bool)`;
  `AppModel.showDebugFiles()`.

- [ ] **Step 1: Failing test** `feedbackAndSupportEndsWithDebugMode`: the submenu's items are the
  three links, `separator`, `toggle(.debugMode, isOn:)` following `settings.debugMode`, and
  `command(.showDebugFiles, "Show Debug Files…")`; Quick Settings still holds only its five.
  `swift test --filter MenuTests` fails, then implement, then passes.
- [ ] **Step 2:** `CallStatsRecorder` leaves `#if DEBUG` and no longer reads `--call-stats`: it is
  installed in every build and owns `set(on:)`, which evaluates `CallStats.switchScript(on:)` in the
  page and, when off, calls `endCall()`. `AudioHost` applies the current value in `didFinish` and when
  `AppModel.setDebugMode` changes it; `stopListening` still ends the file. Remove `--call-stats`
  from `build-app.sh`'s usage and from `debug()`'s terminal handling.
- [ ] **Step 3:** General gets a **Debug** section: `Toggle("Debug mode")`, the caption "Records the
  voice's network numbers once a second during a call, one CSV per call, in LiveBridge's data folder
  under debug/call-stats. No audio, no transcript, no session names; nothing leaves this Mac.", and a
  **Show Debug Files** button. `showDebugFiles()` makes the folder (`CallStats.directory()`) and opens
  it in the Finder. The menu's `debugMode` toggle routes through `AppModel.set` to `setDebugMode`.
- [ ] **Step 4:** Verify on a release build (`scripts/build-app.sh --package`, run from
  `dist/LiveBridge.app`): debug mode off by default; on, a call writes a CSV, Show Debug Files opens
  it; turned off mid-call, the file stops growing; on mid-call, the open line starts a file. Paste the
  CSV's first rows (numbers only) in the PR.
- [ ] **Step 5:** Docs: README § Settings, General: the Debug bullet (what, where, off by default);
  § Privacy: one sentence that debug mode, off by default, writes the voice's network numbers to a
  local file and nothing more; § Known limitations: "A debug build's `--call-stats`" becomes "Debug
  mode". CONTRIBUTING: the `--call-stats` command line goes; § Reading `--call-stats` becomes
  § Reading debug mode's numbers, opening with how to turn it on. `bug_report.yml`: ask, for a voice
  that breaks up, for the CSV from Show Debug Files. CHANGELOG Unreleased, Added: debug mode; Changed:
  `--call-stats` replaced by it, and amend the existing "`--call-stats` records … `onTcp`" bullet.
  Same in each translation.
- [ ] **Step 6:** `scripts/check.sh` exits 0; commit `feat(app): turn debug mode on from Settings or
  the menu`.

## Execution contract

- **Implementer briefs** carry: report a mismatch between this plan and the tree instead of guessing;
  run each verification and paste its output; focused `swift test --filter` while iterating, one
  `scripts/check.sh` before the commit; no line numbers taken from this plan; write nothing outside the
  wave's worktree but its own scratch folder under the session scratchpad; never kill by a name
  pattern; no AI attribution.
- **Parallelism:** A and B run at once, each in its own worktree from `origin/dev`. C starts only after
  both PRs merge. One `scripts/check.sh` at a time per worktree.
- **Review:** one final review per PR (correctness, and what can be deleted), findings without
  replacement text, then one scoped re-review. The owner approves the screenshots before merge.
- **Verification:** the controller re-runs `scripts/check.sh` only on a head it pushes, and waits for
  CI before reporting.
