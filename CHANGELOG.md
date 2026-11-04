# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The voice can look at the Claude Code session. Ask it about "the chat" or what is in the
  session and, when what it has does not cover that, it is instructed to fetch the session's
  context itself and answer from it: the summary, and Claude's last reply (a turn you typed
  included) with its open question and options. Claude runs no turn for a fetch; a question the
  voice hands off instead goes to Claude as before, as a Claude turn. The reply is sent only for
  that fetch and is not saved. If no context arrives within 60 seconds, the voice says so.

### Changed

- **Load context automatically** is now on by default and means "when a line opens": every line
  the app opens (a Start, a line reopened after silence, the line after a target switch) asks the
  target for its summary, and the line does not wait for it. The band's Start no longer asks for
  it separately. The mod reuses its summary until a turn you typed completes, so a line
  reopened after a voice request costs no new summary.
- The voice's instructions say that "the chat" is the Claude Code session, and that a question
  from a turn you typed waits at the keyboard.
- The in-app update attaches and ejects the release image with `diskutil image attach` and
  `diskutil eject` instead of `hdiutil`, which macOS 27 deprecates. Each run mounts the image at
  a new folder of its own.

### Fixed

- When Claude asks a question during a voice request, the voice also gets what Claude wrote just
  before the question, in the same line after the options, with code blocks and tables removed
  as from a result.

## [0.2.0]

### Added

- LiveBridge updates itself and its Claude Code mod from **Settings > Updates**, the menu bar
  menu or a notification, only when you click **Install**. It shows the running version, checks
  GitHub for a newer release once a day (**Check for updates automatically**, on by default,
  off for a build from source) and announces each release once. Install needs a signed-in
  GitHub CLI: it verifies the image's attestation, pinned to the release workflow, the tag and
  GitHub-hosted runners, checks the app inside, waits for Claude to finish a voice request,
  updates the mod, swaps the app in one step and reopens it. The README's
  [Updating](README.md#updating) says what to expect.
- The menu's Conversation submenu shows each request the voice hands to Claude as a **Task**
  line, between what you said and the voice's reply.

### Changed

- The marketplace pins the mod to the release's tag instead of the default branch, so the mod
  installed is the one that belongs to the app.
- `scripts/build-app.sh --release` marks its build as one from source (`LBSourceBuild`): it does
  not check for updates by itself until you turn that on, and Install asks before replacing it
  with the release image.
- The README's `gh attestation verify` command also pins the release workflow, the tag and
  GitHub-hosted runners.

### Fixed

- A call no longer stays on after its last Claude Code session leaves (`/live off`, the session
  closing, the menu's ×, or no poll for 5 s). It stops as Stop does and says that no session has
  joined; a Start whose only session leaves while it is starting ends the same way, and the
  microphone never turns on.
- A question or permission notice from a turn you typed no longer goes to the voice while a
  voice request waits behind that turn. Only a voice turn that is running routes its question to
  the voice.
- The band above the prompt comes back by itself when the Claude app lost it, and `/live on`
  in a session that has already joined brings it back too.

### Note

- Going back to 0.1.x after this release erases the saved conversations: 0.1.x does not read the
  new Task lines and overwrites the saved file on its next save.

## [0.1.2]

### Fixed

- On macOS 27 the menu's Conversation submenu opened as an empty box. It shows the conversation
  again, scrolled to the newest line.

## [0.1.1]

### Fixed

- A question Claude asks during a voice request (the dialog with options) no longer stops the
  conversation. The voice tells you about it, explains the options in its own words and talks
  them over with you without asking Claude; what you decide, an option or a question back to
  Claude, answers the dialog. You can still answer it at the keyboard.

## [0.1.0]

The first release: **LiveBridge.app**, a macOS menu bar app that keeps a GPT-Live voice line
through `codex app-server`, and **`livebridge`**, the Claude Code mod that joins a session to it
with `/live on`. The [README](README.md) describes what it does and how to install it.
