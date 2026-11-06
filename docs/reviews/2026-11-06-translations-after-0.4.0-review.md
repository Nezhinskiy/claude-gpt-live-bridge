# Review: PR 46, translations after 0.4.0

Reviewed [PR 46](https://github.com/getLiveBridge/LiveBridge/pull/46), head `d278249`, base `dev`
at `21c170f`. Report only; nothing in the PR was changed. The Ukrainian and Spanish were read by a
model, not a native speaker.

**Verdict: fix first.** One line, outside the diff: the Ukrainian usage-limit bullet the PR left
open. All five changed lines are good and can stay as they are.

## The five changed lines

Each was read against `README.md` on the PR branch. None promises more than the English, and none
loses a limit.

| Line | Before → after | English | Result |
| --- | --- | --- | --- |
| `README.es.md:468` | `tus propias sesiones` → `tus propios inicios de sesión` | `README.md:438` "under your own logins" | Right. "Sesiones" read as Claude Code sessions; these are the `gh` and `claude` logins. Matches the file's own "inicio de sesión" (line 28). |
| `README.uk.md:410` | `ваша мова й мова голосу` → `ваші слова й слова голосу` | `README.md:393` "your speech and the voice's" | Right. "Мова" also means language, so the old line could read as "your language and the voice's". "Слова" is a little looser than "speech"; see note 1. |
| `README.uk.md:459` | `лічильник хвилин` → `лічильник використання` | `README.md:441` "the usage meter" | Right. Both are true of the code: `UsageMeter` keeps open intervals in `usage.json`, and minutes are derived. Promises nothing new. |
| `README.uk.md:520` | `Запит` → `Промпт` | `README.md:497` "A prompt" | Right, and worth having. The file uses "запит" for a voice request, a different thing, 62 lines mention it, and this bullet is about what is not one. |
| `README.uk.md:523` | `запити` → `промпти` | `README.md:500` "which prompts count as yours" | Right. Same term as line 520, so the bullet reads as one thing. |

## The open question: "lines that fail"

`README.uk.md:513` reads "щоб мовлення не відкривало ліній, які не відкриються", so speech does not
open lines that will not open. `README.md:491` says "so speech does not open lines that fail".

**It needs changing, for two reasons.**

1. It contradicts itself: it speaks of opening lines that will not open.
2. It is narrower than the English and the code. A refused line does not always fail to open. The
   service's usage gate can speak after `session.started`
   (`app/Sources/LiveBridge/Resources/audio/audio.js:213`), and `CallMachine` pauses the call for a
   live line as well as a connecting one (`app/Sources/BridgeCore/Call/CallMachine.swift:240-242`).
   The research note marks a 429 at open only as "the likely shape"
   ([limits](../research/2026-11-05-gpt-live-limits.md)), so the fact that "fail" leaves open is
   stated as settled.

Replace the clause with:

> щоб мовлення не відкривало ліній, які дають збій

"Дають збій" is plain "fail" and says nothing about when. It is the only change the line needs; the
rest of the bullet matches the English, limit detection and `transport_closed` case included.
Spanish ("líneas que fallan"), French ("lignes qui échouent") and Hindi keep the English sense.

## Is anything redundant?

No. Five lines, five separate wordings, nothing duplicated. Lines 520 and 523 look alike but are
the same term in one bullet, and leaving either would mix "запит" and "промпт". The meter line
(`README.uk.md:459`) fixes no ambiguity and is the most skippable of the five, but it matches the
English, Spanish, Hindi and Chinese, so keep it.

## The other two skills

- **`simplify`:** no code, so nothing for its reuse, efficiency or altitude angles. Its four agents
  were not started and nothing was applied, as this review is report only.
- **`security-review`:** no findings. Its template saw an empty diff, because this branch sits on
  `21c170f`, so it was run on the PR diff instead. No link, path, command or identifier changed, and
  the added lines are NFC with no invisible characters or mixed-alphabet words. Markdown is excluded
  from that skill, so this is a mechanical check, not a security reading of the text.
- **`superpowers:requesting-code-review`:** done here without a subagent, scaled to five lines as
  the brief asked.

## Notes that do not block

1. `README.uk.md:410`: "ваші слова" is the phrase the file also uses for what is recorded as yours
   at line 521. "Сказане вами й голосом" would be closer to "speech" and echoes "сказане" at line
   402. Optional; the disclosure holds either way.
2. The PR body says the four Ukrainian lines "name the prompt, the usage meter and the logins". They
   name speech, the meter and the prompt twice; the logins line is the Spanish one. The commit title
   leaves speech out too. Correct the body when the fix goes in.
3. Three of the changed lines are 100 to 102 characters. Nothing checks this, and these files
   already have longer ones.
4. CI's `check` was still pending at the time of writing; it needs to be green before merge.

## Outside this PR

`README.ru.md` still has the three wordings this review or the PR changes in Ukrainian: "счётчик
минут" (line 461), "Запрос, набранный не в композере" (line 521) and "которые не откроются" (line
514). The last has the same two problems as the Ukrainian, so it is worth the same fix.
`README.es.md:420` renders "your speech" as "tu voz y la de la voz", which can read as the audio
rather than the words; it was not checked further.
