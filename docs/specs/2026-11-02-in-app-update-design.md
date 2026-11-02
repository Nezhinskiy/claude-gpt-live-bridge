# In-app update

Status: proposed, 2026-11-02.

## Why

Each release is installed by hand today: download `LiveBridge.dmg`, check it with
`gh attestation verify`, drag the app over the old one, then run two `claude plugin` commands for
the mod. Done by hand it also races the mod: while a session has `/live on`, the mod opens
`/Applications/LiveBridge.app` again whenever the app stops answering, so quitting the app before
replacing it can bring the old binary back (seen while installing 0.1.2). The owner wants the
Settings window to show the version and update the app and the mod from there, and the app to do
it by itself when nothing is going on.

## What the owner sees

At the bottom of Settings, in a section of its own:

- `LiveBridge 0.1.2`, the running app's `CFBundleShortVersionString`.
- **Check for update**. While it runs it shows the step: Checking, Downloading, Verifying,
  Installing, Updating the mod. Its outcome is one line: `Up to date`, `Version 0.1.3 is
  available` with an **Install** button, or a sentence saying what failed.
- **Install updates automatically**, on by default.
- After an update that changed the mod: `Claude Code sessions already open keep the old mod until
  they restart.`

The app installs an update only from the copy in `/Applications`. Any other copy (a debug build in
`app/.build`) shows `Development build` instead of the button and the toggle, and never checks.

With the toggle on, the app checks once every 24 hours while it runs, and on launch when the last
check was more than 24 hours ago. It installs a newer release only while the call is off and no
joined session has a request queued or in flight; otherwise it waits until both hold. After it
relaunched on the new version it posts one notification, `LiveBridge updated to 0.1.3`.

**Install** pressed during a call stops the call first, as Stop does; the automatic install never
does.

An update cannot change two things the owner may expect: macOS asks for the microphone again,
because the app is signed ad hoc, and sessions already open keep their mod until they restart. A
build installed from source with `scripts/build-app.sh --release` is in `/Applications` too and is
replaced by the release image like any other, so a self-signed identity from
`--make-signing-identity` no longer applies after the update.

## How an update runs

1. **Check.** `GET https://api.github.com/repos/getLiveBridge/LiveBridge/releases/latest`, no
   credentials. The release's `tag_name` must be `v` followed by a version; it is newer when its
   numbers are greater than the running version's, compared as integers part by part. The asset
   named `LiveBridge.dmg` gives the download URL. A release without that asset, or a tag that is
   not a version, is reported and not installed.
2. **Download** the image to `~/Library/Application Support/LiveBridge/updates/<version>/`.
3. **Verify the origin.** Run `gh attestation verify <image> --repo getLiveBridge/LiveBridge`.
   `gh` is found the way `codex` is (`CodexLaunch.defaultSearchPath`). Without `gh`, or when it
   fails (not logged in included), nothing is installed: the outcome says that the image could
   not be verified and links to the release page, and the downloaded image is deleted. This is the
   only proof of origin, as the README says for a manual install.
4. **Check the bundle.** Mount the image read-only and without a Finder window
   (`hdiutil attach -nobrowse -readonly`). Its `LiveBridge.app` must have the bundle identifier
   `com.getlivebridge.livebridge`, the version the tag names, and pass `codesign --verify --deep
   --strict`. Then detach.
5. **Stage** a copy at `/Applications/.LiveBridge-<version>.app`, on the same volume as the
   installed app. If `/Applications` is not writable, the outcome says so and nothing changes.
6. **Swap while the old app still runs.** Rename `/Applications/LiveBridge.app` to
   `updates/<version>/LiveBridge-previous.app`, then the staged copy to
   `/Applications/LiveBridge.app`. Both are renames on one volume. The running process keeps its
   binary by inode, so from this point any launch of the path, the mod's included, starts the new
   version. If the second rename fails, the first is undone.
7. **Update the mod.** Find `claude` the same way and run `claude plugin marketplace update
   livebridge`, then `claude plugin update livebridge@livebridge`. When `claude` is missing or
   either command fails, the app stays updated and the outcome shows both commands to run by hand.
8. **Relaunch.** Start a detached `/bin/sh` that waits for this process to exit and then runs
   `open /Applications/LiveBridge.app`, then quit. If the mod opened the new app first, `open`
   only brings it forward.

On the next launch the app removes the `updates/` folders of versions other than its own, which
also drops the previous bundle. A failure at any step before 6 leaves the installed app as it was.

## Components

`BridgeCore/Update/`, pure and tested without a network:

- `Release`: parses the GitHub reply into a tag, a version and the image URL.
- `AppVersion`: parses `X.Y.Z` and orders versions.
- `UpdatePolicy`: whether a check is due (toggle on, last check 24 hours ago or more) and whether
  an automatic install may start (call off, no session with an open request).
- `UpdateMachine`: the steps above as states, `idle`, `checking`, `upToDate`,
  `available(Release)`, `downloading`, `verifying`, `installing`, `updatingMod`, `done`,
  `failed(UpdateProblem)`, and the effect each event asks for; `UpdateProblem` is typed, as
  `Problem` is, and each case carries its sentence.
- `Updater`: an actor that runs the effects through `UpdateEnvironment`, a protocol over the
  network, the file system, `gh`, `hdiutil`, `codesign`, `claude` and the relaunch, so tests use a
  fake.

`Settings` gains `installUpdatesAutomatically` (default `true`) and the time of the last check.
`LiveBridge` adds the Settings section to `SettingsView`, gives the `Updater` the bridge's call
phase and open requests (`SessionRegistry`'s `hasOpenRequest`), and posts the notification through
`Notifier`. A debug build reads the releases URL from `LIVEBRIDGE_RELEASES_URL` when it is set, so
a local fake release can stand in for GitHub; a release build ignores it.

## Tests

One behaviour each, in `BridgeCoreTests`:

- a newer tag is available; an equal or older one is up to date; a tag that is not a version fails;
- a release without `LiveBridge.dmg` fails;
- without `gh`, and with `gh` failing, nothing is staged and the image is deleted;
- a bundle with another identifier or another version is refused;
- `/Applications` not writable leaves the app as it was;
- a failed second rename puts the old bundle back;
- `claude` missing or failing leaves the app updated and reports the two commands;
- an automatic install waits while the call is on or a request is open, and starts once neither
  holds;
- no check is due within 24 hours of the last one, or with the toggle off;
- a copy outside `/Applications` never checks.

The real swap and relaunch are checked by hand: a debug build pointed at a fake release on
localhost through `LIVEBRIDGE_RELEASES_URL`, with an image that passes the other checks, and a
session with `/live on` running so the mod's relaunch is part of the test.

## Documentation, in the same change

- README, Install: the in-app update, that it needs `gh` logged in, and that macOS asks for the
  microphone again.
- SECURITY.md: the new outbound requests (the GitHub API and the image download, daily while the
  toggle is on), that the app runs `gh`, `hdiutil`, `codesign` and `claude`, and that the
  attestation is the one check of origin.
- `docs/architecture/overview.md`: the `Update` components.
- CHANGELOG.

## Out of scope

- Notarization or a Developer ID signature, which would stop macOS from asking for the microphone
  after each update.
- Giving sessions that are already open the new mod without a restart.
