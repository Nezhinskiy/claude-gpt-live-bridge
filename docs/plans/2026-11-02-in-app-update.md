# In-app Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.
>
> **Dispatch unit: the wave, not the task.** One implementer per lettered wave (A–E), working
> its tasks in order; each task keeps its own failing test, verification and commit. Launch
> waves along the graph below; a wave starts only when every wave it consumes is merged into the
> branch.

**Goal:** Settings shows the version and a Check for update button; on the owner's click the app
downloads the latest release, proves its origin with `gh`, updates the mod, swaps itself in
`/Applications` and relaunches; a daily background check only announces.

**Architecture:** Pure rules in `BridgeCore/Update/` (versions, the GitHub reply, the policy,
the persisted record and state) and one `Updater` actor that runs every step through an
`UpdateEnvironment` protocol, faked in tests; `SystemUpdateEnvironment` in `LiveBridge` is the
real one. Small changes to existing code: `CodexLaunch.locate` takes a program name,
`SessionRegistry` reports open requests, the socket bind retries, the build script marks source
builds, the marketplace pins the mod to the release tag.

**Tech Stack:** Swift 6 (SwiftPM, Swift Testing), AppKit/SwiftUI, Foundation `URLSession`,
CryptoKit (SHA-256), Darwin `renamex_np`; shell scripts; Markdown docs.

**Spec:** `docs/specs/2026-11-02-in-app-update-design.md` (read it first; this plan does not
repeat its reasons).

## Global Constraints

- No third-party Swift packages; no runtime npm dependencies in the mod (AGENTS.md).
- An install happens only on the owner's click (Settings, menu or notification). Nothing installs
  in the background.
- No install without `gh attestation verify <image> --repo getLiveBridge/LiveBridge
  --signer-workflow getLiveBridge/LiveBridge/.github/workflows/release.yml --source-ref
  refs/tags/v<X.Y.Z> --deny-self-hosted-runners --format json` passing and its subject digest
  equal to the image's SHA-256. No build of the app has a switch that skips it.
- Tags: `^v(0|[1-9][0-9]{0,5})(\.(0|[1-9][0-9]{0,5})){2}$`; every path, URL and ref is built from
  the parsed integers.
- Image URL: `https://github.com/getLiveBridge/LiveBridge/releases/download/v<X.Y.Z>/LiveBridge.dmg`;
  redirects only over https to `github.com`, `objects.githubusercontent.com` or
  `release-assets.githubusercontent.com`; at most 100 MB.
- Installed copy: `/Applications/LiveBridge.app`, resolved `Bundle.main.bundleURL` equal to it and
  the path not a symlink. Other copies show `Updates install only into /Applications`.
- Check due: toggle on, installed copy, and 24 hours or more since the last check, or `now` before
  it. Evaluated on launch, every 15 minutes, and on wake.
- Programs by absolute path: `/usr/bin/hdiutil`, `/usr/bin/codesign`, `/usr/bin/ditto`,
  `/usr/bin/xattr`, `/usr/bin/open`, `/bin/sh`, `/bin/kill`, `/bin/sleep`; `gh` and `claude` via
  `CodexLaunch.defaultSearchPath`. Timeouts: 30 s for checks, 120 s per `claude` command.
- `claude` never gets `-y` or `--accept-command`; it runs with the data folder as working
  directory.
- Data: `~/Library/Application Support/LiveBridge/updates/` holds `<X.Y.Z>/` (the image),
  `record.json`, `state.json` and `lock`. Staged copies: `/Applications/.LiveBridge-update-<random>.app`.
- Fixtures and tests use `/Users/example`, `Example session` and `00000000-…` ids.
- One behaviour, one test; tests check behaviour, not the wording of sentences.
- Conventional Commits, one logical change each; `scripts/check.sh` exits 0 before each commit
  (on Node 24 run its `node --test` step on `app/Tests/AudioJSTests/*.test.mjs`).

## Review Focus

1. A release whose image is attested by another workflow or ref: refused (Task 4, test
   `anAttestationArgvPinsWorkflowRefAndRunners`).
2. A request opened by voice while the mod updates: the swap waits again (Task 5, test
   `aRequestOpenedDuringTheModUpdateDelaysTheSwap`).
3. The mod's relaunch racing the swap: the new instance retries its socket instead of running
   without a bridge (Task 8, test `bindRetriesWhileAnotherInstanceAnswers`).
4. A leftover or planted `/Applications/.LiveBridge-update-*` symlink: never installed, removed
   at launch without following it (Task 6, tests `aStagedSymlinkIsNotSwapped`,
   `cleanupUnlinksASymlinkWithoutFollowingIt`).
5. `claude plugin update` asking for confirmation without a TTY: reported, never answered
   (Task 5, test `claudeIsNeverAskedToAccept`).

## Execution contract

- **Final review:** one per PR, after Wave E, with two seats: correctness, and "what can be
  deleted, and whom does this refuse". A security seat joins because the diff adds a code path
  that downloads and installs code; its rulings name each anchor's provenance first (an anchor
  the agent can write is no control) and one legitimate owner the ruling must not refuse. One
  scoped re-review follows the fixes, and that is the end.
- **Lifecycle matrix**, checked before Wave E is closed: Check / Install / launch cleanup ×
  {no `gh`, `gh` signed out, attestation fails, digest differs, wrong bundle, `/Applications`
  read-only, request open, call on, `claude` missing, `claude` refuses, mod version differs,
  swap fails, relaunch races the mod, source build, copy outside `/Applications`}.
- **Parallelism:** Waves A and C-8/C-9 touch disjoint files and may run side by side; B waits for
  A; C-7 waits for B; D waits for B and C; E waits for D. Reviewers are read-only and may run
  beside an implementer; two implementers never share a worktree.
- **Fix briefs** list sibling instances only to fold them into one rule or delete them, and carry
  a net line budget.
- **Verification:** the controller re-runs `scripts/check.sh` only on heads it pushes or merges,
  and re-derives the PR body before every push.

## Wave graph

```
A (Tasks 1-3: version, release, policy, record) ──► B (Tasks 4-6: Updater) ──► C7 (Task 7: real environment) ──┐
C (Tasks 8-9: registry, socket, build, marketplace) ─────────────────────────────────────────────────────────┤
                                                                                                              ▼
                                                                    D (Tasks 10-11: UI, notices, schedule) ──► E (Tasks 12-13: docs, manual run)
```

Edges from Consumes/Produces: B imports `AppVersion`, `Release`, `UpdateProblem`, `UpdateRecord`,
`UpdateStateStore`, `UpdatePolicy` (A); Task 7 implements `UpdateEnvironment` (B); D uses
`Updater` (B), `SystemUpdateEnvironment` (7), `SessionRegistry.hasOpenRequests` and
`Bridge.hasOpenRequests` (8), `Settings.checkUpdatesAutomatically` (A), `LBSourceBuild` (9).

---

## Wave A — Tasks 1-3

### Task 1: Versions and the GitHub reply

**Files:**
- Create: `app/Sources/BridgeCore/Update/AppVersion.swift`, `app/Sources/BridgeCore/Update/Release.swift`, `app/Sources/BridgeCore/Update/UpdateProblem.swift`
- Test: `app/Tests/BridgeCoreTests/ReleaseTests.swift`, fixture `app/Tests/BridgeCoreTests/Fixtures/release-latest.json` (a trimmed real `releases/latest` reply: `tag_name`, `html_url`, `assets[].name`, `assets[].browser_download_url`)

**Interfaces:**
- Produces:
  - `public struct AppVersion: Comparable, Hashable, Codable, Sendable, CustomStringConvertible` with `major`, `minor`, `patch: Int`; `public init?(_ text: String)` (strict `X.Y.Z`, the regex parts above); `public init?(tag: String)` (`v` + the same); `public var tag: String` (`"v1.2.3"`); `description` is `"1.2.3"`.
  - `public struct Release: Equatable, Sendable` with `version: AppVersion`, `imageURL: URL`, `pageURL: URL`; `public static func parse(_ reply: Data) throws(UpdateProblem) -> Release`. `imageURL` and `pageURL` (`https://github.com/getLiveBridge/LiveBridge/releases/tag/v<X.Y.Z>`) are built from the version; the reply must list an asset named `LiveBridge.dmg`.
  - `public enum UpdateProblem: Error, Equatable, Sendable` with cases `network(String)`, `http(Int)`, `badTag(String)`, `noImage`, `tooLarge`, `ghMissing`, `ghSignedOut`, `attestationFailed`, `digestMismatch`, `noApp`, `wrongBundle(String)`, `wrongVersion(String)`, `needsNewerMacOS(String)`, `signatureInvalid`, `notWritable`, `stagedChanged`, `swapFailed(String)`, `busy`, `notInstalledCopy`; `public var sentence: String` (one sentence each; `ghMissing`/`ghSignedOut`/`attestationFailed` say the image cannot be verified and that the release page has it).

- [ ] **Step 1: Write the failing tests** in `ReleaseTests.swift`: `aVersionParsesStrictly` (`"0.1.2"` → 0,1,2; `nil` for `"0.1"`, `"01.1.2"`, `"+1.1.2"`, `"0.1.2-rc1"`, `"1.2.3.4"`, `"1234567.0.0"`); `versionsOrderAsIntegers` (`0.1.10 > 0.1.9`, `1.0.0 > 0.9.9`); `aTagNeedsItsV` (`AppVersion(tag: "0.1.2") == nil`, `AppVersion(tag: "v0.1.2")?.tag == "v0.1.2"`); `aReplyGivesTheVersionAndBuiltURLs` (fixture with a hostile `browser_download_url` such as `http://example.com/x.dmg` → `imageURL` is the GitHub URL above); `aSuffixedTagIsRefused` (`v0.2.0-rc1` → `.badTag`); `aReleaseWithoutTheImageIsRefused` (→ `.noImage`); `aReplyThatIsNotJSONIsRefused` (→ `.network`).
- [ ] **Step 2: Run** `cd app && swift test --filter ReleaseTests` — expect compile failure (types missing).
- [ ] **Step 3: Implement** the three files. Parse each part with the regex, not `Int(_:)`, which accepts `+2`.
- [ ] **Step 4: Run** `cd app && swift test --filter ReleaseTests` — expect all pass.
- [ ] **Step 5: Commit** `feat(app): parse release versions and the GitHub reply strictly`.

### Task 2: The policy, the check state and the setting

**Files:**
- Create: `app/Sources/BridgeCore/Update/UpdatePolicy.swift`, `app/Sources/BridgeCore/Update/UpdateState.swift`
- Modify: `app/Sources/BridgeCore/Settings.swift` (field, init, decoder)
- Test: `app/Tests/BridgeCoreTests/UpdatePolicyTests.swift`, `app/Tests/BridgeCoreTests/SettingsTests.swift`

**Interfaces:**
- Consumes: `AppVersion` (Task 1).
- Produces:
  - `public enum UpdatePolicy`: `static let interval: TimeInterval = 86_400`; `static let tick: Duration = .seconds(900)`; `public static func isCheckDue(now: Date, lastCheck: Date?, enabled: Bool) -> Bool`; `public static func checksAutomatically(setting: Bool?, isSourceBuild: Bool) -> Bool` (`setting ?? !isSourceBuild`); `public static func isInstalledCopy(resolvedBundlePath: String, installedPathIsSymlink: Bool) -> Bool` (equal to `/Applications/LiveBridge.app` and not a symlink); `public static let installedPath = "/Applications/LiveBridge.app"`.
  - `public struct UpdateState: Codable, Equatable, Sendable { public var lastCheck: Date?; public var announced: Set<AppVersion> }` and `public final class UpdateStateStore: Sendable` (`init(file: URL)`, `var current: UpdateState`, `func update(_: (inout UpdateState) -> Void)`), kept in `updates/state.json`, an unreadable file giving the empty state.
  - `Settings.checkUpdatesAutomatically: Bool?` (default `nil`), decoded with `decodeIfPresent`.

- [ ] **Step 1: Write the failing tests** in `UpdatePolicyTests.swift`: `aCheckIsDueAfterADay` (last check 86 400 s ago → true); `aCheckIsNotDueWithinADay` (86 399 s → false); `aCheckIsDueWhenTheClockMovedBack` (now before last check → true); `aCheckIsDueWhenNeverChecked`; `noCheckWithTheToggleOff`; `aSourceBuildDefaultsChecksOff` (`checksAutomatically(setting: nil, isSourceBuild: true) == false`, `(nil, false) == true`, `(true, true) == true`); `onlyTheApplicationsCopyIsInstalled` (`/Applications/LiveBridge.app` → true; `/Users/example/Applications/LiveBridge.app` → false; installed path a symlink → false); `theCheckStateSurvivesARestart` (write then reread with a new store in a temporary directory); `anUnreadableStateIsEmpty`. In `SettingsTests.swift`: `anOlderSettingsFileLeavesUpdateChecksUnset` (decode a file without the key → `checkUpdatesAutomatically == nil`), extending the existing older-file test style.
- [ ] **Step 2: Run** `cd app && swift test --filter 'UpdatePolicyTests|SettingsTests'` — expect failures.
- [ ] **Step 3: Implement** both files and the `Settings` field.
- [ ] **Step 4: Run** the same filter — expect all pass.
- [ ] **Step 5: Commit** `feat(app): the update check's policy and state`.

### Task 3: The update record

**Files:**
- Create: `app/Sources/BridgeCore/Update/UpdateRecord.swift`
- Test: `app/Tests/BridgeCoreTests/UpdateRecordTests.swift`

**Interfaces:**
- Consumes: `AppVersion` (Task 1).
- Produces: `public struct UpdateRecord: Codable, Equatable, Sendable { public var from: AppVersion; public var to: AppVersion; public var mod: ModOutcome; public var noticePosted: Bool }`; `public enum ModOutcome: Codable, Equatable, Sendable { case updated; case byHand(commands: [String]) }`; `public static let byHandCommands = ["claude plugin marketplace update livebridge", "claude plugin update livebridge@livebridge"]`; `public static func read(_ file: URL) -> UpdateRecord?`; `public func write(_ file: URL) throws`.

- [ ] **Step 1: Write the failing tests**: `aRecordRoundTrips` (temporary file); `aMissingRecordIsNil`; `anUnreadableRecordIsNil`.
- [ ] **Step 2: Run** `cd app && swift test --filter UpdateRecordTests` — expect failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — expect pass.
- [ ] **Step 5: Commit** `feat(app): the record an update leaves for the relaunched app`.

---

## Wave B — Tasks 4-6

All three tasks build one actor in `app/Sources/BridgeCore/Update/Updater.swift` against
`app/Sources/BridgeCore/Update/UpdateEnvironment.swift`, tested in
`app/Tests/BridgeCoreTests/UpdaterTests.swift` with a `FakeUpdateEnvironment` (in that test file)
that records every `run` argv and answers from a script. File-system steps use real
`FileManager` calls under temporary `UpdatePaths` roots.

**Interfaces (whole wave):**
- Consumes: Tasks 1-3.
- Produces:
  - `public struct ProgramResult: Sendable, Equatable { public var status: Int32; public var output: String }`.
  - `public protocol UpdateEnvironment: Sendable` with `func fetchLatest() async throws(UpdateProblem) -> Data`; `func download(_ url: URL, to file: URL, maxBytes: Int) async throws(UpdateProblem)`; `func locate(_ program: String) async -> URL?`; `func run(_ executable: URL, _ arguments: [String], cwd: URL?, timeout: Duration) async -> ProgramResult?` (nil on timeout or failure to start); `func swap(_ a: URL, _ b: URL) throws`; `func relaunch(pid: Int32, app: URL) throws`; `func osVersion() -> OperatingSystemVersion`; `func sleep(for: Duration) async`.
  - `public struct UpdatePaths: Sendable { public var applications: URL; public var updates: URL; public var dataDir: URL; public var installed: URL { applications.appending(path: "LiveBridge.app") } }`.
  - `public enum UpdateStatus: Equatable, Sendable { case idle, checking, upToDate, available(Release), downloading, verifying, waiting, updatingMod, installing, failed(UpdateProblem) }`.
  - `public actor Updater` with `init(environment: any UpdateEnvironment, paths: UpdatePaths, running: AppVersion, hasOpenRequests: @escaping @Sendable () async -> Bool, stopCall: @escaping @Sendable () async -> Void, quit: @escaping @Sendable () -> Void, pid: Int32)`; `public var status: UpdateStatus`; `public nonisolated var statuses: AsyncStream<UpdateStatus>`; `public func check() async -> UpdateStatus`; `public func verifierProblem() async -> UpdateProblem?` (`.ghMissing` or `.ghSignedOut`, else nil); `public func install(_ release: Release) async`; `public static func cleanUp(paths: UpdatePaths) -> UpdateRecord?`.
  - A second `check()` or `install` while one runs sets nothing and returns `.failed(.busy)`; the run also holds `updates/lock` (`open(O_CREAT|O_EXCL)`, removed at the end of the run).

### Task 4: Check, download and verify

- [ ] **Step 1: Write the failing tests**: `aNewerReleaseIsAvailable`; `anEqualReleaseIsUpToDate`; `anOlderReleaseIsUpToDate`; `anHTTPErrorIsReported` (fetch throws `.http(403)` → `.failed(.http(403))`); `noGhDownloadsNothing` (`locate("gh") == nil` → `.failed(.ghMissing)`, no `download` call); `ghSignedOutDownloadsNothing` (`gh auth status` exits 1 → `.failed(.ghSignedOut)`, no download); `verifierProblemNamesAMissingGh` (`verifierProblem() == .ghMissing` with no `gh`, nil with a signed-in one); `anAttestationArgvPinsWorkflowRefAndRunners` (the recorded argv equals `["attestation", "verify", <image>, "--repo", "getLiveBridge/LiveBridge", "--signer-workflow", "getLiveBridge/LiveBridge/.github/workflows/release.yml", "--source-ref", "refs/tags/v0.1.3", "--deny-self-hosted-runners", "--format", "json"]`); `aFailedAttestationDeletesTheImage` (exit 1 → `.failed(.attestationFailed)`, `updates/0.1.3/` gone, no `hdiutil` call); `aDifferentAttestedDigestStagesNothing` (JSON subject digest ≠ file SHA-256 → `.failed(.digestMismatch)`); `aSecondRunIsRefused`.
- [ ] **Step 2: Run** `cd app && swift test --filter UpdaterTests` — expect compile failure.
- [ ] **Step 3: Implement** `UpdateEnvironment.swift`, and in `Updater.swift`: `check()`, the `gh` preflight (`gh auth status`), download into `updates/<X.Y.Z>/LiveBridge.dmg` with `maxBytes: 100 * 1024 * 1024`, SHA-256 with CryptoKit, and verification. Read the digest from the JSON as an array of results whose `verificationResult.statement.subject[].digest.sha256` holds it; require one equal to the file's.
- [ ] **Step 4: Run** — expect pass.
- [ ] **Step 5: Commit** `feat(app): check for a release and verify its image's origin`.

### Task 5: Bundle checks, staging, waiting and the mod

- [ ] **Step 1: Write the failing tests**: `anImageWithoutTheAppIsRefused`; `anotherBundleIdIsRefused`; `anotherBundleVersionIsRefused`; `anAppNeedingANewerMacOSIsRefused`; `aRefusedSignatureIsRefused`; `theImageIsDetachedOnFailure` (every failing path above records `hdiutil detach`); `readOnlyApplicationsLeavesTheAppAsItWas` (applications root without write permission → `.failed(.notWritable)`, installed untouched); `aFailureAfterStagingRemovesTheStagedCopy`; `theInstallWaitsWhileARequestIsOpen` (status `.waiting` while `hasOpenRequests` is true, goes on when false); `claudeMissingLeavesTheAppUpdated` (record `.byHand(commands: UpdateRecord.byHandCommands)`); `aFailingClaudeLeavesTheAppUpdated`; `aModOfAnotherVersionIsReportedByHand` (`claude plugin list --json` lists `livebridge@livebridge` at `0.1.2` while installing `0.1.3`); `claudeIsNeverAskedToAccept` (no recorded `claude` argv contains `-y`, `--yes` or `--accept-command`; each runs with `cwd == paths.dataDir`); `aRequestOpenedDuringTheModUpdateDelaysTheSwap` (`hasOpenRequests` turns true during the `claude` calls → status returns to `.waiting` before any `swap` call).
- [ ] **Step 2: Run** `cd app && swift test --filter UpdaterTests` — expect the new tests to fail.
- [ ] **Step 3: Implement** in `Updater.swift`: attach with `/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountrandom <updates/X.Y.Z> -plist <image>` and take the mount point from the plist's `system-entities[].mount-point`; read the mounted `Info.plist` (`CFBundleIdentifier`, `CFBundleShortVersionString`, `LSMinimumSystemVersion`); `/usr/bin/codesign --verify --deep --strict`; record the CDHash from `/usr/bin/codesign -dvvv` (`CDHash=` line); create the staged directory exclusively, copy with `/usr/bin/ditto <mount>/LiveBridge.app <staged>`; detach in a `defer`; strip `com.apple.quarantine` with `/usr/bin/xattr -d` on the staged copy only after its CDHash matched; poll `hasOpenRequests` every second through `environment.sleep`; run the two `claude` commands then `claude plugin list --json`.
- [ ] **Step 4: Run** — expect pass.
- [ ] **Step 5: Commit** `feat(app): check, stage and wait for a verified update, and update the mod`.

### Task 6: Swap, record, relaunch and the launch cleanup

- [ ] **Step 1: Write the failing tests**: `theSwapExchangesTheBundles` (fake `swap` records `(staged, installed)`; record written with `from`, `to`, `mod`; `relaunch(pid:app:)` called; `quit` called after it); `theCallStopsOnlyAtTheSwap` (`stopCall` recorded after the `claude` calls and before `swap`); `aStagedCopyWithAnotherCDHashIsNotSwapped` (→ `.failed(.stagedChanged)`); `aStagedSymlinkIsNotSwapped` (→ `.failed(.stagedChanged)`); `aFailedSwapLeavesTheInstalledApp` (swap throws → `.failed(.swapFailed)`, no quit); `theRecordIsReadAfterARelaunch` (`cleanUp` returns the written record); `cleanupRemovesLeftovers` (two `.LiveBridge-update-*.app` and a `0.1.3/` folder removed, `record.json` and `state.json` kept); `cleanupRefusesAnUpdatesSymlink` (updates root a symlink → nothing under its target removed); `cleanupUnlinksASymlinkWithoutFollowingIt` (a staged-name symlink to a directory with a file → link gone, target file kept).
- [ ] **Step 2: Run** `cd app && swift test --filter UpdaterTests` — expect the new tests to fail.
- [ ] **Step 3: Implement** the swap step (re-check `hasOpenRequests`, `stopCall`, `lstat` the staged path, CDHash and `codesign` again, `environment.swap`), the record write, `relaunch`, `quit`, and `cleanUp(paths:)` (removes only `.LiveBridge-update-*.app` in `applications` and entries in `updates` named as an `AppVersion` or `lock`, with `FileManager.removeItem`).
- [ ] **Step 4: Run** `cd app && swift test` — expect all pass.
- [ ] **Step 5: Commit** `feat(app): swap in the verified update and clean up after it`.

---

## Wave C — Tasks 7-9 (Tasks 8-9 may start beside Wave A; Task 7 waits for Wave B)

### Task 7: The real environment

**Files:**
- Create: `app/Sources/LiveBridge/SystemUpdateEnvironment.swift`
- Modify: `app/Sources/BridgeCore/Codex/CodexLaunch.swift` (`locate`, `run` visibility)
- Test: `app/Tests/BridgeCoreTests/CodexLaunchTests.swift`

**Interfaces:**
- Consumes: `UpdateEnvironment`, `ProgramResult`, `UpdateProblem` (Wave B).
- Produces: `CodexLaunch.locate(_ program: String = "codex", searchPath: [String]) -> URL?`; `CodexLaunch.run` becomes `public` with a `cwd: URL? = nil` parameter; `final class SystemUpdateEnvironment: UpdateEnvironment` with `init(releasesURL: URL)`, where `App.swift` passes `https://api.github.com/repos/getLiveBridge/LiveBridge/releases/latest`, or in `#if DEBUG` the value of `LIVEBRIDGE_RELEASES_URL` when set.

- [ ] **Step 1: Write the failing test** `locateFindsTheNamedProgram` (a temporary directory with an executable `gh` → `locate("gh", searchPath: [dir])` is that file; `locate(searchPath: [dir])` still looks for `codex`).
- [ ] **Step 2: Run** `cd app && swift test --filter CodexLaunchTests` — expect failure.
- [ ] **Step 3: Implement** the `CodexLaunch` changes, then `SystemUpdateEnvironment`: `URLSession` with a delegate that refuses a redirect off `https` or off the three hosts and cancels past `maxBytes`; `run` through `CodexLaunch.run` with the search path; `swap` with `renamex_np(a, b, UInt32(RENAME_SWAP))`, throwing on a non-zero return; `relaunch` with `Process` at `/bin/sh` and the argv of spec step 9; `osVersion` from `ProcessInfo`; `sleep` with `Task.sleep`.
- [ ] **Step 4: Run** `cd app && swift build && swift test --filter CodexLaunchTests` — expect pass.
- [ ] **Step 5: Commit** `feat(app): the system side of updates`.

### Task 8: Open requests and the socket retry

**Files:**
- Modify: `app/Sources/BridgeCore/Sessions/SessionRegistry.swift`, `app/Sources/BridgeCore/Bridge.swift`, `app/Sources/BridgeCore/Server/UnixHTTPServer.swift`, `app/Sources/LiveBridge/App.swift:108-145`
- Test: `app/Tests/BridgeCoreTests/SessionRegistryTests.swift`, `app/Tests/BridgeCoreTests/UnixHTTPServerTests.swift`

**Interfaces:**
- Produces: `public var hasOpenRequests: Bool { get }` on `SessionRegistry` (any session's `hasOpenRequest`); `public var hasOpenRequests: Bool { get async }` on `Bridge`; `UnixHTTPServer.start(retryFor: Duration = .zero) async throws`, retrying every 200 ms while `socketInUse`; `App.swift` calls it with `.seconds(10)`.

- [ ] **Step 1: Write the failing tests**: `openRequestsCountQueuedAndInFlight` (none → false; enqueued → true; polled → true; answered → false); `bindRetriesWhileAnotherInstanceAnswers` (first server bound; second `start(retryFor: .seconds(2))` started; first stopped after 300 ms → second binds); `bindGivesUpAfterTheRetry` (`retryFor: .milliseconds(400)` while the first stays → throws `socketInUse`).
- [ ] **Step 2: Run** `cd app && swift test --filter 'SessionRegistryTests|UnixHTTPServerTests'` — expect failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd app && swift test` — expect all pass.
- [ ] **Step 5: Commit** `feat(app): report open requests and retry a socket another instance holds`.

### Task 9: Source builds, the pinned mod and the guards in `check.sh`

**Files:**
- Modify: `scripts/build-app.sh` (the `release` function sets `LBSourceBuild`), `.claude-plugin/marketplace.json`, `scripts/check.sh`, `scripts/tests/` (a new `release-guards.test.sh`)

**Interfaces:**
- Produces: Info.plist key `LBSourceBuild` (`<true/>`) in builds from `--release` only; marketplace plugin source `{"source": "git-subdir", "url": "https://github.com/getLiveBridge/LiveBridge.git", "path": "plugin", "ref": "v<version>"}`.

- [ ] **Step 1: Write the failing shell test** `scripts/tests/release-guards.test.sh`: it fails when `marketplace.json`'s `ref` is not `v` + `CFBundleShortVersionString`, and when a release binary (`swift build -c release`) contains the string `LIVEBRIDGE_RELEASES_URL`.
- [ ] **Step 2: Run** `sh scripts/tests/release-guards.test.sh` — expect failure on the marketplace ref.
- [ ] **Step 3: Implement**: pin `marketplace.json` to `v0.1.2` now (the next release commit moves it, as `CONTRIBUTING.md`'s release steps will say in Task 12); call the test from `check.sh`; set the key in `build-app.sh --release` with `plutil -insert LBSourceBuild -bool true`.
- [ ] **Step 4: Run** `scripts/check.sh` — expect exit 0 (Node 24 note above).
- [ ] **Step 5: Commit** `build: mark source builds and pin the mod to the release tag`.

---

## Wave D — Tasks 10-11

### Task 10: Settings, menu and notices

**Files:**
- Create: `app/Sources/LiveBridge/UpdateSection.swift`
- Modify: `app/Sources/LiveBridge/SettingsView.swift` (a section after "General"), `app/Sources/LiveBridge/App.swift` (`AppModel` owns the `Updater`), `app/Sources/BridgeCore/Menu/MenuContent.swift` (command `.installUpdate(AppVersion)` titled `Install LiveBridge X.Y.Z…`), `app/Sources/LiveBridge/StatusMenu.swift`, `app/Sources/LiveBridge/Notifier.swift`
- Test: `app/Tests/BridgeCoreTests/MenuTests.swift`

**Interfaces:**
- Consumes: `Updater`, `UpdateStatus`, `UpdateRecord`, `UpdatePolicy` (A, B), `SystemUpdateEnvironment` (7), `Bridge.hasOpenRequests` (8), `LBSourceBuild` (9).
- Produces: `MenuContent.init(update:problem:contextLoad:available: AppVersion?)`; `Notifier.postUpdate(identifier: String, title: String, body: String, installs: AppVersion?)` with identifiers `update-available-<X.Y.Z>` and `update-installed-<X.Y.Z>` and a notification action `install`.

- [ ] **Step 1: Write the failing tests** in `MenuTests.swift`: `anAvailableUpdateAddsItsInstallItem` (outline contains `Install LiveBridge 0.1.3…` above `Settings…`); `noUpdateAddsNoInstallItem`.
- [ ] **Step 2: Run** `cd app && swift test --filter MenuTests` — expect failure.
- [ ] **Step 3: Implement** the menu command, then the `UpdateSection` (version line; Check for update disabled while a run is under way; the status line; Install; the toggle bound to `checkUpdatesAutomatically` with `UpdatePolicy.checksAutomatically` as its shown value; the record's lines; `Updates install only into /Applications` for other copies; for a source build, Install first asks with a confirmation that it replaces the source build), the `AppModel` wiring (`Updater.cleanUp` at launch, posting `update-installed-<to>` once and setting `noticePosted`), and the notices (`update-available-<X.Y.Z>` once per version, recorded in `UpdateState.announced`, its body adding `verifierProblem()`'s sentence when there is one; its `install` action calls the same install as the button).
- [ ] **Step 4: Run** `cd app && swift test` and `scripts/build-app.sh --run`; open Settings — expect the section with `LiveBridge <version>` and `Updates install only into /Applications` (a debug build is outside `/Applications`).
- [ ] **Step 5: Commit** `feat(app): update from Settings, the menu and a notification`.

### Task 11: The schedule

**Files:**
- Modify: `app/Sources/LiveBridge/App.swift`
- Test: `app/Tests/BridgeCoreTests/UpdaterTests.swift`

**Interfaces:**
- Consumes: `UpdatePolicy.isCheckDue`, `UpdatePolicy.tick`, `UpdateStateStore`, `Updater.check()`.
- Produces: `Updater.checkIfDue(now: Date, enabled: Bool, state: UpdateStateStore) async -> Release?` (checks when due, stores `lastCheck`, returns a newer release not yet in `announced` and adds it).

- [ ] **Step 1: Write the failing tests**: `aDueCheckRecordsItsTime`; `aReleaseIsAnnouncedOnce` (two due checks with the same newer release → the second returns nil); `aCheckThatIsNotDueDoesNothing` (no `fetchLatest` call).
- [ ] **Step 2: Run** `cd app && swift test --filter UpdaterTests` — expect failure.
- [ ] **Step 3: Implement** `checkIfDue` and the wiring: on launch, a `Task` loop every `UpdatePolicy.tick`, and `NSWorkspace.didWakeNotification`, each calling `checkIfDue` only for the installed copy.
- [ ] **Step 4: Run** `cd app && swift test` — expect pass.
- [ ] **Step 5: Commit** `feat(app): look for updates daily and announce each once`.

---

## Wave E — Tasks 12-13

### Task 12: Documentation

**Files:**
- Create: `docs/adr/0002-the-app-updates-itself-on-the-owners-click.md` (from `docs/adr/0000-template.md`)
- Modify: `README.md` and `README.{zh-CN,hi,es,fr,ru,uk}.md` ("Local by design", Install, its upgrade paragraph and "From source", Permissions, Privacy, the `gh attestation verify` command and its sentence), `site/index.html` (the traffic sentence), `SECURITY.md` (every item of the spec's Documentation list), `.github/workflows/release.yml` (the comment at lines 2-4), `docs/architecture/overview.md` (the `Update` components and the launch steps), `CONTRIBUTING.md` (release steps: move `marketplace.json`'s `ref` in the release commit, push the tag right after the merge), `CHANGELOG.md` (an Unreleased "Added" entry), `docs/specs/2026-11-02-in-app-update-design.md` (status: delivered), `docs/trail.toml` (drop its `proposed` state), `docs/roadmap.md` (`stayfixed docs trail`)

- [ ] **Step 1:** Write each change; every claim must name what the code enforces (AGENTS.md). The README command becomes the spec's step 3 command without `--format json`.
- [ ] **Step 2: Run** `stayfixed docs trail --check` and `scripts/check.sh` — expect OK and exit 0.
- [ ] **Step 3: Commit** `docs: in-app update`.

### Task 13: The manual run

- [ ] **Step 1:** Follow the spec's manual check (Tests section, last paragraph), with a session on `/live on`. Record in the PR body: the swap while the mod polled, the relaunch, the record and notice, `claude plugin list --json`'s version, the login item, any App Management prompt.
- [ ] **Step 2:** Run the lifecycle matrix from the execution contract against the fake-backed tests and this run; any cell neither covers goes to the final review as a finding.
