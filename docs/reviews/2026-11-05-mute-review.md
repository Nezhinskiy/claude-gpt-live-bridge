# Review: the Mute spec and plan

Reviewed 2026-11-05, before execution. Branch `origin/feat/mute` at 7e7949b, base `origin/dev`
(5a8fd93). Documents: [the spec](../specs/2026-11-05-mute-design.md) and
[the plan](../plans/2026-11-05-mute.md), read against the code they change. Every premise below
was checked in the tree at 7e7949b; line numbers are from that tree. Nothing was built or run.

Skills applied: `superpowers:requesting-code-review` (a reviewer seat on the template, plus my
own read), `simplify` (four lenses: reuse, simplification, efficiency, altitude), and
`security-review` (one finder, then a false-positive filter on each candidate rated Medium or
above).

## Verdict

**Ready to execute: with fixes.** The design is the right shape. Mute is an explicit,
idempotent wire action. It is a flag in the pure call machine, orthogonal to the phase. The
microphone is released rather than ignored, so the macOS indicator is something the owner can
see. Stop clears the mute through the existing `end(with:)`. Plan citations are accurate
almost everywhere.

Three things must change before dispatch:

1. **The privacy promise has a hole.** In the audio page, the planned rule ("the handlers do
   nothing while muted") does not cover a microphone request already in flight when Mute
   arrives. In that case the microphone comes back while the app shows Muted (SE-1).
2. **Two tasks cannot pass as scoped.** Task 1 does not compile on its own (CR-1). Wave 2 is
   not build-independent (CR-2).
3. **Several planned tests lock in a defect or cannot fail.** The Mute row that drops the
   grace (CR-5), the Mute button against an older app (CR-3), and `unmuteAttachesOneInput` and
   `stopClearsTheMute` (SI-4).

**Is the design elegant?** At the wire and the call machine, yes. Two explicit actions avoid a
toggle race between the band and the menu, and `isMuted` lives where the other call state
lives. Three places fall short:

- **The audio page** guards two event handlers with a flag instead of placing one rule where
  the microphone is acquired (SI-1).
- **"Speech ends at Mute"** is hand-coded in the machine instead of reusing `.speechEnded`
  (SI-2).
- **The band** swaps the phase label for "Muted", hiding Live and Connecting (CR-11).

**Is anything redundant?**

- **Removable:**
  - the Swift `init(from:)` and its test `aStatusWithoutIsMutedReadsAsUnmuted`, because the
    app never decodes a `StatusReply` it did not write (SI-3);
  - the track-ended guard, because `MediaStreamTrack.stop()` fires no `ended` (SI-1);
  - two tests that cannot fail (SI-4).
- **Not redundant:** emptying the pre-roll at Mute. It looks redundant, but without it the
  first speech after a quick Unmute would carry up to 2 s recorded just before Mute (SE-2).

**Counts:** 1 Critical, 14 Important, 13 Minor (28 findings).

| Skill | Critical | Important | Minor |
| --- | --- | --- | --- |
| requesting-code-review (CR) | 0 | 9 | 6 |
| simplify (SI) | 0 | 3 | 4 |
| security-review (SE) | 1 | 2 | 3 |

---

## superpowers:requesting-code-review

### CR-1 · Important · Plan Task 1: the wire task cannot reach "both pass"

**Problem.** Task 1 breaks the build in two ways:

- Adding `.mute`/`.unmute` to `CallAction` makes `switch action` in `Bridge.perform`
  (Bridge.swift:118-133, no `default`) non-exhaustive, so BridgeCore no longer compiles.
- Step 3's custom `init(from:)`, declared in the body of `StatusReply`, removes the memberwise
  initializer. That initializer is used at Bridge.swift:97, MenuTests.swift:71 and
  StatusPresentationTests.swift:13.

So Step 4 ("both pass") and the global rule "`scripts/check.sh` exits 0 before each commit"
both fail.

**Fix.**

- Add Bridge.swift to Task 1's files with `case .mute, .unmute: break`, which Task 2 replaces.
  Alternatively, move the `CallAction` cases into Task 2.
- Declare `public var isMuted = false` with synthesized `Codable` and no custom init (SI-3).

### CR-2 · Important · Plan, Wave 2: Tasks 2, 3 and 4 are not independent in the build

**Problem.**

- Task 2 adds two requirements to `AudioSide` (BridgeCore). The only conformer outside the
  tests is `AudioHost` (LiveBridge target), and that is Task 3's file. After Task 2, `swift build`
  fails. `check.sh:7` runs `swift build`, and Task 2's own `MenuRows.swift` is in the same
  target.
- Task 2's `swift test` still passes, because the test target depends only on BridgeCore. That
  masks the break.
- Task 3 "consumes Task 2's `AudioSide` methods", so the plan itself states an edge between
  the two tasks, while the header says Wave 2's tasks may run in parallel.
- "They share no file" holds, but sharing no file is not the same as sharing no build.

**Fix.** Do one of these:

- Move the two `AudioHost` methods into Task 2. They are about four lines each and call
  `LB.mute()`/`LB.unmute()`, which Task 3 then implements.
- Give `AudioSide` default no-op implementations in a protocol extension until Task 3.
- Make Task 3 follow Task 2.

Also draw the wave graph from Consumes/Produces, not from file lists.

### CR-3 · Important · Spec "Failures", plan Task 4: a newer mod against an older app shows a dead Mute

**Problem.** Task 4's test "a status without `isMuted` shows **Mute**" fixes the wrong
behaviour:

- `isMuted` is absent only when the app predates Mute.
- That app's `CallBody` decoding rejects `"mute"` with 400 "the body does not match the wire
  schema" (Bridge.swift:247).
- `link.call` (link.ts:120) swallows the failure, so the button does nothing and says nothing.
- The skew is real. The spec handles only the reverse case (older mod, newer app).

**Fix.**

- Draw Mute only when `status.isMuted !== undefined`, using the band's existing conditional
  pattern (band.tsx:31, :68).
- Invert the test: no `isMuted`, no Mute button.
- Add the case to the spec's Failures section.

### CR-4 · Important · Spec "Failures", plan Task 3: a failed Unmute is reported by no existing path

**Problem.** The spec says the existing `microphoneDenied`/`audioFailed` paths report a failed
Unmute "as at Start". The plan does not build that:

- Those paths live in `listen()`'s catch (audio.js:134-140). `attachInput` posts nothing.
- `AudioSide` methods do not throw. The plan's `call("return await LB.unmute()")` would end up
  under `try?`, as `stopListening` does.
- The result: the status says unmuted, the microphone is not captured, and nothing is shown.

**Fix.**

- **Page:** factor `listen()`'s catch into one `failMicrophone(error)` that `listen` and
  `unmute` share. That covers `NotAllowedError` → `microphoneDenied`, the `reasons` map, and
  `fail(...)` after `stop()`.
- **Native:** `AudioHost.unmuteMicrophone` follows `startListening` (AudioHost.swift:60-62):
  a do/catch that calls `onEvent(.failed(...))`.
- **Spec:** say that a failed Unmute ends the call. `.audioFailed` runs `end(...)` and
  `endCodex()` (CallMachine.swift:142, Bridge.swift:205-207).
- **Test:** add one where getUserMedia rejects on unmute and the page posts the failure.

### CR-5 · Important · Plan Task 2 (`muteWhileSpeakingOnALiveLineEndsTheSpeech`): a held result goes unsaid after Mute

**Problem.**

- A result that arrives while the owner speaks is held (`isHeld`, CallMachine.swift:180-182).
  It is said only after `.graceElapsed`, and grace is armed only by `.speechEnded` or
  `.assistantFinishedSpeaking` (`graceIfQuiet`, :133-136, :151, :205).
- The planned `.mute` returns `[.muteMicrophone, arm]` and arms no grace.
- If the page's Mute resets voice detection, which the spec asks for ("ends any speech in
  progress"), no `speechEnded` follows.
- The held answer then waits until the 20 s silence closes the line, and is turned into a
  chime by `hangUp()` (:257, :263). That is the very case the spec exists for: "an answer …
  the voice says it".

The planned row asserts exactly the defect.

**Fix.**

- `.mute` sets `isMuted` and returns `[.muteMicrophone] + handle(.speechEnded)`; see SI-2.
- Add a row: `live`, `.speechStarted`, then an awaited result (held), then `.mute` →
  `[.muteMicrophone, arm, .armGrace(800)]`.

### CR-6 · Important · Spec "App" (`StatusPresentation`), plan Task 2: the menu tells a muted owner to speak

**Problem.** While muted, the call card keeps its phase-only text, and two strings become
false:

- the headline and detail "Listening — line closed" / "The line opens when you speak or
  Claude answers you." (StatusPresentation.swift:75-76), which `accessibilityLabel` (:96) reuses;
- the unheard line "N unheard — speak to hear" (MenuContent.swift:91).

The spec changes only the band's label, so the menu and the band disagree.

**Fix.**

- Make `isMuted` a property of the presentation, orthogonal to the phase. Add a muted detail
  (for example "Muted — the line opens when Claude answers you.") and a muted unheard
  sentence (for example "N unheard — unmute and speak to hear").
- Derive `muteAction` in the same initializer that derives `action`.
- Add the strings to Task 2's menu tests.

### CR-7 · Important · Plan Task 3 "Files": the test seam for `audio.js` is left to the implementer

**Problem.**

- `audio.js` cannot load in Node. It sets `window.LB` at load (:229) and uses `AudioContext`,
  `navigator.mediaDevices` and `webkit.messageHandlers` directly.
- The existing JS tests import only the pure modules (`vad.js`, `preroll.js`, `deadline.js`).
- So the plan's "if" is already decided, and the module boundary is the design decision that
  carries the privacy rule (SI-1). A plan should not leave that to a subagent.

**Fix.**

- Name the module and its interface in the plan. For example, `microphone.js`, exporting
  `createMicrophone({ acquire, connect, disconnect, onLost })`. `acquire` wraps `within`
  around `getUserMedia` (or the fake WAV).
- Give it `attach()`, `mute()`, `unmute()`, `deviceChanged()`, `release()` and a generation
  token.
- `audio.js` wires it. Task 3's tests drive it with a deferred `acquire`.

### CR-8 · Important · Plan Task 3: `stop()` and `listen()` do not reset the mute, and Unmute loses `--fake-mic`

**Problem.**

- **The mute survives Stop.** The plan adds a `muted` flag to a page whose state outlives the
  call. `stop()` (audio.js:145-151) would not clear it, so after Stop-while-muted, the next
  call ignores every device change and loses the microphone silently when a headset goes
  away.
- **The Review Focus item has no test.** It names "Stop while muted, then Start, must start
  unmuted", but Task 3 lists no test for it.
- **Unmute ignores the fake microphone.** `unmute()` "runs the existing `attachInput`", but
  `attachInput(fake)` needs the flag that `listen(fake)` received and never stored. A
  `--fake-mic` debug or smoke run would unmute into the real microphone.

**Fix.**

- `stop()` resets the mute state, or the generation token of SI-1 makes it unnecessary.
- Keep `fake` in module state beside `ctx`.
- Add a JS test: mute, stop, listen → microphone captured and device changes handled.

### CR-9 · Important · `audio.js:52,66-72` (not in the plan): a speech start in flight at Mute leaves the page holding

**Problem.**

1. The page calls `hold()` the moment its detector says "start" (:52), then posts
   `speechStarted`.
2. If Mute reaches the machine first, the muted machine ignores the event. The planned row
   `speechWhileMutedIsIgnored` is right to do so.
3. The page, though, stays `holding = true` with no peer. Every frame from then on is pushed
   into `catchUp` (:54). That queue has no bound (preroll.js:31-53), and nothing pulls it
   until `sending`.
4. **Memory:** 1024-sample frames at 48 kHz are about 190 KB/s, roughly 700 MB per muted hour.
5. **Stale replay:** the next line a result opens calls `makeOffer(false)` → `hold(false)`,
   which returns early because `holding` is already true (:67). The flushed queue then starts
   with the speech recorded before Mute.

The window is milliseconds, but the outcome is unbounded memory growth plus a stale replay.

**Fix.**

- `mute()` with no peer resets the page to fresh listening: `holding = false`,
  `catchUp.clear()`, a new VAD and pre-roll (the setup `listen()` already does, :123-125).
- Test it in the module of CR-7.

### CR-10 · Minor · Plan Tasks 2 and 4: existing assertions that will break are not named

**Problem.** These existing pieces change shape and the plan does not mention them:

- band.test.tsx:39 expects `['Stop']` for a listening call.
- MenuTests.swift:136 expects `"[call] Live · Stop"`.
- `MenuContent.outline`'s `.call` case (:157) renders one button.
- `CallCard.actionTitle` (:45) maps every non-start action to "Stop", so a second action needs
  its own title.
- Task 4's files omit `plugin/types/index.d.ts`, where `BandStatus` is defined (:5).

**Fix.** List these files and assertions in Tasks 2 and 4.

### CR-11 · Minor · Spec "Mod", plan Task 4: "Muted" replaces the phase label

**Problem.** `PHASE` gives Live the `error` colour, which is the billing signal. A line open at
Mute stays open (the spec says so), and a result can open one while muted. Replacing the label
with "Muted" hides Live and Connecting.

**Fix.** Keep the phase label and colour, and add a muted marker beside it, for example
`Live · muted`. Test the live-and-muted band.

### CR-12 · Minor · Plan Task 2: missing call-machine rows

**Problem.** These rows are not covered:

1. `.speechStarted` while muted on a live line. Unguarded, it sets `isSoundOn` and moves the
   silence timer to the 90 s noise cap (:183-185). The planned guard row covers only
   `.listening`.
2. `.mute` while `.connecting` (opened by speech), then `.connected` → `arm` at 20 s, not
   90 s.
3. A repeated `.mute` or `.unmute` does nothing. Both the band and the menu can press. An
   unguarded second Unmute takes the microphone again, and a second Mute re-arms the timer.

**Fix.** Add the three rows. Guard `.mute` with `!isMuted` and `.unmute` with `isMuted`.

### CR-13 · Minor · Plan Task 1: no fixture carries a muted status

**Problem.** The spec's Testing section says "a status with `isMuted` round-trips". Every
`next-*` fixture would carry `false`, so the encoder writing `true` is never pinned on either
side.

**Fix.** Make one fixture (for example `next-reply.json`) `"isMuted": true`.

### CR-14 · Minor · Plan: small citation and command errors

**Problem.**

- `attachInput` is at audio.js:76, not :87 (:87 is the `getUserMedia` call).
- `StatusReply` is at Wire.swift:144.
- `npm run typecheck:pure` works only inside `plugin/`; from the repository root it is
  `npm --prefix plugin run typecheck:pure`, as `check.sh` does.
- `listen()` has a local `const mute` GainNode (:128). Rename it before adding `mute()`.

**Fix.** Correct the citations and the command.

### CR-15 · Minor · Plan Wave 3, Task 5: docs outside the plan's list

**Problem.** Task 5 names only README's band and menu sentences. These also change meaning:

- README's privacy bullets at :282 ("While a call is on … the microphone feeds only a voice
  detector") and :313 (what goes to OpenAI);
- the overview's failure list (docs/architecture/overview.md:452);
- SECURITY.md's local-process list (SE-5).

SECURITY.md's own change sits in Task 3 while the rest of the docs wait for Task 5. That is
fine within one PR, but the plan should say the PR is "the change" that AGENTS.md's rule ("fix
the docs in the same change as the code") refers to.

**Fix.** List the lines in Task 5, and add one sentence on the docs rule.

---

## simplify

### SI-1 · Important · Altitude · Spec "audio.js", plan Task 3: put the microphone rule where the microphone is acquired, not in two handlers

**Problem.** Every capture path ends in `attachInput`:

- `listen`'s first attach (:132);
- `reacquire`, from `onended` (:99) and `ondevicechange` (:142);
- the planned `unmute`.

`attachInput` re-checks only `ctx !== mine` after its await (:93). A flag checked on entry to
two handlers is both too much and too little:

- **Too much:** the track-ended guard is unreachable while muted. `stop()` fires no `ended`,
  and a stopped track never ends again.
- **Too little:** it misses every acquisition already pending when Mute lands (SE-1).

**Fix.** One generation token, the rule the file header already states ("each checks it is
still the current one").

- `mute()` and `stop()` bump it, detach the input, stop the tracks, and null `ondevicechange`
  and the track's `onended`.
- `attachInput` captures the token, and after each await stops the new tracks and returns
  false if the token moved.
- `unmute()` is `attach` plus one helper that re-installs `ondevicechange`, shared with
  `listen` (:142).

This puts the privacy rule in one place, testable in Node through CR-7's module, and removes
the per-handler checks.

### SI-2 · Important · Reuse · Spec "App" (`CallMachine`): Mute should reuse `.speechEnded`, not hand-code it

**Problem.** "Clears `isSoundOn` (re-arming the silence timer)" re-implements
CallMachine.swift:149-151 and drops its `graceIfQuiet` (CR-5).

The spec also gives "speech ends at Mute" two owners: the page "ends any speech in progress"
and the machine clears `isSoundOn`. These are two different states:

- The page's job is its own: a fresh VAD, pre-roll and hold state (CR-9). `vad.js` has no
  reset, so reuse `listen()`'s setup lines (:123-125) as one helper.
- The machine owns the call's view of speech.

**Fix.**

- In the machine: `case (_, .mute)` sets `isMuted` and returns
  `[.muteMicrophone] + handle(.speechEnded)`.
- Put the `isMuted` guard on `.speechStarted` before both :152 and :183.
- `(.off, _)` (:147) already ignores Mute while off, and `end(with:)` (:266) already clears it
  on Stop. No other code is needed.

### SI-3 · Important · Simplification · Plan Task 1 Step 3: the custom decoder and its test serve a case that cannot occur

**Problem.**

- The app is the only producer of `StatusReply`. Swift decodes it only in the fixture
  round-trip (WireTests.swift:12-22). No older app ever sends the app a status.
- `decodeIfPresent ?? false` and `aStatusWithoutIsMutedReadsAsUnmuted` therefore test dead
  code, and the custom init is what breaks the build (CR-1).
- Tolerance for older apps belongs only in the mod (`isMuted?: boolean`; see CR-3).

**Fix.** Use `public var isMuted = false` and drop the Swift test.

### SI-4 · Minor · Simplification · Plan Tasks 2 and 3: tests that cannot fail

**Problem.**

- `stopClearsTheMute` passes under any implementation that keeps `isMuted` in the machine,
  because `end(with:)` is `self = CallMachine()`.
- `unmuteAttachesOneInput` passes even with no guard at all: `attachInput` always disconnects
  the previous input and stops the previous stream (:97, :102). The hazard the Review Focus
  names, two inputs, cannot happen. The real hazard, a capture while muted, is not asserted.
- `aTrackThatEndsWhileMutedIsNotReacquired` drives an `ended` event that the platform never
  fires for a stopped track.

**Fix.** Replace them with tests that can fail:

- "a device change while muted calls no `getUserMedia`";
- "an acquisition pending at Mute leaves no live track and no input" (SE-1);
- "mute, stop, listen captures again" (CR-8);
- at Bridge level: mute, stop, start → `startListening` with no mute effect after it.

### SI-5 · Minor · Simplification · Spec "Design": optionally collapse the internal pairs

**Problem.** The wire's two explicit, idempotent actions are right and should stay. Inside, the
pairs duplicate one another: `CallEvent.mute`/`.unmute`,
`CallEffect.muteMicrophone`/`.unmuteMicrophone`, `AudioSide.muteMicrophone()`/`unmuteMicrophone()`,
and `BandActions.mute`/`unmute`.

**Fix.** Optionally, one parameterised form each: `CallEffect.microphone(muted:)`,
`AudioSide.setMicrophone(muted:)` and `LB.mute(on)`. The band's button can flip its label as
Start/Stop does (band.tsx:63-67) and call `link.call(isMuted ? 'unmute' : 'mute')`. This
saves about five declarations and their fakes. The current form is acceptable.

### SI-6 · Minor · Efficiency · `audio.js:48-62`: the processor does full work on silence while muted

**Problem.** With the input detached, the processor still fires about 47 times a second:

- each frame is copied, its RMS taken, the VAD pushed and the pre-roll written;
- on an open line, `level` 0 is posted every fourth frame, and the menu bar redraws each one.

The cost is negligible. The pre-roll writes also refill the buffer Mute just emptied with 2 s
of zeros, which the first speech after Unmute then queues and trims.

**Fix.** Optionally, when muted, return from `process` after `output.fill(0)` while still
serving `sending`, and post a single `level` 0 from `mute()`. Do not suspend the
`AudioContext`. A result can open a line while muted, and `makeOffer` (:169-173) needs the
running graph.

### SI-7 · Minor · Efficiency · Bridge.swift:253-260: Unmute holds the band's request until the microphone is back

**Problem.** `send` awaits every effect before `changed()` publishes, and `POST /v1/call`
replies after that. On Unmute, the band and menu therefore keep showing Muted for as long as
`getUserMedia` takes, up to the 10 s deadline (audio.js:19). Start behaves the same today.

**Fix.** Either accept it and say so in the spec, or have `unmuteMicrophone` start the
acquisition without awaiting it, with a failure reported through CR-4's path.

### Simplify findings considered and not taken

- **Drop `speechWhileMutedIsIgnored` and its guard as "cannot occur"** (simplification lens):
  not taken. The event in flight at Mute is exactly CR-9. In `.listening`, an unguarded event
  would open a billed line after Mute, and the page's held queue would then send the speech
  recorded before Mute.
- **Suspend the `AudioContext` while muted** (efficiency lens): not taken, for the reason in
  SI-6.
- **`track.enabled = false` instead of releasing the track** (efficiency lens): not
  recommended. Whether WebKit turns the indicator off for a disabled track is unverified, and
  the spec's "released, not ignored" is the decision the owner made.

---

## security-review

**Scope and threat model.** The page is bundled code served under the app's own scheme. Every
process running as the owner's user is trusted on the socket (SECURITY.md). So the risk here
is not an attacker. It is LiveBridge's own code failing the privacy promise Mute makes.

**The skill's strict filter.** The skill keeps only findings rated ≥ 8 for confidence of
exploitability. Under that filter:

- SE-1 scored 7 (Medium as an exploit, because the window is short and needs no attacker).
- The queued-audio candidate (SE-2) was rated a false positive *as a vulnerability*: the
  audio was spoken before Mute and goes to the voice the owner was addressing.
- The rest are docs or informational.

So the skill's exploit report is empty. The findings below are graded as plan-review defects
against a privacy-critical feature, which is the standard this review was asked to hold.

### SE-1 · Critical · Spec "audio.js", plan Task 3: an acquisition pending at Mute re-takes the microphone while the app shows Muted

**Problem.**

- `attachInput` re-checks only `ctx !== mine` after awaiting `getUserMedia` (audio.js:90-93).
  The planned `mute()` keeps `ctx`, and the planned guards sit only on the two handlers'
  entry.
- `Bridge` is a re-entrant actor that awaits each audio effect (Bridge.swift:253-273). The
  machine is `.listening` before the page holds the microphone, so the band and menu already
  offer Mute in that window.

**Sequences, each reachable by an ordinary owner.**

1. Start, then Mute while `startListening` waits on the native microphone prompt
   (AudioHost.swift:57, 100; it shows at the first Start after every ad hoc-signed update) or
   on `getUserMedia`. `LB.mute()` finds no stream to stop, then `listen`'s attach resolves and
   connects the microphone.
2. Unmute, then Mute again within the acquisition (a misclick, someone walking up).
3. A device-change `reacquire` in flight (a Bluetooth headset switching profile can take
   seconds) when Mute lands.

**Result.** The indicator is back on, the app says Muted, and the next line a result opens
sends live microphone audio to OpenAI (audio.js:58-60). The planned tests cannot see it
(SI-4).

**Fix.**

- Apply SI-1's generation token, checked after every await in `attachInput`, with the new
  tracks stopped when it moved.
- `mute()` bumps the token before anything else. It also records the mute when called before
  `listen` has made `ctx`, so that `listen` starts muted rather than capturing.
- Tests: Start then Mute with acquisition pending → no input and no live track; Unmute then
  Mute with acquisition pending → the same.

### SE-2 · Important · Spec "What the owner sees" and "audio.js": what happens at Mute to audio recorded before Mute is unstated, and partly accidental

**Problem.** Three buffers hold audio from before Mute:

- **The pre-roll (2 s).** The spec empties it. Keep that: without it, an Unmute within 2 s
  followed by speech would open the line with up to 2 s from just before Mute, often the
  start of the very conversation the owner muted for.
- **The `catchUp` queue of a line opening for speech.** It is kept. It goes out once the line
  connects (audio.js:54, 58-60), up to the connect time.
- **The held queue of CR-9.** It is kept by accident.

The first two are defensible either way: the owner's request was spoken before Mute, and
dropping it loses a command. But the spec's line "the owner's speech … does not reach the
voice" reads as covering all of it.

**Fix.**

- Decide and state it. Recommended wording: "speech already said when you press Mute still
  reaches the voice; nothing after it does".
- Implement CR-9's reset for the no-peer case.
- If the owner prefers the strict reading instead, `mute()` also clears `catchUp`, and a line
  connecting for speech closes.

### SE-3 · Important · Spec "Decisions", README: the docs would claim more than the code enforces

**Problem.** AGENTS.md says "Docs never claim more than the code enforces". Two claims break
it:

- **"The indicator is the proof that nobody listens."** That holds one way only: indicator
  off means LiveBridge is not capturing. The Muted label is no proof, as SE-1 shows.
- **"The owner's speech does not … reach the voice."** It is false under SE-1, and ambiguous
  under SE-2.

README's privacy list (:282, :313) is not in Task 5.

**Fix.** After SE-1 and SE-2 are fixed, word the claims as what is enforced: "Muted,
LiveBridge holds no microphone; macOS's indicator shows it." Then add the README lines to
Task 5.

### SE-4 · Minor · AudioHost.swift:183-189: no native check backs the page's mute

**Problem.**

- The media-capture delegate grants every microphone request from the page's own origin and
  main frame. While muted, the page's JS state is the only thing keeping the microphone off.
- That is acceptable, because the page is our own code. It does make SE-1's guard the whole
  enforcement.

**Fix.**

- Optionally add a native check: `AudioHost` remembers the mute and the delegate returns
  `.deny` while muted. Verify by hand that WebKit asks the delegate again rather than reusing
  the earlier grant for the page.
- `WKWebView.setMicrophoneCaptureState` is another candidate, but it may end the track and so
  fire `onended` into `reacquire`. Verify that too.
- Either way, the plan's manual check should include "while muted, plug or unplug a headset:
  the indicator stays off".

### SE-5 · Minor · SECURITY.md:66-74, plan Task 3 Step 5: the local-process list omits Unmute

**Problem.**

- Any process running as the owner, and the band of any joined session, can
  `POST /v1/call {"action":"unmute"}` and undo the owner's Mute with no prompt.
- That is no new privilege, since the list already says such a process can start a call. It
  is, however, a new way around an explicit owner choice.
- Step 5 changes only "the microphone sentence".

**Fix.** Add "unmute a muted call" to the list, and say that Mute protects against being
heard by accident and is not a control against local processes.

### SE-6 · Minor · Spec "Failures": an Unmute after the permission was revoked

**Problem.** Unmute skips `askForMicrophone()` (AudioHost.swift:57). If the owner revoked the
microphone in System Settings while muted, `getUserMedia` rejects. That fails closed, which is
safe, but it is reported only once CR-4 is built.

**Fix.** Cover it in CR-4's test with a `NotAllowedError` → `microphoneDenied` case.

### Security candidates refuted

- **A device change while muted.** Both handlers point at `reacquire`, so one entry check
  covers them. `stop()` fires no `ended`. The only open path is an acquisition already in
  flight, which is SE-1.
- **Anything else restarting the microphone.** Only `.startLocalVAD` calls `startListening`,
  and only `(.off, .start)` emits it. Hang-ups and `.audioFailed` never re-take the
  microphone. The voice has no tool that reaches `/v1/call`.

---

## Declined to judge

- **Button order** (Mute before or after Stop, beside "Talk here"): layout taste, not in the
  spec.
- **A muted mark in the menu bar glyph:** reasonable, but the spec scopes the change to the
  band and the card. The macOS indicator already shows the state.
- **A `/live mute` command or a hotkey:** out of scope by the spec ("No global hotkey for
  now").
- **Billing while muted inside the 120 s result window:** existing behaviour, unchanged by
  Mute.
- **Whether WebKit keeps firing a `ScriptProcessor` with no input:** not verifiable here. With
  SI-2 and CR-9 the design does not depend on it.
