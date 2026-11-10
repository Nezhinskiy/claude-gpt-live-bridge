# Review of PR #79: connect the voice over TCP

PR: getLiveBridge/LiveBridge#79, `feat/voice-transport-setting` into `dev`, reviewed at head
`20ab56e` (merge-base `fef553b`). Report only: nothing on the PR's branch was changed.

Seats run against the diff: `superpowers:requesting-code-review` (one reviewer subagent, with
probes and 14 mutations in a throwaway checkout), `simplify` (reuse, simplification, efficiency
and altitude agents), `security-review` (one agent; it found nothing, so no false-positive
filtering was needed), plus my own pass over `AnswerSDP`, the docs and the overlap with the
settings-tabs work. I reproduced F1's premise, F2 and F4 myself (below). No real call ran: no
`scripts/smoke.sh`, no voice probe.

Size of the change: `app/Sources` +96 −6, `app/Tests` +134 −2, `docs` +140 −2, README +7,
CHANGELOG +7.

## Verdict

**With fixes.** The SDP rewrite, the setting, its default and its migration are correct and
tested. The live reconnect is not: three defects (F1, F2, F4) and three smaller ones (F7, F8, F10)
all come from one seam, the reconnect borrowing `hangUp()` and the "a result opened this line"
path. That is past the redesign trigger, so the fix is a decision on the seam (F6), not three
patches. The docs also state as fact what the code only prefers (F3).

## Findings, most severe first

### Important

**F1. A Stop or a target change during the reconnect's close still opens a new line.**
`app/Sources/BridgeCore/Call/CallMachine.swift:303-308`, run by
`app/Sources/BridgeCore/Bridge.swift:307-325`.
- `[.closeRealtime, .openRealtimeForResult]` is the only effect list in the machine that opens
  a line after closing one (I grepped: `openRealtime` is returned at :222, :229 and :308 only, and
  only :308 follows a close).
- `send` runs effects one by one with awaits between them: `.closeRealtime` awaits
  `audio.closePeer()` and `realtime?.close()`. The actor is reentrant, so another `send` can run
  in that gap. `startOpening`/`attempt` (`Bridge.swift:157-165`, `:413-416`) never check the
  phase before opening.
- Scenario (the reviewer's probe, holding `FakeAudio.closePeer`): `perform(.stop)` in the gap
  ends in phase `.off` with `voice.opens == 2`. Stop's `.endCodex` has already retired codex, so
  the open launches codex again and can open a billed realtime session with the call off. With
  `setTarget(b)` in the gap: phase `.listening`, `opens == 2`, `closes == 2`, a realtime session
  left open and uncounted until the next speech or Stop (`(.listening, .connected)` falls to
  `default: []`).
- Who triggers it: the owner, or `followTarget` calling `perform(.stop)` when a session leaves.
  The gap is one page call plus one codex round trip (codex's timeout is 20 s).
- No test covers a reconnect racing another event.

**F2. A reconnect forgets the results the line was waiting for; the reopened line closes at the
first silence.** `CallMachine.swift:305` (`_ = hangUp()` empties `awaited`, `:375`) with
`isAwaitingFirstWord = true` at `:307`.
- Reproduced (throwaway test, deleted): after `[.start, .speechStarted, .connected,
  .speechEnded, .handedOff(a)]`, `.silenceElapsed` gives `[]` and the line stays `live`. The same
  events followed by `.reconnect, .connected` give `[.closeRealtime]` and phase `listening`.
- So: the owner hands off a request ("On it"), the voice breaks up, they switch to TCP and
  choose Reconnect. The new line closes after 5 s of quiet. A result arriving inside those 5 s
  is given as context, not spoken (reviewer's probe). One arriving later reopens a line only if
  it is the target's; one routed through a question only chimes.
- The spec (`docs/specs/2026-11-10-voice-transport-design.md:35-38`) and the code comment at
  `:304` say what was not heard goes to the new line. That holds for a result that already
  arrived (`unheard` survives), not for one still awaited.
- Mutation M5 (delete `_ = hangUp()`) turns no test red: none of the resets is pinned for a
  reconnect.

**F3. The docs and the UI state as fact what the code only prefers.** AGENTS.md: docs never
claim more than the code enforces.
- "no audio is lost": `README.md:326-329`, `CHANGELOG.md:11-14`,
  `app/Sources/LiveBridge/SettingsView.swift:37-38`,
  `app/Sources/BridgeCore/Menu/Confirmation.swift:33-36`, spec `:27`, and the six translations
  (`docs/i18n/README.{es,fr,hi,ru,uk,zh-CN}.md`, Settings bullet).
  - The 0-of-28,213 figure is from the experiment that **removed** the UDP candidates. The
    shipped mechanism, lowering their priority, was seen once to pick TCP (`onTcp` = 1,
    2026-11-10) and has no loss figure at all. The spec's own "Not verified" section says so.
  - The code keeps UDP as a fallback, leaves an answer with no TCP candidate as it came, and
    shows nobody which transport was taken (F5). A line that fell back to UDP still breaks up.
  - Even on TCP, "no audio is lost" is a model of the network: a packet that arrives later than
    the jitter buffer can wait is still discarded (`packetsDiscarded`, which PR #72 records).
- "over TCP port 443 instead of UDP": `README.md:484-485` and the Privacy paragraph in each
  translation (`es:485`, `fr:506`, `hi:460`, `ru:472`, `uk:471`, `zh-CN:269`). The code prefers
  TCP; it does not force it. And it never checks the port: 443 is what the server's answer
  listed on 2026-11-09, not something LiveBridge chooses.
- Wording that matches the code: the line *prefers* the TCP candidates the media server offers
  (port 443 in the answers seen) and can still fall back to UDP; on a lossy connection that
  usually trades breakups for short pauses (as measured once, in a debug experiment).

**F6. Architecture: the reconnect is a special case on the machine, and it is where every
defect in this review sits.** F1, F2, F4, F7, F8 and F10 come from one seam:
`(.connecting|.live, .reconnect)` borrows `hangUp()` (built for "the line ends") and
`.openRealtimeForResult` / `isAwaitingFirstWord` (built for "a result arrived and opened this
line", `CallMachine.swift:79-84`, `:155-157`), although nothing arrived and the call goes on.
Patching each symptom would add a phase check here, a kept `awaited` there, a withdraw
exception, a growing-line reset and a pre-roll rule. Two designs end the class instead; which one
is the owner's call (question O1):
- **(a) Drop live reconnect; the next line takes the setting.** Deletes `CallEvent.reconnect`,
  `Bridge.reconnect()`, `Confirmation.reconnect`, the `Bool` return of `setConnectsOverTCP`, the
  `cancelledReconnects` counter and `.id` redraw, five table rows and two Bridge tests. Cost: an
  owner whose line is breaking up waits for it to close (20 s of quiet) or presses Stop and
  Start. The caption can say exactly that.
- **(b) Keep it, as a transition that keeps the call's state.** A reconnect only swaps the
  transport: `awaited`, `unheard`, `isSoundOn`, the silence state and the first-word state stay
  as they were, and the machine emits one effect (say `.reopenRealtime`) that `Bridge` runs as
  one step: cancel, close, then open only if the phase is still `.connecting` at that moment.
  That closes F1 at its root (no window between two effects) and F2/F4/F8 by not resetting
  state. Cost: a new effect and a transition whose tests must pin each kept field.
- The settings-tabs work (below) makes the first-word wait configurable, including 0 (off);
  either design should be settled before that lands on the same lines.

### Medium

**F4. Any withdraw closes a reconnected line while it connects, even one that removes nothing.**
`CallMachine.swift:326` (`guard phase == .connecting, isAwaitingFirstWord, unheard.isEmpty`).
- Reproduced: after `[.start, .speechStarted, .connected, .speechEnded, .reconnect]`,
  `withdraw { _ in false }` returns `[.closeRealtime]` and leaves the phase `listening`.
- Callers include an answered approval prompt in another session (`Bridge.swift:709`) and a
  session leaving (`:566-569`). With nothing pending there is no chime: the reconnected line just
  goes away.

**F5. Nothing can tell whether a line took TCP, so the setting can fail silently, and the spec's
check cannot catch it.** Spec "Not verified", first item.
- The shipped check is one call with `--call-stats`, reading loss. Low loss does not show TCP
  was chosen (the network may simply be good that minute); high loss does not show UDP was. The
  experiment's `onTcp` column (from the `transport` stats' selected pair) was the one sensor that
  worked; the spec says it would have to be added again.
- PR #72 is merged on `dev` now. A debug-only `onTcp` (or `localProtocol`) column in
  `CallStats` keeps the no-telemetry promise (the `#if DEBUG` and release guard already cover the
  file) and turns the first "Not verified" item into a reading instead of an inference.
- Not verified, a hypothesis to watch in that column: ICE keeps checking the lower pairs after
  it selects one, and an ICE agent switches away from a selected pair that stops receiving. TCP
  under heavy loss can stall long enough for that, so a call may move to UDP mid-way and back.
  The owner would hear breakups return with the switch on.

### Low

**F7. The cut-off sentence merges with the new line's first words in the menu.**
`Bridge.swift:797`: `growing` is cleared only when no line is open, and a reconnect goes from
live to connecting. Reviewer's probe: the menu showed `["The build is half Hello again"]`. Not
reproduced by me.

**F8. A reconnect during a speech-opened connect drops the owner's opening words and shortens
the next silence.** `CallMachine.swift:303`: `closePeer` clears the pre-roll, the reopen is
`makeOffer(false)`, and `isAwaitingFirstWord = true` although the owner is speaking; after
`speechEnded` the timer is 5 s, not 20 s (reviewer's probe). Rare: the switch must flip inside
the 1-3 s connect.

**F9. Some guards in `AnswerSDP` can be removed with every test green.**
`app/Tests/BridgeCoreTests/AnswerSDPTests.swift:46-52`. My mutations on
`app/Sources/BridgeCore/Audio/AnswerSDP.swift:22-25`:

| Mutation | Result |
|---|---|
| drop the numeric-priority check | red (`leavesEveryOtherLineUntouched`) |
| match the transport case-sensitively | red (`readsTheTransportInAnyCase`) |
| drop the no-TCP guard | red (`leavesAnAnswerWithoutTCPUntouched`) |
| guard on a UDP candidate instead of TCP | red (same test) |
| `fields[0].hasPrefix("a=candidate:")` → `true` | **green** |
| `fields.count > 3` → `> 2` | **green**, and the code would trap on `a=candidate:9 1 udp\n` |

- The line `a=x-note udp 5 udp` was meant to pin the prefix check, but its third field is `5`,
  so it never reaches it; a line like `a=x-note 1 udp 5` would.
- `a=candidate:9 1 udp` is only tested with `\r\n` endings, where its last field is `udp\r` and
  fails the transport compare first; the count guard is never what stops it. The same line in
  the `\n` test would pin it.
- The PR description's "mutations were run by hand" lists three; these two were not among them.

**F10. No Bridge test reconnects while an open is in flight** (cancelling `connecting`, the
stale attempt's `Task.checkCancellation`). The reviewer's table: M3, M4, M9 are caught by
`reconnectReopensTheOpenLineOverTheNewTransport`, which starts from a live line only.

**F11. `Confirm`'s doc comment is stale.** `app/Sources/LiveBridge/Confirm.swift:4-5` says the
alert comes before "the menu's items erase a conversation" and that "the menu has closed by
then". It is now also raised from the Settings window, for an action that erases nothing, with
Reconnect drawn as the destructive button.

**F12. The unverified items are not in the README's known limitations.** `README.md:524`.
AGENTS.md makes that list the home of open items; the three "Not verified" items live only in
the spec and the PR body. Once F3's wording says "prefers", one bullet suffices: the TCP path is
measured on one debug call, and nothing shows which transport a line took.

**F13. Copy written twice, and the spec's caption differs from the shipped one.** The trade-off
sentence is in both `SettingsView.swift:37-38` and `Confirmation.swift:33-36`; the spec's caption
(`:25-27`) ends "so speech comes through more clearly", which only the confirmation says. The
confirmation can say what happens ("closes now and opens again over TCP") and leave the
trade-off to the caption.

**F14. Small simplifications** (simplify seats; none changes behaviour):
- `AnswerSDP` and `preferringTCP` are `public` but used only by `Bridge` in the same module
  (`AnswerSDP.swift:2`, `:11`); tests use `@testable`.
- The reconnect case re-spells the open sequence of `(.listening, .deliver)` at `:225-229`
  (`phase = .connecting`, `isAwaitingFirstWord = true`, `[.openRealtimeForResult]`). Moot under
  F6.
- `FakeVoice` gets a property `answer` and a method `answer(with:)` of the same name
  (`BridgeTests.swift:29-30`); the other knobs are assigned or toggled by a verb.
- Efficiency: nothing material. The SDP is split twice per line open (a few KB, microseconds);
  `settings.current` is an in-memory copy under a lock, not disk.

**F15. Informational, no change asked.**
- Any TCP candidate enables the rewrite, including `tcptype active` or `so`, which WebKit, as
  the dialling side, cannot pair with. UDP is then lowered for nothing, but still connects.
- All UDP candidates get the same priority 1000, so their order among themselves is arbitrary;
  the experiment's answer had four and WebKit accepted them.

## The SDP rewrite, case by case

`AnswerSDP.preferringTCP` (`AnswerSDP.swift:11-26`) splits on `\n` and on single spaces and joins
back with the same separators, which round-trips any string exactly; only field 3 of a matching
line is replaced. Checked:

| Input | Result |
|---|---|
| host, srflx, relay UDP candidates | all lowered: the transport is field 2, `typ` is not read (WebKit has no `iceServers`, so no relay pairs are possible on its side) |
| `tcptype passive` / `active` / `so` | untouched; any of them enables the rewrite (F15) |
| IPv6 or mDNS `.local` address | untouched: the address is field 4 |
| `UDP` in any case | lowered (tested) |
| `\r\n` endings | kept: the `\r` stays in the last field, never the priority |
| a truncated or non-numeric candidate line | untouched (count and `UInt32` checks; F9 on their tests) |
| no candidates, or TCP only | returned with the same bytes |
| no TCP candidate | returned as it came (`return sdp`, tested) |
| several `m=` sections, `a=end-of-candidates` | candidate lines in each are handled alike; other lines untouched |

Can it produce an SDP WebKit or OpenAI rejects? OpenAI never sees it: the rewritten answer goes
only to the page's `setRemoteDescription`, and changing a remote description's candidate
priorities is accepted by WebKit (the 2026-11-10 experiment did exactly this). The priority stays
a valid `UInt32`, and the line count and grammar are unchanged. Can it fall back without the owner
knowing? Yes, by design, and that is F3 and F5.

## Bridge, CallMachine, Settings, Confirmation

- **Default UDP:** `Settings.connectsOverTCP` defaults to `false` (`Settings.swift:36`), the
  decoder reads a missing key as `false` (`:69`), and `Bridge`'s init defaults the closure to
  `{ false }`. Tested (`tcpIsOffUntilTurnedOn`, including an older file).
- **Changing the setting with no line:** saved; the next line reads it right before
  `applyAnswer` (`Bridge.swift:456`). Correct, tested both ways.
- **Changing it during a line:** the window asks only if its last status shows connecting or
  live (`App.swift:354-360`); the bridge reconnects only a line still open
  (`reconnectWithNoLineOpensNone`, two table rows). A stale status the other way (a line that
  opened a moment ago) saves the setting without asking, and that line keeps its transport until
  it closes; the spec accepts this as "a courtesy, not a control", which is the right framing.
  The reconnect itself has F1, F2, F4, F7, F8.
- **The old line's late events:** cannot reach the new line: `RealtimeSession.close` drops the
  line, and notifications for another thread are ignored (reviewer, by reading).
- **Confirmation:** follows the existing `Confirmation` shape and `Confirm.ask`; F11 and F13.
  `NSAlert.runModal` from a `Binding` setter and the `.id(cancelledReconnects)` redraw look
  sound by reading but are unverified without the UI, as the PR says.

## Spec against code

The spec matches the code, with these exceptions: the caption wording (F13); "a result the line
was waiting for stays unheard and goes to the new line" (F2, true only for arrived results); and
its first verification step cannot show the transport (F5). Its "Not verified" section is
honest and should keep saying the TCP path is measured once, in a debug experiment, with the
other mechanism (removal).

## Privacy and security

No vulnerability found. What changes on the network: with the switch on, WebKit prefers the
TCP candidates the media server already listed, so the audio, still DTLS-SRTP-encrypted, may run
over TCP to the same host instead of UDP.
- No new destination: the candidates come from the server's own answer.
- No listening port: the offer is built before the answer is touched and is unchanged, and the
  server's candidates are `tcptype passive`, so the Mac dials out.
- No injection: the SDP reaches the page as a named argument of `callAsyncJavaScript`
  (`AudioHost.swift:113`, `:146`), and the rewrite only ever writes the constant `1000` into a
  field that was already numeric.
- No new logging or telemetry; the setting is stored only in `settings.json`.

**SECURITY.md needs no line.** It sends the reader to the README's Privacy section for what goes
to OpenAI, and nothing it states changes. The fix belongs in that README paragraph (F3).

## Overlap with the settings-tabs work

The settings-tabs session (worktree `.claude/worktrees/settings-tabs`, spec
`docs/specs/2026-11-10-settings-tabs-and-silence-design.md` and plan
`docs/plans/2026-11-10-settings-tabs-and-silence.md`, both uncommitted there) will touch the same
lines:

| File | PR #79 | Settings tabs | Conflict |
|---|---|---|---|
| `Settings.swift` | property, init parameter and decode line before `checkUpdatesAutomatically` | the three timeouts in the same three places | textual, trivial |
| `SettingsView.swift` | toggle, caption, `@State cancelledReconnects` and `.id` in `Section("Voice")`; the type's doc comment | the body becomes a `TabView`; the spec puts the UDP/TCP choice in the Voice tab's **Line** section | certain; the toggle, its counter and its `.id` must move together |
| `Bridge.swift` init, `App.swift:169`, `BridgeTests` `make` | `connectsOverTCP:` closure parameter | `timeouts:` closure parameter on the same signature and call sites | textual, same lines |
| `CallMachine.swift`, `CallMachineTests` table | the reconnect sets `isAwaitingFirstWord`; five rows at the table's end | `firstWordSeconds` becomes a setting, 0 = off; rows at the table's end | textual at the table; semantic: under 0 the reconnected line's first-word close must also be off, and F6's choice changes what a reconnect arms |
| README Settings section, six translations, CHANGELOG Unreleased | a Settings bullet; "in Settings under Voice" | the two tabs and three fields | textual; "under Voice" becomes ambiguous (tab and section) |
| `docs/trail.toml`, `docs/roadmap.md` | a line appended; roadmap regenerated | the same | regenerate with `stayfixed docs trail`, never merge by hand |

Whichever lands second rebases. Landing PR #79 first (after F6 is decided) lets the tabs change
move one finished toggle into **Line**, which its spec already expects.

## Questions for the owner

**O1.** Сейчас при переключении Connect over TCP во время разговора линия сразу закрывается и
открывается заново. Именно на этом месте все найденные ошибки: Stop в этот момент открывает новую
линию, а новая линия забывает ожидаемые ответы и закрывается через 5 секунд тишины. Есть два пути:
(а) убрать переподключение. Настройка тогда действует со следующей линии, и это минус около
десяти мест в коде и тестах, но с рвущейся линией придётся нажать Stop и Start. (б) Оставить
переподключение, но сделать его «сменой транспорта», которая сохраняет состояние звонка и
выполняется одним шагом. Какой путь выбрать?

## Declined to judge

- Whether priority 1000 makes WebKit pick TCP in general, and whether the UDP fallback works:
  these need real calls, and the spec already lists them.
- The 5 s first-word close after a reconnect with nothing awaited: the spec chose it; flagged
  only where it meets F2.
- Races older than this PR on the `conversationChanged` path (a buffered handoff from the old
  controller, a doubled codex launch when an open still launching codex is cancelled).
- Automatic transport choice (default TCP, or switching on measured loss): raised by the
  altitude seat, but auto-detection needs `getStats` in a release build, which the no-telemetry
  promise rules out, and default TCP is the owner's settled "UDP stays the default".
