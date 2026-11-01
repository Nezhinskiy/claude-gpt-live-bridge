# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [0.1.0]

The first release.

### Added

- **LiveBridge.app**, a macOS menu bar app that runs a GPT-Live voice line through
  `codex app-server` on your ChatGPT login: a menu bar glyph that shows the call, and a popover
  with Start and Stop, the joined sessions, the voice target, the recent conversation, the
  context that was sent, New conversation, Open at login and the minutes used.
- **The `livebridge` Claude Code mod**: `/voicemod on|off|target|status|context`, a band above
  the prompt, voice requests submitted as prompts to the session's own model, and answers,
  questions, later updates and approval notices posted back to the voice.
- A billing-aware call: local voice detection with a 2-second pre-roll opens the realtime
  session only while someone speaks, it closes after 20 seconds of silence or after a handoff is
  acknowledged, and results that arrive while it is closed chime and wait for the next speech.
- A read-only, tool-less codex voice thread with every MCP server disabled, checked before each
  session.
- `scripts/build-app.sh` with `--release`, `--make-signing-identity` and `--uninstall`, CI on
  the Xcode 27 macOS runner, and an end-to-end smoke test.
