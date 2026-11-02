# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

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
