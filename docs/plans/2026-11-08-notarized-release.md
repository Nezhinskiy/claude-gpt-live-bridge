# Notarized release: implementation plan

> **For agentic workers:** steps use checkbox (`- [ ]`) syntax. The tasks run in order, in one
> branch; each ends with `scripts/check.sh` exiting 0 and one Conventional Commit.

**Goal:** `release.yml` signs the app and its disk image with the owner's Developer ID,
notarizes and staples both, then attests the final image; `--package` without an identity
stays ad hoc.

**Spec:** [`docs/specs/2026-11-08-notarized-release-design.md`](../specs/2026-11-08-notarized-release-design.md).

## Global constraints

- A failing test before the change that makes it pass; one behaviour, one test.
- No secret on a `run:` line or in a log; secrets only through `env`. Actions pinned by SHA,
  minimal `permissions`, `scorecard.yml` untouched.
- No personal data: the identity is the prefix `Developer ID Application`, never a name or team.
- Never add `Co-Authored-By: Claude` or any Claude attribution.

## Task 1: sign the package with an identity

- [ ] Write `scripts/tests/package.test.sh`: a throwaway self-signed identity in a scratch
  keychain; `LIVEBRIDGE_SIGN_IDENTITY=<hash> LIVEBRIDGE_SIGN_KEYCHAIN=<keychain>
  LIVEBRIDGE_DIST=<scratch> scripts/build-app.sh --package`; assert the app's `Authority=`,
  `flags=…(runtime)`, `Timestamp=`, the microphone entitlement, `codesign --verify --deep
  --strict`, the image's `Authority=` and the app inside the image. Add it to `check.sh`.
  Run it: it fails (the app is ad hoc, the image unsigned, `dist/` ignored).
- [ ] In `build-app.sh`: `sign` adds `--timestamp` and `--keychain` for a real identity;
  split `package` into `package_app` and `package_dmg`; `LIVEBRIDGE_DIST`; the usage lines.
- [ ] Run the test, then `scripts/check.sh`; commit `feat(build): sign the package with
  LIVEBRIDGE_SIGN_IDENTITY when it is set`.

## Task 2: notarize a file

- [ ] Write `scripts/tests/notarize.test.sh` with stub `xcrun` and `spctl` on `PATH` that record
  their arguments: missing credentials refused (exit 2, no stub ran); a `.txt` refused; an
  `Invalid` verdict exits non-zero, runs `notarytool log`, never `stapler`; `Accepted` runs
  `stapler staple`, `stapler validate` and `spctl --assess`; a `.app` is submitted as a zip.
  Add it to `check.sh`. It fails (no script).
- [ ] Write `scripts/notarize.sh`.
- [ ] Test, `check.sh`, commit `feat(build): notarize and staple a package with notarize.sh`.

## Task 3: the release workflow

- [ ] `release.yml`: `environment: release`, 60 minutes, the secrets check, the temporary
  keychain, the `.p8`, the four packaging steps, the cleanup step; the header.
- [ ] Commit `ci(release): sign with the Developer ID and notarize the image`.

## Task 4: docs

- [ ] README (install, Gatekeeper, Homebrew, updating, permissions), its six translations,
  SECURITY.md (what an update installs, the microphone prompt), CONTRIBUTING (releasing, the
  owner's one-time setup), AGENTS.md's scripts line, CHANGELOG Unreleased.
- [ ] `docs/trail.toml`, `stayfixed docs trail`; commit `docs: the notarized release`.
