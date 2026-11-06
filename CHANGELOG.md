# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Conversation sync.** What you type in a joined session and Claude's final answer to it now
  go into that session's conversation with the voice, as context: an open line gets them at once,
  a line opened later is seeded with them, and neither chimes nor opens a closed line. This
  happens while the call is on, and also while it is stopped, so the voice has them at the next
  Start; nothing leaves the Mac until a line opens. A question Claude asks or a permission
  prompt it waits on is said by the voice in the target whoever started the turn (in another
  session, one from a turn you typed is only recorded), and a question you answer at the
  keyboard, or a prompt you settle there, is told to the voice. A voice answer a newer request
  superseded is no longer dropped: it is kept in the conversation, unsaid, and added to the open
  line as context. **Load context** is enabled only when the voice lacks part of the session. A mod and an app from before this keep
  working together: an older mod's sessions are treated as missing turns, so their lines load a
  summary as before. The data is described in [SECURITY.md](SECURITY.md#residual-risk-by-design).
- **Pause sync while the call is stopped** in Settings (off by default): with it on, what you type
  while the call is stopped is not recorded, and no line loads a summary by itself; only **Load
  context** or `/live context` does. It removes nothing already recorded. Typing under the pause
  into a turn that has a voice request in flight (or waiting behind it) makes that request's
  answer fail with a plain reason, with nothing of it recorded or said, and that turn's later
  questions and approval notices stay out.
- **Star LiveBridge on GitHub** in the menu bar menu opens the repository's page, for those who
  want to support the project.
- **Mute** beside Stop, in the band above the prompt and in the menu's call card (**Unmute**
  while muted), releases the microphone while the call goes on: an answer from Claude still opens
  the line and the voice says it. While muted LiveBridge holds no microphone, and macOS's
  microphone indicator shows it. Mute does not close an open line: it closes as if you had
  stopped speaking when you pressed Mute (the usual silence, counted from Mute if you were
  speaking), so Mute does not save realtime minutes, and it is not a control against
  other processes running as you ([SECURITY.md](SECURITY.md#who-can-drive-the-bridge)).

### Changed

- The conversation kept for each session holds its last 64 lines instead of 24.
- **Load context automatically when a line opens** is gone from Settings. A line now loads a
  summary by itself when the voice lacks part of the session (it has none, a turn did not
  arrive, the lines since the summary outgrew what the voice can carry, or the mod does not
  sync), and never after a pause or while the pause setting is on. An owner who had turned it off gets **Pause sync while the call is stopped** turned on at
  the update, so summaries stay by hand; turns typed while the call is on now sync all the same.
- **Load context** in the menu is disabled, reading **Context up to date**, while the voice has
  the whole conversation.
- A voice line that Claude's answer opens now closes and chimes when nobody has spoken on it 5
  seconds after it connects, instead of after 20 seconds of silence. In the runs measured, the
  voice started within about 2 seconds or not at all
  ([measurement](docs/adr/0001-platform-findings.md)); a voice that starts later is cut off, and
  the answer chimes and waits. A silent line costs about 15 seconds less, and the chime comes
  sooner.
- After an update, Settings lists the joined Claude Code sessions still on the old mod, by name,
  instead of always saying that open sessions keep it until they restart. A mod reports its
  version when it joins; one from before this release names none and counts as old.

### Fixed

- The requirements now say Claude Code 2.1.301 or later. They said 2.1.289, but the mod's hooks do
  not load on 2.1.296, so `/live` is not there; 2.1.301 is the lowest version checked that loads
  the mod.
- At the ChatGPT plan's usage limit the app now says so, in codex's sentence with its reset time
  where codex gives one, and ends the call, instead of "Realtime voice failed" or a wrong hint that
  the plan lacks voice, and a new failing line for every word spoken. Answers keep waiting, and
  Start tries once more. So does a plan without voice, and the service's usage check on the line's
  data channel, which codex does not report; those are not called a limit, as nothing shows one.
- A long conversation in a language other than English could stop a line from opening: the app
  measured its seed in characters while codex counts bytes and refuses a start past its limit.
- An answer, a question or a permission prompt from the target now opens the closed line every
  time. When the last line had been about another session, the app could close the new line
  before it started, so the voice said nothing and the line waited for you to speak or for a
  second one.
- A question waiting to be said keeps its route when you pick another session: your reply reaches
  the session that asked, instead of landing in the new target as a request of its own.
- A voice request whose turn ends with no answer, as a plain **No** at a permission prompt or a
  cancelled question does, now fails and says Claude ended the turn without an answer, instead of
  saying the answer is code or a table only.
- A Stop pressed while macOS's first microphone prompt was showing no longer opens the microphone
  after the call has ended: the Start that was waiting on the prompt is cancelled.

## [0.3.0]

### Added

- A short sound when the app queues a request the voice handed off. The voice sometimes says it
  is looking without handing the request off; with no sound, nothing was queued
  ([BR-001](docs/bugs/BR-001.md)). **Settings > Notifications > Play a sound when a request is
  queued for Claude** turns it off.

### Changed

- **Load context automatically** is now on by default and means "when a line opens": every line
  the app opens (a Start, a line reopened after silence, the line after a target switch) asks the
  target for its summary, and the line does not wait for it. The band's Start no longer asks for
  it separately. The mod reuses its summary until a turn the voice did not hear completes (a turn
  you typed, say) or you `/clear`, so a line reopened after a voice request costs no new summary.
- The voice's instructions say that "the chat" is the Claude Code session, and that a question
  about it that the voice's lines do not cover is handed off to Claude.
- The in-app update attaches and ejects the release image with `diskutil image attach` and
  `diskutil eject` instead of `hdiutil`, which macOS 27 deprecates. Each run mounts the image at
  a new folder of its own.
- The voice's rule against promising a look without a handoff is one sentence shorter, and lets
  the voice ask you to confirm an action first. In 20 test runs it missed no handoff, against 3 of
  20 with the old wording: too few runs to call the failure fixed
  ([BR-001](docs/bugs/BR-001.md)).
- Claude's answer to a request you handed the session you are talking to, a question Claude asks
  you there, or a permission prompt it waits on now opens the closed voice line, and the voice
  says it, instead of only chiming. It is billed like any open line; if the voice stays silent,
  the line closes after 20 seconds and chimes as before. Anything from another session, and a
  later update, still only chimes
  ([billing](README.md#billing-aware-by-design), [privacy](README.md#privacy)).

### Fixed

- When Claude asks a question during a voice request, the voice also gets what Claude wrote just
  before the question, in the same line after the options, with code blocks and tables removed
  as from a result.
- When a voice request stops at a permission prompt, the approval notice also carries what Claude
  wrote in the step that asks for it, such as "I'm going to delete build/ and re-run", with code
  blocks and tables removed. The voice only reports the prompt and tells you to answer it in
  Claude Code. Both pauses now take the step's text as it streams, so a tool that starts before
  its step ends still gets that step's text, and a long text is cut so the question still reaches
  the app.

### Note

- This release was not tried end to end against the real voice: the line that a result,
  question or approval opens, the context a line loads when it opens, and the text that comes
  with a question or an approval are covered by tests only.

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
