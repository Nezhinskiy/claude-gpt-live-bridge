# Review of PR #72: `--call-stats`, 2026-11-09

PR head `4598f27`, base `dev` at `3b17f01`. All file:line references are at the PR head. Report
only: nothing in the PR was changed.

Skills run against the diff: `superpowers:requesting-code-review`, `simplify` (its four lenses,
findings only, no fixes applied) and `security-review`.

## Verdict

**Merge with fixes. Nothing Critical or High.** The release promise holds, and more strongly than
the PR claims. The only-numbers rule is enforced on both sides. The design is sound. Two Medium
findings should be fixed first: the guide for reading the numbers says more than the numbers can
show, and half of the release guard turns itself off without failing. Neither blocks a release,
and the tool is not going into one.

| # | Severity | Finding | Where |
|---|---|---|---|
| 1 | Medium | The reading guide blames the network for what the server can also cause | `CONTRIBUTING.md:219-222` |
| 2 | Medium | The guard's audio-page check passes when the bundle is not where it looks | `scripts/tests/release-guards.test.sh:37` |
| 3 | Low | "A release build has none of this (guard checks)" says more than the guard checks | `CONTRIBUTING.md:212-213` |
| 4 | Low | "Prints the file's path" holds only from a terminal, and the failure reason goes the same way | `CONTRIBUTING.md:210-211`, `CallStatsRecorder.swift:14,47-49` |
| 5 | Low | The stdout channel costs a shell loop on every `--run` | `scripts/build-app.sh:118-141` |
| 6 | Low | `AudioHost` reaches up to `AppModel` for the flag, unlike `--fake-mic` | `AudioHost.swift:43`, `App.swift:530-533` |
| 7 | Low | The reading guide is written twice | `scripts/build-app.sh:24-26` |
| 8 | Low | `onlyNumbersLeaveThePage` cannot catch a string in a listed field | `CallStatsTests.swift:172-173,190-193` |
| 9 | Low, owner's call | WebKit also reports late-packet discards and round-trip time; neither is recorded | `CallStats.swift:13-17` |

## The four questions

### Does anything reach the release? No.

I built `swift build -c release` for the base and for the PR head at the same path, from clean,
and compared the binaries.

- **Same size (3,594,376 bytes). 196 bytes differ**, all accounted for: `LC_UUID`, the ad hoc code
  signature, and 10 `mov` immediates that are source line numbers (+11 and +6), because `AudioHost.swift`
  grew. The disassembly is otherwise identical line for line (271,168 lines).
- **The audio-page bundle is byte-identical** (`diff -r`).
- `getStats`, `packetsLost`, `callStats`, `CallStats`, `call-stats`, `recordsCallStats`,
  `inbound-rtp`, `concealedSamples`, `jitterBuffer` and `RTCPeerConnection` are absent from the
  binary, and the four main names are also absent from the dSYM, `libBridgeCore.a` and
  `BridgeCore.o`.
- `app/Sources/BridgeCore/Audio/CallStats.swift` is compiled out too: its object file exists but
  holds no trace of the code.

This is stronger than the PR's table and could go in its description. `Package.swift` defines no
`DEBUG`, and `--package-app` builds through the same `swift build -c release`.

**Can the guard fail?** Yes, at every level I tried:

| Mutation | Guard |
|---|---|
| None | exit 0 |
| Only `CallStats.swift` under `#if true` | exit 1, all three names in the binary |
| `CallStats.swift` and `CallStatsRecorder.swift` | exit 1, all three |
| Every block, the PR's own mutation | exit 1, all three |
| `getStats` planted in `audio.js` | exit 1, the audio page |
| `getStats` planted in `audio.js`, bundle renamed, clean build | **exit 0**: finding 2 |

**What it cannot see:** sampling code under other names (the PR says so); the flag string (the PR
says so); a build script that passes `-DDEBUG` only for packaging, because the guard builds on its
own rather than reading `dist/LiveBridge.app`; and a bundle at another path (finding 2).

### Are only numbers written? Yes.

- `CallStats.row` (`CallStats.swift:60-68`) reads only `line` and the listed fields, each through
  `number()` (`:71-74`). A string cannot pass the `NSNumber` cast. Making `number()` accept strings
  turns `onlyTheListedNumbersAreWritten` red, so that side is tested.
- The file name comes only from the clock and the folder is fixed, so nothing from the page reaches
  a path. The security review found nothing at confidence 8 or above.

**The wrap, run for real.** The PR's open item was the injected script against the real page. I
ran the unmodified `AudioHost.swift`, `CallStatsRecorder.swift`, `CallStatsLog` and page script
with the real `audio.js`, in a scratch harness with a fake microphone and a local answering peer:
no codex, no server, no voice.

- **No change to the call.** With the flag on and off, the events and steps matched: offer, answer,
  `session.started`, reopen, stop. The one visible difference is `RTCPeerConnection.name`, now
  empty, which `audio.js` does not read.
- **No timer left running.** The last row of line 1 came at :34.367 and none followed `closePeer`.
  The timer clears on its next tick, at most 1 s later.
- **No peer kept alive.** The interval's closure holds the peer only until that tick, and every
  peer is closed: `makeOffer` calls `dropPeer` before each new one (`audio.js:186,190`), and `stop`
  reaches it through `closePeer` (`audio.js:162,242`).
- **A failing `getStats` cannot end a call.** The page has no `unhandledrejection` or `onerror`
  handler, so a rejection only loses that tick.
- **The hidden window does not throttle it.** Rows came 1.000 to 1.004 s apart over 12 s.
- **The rotation trigger is right.** `.stopLocalVAD` comes only from the three call-end paths
  (`CallMachine.swift:188,190,392`), and a line reopening only calls `closePeer`. Measured: line 1
  and line 2 went into one file, and the second call went into a new file starting at line 3.

### The file

- **Owner-only: effectively yes.** `LiveBridge/`, `debug/` and `call-stats/` were all measured at
  `drwx------`. The CSV itself is `-rw-r--r--`, protected only by its folder. That is fine for a
  folder `Paths.ownerOnlyDirectory` keeps at 0700 and for numbers only; no change needed.
- **One file per call: yes,** as above.
- **Growth: unbounded but negligible.** About 81 bytes a row, so about 0.3 MB an hour. There is no
  rotation or clean-up, and `--uninstall` removes the folder. No change needed.

### Is +515 proportionate, and is the design elegant?

**The design is right; the edges are heavy.** Injecting the wrapper from Swift is the correct hook
because it leaves the shipped page byte-identical. The file is a string in `BridgeCore` because
a resource file would ship, and because `fields` is then one list for both the JS and the CSV. The
double allow-list is not redundant: Swift has to pick the columns anyway. Opening the file on the
first sample removes any need for a call-start signal.

Of the 515 lines, 254 are tests, 181 are the tool itself, and the rest is docs, the guard and
`build-app.sh`. The tool itself is proportionate. What could go, about 75 to 100 lines:

| What | Saves | Note |
|---|---|---|
| Stdout, the `tty` capture and the `set --` loop (finding 5) | ~20 | Keeps `build-app.sh` almost unchanged |
| `recordsCallStats` in `App.swift` (finding 6) | 5 | One touch point fewer |
| Second copy of the reading guide (finding 7) | 3 | |
| One `grep -r` over binary and bundle instead of two `if` blocks | ~5 | Fold in finding 2's check |
| `timeZone` through three signatures and a stored property | ~4 | Tests can parse the time cell |
| Two `ownerOnlyDirectory` calls for one path (`CallStats.swift:90-92`) | 2 | Already inside a 0700 folder |
| `CallStatsTests.swift:60-68`, `:195-198`: assert constants | ~15 | Against "tests check behaviour"; `:67` follows from `:66` |
| `CallStatsTests.swift:126-133`: `endCall` has no way to create a file | 8 | `aDroppedSampleOpensNoFile` covers the real case |
| `CallStatsTests.swift:24-33`, `:52-58`: Foundation, and two tests of one `guard` | ~10 | Keep one of each |

Efficiency: nothing matters at one sample a second in debug builds. A new `ISO8601DateFormatter`
per row (`CallStats.swift:64`) is the only true repeat, and it is not worth a change.

## Findings

### 1. Medium: the reading guide blames the network for what the server can also cause

`CONTRIBUTING.md:219-222`, repeated in `scripts/build-app.sh:24-26` and the PR body.

The guide says concealment or rising jitter "points to the network" and clean numbers "mean the
server or the local audio output". A receiver cannot tell a sender that stalled or paced late from
a network that delayed packets. If the server pauses in mid-sentence, the jitter buffer runs dry and
`concealedSamples` minus `silentConcealedSamples` jumps with zero loss, and RTP jitter rises too.
By this guide that reads as the network, and the "clean" branch has just told the owner it is not
the server.

The loopback shows the shape: with no network at all, the first row of a line had 654 concealed
samples and 0 lost. (That is start-up, so it shows only that concealment does not imply loss.)

This matters because "was it the network?" is the tool's only question, and AGENTS.md says docs
never claim more than the code enforces. A fix that keeps to what is known:

- `packetsLost` jumping points to the network.
- Concealment or jitter without loss means audio arrived late or not at all: the network or the
  server, and these numbers cannot separate them.
- Clean numbers rule out delivery of the incoming audio and leave what the model produced and the
  local audio path.
- Ignore a line's first row: concealment there is start-up.

### 2. Medium: the guard's audio-page check passes when the bundle is not where it looks

`scripts/tests/release-guards.test.sh:37`.

`grep -r` on a missing path exits 2, and `if` reads that as "not found". The binary half guards
against this at `:24`; the bundle half does not. Proved: with the package renamed so the bundle
became `LB_LiveBridge.bundle`, `getStats` planted in `audio.js`, and a clean build, the guard printed
`No such file or directory` and **exited 0**, while the planted call was in the bundle.

The check is what the no-telemetry claim leans on for the page, and bundle paths do move: this
toolchain already places products under `.build/out/Products/Release`. Add a `[ -d "$bundle" ]`
that fails, the same way as `:24`.

### 3. Low: "A release build has none of this (guard checks)"

`CONTRIBUTING.md:212-213`, also `CallStats.swift:1-3`.

The `#if DEBUG` blocks are what remove it; the guard only looks for three names, as the PR body
rightly says. Say so here too, for example "compiled out; `release-guards.test.sh` looks for its
names".

### 4. Low: "prints the file's path" holds only from a terminal

`CONTRIBUTING.md:210-211`, `scripts/build-app.sh:24`, `CallStatsRecorder.swift:14,47-49`.

`scripts/build-app.sh:128` sets `--stdout` only when `tty` succeeds. Without a terminal the file is
still written, but nothing is printed, and `call stats: off, <reason>` goes nowhere, so the doc
comment "Nil, having said why" is not always true. That is the one message that explains an empty
folder. Say "when started from a terminal", or take finding 5.

### 5. Low: the stdout channel costs a shell loop on every `--run`

`scripts/build-app.sh:118-141`, `CallStatsRecorder.swift:47-49`.

The loop is correct (six argument shapes tried, both flag orders). But `set --` rotation with a
manual counter runs on every `--run`, including `scripts/smoke.sh:27`, to print a path the docs
already give.

The app already has a `Logger` (`App.swift:129`), and `CONTRIBUTING.md` already documents `log
stream`. Logging through it (`.public` for the path) removes `say`, the `tty` capture and both
`--stdout` edits, and it fixes finding 4. The cost is that the path no longer appears in the
launching terminal; the newest file in the documented folder is the current call. If the terminal
line must stay, keep the old fixed-order `--fake-mic` block and run the `tty` capture
unconditionally: the usage line already shows that order.

### 6. Low: `AudioHost` reaches up to `AppModel` for the flag

`AudioHost.swift:43`, `App.swift:530-533`.

`--fake-mic` is passed in (`App.swift:108`), but this is `AudioHost`'s only reference to `AppModel`,
so the dependency now runs both ways. Do not add an init parameter, since that puts a value in the
release path. Have `CallStatsRecorder.install` read the flag and return nil without it: everything
stays under `#if DEBUG` and `App.swift` drops out of the diff.

### 7. Low: the reading guide is written twice

`scripts/build-app.sh:24-26` copies `CONTRIBUTING.md:219-222`, then links to it, against "one fact,
one home". Keep the link.

### 8. Low: `onlyNumbersLeaveThePage` cannot catch a string in a listed field

`CallStatsTests.swift:172-173,190-193`.

No listed field in the fixture holds a non-number, so changing `typeof entry[name] === 'number'`
(`CallStats.swift:34`) to `!== 'undefined'` keeps all 24 tests green. Add a listed field with a
string value, such as `packetsReceived: 'secret'`. Swift still drops it, so this is the JS half of a
double check only.

### 9. Low, owner's call: late-packet discards and round-trip time are not recorded

`CallStats.swift:13-17`.

The voice-quality research listed RTT among the numbers to sample, and the PR does not say why it
went. In the same loopback WebKit reports `packetsDiscarded` on `inbound-rtp` (packets that came too
late, a network or pacing sign that `packetsLost` misses) and `currentRoundTripTime` on
`candidate-pair`. Adding `packetsDiscarded` is one word in `fields`. RTT needs a second report type
and may not be worth it. Either is cheap only now.

## Checked, no finding

- **Security:** no finding at confidence 8 or above. Examined and dismissed: report strings reaching
  the CSV, page values reaching a path, CSV injection, other content posting to the handler (the
  navigation lock, `forMainFrameOnly` and the `isMainFrame` check), and the shell changes.
- **`line` is not per call:** it counts peers for the page's life, so a second call's file starts
  at 3 (measured). `CONTRIBUTING.md` does not claim otherwise; only the PR body's "which peer of
  the call" is loose.
- **File-name collision within one second:** a first sample needs at least 1 s of a new peer, so two
  calls cannot share a second.
- **`usage` range:** `4,16` matches the header after the new line.
- **`swift test -c release` would not compile the unguarded test file:** nothing runs it.
- **The `endCall` wiring in `AudioHost.swift:90` has no unit test:** the `LiveBridge` target has no
  tests by design; the harness run above covers it.

## Test mutations

15 mutations of `CallStats.swift`, `swift test --filter CallStats`, baseline 24 passing.

- **13 killed:** the re-check after `await`, the `typeof` check removed, the `kind` and `type`
  checks, `isFinite`, `endCall` as a no-op, `clearInterval`, the closed check, `super(...settings)`,
  the line counter, the interval, the owner-only folder, strings accepted by `number()`.
- **2 survived:** `typeof` weakened to `!== 'undefined'` (finding 8), and removing
  `removedSamplesForAcceleration` from `fields`, which no test pins.

## Run and not run

Run at the PR head: `swift format lint --strict -r app` (exit 0), `swift test` (659 tests pass),
`release-guards.test.sh`.

Not run, and so not verified:

- A real GPT-Live call, as instructed; `scripts/smoke.sh` was not run.
- Behaviour during a real network glitch: the loopback had no loss.
- The packaged, signed or notarized app, beyond the configuration it is built from.
- The rest of `scripts/check.sh` (the mod's checks, the package and notarize tests): the PR touches
  nothing they cover.
- `open --stdout` reaching a real terminal: the harness printed to its own stdout.

## Follow-up outside this PR

In the harness, `LB.listen` called straight after `AudioHost.init` failed with `Can't find variable:
LB`, with the flag on or off, and worked after a 1 s wait. So `didFinish` may arrive before the
page's module has run. It was seen only in a command-line harness, not in the app, and this PR did
not cause it.

## Re-review at a61eb3c, 2026-11-10

Head `a61eb3c`, merge-base with `dev` `334a186` (0.5.0). The PR is now +501 −10 across 7 files,
down from +515 −12 across 8. CI is green (`check`, CodeQL), and GitHub reports it mergeable and
clean. I checked the implementer's reply on the PR against the code, not against the reply.

### Each finding

| # | Reply | At a61eb3c |
|---|---|---|
| 1 | Accepted | **Fixed.** `CONTRIBUTING.md:225-230` names the network only for `packetsLost`; concealment, jitter and discards without loss name "the network or the server"; clean numbers rule out delivery only; `:223` says to ignore a line's first row. |
| 2 | Accepted | **Fixed.** `release-guards.test.sh:32-36` exits 1 on a missing bundle, and `:37-42` searches binary and bundle in one `grep`. Reproduced below: the renamed bundle now exits 1. |
| 3 | Accepted | **Fixed.** `CONTRIBUTING.md:212-213` and `CallStats.swift:1-4`: `#if DEBUG` compiles it out, and the guard looks for its names. |
| 4 | Accepted | **Fixed.** `CONTRIBUTING.md:210-211` and `scripts/build-app.sh:24` say the path prints when started from a terminal; `CallStatsRecorder.swift:14-15` says only a terminal shows the reason. |
| 5 | Partly | **Fixed in what it cost; the rejection holds.** The `set --` loop is gone. `build-app.sh:117-121` is the old fixed-order `--fake-mic` block, which now also keeps any later arguments, and `:122-126` reads `tty` only when `--call-stats` is present. Keeping stdout over `Logger` because the owner reads the path in the launching terminal is a requirement, not a defect. |
| 6 | Accepted | **Fixed.** `CallStatsRecorder.install` (`:16-17`) reads the flag and returns nil without it. `AudioHost.swift:43` calls it unconditionally inside `#if DEBUG`, `AudioHost` no longer names `AppModel`, and `App.swift` is out of the diff. |
| 7 | Accepted | **Fixed.** `build-app.sh:24-25` links to the guide instead of copying it. |
| 8 | Accepted | **Fixed.** The fixture's listed `packetsReceived` is a string. Weakening `typeof` to `!== 'undefined'` now fails `onlyNumbersLeaveThePage` (it survived before). |
| 9 | Partly | **Fixed for discards; the rejection holds for RTT.** `packetsDiscarded` is in `fields`, a test pins its column, and the loopback below wrote it. RTT needs a second report type and was not asked for; adding it after a real call shows the need is reasonable. |

The proportion table:
- The single `ownerOnlyDirectory` call is in. A fresh home showed `debug/` created at 0700 too.
- `theColumnIsWritten` now writes a value through `row`, and dropping `packetsDiscarded` from
  `fields` fails it.
- The `endCall` test that could not fail is gone.

The three rejections hold:
- **`timeZone`:** a fixed zone is what lets the file-name and time-cell tests be exact.
- **Whole numbers and fractions:** these are separate behaviours, since an integer cast would break
  only `jitter`.
- **The once-a-second test:** it pins a stated requirement, and it killed the interval mutation.

### Nothing new reaches the release

I built `swift build -c release` for the merge-base and for `a61eb3c` at one path, from clean.

- The binaries are the same size (3,597,176 bytes), and 196 bytes differ: `LC_UUID`, the ad hoc
  signature, and the same 10 line-number immediates (+11, +6) as before, because the shape of
  `AudioHost.swift` did not change.
- The disassembly is otherwise identical (271,526 lines), and the audio-page bundle is
  byte-identical.
- None of these is in the binary: `getStats`, `packetsLost`, `packetsDiscarded`, `callStats`,
  `CallStats`, `call-stats`, `recordsCallStats`, `inbound-rtp`, `concealedSamples`,
  `jitterBuffer`, `RTCPeerConnection`.
- None of the main names is in the dSYM or `libBridgeCore.a`.

Guard, at `a61eb3c`:

| Mutation | Guard |
|---|---|
| None | exit 0 |
| Only `CallStats.swift`'s `#if DEBUG` set to `#if true` | exit 1, all three names |
| Every directive of the tool set to `#if true` | exit 1, all three names |
| `getStats` planted in `audio.js` | exit 1, the binary or its audio page |
| Bundle renamed, `getStats` planted, clean build | **exit 1**, the bundle is missing (was exit 0) |

A note for anyone repeating this: the new header comment in `CallStats.swift:3` contains the text
`#if DEBUG`, so a first-match substitution hits the comment, not the directive. My first run did,
then failed to compile; the table is from the rerun on the directive lines.

### Tests and the real page

- **Tests:** 16 mutations of `CallStats.swift` against 23 passing tests. 15 were killed, including
  the weakened `typeof` and a dropped `packetsDiscarded`. One survived: dropping
  `removedSamplesForAcceleration` from `fields`, which no test pins and no requirement names.
- **Loopback:** the same harness as before (the unmodified `AudioHost.swift` and
  `CallStatsRecorder.swift` from `a61eb3c`, the real `audio.js`, a fake microphone and a local
  answering peer; no codex, no server, no voice).
  - With the flag off, there was no folder and no file, and the calls ran the same.
  - With the flag on, one file per call: lines 1 and 2 in the first, line 3 in the second. The
    `packetsDiscarded` column was filled, `debug/` and `call-stats/` were 0700, and no row
    followed a close.

### The new commits

- **`a61eb3c` (start the debug build before quitting the installed app): the paragraph holds.**
  - `UnixHTTPServer.start(retryFor:)` retries every 200 ms, and `App.swift:194` passes 10 s.
  - The mod calls `ensureApp` when a poll gets no reply (`register.tsx:268-272`), which opens
    `/Applications/LiveBridge.app` first (`link.ts:165-166`, `register.tsx:552`).
  - `build-app.sh`'s `quit` matches only the debug app's path, so the installed copy is left for
    the owner to quit.
- **`8873bad`, `48ab367`, `8be629e`, `1b266cb`, `14399d1`:** nothing found beyond the rows above.
  `case " $* "` would also match a WAV path spelled `--call-stats`, which is not worth handling.
- **Commit messages:** the six new commits carry no attribution lines.

**Non-blocking, the PR description only.** Three lines no longer match the code, and none is in
the repository:
- It still lists "the three touch points in `AudioHost` and `App`". `App.swift` is out.
- It says "and prints the path" without the terminal condition.
- It says the loopback's `concealedSamples` "stayed 0". The first row of each line had start-up
  concealment.

### Verdict

**Merge.** Every finding is fixed or rejected for a reason that holds. The release binary is
unchanged apart from its UUID, its signature and line numbers. Nothing remains for the
implementer. The three stale lines in the PR description can be corrected at merge.

Still not verified, as in the first round: a real GPT-Live call, numbers during a real network
glitch, and the packaged or notarized app.
