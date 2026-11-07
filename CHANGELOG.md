# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The app installs with Homebrew from LiveBridge's own tap:
  `brew install --cask getlivebridge/tap/livebridge`.
- Each release from v0.2.0 on carries its disk image's build attestation as
  `LiveBridge.dmg.sigstore.json`.
  Adding `--bundle LiveBridge.dmg.sigstore.json` to the README's whole `gh attestation verify`
  command checks the image against that file instead of the copy GitHub stores.

## [0.4.2]

### Changed

- The translated READMEs moved to `docs/i18n/`.
- An answer, failure or question from Claude that reaches an open or opening line now plays the
  same sound, unless someone is speaking. There is no notification with it, and an update has no
  sound. The setting is now **Play sounds for requests and answers** and covers it; the sound for a
  result that waits plays either way.
- The sound for a waiting result is now LiveBridge's own instead of macOS's Glass, made to pair
  with the sound for a queued request. It is shorter, 0.82 s instead of 1.65 s, and louder at its
  peak.
- **`/live` is the one command that joins.** In a session that has not joined it joins, and opens
  the app if it is not running; in a joined session it brings back the band and answers with the
  status line. It is not a toggle: repeating it never leaves, and `/live off` still does. `/live on`
  still works, the same as `/live`.

### Removed

- `/live target`, `/live status` and `/live context`. Each now answers
  `Usage: /live | /live off`. **Talk here** in the band and a click on a session in the menu set the
  target, `/live` gives the status, and **Load context** in the menu loads a summary.

### Fixed

- During a call, **Conversation** now shows your words and the voice's as codex transcribes them,
  where a line used to appear only when it was final: a long reply showed once the voice had
  finished it, and your line once the voice had started answering. Your words can still appear a
  moment after you say them, and the voice's a moment before you hear them. What is kept, and what
  the voice is seeded with, is still only the final text, which replaces the words shown.
- A click on a usage row no longer closes the menu: the row lights up under the pointer and does
  nothing. Its reset times now go as soon as the pointer leaves the row, and clicks pass through
  them.

Note: the owner tried this version by hand on a debug build before the release. How often the new
sound reaches the microphone on speakers was not measured, and the update from the app has not run
on this version.

## [0.4.1]

### Changed

- A loaded summary now sits in **Conversation** where it was loaded, marked **Loaded context** and
  shown whole, instead of under **What was sent** at the bottom, cut to 600 characters.
- **Load context** is no longer enabled just because a new session has no summary, since its next
  line asks for one by itself: the item reads **Context loads with the line** and is disabled. It stays
  enabled for a gap, a mod that does not sync, too many lines, and **Pause sync**.

Note: neither change has been seen in the real menu on the final build. A debug build and the
installed app share one data folder, so opening an older app after this version empties its saved
conversations and paused marks; the in-app update never goes back.

## [0.4.0]

### Added

- **Conversation sync.** What you type in a joined session and Claude's final answer to it now go
  into that session's conversation with the voice, as context: an open line gets them at once, a
  line opened later is seeded with them, and neither chimes nor opens a closed line. This happens
  while the call is on, and also while it is stopped, so the voice has them at the next Start;
  nothing leaves the Mac until a line opens. A question Claude asks or a permission prompt it waits
  on is given to the voice in the target whoever started the turn, and the voice may say it; in
  another session, one from a turn that was not a voice request is only recorded. A question or a
  prompt settled without the voice, or a turn that ends without an answer, reaches the voice as a line saying so. Typing does not wait on a stuck codex: the mod's hooks hold
  at most 200 ms for their posts. A voice answer a newer request superseded is no longer dropped: it is kept in the
  conversation, unsaid, and added to the open line as context. An older mod's sessions are treated
  as missing turns, so their lines load a summary as before. On such
  a mod a voice turn that outlives its 10-minute request and gets a spoken reply loses its answer:
  the reply opens no request, the answer is refused, and the mod says so in the session (traced, not
  run). A newer mod on an older app works but
  differs: a question from a turn you typed goes to the voice too, in other sessions as well, and a
  spoken reply to it goes with nothing in flight, so the line can wait up to 120 seconds, billed,
  for no result (traced in the code, not run). Sync is delivered in part: still unchecked are the
  real desktop app, a real model, **Load context** in the real menu, and whether the voice announces
  a permission prompt ([known limitations](README.md#known-limitations)). The data is described in
  [SECURITY.md](SECURITY.md#residual-risk-by-design).
- **Pause sync while the call is stopped** in Settings (off by default): with it on, what you type
  while the call is stopped is not recorded, and no line loads a summary by itself; only **Load
  context** or `/live context` does. It removes nothing already recorded. Typing under the pause
  into a turn makes the answer of the voice request that turn names fail with a plain reason, with
  nothing of it recorded or said, and that turn's later questions and approval notices stay out. A
  request that only waits behind that turn keeps its answer, which can quote the paused text
  ([SECURITY.md](SECURITY.md#residual-risk-by-design)).
- The menu shows how much of your Codex and Claude usage is used, one row each, with the percent
  used of every window the plan reports (up to three), orange from 90 %, and the reset times on
  hover. Codex's figures are read when the menu opens, at most once a minute, by a short-lived
  codex that asks OpenAI, also while the call is off; Claude's come from a joined session that has
  answered ([Privacy](README.md#privacy)).
- **Star LiveBridge on GitHub** in the menu bar menu opens the repository's page, for those who
  want to support the project.
- **Mute** beside Stop, in the band above the prompt and in the menu's call card (**Unmute**
  while muted), releases the microphone while the call goes on: an answer from Claude still opens
  the line and goes to the voice to say. While muted LiveBridge holds no microphone, and macOS's
  microphone indicator shows it. Mute does not close an open line: it closes as if you had
  stopped speaking when you pressed Mute (the usual silence, counted from Mute if you were
  speaking), so Mute does not save realtime minutes, and it is not a control against
  other processes running as you ([SECURITY.md](SECURITY.md#who-can-drive-the-bridge)).

### Changed

- The conversation kept for each session holds its last 64 lines instead of 24.
- **Load context automatically when a line opens** is gone from Settings. A line now loads a summary
  by itself when the voice lacks part of the session ([when](README.md#the-band-and-the-menu)). An
  owner who had turned it off gets **Pause
  sync while the call is stopped** turned on at the update, so summaries stay by hand; turns typed
  while the call is on now sync all the same.
- **Load context** in the menu is disabled, reading **Context up to date**, while the voice has
  the whole conversation. A summary the app asked for before a later gap or **New conversation** is
  ignored, and the menu keeps offering it.
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
- The requirements, the site and the app's help and hint now ask for a ChatGPT plan whose Codex
  includes voice, and the README names the plans OpenAI's pricing page lists, instead of "realtime
  voice", which no OpenAI page says.
- A long conversation in a language other than English could stop a line from opening: the app
  measured its seed in characters while codex counts bytes and refuses a start past its limit.
- An answer, a question or a permission prompt from the target now opens the closed line whichever
  session the last line was about, as long as the target's conversation holds a turn of yours (after
  **New conversation** it only chimes). When the last line had been about another session, the app
  could close the new line before it started, so the voice was given nothing and the line waited for
  you to speak or for a second one.
- Choosing another session, from the menu, the band, `/live target` or `POST /v1/target`, takes
  every other session's waiting question off the voice's queue and ends its route, so your next
  words go to the new target and do not answer a question you left behind; it stays recorded for
  that session's seed. A pause at the plan's limit, with no change of target, keeps the question
  and its route. A session that leaves or is removed takes its waiting question and approval notice
  with it, and a failed microphone ends a route as Stop does.
- A voice request whose turn ends with no answer, as a plain **No** at a permission prompt or a
  cancelled question does, now fails and says Claude ended the turn without an answer, instead of
  saying the answer is code or a table only. With a mod from before this release an empty answer
  still reads as code or a table only.
- Redaction no longer stalls on a long unbroken run of text.
- A `/clear` while the line connects keeps the line's seed.
- A Stop pressed while macOS's first microphone prompt was showing no longer opens the microphone
  after the call has ended: the Start that was waiting on the prompt is cancelled.

### Note

- The README's [known limitations](README.md#known-limitations) now say what the mod loses where
  an organization manages Claude Code: there the mod's hooks on `classic.PermissionRequest`,
  `classic.PostToolUse`, `classic.PostToolUseFailure` and `classic.PermissionDenied` do not run,
  so the voice does not say that a permission prompt is waiting, and three managed settings keep
  a mod you installed from loading. Nothing about the prompt itself changes: it still appears in Claude Code
  and only you can answer it. No code changed.
- This release's end-to-end check was `scripts/smoke.sh` on the real voice with a stand-in Claude
  Code session, and conversation sync's manual check, also on a canned model. Not run: sync with a
  real model, or in the Claude desktop app. Not seen in the real menu on the final build: **Load
  context**, and the colouring of the usage rows. The in-app update from 0.3.0 was read, and its
  data files tested, but not run.

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
