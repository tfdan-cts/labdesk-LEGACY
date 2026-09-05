---
type: session-notes
created: 2026-09-05
status: open
related:
  - docs/IOS.md
  - docs/research/2026-09-05-ios-reference-teamviewer.md
  - docs/plans/2026-09-05-001-production-program.md
---

# iOS lane, session notes

What was actually done, in order, with the evidence for each claim. Anything not
proved by a tool result is marked unverified. The branch is `feat/ios`, cut from
`feat/labnet` at `bb8ccd682`, worked in the worktree
`.claude/worktrees/ios`. Nothing here has been merged anywhere.

There is no Mac in this fleet, so every iOS claim below rests on a GitHub
Actions macOS runner. Evidence that does not fit in the repository (CI logs,
screenshots, downloaded artifacts) is kept under the session scratchpad at
`AppData/Local/Temp/claude/C--Users-DVonR/275fde7d-4fb4-405a-9436-e65532de5402/scratchpad/ios/`.

## Ground truth, established before building

Three questions, three answers, each from a tool result rather than a reading of
the code.

**Why the iOS CI job reports skipped.** The job `build rustdesk ios ipa` in
`.github/workflows/flutter-build.yml` carries its own
`if: ${{ inputs.upload-artifact }}`, and `flutter-ci.yml`, which is Full Flutter
CI, calls the reusable workflow with `upload-artifact: false`. The job therefore
evaluates false and skips. It runs only from `labdesk-dispatch.yml`,
`flutter-nightly.yml` and `flutter-tag.yml`. Nothing was broken; the skip is the
workflow doing what it was told.

**Whether the inherited iOS target builds on a macOS runner.** Not since this
morning. The job last succeeded in run 33931151246 at 2026-09-05T00:01Z, then
failed in runs 33944666923 and 33948273476 with four `E0433` errors at
`src/client.rs` lines 401, 402, 479 and 480: `crate::ipc::set_option_async` on a
platform where `src/lib.rs` declares `pub mod ipc` under
`#[cfg(not(any(target_os = "ios")))]`. `git log -L` on those lines named
`b3fe22bc5` as the commit that introduced it. This was reported to dvonr-02,
who owns that file; the fix is theirs, committed as `82a6d8f27`, and it was
reviewed here before it landed. Until it lands on `feat/labnet` and this branch
rebases onto it, no iOS build of any kind can be green.

A separate fact worth recording: the successful iOS runs produced nothing to
download. The artifact upload and release steps of that job are commented out,
so no iOS build has ever left this repository.

**What the mobile entry point renders.** `flutter/lib/main.dart:49` sends any
non-desktop platform to `runMobileApp`, which at line 181 calls `runApp(App())`,
and `App.build` sets `home` to `HomePage()` for the non-desktop non-web case.
That is upstream's `flutter/lib/mobile/pages/home_page.dart`, whose `initPages`
builds a connection page and a settings page on iOS; the chat and incoming
service tabs are gated on `isAndroid`. The LabDesk console is desktop only:
every console screen is under `flutter/lib/desktop/`. Two pieces are already
shared and usable from the phone, `flutter/lib/common/labdesk_profiles.dart` and
`flutter/lib/common/labdesk_status_binding.dart`; dvonr-02 confirmed neither is
mid-change, though the phase 1 console work is actively editing
`flutter/lib/labdesk/` and consumes the status binding.

## Piece 1: the verification path

The strongest verifier available without a Mac is a booted simulator on a macOS
runner. Before writing that job, a throwaway probe workflow measured the runner
rather than assuming it (run 33982479503, deleted in the same commit that added
the real job):

- `macos-latest` is arm64, macOS 26.6.2, Xcode 26.6.
- Simulator runtimes present: iOS 26.2, 26.4 and 26.5. Device types include
  iPhone 11 through iPhone 17.
- All four Rust iOS targets are installable, including `aarch64-apple-ios-sim`.
- vcpkg carries `arm64-ios-simulator` as a community triplet.

That last line decided the shape of the job. An iOS simulator build needs
simulator slices of libvpx, libyuv, aom and opus, and `arm64-ios` builds device
slices; without a simulator triplet the job would have had to hunt an Intel
runner. `macos-13` never scheduled during the probe and is treated as gone.

`.github/workflows/ios-verify.yml` is the result. It reuses `bridge.yml` rather
than copying the codegen, builds the Rust core for `aarch64-apple-ios-sim`
without `hwcodec` (matching the inherited `flutter/ios_x64.sh`), builds the app
with `flutter build ios --simulator --debug`, creates and boots an iPhone 17,
installs and launches the app, screenshots it at three, seven and ten seconds,
collects its log, and uploads all of it. It fails unless `launchctl` inside the
simulator still lists the app twenty seconds after launch.

One shortcut is deliberate and marked in the workflow: `Runner.xcodeproj` links
`target/aarch64-apple-ios/release/liblibrustdesk.a` as a literal path, so the
job copies the simulator slice to that path instead of forking the project file
for a job that never ships a build. The device build in `flutter-build.yml` is
untouched by it.

**Unverified as of this note.** The job has not yet completed a green run. Run
33982913736 is the first attempt. It is expected to fail at the Rust build until
`82a6d8f27` lands, and neither the vcpkg `arm64-ios-simulator` install nor the
`flutter build ios --simulator` step has been observed to succeed even once.
Nothing in `docs/IOS.md` claims otherwise.

## Piece 2: the target's identity

Changed, and each verified by reading the file back:

- `PRODUCT_BUNDLE_IDENTIFIER` in all three build configurations from
  `com.carriez.flutterHbb` to `net.lab-desk.LabDesk`. That prefix already exists
  in the project: the Linux packaging ships a polkit action named
  `net.lab-desk.LabDesk.install-update`, so this is not an invented identifier.
- `DEVELOPMENT_TEAM = HZF9JMC8YN`, upstream RustDesk's team, removed from all
  three configurations rather than replaced. There is no LabDesk team identifier
  until the owner holds an Apple Developer membership, and an empty team is the
  truthful state.
- `CFBundleDisplayName` and `CFBundleName` from `RustDesk` to `LabDesk`, and
  `CFBundleURLName` from `com.carriez.rustdesk` to `net.lab-desk.LabDesk`.
- `Runner.entitlements` reduced to an empty dictionary carrying the reason.
  Upstream asked for `aps-environment`, which needs a membership and which this
  application does not use, and
  `com.apple.developer.networking.wifi-info`, which nothing here asks for. A
  grep of `src/` and `flutter/lib/` found no SSID or network-name reader.
- The app icon set regenerated from `res/icon.png`, which already carries the
  LabDesk mark while the iOS icons still carried RustDesk's blue ring. The
  generator is committed at `flutter/tool/make_ios_app_icons.py`. It writes
  square opaque images with no alpha and no pre-applied rounding, because the
  App Store rejects a marketing icon with an alpha channel and iOS applies its
  own corner mask.
- The camera and photo library purpose strings rewritten to say what LabDesk
  actually does with each.

Both plists were parsed with `plistlib` after editing, and all three files kept
their CRLF endings.

**Left alone on purpose.** The `rustdesk://` URL scheme. It is parsed by shared
Dart in `flutter/lib/common.dart` and declared in the Android manifest, so
renaming it is a coordinated change across three clients rather than an iOS
decision. It is recorded in `docs/IOS.md` as an open branding item.

**Unverified.** None of these values has been seen in a built application yet.
The workflow reads the bundle identifier and display name out of the built app
and prints them, so the first green run will either confirm them or not.

**Still upstream's answer.** `ITSAppUsesNonExemptEncryption` is `false` in
`Info.plist` and has not been checked against what the Rust core actually does
with cryptography. Answering it truthfully is a Tier 1 item and its own piece of
work.

## Piece 3: the machine list, Tier 1 item 4

Written test first. The seven tests in
`flutter/test/labdesk_ios_machine_list_test.dart` were red before the widget
existed and are green now; the whole `flutter test -j 1 test/labdesk_*.dart`
gate passes at 350 tests.

The find that shaped it: `buildMachineRows` in
`flutter/lib/labdesk/console_data.dart` is plain Dart with no FFI and no
platform gating, and `LabDeskPeerStatusStore` already holds real per-peer
three state reachability. So the phone did not need a reachability model of
its own; it needed a list widget over the one that exists. Two
implementations of three states would have drifted, and the desktop one is
the one dvonr-02 named as correct.

Worth recording because it was checked rather than assumed: the store does
get fed on the phone. `_attachLabDeskStatus` in
`flutter/lib/models/peer_model.dart` registers the online-state handler once
for the whole application, and `flutter/lib/common/widgets/peers_view.dart`,
which the mobile peer tabs use, already calls `bind.queryOnlines`. So the
dots carry real answers rather than sitting at unknown forever.

Also worth recording, because it contradicts a first reading: the shared
`getOnline` in `flutter/lib/common/widgets/peer_card.dart` still renders the
old two state model, a global `labdeskStatusChecking` flag plus a boolean,
so a peer nobody has asked about draws red there. That widget is shared with
the desktop client and was left alone. The machine list does not use it.

Files: `flutter/lib/mobile/widgets/machine_list.dart` (pure, no FFI),
`flutter/lib/mobile/pages/machines_page.dart` (wiring), one gated insertion
into `flutter/lib/mobile/pages/home_page.dart`. `dart analyze` on all three
returns four infos and no errors; three are `withOpacity` deprecations,
which the rest of this codebase also carries, and one is a pre-existing
`WillPopScope`.

**Unverified.** Nobody has looked at this list running. Widget tests prove
the rules, not the look, and the look cannot be judged until the simulator
job is green.

## Piece 4: the encryption declaration, Tier 1 item 9

`ITSAppUsesNonExemptEncryption` was `false`, inherited from upstream. It is
now `true`, and the reasoning is in `docs/IOS.md` with both Apple pages
cited.

The code side, read rather than remembered: `libs/hbb_common/Cargo.toml`
pulls `sodiumoxide 0.2`, and `src/common.rs`, `src/client.rs`,
`src/server.rs` and `src/custom_server.rs` use `crypto::box_`,
`crypto::secretbox`, `crypto::sign` and `crypto::hash::sha256`. Transport is
`tokio-rustls` with `ring` and `rustls-platform-verifier`, so the TLS is the
application's own rather than the system's. `openssl` is scoped in
`Cargo.toml` to Linux and Android and is not compiled for iOS.

The Apple side: the exemption is for an app whose encryption is limited to
what is within the Apple operating system. This one bundles libsodium and a
TLS stack, so it is not that app, and Apple says the developer carries the
liability for claiming an exemption inaccurately.

**Unverified, and owner work.** Whether a French encryption declaration is
needed depends on distributing in France, and whether anything more than
self classification is needed is a determination against the Export
Administration Regulations that Apple explicitly leaves to the developer.
Nothing has been filed and there is no account to file it against.
`ITSEncryptionExportComplianceCode` is left absent on purpose: that key
holds a code Apple issues after approving uploaded documentation, and
writing one there would be inventing it.

## Piece 5: leaving a session in a pocket, Tier 1 item 7

Written test first again. Six tests in
`flutter/test/labdesk_ios_background_grace_test.dart` were red before
`flutter/lib/mobile/background_grace.dart` existed.

What was there before: `_RemotePageState` already mixed in
`WidgetsBindingObserver` and already overrode
`didChangeAppLifecycleState`, but only to sync the clipboard on resume.
Nothing closed a session on background, so a phone in a pocket left the far
end showing somebody connected to it.

The iOS-shaped part, which is why the policy is checked twice rather than
once. A timer alone is not enough: iOS suspends the process shortly after
backgrounding and a suspended process runs no timers. So the timer handles
the case where the app still has runtime, and gives the far end a real
disconnect, while the way back to the foreground re-checks the elapsed wall
clock and closes a session that outlived its grace while suspended. Both
callers ask the same clock-free value type so they cannot disagree.

One test exists because of a bug it would otherwise invite: a clock that
jumps backwards produces a negative elapsed time, and treating that as an
expired grace would drop the operator at random.

Gated to iOS. Android keeps a session alive deliberately, running a
foreground service and able to be the controlled side.

**Unverified.** Nobody has watched this happen. The policy is proved by
tests; the wiring into the session screen is not, and backgrounding under
real memory pressure is something a simulator cannot show anyway.

## The verification loop so far, failure by failure

Named verifier: the `simulator` job of `.github/workflows/ios-verify.yml`
produces screenshots of the running application. Nothing about a screen is
claimed until that job has produced one. Attempts, in order:

**Run 33982913736.** Reached the Rust build and stopped there, as expected,
because dvonr-02's iOS compile fix was not yet on the branch. It answered
the question the whole approach rested on: `Install vcpkg dependencies`
succeeded in 8 minutes 31 seconds against the `arm64-ios-simulator`
triplet. No Intel runner is needed and none exists.

**Run 33983869505.** Carried the compile fix. vcpkg passed again, the
bridge restored, and the Rust build failed on something new:

    thread 'main' panicked at libsodium-sys-0.2.7/build.rs
    Unknown iOS build target: aarch64-apple-ios-sim

`sodiumoxide` pins `libsodium-sys 0.2.7`, whose build script maps the
target triple to an iOS build flavour and panics on any triple it does not
recognise. That crate predates the simulator triple, and upstream
sodiumoxide is unmaintained, so waiting for a release is not a plan.

Reading its `build.rs` rather than guessing at a workaround: `main` checks
`SODIUM_LIB_DIR` first and calls `find_libsodium_env`, returning before
`build_libsodium` and therefore before `make_libsodium`, which is where the
panic lives. So a prebuilt libsodium removes the problem without patching
or vendoring anything. The job now installs `libsodium:arm64-ios-simulator`
through the vcpkg that is already there and points `SODIUM_LIB_DIR` at it.
The device build in `flutter-build.yml` is untouched: it targets
`aarch64-apple-ios`, a triple that crate does recognise.

Source for the build script reading:
<https://raw.githubusercontent.com/sodiumoxide/sodiumoxide/master/libsodium-sys/build.rs>,
read 2026-09-05.

## A correction: the icons were already somebody's job

The first version of the icon work was a Python script,
`flutter/tool/make_ios_app_icons.py`, written because `res/icon.png` is a
rounded tile with transparent corners and iOS wants square opaque art. It
is deleted.

`flutter/pubspec.yaml` already carries `flutter_launcher_icons` as a direct
dependency with a complete `flutter_icons` block pointed at `res/icon.png`
and `remove_alpha_ios: true`. The script was custom code for a job an
installed and configured dependency already did. Running
`dart run flutter_launcher_icons` regenerates them, and the iOS icons in
this branch are now its output; the Android files it also rewrote were
reverted, since that client is another lane.

The one thing worth knowing, checked rather than waved away: the tool
flattens the transparent corners onto black, so the raw 1024 asset has
black corners while the hand-written script had extended the artwork into
them. `res/icon.png` rounds at 390 in a 2048 tile, 19 percent of the width,
and the mask iOS applies to an app icon is wider than that, so those black
pixels sit where iOS cuts. The two outputs should be indistinguishable on a
home screen. Should be, because that is a reading of the geometry and not
yet a screenshot, which is why the verification job now takes one of the
home screen: it shows the icon and the display name as iOS renders them,
and it is the only thing that settles both the rebrand and this paragraph.

### Run 33985338173, and two things it taught

The libsodium step, the one added to get past the `libsodium-sys` panic,
failed itself:

    CMake Error at scripts/cmake/vcpkg_configure_make.cmake:721
    libsodium requires autoconf from the system package manager

The vcpkg libsodium port builds through `vcpkg_configure_make` and needs
autoconf, automake and libtool present on the machine; the ports do not
install them for themselves. The job installed only nasm and yasm, which is
what the ffmpeg and aom ports want. Fixed by installing all five.

Worth separating: the vcpkg step itself succeeded again, so the
`arm64-ios-simulator` triplet install is now confirmed twice rather than
once. The failure was in the newest and least proven step in the job, which
is the right place for a failure to be.

The general rule behind that, worth having because the error message does
not state it: the ffmpeg and aom ports want nasm and yasm, the ports that
go through `vcpkg_configure_make` want the autotools, and a job's package
list has to satisfy the union of what every port it builds needs rather
than whichever port somebody added first. Adding a port to a vcpkg manifest
can therefore break a job that never mentions that port.

The second thing is not about iOS at all and belongs to whoever owns CI.
vcpkg printed:

    warning: The 'x-gha' binary caching backend has been removed.
    on expression: clear;x-gha,readwrite

`VCPKG_BINARY_SOURCES: "clear;x-gha,readwrite"` is set at workflow level in
`flutter-build.yml` and inherited by every build in this repository. Since
that backend was removed from vcpkg, the setting caches nothing and only
emits a warning, which means every job rebuilds its vcpkg ports from source
every time. For this job that is about eight and a half minutes a run; for
the Windows, Linux, Android and macOS builds it will be considerably more.
This workflow now sets no `VCPKG_BINARY_SOURCES` at all and says why,
because carrying a dead setting suggests a cache that does not exist.
Passed to dvonr-02 rather than changed, since it is their workflow.

### Run 33987037867: past libsodium, stopped by clang

The autoconf fix worked and so did the libsodium one. The vcpkg step, the
libsodium step, the toolchain and the bridge restore all passed, and the
Rust build ran for about three minutes before stopping on a third distinct
cause:

    error: failed to run custom build command for `coreaudio-sys v0.2.15`
    unable to generate bindings: ClangDiagnostic("error: version 'sim' in
    target triple 'aarch64-apple-ios-sim' is invalid")

`coreaudio-sys` generates its bindings with bindgen, and bindgen hands the
Rust target triple straight to clang. Rust spells the iOS simulator with a
`-sim` suffix; clang spells it as a `-simulator` environment and rejects
the Rust spelling outright. Nothing is wrong with either tool, they just
disagree, and the crate passes the string through without translating it.

Worth stating because the error text misleads: it blames the triple, which
sends the next reader hunting for a typo in their own configuration. There
is no typo. `aarch64-apple-ios-sim` is the correct and only Rust name for
that target. clang simply does not accept that spelling, and the crate hands
it over untranslated.

Fixed through bindgen's own escape hatch rather than by patching or
vendoring the crate: `BINDGEN_EXTRA_CLANG_ARGS` is exported for the cargo
step with `--target=arm64-apple-ios-simulator` and the simulator SDK as the
sysroot. The sysroot goes with it because a simulator build wants the
simulator SDK's headers, and every bindgen crate in this build is building
for the simulator. The device build is untouched, as ever: it uses
`aarch64-apple-ios`, which clang accepts.

This is the third dependency to be surprised by the simulator triple, after
`libsodium-sys` and the vcpkg triplet question. The pattern is worth naming:
the device target is well travelled and the simulator target is not, so
anything that maps or forwards a triple is a candidate to break, and the
fix is usually an environment variable the crate already respects rather
than a change to the crate.

### An impact check on the tab insertion, and a process correction

Adding a Machines tab to the phone's home page shifts every tab index after
it, so anything reading a tab by index could be off by one. Checked through
the codebase graph rather than by grepping and hoping: `HomePage` has
exactly two consumers outside its own file.

`flutter/lib/models/chat_model.dart:425` reads `isChatPageCurrentTab`, which
is `isAndroid ? _selectedIndex == _chatPageTabIndex : false`, and
`_chatPageTabIndex` is only assigned inside the Android branch of
`initPages`. The new tab is gated to iOS, so no Android index moves and the
iOS answer was already constant false.
`flutter/lib/mobile/pages/settings_page.dart:1078` calls `refreshPages`,
which re-runs `initPages` and does not depend on an index.

No off by one was introduced.

The process correction is worth writing down too. The operating rules say to
consult the codebase graph before file-by-file exploration and never to
answer a callers-or-impact question with a blind grep. This session did the
opposite for most of the day: it grepped. The graph turned out to hold this
repository at 14,720 nodes and 56,306 edges the whole time, and answering
"who uses HomePage" took one query where grep would have taken several and
would not have distinguished a definition from a use.

### Run 33988135105: coreaudio fixed, vcpkg-rs picks the wrong triplet

The bindgen fix worked. coreaudio-sys built, and the Rust build went
further than it ever has before stopping on the fourth instance of the same
pattern:

    error: failed to run custom build command for `magnum-opus v0.4.0`
    opus_ffi.h:1:10: fatal error: 'opus/opus_multistream.h' file not found

The log names the cause without ambiguity, two lines above the error:

    cargo:info=arm64-ios
    cargo:include=.../vcpkg/installed/arm64-ios/include

The `vcpkg-rs` crate maps the Rust target to a vcpkg triplet itself, and for
`aarch64-apple-ios-sim` it chooses `arm64-ios`, the device triplet. The only
triplet installed in this job is `arm64-ios-simulator`, so the include
directory it went looking in does not exist.

Fixed with `VCPKGRS_TRIPLET=arm64-ios-simulator`, which is that crate's own
documented override: "Use this to override vcpkg-rs' default triplet
selection with your own." (<https://docs.rs/vcpkg/latest/vcpkg/>, read
2026-09-05.)

The tempting wrong fix is worth naming, because it would have gone green
for a while: installing the `arm64-ios` triplet as well would satisfy the
header search immediately, and then link device slices into a simulator
binary. That fails later, further from its cause, and possibly not until
the app refuses to launch.

Fourth dependency, fourth escape hatch the tool already had, and no crate
patched yet.

## The bar, written before anything is judged against it

The brief asks for a gauntlet loop: one concrete bar, pieces judged alone,
a separate critic with fresh context per piece, looping until the critic
picks ours. The bar has to exist before the screenshots do, or it becomes a
description of whatever was built.

The reference is TeamViewer's iOS app, and the useful part of the research
brief is not its feature list but its review feed: 50 most recent reviews,
2026-02-06 to 2026-08-28. What that app loses users over is not missing
features. It is, in order of count: the licence gate, pointer precision
(six reviews, missed clicks and external mouse), connection drops (six),
sign-in that does not persist (three, one of them logged out within three
minutes of closing a connection), on-screen controls that are almost
impossible to see, no dark mode, and a session left open in the background
draining a phone from 100 percent to 9 in a couple of hours.

So the bar, per piece, is a thing a critic can check in a screenshot or a
log rather than a matter of taste:

1. **The machine list.** A machine nobody has asked about is visibly not the
   same as a machine that answered and is down, at a glance, without reading
   a word. Every row's state is legible in one look at a phone-sized image.
   No row invents a time it does not have.
2. **Both appearances.** The dark screenshot and the light screenshot differ,
   and text is readable in both. The reference app has a review complaining
   there is no dark mode at all.
3. **On-screen controls.** Anything overlaid on a session is legible against
   whatever is behind it. The reference app has a review saying its controls
   are almost impossible to see.
4. **First run.** A fresh install asks for nothing it does not need yet: no
   camera prompt, no notification prompt, no permission dialog in the first
   screenshot. Statically this already holds (no permission plugin is
   invoked at launch, and AppDelegate registers no push), but the first
   screenshot is what proves it.
5. **Backgrounding.** A session left in the background stops, and the log
   says so. This is the battery complaint, and it is item 7.
6. **Staying signed in.** A sign in survives a relaunch. The token is kept
   in the local option store and `runMobileApp` calls
   `refreshCurrentUser` at launch, so this should already hold; proving it
   needs a real lab-desk.net account, which is named as a limit rather than
   assumed away.

Pointer precision and connection drops, the two largest complaint themes,
cannot be judged on a simulator at all. They are named here so that nothing
later claims the bar was cleared when only the part a simulator can see was.

## A finding that gives Tier 1 item 2 its point

A fresh LabDesk install on a phone, before anybody configures anything,
registers with RustDesk's public rendezvous server. This was traced rather
than suspected.

`Config::get_rendezvous_server` in `libs/hbb_common/src/config.rs:913` tries
four sources in order and then falls back:

1. `EXE_RENDEZVOUS_SERVER`, written in exactly one place in the tree,
   `src/platform/windows.rs:2197`, from the licence embedded in the
   installer executable. There is no such mechanism on iOS.
2. the `custom-rendezvous-server` option, which is empty until a server
   profile is set or a sign in writes one.
3. `PROD_RENDEZVOUS_SERVER`, which a grep of `src/` and `libs/` shows is
   read in three places and written in none, so it is always empty.
4. `CONFIG2.rendezvous_server`, empty on a fresh install.

Then `RENDEZVOUS_SERVERS`, which is `["rs-ny.rustdesk.com"]`
(`config.rs:120`) with `RS_PUB_KEY` beside it, RustDesk's own key.

So the phone has no LabDesk server until somebody gives it one, and in the
meantime it talks to upstream's infrastructure under upstream's key. That
is precisely what Tier 1 item 2 asks for, a first run that asks for a
server profile or the lab-desk.net sign in, and this is the reason the item
exists rather than a matter of polish. The first screenshot from the
verification job will be of an application in exactly this state.

The reason this matters is not the hostname. `RS_PUB_KEY` at `config.rs:121`
is upstream's public key, and it is pinned beside the fallback server, so an
unconfigured client is not merely reachable through somebody else's broker,
it is trusting somebody else's key material for the rendezvous exchange.
"Registered nowhere" and "registered with another party's broker under that
party's key" are different sentences, and the second is the one that is true
today. It follows that changing the hostname alone would not finish the job:
the pinned key has to change with it, and a LabDesk client should carry no
upstream key material as a fallback at all.

**Resolved by the owner, 2026-09-05.** LabDesk defaults to a LabDesk public
server, never to RustDesk's. That server does not exist yet; dvonr-02 owns
building it, with its own threat model rather than as a constant swap. For
this lane it means the first run screen is offered rather than required and
can be skipped, and the empty state names the server the client fell back to
instead of showing a blank. The screen is still being built against the
stricter no-default reading, because one that works with no default also
works with one and the reverse is not true. Until that server and its pinned
key are real, any default written here is a placeholder and says so.

Worth flagging beyond iOS: nothing here is iOS specific except the absence
of the Windows installer path, so an Android build and a desktop build
started without the installer licence land in the same place. That is
another lane's call, and it has been passed to dvonr-02 rather than acted
on here.

## Piece 6: first run, Tier 1 item 2

Written test first: nine tests in
`flutter/test/labdesk_ios_first_run_test.dart`, four on the rule and five on
the screen, red before
`flutter/lib/mobile/widgets/first_run.dart` existed. The gate is at 370.

The rule is that the phone asks when it has nothing: no server profile and
no sign in. A sign in counts as having one because signing in is what writes
the server, and a skip counts because asking twice for something already
declined is nagging rather than onboarding. Stated as a plain function over
three booleans so it can be read and tested without configuration.

One test earns its place more than the others: it asserts that the words
camera and notification appear nowhere on the screen. That is Tier 1's
"asks for nothing but a server profile or the sign in" turned into something
that fails if somebody later adds a permission prompt to onboarding.

The copy problem, and how it was avoided. The screen wants to say which
server the client is on, but there is no FFI that returns the effective
rendezvous server; `main_get_api_server` exists and no equivalent for the
rendezvous does. Adding one means touching `src/flutter_ffi.rs` and
regenerating the bridge, which is another lane and a heavy change for a
sentence. So the screen names the configured server when there is one and
otherwise says the built in default is in use, without inventing a name for
it. `bind.mainIsUsingPublicServer` reports the same condition, and
`using_public_server` in `src/common.rs:2108` is literally "no custom
rendezvous server is set", so nothing here is a guess about what the core
does. When dvonr-02's LabDesk server exists, that sentence can name it
without the screen changing shape.

**Unverified.** Not seen running, and whether it appears at the right moment
on a genuinely fresh install is a thing only a fresh install shows.

## Open items

- Rebase onto `feat/labnet` once `82a6d8f27` is pushed there, then rerun the
  verification workflow and read the screenshots.
- Nothing has been added to `CHANGELOG.md` yet. There is no iOS build a user
  can obtain, and the file is shared with another session's work in flight, so
  one entry covering the lane will be written when the first green simulator run
  produces a downloadable artifact.
