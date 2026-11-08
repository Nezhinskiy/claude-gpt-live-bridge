# Review: PR #70, the notarized release

- **PR:** [getLiveBridge/LiveBridge#70](https://github.com/getLiveBridge/LiveBridge/pull/70),
  `feat/notarized-release` → `dev`, head `8e64c14`, base `1ac9757`.
- **Date:** 2026-11-08.
- **Scope:** report only; nothing in the PR was changed.
- **Passes run:**
  - `superpowers:requesting-code-review`: an independent reviewer that also tried mutations.
  - `security-review`: a security sub-review.
  - `simplify`: four angles (reuse, simplification, efficiency, altitude), with no fixes applied.
  - My own pass over the workflow, the docs, the translations and the Homebrew tap.
- **Line numbers** are at the PR head.

## Verdict

**Merge with fixes.** No finding is High.

- **Holds up:**
  - The pipeline runs in the right order: sign, notarize and staple the app, build the image from
    it, then notarize and staple the image. The attestation comes last, on the stapled image.
  - It fails safe at every point checked. Secrets are scoped per step.
  - The tests can fail: every mutation tried turned them red.
- **Fix before merge:** two docs findings (D1 and D2) and the cost the new test adds to
  `check.sh` (C1).
- **Fix before the first `v*` tag:** S1, S2 and S3. Each is cheap. Each turns a first-tag
  surprise either into an early, clear failure or into a check that actually proves something.

## What was verified

| Claim | Result | How |
|---|---|---|
| Secrets reach only the steps that need them, through `env`, never through `${{ }}` in a script | Holds | Read every step (`release.yml:63-134`). The `security import -P` argv exception (`:96`) cannot be exploited on an ephemeral, single-tenant hosted runner. The spec records it. |
| Temporary keychain created and deleted with `if: always()` | Holds | `release.yml:88-99`, `:147-151` |
| The runner's search list is never changed | Holds | Locally, on this macOS, `security create-keychain` left `list-keychains -d user` unchanged. The reviewer saw the same during a full `package.test.sh` run. |
| No untrusted ref reaches the `release` secrets | Holds | `release.yml` is the only workflow with `environment:`, and it runs only on `push: tags: v*`. No workflow uses `pull_request_target`, `workflow_run` or `issue_comment`. |
| Minimal `permissions`; actions pinned by SHA | Holds | `permissions: {}` at the top. The job gets `contents`, `id-token` and `attestations: write`. No action was added, and every `uses:` is a full SHA. |
| Scorecard: Token-Permissions, Dangerous-Workflow, Pinned-Dependencies | No regression | As above. No new trigger, and no untrusted context interpolated. |
| The attestation runs last, on the stapled image | Holds | `release.yml:130-138` |
| `--package-app` / `--package-dmg` split, `set -e`, `trap` | Sound | The two halves run in sequence, not with `&&`. Each half sets and clears its own `EXIT` trap. A failure in either one cleans up its scratch folder. |
| An ad hoc local build still works without an Apple account | Holds | The reviewer ran `--package` with no identity: the app came out `adhoc,runtime` and passes `--verify --deep --strict`, and the image is unsigned, as before. |
| `notarize.sh` staples only on `Accepted` | Holds | It reads the JSON verdict, not the exit status. On rejection it prints the reply and the log, exits 1 and staples nothing. |
| The tests can fail | Holds | Nine mutated copies of `notarize.sh` (staple on any verdict, no log, no zip, no validate, no `spctl`, no key or credential check, exit 0 on rejection, a looser match) each turned `notarize.test.sh` red. Dropping `--timestamp` turned `package.test.sh` red. `notarize.test.sh` takes 0.8 s, `package.test.sh` 43 s. CI `check` passes on the PR. |
| The updater accepts a Developer ID app and the ad hoc 0.4.2 → Developer ID update | Holds as far as code goes | `Updater.swift:362-376` checks `codesign --verify --deep --strict` plus the CDHash and names no signer. Stapling leaves the CDHash unchanged, and `ditto` keeps the ticket. The origin check is still the attestation, pinned to workflow, tag and hosted runners (`Updater.swift:254-256`), and the environment does not change it. A real update is first-tag only. |
| The docs match the updater | Holds | SECURITY.md (`:338-345`) and ADR 0002 say the check names no signer and is not an origin check. |
| The translations follow the English | Holds | All six translations say the same thing: four "Developer ID" mentions each (ru has five), no "Open Anyway" left, and the 0.4.2 transition stated. Wording quality was not judged. |

## Findings, most severe first

Severity scale: **Medium** = fix before merge or before the first tag; **Low** = worth doing,
not blocking; **Nit** = taste.

### D1. Medium: the docs on `main` will describe a release that may not exist yet

**Where:** `README.md:96-98`, `:130-131`, `:151-153`, the same sentences in `docs/i18n/README.*.md`,
and `site/index.html:195`.

**What:** these lines say the download is notarized and that macOS just asks before opening it.
They are written in the present tense, with no version. Today's release is 0.4.2, which is ad
hoc, and it is blocked until **Open Anyway**.

- `main` is the default branch, so these lines go live when the release PR merges, which is
  before the tag runs.
- Several things can only be proven on the first tag: the certificate chain, the notary reply,
  `stapler` and `spctl` on the runner. If the first tag fails, `main` tells every reader
  something false about the only download there is.
- The spec accepts this (`docs/specs/2026-11-08-notarized-release-design.md:193`). The repo rule
  "docs never claim more than the code enforces" says otherwise.
- The site is held back until the release exists (the implementer's note). The README is not.

**Also outside the repo:** the Homebrew tap's cask (`getLiveBridge/homebrew-tap`,
`Casks/livebridge.rb`) still has this caveat: "LiveBridge is signed ad hoc and not notarized.
… Open Anyway". It is right for 0.4.2. It will be wrong once the cask moves to the first
notarized version, and the PR does not mention it.

**Fix:**
- Put a version on the claim, as the Updating section already does ("Releases after 0.4.2 …"),
  in the Quick start step 3, the Install paragraph and From the disk image step 4. Keep the
  Open Anyway steps for 0.4.2 and earlier until the first notarized release exists.
- Or merge the README hunk only after the first tag has succeeded.
- Either way, list the cask caveat as a release-day step in CONTRIBUTING's Releasing section.

### D2. Medium: CHANGELOG and CONTRIBUTING say the ad hoc image is signed; it is not

**Where:** `CHANGELOG.md:25-26` and `CONTRIBUTING.md:150-151`.

**What:**
- CHANGELOG says "without it the image is signed ad hoc as before".
- CONTRIBUTING says "still builds the same image, signed ad hoc and not notarized".
- In fact, with no identity, `package_dmg` leaves the image unsigned (`build-app.sh:216-217`,
  `:232-235`, as the reviewer observed); only the app inside is ad hoc. It is also not "the same
  image": its signatures differ from the release's.
- The CHANGELOG text ends up in release notes.

**Fix:** "…the app is signed ad hoc and the image left unsigned, as before." In CONTRIBUTING:
"builds the image from the same source, with the app signed ad hoc and nothing notarized."

### C1. Medium: `check.sh` now needs the network and a full release build on every run

**Where:** `scripts/check.sh:12-13` and `scripts/tests/package.test.sh:5-6`.

**What:**
- `package.test.sh` archives HEAD into a fresh `/tmp` folder, so it runs a cold
  `swift build -c release` every time. It signs with `--timestamp`, which contacts Apple's
  timestamp server twice.
- AGENTS.md (`:23`) says `check.sh` "must exit 0 before a commit".
- Offline, behind a proxy, or during a timestamp-server outage, every commit gate now fails. Each
  run also costs about 45 s more.
- `check.sh`'s comment and AGENTS.md do not say so; only the test's own header does.

**Fix (any one):**
- Skip it with a message when `timestamp.apple.com` is unreachable, the way the `claude`-facing
  half is skipped.
- Or test the signing flags on a stub bundle: a tiny `LiveBridge.app` signed through the same
  `sign_package`, plus a tiny image. Keep the full build in CI only.

Either way, say it in `check.sh`'s comment.

### S1. Medium (first tag): the early identity check may not match what `codesign` sees

**Where:** `release.yml:100-108` and `build-app.sh:82-91`.

**What:**
- `man codesign` (checked here) says this about `--keychain`: "the standard keychain search path
  is still consulted while constructing the certificate chain", and the named keychain "will not
  be searched to resolve the signing identity's certificate chain unless it is also on the user's
  search list".
- `security find-identity -v` may still call the identity valid. It may do so through an
  intermediate that came in the `.p12`, or through a network fetch.
- `codesign` builds the chain only from the System keychain and the system roots. If the runner
  image (the custom `xcode-27` label) lacks Apple's Developer ID G2 intermediate there, signing
  fails with "unable to build chain".
- That is safe, but it costs a tag run. It also breaks the comment's promise that a bad chain
  "fails now, not at notarization".

**Fix:**
- In the keychain step, require
  `security find-certificate -c "Developer ID Certification Authority" /Library/Keychains/System.keychain`.
- Or, after signing, require that `codesign -dvv` lists `Authority=Developer ID Certification
  Authority` and `Authority=Apple Root CA`.
- Add the intermediate to the spec's "What only the first tag proves".

### S2. Medium (first tag): `spctl --assess` passes without proving anything if Gatekeeper is off

**Where:** `scripts/notarize.sh:63-67`.

**What:**
- If the runner image has assessments disabled, `spctl --assess` exits 0 with
  `override=security disabled`. I could not confirm the hosted image's setting either way.
- The script would still print "Gatekeeper accepts it".

**Fix:** capture `spctl --verbose=2`'s output and require `source=Notarized Developer ID`. Or run
`spctl --status` first and fail if assessments are disabled. Add a `notarize.test.sh` case where
the stub answers `override=security disabled`.

### S3. Low (first tag): no retry around `stapler staple`

**Where:** `scripts/notarize.sh:62`.

**What:**
- `stapler staple` right after an `Accepted` verdict can fail briefly while Apple's ticket
  service catches up ("Record not found" / error 65). This comes from memory; I did not reproduce
  it here.
- One such failure kills a release whose notarization already succeeded, and the rerun signs and
  notarizes everything again.

**Fix:** a few attempts with a sleep between them, on `stapler staple` only.

### S4. Low: the signing material outlives its use

**Where:** `release.yml:110-116`, `:147-151`.

**What:**
- The `.p8` is written before packaging. The keychain stays unlocked (`-lut 3600`, `:93`).
- Both survive through the release build of the tag's code, the third-party
  `attest-build-provenance` step and `gh release create`, none of which needs them.
- The code is the tag's own, the repo has no third-party Swift packages, and the action is pinned
  by SHA, so this is not exploitable. It is defence in depth.

**Fix:**
- Write the `.p8` just before the first notarize step.
- Delete the keychain right after "Build and sign the disk image", and the `.p8` right after the
  second notarize step.
- Keep the `always()` step as the backstop.

### S5. Low: the only gate on the Developer ID is a click that shows no diff

**Where:** `release.yml:21-35`, and CONTRIBUTING "The release environment" step 3.

**What:**
- Anyone with write access can push a `v*` tag on any commit, including one that never reached
  `main`, with a `release.yml` changed to send the `.p12` and `.p8` elsewhere.
- The environment's tag rule matches that tag. The owner's Approve is the only stop, and the
  approval screen does not show the workflow's diff.
- Before this PR, such a tag could forge a release that passes the updater, which SECURITY.md
  says. Now it can also take the Developer ID certificate.
- This needs an insider and the owner's click, so it is below the security pass's threshold.

**Fix:**
- A tag ruleset that limits creating `v*` tags to the owner.
- A line in CONTRIBUTING: approve only a run whose commit is the release merge on `main`.
- Optionally, a step before the secrets that fails unless the tagged commit is reachable from
  `origin/main`. That is a control the code enforces, not a habit.

### S6. Low: docs state as fact that the microphone permission carries over

**Where:** `README.md:205-209`, `SECURITY.md:378-383`, `CHANGELOG.md:23-24`, ADR 0002 `:64-66`.

**What:**
- With a Developer ID, the designated requirement names the team, so the permission should carry
  over. That is the expected behaviour.
- It can only be observed on the second Developer ID release.
- The README's own convention for the quarantine claim is "this follows from the code and has not
  yet been observed". These lines drop that hedge.
- Login items (`SMAppService`) and the Local Network permission across the 0.4.2 → Developer ID
  update are not in the spec's first-tag list.

**Fix:**
- Use the same hedge until the second Developer ID release has been observed.
- Add the login item and Local Network permission to "What only the first tag proves".

### A1. Low (architecture): the keychain logic lives in YAML, untested, and is copied in the test

**Where:** `release.yml:83-109` and `scripts/tests/package.test.sh:21-41`.

**What:**
- Everything else in the signing chain is a script with a test. The step that handles the real
  certificate is 25 lines of workflow YAML: create, import, partition list, and the one-identity
  check.
- `package.test.sh` builds a near-identical keychain by hand.
- Its self-signed certificate profile copies `make_identity` (`build-app.sh:150-180`).

**Fix:**
- Move the logic into `scripts/signing-keychain.sh create|delete`, which prints or exports
  `LIVEBRIDGE_SIGN_KEYCHAIN` (and the identity's SHA-1, see A3).
- The workflow and `package.test.sh` both call it, and its one-identity check gets a test.
- The notary-key write fits there too, or in `notarize.sh`, which already owns that credential.

### A2. Low (architecture): the team pin in the updater is deferred one release longer than it has to be

**Where:** the spec, `docs/specs/2026-11-08-notarized-release-design.md:141-150`; the implementer's
follow-up.

**What:**
- An updater can only enforce a requirement on the release after its own, so a pin that ships in
  release N protects N → N+1.
- If the first Developer ID release ships without the pin, as now planned, the earliest protected
  update moves out by one more release.
- The deeper fix is small:
  `codesign --verify -R '=anchor apple generic and certificate leaf[subject.OU] = "<TEAM>"'`.
- It would apply only when the running app is itself Developer ID-signed, so builds from source
  and ad hoc builds keep today's path.

**Fix:** land the pin in the first Developer ID release, in this PR or one merged before the tag,
or record in the spec why one release without it is accepted.

### A3. Low (simplification): the identity is found twice and named by a prefix

**Where:** `release.yml:103-109`, `:119`, `:128`.

**What:**
- The keychain step already proves exactly one valid "Developer ID Application" identity.
- The two packaging steps then set `LIVEBRIDGE_SIGN_IDENTITY: Developer ID Application`, a prefix
  `codesign` matches again.

**Fix:** have the keychain step write the identity's SHA-1 to `$GITHUB_ENV`, alongside
`LIVEBRIDGE_SIGN_KEYCHAIN`. The SHA-1 is not secret and is public in every signature anyway. That
removes both `env:` duplicates and the prefix match. No personal name lands in the repository.

### Q1. Low: a failed image signature leaves an unsigned image in `dist/`

**Where:** `scripts/build-app.sh:229-235`.

**What:** if `sign_package` or `codesign --verify` fails on the image, `$out/LiveBridge.dmg` stays
behind, unsigned. In CI the job fails, so that is harmless. Locally it can pass for a signed
image.

**Fix:** remove it on that path.

### Q2. Low: test gaps

**Where:** `scripts/tests/package.test.sh` and `scripts/tests/notarize.test.sh`.

**What:**
- `package.test.sh` covers only identity plus keychain. Two branches have no test:
  - the ad hoc path, which the spec promises to keep;
  - identity without keychain (`build-app.sh:88-90`).
- `notarize.test.sh` has no case for:
  - an empty or non-JSON reply;
  - `In Progress` (the `--timeout 20m` expiry);
  - an empty key file.
- The code handles all of these today (exit 1), but nothing holds that in place.

### Q3. Nit: `sign_package` has three branches where two would do, and repeats `sign`'s flags

**Where:** `scripts/build-app.sh:82-91`, `:198-199`; the spec at `:98`.

**What:**
- The keychain branch differs only by `--keychain`. POSIX `${LIVEBRIDGE_SIGN_KEYCHAIN:+--keychain
  "$LIVEBRIDGE_SIGN_KEYCHAIN"}` folds it into the identity branch.
- `package_app` then repeats `--options runtime --entitlements …`, which `sign()` already holds.
- The spec says `sign` gains `--timestamp` and `--keychain`. The code adds `sign_package` instead,
  which leaves `--release` untouched; that is better.

**Fix:** say so in the spec.

### Q4. Nit: two near-identical test helpers

**Where:** `scripts/tests/notarize.test.sh:42-49` (`expect`) and `scripts/tests/package.test.sh:51-58`
(`check`).

**What:** they have the same shape and differ only in what they print on failure.

**Fix:** use one name and one body, or a shared `scripts/tests/lib.sh` if a third test wants it.

### Q5. Nit: `notarize.sh` accepts an empty key file

**Where:** `scripts/notarize.sh:25`.

**What:** `[ -f ]` accepts an empty file, which then fails late, at `notarytool`. The workflow's
secret check makes this unlikely there.

**Fix:** use `[ -s ]`.

### Q6. Nit: the workflow header states GitHub settings as if the file enforced them

**Where:** `release.yml:15-17`.

**What:** "which only a v\* tag may use and which waits for the owner's approval" describes the
environment's settings in the repository. Nothing in the file enforces it.

**Fix:** "configured (in Settings > Environments, see CONTRIBUTING.md) so that only a v\* tag may
use it and the owner approves each run."

### Q7. Nit: ADR 0002 is rewritten in place

**Where:** `docs/adr/0002-the-app-updates-itself-on-the-owners-click.md:13-16`, `:64-69`.

**What:**
- Its context now says "LiveBridge was then signed ad hoc" and points at later releases.
- The decision to require a Developer ID, with no ad hoc fallback and an environment with a
  reviewer, is a decision of its own. Its home is the spec, not an ADR.

**Fix:** a short ADR 0003 that supersedes those consequence lines would keep 0002 a record of its
own time. This is the owner's call on how ADRs are kept.

### Q8. Nit (pre-existing): the release toolchain is not pinned the way CI's is

**Where:** `release.yml:33`.

**What:** the comment says "the same image as ci.yml, so the release builds with the tested
toolchain". But `ci.yml:38` also runs `xcode-select -s /Applications/Xcode_27.2.app` and
`release.yml` does not. `notarytool` and `stapler` now come from whichever Xcode is the default.
The implementer already lists this as a follow-up.

## Suggestions considered and rejected

- **Drop the secret-presence step and let each consumer fail.** Rejected. It fails before a
  20-minute notarization, with a message naming the missing secret. The owner chose "no secrets,
  no release".
- **Delete the mid-function `rm -rf …; trap - EXIT` in `package_app` and `package_dmg`, and let
  the trap clean up.** Rejected as wrong. `--package` runs both functions in one shell, so
  `package_dmg`'s `trap` would replace `package_app`'s and leak `$src`.
- **Notarize only the image.** Rejected. Stapling the app before it goes into the image is what
  lets a copy dragged out of the image pass Gatekeeper offline. The `--package-app` /
  `--package-dmg` split exists for exactly that, and pulls its weight.
- **Job-level `env:` for the notary IDs.** Rejected. It widens their exposure to every step,
  including the third-party action. Only the non-secret identity could move, and A3 removes it
  altogether.
- **The `.p12` path in the cleanup step is dead.** Not dead. It removes the file when
  `security import` fails before `release.yml:98`.

## Architecture: is it elegant enough, and is anything redundant?

Mostly yes.

- **The shape follows the credentials.** There are two scripts: one signs (`build-app.sh`, which
  reads the identity), one notarizes (`notarize.sh`, which reads the key). The workflow only
  provisions the credentials and calls the scripts in order.
- **The `--package` split is forced by notarizing between the halves.** It is not ceremony.
- **The redundancy is small and local:**
  - the identity is checked and then named again by prefix (A3);
  - two `env:` blocks repeat it;
  - `sign_package` has a third branch (Q3);
  - two test helpers do the same job (Q4).
- **Two pieces sit one level too shallow:**
  - the keychain handling, which is security logic in untested YAML (A1);
  - the updater's team pin, deferred past the first release that could ship it (A2).
- **The PR's costliest side effect is not in the release path.** It is the new test's network
  and build cost on every `check.sh` run (C1).

## Follow-ups outside this PR

- **The Homebrew tap's caveat**, on release day (D1).
- **A tag ruleset for `v*`** (S5), set in repository settings.
- **The team pin in the updater** (A2), if it does not land before the tag.
- **The `xcode-select` gap** in `release.yml` (Q8).
