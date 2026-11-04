# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- LiveBridge updates itself and its Claude Code mod from **Settings > Updates**, the menu bar
  menu or a notification, only when you click **Install**. It shows the running version, checks
  GitHub for a newer release once a day (**Check for updates automatically**, on by default,
  off for a build from source) and announces each release once. Install needs a signed-in
  GitHub CLI: it verifies the image's attestation, pinned to the release workflow, the tag and
  GitHub-hosted runners, checks the app inside, waits for Claude to finish a voice request,
  updates the mod, swaps the app in one step and reopens it. The README's
  [Updating](README.md#updating) says what to expect.

### Changed

- The marketplace pins the mod to the release's tag instead of the default branch, so the mod
  installed is the one that belongs to the app.
- `scripts/build-app.sh --release` marks its build as one from source (`LBSourceBuild`): it does
  not check for updates by itself until you turn that on, and Install asks before replacing it
  with the release image.
- The README's `gh attestation verify` command also pins the release workflow, the tag and
  GitHub-hosted runners.

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
