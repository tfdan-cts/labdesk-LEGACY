---
type: log
created: 2026-09-05
status: active
supersedes: nothing
related:
  - docs/plans/2026-09-05-001-production-program.md
  - docs/plans/2026-09-05-002-phase1-contracts.md
---

# Phase 1 session notes

Written in the client repository while the vault (`~/trapLab-brain`) is under a data-loss
incident owned by another session; the lead merges these into the vault's development log after
recovery. One entry per lane and round, newest last.

## Client lane, RUST CORE, round 1 (2026-09-05)

What landed, all on `feat/labnet`:

- `Cargo.toml`: `Win32_NetworkManagement_IpHelper` added to the `windows` features as its own
  commit, the way WP10's two were, so CI proves the feature string before code is written
  against it.
- WP10, the disk platform layer, proven on real hardware for the first time. homebox-devserver
  (Lubuntu 26.04, kernel 7.0.0-30) carries a Micron 3400 NVMe and a Seagate ST1000VX008 SATA
  disk. A harness that compiled `src/labdesk/disk/` verbatim (source hashes recorded beside the
  output) ran as root: `NVME_IOCTL_ADMIN_CMD` answered the 512 byte log page (temperature 27 C,
  4,500 hours, 1 percent used, verdict `ok`, source `nvme_logpage`) and `SG_IO` with the ATA
  PASS-THROUGH(16) CDB answered the attribute table with a valid checksum (verdict `ok`, source
  `ata_smart`). Unprivileged, both refused and both drives reported `unreadable` with source
  `sysfs`, never `ok`. Three defects found by the hardware and fixed, tests first: attribute 9
  on the Seagate carries a second counter in its upper bytes (71 trillion hours as read; the low
  24 bits, 47,210, are the hours); the NVMe hwmon sits on the controller
  (`/sys/class/nvme/nvme0/hwmon1`), not under `device/`; and neither drive's firmware was read
  from sysfs. Both captures are committed as fixtures with their provenance in
  `src/labdesk/disk/fixtures/README.md`. `labdesk --disk-health` is the harness the crate now
  offers for the same check on any machine.
- WP13 on the agent: `src/labdesk/tools.json` (the catalog, byte for byte the Worker's copy) and
  `src/labdesk/tools.rs` (parse and check the catalog, validate parameters, build argv, run each
  step with `std::process::Command` under one timeout, cut output to 16 KiB with its SHA-256,
  refuse `already_ran` from a 256 entry ledger beside the identity file). The collector reads
  `jobs` and `collectNow` from the batch answer, runs jobs on a thread of their own, and sends
  at most four `jobResults` a batch. Section 11 of the contracts records the divergences: the
  pattern subset, the leading `-` refusal, the seat0 user appended to `power_logoff` on
  Linux, Linux `active_user` entries running in the daemon, Windows launches whose exit
  status is not observed. The site lane wrote its `tools.json` first (labels and 30 s power
  timeouts); the client adopted those bytes, and `cmp` of the two copies is silent.
- WP15, the ticket claim path: `Data::ConnectTicket` over the main IPC channel,
  `insert_pending_ticket` and `claim_pending_ticket` in `src/server/connection.rs` beside the
  switch-sides map (`cargo test claim_once`), the hook at the top of `validate_password`, the
  `handle_hash` branch in `src/client.rs` with `PasswordSource::Ticket`, and
  `src/labdesk/ticket.rs` reading `tickets` from the batch answer and delivering them.
- The self-heal switch: `selfheal::enabled()` parses the daemon's config file on every tick,
  `start()` spawns always, and the running step is published as `net.reachability`.
- The network view: `src/labdesk/netview.rs` walks `getifaddrs` on Linux and macOS and
  `GetAdaptersAddresses` on Windows, the collector sends `net.adapters` and `net.reachability`
  in the `attrs` member with the change rules in section 11 of the contracts.

How it was checked before CI: the pure parts (`tools.rs`, `netview.rs`, `ticket.rs`,
`selfheal.rs`) were compiled and their 25 tests run on homebox in a shim harness
(`gauntlet-evidence/p1-rust-core/round-1/`); the disk module's 64 tests ran there too after the
fixes. `collector.rs`, `ipc.rs`, `connection.rs`, `client.rs` and `core_main.rs` are proven by
the CI run on the pushed head only.
CI then found two build gates the harness could not: `PENDING_TICKETS` sat behind the
`flutter` feature (the drm and i686 jobs build without it) and the `handle_hash` ticket block
referenced `crate::labdesk` on Android, where `lib.rs` does not compile the module; both are
`cfg` fixes, no logic changed.

The Windows network walk, added after that round. Two gates, and it matters which is which:
`.github/workflows/ci.yml` is the workflow that RUNS the tests and it builds Linux only (one
uncommented matrix row), so it compiles nothing behind `#[cfg(target_os = "windows")]`; what it
asserts about the Windows arm is `netview::windows_kind`, which is free of `cfg` and carries the
whole `IfType` classification. `Full Flutter CI` (`.github/workflows/flutter-ci.yml`, which runs
on every pull request) is the workflow that COMPILES it: run 33968145857 on head 6df79e172 is
green with `run-ci / x86_64-pc-windows-msvc`, `run-ci / i686-pc-windows-msvc` and
`run-ci / aarch64-pc-windows-msvc` all success, so the call, the two added `windows` features and
the struct layouts build on all three Windows targets. That workflow builds and does not test.
The call's behaviour was proven by compiling and running it on this Windows workstation against
the real `src/labdesk/netview.rs` bytes, in a harness that supplies only the sampler's `Networks`
(`gauntlet-evidence/p1-rust-core/round-4/`): 34 raw entries folded to 10 adapters, loopback
dropped, prefixes 8, 16, 20, 24, 32, 64 and 128 read straight off `OnLinkPrefixLength`, and
`cargo test` green on all 7 tests in the module including `the_walk_finds_this_machines_interfaces`
and `the_if_type_numbers_are_the_crates`, which asserts the three `IfType` numbers against the
`windows` crate's own constants.

Open after this round:

- The site repository's copy of the contracts, `docs/phase1-contracts.md`, needs the same edit
  to item 7 of section 11 that this round made to
  `docs/plans/2026-09-05-002-phase1-contracts.md` (the two `windows` features the call really
  needs, and `FriendlyName` as the adapter name). The two copies are byte identical by that
  document's own rule and only the site lane can land its half.
- A second Windows machine for the network walk. Foundry was offline for this round
  (`tailscale status`: "offline, last seen 1h ago" on `centaur-diminished.ts.net`, ssh to
  100.81.16.49 timed out), so `net.adapters` is proven on one Windows box, this workstation,
  and by three Windows compile targets in CI. The static harness binary is in
  `gauntlet-evidence/p1-rust-core/round-4/netview-harness.exe` and runs on Foundry unchanged
  when it comes back.
- The exit status of an `active_user` launch on Windows.
- Field checks that need a built binary: `labdesk --disk-health` on homebox from the branch's
  own Linux build (the harness proved the module, not the shipped binary) and on Foundry, where
  the QEMU virtual disks cannot prove SMART and the honest expectation is `unreadable`; the
  self-heal switch flip on both; a job end to end and a ticket end to end, which also need an
  enrolled machine and therefore an owner-minted token.
- `CHANGELOG.md` and the program plan's phase 1 row carry another session's uncommitted edits
  in this checkout and were left alone.

## Site lane, WORKER CORE, rounds 1 to 3 (2026-09-05)

What landed on `feat/labnet-broker` = `dev`, deployed to lab-desk.net:

- `99e83df`: the tool catalog (`src/worker/tools.json`, nine v1 entries, and `tool-catalog.ts`
  enforcing every rule of contracts section 1), the job outbox (`routes/jobs.ts` under `/api`
  and `/console`: request, approve by an owner other than the requester on a fresh sign-in,
  refuse, list, read one), the batch wire (`jobs`, `tickets`, `collectNow` in the answer;
  `jobResults` and `attrs` in the request), the connect ticket minted beside the session grant
  and reported claimed on `POST /agent/ticket/:id/claimed`, the console read routes
  (`machines?state=1`, `machines/:id/state`, `/metrics`, `/disks`, `events` and `ack`,
  `PATCH machines/:id`, `attrs` on the machine answer), a `runTool` firing writing a job row
  from `scheduled.ts`, and migration `0011_job_urgent.sql`, applied to production D1.
- `b86f288`: the wrong organization, wrong role and narrowed member cases for approve, refuse,
  one job, metrics and disks, after the round 1 critic found the suite held none.
- Round 3 was a verification pass on `b86f288` with no code change: `npx tsc --noEmit` clean,
  the suite run serially, `cmp` of the two `tools.json` copies, production probes with a
  browser user agent (every new route 401 JSON unsigned, `/agent/*` 401 "no machine
  signature", `/console/nothing` 404 JSON), and a hand review pass with three P3 notes
  (a job may be requested against a revoked machine and then expires undispatched; an attrs
  key `__proto__` is dropped rather than refused; the minute tick's expiry update has no
  serving index). Evidence under the session scratchpad
  `gauntlet-evidence/p1-worker-core/round-3/`.

Recorded for the client lane: the two `tools.json` blobs are identical in git
(`652f3923addf13646b88498dbf00beaa2e22ac25` on both sides), but this repository's
`.gitattributes` `text=auto` checks the file out with CRLF on Windows, so a working-tree `cmp`
on a Windows checkout differs at byte 2 while `git show HEAD:src/labdesk/tools.json` matches
byte for byte. A `src/labdesk/tools.json text eol=lf` line would make the working-tree `cmp`
silent everywhere; it is the client lane's file to change.

Open after these rounds: no signed-in production request (the program seeds no account); a job
and a ticket end to end need an enrolled machine and therefore an owner-minted token; WP17's
pages and the rules presets are their own pieces.

## Client lane, RUST CORE, round 2 (2026-09-05)

The round 1 critic found WP15 dead on the controller: `handle_hash` in `src/client.rs` read the
option `labdesk-ticket-<peer id>` and nothing wrote it, so no ticket was ever presented and the
target's claim-once map was never exercised. Closed in this round, tests first:

- `flutter/lib/labdesk/services/overlay_broker.dart`: `SessionGrant` carries `ticket`, the
  `secret` of the `ticket` member `POST /console/overlay/session` answers (contracts section 3),
  empty when the Worker minted none.
- `flutter/lib/labdesk/services/overlay_session.dart`: `prepare` writes `labdesk-ticket-<peer
  id>` after the address and key hints when the grant carried a ticket; `release` clears it with
  the other two. `handle_hash` already clears it on use, so a ticket is presented once and never
  lingers past the grant.
- `flutter/test/labdesk_overlay_session_test.dart` and `labdesk_overlay_broker_test.dart`
  assert both, and the case of a grant without a ticket. Gate: `flutter test test/labdesk_*.dart`
  343 pass, `flutter/pubspec.lock` restored.
- `docs/CONSOLE.md`: "A session" names the third option; "Connect tickets" no longer claims
  nothing touches disk on either side. The controller holds the plaintext in its options file
  for the seconds between the grant and the connect (the same file the two overlay hints live
  in), cleared on use and on release; the target keeps the hash in memory only.
- `.gitattributes`: `src/labdesk/tools.json text eol=lf`, so a working-tree `cmp` against the
  Worker's copy is silent on a Windows checkout too (the site lane's note above).

What this round did not change: the Rust side (`src/client.rs`, `src/labdesk/ticket.rs`,
`src/server/connection.rs`) is as round 1 left it. What remains unproven in the field: a
ticket end to end needs two enrolled machines and a signed-in console, which needs an
owner-minted token; Foundry's QEMU disks cannot prove the Windows disk path.

## Client lane, RUST CORE, round 3 (2026-09-05)

Critic gap closed: `handle_peer_info` in `src/client.rs` wrote the ticket-derived password into
the peer config when `remember` was set (only a shared address book password was excluded), so a
peer with a remembered password had it overwritten by a spent one-time hash, and the flutter
build then synced that hash to the personal address book. This contradicted the "never saved"
promise on `PasswordSource::Ticket`.

- `PasswordSource::is_storable(password, hash)`: false for a shared address book password that
  matches the sent one and for `Ticket`, true otherwise. Both save paths (the `remember` branch
  and the `sync_peer_hash_password_to_personal_ab` event behind the `flutter` feature) call it
  where they called `!is_shared_ab` before, so the shared password behaviour is unchanged and a
  ticket is excluded from both.
- `password_source_tests` (three tests beside the type) pin the rule: a ticket is never storable,
  a shared ab password is storable only when it does not match the sent one, a typed or personal
  ab password is storable.
- `docs/CONSOLE.md` "Connect tickets" states the rule.

Proof: the crate does not build on this workstation (kcp-sys needs libclang), so the red run
was not executed locally and the green is the CI run on the pushed head, recorded in the
workbench log. The disk sources are unchanged since c342c53cb, so the homebox field proof stands;
Foundry's QEMU disks cannot prove Windows.

## Site lane, WORKER CORE, round 4 (2026-09-05)

Tests only, on `feat/labnet-broker` = `dev`, commit `e13951a`, after the round 3 critic found
the suite held no narrowed-writer case for the three write routes and no test reaching the
acknowledgement's fleet branch (`routes/org.ts:214-216`).

- `test/jobs.test.ts`: a technician narrowed to `fl-jobs` asks for a job on the fleetless
  machine and is answered 404 with no `machine_job` row under their id, then 201 on the fleet's
  machine.
- `test/console-api.test.ts`: a technician narrowed to `fl-capi` gets 404 on
  `PATCH /org/machines/:id` outside the fleet with `display_name` untouched and 200 inside,
  and 404 on `POST /org/events/:id/ack` outside the fleet with `acknowledged_by` and
  `acknowledged_at` still null, then 200 inside with `acknowledged_by` set to them.

Red was proven by mutation rather than by flipping an assertion: with the machine narrowing
line in `actor()` removed the job and PATCH cases fail, and with the ack fleet branch removed
only the ack case fails, so those lines are now covered. `tsc` clean, the suite serial 28 files
466/466, site CI 33965660638 green on the head, dev build `86caaa66` deployed version
`8e3e6fe6` at 12:19:26Z, production probes unchanged (every org and console route 401 JSON
unsigned). Evidence under the session scratchpad `gauntlet-evidence/p1-worker-core/round-4/`.

## Client lane, RUST CORE, round 1 (2026-09-05)

Two commits on `feat/labnet`, `e9f76968a` and `8df27e59d`, on top of the round that built
`tools.rs`, `ticket.rs`, `netview.rs` and the self-heal file read. What was left of the piece was
the half of WP15 nothing called, and the field proof the plan asks for on real hardware.

The claim report. `POST /agent/ticket/:id/claimed` existed on the Worker and had no caller, so a
ticket's row never recorded that its one-time credential was spent and the Worker kept offering
the same ticket in every batch answer for the rest of its two minutes. The claim happens inside
`--server`, the process that answers logins, and that process holds no agent key, so it cannot
make the signed call itself.

- `src/server/connection.rs`: `PendingTicket` gains `reported`, and `take_claimed_tickets()`
  hands each claimed id over exactly once.
- `src/ipc.rs`: `Data::ClaimedTickets(Vec<String>)`, sent empty by the daemon as the question and
  answered with the ids. The `_service` channel (0666) still admits only `SyncConfig` and
  `Labnet`, so this rides the main channel alone.
- `src/labdesk/ticket.rs`: `ask()` is the one connect both `deliver` and the new `claimed()` use;
  `is_ticket_id` checks what comes back before it reaches a URL path, because on Linux and macOS
  those ids cross from a process running as the logged-in user.
- `src/labdesk/collector.rs`: `TICKET_POLL` is 5 s and the daemon asks only while a ticket it
  delivered is still live (`watch_until`), because a ticket lives 120 s, the default flush is
  300 s, and the route answers 410 past `expiresAt`.

Tests, one per behaviour: `test_pending_ticket_claim_once_per_ticket_never_for_another_peer`
gained the two assertions that the three claimed ids are reported and that a second ask has
nothing left, and `ticket.rs` gained `a_ticket_id_that_could_reshape_a_url_is_dropped`.

The field proof, and what CI now hands out. `.github/workflows/ci.yml` uploads the stripped Linux
binary as `labdesk-x86_64-unknown-linux-gnu`, which is how a machine the program may not install
anything on gets a binary to prove the disk read path with. On homebox-devserver, a real
Lubuntu 26.04 box, `sudo /tmp/labdesk-fieldcheck --disk-health` from run 33975560768's artifact
read both real drives:

- `/dev/nvme0n1`, a Micron_3400_MTFDKBA512TFH, source `nvme_logpage`, `percentUsed` 1,
  `sparePct` 100 against a threshold of 5, `tempC` 26, `powerOnHours` 4500, `mediaErrors` 0,
  `criticalWarning` 0, verdict `ok`;
- `/dev/sda`, an ATA ST1000VX008-2AY1, source `ata_smart`, `powerOnHours` 47216, `reallocated` 0,
  `pending` 0, `uncorrectable` 0, `crcErrors` 0, `tempC` 27, verdict `ok`.

That reading is what found the second commit. The SATA drive came back with `bus` `unknown`
beside its `ata_smart` source, because `probe_linux` named the bus from the device name and had
no value for anything that is not an NVMe namespace. A drive that answers ATA PASS-THROUGH with a
SMART table is an ATA drive whatever controller is in front of it, so the branch that parses its
attributes now says so.

Proof: the crate does not build on this workstation (kcp-sys needs libclang), so the green is CI
on the exact head. CI 33975560768 is success on `e9f76968a` with 250 tests passed including the
two new ones, and 33976803049 on `8df27e59d`. Nothing was installed on homebox: the binary was
copied to `/tmp` and run from there.

Open at this head: no Windows disk proof exists in this phase, because trapLab-Foundry is off
limits by owner order and its disks are virtual in any case; the round 4 critic's gap, that the
Windows adapter walk's `FriendlyName` keying of the sysinfo counters map is source read and not
proven at runtime, is still open and could not be closed this round because the workstation had
under 1 GB of free memory; `HealConfig::from_options` still reads the three self-heal tuning
options from process memory, so on Windows only the switch itself survives a daemon that was
started before the change; and section 3's delivery timing (a ticket lives 120 s while the
default flush is 300 s) is recorded as contracts section 12 correction 6 and belongs to the site
lane.

## Client lane, LINUX DELIVERY (WP19), round 1 (2026-09-05)

Linux received no update at all. `src/updater.rs` had a `windows` arm and a `macos` arm and
nothing else, and `res/DEBIAN/postinst` only symlinked the binary and enabled the service, so a
Linux machine could learn that a new version was offered and had no way to install it. An earlier
attempt at this package was reverted because it called
`/usr/share/rustdesk/labdesk-helper`, a path no package this repository builds produced. This
round starts where that one should have: with the file.

What landed, on `feat/labnet`, heads `462889346`, `84da030f8` and `489339fc1`:

- `res/labdesk-helper` and `res/polkit/net.lab-desk.LabDesk.policy`, staged by `build.py` into
  `/usr/share/rustdesk/labdesk-helper` and `/usr/share/polkit-1/actions/` on both deb paths
  (`build_flutter_deb` and `build_deb_from_folder`) and installed by both flutter rpm specs.
  `system2` exits the build on a failed command, so a deb that exists is a deb that carries them.
- The helper is the fence, not a wrapper. `pkexec` authorizes through
  `org.freedesktop.policykit.exec` against the program it launches and reads the action id from
  that program's own annotation, so `pkexec dpkg -i <file>` was authorized as dpkg, under dpkg's
  annotation, and installed whatever package it was pointed at. The helper copies the package into
  a root-owned 0700 directory first and everything after that reads the copy: the name and version
  out of the copy, a refusal of any version that is not newer than the installed one, the digest
  lab-desk.net publishes for that asset of that release, and an install only of bytes that hash to
  it. The digest is fetched, never taken from the caller, because a digest the caller supplies
  proves only that the caller knows the hash of its own file.
- `crate::updater::start_auto_update_linux`, started from `start_os_service` in
  `src/platform/linux.rs`, which is the root process the unit starts; `--server` is the desktop
  user's and cannot install a package. It asks that `--server` over IPC whether a session is live
  (`Data::HasNoActiveConns` is no longer macOS only) and reads an unanswered question as a live
  session. The install goes to the helper through `systemd-run` and NOT as a child of the service:
  `res/DEBIAN/preinst` stops `rustdesk.service` on an upgrade and `KillMode=mixed` then kills
  whatever is left in that cgroup, which would be dpkg part way through unpacking. `postinst`
  starts the service again on the new binary. `res/DEBIAN/postinst` needed no change; polkit picks
  the action file up from the packaged path by itself.
- One test, `updater::linux_tests::the_linux_asset_url_is_one_the_release_allowlist_accepts`, on
  the one seam a mistake would hide in: a wrong asset name is not a visible failure, it is a 404
  and a machine that quietly never updates.
- `docs/CONSOLE.md` said a Linux machine receives no unattended update at all. It now describes
  the arm that installs one. The architecture's corrections block, item 3b, is rewritten from
  "built and reverted, still outstanding" to what was built.

Proof, in the order it was taken.

Before any build: the helper and the policy copied to homebox-devserver by hand. `pkaction` reads
the action with its `auth_admin` defaults and its `exec.path` annotation; `pkexec` executes the
script (it printed the helper's own usage line), which is the question the design turned on. The
helper refused a genuine published `labdesk-1.2.4-x86_64.deb` as not newer than the installed
1.2.4 (exit 67), refused a relative path (64), refused a repacked 9.9.9 deb because lab-desk.net
publishes no digest for it (68, and the site answers 404 for that URL), and refused a named pipe
wearing an asset name (66). `dpkg-deb` will not build a package whose version is a path, so the
version-shape check the round added is belt and not braces.

CI: run `33980760549` is success on `84da030f8`, 251 tests passed, with the new test named in the
log. The crate does not build on this workstation (kcp-sys needs libclang), so every Rust claim
here is that run plus the field check below.

Two dispatch builds, because an update needs a version the installed one is behind: `p1-linux-1`
at 1.2.5 and `p1-linux-2` at 1.2.6. The 1.2.5 deb carries
`./usr/share/rustdesk/labdesk-helper` (root/root, 755) and
`./usr/share/polkit-1/actions/net.lab-desk.LabDesk.policy` (root/root, 644), read out of the deb
with `dpkg-deb -c` before it was installed. Installed on homebox with `dpkg -i`: version 1.2.5,
service active, `pkaction` reads the action from the packaged path, `pkcheck` from the desktop
user answers `polkit.result=auth_admin`, and `pkexec` without an authentication agent refuses.

The switch. `allow-auto-update` defaults to off and the daemon's config is not
`/root/.config/rustdesk/RustDesk2.toml` as it looks: `Config::path` resolves to
`/root/.config/labdesk/`, and the root service gets its options by `Data::SyncConfig` from the
user `--server`. `sudo rustdesk --option allow-auto-update Y` is what sets it, and the root
service's `/root/.config/labdesk/LabDesk2.toml` carried it seconds later. The first check, before
the switch was on, is in the log as "Auto update is off, skipping" and is itself the proof that
the IPC session question answered, because the loop asks it before it reads the switch.

The update, unattended. `SHA256SUMS` for `p1-linux-2` was computed the way
`release-checksums.yml` computes it (`sha256sum -- *` over every asset the release carried) and
uploaded to the release, because that workflow only offers `workflow_dispatch` from the default
branch and this work is on a feature branch. The stable channel was pointed at `p1-linux-2` /
1.2.6 by the same direct D1 write with an audit row that the 2026-09-04 session used for 1.2.4 --
stable and not a beta channel because `/version/latest`, the only endpoint an installed client
asks, serves the stable row and nothing else. `/version/latest` then answered 1.2.6 and
`/releases/checksums/1.2.6/labdesk-1.2.6-x86_64.deb` answered
`03d1e8b9860038dba53ec9ce42011793335511934352d490ea4c271f5c851e39`.

One more refusal first, the only branch the earlier tests could not reach: the published 1.2.6 deb
downloaded from lab-desk.net with one byte flipped, which is newer than the installed version and
whose version the site has published, was refused with "does not hash to the digest lab-desk.net
publishes for it" and nothing was installed.

Then one command, `systemctl restart rustdesk` at 14:15:23, to bring a check that is otherwise a
day away forward. Everything after it is the machine:

    14:15:23  [root-update] The unattended update loop has started.
    14:15:54  [root-update] lab-desk.net offers 1.2.6 over 1.2.5; the release publishes
              sha256 03d1e8b9...51e39 for labdesk-1.2.6-x86_64.deb
    14:15:55  [root-update] Handing /tmp/labdesk-update-b4a418a2-.../labdesk-1.2.6-x86_64.deb
              to the update helper.
    14:15:55  labdesk-install-update.service: labdesk-helper: installing rustdesk 1.2.6 over 1.2.5
    14:15:58  labdesk-helper: rustdesk 1.2.6 installed
    14:15:58  rustdesk.service ActiveEnterTimestamp, on the new binary
    14:16:28  [root-update] No update available.

Installed version before 1.2.5, after 1.2.6, `dpkg-query -W rustdesk`. The service, `--server` and
`--tray` are all running on the new binary. The stable channel was then restored to
`v1.2.4-preview` / 1.2.4 with its full ten-platform asset map and a second audit row; it held
1.2.6 for about six minutes.

Open at this head:

- The stable channel is the only channel an installed client reads, so proving the path meant
  pointing the public one at a proof build for six minutes. It is back as found. The site has no
  way for a client to follow a beta channel, and giving it one is not this package.
- `p1-linux-2` was built from a tag at the version-bump commit, so the 1.2.6 that homebox now runs
  does not carry the two commits another lane pushed to `feat/labnet` while it built. It is a
  proof build on a throwaway tag, not a release.
- Both dispatch runs were cancelled once the deb they existed for was published, so `p1-linux-1`
  and `p1-linux-2` carry no macOS x86_64, Windows or AppImage assets, and the `SHA256SUMS` on
  `p1-linux-2` describes the assets that existed when it was written.
- The signing key is still the empty placeholder, so the helper and the client both verify a
  digest and neither verifies a signature. That is WP20 and it is unchanged by this round.
- The helper's `curl` goes straight to lab-desk.net and does not read the daemon's configured
  socks proxy, which `create_http_client_with_url_strict` does honour. A machine that can only
  reach the site through a proxy would download the package and fail at the digest fetch.
- The helper installs only the stock `rustdesk` package. The `rustdesk-unattended-wayland` variant
  has an asset name the arm does not build and would be refused by the asset-name check.
- No macOS or Windows behaviour was touched, and no rpm machine exists to test the rpm arm on; the
  rpm asset name (`labdesk-<version>-0.<arch>.rpm`) is read from `res/rpm-flutter.spec` and
  covered by the unit test, not by a field install.
- `CHANGELOG.md` and `docs/plans/2026-09-05-001-production-program.md` each carry an accidentally
  duplicated paragraph from another session's uncommitted work. They were left exactly as found
  and no changelog line was written for 1.2.5 or 1.2.6.

## Flutter console, WP18 with the network view, the self-heal switch, the presets and labnet stage 2, round 1

Client `526756bd4` on `feat/labnet` (the feature commit is `de97fe565`, the analyzer fix
`526756bd4`). Full Flutter CI run 33989733524, Dart job 101369747885, success on that exact head.
`flutter test -j 1 test/labdesk_*.dart` locally: 335 tests, all passed.

What landed is written out in section 13 of `docs/plans/2026-09-05-002-phase1-contracts.md`,
including the four places the code had to differ from the contract. What a later round should pick
up, none of which breaks anything shipped:

- The Automation section still keeps its own rule store and its own tick, because
  `src/worker/routes/rules.ts` carries only `GET /org/rules` and the enabled switch. When the
  create, delete and `/org/rules/presets` routes land, the editor moves to the organization's rules
  and `labdesk-automation` and `automation_engine.dart` go with them.
- `GET /org/machines?state=1` answers no `uptimeS` and no `loggedInUser`, so those two come from a
  round-robin `/state` read of one machine a poll. On a large fleet a card's uptime can be
  `machines * 15 s` old. Adding the two columns to the fleet projection would remove the second
  request entirely.
- Nothing here has been exercised against a signed-in console in production: no account exists for
  the program, so every route is proven by unit test against a fake wire and by the shots harness
  against fixtures.
- `flutter/lib/labdesk/screens/health_screen.dart` is still unreferenced and its wording still
  describes the PTY probe this round deleted. It is rendered only by `tool/shots/shots_test.dart`.
- The console reads no health events: `GET /console/org/events` and the acknowledgement route exist
  and nothing calls them.
- The preview harness `lib/labdesk_preview.dart` renders every new surface, but it cannot be run
  with `-d chrome`: this project has no `flutter/web` directory. The screenshots in the evidence
  directory come from the new `flutter/tool/shots/wp18_test.dart` instead, which renders the real
  widgets to PNG in a widget test and needs no device.

## Client lane, Flutter console, round 2

One defect closed, commit `8df1535a1` on `feat/labnet`. The health card branched on a single
`online` bool, so a machine whose reachability is `unknown` was captioned "Offline. Last seen 8s
ago." and sat under a heading that called it unreachable. Unknown is the absence of an answer,
not a report that a machine is down. `screens/health_board.dart` now groups the board in the
product's three states, Online, Offline and Unknown, with one caption per state, and the last
sighting is printed only where one exists. `tool/shots/wp18_test.dart` gives its unknown machine
no sighting at all, so the shot shows the absence rather than a borrowed timestamp.

`flutter test -j 1 test/labdesk_*.dart`: 337 tests, all passed, including the new
`test/labdesk_health_board_test.dart`. `dart analyze` on the changed files reports no error and
no warning. The rendered board is `wp18-health-board.png` in the round evidence directory.
