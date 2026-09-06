# LabDesk security posture

This page records what is true about LabDesk's security today. It is not the
plan, and it is not a roadmap. Where a control exists but nothing reaches it,
this page says so. Where a control is known broken, this page says that too.

It describes the code as committed:

- `LabDesk`, branch `feat/labnet`
- `labdesk-site`, branch `feat/labnet-broker`

The audit that produced the gap list below ran before the fixes for it landed.
Everything the fixes closed has been moved into "Closed since the audit" in
section 3 and re-verified against the committed code. Re-read this page against
the commit you are actually running rather than trusting its ordering.

Every claim below was checked by opening the file named beside it. Claims that
could not be checked from source are in section 5, stated as unknown, with the
evidence that would settle them.

## 1. The trust model

### The principals

Seven principals hold authority in this system, and they authenticate in five
different ways.

**1. The site administrator.** A Better Auth cookie session on an account whose
`user.role` is `admin`, checked by `requireAdmin` (`src/worker/session.ts:43`).
Site wide, not scoped to any organization. May approve, revoke and delete
accounts, publish and unpublish release channels, revoke every console token a
user holds (`src/worker/routes/admin.ts:106`), and add or remove emails on the
Cloudflare Access allowlist (`src/worker/access.ts`). This is the most powerful
human credential in the product.

**2. An organization member: owner, technician or viewer.** A Better Auth cookie
session, re-read on every request with `disableCookieCache: true`, resolved by
`actor()` (`src/worker/org.ts:66`). `actor()` is the only source of human
authority on the organization plane, and every `/api/org/*` and `/api/overlay/*`
route calls it.

**3. A console token holder.** `Authorization: Bearer <token>` against a SHA-256
in `app_token`, resolved by `bearerUser()` (`src/worker/routes/client-api.ts:58`).
This is what the desktop client gets from `POST /api/login`. It reaches the
legacy RustDesk plane only: `/api/currentUser`, `/api/heartbeat`, `/api/sysinfo`,
and the address book routes. It is not read anywhere under `/agent/*`, and
`actor()` does not look at it, so a stolen console token cannot speak as a
machine and cannot reach the organization plane.

**4. An enrolled machine.** An Ed25519 detached signature over
`labdesk-agent-v1\0METHOD\0PATH+QUERY\0TS\0sha256_hex(BODY)`, carried in
`X-LD-Machine`, `X-LD-TS` and `X-LD-Sig`, verified by `agentAuth`
(`src/worker/agent-auth.ts:143`). The subject is whichever machine's stored
public key verified the signature, and nothing in any request body names a
machine. May post `/agent/batch` and the six `/agent/overlay/*` routes.

**5. A machine that has not enrolled yet.** Holds a single-use enrolment token an
organization owner minted at `POST /api/org/enrol-token`
(`src/worker/routes/org.ts:98`), and signs `labdesk-enrol-v1\0...` with the key
it is asking the server to trust. Reaches exactly one route, `POST /agent/enrol`
(`src/worker/routes/agent.ts:65`), which is the one path exempted from the
signature guard (`src/worker/routes/agent.ts:23`). The token is the whole
credential: the self-signature proves possession of a key the caller generated a
moment earlier and vouches for nothing else.

**6. The release pipeline.** GitHub Actions holding the repository secret
`RELEASE_SIGNING_KEY`, used by `.github/workflows/release-checksums.yml`. Anyone
who can make that pipeline sign can publish an update manifest. Section 4 covers
what that is worth today, which is less than it sounds.

**7. The Worker, acting as NetBird account administrator.** The NetBird API token
lives only in the Worker's environment. The Worker creates and deletes peers,
groups and policies on the labnet control plane. No human credential and no
machine credential reaches NetBird directly.

Outside all seven stood Cloudflare Access, the wall in front of lab-desk.net for
the private phase, until 2026-09-05, when it and its bypass were deleted along
with `src/worker/access.ts`. The site is public; the registration switch in
`/admin` (default off, so a new account waits for approval) decides who may use
it, and the zone's WAF rules, rate limit and bot policies stand at the edge.

### What each organization role may do

The capability table is `GRANTS` in `src/worker/org.ts:21`. An unknown role holds
nothing, because the lookup fails closed (`src/worker/org.ts:28`).

| Capability | viewer | technician | owner |
| --- | --- | --- | --- |
| `read` | yes | yes | yes |
| `machine:write` | no | yes | yes |
| `session:open` | no | yes | yes |
| `job:request` | no | yes | yes |
| `rule:write` | no | yes | yes |
| `org:admin` | no | no | yes |

Before any capability is consulted, `actor()` applies four account gates in the
same order as `requireApproved`: banned, pending password rotation, unverified
email, and not approved (`src/worker/org.ts:78-81`). Owner-only routes
additionally require a sign-in within `FRESH_SECONDS`, which is 300
(`src/worker/org.ts:36`). Both the machine and the fleet lookup carry
`eq(orgId)` in the same WHERE clause as the row id, so a mistake in the
capability table still cannot cross an organization boundary, and a target
outside the caller's reach answers 404 rather than 403.

### What is never an authorization subject

- **A machine id in a body on the machine plane.** `agentAuth` decides who is
  speaking from the signature alone, and no `/agent/*` body names a machine, so
  cross-machine writes are structurally impossible rather than merely refused.
- **`Authorization` on `/agent/*`.** It is not read there at all. This is
  deliberate, and `test/agent-auth.test.ts` asserts it on the wire.
- **A machine id in a path or body on the human plane, in principle.** In
  practice four routes take one straight into a query without passing it through
  `actor()`. That is gap 5 below, and it is the largest authorization defect in
  the committed code.

## 2. What is verified sound

Six lenses attacked the following and none of them broke. Each item below was
re-checked against the committed file before it was written here.

**`actor()` is a correct choke point.** `src/worker/org.ts:66-121`. It re-reads
the session bypassing the five-minute cookie cache, applies the account gates
before anything else, checks the capability *before* resolving the named target
so a refusal does not confirm a row exists, and carries the organization id in
the same WHERE clause as the row id. Fleet narrowing is applied to both the
machine and the fleet lookup. The defect is not in this function; it is in the
routes that call it with an empty target.

**The signed machine plane is right.** `src/worker/agent-auth.ts`. The message
construction (`:64`) and the Rust side (`uplink_signed_msg` in
`src/labdesk/identity.rs`) agree byte for byte and are pinned by a fixture
generated from both sides. The machine id is deliberately excluded from the
signed message. `agentPkIsCanonical` (`:89`) refuses non-canonical base64, which
closes a real key-rebinding path that a unique index on a TEXT column would not:
`atob` is forgiving base64, so six spellings decode to the same 32 bytes. The
signature is checked before `revokedAt` (`:159` before `:161`) so the plane
cannot be used as a directory of revoked machine ids, and an unknown machine and
a bad signature share one 401 string (`:124`). Enrolment burns its token with a
conditional `UPDATE ... RETURNING` (`src/worker/routes/agent.ts:125`) so two
agents racing the same token cannot both enrol.

**The `/agent/*` mount order is correct.** `src/worker/index.ts:67` registers
`app.use("/agent/*", agentGuard)` above every `app.route` call, which begin at
`:73`. Hono runs matching handlers in registration order, so a `/agent/*` route
registered above that line would answer unauthenticated. Three files carry the
warning, and the test asserts it against `index.ts`'s own source as well as on
the wire.

**Better Auth's permissive defaults are closed.** `src/worker/auth.ts:29-57`.
`allowUserToCreateOrganization: false` shuts the endpoint that would let any
signed-in account mint itself an owner row and then an enrolment token.
`disableOrganizationDeletion: true` shuts the cheaper way to destroy a whole
fleet. `technician` and `viewer` are given empty statement sets, and the
plugin's `isResourceAuthorized` returns false for an empty allow-list. Teams are
disabled, because a machine is not a user.

**The ingest is idempotent, and better than the plan it implements.**
`src/worker/routes/agent-ingest.ts:102-226`. Four statements in one `db.batch()`:
the `machine_state` upsert guarded `WHERE seen_at <= excluded.seen_at`, a
`metric_batch` widen for a retried flush that grew, an insert de-duplicated with
`NOT EXISTS` inside the statement rather than a SELECT the handler branches on,
and an identity update using the null-safe `IS NOT` where `<>` would have
silently discarded the first hostname a machine ever reports. The author found
that the plan's `(machineId, fromAt)` dedup would discard a retried flush that
grew, which is the default configuration's case, and replaced it rather than
implementing the plan as written.

**The migrations avoid SQLite's two real punishments.** I checked the six
committed migrations `0002` through `0008` (there is no `0007`; the number is
reserved and unused). No `ALTER TABLE ... ADD` in any of them carries a
non-constant default or a `NOT NULL`: the non-constant default on
`app_token.expires_at` is delivered by a full table rebuild
(`drizzle/0004_machine.sql:99-117`), and every added `REFERENCES` column is
nullable (`drizzle/0004_machine.sql:118-122`). The audit additionally applied all
of them to a reconstruction of live production with `foreign_keys=ON` and got an
empty `foreign_key_check`, and ran `EXPLAIN QUERY PLAN` over eighteen live
statements to confirm index searches rather than scans. I did not repeat those
two checks.

Two more things are worth not re-auditing. `docs/SIGNING.md` names its own holes
in plain words, including the fact that the key ceremony has not happened.
`src/platform/windows/installer_handoff.rs` is the correct pattern for handing
work to an elevated process: it copies the script into System32 and re-verifies
its SHA-256 inside the elevated context against a hash carried on the command
line, with a distinct exit code for each failure and a test that swaps the file.
Gap 9 is that this pattern was not extended to the installer payload, not that
the pattern is wrong.

## 3. Known open gaps, ranked

Twenty-eight defects survived independent verification in the 2026-09-04
adversarial audit. What follows is the subset with security consequence, ranked,
each with the file it lives in and one sentence saying what it costs. The
numbering here is this document's own.

### Closed since the audit, and verified in the committed code

These were the audit's highest ranked findings. Each is now closed on the branch
and the check that proves it is named. Re-verify before trusting this list; do
not assume it stayed true.

**Revocation now revokes.** `revokeMachine` in `src/worker/routes/org.ts` and the
shared `retireFromLabnet` teardown, used by the owner initiated path and by the
machine's own `DELETE /agent/overlay/enrol` alike, end the machine's open
sessions and delete their policies, delete its setup keys, delete every peer in
its group rather than only the recorded one, delete the group, mark its labnet
memberships removed, and only then write `revokedAt`. It reads the overlay row
before the machine row is touched, because that row cascades away with the
machine and is the only record of which peer it was. It is idempotent, so a
teardown that failed part way can be run again, and it refuses rather than
orphaning a peer when the overlay is not configured. `afterRemoveMember` in
`src/worker/auth.ts` ends the grants a removed member left standing, and the
plugin's own leave path, which fires no hook at all, is wired to the same
teardown. `GET /api/overlay/sessions` lets an owner see and end standing grants.
Console tokens expire: `bearerUser` now filters on `expiresAt`.

**Fleet narrowing applies everywhere a machine is named.** The four leaks are
closed: the labnet listing narrows by the caller's fleets, the member eviction
route resolves its path parameter through `actor()` instead of dropping it into
the update, and the personal address book carries the same predicate the fleet
book already had. `labnet` has an owning fleet column
(`drizzle/0009_labnet_fleet.sql`), so narrowing has something to apply to, and
turning on full access now costs a recent sign in.

**The login rate limit prunes.** Keys are bounded, bodies go through the small
body helper, and rows older than the window are deleted in the same statement
that increments, so one unauthenticated address can no longer grow the table
without bound.

**Scheduled work runs.** `src/worker/index.ts` exports
`{ fetch: app.fetch, scheduled }` and `wrangler.jsonc` carries the trigger, so
the health engine has a caller, rules are evaluated, the hourly rollup is
written, and retention deletes in bounded slices with a cursor that resumes.

**The ingest is bounded.** `overLimit` is called on `/agent/batch` keyed on the
machine, with a ceiling per machine.

**The agent no longer trusts a bare 403.** Destroying the spool needs positive
proof that the server said revoked, not a status code that a proxy or a wall can
also produce.

**Disk health reaches the server.** The collector gathers it on the slow cadence
and includes it in the uplink, the ingest stores it, and unreadable stays
distinguishable from healthy all the way to the database.

### Must close before any machine is enrolled

**1. The desktop client cannot authenticate on either plane.** CLOSED 2026-09-05,
kept for the record. The machine plane is signed by the privileged process over
IPC (`b3fe22bc5`, `src/labdesk/labnet.rs`, `main_agent_sign`), and the human
plane moved to `/console/overlay/*` and `/console/org/*` (`d9d9b23dc`), where the
Worker mounts the same handlers a second time and `actor()` resolves the app
bearer (site `a73fa72`, `9728be6`). The Access bypass that admitted `/console` and
`/agent` went with the wall on 2026-09-05; the prefix stays because this build
speaks it. What was true when written:
the broker addressed the right routes, six machine side calls to
`/agent/overlay/*` and the rest to `/api/overlay/*`, but neither half
authenticated.

The machine plane wants an Ed25519 signature from the agent key. That key lives
in the privileged service and deliberately never crosses IPC, which is correct,
so the console process cannot read it and cannot sign. The six calls are refused
before they reach the wire. Closing this means the console asking the service to
sign over IPC rather than holding the key itself.

The account plane resolves the caller through `actor()`, which reads a Better
Auth session. The console holds an `app_token` bearer and no bearer plugin is
registered, so that credential is invisible to the Worker.

Until both are closed, remoting between two machines over labnet does not work
from the built product, whatever else is true.

**2. Attended updates hand an elevated process a path an unprivileged user can
still overwrite.** The download lands in `std::env::temp_dir()`
(`src/updater.rs`), the SHA-256 is checked by path, the handle is dropped, and an
elevated process re-opens that same path after an authentication prompt that
waits indefinitely. Section 4 has the full picture. This is a traced control
flow, not an executed exploit.

**3. Nothing publishes a digest, so no unattended update installs at all.**
`.github/workflows/release-checksums.yml` is not on the default branch, so
neither a tag push nor a manual dispatch runs it; no published release carries
`SHA256SUMS`; and the digest fetch is fatal rather than advisory. The verification
is correct and it currently gates nothing because there is nothing to verify
against. Section 4 and `docs/SIGNING.md` carry the ceremony that ends this.

**4. Nothing is deployed.** CLOSED 2026-09-05, kept for the record. Migrations
`0002` through `0009` were applied to production D1 that day, and lab-desk.net
serves the Worker at site commit `35389e2` with `/agent/*` and `/console/*`
answering JSON. What was true when written: the migrations were pending, and
`0002` creates the labnet tables themselves, so no route on the organization,
machine or labnet planes could work against production.

### Can follow

**11. The enrolment token is passed in argv.** `src/core_main.rs:662-667` reads
`--enrol --token <t>` from the command line, so the credential sits in
`/proc/<pid>/cmdline`, in root's shell history and in any provisioning log, and
there is no stdin or file alternative.

**12. A release is resolved by a non-unique version string.**
`src/worker/routes/updates.ts:60-68` scans `release_channel` and takes the first
row whose `version` matches, while `channel` is the primary key; two channels
sharing a version string means the download and its checksum both resolve through
the wrong row, so client-side verification passes on the wrong bytes.

**13. Cross-tenant device-row squat.** `src/worker/routes/client-api.ts:182-192`
looks up `overlay_device.deviceId` with a peer id while every row written today
is keyed on the server-minted machine UUID, so the guard never matches and an
account in no organization can claim another tenant's peer id and lock the real
holder out of `/api/heartbeat` and `/api/sysinfo`.

**14. Telemetry is write-only.** `machine_state` has no reader anywhere in the
Worker (only the three write lines in the ingest), and `metric_batch` has none
either, so not even a hand-crafted request with an owner cookie can read back a
CPU, memory or disk figure.

**15. There is no web operator console.** `src/app/pages/` holds four files:
`account.tsx`, `admin.tsx`, `auth.tsx`, `download.tsx`. Fleets exist in the
database with no page to manage them, and the organization API has no caller in
any client. Page work was started and then removed unreviewed rather than left
in the tree unmounted, so this gap is open, not partly done.

**16. `machine.platform` has no writer.** The only INSERT
(`src/worker/routes/agent.ts:142-156`) omits it and the ingest never sets it, so
a machine that arrived by enrolment has a permanently empty platform and the
client's per-platform command lookup matches nothing.

**17. A deterministic 400 wedges the head of the spool.** Every flush rebuilds
the window from index 0 and only an accepted batch drops lines
(`src/labdesk/spool.rs:104` folds every non-2xx, non-403 into `Retry`), so a
batch the ingest rejects on a validation rule is retried until the 4096-line cap
evicts it, roughly 2.85 days at 60-second samples.

**18. The disk verdict rule set has three gaps**, latent only because nothing
calls it. The ATA threshold-exceeded rule covers exactly three attribute ids, 5,
197 and 198 (`src/labdesk/disk/verdict.rs:182-200`), so every other pre-failure
attribute at or below its published threshold returns `Ok`; the generalising
`prefail()` accessor (`src/labdesk/disk/ata.rs:96`) has no production caller.
Temperature and UDMA CRC errors are not inputs on either bus. A SATA SSD
reporting zero life left returns `Ok` while the NVMe equivalent correctly warns.

**19. Twenty of the thirty-three platform-layer disk tests never run in CI.**
`.github/workflows/ci.yml:85` leaves `x86_64-unknown-linux-gnu` as the only live
matrix row, every Windows and macOS row commented out, so the struct-offset
assertions that `src/labdesk/disk/windows.rs` advertises as its guard against a
crate bump are never compiled, let alone executed.

**20. The Flutter analyzer cannot catch a mistyped bridge call.**
`.github/workflows/flutter-ci.yml:78-84` says so in its own comment: the job does
not generate `lib/generated_bridge.dart`, so a `bind.*` call in a LabDesk screen
resolves against an invalid type and is not reported.

**21. The machine plane has no oversize-body refusal.**
`src/worker/routes/agent-overlay.ts:39-43` parses a malformed or oversized body
as `{}`, and the invite decision route then writes an irreversible `declined`,
after which the machine's correct retry gets 403 forever. The human plane's
`smallJson` (`src/worker/routes/org.ts:19-24`) returns 413 for exactly this case
and explains why. Separately, the 64 KiB uplink cap is enforced at
`src/worker/routes/agent-ingest.ts:106`, after `agentAuth` has already buffered
and hashed the whole body.

**22. Owner-route freshness is measured from `session.createdAt`**
(`src/worker/org.ts:99-101`), which Better Auth preserves across session renewal,
so owner-only routes refuse five minutes after sign-in and only a fresh sign-in
reopens the window.

## 4. The update and execution chain

This is the path to code execution as SYSTEM or root on every machine that runs
the agent, so it gets its own section.

### What verifies today

The client learns the expected SHA-256 of an installer **before** it fetches a
byte of it (`src/updater.rs:220`), refuses to proceed if it cannot read one, and
re-uses a leftover file in the temporary directory only when that file hashes to
the published digest (`:226-231`). The download URL is checked against an
allowlist that inspects the raw prefix before `Url` normalises it, rejects
userinfo, port, query and fragment, and runs the filename through
`Path::components`. The manifest module takes the network as a parameter so a
test can watch which URLs are asked for, and a test asserts that pinning a key
*replaces* the digest route rather than sitting in front of it
(`src/updater.rs:1384`), which is the 404-downgrades-the-fleet failure this kind
of code usually ships with.

That closes tampering in transit, a poisoned cache, a truncated download, and a
file swapped in the temporary directory between the download and the check.

### What does not verify

**The signature does not, because no key is pinned.**
`RELEASE_SIGNING_PUBLIC_KEY_B64` at `src/updater.rs:509` is the empty string. The
constant is the entire switch: `release_signing_public_key()` returns `None`,
`published_sha256()` takes the unsigned digest branch (`:656`), and every
installed client today trusts whatever digest lab-desk.net serves. Anyone who
controls the Worker controls both the asset and the digest and can serve a
matching pair.

**The elevated re-open is not covered.** On all three platforms the digest is
checked by path in the unprivileged process, the handle is dropped, and an
elevated process re-opens the same path in a directory the unprivileged user
owns, after an authentication prompt that waits as long as the person takes.
Windows verifies at `src/platform/windows.rs:3750` and then hands the path to
`run_uac`; the elevated `update_me` at `:3369` derives everything from
`current_exe()` and never receives a digest. Linux verifies at
`src/platform/linux.rs:1600` and then runs `pkexec dpkg -i` on the same path,
under a comment at `:1586-1589` asserting the opposite, that the check is the
last act before root reads the file. macOS extracts into a fixed, guessable,
user-owned tree and root copies from it with no re-check, while the root-side
path in the same codebase correctly uses `mktemp -d` with mode 0700.

The correct pattern is already in this repository and already tested:
`src/platform/windows/installer_handoff.rs` passes an expected hash on the
command line and re-verifies inside the elevated context, with a dedicated
mismatch exit code. It was not extended to the installer payload.

**Linux machines receive no unattended updates at all.** `check_update()` in
`src/updater.rs:253-259` installs only under `cfg(target_os = "windows")`; macOS
is handled separately by `check_update_as_root()` in the service process; every
other platform downloads, verifies the digest, and stops. A Linux delivery
package was built, reviewed as broken, and reverted (commit `5ebc69f91`). A Linux
fleet is therefore not patchable by this product.

### The signing key ceremony

**It has not been performed.** No Ed25519 release keypair exists. The pinned
constant is a labelled placeholder and the comment above it says so
(`src/updater.rs:499-509`). `docs/SIGNING.md` carries the full ceremony and the
order the two halves have to land in, and its own "The key ceremony" section is
headed "Not yet performed."

Two things block turning enforcement on even after a key exists, and both are
recorded in `docs/SIGNING.md`:

1. **The site does not serve the manifest.** The client fetches
   `/releases/download/<version>/SHA256SUMS` and `.../SHA256SUMS.sig`, and both
   return 404 today, because `resolvePublishedAsset`
   (`src/worker/routes/updates.ts:60`) only resolves names that appear in the
   channel row's per-platform asset map, and those two are not platform assets.
2. **Every published tag needs backfilling** before the constant is filled in.
   Filling it in first gives a fleet that refuses to update, which is the safe
   direction to fail in and is still a dead update channel.

What the signature would *not* close, once it exists, is written down in
`docs/SIGNING.md` and is worth repeating here: it does not stop anyone who can
make the pipeline sign, it carries no version or expiry so a downgrade to an
older genuine release still verifies, and it says nothing about what the
installer does once it is running as root.

## 5. Never tested: unknown, not safe

Each item here is unknown because nobody has settled it, not because it is
believed to be fine. Each names the evidence that would settle it.

**No disk call has ever run against real hardware.** No `DeviceIoControl` on
Windows, no SG_IO ioctl on Linux. Every byte in `src/labdesk/disk/fixtures/` was
constructed programmatically, and that directory's own `README.md` says so in its
third paragraph. Two specifics deserve naming. `IOCTL_STORAGE_PREDICT_FAILURE`
returning a bare `Some(false)` is treated as a healthy verdict, and the module is
explicitly designed to trust that call on the USB bridges and RAID members that
refuse everything else: the test `a_bare_negative_prediction_is_ok`
(`src/labdesk/disk/verdict.rs:417`) pins that behaviour. If such a bridge answers
zero rather than failing the call, every external drive in a fleet renders
healthy. And
`src/labdesk/disk/windows.rs:453` sets `bDriveHeadReg` to
`DRIVE_HEAD_MASTER | (((drive & 1) as u8) << 4)`, which applies the IDE master
and slave convention to a PhysicalDrive index, and a PhysicalDrive index is not
a controller position on AHCI. **Settles it:** capture raw buffers from a
SATA hard disk, a SATA SSD and an NVMe drive, plus one USB enclosure and a
machine with an odd-numbered SATA disk.

**No second machine has ever been remoted into over labnet.** Gap 2 means the
shipped client cannot complete the flow, so the end-to-end path has never run
even once.

**No real NetBird tenancy has been exercised.** Every labnet policy and group
call in every test goes through a scripted double,
`test/fakes/netbird-worker.mjs`. Whether an orphaned peer really retains
reachability inside its group, whether one NetBird account isolates two
organizations' peers, and whether `syncLabnetGroup` produces the policy it
believes it does are all unverified against the real control plane.
**Settles it:** run the suite against a real NetBird instance.

**Migrations 0002 through 0008 are pending on production D1.** They have not been
applied, so the deployed schema is not the schema any test or probe ran against.
This was established this session against the live database, not from the
repository. **Settles it:** apply them, then read the deployed schema back.

**Whether `/agent/*` is on the Cloudflare Access bypass is unknown.** SETTLED
2026-09-05, kept for the record: `/agent` was put on the bypass that morning
(`/agent/overlay/inbox` answered JSON 401 and `POST /agent/enrol` JSON 400 from
outside), and the wall itself was deleted later that day.
`wrangler.jsonc` carried a `CF_ACCESS_APP_ID`, and a live `POST` to
`/agent/batch` returned a redirect to the Access login. If that prefix is not
bypassed, every agent request in production hits a login wall and the machine
plane is dead on arrival regardless of the code. The policy lives in Cloudflare,
not in either repository. **Settles it:** read the Access application's policy.

**Whether the Rust half compiles or runs as a whole is unknown on this
workstation.** The crate cannot be built here because `kcp-sys` bindgen needs a
libclang that is not installed, so every Rust finding in this document is read
from source or executed against an extracted copy of the pure layer. No
`identity.rs`, `spool.rs`, `collector.rs` or platform test has been executed as
part of the real crate. **Settles it:** install libclang and run `cargo test`.

**The attended-update escalations in section 4 are traced, not executed.** No
Linux or macOS host was available, and there is no second user account on this
workstation to stage the file swap. **Settles it:** stage the swap on each
platform with a second account.

**The repository's own settings are the real defence for the signing key, and
none of them is inspectable from here.** Branch protection on the default branch,
who holds write access, and whether two-factor authentication is required all
decide what the ceremony in section 4 is worth once it happens.

One test-suite caveat worth carrying forward: `test/overlay.test.ts` has a
`beforeAll` hook that times out at the default ten seconds under load, which
skips all 47 of its authorization tests. Vitest exits non-zero, so CI fails
rather than passing silently, but on a slow runner those 47 are the first tests
to stop running and they are the worst set to lose.
