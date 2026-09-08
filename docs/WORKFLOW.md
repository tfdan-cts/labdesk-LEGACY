# LabDesk development workflow

This is the binding workflow for this repository. It applies to every contributor and every
automated agent, on every machine, in every session. Where any other document conflicts with
this one, this one wins.

## Branches

| Branch | Role | How it moves |
|---|---|---|
| `master` | The released public version. What users download. | Only by a release pull request from `labdesk-next`, approved and merged by the owner personally. |
| `labdesk-next` | The integration branch. Finished work waiting to be released together. | Only by pull-request merge from a feature branch. Never by direct push. |
| `feat/*`, `fix/*`, `docs/*`, `chore/*` | One unit of work each. | Branched from `labdesk-next`, pushed once when ready. |

`master` additionally tracks the upstream remote-access engine. Upstream merges land on `labdesk-next` first
and reach `master` through the same release pull request as everything else.

Nobody pushes to `master` directly. This is enforced by `.githooks/pre-push`; see *Enabling the
hooks* below.

## The lifecycle of a change

1. Branch from the current tip of `labdesk-next`.
2. Commit locally in logical units as the work progresses. Do not push once per commit.
3. Run the full gate suite locally and get it green **before** opening a pull request.
   Continuous integration confirms what already passed; it is never the first place the gates
   run. Actions minutes are paid overhead, and pushing to see whether CI passes wastes them.
4. Push once, when the work is ready, and open the pull request against `labdesk-next`.
   Later pushes to the branch are responses to review, not a save button.
5. Merge through the pull request, squashed.
6. Release: the owner approves, a release pull request from `labdesk-next` to `master` is
   opened, and its entire diff is read before merging. What lands on `master` is exactly the
   reviewed, intended promotion, and nothing else.
7. Hotfix, for a production emergency only: branch from `master`, fix, open a pull request to
   `master` with explicit owner approval, and merge the same fix back to `labdesk-next`
   immediately.

A release may contain only the work the owner explicitly ordered. If `labdesk-next` carries
anything else, do not cut the release: surface it and wait.

## Versions

LabDesk carries its own semantic version, separate from the upstream engine core's. It is written in
five files that must agree and is only ever changed by `scripts/set-version.ps1`; a release is
the tag `v<version>` the owner creates when the release pull request lands. The rules, the list
of files and the reason the first self-reported version is 1.2.0 are in `docs/VERSIONING.md`;
every version has an entry in `CHANGELOG.md`.

## The gate suite

Run all of these from `flutter/` and get them green before opening a pull request.

```
flutter test test/labdesk_*.dart      # LabDesk's own unit tests
flutter analyze --no-fatal-infos      # must add no new issues under lib/labdesk or lib/common/labdesk_*
```

Notes on the gates as they stand today:

- `flutter analyze` reports issues inherited from the upstream engine, so the total is never zero.
  The gate is that LabDesk's own files contribute none of them. Two measurements from
  2026-08-29, and the difference between them is the point:

  | Flutter | Total | In LabDesk's files |
  |---|---|---|
  | 3.24.5, the pinned version continuous integration builds with | 254 | **0** |
  | 3.47.2, installed on the development workstation | 351 | 17 |

  The pinned version is the one that counts. The extra items a newer Flutter reports are
  deprecations it introduced after 3.24.5, plus one `unnecessary_non_null_assertion` that has
  since been fixed. Filter the output for `labdesk` to see them.
- **Read the analyzer's count against the pinned Flutter version, not the newest one.** The
  version continuous integration builds with is pinned in
  `.github/workflows/flutter-build.yml` (`FLUTTER_VERSION`, currently 3.24.5). A newer Flutter
  installed locally deprecates APIs that the pinned one still considers current: every remaining
  LabDesk deprecation that names a version names v3.32, which is later than the pinned version,
  so the pinned analyzer cannot be reporting them. Do not "fix" those against a newer SDK. The
  replacement for `withOpacity` is `withValues`, which does not exist before Flutter 3.27, so
  applying it would break the build the release actually ships.
- A newer local Flutter can also fail to compile a dependency that continuous integration
  compiles fine. A failure inside `~/AppData/Local/Pub/Cache` or another package's source is a
  toolchain mismatch, not a regression here. Confirm the version before treating it as real.
- Running the tests locally rewrites `flutter/pubspec.lock` to suit the local SDK, which on a
  newer Flutter raises the Dart floor above what the pinned version can satisfy. **Never commit
  that churn.** Revert it with `git checkout -- flutter/pubspec.lock` before staging.
- The Rust core is not built locally by default; changes under `src/` are compiled by CI.
  A change to `src/` therefore cannot be gated locally, and its pull request must wait for the
  `CI` workflow to pass before merging.

## Continuous integration

- The `CI` workflow runs on pushes and pull requests and is the gate that must be green.
- `Full Flutter CI` is an upstream `workflow_call` pipeline. It reports `startup_failure` when
  triggered directly by a push, because a caller must grant it `contents: write` for its
  nested SBOM job. That failure is expected and is not a signal about the code.
- Producing installable artifacts is a manual step: run the *Manual build with artifact upload*
  workflow (`.github/workflows/labdesk-dispatch.yml`) by dispatch, with the release tag as its
  input.
- Superseded runs should be cancelled rather than left to complete.

## Testing on real machines

LabDesk is a remote administration tool, so a change to anything that touches a peer is not
verified until it has been exercised against a real second machine. Real-machine testing happens
on private hosts recorded outside this repository.

## Private files

Working files for automated agents are excluded locally and must never be committed. Do not name
them in the public `.gitignore` either, because naming them there is itself a disclosure.

Before any commit made with `git add -A`, check `git diff --cached` and confirm every hunk is
intended.

## Enabling the hooks

The hooks live in `.githooks/` and are not active until git is told to use them. Run once per
clone:

```
git config core.hooksPath .githooks
```

`pre-push` refuses any push to `master`. Overriding it requires `LABDESK_ALLOW_MASTER_PUSH=1`
in the environment, which exists so the owner can perform a release, and for no other reason.
