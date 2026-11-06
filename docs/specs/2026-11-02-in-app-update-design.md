# In-app update

Status: delivered, 2026-11-03. Proposed 2026-11-02 and revised the same day after a design and security review.

## Why

Each release is installed by hand today: download `LiveBridge.dmg`, check it with
`gh attestation verify`, drag the app over the old one, then run two `claude plugin` commands for
the mod. Done by hand it also races the mod: while a session has `/live on`, the mod opens
`/Applications/LiveBridge.app` again whenever the app stops answering, so quitting the app before
replacing it can bring the old binary back (seen while installing 0.1.2). The owner wants the
Settings window to show the version and update the app and the mod from there, and the app to
look for updates by itself.

## Decisions

- An update installs only when the owner says so: a click on **Install** in Settings, in the
  menu, or in the notification. The app may look for updates by itself; it never installs by
  itself. This keeps a release that someone with push access to the repository could produce
  from reaching a Mac without its owner's action.
- Nothing installs without a passing attestation check through `gh` (below).
- The app updates the mod as well as itself.

## What the owner sees

At the bottom of Settings, in a section of its own:

- `LiveBridge 0.1.2`, the running app's `CFBundleShortVersionString`.
- **Check for update**. Its outcome is one line: `Up to date`, `Version 0.1.3 is available` with
  an **Install** button, or a sentence saying what failed. While a run is under way the button is
  disabled and the line shows the step: Checking, Downloading, Verifying, Waiting for Claude to
  finish, Updating the mod, Installing.
- **Check for updates automatically**, on by default (off by default for a build from source,
  below).
- After an update, until the next one: `Updated from 0.1.2.` and, when the mod could not be
  updated, the two commands to run by hand. Either way, while a joined session still runs a mod
  older than the app (or one that names no version): `Still on the old mod: <labels>.`

The update runs only for the copy installed at `/Applications/LiveBridge.app`: the app's
`Bundle.main.bundleURL`, symlinks resolved, equals that path, and that path is not a symlink.
Any other copy (a debug build in `app/.build`, a copy in `~/Applications`, one run from the disk
image) shows `Updates install only into /Applications` instead of the button and the toggle, and
never checks.

With the toggle on, the app looks for a newer release when it is due: 24 hours or more since the
last check GitHub answered, or a clock that moved back past it. It evaluates this on launch, every 15 minutes, and
when the Mac wakes. A newer release is announced once per version: a notification
`LiveBridge 0.1.3 is available` with an **Install** action, and a menu item
`Install LiveBridge 0.1.3…` until it is installed or a newer one replaces it.

Before **Install** does anything it checks that `gh` is found and `gh auth status` succeeds; if
not, it says that the image cannot be verified without a logged-in GitHub CLI, links to the
release page, and downloads nothing. A check due in the background with no usable `gh` still
announces the release, and the announcement says the same.

**Install** never interrupts work in flight. It downloads and verifies first. It then waits
while any joined session has a request queued or in flight (`Waiting for Claude to finish`), and
stops the call, as Stop does, only at the swap. A background task's `update` that arrives after
the swap is lost; the mod reports a lost answer, as it does for any answer the app no longer
knows.

An update cannot change two things the owner may expect: macOS asks for the microphone again,
because the app is signed ad hoc, and sessions already open keep their mod until they restart.
The microphone prompt comes right after the app relaunched on the new version; the docs tell the
owner to expect it only then.

A build installed from source with `scripts/build-app.sh --release` carries the Info.plist key
`LBSourceBuild` (the release image does not). For such a build the toggle is off by default, and
**Install** says first that it replaces the source build with the release image, which is signed
ad hoc, so a self-signed identity from `--make-signing-identity` no longer applies.

## How an update runs

One run at a time: the `Updater` actor refuses a second run while one is under way, and takes an
exclusive lock file in `~/Library/Application Support/LiveBridge/updates/` for the run, so two
instances of the app cannot run one each. Every program is started by absolute path
(`/usr/bin/hdiutil`, `/usr/bin/codesign`, `/usr/bin/ditto`, `/usr/bin/xattr`, `/usr/bin/open`,
`/bin/sh`) except `gh` and `claude`, which are found the way `codex` is
(`CodexLaunch.defaultSearchPath`, with `CodexLaunch.locate` taking the program's name), and every
one runs with a timeout (`CodexLaunch.run`'s): 30 s for the checks, 120 s for each `claude`
command.

1. **Check.** `GET https://api.github.com/repos/getLiveBridge/LiveBridge/releases/latest`, no
   credentials. The reply is untrusted input. Its `tag_name` must match
   `^v(0|[1-9][0-9]{0,5})(\.(0|[1-9][0-9]{0,5})){2}$`; anything else (`v0.2.0-rc1` included) is
   reported and not installed. The version is the three parsed integers, and every path, URL and
   ref below is built from them, never from the raw string. It is newer when it orders after the
   running version, part by part as integers (`0.1.10` after `0.1.9`). A network failure or an
   HTTP error (a 403 from the rate limit included) is reported in one sentence.
2. **Download** `https://github.com/getLiveBridge/LiveBridge/releases/download/v<X.Y.Z>/LiveBridge.dmg`,
   built from the version, not taken from the reply. Redirects are followed only to GitHub's
   asset hosts over https, and a download larger than 100 MB is cut off and refused. The image goes
   to `updates/<X.Y.Z>/`, and its SHA-256 is computed once.
3. **Verify the origin.**

   ```
   gh attestation verify <image> --repo getLiveBridge/LiveBridge \
     --signer-workflow getLiveBridge/LiveBridge/.github/workflows/release.yml \
     --source-ref refs/tags/v<X.Y.Z> --deny-self-hosted-runners --format json
   ```

   The attested subject digest in the JSON must equal the SHA-256 from step 2. Any failure
   deletes the image and installs nothing. What this proves: the image was built by `release.yml`
   from tag `v<X.Y.Z>` of this repository and was not changed in transit or on GitHub. It does not
   prove that anyone reviewed the code, and it cannot stand against a process on this Mac that
   runs as the owner, which could replace `gh` on the `PATH`.
4. **Check the bundle.** Attach the image once:
   `hdiutil attach -readonly -nobrowse -noautoopen -mountrandom <dir> -plist`, the mount point
   read from the plist. Its `LiveBridge.app` must exist and have the bundle identifier
   `com.getlivebridge.livebridge`, the version `X.Y.Z`, an `LSMinimumSystemVersion` the running
   macOS meets, and pass `codesign --verify --deep --strict`. Record its CDHash
   (`codesign -dvvv`). `codesign` proves the bundle is whole as signed, not where it came from.
5. **Stage.** Create `/Applications/.LiveBridge-update-<random>.app` exclusively and copy the
   mounted app into it with `ditto`, then detach. The image is detached on every path, failures
   included. If `/Applications` is not writable, the outcome says so and nothing changes. The
   download sets no quarantine attribute (the app does not set `LSFileQuarantineEnabled`); a
   `com.apple.quarantine` attribute found on the staged copy is removed from that copy only, after
   its CDHash matched.
6. **Wait for quiet.** While any joined session has a request queued or in flight, wait.
7. **Update the mod.** Run `claude plugin marketplace update livebridge`, then
   `claude plugin update livebridge@livebridge`, with the data folder as the working directory, so
   no project settings apply. Never with `-y` or `--accept-command`: a command that asks for a
   person's confirmation is LiveBridge answering a Claude Code prompt, which it never does
   (`SECURITY.md`). Then the installed mod's version must equal `X.Y.Z`. When `claude` is missing,
   a command fails or refuses, or the version differs, the app still updates and the outcome
   shows both commands to run by hand. The mod is updated before the swap so that nothing slow
   runs between the swap and the quit.
8. **Swap.** Re-check the gate of step 6, stop the call if it is on, and require the staged copy
   to be a directory and not a symlink (`lstat`), to have the CDHash of step 4 and to pass
   `codesign --verify --deep --strict` again. Then exchange the staged copy and
   `/Applications/LiveBridge.app` in one call, `renamex_np(staged, installed, RENAME_SWAP)`: same
   directory, so there is no moment without an app at the path and no cross-volume case. The old
   bundle is now at the staged path. The running process keeps its binary by inode, so any launch
   of the path from now on, the mod's included, starts the new version.
9. **Record and relaunch.** Write `updates/record.json`: the old and new versions, the mod's
   outcome and the commands to show. Start `RelaunchScript`'s `/bin/sh`, which waits for this
   pid to exit with `/bin/kill -0`, then, until `/usr/bin/pgrep -U <uid> -f` finds a process of
   this user running `/Applications/LiveBridge.app`'s own executable (a `LiveBridge` built
   elsewhere does not count), runs `/usr/bin/open /Applications/LiveBridge.app` and waits a
   second, at most ten times
   (one `open` right after the quit can target the quitting instance, fail and still exit 0),
   every value a positional argument; then quit.

A failure at any step before 8 leaves `/Applications/LiveBridge.app` as it was and removes the
staged copy and the image.

**On launch**, the app:

- reads `updates/record.json` if present, shows it in Settings, posts
  `LiveBridge updated to 0.1.3` once (its own notification identifier, shown whatever the
  results-notification setting, since the owner asked for the update), then marks it shown;
- removes every `/Applications/.LiveBridge-update-*.app` (the previous bundle, or a copy a failed
  run left) and every entry of `updates/` except the record, refusing an `updates` that is a
  symlink and removing only entries whose names it made, with `FileManager.removeItem`, which
  unlinks a symlink rather than following it;
- binds its socket, retrying for up to 10 s while another instance still answers on it
  (`ServerError.socketInUse`), so a new instance started by the mod before the old one exited
  does not stay up without a bridge.

## The mod and the app across versions

After an update, sessions already open run the old mod against the new app until they restart.
The rule: the `/v1` wire stays backward compatible across releases, so an app accepts the mod of
the release before it; a release that cannot keep this changes the route prefix. The mod is
installed from the marketplace, which today points at `./plugin` on the default branch. Each
release commit pins it to the release's tag instead (below, "Settled before the plan"), and the
version check of step 7 reports a mod that is still not the release's. The mod is fetched with
git over HTTPS from this repository and is not attested; `SECURITY.md` says so.

## Components

`BridgeCore/Update/`, pure and tested without a network:

- `Release`: parses and validates the GitHub reply into a version, its tag and the image URL.
- `AppVersion`: parses `X.Y.Z` strictly and orders versions.
- `UpdatePolicy`: whether a check is due (toggle on, installed copy, 24 hours or more since the
  last check or a clock that moved back), and whether the install may go past step 6 and 8.
- `UpdateStatus`: where a run stands, `idle`, `checking`, `upToDate`, `available(Release)`,
  `downloading`, `verifying`, `waiting`, `updatingMod`, `installing`, `failed(UpdateProblem)`;
  `UpdateProblem` is typed, as `Problem` is, and each case carries its sentence. The steps run
  in one order, so no separate event and effect machine is needed.
- `UpdateRecord`: what step 9 writes and the next launch reads.
- `Updater`: an actor that runs the steps through `UpdateEnvironment`, a protocol over the
  network, `gh`, `hdiutil`, `codesign`, `ditto`, `claude`, the swap and the relaunch, so tests use
  a fake; file-system steps run under roots the tests point at temporary folders. Whether the
  copy is the installed one and whether it is a source build are decided by `UpdatePolicy` and
  the app, which start no check or install otherwise.

Changes to existing code:

- `CodexLaunch.locate` takes the program's name.
- `SessionRegistry` gains a public `hasOpenRequests` (any session with a request queued or in
  flight), and `Bridge` passes it on.
- `UnixHTTPServer.start` is retried on `socketInUse` as above.
- `Settings` gains `checkUpdatesAutomatically: Bool?`, decoded with `decodeIfPresent`; nil means
  the default for the build. The time of the last check and the versions already announced live
  in `updates/state.json`, not in the owner's settings, so a check does not rewrite
  `settings.json`.
- `Notifier` gains a post for the two update notices, with their own identifiers and the
  notification's Install action.
- `SettingsView` gains the section; the status menu gains the Install item; `App.swift` wires the
  `Updater`.
- `scripts/build-app.sh --release` sets `LBSourceBuild`; `--package` does not.
- In a debug build only (`#if DEBUG`, as `--fake-mic` is), `LIVEBRIDGE_RELEASES_URL` replaces the
  releases API URL; `check.sh` asserts that the release binary does not contain that string.
  There is no switch that skips the attestation in any build.

## Tests

One behaviour each, in `BridgeCoreTests`:

- a newer tag is available;
- an equal tag is up to date;
- an older tag is up to date;
- `0.1.10` orders after `0.1.9`;
- a tag with a suffix is refused;
- a tag with a sign or leading zero is refused;
- a release without `LiveBridge.dmg` is refused;
- an HTTP 403 reports the failure;
- a network failure reports the failure;
- no `gh` downloads nothing;
- `gh auth status` failing downloads nothing;
- a failed attestation deletes the image and stages nothing (seen as calls on the fake);
- an attested digest that differs from the image's hash stages nothing;
- an image without `LiveBridge.app` is refused;
- a bundle with another identifier is refused;
- a bundle with another version is refused;
- a bundle that needs a newer macOS is refused;
- a refused `codesign` is refused;
- `/Applications` not writable leaves the app as it was;
- a failure after staging removes the staged copy;
- the install waits while a request is open and goes on once none is;
- a request opened during the mod update makes the swap wait again;
- a staged copy whose CDHash changed is not swapped;
- a failed swap leaves the installed app;
- `claude` missing leaves the app updated and reports the commands;
- a `claude` command failing leaves the app updated and reports the commands;
- a mod version that is not the release's reports the commands;
- `claude` is never run with `-y` or `--accept-command`;
- the record is read after a relaunch and its notice posted once;
- the launch removes leftover staged copies and update entries;
- the launch refuses an `updates` that is a symlink;
- a check is due 24 hours after the last one;
- a check is not due within 24 hours;
- a check is due when the clock moved back;
- a check is not due with the toggle off;
- a copy outside `/Applications` never checks;
- a source build defaults the toggle off;
- a second run is refused while one is under way;
- a newer release is announced once;
- `Settings` from an older file keeps the default;
- the socket bind is retried while another instance answers.

The real swap and relaunch are checked by hand. Build a debug app, lower its
`CFBundleShortVersionString` below the latest release, copy it to `/Applications`, and open it
with `open --env LIVEBRIDGE_RELEASES_URL=<fake>`, where the fake is a local JSON naming the latest
real tag, so the real attested image is downloaded and verified. With a session on `/live on`,
press Install, and check: the swap while the mod polls, the relaunch, the record and notice, the
mod's version, the login item (`SMAppService.mainApp`), and whether macOS asks for App Management
when one app replaces another's bundle in `/Applications`.

## Documentation, in the same change

- README, "Local by design", Install (from the disk image, the upgrade paragraph, and from
  source with `--make-signing-identity`), Permissions and Privacy; the same in the six
  translations; `site/index.html`'s sentence on traffic.
- README's `gh attestation verify` command and its sentence, and `release.yml`'s comment: the
  command gains `--signer-workflow` and `--source-ref`, and the sentence says what it proves.
- SECURITY.md:
  - what the attestation proves and what it does not (step 3), and that `codesign` on an ad hoc
    signature is not an origin check;
  - that the app now replaces itself in `/Applications`, from a release the network names, only
    when the owner clicks Install (in "The app the mod opens" too);
  - that an updated app skips Gatekeeper's first-launch block: the updater's checks are the gate;
  - that the mod is fetched from the repository with git and is not attested;
  - that LiveBridge never runs `claude` with `-y` or `--accept-command`;
  - each new outbound request in "What leaves the Mac": the daily unauthenticated GitHub API
    request (it shows the Mac's IP address to GitHub), the image download (counted by GitHub),
    `gh`'s attestation fetch under the owner's own GitHub login, Sigstore's trust-root fetches,
    and `claude`'s git fetch of the marketplace;
  - that the microphone prompt is expected right after an update, and only then.
- An ADR: the app makes outbound requests and replaces itself, and why on the owner's click only.
- `docs/architecture/overview.md`: the `Update` components and the launch steps.
- CHANGELOG.

## Settled before the plan

- The `xcode-27` runner is GitHub-hosted (the 0.1.2 release job ran on a runner of the group
  "GitHub Actions"), so step 3 adds `--deny-self-hosted-runners`.
- The marketplace format lets a plugin source name a ref:
  `{"source": "git-subdir", "url": "https://github.com/getLiveBridge/LiveBridge.git", "path": "plugin", "ref": "vX.Y.Z"}`.
  Each release commit pins the mod to its own tag this way (a commit cannot name its own SHA,
  so the tag alone, which only maintainers may create); `check.sh` holds the ref equal to `v` and
  the app's version.
- `claude plugin list --json` gives each installed plugin's id and version without a TTY; step 7
  reads `livebridge@livebridge`'s version from it.

## Out of scope

- An install without the owner's click.
- A second signature over the image with a key held offline.
- Notarization or a Developer ID signature, which would stop macOS from asking for the microphone
  after each update.
- Giving sessions that are already open the new mod without a restart.
