# Review: a sound on each answer

Report-only review of [PR 51](https://github.com/getLiveBridge/LiveBridge/pull/51), commit 51a74c9
(`feat(app): an answer that reaches the call has a sound too`). Commit c01761f belongs to PR 50 and
is out of scope. File and line references are at 51a74c9.

**Verdict: fix finding 1 before merging.** It is a real bug, proven with a test, and the fix is
one line plus two table rows. Findings 2 and 3 need the one real call on speakers that the PR
already asks for before the release. The rest is small.

## How this was checked

- `scripts/check.sh` at 51a74c9, Node 24.10.0: exit 0, 607 Swift tests and 183 mod tests.
- Skills: `superpowers:requesting-code-review` (a separate reviewer, given the code and not these
  findings, reached finding 1 on its own), `simplify` in report-only mode, `security-review`.
- Throwaway tests and mutations in a scratch checkout, none of them committed.
- Not run: `scripts/smoke.sh`, any real voice, `scripts/check-floor.sh`. So nothing here measures
  what a microphone hears. Findings 2 and 3 are read from the code and replayed through
  `CallMachine`.

## Findings by severity

### 1. Important: the sound runs before the open, so a line can open with the machine closed

`app/Sources/BridgeCore/Call/CallMachine.swift:226`, pinned by `CallMachineTests.swift:78` and
`:166`.

`Bridge.send` awaits each effect in turn (`Bridge.swift:296`). `audio.confirmAnswer()` hops to the
main actor (`AudioHost` is `@MainActor`), which releases the `Bridge` actor between the machine's
decision to open and `startOpening`. That breaks a rule the code states twice: "It goes false with
the decision to open, not when the attempt starts" (`Bridge.swift:35-38`, from 163448f) and "in the
same turn as the machine's decision to open" (`Bridge.swift:394`). Until now
`.openRealtimeForResult` was the first effect, so nothing could get in between.

Failure, reproduced at 51a74c9:

1. The owner talks on Alpha's line, it closes, and the owner picks Beta. `lineKnowsSession` stays
   true and `lineSession` is still Alpha.
2. Beta's answer opens the line: the machine goes to `.connecting` and the sound suspends the actor.
3. Any `changed()` runs in that gap. The sweep runs one every second (`Bridge.swift:92`), and so
   does every POST from any session. `followTarget` (`:562`) sees the stale session and sends
   `.conversationChanged`, so the machine hangs up to `.listening`, with a chime and a notification.
4. The effect list resumes and `startOpening` opens the line anyway.
5. `.connected` in `.listening` does nothing (`CallMachine.swift:306`): no `flushPreroll`, no
   `armSilence`, no `meter.opened`.

The throwaway test holds `confirmAnswer` in `FakeAudio`, posts `/v1/activity` from Alpha, then lets
it go. It ended with one voice session opened and `phase=listening`, three runs of three, and the
audio calls end `closePeer, chime, applyAnswer`, with no `flushPreroll` after. So the owner has an
open voice session with no silence timer that the usage meter does not count. It lasts until the
next speech, Stop, or the service closes it. I did not trace what the next speech does on the codex
side.

Stop in the same gap fails the same way: `connecting?.cancel()` finds nothing, then `startOpening`
runs with the call off. The test ended with `phase=off` and a voice session opened. In the real page
`LB.makeOffer` throws once `ctx` is gone, but `controller()` has already launched a new codex by
then (`Bridge.swift:416-417`), and `.connectFailed` is ignored in `.off`. That last part is from
reading the code.

The gap is one main-actor hop, not measured, so each opening that qualifies has a small chance,
and it needs a target changed since the last line. Rare, but the owner pays and the meter hides it.

`aQuestionOpensAClosedLineAfterAnotherSessionsLine` does not cover this: it uses `.asking`, which
has no sound.

Fix: `return [.openRealtimeForResult] + arrival(of: result)`. `startOpening` does not suspend before
the attempt exists (`waits: false`), so the owner hears no difference. With that swap the same test
ends `phase=live`, and a Stop in the gap cancels the attempt and closes the line. Add a `Bridge` test
with a `FakeAudio` that suspends in `confirmAnswer`. `.speak` and `.addContext` have no such rule;
their order is fine.

### 2. Important if the microphone hears the sound: an opening line stays open 20 s, not 5 s

`CallMachine.swift:259-262`, with `Bridge.swift:296` and `Resources/audio/vad.js:13`.

Yes, the sound can make the line look spoken on and keep it open longer. An opening answer sounds at
the moment the line starts connecting, and the sound is 0.82 s. 250 ms of it above -45 dB gives
`.speechStarted`, which during `.connecting` clears `isAwaitingFirstWord` for good. Replayed through
`CallMachine`:

| Given, then `.connected` | Silence armed |
|---|---|
| Nobody heard anything | 5 s |
| The sound heard and ended while connecting | 20 s |
| The sound still heard at the connect | 90 s, then 20 s at `.speechEnded` |

The voice stays silent in about 4 of 14 runs (ADR 0001 (n)), and each of those then costs 15 s more
on speakers, or about 4 s averaged over every opening. Where the voice speaks, nothing changes.

Two more effects the PR body does not list:

- A question withdrawn while its line connects no longer closes that line: `withdraw` requires
  `isAwaitingFirstWord` (`CallMachine.swift:317`). Replayed, it returns no effects and the phase
  stays `.connecting`; without the sound heard it closes.
- A live line a result opened loses the 5 s the same way when another session's answer sounds on it
  (`:263-266`).

`README.md:485-486` ("closes 5 seconds after it connects") and `overview.md:285` would then claim
more than the code does on speakers.

How likely it is: the code cannot say. The page asks for `echoCancellation` (`audio.js:86`), and
BR-001 records that echo cancellation removed most of `say` played through the speakers, which is
also audio from outside the page. The waiting chime has also played with the microphone live in
`.listening`, where `.speechStarted` would open a line, and `docs/bugs/` records no such report. But
"most" is not all, and PR 50 made the sound louder at its peak, so neither settles it.

For the owner to choose, after the real call: BR-001 already names one fix, playing the sound through
the audio page, in the voice's output path. Another is to let only `.userTranscribed` or the voice end
the first-word wait, so a sound without words cannot.

### 3. Important if the microphone hears the sound: it is sent to the voice as the owner's audio

`Resources/audio/audio.js:185-187`, `preroll.js:73-79`, `docs/architecture/overview.md:282`.

The PR body says codex's handling is unknown, but not that the path exists. `makeOffer(false)` drops
the pre-roll and then queues everything after it, and it runs within moments of the sound starting.
At `flushPreroll` the queue plays into the peer's track, and catch-up drops only silent frames, so a
loud sound stays. A heard sound therefore becomes the first audio of a line that "starts without the
pre-roll, as nobody spoke". On a live line it goes straight in, while the voice is starting the
answer.

If codex takes it for speech it could reply to it, cut the answer short, or transcribe something
that `Bridge.swift:494` records as an owner turn. None of that is tested. The real call should listen
for it, and watch the conversation in the menu.

### 4. Minor: the PR body's delay estimate is wrong

"Delaying the result by about 1.4 s" does not describe the code. The answer that made the sound is
not delayed at all: `.speak` is in the same effect list and has gone out before anything hears the
sound. Only a second answer arriving while the sound counts as speech is held, and it then gets no
sound of its own. Its delay is up to 0.82 + 0.6 + 0.8 = about 2.2 s from the start of the first
sound, not 1.4 s, which leaves out the sound's own length. Replayed: `[armSilence(90)]`, then
`.speechEnded` arms the grace, then `.speak`. The same 1.4 s also pushes back the silence timer once
per answer on an open line. The handoff sound's "about half as long" is right: 0.47 s against 0.82 s.

### 5. Minor: nothing tests that the waiting chime ignores the setting

`Bridge.swift:325-327`. README, CHANGELOG and the PR all say it "plays either way". Mutation: gating
`.chime` on `confirmsWithSound()` leaves all 207 `BridgeTests` green. Only two tests pass the setting,
and neither reaches `.chime`. Add one test: setting off, a result that waits, `chime` plays. The same
mutation pass confirms the PR's other claims: dropping any of the four conditions in `arrival(of:)`
fails `CallMachineTests`, and adding a notification or removing the setting from `.confirmAnswer`
fails `answerSoundFollowsTheSoundSetting`.

### 6. Minor: the doc that says what the sounds mean is now stale

`scripts/render-sound.mjs:8` says `chime.wav` is "played when a result waits with the line closed",
and `overview.md:203` sends readers there. The commit changed that meaning and not the file.

### 7. Minor: "no sound means nothing was queued" is now weaker

`README.md:463-464`, `SettingsView.swift:42`, `docs/bugs/BR-001.md`. Another session's answer can now
sound just after the voice says it is looking, and the owner may take that as the confirmation. The
caption under the renamed toggle also still speaks only of requests. Say that only the handoff sound
confirms a request.

### 8. Minor: what counts as an answer is not quite what the docs say

- Failures the bridge writes itself, "timed out" and the session-left reason, carry a session
  (`SessionRegistry.swift:278`, `:342`), so they sound. CHANGELOG says "An answer from Claude", and
  the sound means Claude has thought and sent. Accept it and word it so, or exclude them.
- `.asking` has no sound, which fits "final answer", but `overview.md:289-291` and the PR's table
  list what has none without it. A reader of the paragraph above takes it for "a question".
- For the owner to confirm: the final answer of a typed turn arrives as a synced line, so it has no
  sound on an open line, and neither does a superseded answer (`Bridge.swift:734`). The code matches
  the brief as written; whether "each final answer" means these too is the owner's call.

### 9. Minor: two sounds within 0.82 s are one

`AudioHost.swift:109,113` share one `NSSound`. A muted run confirmed that a second `play()` returns
false while the first plays. So two answers in that span sound once, and a `.chime` right after a
`.confirmAnswer` (a connect that fails at once) is silent, though its notification still posts. The
owner has just heard the same sound, so this is harmless. It is noted because the rule says "each".

### 10. Minor: redundancy

See the architecture section.

- `AudioSide.confirmAnswer` is `chime` under a second name.
- The test row at `CallMachineTests.swift:409` duplicates line 198 exactly.
- `.handedOff(alpha)` in the given of `aQuestionSoundsToo` (`:385`) does nothing.
- `Play sounds for requests…` lines in the seven READMEs run past the files' width (110 characters
  in `README.md:287`). Rewrap.

## Questions from the brief

**Every path through `arrival(of:)`.** It matches the PR's table.

| Phase and event | Sound | Then |
|---|---|---|
| `.off`, `.listening` not opening | none, or the waiting chime | unchanged |
| `.listening`, opening | `confirmAnswer` if answer and quiet | see finding 1 |
| `.connecting` | `confirmAnswer` if answer and quiet | context at `.connected`, no second sound |
| `.live`, not awaited | `confirmAnswer` if answer and quiet | context; chime at hang-up if unsaid |
| `.live`, awaited, quiet | `confirmAnswer` | `.speak` |
| `.live`, awaited, someone speaking | none | held; `.graceElapsed` says it with no sound |
| Update, approval, `.asking`, session `nil` | none | as before |

No answer sounds twice for one arrival. `say` runs once per delivery, and neither `.connected` nor
`.graceElapsed` nor a reopened line calls `arrival`. A `.question` takes the same paths as a result.
An answer on an open line that is never said sounds and later chimes at hang-up: the same two
moments as the opening case the owner accepted. With the microphone muted `.speechStarted` is
ignored, so the sound always plays and cannot be heard by detection.

**`Bridge`.** The rename is complete and `App.swift` passes the setting. `.confirmAnswer` plays and
posts no notification, and the saved key is unchanged.

**The test `answerSoundFollowsTheSoundSetting`.** It is behaviour and it fails under both mutations.
It covers the context path, not `.speak`, which the table covers.

**The table rows.** Behaviour, apart from line 409. `noSoundWithTheCallOff` and
`aWaitingAnswerOnlyChimes` look like rows that exist, but those use `a`, which has no session, so
only the new rows would catch `arrival` added to those paths. `noSoundForAnUpdate` is new coverage.

**Docs.** All seven READMEs say the same thing. Nothing in the README still says an answer on an
open line makes no sound. The `README.md:309` and `:354-356` passages are about a closed line and
stay true. The Settings label matches. Beyond that, see findings 2, 6, 7 and 8.

**Is the architecture elegant enough, is anything redundant?** Yes, once finding 1 is fixed. The
machine decides who is speaking, the bridge holds the setting, and `.confirmAnswer` earns its own
effect, because it has the gate and lacks the notification. What is redundant:

- `AudioSide.confirmAnswer`, `AudioHost.confirmAnswer:113` and the `FakeAudio` entry encode no audio
  difference. `.confirmAnswer` can call `audio.chime()`, and the test's notifier check still tells
  them apart. This also removes the need for the doc comment's "the same sound as `chime`".
- `isSoundOn || isVoiceSpeaking` now appears four times (`CallMachine.swift:177`, `:256`, `:291`,
  `:380`). One private `isSomeoneSpeaking` would do.
- `confirmsWithSound` reads `confirmHandoffs`, half a rename that a comment has to explain. Map the
  key with `CodingKeys`, or leave `Bridge`'s name alone.

Threading `arrival` through three arms is tolerable; moving it into `handle` is not worth the churn.

## Security

No findings. `.confirmAnswer` carries no payload and plays a bundled file, so no text reaches a
notification, a log or the wire. Approvals have no sound, and the commit adds no route to a
permission prompt. The saved settings key is unchanged. Findings 2 and 3 concern cost and call
quality; a sound with no words is not a request path this review could establish.

`simplify`'s efficiency angle found nothing; its reuse, simplification and altitude angles are in
findings 10 and the architecture section.
