# Versioning

LabDesk versions identify the application, service, and bundled Labnet runtime together.

## The rule

- **Semantic versioning**, `MAJOR.MINOR.PATCH`, and a build number after `+`.
  - `MAJOR` when an existing installation cannot be upgraded in place, or an identity,
    peer store or option written by the previous version can no longer be read.
  - `MINOR` for a new capability an operator can see: a section, a tool, a trigger, a probe.
  - `PATCH` for a fix that changes no interface and no stored data.
  - The build number (`+N`) increases by one on every version change and is never reused. It is
    used in the Windows MSI version `MAJOR.MINOR.N`. The patch and prerelease suffix
    remain in the application version. MSI requires major/minor at most 255 and
    build between 1 and 65535; the packaging script rejects values outside those limits.
- **One number, everywhere it is read.** The version is written in several places and they must
  agree. `scripts/set-version.ps1 <version>` rewrites all of them; nothing edits them by hand.

  | File | Read by |
  |---|---|
  | `Cargo.toml` `version` | `labdesk --version`, the About page, the connection manager's title |
  | `libs/portable/Cargo.toml` `version` | the portable wrapper exe |
  | `flutter/pubspec.yaml` `version` | the Flutter bundle; the `+N` is the build number |
  | `.github/workflows/flutter-build.yml` `VERSION` | asset names, `LabDesk-<version>-<arch>-install.exe` |
  | `appimage/AppImageBuilder-*.yml` `version` | the AppImage metadata |
  | `res/rpm*.spec` `Version:` | the `.rpm` package names and metadata |
  | `Cargo.lock`, `libs/portable/Cargo.lock` | our own crates' entries, so a `--locked` build agrees |

- **A tag is a release.** `v<version>` on the commit that is released, created by the owner when
  the release pull request lands on `master`. A tag is never moved.
- **Pre-releases** carry a suffix: `1.2.0-rc.1`. The build number still increases.
- Cargo, lockfiles, Flutter and release filenames retain the prerelease suffix. RPM and
  AppImage metadata use the numeric version; they are not Windows acceptance artifacts.
- Baseline source attribution stays in the license and provenance documentation. It does
  not select the product version, networking service, endpoints, or upgrade channel.

## Labnet milestone

The current private candidate is `1.4.0-alpha.8+80`, packaged as MSI `1.4.80`.
The next acceptable release is `1.4.0`, after matching Windows installations on Zenbook
and Foundry work across separate internet connections with Tailscale stopped on both.
Acceptance covers enrollment, encrypted desktop/control/file operations, the enabled
service surviving GUI exit and restart, membership removal, and recovery after a network
change. Build or unit-test success alone does not close this milestone.

Website and console releases use separate versions but must record their compatible
application version, database migrations, and deployed Worker identity. Private alpha/RC
artifacts are not promoted through the stable updater before the milestone passes.

## Compiler and release scope

The security candidate pins Rust 1.98.1 in `rust-toolchain.toml`. The manifest declares
Rust 1.88 as the minimum required by the resolved dependencies. The Windows x64 Flutter
build uses the same pinned compiler; it does not use the legacy Sciter compiler setting.
The compiler archives are verified against the official Rust distribution checksums.

This milestone is accepted on the Windows x64 installations named above. Updating the
shared compiler setting does not establish compatibility for macOS, Linux, Android,
Windows ARM64 or the legacy Sciter builds; those require their own validation. The
standalone portable packer carries the complete application payload and is included
alongside the MSI in this candidate's signed update inventory.

## History, and why 1.2.0

Until 2026-09-02 the binaries reported `1.4.9`, the upstream core's number, while the
repository's tags said `v1.0.0` to `v1.1.0`. Two numbers for one artifact meant neither could be
trusted: an installed copy could not tell you which LabDesk it was. `v1.1.0` had already been spent
on the 2026-08-29 console preview, so the first version the binaries themselves carry is
**1.2.0**, and from here the tag and the binary agree.

## Bumping

```
pwsh scripts/set-version.ps1 1.2.1
```

The script refuses a version that is not `MAJOR.MINOR.PATCH[-suffix]`, computes the next build
number from `pubspec.yaml`, rewrites every file in the table, and prints them for the commit. Add the
`CHANGELOG.md` entry in the same commit; the commit subject is `chore(version): 1.2.1`.
