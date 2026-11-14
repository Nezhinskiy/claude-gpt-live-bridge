# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- The target session polls the app five times a second only while the call is on; with the call
  off it polls once a second, as the others do, so a session with no call wakes the app and itself
  a fifth as often. With the call off, Start's ask for a summary, a **Load context** press and a
  model check reach the mod up to 0.8 s later than in 0.6.0, well within the line's 10 seconds of
  waiting for a summary.
- **Show Debug Files** in the menu's **Feedback & Support** has no ellipsis any more, as in
  Settings: it opens the folder and asks nothing more.

### Fixed

- A setting of the wrong type in `settings.json`, such as a hand-edited `"silenceSeconds": 7.5`
  or `"20"`, no longer resets every setting: that one takes its default, and the voice, the
  prompt and the rest are kept.
- **Uninstall LiveBridge…** no longer says "Nothing was changed" when it cannot move the app to the
  Trash and macOS does not let it put back the login item it removed first: it says the login item
  could not be restored, and that **Open at login** in Settings or System Settings ▸ General ▸
  Login Items turns it on again.
- A summary that fails is no longer asked for again by itself. After an ask the mod answers with
  no summary and a failure, neither a change of target during the call nor a line that opens asks
  that session again until a turn of it arrives, typed or by voice, or the next Start, so a long
  call no longer sends the same transcript, up to 120,000 characters, to the summary model at
  every line. **Load context** still asks, and the menu offers it then. An ask already answered is no longer handed to the mod
  again. `/clear` during a call no longer asks the session ahead as if the target had changed, nor
  lets a line wait for the summary again when the call had spent that wait, and **Context loaded**
  survives it.
- A session whose transcript the mod cannot turn into text now reports the summary as failed with
  **transcript-unreadable**, before any model is asked, and logs the error in the session, instead
  of failing with no reason.
- A summary still being written when you run `/clear` is stale, as one a gap crossed is: the band
  no longer says **Context sent** for it, and an older app no longer gets the old conversation's.
- A summary that went stale while its first model failed (a gap, or `/clear`) no longer asks the
  fallback model for one nobody will use.

## [0.6.0]

### Added

- Settings sets how long the line stays open in quiet: **Silence before the line closes** (20
  seconds by default), **Wait for a first word on a line a result opened** (5 seconds) and **Sound
  without words before the line closes** (90 seconds), each from 0 to 300 seconds. 0 switches the
  silence or the sound without words off, and a first-word wait of 0 waits as long as the silence,
  so with all three at 0 quiet never closes the line, which stays open and billed. A timer turned
  on starts at once on a quiet open line. The defaults are the old fixed values, so nothing changes
  until you change them.
- **Connect over TCP**, in Settings under Line, off by default: if the voice breaks up on a poor
  connection, turn it on and the line prefers the media server's TCP route (port 443 in the answers
  seen) to UDP, which can turn breakups into short pauses; it can still fall back to UDP. Changing
  it while a line is open asks first, then opens the line again over the new transport, still
  waiting for what it was waiting for.
- The menu's **Quick Settings** submenu holds five of Settings' switches as checkmark items:
  **Connect over TCP**, **Play sounds for requests and answers**, **Notify when a result is
  waiting**, **Pause sync while the call is stopped** and **Load a session's context on its first
  call**. Each is the setting itself, so a change in the menu or in Settings shows at once in the
  other, and Connect over TCP asks before reconnecting an open line, as in Settings.
- The menu's **Feedback & Support** submenu holds **Report a Bug…** (the repository's bug report
  form), **LiveBridge Website** and **Star LiveBridge on GitHub**.
- **Debug mode**, in Settings under General and as **Debug Mode** in **Feedback & Support**, off by
  default, in every build: during a call it writes a row a second of the voice's network numbers,
  one CSV per call, under `debug/call-stats` in LiveBridge's data folder; no audio, no transcript,
  no session names, and nothing leaves the Mac. **Show Debug Files** opens the folder. The
  numbers include which transport the line took (`onTcp`).
- **Uninstall LiveBridge…**, in **Feedback & Support** of the copy in `/Applications`, asks, then
  moves the app to the Trash, or says why it cannot and changes nothing; then every session leaves
  LiveBridge, so `/live` turns off, LiveBridge removes its login item and microphone permission and
  quits, and the files it keeps go to the Trash. It copies the command that removes the Claude Code
  mod for you to run.
- **Summary model**, in Settings under Context: Haiku 5.5 (the default), Sonnet 5.5 or Opus 5.5
  writes the summary the voice gets as context, always at low effort, on your Claude usage. If
  another model fails, Haiku 5.5 writes it instead, unless that model ran out of time, and a line
  under the setting says so; if no model writes one, it says why, or that the session's transcript
  could not be read. When a summary fails, the session's band says **Context failed**.
  **Custom…** takes a model id, refusing text that cannot be one (with a space, say, or over 128
  characters), which a joined session checks with one short request before it is saved.

### Changed

- The Settings window has four tabs in its toolbar: **General** (notifications, Open at login,
  updates and debug mode), **Voice** (the voice, the prompt and the sounds), **Line** (the line's
  timers and Connect over TCP) and **Context** (sync and the summary model).
- **Star LiveBridge on GitHub** moved from the menu's foot into **Feedback & Support**.

- While Claude works, the menu bar icon shows dots turning in depth, three and then four, which
  gather into one between turns, for thinking, in place of a turning ring, which read as loading;
  the session's row in the menu shows an ellipsis in place of turning arrows.
- During a call, while the target's summary is on its way, the menu bar icon shows a
  three-quarter ring turning once a second, still when macOS is set to reduce motion. A problem
  or a waiting approval shows instead of it; it shows instead of unheard results or Claude working.
- While the call is stopped, the menu bar icon no longer shows that a session's Claude is working;
  the session's row in the menu still says so. A waiting approval still shows.
- Summaries are written by Haiku 5.5 by default, on an update too, in place of the session's own
  model at the session's own effort. The model reads the session's transcript with tool output,
  thinking and system reminders left out, but not text that quotes them, cut to 120,000
  characters. Unlike the fork, it does not wait for a
  turn of a resumed or new Claude Code process to end ([BR-003](docs/bugs/BR-003.md), for an app
  and a mod of this release). Where Claude Code's provider does not offer Haiku 5.5, the session gets no
  summary ([known limitations](README.md#known-limitations)).
- A line no longer reaches the voice before its context: for a session on a mod of this release,
  the line waits for the summary in flight before it connects, while what you say is recorded and
  queued on the Mac, then opens with the summary in its seed and plays what you said. It opens
  without one 10 seconds after the ask, or as soon as the mod answers with none; an answer with none,
  or a line that waits the 10 seconds, ends that session's waits until the next Start
  ([the wait](docs/architecture/overview.md#silent-hang-up)). Such a session is asked at
  Start and when the target changes during the call, so the summary is often in before you speak;
  a line that opens while that ask is on its way joins it, and the mod writes one summary for both,
  or writes it again if it lost it (it restarted, or the app did). A failing summary is reported
  once for each write, and the next line that needs it asks, and may report, again. A session on
  an older mod is asked when its line opens and is not waited for, as before.
- The menu's **Load context** reads **Loading context…**, disabled, while any summary of the target
  is on its way from a mod of this release, whatever asked for it (Start, a new target, a line or
  a press), not only after a press; it waits until the summary arrives or the mod's 60 seconds from
  the ask pass. For a session on an older mod, a press no longer shows **Loading context…**. A summary that arrives shows **Context loaded** for a
  moment, whatever asked for it; an empty answer goes back to **Load context** without it.
- The target session polls the app five times a second, call on or off, and the others still once
  a second, so a summary ask reaches it up to 0.8 s sooner; its title is still read once a second.
- A session's band draws a call phase it does not know, from a later app, as **Connecting**, where
  it could not draw the band before.
- The mod answers every summary ask from this app, with an empty summary when it has none, and
  each ask carries a number that its answer repeats, so a summary written before a gap the app
  has heard of is not taken for a fresh one, nor one written across a gap the mod noted and had
  not yet reported ([the wire](docs/architecture/overview.md#the-wire)). An older app or mod sends no number and still guesses ([BR-002](docs/bugs/BR-002.md)).

### Deprecated

- The mod's fork of the session's own model, kept only for an app that names no summary model. It
  is removed in the first mod release after the app that names one has been the oldest supported
  app for one release.

### Fixed

- The Settings window no longer runs past the bottom of a small screen: it is never taller than
  the screen above the Dock and below the menu bar, and a tab taller than that scrolls.

## [0.5.0]

### Added

- The app installs with Homebrew from LiveBridge's own tap:
  `brew install --cask getlivebridge/tap/livebridge`.
- Each release from v0.2.0 on carries its disk image's build attestation as
  `LiveBridge.dmg.sigstore.json`.
  Adding `--bundle LiveBridge.dmg.sigstore.json` to the README's whole `gh attestation verify`
  command checks the image against that file instead of the copy GitHub stores.
- **Load a session's context on its first call**, in Settings under Sync, on by default: a line
  that opens for a session the voice has no summary for asks for one even while **Pause sync
  while the call is stopped** is on or the session is paused, so an old chat or a chat after **New
  conversation** starts with its context. That summary is written from the whole transcript,
  paused text included, and goes to OpenAI; after it, the pause works as before. If the pause was
  on when you update (or you had turned off the automatic summary, which became the pause), this
  stays off; you can turn it on in Settings. A session still marked paused from an earlier pause,
  with the pause off when you update, is not covered: the setting is on, and that session's first
  summary carries what you paused.

### Changed

- The disk image and the app inside it are signed with LiveBridge's Developer ID and notarized
  by Apple, so macOS opens the download after its usual question instead of blocking it until
  **Open Anyway**. The release fails rather than ship without the signature.
- With the Developer ID, the microphone permission should carry over from one release to the
  next. The first update from 0.4.2 or earlier, which were signed ad hoc, asks for it once more.
- `scripts/build-app.sh --package` is `--package-app` then `--package-dmg`, and signs with
  `LIVEBRIDGE_SIGN_IDENTITY` when it is set; without it the app is signed ad hoc and the image
  left unsigned, as before.
  `scripts/notarize.sh` notarizes and staples either half.

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
