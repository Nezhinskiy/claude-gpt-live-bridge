# Settings in a toolbar, Quick Settings, Feedback & Support, and a debug mode

Status: approved, 2026-11-11; the plan is
[`plans/2026-11-11-settings-toolbar-and-menus.md`](../plans/2026-11-11-settings-toolbar-and-menus.md).

## Why

After a real call on the 0.5.0 test build the owner asked for three things, by the example of
Amphetamine's menu and Settings window:

- **The Settings window** looks like a Mac app's own: a toolbar of tabs, each an icon above its
  name, and more than two of them where the settings fall into natural groups. Today it is SwiftUI's
  `TabView` with two segmented tabs, Voice and General
  ([settings tabs design](2026-11-10-settings-tabs-and-silence-design.md)).
- **The menu** gets two submenus: **Quick Settings**, the switches worth reaching during a call
  without opening Settings, and **Feedback & Support**, which gathers the links (the GitHub star,
  the project) and the debug mode.
- **A debug mode**, off by default, that a release build can turn on: today `--call-stats` exists in
  debug builds only, started from a terminal.

The owner's words: "то, что у нас сейчас есть, выпустить как дебаг мод, отдельно включаемый, по
дефолту, естественно, выключенный". What exists today is the call's statistics; no build records
audio, and the app's log (`os_log`, subsystem `com.getlivebridge.livebridge`) is already written in
every build. Recording the call's audio is not part of this design (below).

## What the owner sees

### The Settings window: four tabs in a toolbar

The window's toolbar holds four tabs, each an SF Symbol above its name; the one shown is selected,
as in Amphetamine and in macOS's own apps. The window keeps the title **LiveBridge Settings** and
takes the height of the tab shown.

| Tab | Symbol | Sections |
|---|---|---|
| **General** | `gearshape` | Notifications: **Notify when a result is waiting**; Login: **Open at login**; Updates; Debug (below) |
| **Voice** | `waveform` | Voice; Prompt; Sounds: **Play sounds for requests and answers** |
| **Line** | `antenna.radiowaves.left.and.right` | the three timers; **Connect over TCP** |
| **Context** | `text.bubble` | **Pause sync while the call is stopped**; **Load a session's context on its first call** |

- Every control, its caption and its warning moves as it is; nothing is reworded. Today's **Line**
  section of Voice becomes the **Line** tab, and today's Sync section of General becomes the
  **Context** tab, where the summary model of the
  [summary model design](2026-11-09-summary-model-design.md) will join it.
- The window first opens on **General**, then on the tab last shown. A notice's **Install** opens
  it on **General**, where the update is, as today.
- The tabs take the keyboard (Full Keyboard Access) and VoiceOver reads each by its name, as the
  segmented tabs do today.

### Quick Settings

A submenu of the menu, **Quick Settings**, holds five switches, each a checkmark item. Each is the
setting of the same name in Settings, not a copy: changing one shows in the other at once.

1. **Connect over TCP**: with a line connecting or open, it asks to reconnect, as the switch in
   Settings does; cancelled, nothing changes.
2. **Play sounds for requests and answers**
3. **Notify when a result is waiting**: turned on, macOS asks for permission if it never was, as
   in Settings. If notifications are refused, the item stays checked as the setting does, and
   Settings says why nothing shows.
4. **Pause sync while the call is stopped**
5. **Load a session's context on its first call**

The call card's **Mute** and **Unmute** stay where they are; Quick Settings does not repeat them.
The timers, the voice and the prompt are values, not switches, and stay in Settings.

### Feedback & Support

A second submenu, **Feedback & Support**, holds:

- **Report a Bug…**: opens the repository's bug report form,
  `https://github.com/getLiveBridge/LiveBridge/issues/new?template=bug_report.yml`.
- **LiveBridge Website**: opens `https://getlivebridge.com`.
- **Star LiveBridge on GitHub**: opens the repository's page, as the root item does today. GitHub
  has no link that stars a repository, so this and a "project on GitHub" item would open the same
  page; the website is the project's other link.
- a separator, then **Debug Mode** (a checkmark item, the setting below) and **Show Debug
  Files…**.

### The menu's foot

The root item **Star LiveBridge on GitHub** moves into Feedback & Support. The foot becomes, as in
Amphetamine:

```
Install LiveBridge <version>…   (only when a release waits)
Quick Settings              ▸
Settings…                  ⌘,
───────────────
Feedback & Support          ▸
───────────────
Quit LiveBridge            ⌘Q
```

Before the bridge is up (the menu with only the call card), Quick Settings is there too: the
settings are the app's, not the bridge's.

### Debug mode

A setting, **Debug mode**, off by default and kept across launches like every other. It sits in
two places that are one setting: General's **Debug** section, a switch with a caption and a **Show
Debug Files** button, and Feedback & Support's **Debug Mode** item.

- **On**, every line that opens records the call's statistics, as `--call-stats` does today: a row
  a second of the numbers WebKit's `getStats()` gives for the incoming voice (packets lost and
  discarded, jitter, concealed samples, whether the line runs over TCP), one CSV per call, in
  `~/Library/Application Support/LiveBridge/debug/call-stats/`. Nothing else: no audio, no
  transcript, no session names. Turned on during a call, it records the open line from that moment.
- **Off**, nothing is recorded, and a line recording stops at once. Files already written stay
  until the owner deletes them.
- **Show Debug Files** opens that folder in the Finder, creating it if it is missing.
- The caption says what is written, where, and that nothing leaves the Mac; the bug report form
  asks for these files when a voice breaks up.
- `--call-stats` is gone: the setting replaces it in debug builds too, so there is one way to turn
  it on. CONTRIBUTING's section on reading the numbers points to the setting.

## What changes underneath

- **The window.** `SettingsWindow` hosts an `NSTabViewController` with the `.toolbar` tab style, one
  `NSHostingController` per tab, each a `Form` cut from today's `SettingsView`. `AppModel.settingsTab`
  gains the two new cases and keeps the tab last shown.
- **The menu's model.** `MenuContent` gains a checkmark item, `toggle(Switch, title:, isOn:)`, and its
  initialiser takes the settings it shows. Today's `starOnGitHub` command moves into the new
  submenu, and three commands join it (`reportBug`, `website`, `showDebugFiles`). `MenuContent`
  stays pure and is tested as today.
- **The switches.** Each Quick Settings item calls the setter its Settings control calls
  (`setConnectsOverTCP`, `setNotifyResults`, `settings.update`), so the confirmation, the permission
  request and the reconnect stay in one place.
- **The recorder.** `CallStatsRecorder`, `CallStats` and the page's statistics script leave
  `#if DEBUG`. The page script is installed in every build, and its once-a-second reading does
  nothing until the app switches it on; the app switches it to the setting when the page loads and
  whenever the setting changes, and turning it off also closes the file.
- **The release guard.** `scripts/tests/release-guards.test.sh` looks for `getStats`, `packetsLost`
  and `callStats` in the release binary and its audio page, because "`--call-stats` exists in debug
  builds only, because the README promises no telemetry". The promise is about data leaving the Mac,
  which debug mode does not do, so that check goes, with the reason in the commit. Its guard is
  replaced by a test that a fresh settings store has debug mode off and that no file is written while
  it is off. The `LIVEBRIDGE_RELEASES_URL` guard stays.

## Documents

In the same change as the code, each where its fact lives: the README's [Settings](../../README.md#settings)
and menu sections and its [Privacy](../../README.md#privacy) section (debug mode writes local files,
off by default); CONTRIBUTING's call-stats section; the bug report form's request for the files;
`CHANGELOG.md`'s Unreleased section; the README's translations under `docs/i18n/`, in the same
sections.

## Not in this design

- **Recording the call's audio.** No build records the microphone or the voice today. Writing the
  conversation to disk is a privacy decision of its own (format, retention, what the README and
  SECURITY.md promise); it gets its own design if the statistics prove not enough.
- **A cap or an expiry for debug files.** A one-hour call writes about 3,600 rows, a few hundred
  kilobytes. Show Debug Files is the way to clear them.
- **The working glyph's three dots.** The menu bar glyph and the session row show turning arrows while
  Claude works; the [summary model design](2026-11-09-summary-model-design.md) gives `working`
  three dots and keeps the ring for a context load. That part ships on its own, ahead of this design.

## Testing

- `MenuContent`: the foot's order; Quick Settings' five items reflect the settings given; Feedback &
  Support's items and their commands; Quick Settings present before the bridge is up.
- `Settings`: debug mode decodes as off from a store written before it existed, and round-trips.
- `CallStatsLog` as today; the recorder writes nothing while the setting is off, and stops writing
  when it is turned off mid-call.
- The release guard without the statistics check still fails on `LIVEBRIDGE_RELEASES_URL`.
- By hand, on a release build from `scripts/build-app.sh --package`: the four tabs with the keyboard
  and VoiceOver; each Quick Settings item against its Settings switch, both ways; Connect over TCP
  from the menu during a call; Debug Mode on, a call, the file in Show Debug Files; off, no new file.
