---
type: decision-record
created: 2026-09-04
status: accepted
supersedes: nothing
related: docs/plans/2026-09-03-001-feat-labnet-overlay-plan.md
---

# Owner decisions, 2026-09-04: LabDesk becomes an RMM

The owner asked for a production ready remote monitoring and management product: machines that
remote into each other, fleets of machines, verified machine health, hard drive health, and
arbitrary machine metadata, secure with no compromises. A survey of both repositories ran first,
because the shape of the answer depended on what already exists rather than on what the plan said
exists. Four decisions came out of it. They are recorded here because each one changes the schema
and cannot be re-litigated cheaply later.

## The decisions

**1. An organization owns machines.** Multiple humans join it with roles: owner, technician,
viewer. Fleets are groups of machines inside the organization. Not the single user model the code
implements today, where every ownership edge is one `user_id` foreign key, and not an MSP tenant
boundary. Every overlay route's ownership check changes as a result.

**2. Collection moves into the always-on service.** The LabDesk service already runs as LocalSystem
on Windows and root on Linux. Health and inventory are collected there and reported over the
authenticated uplink, with no console open. This is not a preference. It was measured: on Windows
the interactive user is denied every SMART surface, with
`MSStorageDriver_FailurePredictStatus` and `MSFT_StorageReliabilityCounter` both returning access
denied, and only `MSFT_PhysicalDisk` succeeding with no temperature or wear data. Hard drive health
is not deliverable any other way. The existing metrics probe, which opens a visible terminal session
on the far machine using a stored password, is replaced for metrics.

**3. Samples are batched and rolled up.** The client batches instead of posting once per heartbeat,
raw samples are kept for days, and aggregates are kept for about thirty days. The current three
second heartbeat cadence is cut. The reason is arithmetic rather than taste: every heartbeat is a
database write, and at three seconds a single machine writes about 28,800 rows a day while a session
is open.

**4. Updates get a published SHA-256 now and a signing key next.** The Worker publishes a per asset
hash generated at release time and the client refuses to install anything that does not match,
before any elevation. A real signing key, with releases signed at build time and the public key
pinned in the client, follows as its own work package, because a hash alone still trusts whoever
serves it.

## Why decision 4 could not wait

The updater downloads an installer from the release endpoint and runs it elevated. A search of
`src/updater.rs` for any of sha, checksum, verify, signature or digest returns nothing, and
`update_new_version` calls `update_me_msi(p, true)`. Anyone able to write a GitHub release, the
`release_channel` row, or the Worker itself would own SYSTEM on every machine within a day. This
outranks every other finding in the survey.

## What the survey found that the plan did not know

- The production device table holds zero rows. The Rust client posts heartbeat and sysinfo with an
  empty header argument, and the Worker requires a bearer, so nothing has ever been stored. Every
  server side inventory feature was being planned on top of an empty table.
- Any signed in account can upsert any machine's device row, because the handlers take the row key
  from the request body and never compare it to the caller's own token. That row's key is then used
  as a fallback for overlay sessions.
- `/api/overlay/*` answers a 302 to a Cloudflare Access login page, so the overlay broker is
  unreachable by any client today, whatever else is true of it.
- The address book protocol the client already speaks is a fleet and credential store: peers carry
  aliases, tags, and both a personal hash and a shared password, across roughly fifteen endpoints
  including shared profiles with read and write permissions. The Worker implements only a legacy
  single opaque blob. The fleet model has to decide whether it extends that protocol or replaces it.
- An automation and alerting engine already exists client side, around 2,600 lines, with edge
  triggered rules, schedules, a run log and an action that runs a command over the headless link.
  The health engine is a migration of that, not a new build.
- Linux receives no updates at all: the update path is compiled only for Windows, and the packaging
  installs no daemon and ships no polkit policy.
- The Worker repository has no CI at all, and the pipeline that deploys it runs only a build and an
  upload, so a reverted security fix ships green.

## A survey claim that was wrong

The survey also reported that roughly 320 Rust test functions are never executed by anything. That
is false and was corrected by direct check rather than left standing. `.github/workflows/ci.yml`
carries a "Run tests" step invoking `cargo test --locked --target=<target> --workspace
--no-fail-fast`, the workflow runs on every pull request, and run 33834898725 on `feat/labnet`
reports that step as `success`. Rust unit tests therefore do run on every pull request. What remains
true is narrower and still worth stating: `cargo` cannot build this crate on the development
workstation, because `kcp-sys` needs `libclang` for its bindgen step and no `libclang.dll` exists
here, so Rust changes are proven by CI and by field checks rather than locally.

## Standing constraint

`cargo` is not installed on the development machine, verified directly. Rust changes can be proven
only by CI and by field checks on real machines. Any claim about Rust runtime behaviour that has not
been through one of those two gates is to be reported as unverified rather than as done.
