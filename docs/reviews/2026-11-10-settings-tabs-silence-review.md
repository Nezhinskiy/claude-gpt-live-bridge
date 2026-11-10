# Review of PR #80: the line's quiet timers as settings, and Settings in two tabs

PR: getLiveBridge/LiveBridge#80, `feat/settings-tabs-silence` into `dev`, reviewed at head
`ffe146d` (merge-base `cc28336`). Report only: nothing on the PR's branch was changed. File:line
references are to `ffe146d`.

Seats run against the diff:

- `superpowers:requesting-code-review`: one reviewer subagent, with its own mutations in a
  throwaway checkout.
- `simplify`: four agents, for reuse, simplification, efficiency and altitude. This review applies
  none of their fixes.
- `security-review`: one agent. It found nothing at confidence 8 or above, so no false-positive
  filter ran.
- My own pass over the machine, the bridge, the decoder, the docs, the translations, and the
  overlap with PR #79.

I reproduced F1, F3 and the premise of F7 with throwaway probe tests, deleted afterwards. I also
ran 11 mutations (below). No real call ran: no `scripts/smoke.sh`, no voice probe, no
`/Applications`.

`swift test` at the head: 694 tests in 41 suites pass.

Size: `app/Sources` +160 −36, `app/Tests` +81 −4, `docs` +331 −79 (spec, plan, overview, six
translations), README +27 −14, CHANGELOG +11.

## Verdict

**Ready to merge with fixes.** The mechanism is correct:

- one function picks every duration (`CallMachine.armSilence`, `CallMachine.swift:187-191`);
- a 0 cancels the armed timer instead of leaving it to fire;
- `Bridge.arm` replaces a timer, so none is ever doubled;
- the migration is additive and leaves `autoContext` and `loadContextOnFirstCall` as they were;
- the tests kill 10 of 11 mutations.

Two things must change before merge. A first-word wait of 0 keeps every unattended result line
open and billed with no bound (F1). The noise hang-up message still says "90 seconds" (F2).

Three Medium findings are about a change made during a call and about a first-word wait too short
for the voice (F3, F4, F5). F1 and F4 are one design question about the first-word wait, so they
go to the owner together (O1).

## Findings, most severe first

### Important

**F1. With the first-word wait at 0, a line a result opened never closes, and the room's audio
streams to OpenAI until something else ends it.**
`app/Sources/BridgeCore/Call/CallMachine.swift:189-191`, armed at `:257-263`
(`(.connecting, .connected)`).

- How it happens: a result, a question or an approval opens the line (`:240-245`) with
  `isAwaitingFirstWord = true`. At `.connected` the quiet chosen is `timeouts.firstWord`, and at 0
  that gives `.cancelSilenceTimer`. Only `speechStarted`, `assistantSpeaking` or
  `userTranscribed` arm a timer again, and on such a line nobody has spoken yet.
- Reproduced: a probe test with `Timeouts(firstWord: 0)` gave the effects
  `[.problem(nil), .flushPreroll, .cancelSilenceTimer]` at the connect, in phase `live`. No timer
  is left.
- When it happens: these lines open by themselves, usually while the owner is away. The voice
  stays silent on about 4 in 14 of them (README, Known limitations; ADR 0001 (n)).
- Example: the owner sets the first-word wait to 0 so a slow voice is never cut off, and keeps the
  silence at 20 s. Then they hand off a request and leave the desk. The answer reopens the line,
  the voice says nothing, and the line stays open, billed, with the microphone streaming the
  room. It ends only at Stop, a target change, a pausing refusal or OpenAI closing the session,
  and nothing documents when OpenAI does that.
- Why it surprises: the spec says that with all three at 0 the line never closes for quiet. That
  does not tell the owner that one 0 on its own turns the one unattended kind of line into an
  unbounded one, while their ordinary silence still says 20 s. Someone reading "0 switches that
  one off" for the first-word wait would expect the ordinary silence to apply instead.
- Privacy: README's Privacy section (audio goes "while the line is open … until it closes") and
  SECURITY.md stay literally true. But the owner's expectation that a line opened while they are
  away closes in seconds no longer holds, and no caption at this field says so.
- Direction: either a first-word wait of 0 falls back to `timeouts.silence`, or 0 is not offered
  for this field (range 1…300), or 0 shows a warning at the field. Add a machine test for
  whichever is chosen. This is the owner's call: **O1**.

**F2. The noise hang-up message still says "90 seconds".**
`app/Sources/BridgeCore/Call/CallMachine.swift:113-114` (`CallMachine.noise`), shown through
`:325`.

- The text is a constant `Problem`, but the cap it names is now a setting.
- Example: with sound without words at 30 s, the line closes after 30 s, and the menu says the
  microphone heard sound but no words "for 90 seconds".
- AGENTS.md says no claim may go beyond what the code does. This text was true before the PR.
- Direction: build the text from the timeout that elapsed, or drop the number. The table rows
  that compare against `CallMachine.noise` follow either way.
- Found by the reviewer subagent; I confirmed it.

### Medium

**F3. A timer turned back on during a quiet open line does not start, so the line stays open; a
timer turned off while one counts still closes the line.**
`app/Sources/BridgeCore/Bridge.swift:303` (the values are read only inside `send`).

- Reproduced, 0 to 20 (probe test): silence 0, line live, `speechEnded`, then silence set to 20.
  After 300 simulated seconds the call is still `live`. No event came, so nothing armed a timer.
- Reproduced, 20 to 0 (probe test): line live, `speechEnded`, then silence set to 0. At 21 s the
  call is `listening`, closed by the timer armed before the change.
- What the docs say:
  - the caption says "A change applies from the next words" (`SettingsView.swift:79`), and so do
    the README and the six translations;
  - the spec says "A timer already counting is not moved, so a change never cuts the line
    mid-sentence".
  - So both behaviours are documented. That does not make them what someone expects. An owner who
    sees the line stuck open and turns the silence back on expects it to close, and it stays open
    and billed with no bound until the next speech or reply. That is the case that costs money.
    The 20 to 0 case closes one line early, which the next speech reopens.
- Direction: on a change of `timeouts` while live, hand the machine an event that arms the silence
  only when none is armed and the new value is above 0. That never moves a timer already counting,
  so the spec's promise holds, and it needs one test. The caption could also say "applies from the
  next words or reply". Both are fine; the first fixes the billing case.

**F4. A first-word wait of 1 to 3 s cuts off the voice that was about to say the result, and gets
no warning.**
`app/Sources/LiveBridge/SettingsView.swift:65-70`; the spec's "A short first-word wait is normal
… and gets none".

- The wait is counted from `.connected`. Where the voice spoke on a reopened line, it started
  within about 2 s of the connect (README, Known limitations, and ADR 0001 (n): the voice starts
  1 to 2 s after the connect). "Voice finished" lags 0.6 to 2 s, but that does not matter here:
  `assistantSpeaking` ends the wait as soon as the first delta arrives.
- Example: at a wait of 2 s, a voice that starts at 2.3 s is cut off. The result is not lost (it
  chimes and waits), but the owner pays for the reopen and hears nothing, which is the
  "silent first reply" the owner wanted to avoid.
- The two other timers warn from 1 to 9 s. This one has the shortest safe floor and no warning.
- Direction: warn below about 3 s, or set the field's floor there. This is part of **O1**.

**F5. No test reads a saved timer back.**
`app/Tests/BridgeCoreTests/SettingsTests.swift`.

- The reviewer subagent replaced each `decodeIfPresent(...) ?? default` line with the default
  alone, and all 694 tests passed. `changesAreKeptAcrossRestarts` (`:95-110`) sets the voice, the
  notifications and the prompt, but no timer.
- My mutations M4 and M5 (`?? 0`) were killed, but only because the defaults changed. A renamed
  key or a wrong decode would reset the owner's timers to 20, 5 and 90 s on every launch, with
  every test green.
- Direction: one round-trip test: `update` all three to values other than the defaults, then read
  them from a new `SettingsStore`.

### Low

**F6. The decoder takes any `Int`, and a wrong-typed value loses the whole settings file.**
`app/Sources/BridgeCore/Settings.swift:29-30, 79-84`.

- The doc comment says "Settings keeps each in `Timeouts.range`". Only the SwiftUI binding clamps
  (`SettingsView.swift:159`). A hand-edited `-5` behaves as off (`seconds > 0` at
  `CallMachine.swift:191`), and `9999` is kept as it is. The spec says so ("A value is not clamped
  on read"); the comment claims more than that.
- `20.5`, `"30"` or `1e20` throw (reviewer subagent's `JSONDecoder` probe). `SettingsStore.init`
  then falls back to all the defaults, and the next `update` overwrites the file. That loses the
  voice, the prompt and `pauseSyncWhileStopped`, so typed text reaches the voice again. Every
  older field already works this way. The adversary is only the owner's own typo, so this is a
  convenience, not a control.
- Direction: put the clamp next to `Timeouts.range` in BridgeCore, for example
  `Timeouts.clamped`, and use it in both the decoder and the binding. Or decode each timer with
  `try?` and fall back to its default. Or correct the comment.

**F7. A typed negative switches a timer off without a word, and 0 carries no warning at its
field.**
`app/Sources/LiveBridge/SettingsView.swift:155-160, 60-76`.

- "-20" is clamped to 0, which is off, the costly state. Values from 1 to 9 warn; 0 does not.
- README `:336` says "Settings warns below 10 seconds", which includes 0. The code warns only for
  1 to 9 (`(1...9).contains`), so the README claims a warning the code does not show. The same
  holds in the six translations.
- Direction: a note at any field set to 0 that the line stays open there and is billed. Or have the
  README say "from 1 to 9 seconds".

**F8. The README and CHANGELOG say a little more than the code enforces.**

- README `:419-420`: sound without words closes the line "after a longer one". The owner can set
  the noise cap shorter than the silence. "At 0, neither closes it" reads as both at 0, and each
  is set on its own. The translations have the same wording.
- README `:333-334` and CHANGELOG `:13-14`: with all three at 0, the line stays open "until you
  press Stop". It also closes on a target change, a pausing refusal, an audio failure or OpenAI
  closing it. The spec says "until the owner presses Stop, the call ends or OpenAI closes it".
- The first-word caption (`SettingsView.swift:67-68`) says "A line opened by Claude's answer or
  question". An approval notice opens one too (README `:425-427`).

**F9. VoiceOver gets no unit, and two controls share one name.**
`app/Sources/LiveBridge/SettingsView.swift:162-169`.

- The TextField and the Stepper both carry the title as their label, and "s" is
  `accessibilityHidden`. VoiceOver reads "Silence before the line closes, 20", and the unit only
  appears in the caption at the end of the section.
- Direction: give the field an accessibility value of "20 seconds", or put the unit in the title.
  Give the stepper a distinct label.
- Reasoned, not run under VoiceOver. The PR lists keyboard and VoiceOver access as not checked.
  That holds for this review too: neither the debug app nor Full Keyboard Access was run.

**F10. A clamped value may not show in the field.** `SettingsView.swift:155-160`. With 300 stored,
typing 500 writes 300 again, the same value. A value-bound `TextField` on macOS may go on showing
"500" while 300 is in effect. Reasoned, not run. It is on the PR's own "not seen" list.

**F11. Nothing tests the app's wiring of the setting.** Mutation M11 removed
`timeouts: { settings.current.timeouts }` from `App.swift:170`, and it survived: `Bridge` falls
back to `{ .init() }`, so every setting would be silently ignored. The LiveBridge target has no
tests. This matches `pausesSync` and the other closures, so it is not new. A release check by
hand, or making the default parameter required, would catch it. Making it required costs nothing.

**F12. The trail and the spec disagree about status.** `docs/trail.toml` marks the spec and the
plan "in progress", while the spec says "Status: approved". The PR delivers both, so on merge they
should be "delivered" and `docs/roadmap.md` should be regenerated. PR #79 will regenerate the
roadmap again (below).

## Simplify, reuse and altitude (no defects; apply what is cheap)

Ranked by what they save. None changes behaviour.

1. **Three flat fields mirror `Timeouts`.** `Settings.swift:29-54, 79-84`.
   - The same triple appears in four places: the stored fields, the `timeouts:` init parameter,
     the computed `timeouts`, and the decoder's `defaults`.
   - The init parameter has no caller (grep: no `Settings(timeouts:)` anywhere).
   - Cheapest fix: delete the parameter. Fuller fix: store `var timeouts: CallMachine.Timeouts`,
     keeping the flat keys on disk with a custom key mapping. 0.5.0 never shipped these keys, so a
     rename is still free.
   - A fourth timer now touches seven places.
2. **The warning thresholds and the clamp are domain rules living in the view.**
   - `(1...9)` appears twice (`SettingsView.swift:60, 72`); the clamp is at `:159`.
   - Next to `Timeouts.range` in BridgeCore, for example `Timeouts.clamped` and `Timeouts.short`,
     they could be tested without SwiftUI, and the decoder could use the clamp (F6). The codebase
     already clamps by hand in `Menu/LimitRow.swift:34` and `HintPlacement.swift:16`.
3. **`.cancelSilenceTimer` is a new effect for what "arm with nothing" could express.**
   - `CallMachine.swift:86`, `Bridge.swift:335-337`. `armSilenceTimer(seconds: Int?)` with nil for
     "disarm", or a `disarm(_:)` next to `arm`, would avoid a second effect and inline cancel code.
   - This is a judgement call: the explicit case reads clearly, and the 0 → cancel test depends on
     it.
4. **`warning(_:)` duplicates a label written five more times.**
   - `SettingsView.swift:174-177` repeats the `Label(…, systemImage: "exclamationmark.triangle.fill")
     .font(.caption).symbolRenderingMode(.multicolor)` at `:124`, `:132`, `:195` and
     `UpdateSection.swift:64`.
   - The PR moves `:124` and `:132`, so converting them now is cheapest.
5. **`seconds(_:_:)` rebuilds the get/set pair `setting(_:)` already makes**
   (`SettingsView.swift:155-160` against `:141-148`); only the clamp is new.
6. **Three tests in `CallMachineTests.swift:435-446` are one table.**
   - `theSilenceIsTheSetting`, `aLineAResultOpenedWaitsTheSettingForAFirstWord` and
     `soundWithoutWordsIsCappedByTheSetting` could be one `@Test(arguments:)`, like
     `zeroSwitchesATimerOff` beside them.
   - `CallMachine.Timeouts().silence` is built three times in `BridgeTests.swift` as a throwaway
     value.
7. **Efficiency: nothing worth changing.**
   - Reading Settings under a lock on each event costs nanoseconds at tens of events a second.
   - A stepper held down rewrites the roughly 1 KB file about ten times a second. An equality guard
     in `SettingsStore.update` would skip the no-op writes; debouncing is not worth the risk of a
     lost write at quit.
8. **Altitude.**
   - `machine.timeouts = …` before every event leaves public mutable state on a pure machine.
     `handle(_:timeouts:)`, or passing the values only where a timer is armed, would keep it
     value-pure. It is not urgent, and the per-event read is what makes "from the next words"
     true.
   - `settingsTab` on `AppModel` is view state in the model. That is acceptable, because a notice
     must select the tab.

**Is the architecture elegant enough?** Yes, at the core. The rule sits in one place in the pure
machine, `Bridge` only carries out effects, and the closure seam matches its neighbours. What is
redundant is the shape in `Settings` (item 1) and the rules left in the view (item 2). Neither is a
defect.

## Security

Nothing at confidence 8 or above.

- Only the owner's Settings window and the owner's own `settings.json` write the timers. No
  socket route, wire message or mod code touches them, and the PR has no wire change.
- The values go only to `Duration.seconds`, never into a command, a path or a URL.
- The SECURITY.md and README Privacy promises stay literally true. The privacy effect of a 0 is
  under F1.
- The security agent dropped the unclamped decode (score 2) and the 0-keeps-the-mic-streaming
  case (score 3) as owner choices. F1 keeps the second as a design finding.

## Tests can fail: mutations

Run in my review checkout at `ffe146d`. After each run the file was restored and the tree checked
clean.

| # | Mutation | Result |
|---|---|---|
| M1 | silence read as a constant 20 | killed (`theSilenceIsTheSetting`, `aLineClosesAfterTheSilenceSet`, …) |
| M2 | default silence 20 → 25 | killed (`theLineKeepsTodaysTimersByDefault`, transition table) |
| M3 | default first word 5 → 6 | killed (same) |
| M4 | decoded noise default → 0 | killed (`aFileFromBeforeTheTimersKeepsTodaysTimers`) |
| M5 | decoded silence default → 0 | killed (same) |
| M6 | `machine.timeouts = timeouts()` removed | killed (both new Bridge tests) |
| M7 | `.cancelSilenceTimer` does nothing | killed (`aSilenceOfZeroKeepsTheLineOpen`: the noise timer from `speechStarted` fires) |
| M8 | `seconds > 0` → `>= 0` (arms a 0 s timer) | killed |
| M9 | noise cap read as a constant 90 | killed |
| M10 | first word read from the silence | killed |
| M11 | `App.swift` stops passing the setting | **survived** (F11) |

The reviewer subagent added one more survivor: decoding each key as its default alone (F5).

Notes for the implementer:

- My mutation runs edited the shared review checkout while the reviewer subagent was reading it.
  The "silence default 25" it saw there was my M2, not a change on the PR.
- The reviewer saw one unattributed failure in about 20 `swift test` runs, while my builds loaded
  the machine. 19 reruns passed. The two new Bridge tests sleep 50 ms in real time, but in the
  direction of a false pass, not a false failure. So the flake is not shown to be this PR's.

## Nothing lost from the old form

I compared the forms section by section; the reviewer subagent did the same.

- Every control and caption of the old form is in one of the two tabs.
- The old "General" section is now "Login", which avoids a General section inside the General tab.
- The Notifications section split as the spec says.
- `.onAppear`, `.task` and the `didBecomeActive` refresh moved onto the `TabView` and still run
  once per window.
- Both Install paths, the notice and the menu item, go through `installUpdate(_:)`, which selects
  General (`App.swift:317-319`).

Not verified, because the app was not run:

- keyboard and VoiceOver access of the tabs;
- the window's resizing between tabs;
- whether a value typed and left without Enter is kept when the window closes.

## Docs

- README and the six translations: every "20 seconds", "90 seconds" and "5 seconds" of the timers
  is gone. Only the Settings section gives the defaults, which keeps one fact in one home. zh-CN
  is shorter but carries the same changes. Their remaining overclaims are F7 and F8.
- `docs/architecture/overview.md`: true to the code. It says the values are "read before each
  event" and that "a timeout of 0 arming no timer"; strictly, a 0 also cancels the one armed.
- The spec and the plan match the code, with two exceptions. The plan's Task 4 lists a "General"
  section that the code calls "Login". The plan's review focus 3 ("leaves the one counting") has
  no test; nothing moves a timer today, so there is nothing to mutate, but F3's fix would need one.
- CHANGELOG: F8.

## Overlap with PR #79 (Connect over TCP, head `b1f4b2e`)

A trial merge (`git merge-tree` of both heads) gives content conflicts in:

- `app/Sources/BridgeCore/Bridge.swift`: both add a closure to `Bridge.init` at the same place
  (`timeouts:` before `loadsContextOnFirstCall:`, `connectsOverTCP:` after it). Trivial.
- `app/Sources/BridgeCore/Settings.swift`: both add fields, an init parameter and decoder lines at
  the same places. Trivial, but it is the moment to settle simplify item 1.
- `app/Sources/LiveBridge/SettingsView.swift`: #80 rebuilds the form into two tabs, and #79 adds
  its toggle to the old single form's Voice section. The spec puts the toggle in **Voice ▸ Line**,
  so #79's toggle and caption move there by hand, and its `@State cancelledReconnects` / `.id(…)`
  goes with them.
- `app/Tests/BridgeCoreTests/BridgeTests.swift`: both extend `make(...)`'s `Bridge(...)` call.
- `CHANGELOG.md` (both under Unreleased), `docs/roadmap.md` and `docs/trail.toml`: regenerate the
  roadmap with `stayfixed docs trail` after the second merge.

These merge cleanly but still need a look:

- `CallMachine.swift`: #79's `.reconnect` keeps `isAwaitingFirstWord` and re-arms through
  `armSilence()` at the next `.connected`. With F1 unresolved, a result line reconnected with a
  first-word wait of 0 stays open as well. Whatever O1 decides covers both.
- README and translations: #79's bullet lands in the Voice tab's list. Check that it reads as part
  of the Line section and that the "Voice / General" sentence still holds.

**Order: #80 first, once F1 and F2 are fixed.**

- #79 is still under fixes, and its reconnect seam has an open redesign question: its review's F6
  and owner question O1 ask whether to drop the live reconnect or make it one state-keeping step.
  Merging #79 first would make #80 rebase onto a machine that is about to change.
- #80's machine change is confined to `armSilence`, so it does not touch #79's reconnect hunks.
- #80 also creates the Line section #79's toggle belongs in. Then #79 rebases once, moves its
  toggle into Voice ▸ Line and regenerates the trail.

## Questions for the owner

**O1. Что должно значить 0 у «Wait for a first word on a line a result opened», и нужен ли этому
полю нижний предел?**

Пример. Вы ставите это ожидание на 0, чтобы медленный голос не обрывался, а тишину оставляете на
20 с. Затем отдаёте Claude задачу и уходите от стола. Ответ открывает линию, голос молчит (так
бывает примерно в 4 случаях из 14). Сейчас такая линия остаётся открытой, платной и с включённым
микрофоном, пока её не закроет Stop, смена цели или сама OpenAI. Срок, через который OpenAI
закрывает сессию, нигде не записан. При значениях 1–3 с другая беда: голос, который начал бы
говорить через 2,3 с после подключения, обрывается. Предупреждения для этого поля нет.

- **(а) 0 значит «ждать как обычную тишину»** (рекомендую). Линия, открытая результатом,
  закрывается через ваши 20 с, если никто не заговорил. Плюс: ни одна настройка не оставляет
  линию без присмотра открытой навсегда, а «все три на 0» по-прежнему держат линию открытой.
  Минус: 0 у этого поля значит не то же, что у двух других, и это надо одной фразой сказать в
  подписи.
- **(б) Поле от 1 до 300 и предупреждение ниже 3 с.** Плюс: смысл 0 у оставшихся двух полей один.
  Минус: «никогда не закрывать» для такой линии становится недоступным, а вы просили, чтобы при
  трёх нулях линия не закрывалась, как в ChatGPT.
- **(в) Оставить как есть, добавить предупреждение у поля при 0 и при 1–3 с.** Плюс: никакого
  ограничения. Минус: самый дорогой случай включается одной цифрой в поле, которое кажется
  второстепенным.

**O2. Нужно ли, чтобы включённый обратно таймер сразу начинал отсчёт на тихой открытой линии
(F3)?**

Сейчас изменение действует «со следующих слов». Если вы поставили тишину на 0, увидели, что линия
висит, вернули 20 с и ушли, линия так и останется открытой, пока кто-нибудь не заговорит.
Рекомендую да: отсчёт начинается с момента изменения, только если сейчас ничего не отсчитывается.
Уже идущий таймер это не сдвигает, так что фраза из спецификации «изменение никогда не обрывает
линию посреди фразы» остаётся верной. Цена: одно событие и один тест.
