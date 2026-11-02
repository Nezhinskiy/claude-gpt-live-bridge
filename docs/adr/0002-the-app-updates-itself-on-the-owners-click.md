# 0002. The app updates itself on the owner's click

## Context

Until 0.1.2 each release was installed by hand: download `LiveBridge.dmg`, check it with
`gh attestation verify`, drag the app over the old one, then run two `claude plugin` commands
for the mod. Done by hand, it races the mod. While a session has `/live on`, the mod opens
`/Applications/LiveBridge.app` again whenever the app stops answering, so quitting the app before
replacing it can bring the old binary back; this happened while installing 0.1.2. The owner
asked for the Settings window to show the version, to update the app and the mod from there,
and for the app to look for updates by itself.

An app that replaces itself is a new way for code to reach the Mac. LiveBridge is signed ad hoc
and not notarized, so macOS checks nothing about where a new version comes from; the release's
one proof of origin is the build provenance attestation that `release.yml` makes on GitHub
Actions. Before this, the app's only traffic was the voice line to OpenAI, through codex.

The design and its review are in
[the in-app update spec](../specs/2026-11-02-in-app-update-design.md).

## Decision

- We will install an update only when the owner clicks **Install**: in Settings, in the menu bar
  menu, or in the notification that announces a release. The app may look for a release by
  itself (once a day, on by default, off for a build from source), and announces each version
  once; it never installs by itself. A release that someone with push access to the repository
  could produce then cannot reach a Mac without its owner's action.
- We will install nothing without a passing
  `gh attestation verify --repo getLiveBridge/LiveBridge --signer-workflow
  getLiveBridge/LiveBridge/.github/workflows/release.yml --source-ref refs/tags/vX.Y.Z
  --deny-self-hosted-runners`, pinned to the release workflow, the release's tag and GitHub's own
  runners, whose attested digest equals the downloaded image's SHA-256. The tag must be a plain
  `vX.Y.Z` newer than the running version, and every path and URL is built from the parsed
  version, never from the reply. Without a signed-in `gh` nothing is downloaded.
- We will check the app in the image (bundle identifier, version, minimum macOS,
  `codesign --verify --deep --strict`), stage a copy beside the installed app, and swap the two
  in one `renamex_np(…, RENAME_SWAP)` call once the staged copy still has the CDHash the image's
  app had. There is no moment without an app at the path, so the mod's relaunch finds either the
  old version or the new one.
- We will update the mod in the same run with `claude plugin marketplace update livebridge` and
  `claude plugin update livebridge@livebridge`, never with `-y` or `--accept-command`: a prompt
  that `claude` raises is a Claude Code prompt, which LiveBridge never answers. When they fail,
  the app still updates and shows the two commands.
- We will pin the mod in `.claude-plugin/marketplace.json` to the release's tag (a `git-subdir`
  source with `ref: vX.Y.Z`), so the mod an update installs is the release's; `check.sh` holds the
  ref equal to the app's version.

## Consequences

- The app makes outbound requests of its own: a daily unauthenticated request to GitHub's API,
  which shows GitHub the Mac's IP address, and, on Install, the image download, `gh`'s requests
  under the owner's GitHub login (Sigstore's trust root included) and `claude`'s git fetch of the
  marketplace. The README's Privacy and SECURITY.md's "What leaves the Mac" list them, and the
  daily check can be turned off.
- An updated app skips Gatekeeper's first-launch block: the download sets no quarantine attribute,
  and one found on the staged copy is removed after its CDHash matched. The updater's checks are
  the gate, and they rest on `gh` as found on the owner's `PATH`.
- The attestation proves where and from what the image was built, not that anyone reviewed the
  code; the owner's click is the only stop for a release pushed by someone with push access.
- macOS asks for the microphone again at the first Start after each update, because each release
  is signed ad hoc. Notarization or a Developer ID signature would stop that; neither is in place.
- A build from source is replaced by the release image, which is signed ad hoc, so a self-signed
  identity from `build-app.sh --make-signing-identity` no longer applies; Install says so and asks
  first.
- Sessions already open keep the old mod until they restart, so the `/v1` wire stays backward
  compatible across releases; a release that cannot keep this changes the route prefix.
- The release commit must move the marketplace's `ref` to the new tag, and the tag must be pushed
  right after the release merges ([CONTRIBUTING.md](../../CONTRIBUTING.md#releasing)).

Alternatives considered:

- **Install in the background**, unattended, as many apps do. Rejected by the owner: a release
  that passes the attestation could then reach the Mac with nobody's action.
- **A cooldown**: install a release only some days after it is published, so a bad one can be
  pulled first. Not taken; the owner's click already stands between publication and install.
- **A second signature over the image with a key held offline**, which would stand even against
  someone who can push a tag. Out of scope for now.

## Status

Accepted, 2026-11-02.
