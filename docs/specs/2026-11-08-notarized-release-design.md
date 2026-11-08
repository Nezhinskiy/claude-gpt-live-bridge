# Notarized release

Status: written 2026-11-08; the workflow half is proven only by the first tag that runs it
([What only the first tag proves](#what-only-the-first-tag-proves)).

## Why

Every release up to 0.4.2 is signed ad hoc and not notarized, so macOS blocks the first launch
of a downloaded LiveBridge until the owner of that Mac finds **Open Anyway** in Privacy &
Security, and asks for the microphone again after every update. On 2026-11-08 the project's
owner joined the Apple Developer Program. A release signed with their Developer ID and
notarized by Apple opens on the first launch after macOS's usual "downloaded from the
internet" question, without the block, and keeps the microphone permission from one release to
the next.

## Goals

- `release.yml` signs the app and the disk image with the owner's Developer ID Application
  identity and has Apple notarize both; the tickets are stapled, so Gatekeeper's check works
  offline too.
- The attestation covers the image as uploaded, stapled ticket included, so the in-app updater's
  `gh attestation verify` keeps passing.
- A contributor without an Apple account still runs `scripts/build-app.sh --package` and gets
  the same image as today, signed ad hoc.

## Non-goals

- The official Homebrew cask (it comes after the first notarized release). The tap's cask needs
  no change: it installs the same `LiveBridge.dmg`.
- Pinning the team in the in-app updater (a follow-up; see [The updater](#the-updater)).
- Notarizing a build from source (`--release`) or the debug app.

## Anti-goals

- A release that silently ships ad hoc because a secret is missing. The workflow fails instead
  (the owner's call).
- A secret in a log, on a `run:` line or in the repository; a personal name in the repository.
- Docs that call the updater's signature check an origin check: it still is not one.

## Decisions

Recorded as made, with whose call each was.

- **Order** (the orchestrator's call):
  1. Sign the app with the Developer ID identity, hardened runtime, a secure timestamp and the
     existing `app/Support/LiveBridge.entitlements`.
  2. Zip it with `ditto -c -k --keepParent`, `xcrun notarytool submit --wait`, then
     `xcrun stapler staple` the app.
  3. Build the disk image from the stapled app and sign the image.
  4. Notarize the image, staple it, `xcrun stapler validate` it.
  5. Only then `actions/attest-build-provenance`, so the attestation covers the final image.
- **Notary credentials** (the orchestrator's call): an App Store Connect Team API key (`.p8`,
  Key ID, Issuer ID), not an Apple ID and app-specific password.
- **Signing credentials** (the orchestrator's call): the Developer ID Application certificate as
  a `.p12`, imported into a keychain the job creates under `$RUNNER_TEMP` and deletes in an
  `if: always()` step.
- **Where the secrets live** (the orchestrator's call): environment secrets of a GitHub
  Environment named `release`, deployable only from tags matching `v*`. Names:
  `MACOS_CERTIFICATE` (the `.p12`, base64), `MACOS_CERTIFICATE_PASSWORD`, `NOTARY_KEY` (the
  `.p8`, base64), `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`.
- **A required reviewer on `release`** (the owner's call): each release run waits for the
  owner's Approve before it gets the secrets, so a pushed tag alone signs nothing.
- **No secrets, no release** (the owner's call): the job's first step after the tag checks fails
  when any of the five is empty.
- **Identity by environment** (the orchestrator's call): `build-app.sh` signs with
  `LIVEBRIDGE_SIGN_IDENTITY` when it is set, and ad hoc otherwise. The workflow sets it to the
  prefix `Developer ID Application`, which `codesign` matches against the certificate's name,
  so no personal name lands in the repository; a SHA-1 hash also works.
  `LIVEBRIDGE_SIGN_KEYCHAIN`, when set, is the one keychain `codesign` searches (my call: the
  job then never changes the runner's keychain search list, and the packaging test signs with a
  throwaway identity without touching the login keychain).
- **Notarization is its own script** (the orchestrator's call, the shape mine):
  `scripts/notarize.sh FILE` takes a `.app` or a `.dmg`, needs the key in the environment and
  contacts nothing without it. `--package` is split into `--package-app` and `--package-dmg`,
  which it runs in turn, so the workflow can notarize the app between the two while a
  contributor's `--package` stays one command.
- **The notary's verdict is read, not assumed** (my call): `notarytool submit --wait` is run with
  `--output-format json`; anything but `"status": "Accepted"` prints the submission's log and
  fails, before anything is stapled.
- **Gatekeeper's own check** (my call): after stapling, `notarize.sh` runs `spctl --assess` on
  the file (`--type execute` for the app, `--type open --context context:primary-signature` for
  the image) and fails unless it passes.
- **The certificate's password reaches `security import -P`** (my call): `security import` reads
  a `.p12` password only from its command line. The value comes from the step's `env`, never
  from `${{ }}` in the script, so it is not in the workflow's text or its log (GitHub masks it);
  it is visible only to processes on the ephemeral runner during that one command. The keychain's
  own password is random per run and not a secret of the owner. Likewise `notarytool` takes the
  Key ID and Issuer ID as arguments; they name the key, and the `.p8` file, which is the secret,
  goes by path.
- **The microphone permission** (the orchestrator's call): a Developer ID signature gives the
  app a designated requirement that names the team, not one build's hash, so the permission
  survives later updates. The first update from an ad hoc 0.4.x release asks once more.

## Design

### `scripts/build-app.sh`

- `sign BUNDLE IDENTITY`: ad hoc (`-`) as today; any other identity adds `--timestamp`, which
  notarization requires, and `--keychain "$LIVEBRIDGE_SIGN_KEYCHAIN"` when that is set.
- `--package-app`: the first half of today's `--package` (the scratch copy of HEAD, the release
  build, `strip`, the signature, the check that the binary names no `$HOME`), ending with
  `codesign --verify --strict` and `ditto` of the app to `$DIST/LiveBridge.app`.
- `--package-dmg`: copies `$DIST/LiveBridge.app` with `ditto` (signature and any stapled ticket
  kept) beside an `/Applications` link, builds `$DIST/LiveBridge.dmg` named after the app's own
  version, and signs the image with the same identity (with `--timestamp`; not ad hoc, which
  has no meaning for an image, so an ad hoc package leaves the image unsigned as today).
- `--package`: `--package-app` then `--package-dmg`.
- `LIVEBRIDGE_DIST` names the output folder (default `dist`), so the test does not overwrite a
  contributor's `dist/`.

### `scripts/notarize.sh FILE`

Reads `LIVEBRIDGE_NOTARY_KEY` (the `.p8`'s path), `LIVEBRIDGE_NOTARY_KEY_ID` and
`LIVEBRIDGE_NOTARY_ISSUER`; refuses with exit 2 when one is missing or FILE is not an existing
`.app` or `.dmg`. A `.app` is zipped with `ditto -c -k --keepParent` into a scratch folder and
the zip submitted; a `.dmg` is submitted itself. Then the verdict, `stapler staple`,
`stapler validate`, `spctl --assess`.

### `.github/workflows/release.yml`

`environment: release`, `timeout-minutes: 60` (two notarizations, each given 20 minutes), the
same three permissions. After the two tag checks:

1. Fail unless the five secrets are set.
2. Create the keychain in `$RUNNER_TEMP`, import the `.p12`, allow `codesign` to use the key
   without a prompt (`set-key-partition-list`), require exactly one valid
   `Developer ID Application` identity in it, and export `LIVEBRIDGE_SIGN_KEYCHAIN`.
3. Decode the `.p8` into `$RUNNER_TEMP` (mode 600) and export `LIVEBRIDGE_NOTARY_KEY`.
4. `build-app.sh --package-app`; `notarize.sh dist/LiveBridge.app`; `build-app.sh
   --package-dmg`; `notarize.sh dist/LiveBridge.dmg`.
5. Attest, create the Release (unchanged).
6. `if: always()`: delete the keychain, the `.p8` and the `.p12`.

Secrets reach steps only through `env`. Actions stay pinned by SHA; no action is added;
`scorecard.yml` is untouched.

### The updater

No change. `Updater.checkBundle` requires `codesign --verify --deep --strict` and records the
CDHash, then requires the staged copy to have the same CDHash and pass `codesign` again. Neither
names a team or a requirement, so a Developer ID signature passes exactly as an ad hoc one does.
Stapling writes the ticket outside the code directory, so the CDHash `codesign -dvvv` reports is
the one the signature gave, and `ditto` keeps both. The same fact cuts the other way: the check
accepts an ad hoc app as readily, so it is still not an origin check, and the attestation stays
the one proof of where the image came from. Nor does the `release` environment's reviewer gate
the updater: a tag whose own `release.yml` drops the environment and the signing still gets an
attestation from that path, which the updater accepts (SECURITY.md already says that anyone who
can push a tag can make a release that passes). The reviewer guards the Developer ID, not the
update. Pinning the team (`codesign --verify -R` with the
team's requirement) is a follow-up once the first notarized release exists; an update from an ad
hoc release cannot use it, because the running, older updater does the checking.

### What else says "ad hoc"

The README and its translations, SECURITY.md, CONTRIBUTING.md (with the owner's one-time setup
of the `release` environment), ADR 0002's consequences, the website's install step
(`site/index.html`), CHANGELOG, and the app's own confirmation before **Install** replaces a
build from source (`Confirmation.replaceSourceBuild`), which said the release image is signed ad
hoc.

## Tests

- `scripts/tests/package.test.sh` (in `check.sh`): makes a throwaway self-signed code-signing
  identity in a keychain under a scratch folder, runs `--package` with
  `LIVEBRIDGE_SIGN_IDENTITY` (its hash), `LIVEBRIDGE_SIGN_KEYCHAIN` and `LIVEBRIDGE_DIST`, and
  checks that the app is signed by that identity with hardened runtime, a timestamp and the
  microphone entitlement, and that the image is signed by it and holds that app. It needs the
  network for the timestamp, as CI has.
- `scripts/tests/notarize.test.sh` (in `check.sh`): with stub `xcrun` and `spctl` first on
  `PATH`, checks that missing credentials and a wrong file are refused before anything runs, that
  an `Invalid` verdict fails without stapling and prints the log, and that an `Accepted` one
  staples, validates and assesses.
- The workflow itself runs only on a tag.

## What only the first tag proves

Nothing below can run without the secrets, so the first `v*` tag after this change is its test:

- The `release` environment, its tag rule and its reviewer gate the job as configured.
- The `.p12` imports, the runner's image holds Apple's Developer ID intermediate certificate so
  the identity is valid, and `codesign` finds it in the temporary keychain without a prompt (a
  local dry run with a self-signed stand-in covered every step up to that validity check).
- `notarytool submit --output-format json` answers with the `id` and `status` fields
  `notarize.sh` reads (its test uses a stub), and a Team key with the Developer role may
  notarize (Apple's forums say so; Apple's documentation names no role).
- Apple accepts the app and the image (hardened runtime, timestamp, entitlements, the bundled
  resource bundle), and `stapler` and `spctl` pass on the runner.
- The attestation of the stapled image verifies, and the in-app update from 0.4.2 installs it
  (the updater's `codesign` and CDHash checks on a stapled, Developer ID app).
- A download opens with macOS's "downloaded from the internet" question and no block, and the
  microphone permission given to that release survives the next update.

If the first tag fails, no Release is created; the README already describes the next release,
so the fix goes out before anyone reads it against the old one.

## Left to the builder

The exact wording in the docs; the step names; the messages the scripts print.
