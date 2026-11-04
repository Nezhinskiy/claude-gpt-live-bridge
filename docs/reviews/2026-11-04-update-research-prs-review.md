# Review of PR #25 and PR #26 (2026-11-04)

Two open pull requests into `dev`, reviewed before merge with three skills each:
`superpowers:requesting-code-review` (a reviewer given the diff and the spec),
`simplify` (reuse, simplification, efficiency and altitude, findings only, nothing applied) and
`security-review`. Findings only; nothing was pushed to either branch.

- [getLiveBridge/LiveBridge#26](https://github.com/getLiveBridge/LiveBridge/pull/26)
  `fix/diskutil-image-attach`, head `879f70e`, base `origin/dev` `a680968`.
- [getLiveBridge/LiveBridge#25](https://github.com/getLiveBridge/LiveBridge/pull/25)
  `claude/sad-hamilton-26e35c`, head `47fa2c2`, merge base `e853430` (behind `dev`, merges
  cleanly).

Line numbers are at each PR's head commit.

| PR | Critical | Important | Minor |
| --- | --- | --- | --- |
| #26 | 0 | 2 | 8 |
| #25 | 0 | 3 | 12 |

Verdicts: **#26 with fixes** (settle the one-tool question and pin the real `diskutil` output as a
fixture), **#25 with fixes** (label the ChatGPT-route claims as inferred and use the repo's own
`audio_duration_ms` observation).

---

## PR #26: on macOS 27 the update attaches its image with diskutil

### What was checked by hand

On this Mac (macOS 27.2, 26B123), using a throwaway image built the way `scripts/build-app.sh:184`
builds the release image (`hdiutil create -srcfolder … -format UDZO`), attached in the
scratchpad, never in `/Applications`:

- `diskutil image attach --plist --readOnly --nobrowse --mountPoint <dir>/mount <image>` exits 0
  and prints `system-entities` with `dev-entry`, `content-hint` and, on the APFS volume,
  `mount-point`. These are the keys `UpdateBundleCheck.volume` reads. One difference from
  `hdiutil`: `dev-entry` is `disk10`, not `/dev/disk10`. The image has one mountable entity, so
  `--mountPoint`'s single-entity rule holds.
- `diskutil eject <mount point>` detaches the whole image: after it, `hdiutil info` no longer
  lists the image and the auto-created mount folder is gone.
- A second attach to the same `--mountPoint` while the first volume is still mounted also exits 0
  and **stacks** the new volume on top. `eject <mount point>` then removes only the top one.
- `man diskutil`: "Starting with macOS 13.0, the verb "image" can be used to allow attaching disk
  images". `man hdiutil`: hdiutil defaults to `-noautoopen`. `hdiutil attach` on 27 prints its
  deprecation warning on standard error, which `CodexLaunch.swift:181` sends to `/dev/null` when
  `mergingErrors` is false.
- `swift test --filter UpdaterTests` at `879f70e`, run in a temporary worktree: 53 tests pass.

### superpowers:requesting-code-review

**Important 1: the reason given for the version switch is wrong, and the old path still works.**
`app/Sources/BridgeCore/Update/Updater.swift:284-286`

- The problem:
  - The comment and the commit message say macOS 14 "may have no `diskutil image`". `man diskutil`
    says the `image` verb has existed since macOS 13, so it is present on every macOS the app
    supports. Whether macOS 14 to 26 accept these exact flags (`--readOnly`, `--nobrowse`,
    `--mountPoint`) has not been checked.
  - On 27, `hdiutil attach`/`detach` still work. Their only symptom is a warning on standard
    error, and the updater throws standard error away.
  - So the PR swaps a path that works on the owner's own OS for one that has never run a real
    update, and the owner sees no difference. It also keeps two code paths, two sets of tests and
    two doc caveats.
- Suggested fix: choose one tool and state the real reason.
  - (a) Use `diskutil image attach` everywhere, after a macOS 14 CI runner confirms the flags.
    This is the cleanest end state.
  - (b) Keep `hdiutil` everywhere until Apple removes it, with a one-line note that it is
    deprecated. This is the least risk.
  - Keeping the switch is the weakest option. If it stays, correct the comment to "deprecated from
    27; diskutil's flags on 14 to 26 are untried".

**Important 2: the 27 path is tested only against a fake that was written to agree with the
PR's claim.** `app/Tests/BridgeCoreTests/UpdaterTests.swift:154`

- The problem:
  - `case ("hdiutil", "attach"), ("diskutil", "image")` returns the hdiutil-shaped plist
    (`/dev/disk9`) for both tools, so the new tests prove the argv, not the parse.
  - The real output does match on the keys that matter (checked above), but its `dev-entry` has
    no `/dev/` prefix. The fake does not show that.
  - The PR lists a real in-app update through the new path as not run. The owner is on macOS 27,
    so this is the path the owner's own next update takes. A mismatch there fails as `.noApp`,
    which names the wrong cause. If not even a `dev-entry` is parsed, nothing is ejected.
- Suggested fix:
  - Commit a real `diskutil image attach --plist` output as a fixture and parse it in a pure
    `UpdateBundleCheck.volume` test.
  - Have the fake return that fixture for `diskutil`.
  - Narrow the fake's match to `arguments[1] == "attach"`.
  - Run one real update on 27 before merging. This is moot under fix (b) of Important 1.

**Minor 1: a fixed mount folder stacks onto a stale mount.** `Updater.swift:293`
(`folder.appending(path: "mount")`)

- The problem:
  - The eject's result is ignored (`Updater.swift:306-311`). After a crash between attach and
    eject, or an eject refused because the volume is busy, the volume stays mounted at
    `updates/X.Y.Z/mount`.
  - The next run's `download()` (`:236`) cannot remove that folder. A retry of the same version
    then mounts on top (reproduced above), and its eject removes only the top volume, so mounts
    pile up until reboot.
  - With `-mountrandom` every attach got a fresh folder. It is not a security issue: see the
    security section.
  - The CHANGELOG entry does not mention this change of behaviour.
- Suggested fix: use `mount-\(UUID().uuidString)`, which matches how staged copies are named.

**Minor 2: the version boundary is half-tested.** `UpdaterTests.swift:530-558`

- The problem: the tests use only 15.x (the rig's default) and 27.0, so `>= 16` or `>= 26` would
  pass as well.
- Suggested fix: if the switch stays, add a 26.x case that expects `hdiutil`.

**Minor 3: the spec and overview are out of step.**

- The problem:
  - `docs/specs/2026-11-02-in-app-update-design.md:77,108` still names only
    `hdiutil attach … -noautoopen -mountrandom`. The documentation policy removes superseded prose
    in the same change, unless dated specs count as history; say which.
  - `docs/architecture/overview.md` step 4 ("the image is detached on every path") already
    overstated before this PR: an eject is only attempted when the attach named a target, and a
    failed eject is ignored.
  - The new lines `overview.md:85` (142 characters) and `:367` break the paragraph's wrap.
- Suggested fix:
  - Update or annotate the spec.
  - Say "an eject is attempted on every path".
  - Rewrap both lines.

### simplify

Efficiency: nothing. `osVersion()` is a cheap in-process read, and `checkTimeout` is the same as
before.

**Minor 4: the tool is chosen in three places.** `Updater.swift:286-311`

- The problem: `isDiskutil`, a 16-line tuple ternary, and a second ternary in the `defer`
  (`isDiskutil ? "eject" : "detach"`) must stay in step. The `defer` also assumes the detaching
  binary is the attaching one.
- Suggested fix:
  - If two tools remain, choose once into a small pure value next to `UpdateBundleCheck`, for
    example `ImageTool { program; attach(image:mountIn:) -> [String]; eject(target:) -> [String] }`,
    tested without the rig.
  - Better, Important 1's one tool removes all of it.

**Minor 5: the version comparison is hand-rolled.** `Updater.swift:286`

- The problem: `osVersion().majorVersion >= 27` sits beside
  `UpdateBundleCheck.runs(on:minimum:)` (`UpdateBundleCheck.swift:41`), which `checkBundle`
  already uses.
- Suggested fix: `UpdateBundleCheck.runs(on: environment.osVersion(), minimum: "27")`.

**Minor 6: the new tests copy the existing ones.** `UpdaterTests.swift:532-558`

- The problem:
  - `onMacOS27TheImageIsAttachedWithDiskutil` mirrors
    `theImageIsAttachedReadOnlyWithoutBrowsingOrOpening`.
  - `onMacOS27TheImageIsEjectedOnFailure` mirrors `theImageIsDetachedOnFailure`, including its
    permission-restoring `defer`.
  - The `.filter { $0 != .newerMacOS }` exists only because `BundleFault.apply` hard-codes a
    minimum of 15.2.
- Suggested fix:
  - Parameterize the existing tests over `(os, program, attach arguments, eject verb)`.
  - Have `BundleFault.newerMacOS` set a minimum above the rig's OS.

**Minor 7: names and comments still say hdiutil.**

- The problem:
  - `UpdateBundleCheck.Volume.detachTarget` (`UpdateBundleCheck.swift:10`) and the comment at
    `:14` ("is detached") say "detach" while the type's comment now says "detach or eject".
  - `UpdaterTests.swift:83` still says "the fake `hdiutil attach`".
- Suggested fix: rename to `ejectTarget` (three sites) or reword to "what to release", and fix the
  fake's comment.

**Minor 8: the macOS 27 rule has four homes.**

- The problem: the code comment `Updater.swift:284`, `overview.md:85`, `overview.md:365` and the
  CHANGELOG all state it. This breaks one fact, one home.
- Suggested fix:
  - Keep it in overview step 4 and the CHANGELOG.
  - List only the programs at `overview.md:85`.
  - Keep the code comment to the one fact the code needs.

### security-review

No findings. Every candidate scored below the 8/10 bar, and none reached 5. Concerns examined and
dismissed:

- **Predictable mount path, a planted symlink or folder at `mount`.**
  - `updates/` is under the 0700 data folder (`Paths.swift:49-55`), so only processes running as
    the owner can reach it.
  - SECURITY.md already trusts every process running as the owner; such a process could replace
    `gh` on `PATH`.
  - Defence in depth is slightly lower; no boundary the project claims is crossed.
- **Time-of-check to time-of-use between `checkBundle` and `ditto`.** Closed by the CDHash
  re-check of the staged copy in `settle` (`:352`) and `swapIn` (`:363-364`), plus `codesign`
  again at the swap.
- **Stale or stacked mount.** It can only hold an image that already passed `verifyOrigin`,
  unless a process running as the owner planted it (trusted). The app reads the `mount-point` that
  diskutil reports.
- **Recursive delete of the run folder** (`:150`, `cleanUp` `:199-201`) while still mounted.
  - Not new: `-mountrandom` also mounted inside the folder.
  - The volume is read-only, and symbolic links are unlinked, not followed.
  - Whether Foundation uses `removefile`, which does not cross mounts by default, is unverified.
- **Missing `-noautoopen`.** hdiutil defaults to it anyway, `--nobrowse` hides the volume from
  Finder, and macOS has no autorun.
- **Argument injection.**
  - The argv array goes to `Process` with no shell.
  - `AppVersion` parses strictly (digits only, three parts), so the folder name cannot start with
    `-` or contain `..`.
  - The image and mount paths are absolute.
  - The eject target comes from diskutil's own output.
- **Eject semantics.** `diskutil eject <mount point>` detaches the image device (checked above).
  Neither path forces.
- **Not security, noted.** The eject `defer` is registered only after the `status == 0` guard
  (`:304`), so an attach that attaches the device but fails to mount it leaves the device
  attached. This predates the PR.

### Is the design elegant enough? Is anything redundant?

**Not yet.** The redundant part is the second code path itself:

- `hdiutil` works on 27 with its warning discarded, and `diskutil image` exists from 13.
- One tool in either direction removes the branch, a test variant, a fake case and two doc
  caveats.
- `-noautoopen` was already redundant, since it is hdiutil's default.
- If two paths stay, choosing them once (Minor 4) and parameterizing the tests (Minor 6) is the
  minimum.
- On the diskutil path the app chooses the mount folder itself, so reading the mount point back
  from the output could at least be checked against the folder it asked for.

---

## PR #25: GPT-Live billing research

Every cited codex source line was checked at `ba057e43`, along with the LiveBridge timers
(20 / 90 / 120 s, 800 ms), the arithmetic ($0.017, $0.075, $0.10, $3 an hour) and the quoted
OpenAI sentences. All of them hold. The conclusion holds too: closing after silence saves plan
budget, and a lost cache costs no voice quota. The findings are about labels, scope and
precision, not the answer.

### superpowers:requesting-code-review

**Important 1: the doc overlooks the repo's own evidence on the ChatGPT route.**
`docs/research/2026-11-04-gpt-live-billing.md:44-46,65-72`

- The problem:
  - The doc says a ChatGPT-side "minute" is not documented, that LiveBridge sees "Nothing from
    codex", and that `UsageMeter` is "the best measure the app has".
  - `docs/adr/0001-platform-findings.md:162` records that on this login the data channel reports
    `session.usage.updated` with `usage.audio_duration_ms`. The audio page already owns that
    `oai-events` channel.
  - So a billed duration is probably readable today without codex. The field is
    `audio_duration_ms`, not the API's `usage.seconds`, which bears on the "same meter" inference
    at `:53-54`.
- Suggested fix:
  - Cite ADR 0001 (b).
  - Replace "best measure" with: the data channel reports `audio_duration_ms`; whether that is the
    plan's meter is not documented.
  - Make the follow-up at `:197-198` "log it next to `UsageMeter` and compare".

**Important 2: a price is labelled documented for a product the source does not name.** `:29-33`,
`:48-54`

- The problem:
  - The pricing page prices "Voice in Desktop", meaning ChatGPT Voice in the desktop app. The forum
    reply is about the same app.
  - LiveBridge drives `codex app-server` realtime with `gpt-live-1-codex`. That the same price
    applies is likely (same `backend-api/codex/realtime/calls` endpoint, same family), but it is an
    inference.
  - `:48-54` calls the API's `gpt-live-1` "the same model", but the ids differ and no page links
    them.
- Suggested fix:
  - Label the scope **inferred** and give that evidence.
  - Say "the API model of the same family".

**Important 3: the README and `UsageMeter` state two inferences as fact.**
`README.md:290-293`, `app/Sources/BridgeCore/Call/UsageMeter.swift:4`

- The problem:
  - The README says "OpenAI charges voice to your Codex budget per minute the line is open,
    silence included". The comment says "the plan bills voice per minute open".
  - Both the route (Important 2) and "silence included" on the plan are inferred in the doc's own
    labels (`:53`).
  - AGENTS.md: docs never claim more than is known.
- Suggested fix:
  - README: "OpenAI prices desktop voice per minute of your Codex budget; on the API the same
    family bills silence too ([details](docs/research/…))".
  - Comment: "how the plan meters voice: docs/research/…".

**Minor 1: wrong percentage range, and one explanation missing.** `:56-63`

- The problem:
  - [openai/codex#49405](https://github.com/openai/codex/issues/49405) reports 51 % used, so the
    range is 27 to **49 %** left, not "27 to 45 %".
  - A comment on #49331 points at
    [openai/codex#49322](https://github.com/openai/codex/issues/49322) (usage shown doubled), an
    accounting bug rather than a separate meter.
- Suggested fix: correct the range and add "or an accounting bug (#49322)".

**Minor 2: "no voice field" is too strong.** `:68-70`

- The problem: `account/rateLimits/read` returns `rate_limits_by_limit_id`, an open map
  (`codex-rs/app-server-protocol/src/protocol/v2/account.rs:367-368`). A voice bucket could
  appear there under its own id.
- Suggested fix:
  - Say "no named voice field".
  - Propose reading the map while a line is open as a cheap check.

**Minor 3: "no LiveBridge line that connects lasts under 20 s" is too strong.** `:151-153`

- The problem: Stop, a target switch, `remoteClosed` and `audioFailed` close the line sooner
  (`CallMachine.swift:129,131,154,198`).
- Suggested fix: "no line that ends by the silence timer".

**Minor 4: an inference is labelled documented.** `:121-124`

- The problem: "only a session shorter than 15 s pays for time it did not use" is a reading of
  "credited against duration charges". The source does not say it.
- Suggested fix: label it inferred.

**Minor 5: "at most" is not an upper bound.** `:148`, `:166-167`

- The problem: a result spoken late in the result window re-arms the 20 s silence timer, and each
  new handoff re-arms the window.
- Suggested fix: say "about".

**Minor 6: the cache lifetime is quoted without a source for these models.** `:83-84`

- The problem: the 5 to 10 minute, up to an hour figure is the prompt-caching page's `in_memory`
  value for "earlier models". The page does not say it covers `gpt-realtime*`, and it does not
  apply to LiveBridge.
- Suggested fix: cut it.

**Minor 7: "checks its MCP servers" is imprecise.** `:101`

- The problem: LiveBridge reads `config/read` and starts the thread with every MCP server disabled
  (`RealtimeSession.swift:102-117`).
- Suggested fix: say that.

**Minor 8: the default model can be overridden.** `:20-22`

- The problem: `gpt-live-1-codex` is the default only when the owner's codex config does not set
  `experimental_realtime_ws_model` (`realtime_conversation.rs:1645`).
- Suggested fix: add that clause.

**Minor 9: "billed by the minute of open session".** `:8`

- The problem: the source bills per second, at a per-minute rate.
- Suggested fix: reword.

**Minor 10: the proposed settings copy embeds a price.** `:179-187`

- The problem: "$0.05 a minute" in app copy would be a second home for a price that will drift.
- Suggested fix: "billed per minute open", with a link.

**Minor 11: `docs/research/` has no home in the documentation policy.**

- The problem: `docs/architecture/documentation.md` does not name `docs/research/`. Section 5,
  the recommended defaults, is a design proposal, which in this repo belongs in `docs/specs/` or
  an ADR.
- Suggested fix: either add research notes to the policy, or move section 5 into a spec and link
  to it.

### simplify

**Minor 12: the doc can lose about a third without losing anything.** 200 lines; target about 130.

- The problem:
  - The 15 s creation charge is explained three times (`:121-124`, `:151-153`, `:170-171`).
  - "$3 an hour" appears twice (`:165`, `:192`).
  - The "Uncertainty" paragraph (`:169-173`) restates section 1's not-documented items.
  - Token-billed `gpt-realtime*`, which LiveBridge does not use, gets two passages (`:82-88`,
    `:127-129`).
  - The table's last column repeats the bullets at `:156-161`.
- Suggested fix: keep each of these once.

Reuse, efficiency and altitude: nothing in the README line or the one-line comment.

### security-review

No findings. The change is documentation plus one doc comment.

### Is the design elegant enough? Is anything redundant?

**Mostly.** The structure is good: answer first, every claim labelled documented, source or
inferred, and the timers priced in one table. Two things keep it short of that standard:

- The labels are applied unevenly. The central claim is labelled more strongly than its evidence
  (Important 1 to 3).
- About a third of it repeats itself (Minor 12).

### Not verified

- Whether `gpt-live-1-codex` is metered like `gpt-live-1`, and whether `audio_duration_ms` equals
  the plan's charge: no source either way.
- The help-center article that returned 403 to the author was not retried.
- codex line numbers at `rust-v0.166.0`, other than the two model constants, were not checked.
- The `realtime_context.rs` budget split: it does not matter here, since startup context is off.
