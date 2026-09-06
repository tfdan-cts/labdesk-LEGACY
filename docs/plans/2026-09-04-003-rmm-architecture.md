---
type: plan
created: 2026-09-04
status: accepted
supersedes: nothing
related:
  - docs/plans/2026-09-03-001-feat-labnet-overlay-plan.md
  - docs/plans/2026-09-04-002-rmm-decisions.md
---

<!--
CORRECTIONS FOUND WHILE BUILDING. The plan is the source of truth, so where the code proved it
wrong, the correction is recorded here rather than left to be rediscovered.

1. actor() and session.activeOrganizationId (section 2). The plan says actor() reads
   session.activeOrganizationId. The Better Auth organization plugin DECLARES that column and never
   writes it: the returned plugin object carries no init, no hooks and no databaseHooks, so only an
   explicit set-active call ever populates it and a fresh sign-in carries null. Read literally, every
   actor() call would have refused and the authorization plane would have been dead on arrival.
   As built: membership is what authorizes. The active organization is used when present, the
   caller's single membership is used otherwise, and a caller holding several is asked to choose. A
   forged or stale active organization id still finds no member row and is still refused.

2. The organization plugin's permissive defaults (section 2). Mounting the plugin does not by itself
   restrict anything: organization creation is allowed by default and the organization delete
   endpoint is live by default. Both are now set explicitly. A reviewer also found that actor() had
   dropped the approval gate every other authenticated surface enforces, so an account an admin had
   revoked still ran.

3b. WP19 (Linux delivery) was BUILT AND REVERTED once, and is now built. The first attempt shipped
   src/platform/linux.rs calling /usr/share/rustdesk/labdesk-helper, a path that NO package this
   repository builds produced, and its new Linux update arm was unreachable, so Linux still received
   no unattended update while the code implied otherwise. It also asserted invented pkexec behaviour
   as fact in shipped comments. A reviewer returned BROKEN and the change was reverted rather than
   committed, because a broken and misleading state is worse than the honest broken state that
   preceded it.
   As built, 2026-09-05, in the order the earlier attempt got wrong. build.py stages res/labdesk-helper
   at /usr/share/rustdesk/labdesk-helper and res/polkit/net.lab-desk.LabDesk.policy at
   /usr/share/polkit-1/actions/, on both deb paths and in both flutter rpm specs, so the file the
   code calls is a file a package produces. The helper is the fence, not a wrapper: it copies the
   package into a root-owned directory, reads the name and version out of the copy, refuses a
   version that is not newer than the installed one, fetches the digest lab-desk.net publishes for
   that asset of that release, and installs only bytes that hash to it. A package the site has not
   published cannot be installed as root through the polkit action even by an administrator who
   authenticates. Measured on homebox 2026-09-05: pkaction reads the action, pkexec executes the
   script, a genuine published 1.2.4 deb is refused as not newer, and a repacked 9.9.9 deb is
   refused because the site publishes no digest for it.
   The unattended arm is crate::updater::start_auto_update_linux, started from start_os_service in
   src/platform/linux.rs, which is the root process; --server is the desktop user's and cannot
   install a package. It asks that --server over IPC whether a session is live (Data::HasNoActiveConns
   is no longer macOS-only) and treats no answer as a live session. The install is handed to the
   helper through systemd-run and NOT as a child of the service: res/DEBIAN/preinst stops
   rustdesk.service on an upgrade and KillMode=mixed then kills whatever is left in that cgroup,
   which would be dpkg part way through unpacking. postinst starts the service again on the new
   binary. res/DEBIAN/postinst needed no change; polkit picks the action file up from the packaged
   path on its own.

3. WP1's migration number (section 9). 0003 was already taken by the organization migration, so the
   indexes ship as 0008. drizzle-kit reports no pending schema changes, and wrangler lists 0002
   through 0008 as pending on the remote.

4. A fleet book's guid is its fleet id (section 1.2, recorded from the phase 1 contracts, section
   4). `ab_book.kind = 'fleet'` rows are not written; `book()` in `src/worker/routes/ab.ts` decides
   the kind from the guid, and `ab_book` holds personal books only.

5. The Windows daemon did not re-read its config (phase 1 contracts, section 7). `CONFIG2` is a
   lazy_static loaded once per process, and on Windows `--server` and `--service` are two
   LocalSystem processes with nothing syncing them, so the `labdesk-selfheal` switch flipped from
   the console never reached a running daemon. As built: `selfheal::enabled()` parses the daemon's
   own config file on every tick on every platform, and `start()` spawns the thread whether or not
   the switch is on, so a daemon started with it off still honours a later flip.

6. ATA power-on hours (section 5.4). Measured on a Seagate ST1000VX008 on homebox, 2026-09-05: the
   raw 48 bit value of attribute 9 carries a second counter in its upper two bytes (they moved
   between two reads seconds apart) and reads as 71 trillion hours. `ata::summarize` takes the low
   24 bits. The capture is `src/labdesk/disk/fixtures/ata_attrs_st1000vx008.bin`.

7. The NVMe hwmon path (section 5.2). The plan names `/sys/class/nvme/nvmeN/device/hwmon*`; on
   kernel 7.0 the hwmon device is registered on the controller itself,
   `/sys/class/nvme/nvme0/hwmon1`, and `device/hwmon*` does not exist. Both are searched now. Read
   from sysfs that the plan did not list: `firmware_rev` on the controller and `device/rev` on a
   SCSI disk, both of which had been arriving at the server as null. The Micron 3400 log page from
   the same machine is `fixtures/nvme_health_micron3400.bin`; both platform calls answered on real
   hardware, and both refused without root, as `Unreadable` and never `Ok`.

8. Linux `active_user` tools (phase 1 contracts, section 1). The two entries are `loginctl`
   commands aimed at another user's sessions, which polkit refuses to anyone but root, so on Linux
   the daemon runs them itself, appending the seat0 user from `get_active_username()` to the
   `power_logoff` argv. `run_as_user` serves Windows and macOS through `labdesk --labdesk-tool
   <id>`; on Windows the exit status of that launch is not observed (`LaunchProcessWin` hands back
   no handle) and the job result says so in its output.

9. `machine.platform` was read everywhere and written nowhere (sections 4.4 and 6.2). Enrolment
   stores hostname and OS build; the batch stored those and the agent version; nothing in either
   half of the product ever set `platform` or `arch`. Every catalog entry is keyed by platform, so
   for a really enrolled machine `POST /org/jobs` answered "That machine has not reported its
   platform yet." for every tool and `scheduled.ts::jobFor` fired nothing, forever. Found on
   homebox-devserver 2026-09-05 by enrolling a real machine, which no fixture had done: the seeded
   rows all carried a platform set by hand. As built: the batch's `machine` member names `platform`
   and `arch`, and the ingest stores a platform this build's catalog knows and nothing else.

10. `collectNow` bought nothing (phase 1 contracts, section 6.4). It moved the next FLUSH to ten
    seconds, and `flush()` sends nothing at all when the spool holds no line (`window.sent == 0`),
    which ten seconds after a flush it never does. Measured on homebox-devserver 2026-09-05: an
    urgent `flush_dns` exited 0 at 16:27:13 and its result reached the server on the ordinary 300 s
    tick. As built: an answer asking for it brings the next SAMPLE forward as well, so the early
    flush has a line to carry the result on.

11. The console lost the whole organization when labnet was not configured (section 8.2). One
    `try` read the organization's machines and the labnet inbox in sequence, and lab-desk.net
    answers `/agent/overlay/inbox` 503 when no NetBird is configured for it, so the 503 threw past
    the assignment: an empty health board, no adapters, no self-healing report and no machine
    picker, over a subsystem the technician had not asked for. The two reads are separate now.
    Two more from the same field check: the health board rendered the technician's PEER list rather
    than the organization's fleet, so a freshly installed console said "No machines yet." over a
    fleet the server was answering with; and every place needing this machine's own peer id read
    `serverModel.serverId.text`, which is the formatted id the box shows ("1 180 573 903"), so the
    console never recognised itself.

12. A Linux tunnel read as down (section 8.2, the adapter view). `link_up` trusted
    `/sys/class/net/<if>/operstate` alone, and a driver that never calls `netif_carrier_*` leaves
    that at `unknown`: `tailscale0` on homebox-devserver reported down 2026-09-05 while this
    session was talking to the machine over it. `unknown` falls back to `IFF_UP` now. The same
    check found the first `net.adapters` attribute of a run written with no MAC address and zero
    traffic, because the flush offset is shorter than one sample cadence and the sampler's
    interface list was still empty; the constructor seeds it.

13. The connect ticket's 120 second life (section 12 step 2, and the schema comment on
    `connect_ticket.expires_at`). The target is handed a ticket only in the answer to its own
    `POST /agent/batch`, and the default `flushSeconds` is 300, so a row that expired after 120
    seconds was almost always gone before the batch that would have carried it: the delivery
    select filters on `claimed_at` null and `expires_at` in the future and found nothing. The
    half of the design this document spends the most words on therefore almost never ran. As
    built, `ticketLife()` in the site's `src/worker/routes/overlay.ts` is
    `max(120, 2 * flushSeconds)`, keeping the 120 second floor for a machine that flushes faster.
    The claim leg is still unproven end to end: a ticket was minted and delivered on
    homebox-devserver 2026-09-05 with `claimed_at` null, and claiming one needs a controller and a
    target both signed in, which needs an enrolment token only the owner mints in production.

14. Every capability in the grant table is now requested by a route (section 2). The table named
    six, and for most of phase 1 only four were asked for by any handler, so `machine:write` and
    `job:request` were granted to a role and reachable by nobody. `POST /org/jobs` asks for
    `job:request`, the machine label and tag edit and the alert acknowledgement ask for
    `machine:write`, and the grant table is what a role can actually do rather than what was
    intended.
-->

<!--
Produced by a judge panel: independent architectures designed from a schema-first, an agent-first and
a security-first angle, each scored by an independent judge, then synthesized from the winner with
the best of the others grafted in. One of the three design agents failed to return a valid result, so
the panel that reached synthesis was two designs, not three. That is recorded here rather than
implied away.

Nothing Rust in this document has been compiled. Cargo is installed on the development workstation
but cannot build this crate, because kcp-sys needs a libclang that is not present. CI runs
cargo test on every pull request and is the gate.
-->

# LabDesk RMM — The Architecture We Build

**Spine:** Design A (score 19) — server-proven machine identity, org/fleet authorization plane, packed telemetry batches, allowlisted job outbox.
**Grafted from Design B, where the judges named them:** the Better Auth `organization` plugin instead of hand-rolled org tables; the single `/agent/*` namespace so the Cloudflare Access bypass is one prefix rather than a growing per-path list; `disk.health_source` so "healthy" and "we could not ask" are different sentences; the on-disk spool with a hard cap; server-returned cadence; "the two missing indexes ship alone, first".

**Every fatal flaw the judges found is fixed below, not disclosed.** Where a fix required abandoning something both designs assumed, the one-sentence reason is inline and marked **DECISION**.

Everything cited was read in these repos today. Nothing Rust here has been compiled — Cargo is not installed on this machine, so CI is the only proof, and I say so at each point. Files under active edit by another workflow (`src/updater.rs`, `src/hbbs_http/sync.rs`, `src/client.rs`, `src/rendezvous_mediator.rs`, `worker/routes/{updates,client-api,overlay}.ts`, `worker/netbird.ts`, both `ci.yml`) are cited by symbol, not by line, because the lines will move.

---

## 0. The four premises the judges overturned, verified here

Before anything else, because three of them invalidate parts of both designs:

**0.1 — On Linux and macOS, `--server` is NOT privileged.** `src/platform/linux.rs:713-717` launches it as the desktop user:

```rust
run_as_user(vec!["--server"], Some((desktop.uid.clone(), desktop.username.clone())), envs)
```

Only the no-session fallback (`linux.rs:719`, `run_me(vec!["--server"])`) is root. `src/platform/macos.rs:886` does the same (`run_as_user("--server")`). On Windows `--server` *is* LocalSystem — `src/platform/windows.rs:833` calls `LaunchProcessWin(wstr, session_id, FALSE, FALSE, &mut token_pid)`, and `src/platform/windows.cc:139` shows `as_user=FALSE` duplicates **winlogon.exe**'s token.

**DECISION: the collector lives in the `--service` daemon on all three platforms, not in `--server`,** because `--service` is the only process that is root/SYSTEM on every platform (`res/rustdesk.service`: `ExecStart=/usr/bin/rustdesk --service`, `User=root`; `src/platform/windows.rs:549 start_os_service`; `sc create ... binpath= "--service"` at `windows.rs:3808`), and one host process means one code path instead of a Windows path and a broken Linux one.

**0.2 — `Config::get_key_pair()` cannot be the machine credential.** `key_pair` is a serialised field of `Config` (`libs/hbb_common/src/config.rs:224`), and the whole `Config` is shipped to the unprivileged process: `src/ipc.rs:1021-1028` answers `Data::SyncConfig(None)` with `(Config::get(), Config2::get())`, and `src/server.rs:641-645` / `:762-775` call `Config::set(config)` in the user process, persisting it to that user's own profile. So on Linux and macOS the interactive user holds that key on disk.

**DECISION: the agent gets its own Ed25519 keypair, generated inside the privileged daemon, stored in a file that is not `Config` and never crosses IPC,** because the existing key is by design synchronised to a process we do not trust.

**0.3 — `handle_hash` has no capability branch.** `src/client.rs:3719-3810` resolves a connection credential in this order and no other: last password → preset → `shared_password` (shared address book) → peer config password → personal-AB hash → builtin default. Deleting the stored shared password, as Design B proposed, removes unattended access with nothing in its place.

**DECISION: we do not delete the shared password until the replacement ships and is verified,** and the replacement is a server-issued one-time connect ticket built on RustDesk's existing claim-once switch-sides machinery (`src/server/connection.rs:6147 insert_pending_switch_sides_uuid`, `:6170 claim_pending_switch_sides_uuid`, already unit-tested at `:7122-7136`).

**0.4 — Every overlay route still authorizes on client-declared identity.** `src/worker/routes/overlay.ts:19-27 who()` reads `r.token.deviceId` / `r.token.deviceUuid`, which `/api/login` (`client-api.ts:109-110`) stored verbatim from the client. `POST /api/overlay/enrol` (`:97`), `POST /api/overlay/self` (`:169`), `POST /api/overlay/session` (`:257`) all run through it. This is the plane that hands out NetBird setup keys and `targetIdPk`; signing only the telemetry plane, as Design A did, leaves the valuable half unprotected.

**DECISION: the overlay machine-side routes move onto the signed `/agent/*` plane in the same work package as the uplink,** because a stolen bearer that can still enrol a host onto the overlay or overwrite a target's `idPk` makes the rest of the identity work decorative.

---

## 1. The D1 schema

Conventions taken from the existing files: app tables use `integer(..., { mode: "timestamp" })` (unix **seconds**); auth tables use `timestamp_ms` because Better Auth's Drizzle adapter writes `Date` (`src/worker/db/auth-schema.ts:18-24`); hot sample columns use a bare `integer()` holding unix seconds so a range predicate is integer comparison with no `Date` allocated per row.

**No `WITHOUT ROWID` anywhere.** drizzle-kit 0.31 does not emit it, so it would mean hand-editing every generated migration forever and reviewing every regeneration for the regression. The write-cost it would have saved is instead saved by packing samples (§4), which is the same win with none of the maintenance. Where a table needs a cheap PK, it uses an integer rowid alias so SQLite creates no `sqlite_autoindex`.

### 1.1 Changes to existing tables

| Table | File | Change |
|---|---|---|
| `session` | `db/auth-schema.ts` | **add** `activeOrganizationId: text("active_organization_id")` — required by the Better Auth organization plugin (`node_modules/better-auth/dist/plugins/organization/`). |
| `appToken` | `db/schema.ts` | **add** `expiresAt: integer(..., {mode:"timestamp"}).notNull()`. Today the token never expires (`schema.ts:47-63`) and `bearerUser` (`client-api.ts:58-70`) is a plain hash lookup; a stolen console token would otherwise be a permanent fleet credential. Default 90 days, refreshed on use. |
| `appToken` | `routes/client-api.ts` | `lastSeenAt` update becomes conditional (only when older than an hour). It currently fires on **every** authenticated call. |
| `overlayDevice` | `db/schema.ts` | **add** `orgId`, `machineId` (FK → `machine.id`, `on delete cascade`). `userId` stays for one release, then goes. |
| `labnet` | `db/schema.ts` | **add** `orgId` (FK → `organization.id`, cascade). |
| `overlaySession` | `db/schema.ts` | **add** `orgId`, `requestedBy` (which technician opened it — today nothing records this), and **two indexes** (below). |
| `labnetMember` | `db/schema.ts` | **add** index on `deviceId`. Its PK is `(labnetId, deviceId)` (`schema.ts:133`) so the `deviceId`-only predicate at `overlay.ts:~466` is a full scan. |
| `device`, `addressBook` | `db/schema.ts` | **dropped** in migration 0007, one full release after the uplink cutover. The live `device` table has 0 rows, so there is no production migration burden. |

### 1.2 New Drizzle definitions — `src/worker/db/schema.ts`

```ts
import { sqliteTable, text, integer, real, index, uniqueIndex, primaryKey } from "drizzle-orm/sqlite-core";
import { user } from "./auth-schema";

/* ─────────────────────────── ORG PLANE ─────────────────────────── */
/* Shapes are the Better Auth organization plugin's own. Do NOT invent
   columns here: the plugin's adapter writes these names. */

export const organization = sqliteTable("organization", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  slug: text("slug").notNull().unique(),
  logo: text("logo"),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
  metadata: text("metadata"),                       // plugin-owned JSON
});

export const member = sqliteTable("member", {
  id: text("id").primaryKey(),
  organizationId: text("organization_id").notNull()
    .references(() => organization.id, { onDelete: "cascade" }),
  userId: text("user_id").notNull()
    .references(() => user.id, { onDelete: "cascade" }),
  // owner | technician | viewer. Set through the plugin's access-control
  // config, never from a request body. Default matches the plugin's own
  // ("member" is NOT in our role set, so we pin it).
  role: text("role").notNull().default("viewer"),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
}, (t) => [
  uniqueIndex("member_org_user_uidx").on(t.organizationId, t.userId),
  index("member_user_idx").on(t.userId),
]);

export const invitation = sqliteTable("invitation", {
  id: text("id").primaryKey(),
  organizationId: text("organization_id").notNull()
    .references(() => organization.id, { onDelete: "cascade" }),
  email: text("email").notNull(),
  role: text("role"),
  status: text("status").notNull().default("pending"),
  expiresAt: integer("expires_at", { mode: "timestamp_ms" }).notNull(),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
  inviterId: text("inviter_id").notNull()
    .references(() => user.id, { onDelete: "cascade" }),
}, (t) => [
  index("invitation_org_idx").on(t.organizationId),
  index("invitation_email_idx").on(t.email),
]);

/* Fleets group MACHINES. The plugin's `teams` option groups USERS, which
   would need a user row per machine, so fleets get their own table. */
export const fleet = sqliteTable("fleet", {
  id: text("id").primaryKey(),
  orgId: text("org_id").notNull()
    .references(() => organization.id, { onDelete: "cascade" }),
  name: text("name").notNull(),
  note: text("note"),
  createdBy: text("created_by").notNull(),
  createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
}, (t) => [
  uniqueIndex("fleet_org_name_uidx").on(t.orgId, t.name),
]);

/* Optional narrowing. NO ROWS for a member means the whole org, which is
   the ordinary case, so this table is empty on most installs. */
export const memberFleet = sqliteTable("member_fleet", {
  memberId: text("member_id").notNull()
    .references(() => member.id, { onDelete: "cascade" }),
  fleetId: text("fleet_id").notNull()
    .references(() => fleet.id, { onDelete: "cascade" }),
}, (t) => [primaryKey({ columns: [t.memberId, t.fleetId] })]);

/* ───────────────────── MACHINE IDENTITY ───────────────────── */
/* id is a server-minted UUID. peer_id is a LABEL for display and dialling,
   never an authorization subject. agent_pk is the credential (§3) and is
   NOT Config::get_key_pair() — see §0.2. */

export const machine = sqliteTable("machine", {
  id: text("id").primaryKey(),
  orgId: text("org_id").notNull()
    .references(() => organization.id, { onDelete: "cascade" }),
  fleetId: text("fleet_id").references(() => fleet.id, { onDelete: "set null" }),

  agentPk: text("agent_pk").notNull(),        // base64 raw 32-byte Ed25519
  peerId: text("peer_id").notNull(),          // Config::get_id()
  idPk: text("id_pk"),                        // Config key_pair PUBLIC half, for
                                              // the session key exchange only
  machineUuid: text("machine_uuid"),          // hbb_common::get_uuid()

  displayName: text("display_name"),
  hostname: text("hostname"),
  platform: text("platform"),                 // windows | linux | macos
  osVersion: text("os_version"),
  arch: text("arch"),
  agentVersion: text("agent_version"),

  // Server-controlled cadence, echoed in every batch response so a large
  // fleet can be slowed without shipping a client.
  sampleSeconds: integer("sample_seconds").notNull().default(60),
  flushSeconds: integer("flush_seconds").notNull().default(300),

  enrolledBy: text("enrolled_by").notNull(),
  enrolledAt: integer("enrolled_at", { mode: "timestamp" }).notNull(),
  revokedAt: integer("revoked_at", { mode: "timestamp" }),
}, (t) => [
  uniqueIndex("machine_agent_pk_uidx").on(t.agentPk),   // GLOBALLY unique: the
                                                        // uplink resolves on it
  uniqueIndex("machine_org_peer_uidx").on(t.orgId, t.peerId),
  index("machine_org_fleet_idx").on(t.orgId, t.fleetId),
]);

export const machineEnrolToken = sqliteTable("machine_enrol_token", {
  id: text("id").primaryKey(),
  orgId: text("org_id").notNull()
    .references(() => organization.id, { onDelete: "cascade" }),
  fleetId: text("fleet_id").references(() => fleet.id, { onDelete: "set null" }),
  tokenHash: text("token_hash").notNull(),    // sha256Hex, src/worker/crypto.ts
  maxUses: integer("max_uses").notNull().default(1),
  uses: integer("uses").notNull().default(0),
  createdBy: text("created_by").notNull(),
  createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  expiresAt: integer("expires_at", { mode: "timestamp" }).notNull(),
  revokedAt: integer("revoked_at", { mode: "timestamp" }),
}, (t) => [uniqueIndex("enrol_token_hash_uidx").on(t.tokenHash)]);

/* Hot row: rewritten once per flush. ONE secondary index, on seen_at,
   deliberately: the minute cron selects "machines that reported since the
   last tick", and without it that is a full scan of this table 43,200
   times a month. The index costs one extra row-write per flush; the scan
   would cost the whole table every minute. */
export const machineState = sqliteTable("machine_state", {
  machineId: text("machine_id").primaryKey()
    .references(() => machine.id, { onDelete: "cascade" }),
  seenAt: integer("seen_at").notNull(),        // unix seconds
  cpuPct: real("cpu_pct"),
  memPct: real("mem_pct"),
  fsWorstPct: real("fs_worst_pct"),
  uptimeS: integer("uptime_s"),
  loggedInUser: text("logged_in_user"),
  conns: integer("conns").notNull().default(0),
  agentVersion: text("agent_version"),
  overlayIp: text("overlay_ip"),
  worstDisk: text("worst_disk"),               // ok|warn|failing|unreadable
}, (t) => [index("machine_state_seen_idx").on(t.seenAt)]);

/* ───────────────────────── TELEMETRY ───────────────────────── */
/* One row per UPLOAD, samples packed. Integer rowid PK so there is no
   sqlite_autoindex; the only index is the one the reader uses. */

export const metricBatch = sqliteTable("metric_batch", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  machineId: text("machine_id").notNull()
    .references(() => machine.id, { onDelete: "cascade" }),
  fromAt: integer("from_at").notNull(),
  toAt: integer("to_at").notNull(),
  stepS: integer("step_s").notNull(),          // 60
  // JSON [[cpu,memPct,fsWorstPct,netRx,netTx], ...]; nulls preserved,
  // never coerced to 0 (machine_metrics.dart:285-305 keeps that rule).
  samples: text("samples").notNull(),
}, (t) => [index("metric_batch_machine_idx").on(t.machineId, t.fromAt)]);

export const metricHour = sqliteTable("metric_hour", {
  machineId: text("machine_id").notNull()
    .references(() => machine.id, { onDelete: "cascade" }),
  hourAt: integer("hour_at").notNull(),
  cpuAvg: real("cpu_avg"), cpuMax: real("cpu_max"),
  memAvg: real("mem_avg"), memMax: real("mem_max"),
  fsWorstMax: real("fs_worst_max"),
  upMinutes: integer("up_minutes").notNull().default(0),
  samples: integer("samples").notNull(),
}, (t) => [primaryKey({ columns: [t.machineId, t.hourAt] })]);

/* Current state per mount. Not sampled: fullness moves slowly, and the
   worst mount's history already rides metric_batch. A full filesystem and
   a dying disk are DIFFERENT alerts and never share a column. */
export const machineVolume = sqliteTable("machine_volume", {
  machineId: text("machine_id").notNull()
    .references(() => machine.id, { onDelete: "cascade" }),
  mount: text("mount").notNull(),              // "C:" | "/" | "/var"
  fsType: text("fs_type"),
  label: text("label"),
  used: integer("used"), total: integer("total"),
  diskId: text("disk_id"),                     // physical disk, when known
  updatedAt: integer("updated_at").notNull(),
}, (t) => [primaryKey({ columns: [t.machineId, t.mount] })]);

/* ─────────────────────── DISK HEALTH ─────────────────────── */

export const disk = sqliteTable("disk", {
  id: text("id").primaryKey(),
  machineId: text("machine_id").notNull()
    .references(() => machine.id, { onDelete: "cascade" }),
  // sha256 of the serial when the drive gave one, else of
  // model|size|device_index. NOT NULL and never the raw serial: a NULL
  // here would be distinct from every other NULL under SQLite's unique
  // index rules, so every USB bridge that refuses identity would add a
  // fresh row every hour.
  serialHash: text("serial_hash").notNull(),
  deviceIndex: integer("device_index").notNull(),
  devicePath: text("device_path"),
  model: text("model"), firmware: text("firmware"),
  bus: text("bus"),                            // nvme|sata|sas|usb|raid|unknown
  sizeBytes: integer("size_bytes"),
  rotational: integer("rotational", { mode: "boolean" }),
  // WHICH call produced the last reading, so "healthy" and "we could not
  // ask" are distinguishable in the UI:
  // ioctl_predict | nvme_logpage | ata_smart | sysfs | none
  healthSource: text("health_source"),
  firstSeenAt: integer("first_seen_at").notNull(),
  lastSeenAt: integer("last_seen_at").notNull(),
  removedAt: integer("removed_at"),
}, (t) => [uniqueIndex("disk_machine_serial_uidx").on(t.machineId, t.serialHash)]);

export const diskSample = sqliteTable("disk_sample", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  diskId: text("disk_id").notNull().references(() => disk.id, { onDelete: "cascade" }),
  at: integer("at").notNull(),                 // unix seconds, floor to 3600
  verdict: text("verdict").notNull(),          // ok|warn|failing|unreadable
  predictFailure: integer("predict_failure", { mode: "boolean" }),
  tempC: integer("temp_c"),
  powerOnHours: integer("power_on_hours"), powerCycles: integer("power_cycles"),
  reallocated: integer("reallocated"), pending: integer("pending"),
  uncorrectable: integer("uncorrectable"), crcErrors: integer("crc_errors"),
  percentUsed: integer("percent_used"), sparePct: integer("spare_pct"),
  spareThresholdPct: integer("spare_threshold_pct"),
  criticalWarning: integer("critical_warning"),
  unsafeShutdowns: integer("unsafe_shutdowns"), mediaErrors: integer("media_errors"),
  dataWrittenGb: integer("data_written_gb"),
}, (t) => [index("disk_sample_disk_idx").on(t.diskId, t.at)]);

/* Append-only, written ONLY when the verdict or a key counter moves.
   This is where the raw vendor table lives (bounded 4 KiB) so a better
   parser can be written later without re-collecting from the field —
   keeping it off disk_sample keeps that table narrow. */
export const diskEvent = sqliteTable("disk_event", {
  id: text("id").primaryKey(),
  diskId: text("disk_id").notNull().references(() => disk.id, { onDelete: "cascade" }),
  at: integer("at").notNull(),
  verdict: text("verdict").notNull(),
  reason: text("reason"),
  raw: text("raw"),                            // base64, <= 4 KiB
}, (t) => [index("disk_event_disk_idx").on(t.diskId, t.at)]);

/* ───────────── METADATA: two mechanisms, on purpose ───────────── */

/* Flat labels. Mirrors Peer.tags (flutter/lib/models/peer_model.dart:18)
   so the address-book projection is a straight read. */
export const machineTag = sqliteTable("machine_tag", {
  machineId: text("machine_id").notNull()
    .references(() => machine.id, { onDelete: "cascade" }),
  orgId: text("org_id").notNull(),             // denormalised for fleet search
  tag: text("tag").notNull(),
}, (t) => [
  primaryKey({ columns: [t.machineId, t.tag] }),
  index("machine_tag_org_idx").on(t.orgId, t.tag),
]);

/* Arbitrary key/value. `source` stops an agent-discovered value from
   overwriting an operator-set one of the same key. Agent writes are
   confined to source='agent' and are read-only in the console, so a
   rooted machine cannot write a field an operator reads as authority. */
export const machineAttr = sqliteTable("machine_attr", {
  machineId: text("machine_id").notNull()
    .references(() => machine.id, { onDelete: "cascade" }),
  orgId: text("org_id").notNull(),
  key: text("key").notNull(),                  // [a-z0-9_.:-]{1,64}, route-enforced
  value: text("value").notNull(),              // <= 4 KiB, <= 64 keys/machine
  source: text("source").notNull().default("manual"),  // manual | agent | rule
  setBy: text("set_by"),
  updatedAt: integer("updated_at").notNull(),
}, (t) => [
  primaryKey({ columns: [t.machineId, t.key] }),
  index("machine_attr_search_idx").on(t.orgId, t.key, t.value),
]);

/* ──────────────────── HEALTH ENGINE ──────────────────── */

export const healthRule = sqliteTable("health_rule", {
  id: text("id").primaryKey(),
  orgId: text("org_id").notNull()
    .references(() => organization.id, { onDelete: "cascade" }),
  name: text("name").notNull(),
  enabled: integer("enabled", { mode: "boolean" }).notNull().default(true),
  // BYTE-IDENTICAL to AutomationTrigger/AutomationAction toJson
  // (flutter/lib/labdesk/models/automation_models.dart:74-98, :312-330)
  trigger: text("trigger").notNull(),
  action: text("action").notNull(),
  targetKind: text("target_kind").notNull(),   // org | fleet | machines
  targetFleetId: text("target_fleet_id").references(() => fleet.id, { onDelete: "cascade" }),
  targetMachines: text("target_machines").notNull().default("[]"),
  cooldownS: integer("cooldown_s").notNull().default(600),
  createdBy: text("created_by").notNull(),
  createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
}, (t) => [index("health_rule_org_idx").on(t.orgId, t.enabled)]);

/* The engine's eight in-memory maps (automation_engine.dart:36-64), made
   durable, because a Worker invocation holds nothing between ticks. */
export const healthRuleState = sqliteTable("health_rule_state", {
  ruleId: text("rule_id").notNull().references(() => healthRule.id, { onDelete: "cascade" }),
  machineId: text("machine_id").notNull(),     // "" for rule-wide schedule state
  baselined: integer("baselined", { mode: "boolean" }).notNull().default(false),
  prevStatus: text("prev_status"),             // online | offline | unknown
  trueSince: integer("true_since"),
  latched: integer("latched", { mode: "boolean" }).notNull().default(false),
  cooldownUntil: integer("cooldown_until"),
  nextDue: integer("next_due"),
  lastSlot: integer("last_slot"),
  offlineSince: integer("offline_since"),
}, (t) => [primaryKey({ columns: [t.ruleId, t.machineId] })]);

export const healthEvent = sqliteTable("health_event", {
  id: text("id").primaryKey(),
  orgId: text("org_id").notNull()
    .references(() => organization.id, { onDelete: "cascade" }),
  machineId: text("machine_id"),
  ruleId: text("rule_id"),
  at: integer("at").notNull(),
  kind: text("kind").notNull(),                // rule_fired|disk_warn|disk_failing
                                               // |offline|back_online|job_failed
  severity: text("severity").notNull(),        // info | warn | critical
  summary: text("summary").notNull(),
  detail: text("detail"),
  acknowledgedBy: text("acknowledged_by"),
  acknowledgedAt: integer("acknowledged_at"),
}, (t) => [
  index("health_event_org_at_idx").on(t.orgId, t.at),
  index("health_event_machine_at_idx").on(t.machineId, t.at),
]);

/* ───────── JOBS: the audit record that happens to be a queue ───────── */
/* There is NO `command` column. The agent executes only entries from a
   catalog compiled into its own binary (§6); a job names a tool id and
   typed params. Free-text shell is not deliverable by ANY party,
   including a fully compromised Worker. */

export const machineJob = sqliteTable("machine_job", {
  id: text("id").primaryKey(),
  orgId: text("org_id").notNull()
    .references(() => organization.id, { onDelete: "cascade" }),
  machineId: text("machine_id").notNull()
    .references(() => machine.id, { onDelete: "cascade" }),
  ruleId: text("rule_id").references(() => healthRule.id, { onDelete: "set null" }),

  toolId: text("tool_id").notNull(),           // catalog entry, agent-validated
  params: text("params").notNull(),            // JSON, schema-validated both ends
  runAs: text("run_as").notNull().default("active_user"),  // active_user | system
  timeoutS: integer("timeout_s").notNull().default(120),

  requestedBy: text("requested_by"),           // user id, NULL when a rule fired
  requestedAt: integer("requested_at").notNull(),
  approvedBy: text("approved_by"),             // required, and DISTINCT from
  approvedAt: integer("approved_at"),          // requestedBy, when runAs='system'
  dispatchedAt: integer("dispatched_at"),
  startedAt: integer("started_at"),
  finishedAt: integer("finished_at"),
  state: text("state").notNull().default("pending"),
    // pending|approved|dispatched|running|done|failed|expired|refused
  exitCode: integer("exit_code"),
  output: text("output"),                      // truncated to 16 KiB
  outputSha256: text("output_sha256"),
  expiresAt: integer("expires_at").notNull(),
}, (t) => [
  index("machine_job_pickup_idx").on(t.machineId, t.state),
  index("machine_job_org_at_idx").on(t.orgId, t.requestedAt),
]);

/* ──────── ADDRESS BOOK: extend the protocol the client speaks ──────── */

export const abBook = sqliteTable("ab_book", {
  guid: text("guid").primaryKey(),             // what AbProfile.guid carries
  orgId: text("org_id").notNull()
    .references(() => organization.id, { onDelete: "cascade" }),
  kind: text("kind").notNull(),                // personal | fleet
  ownerUserId: text("owner_user_id").references(() => user.id, { onDelete: "cascade" }),
  fleetId: text("fleet_id").references(() => fleet.id, { onDelete: "cascade" }),
  name: text("name").notNull(),
  note: text("note"),
  updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
}, (t) => [uniqueIndex("ab_book_personal_uidx").on(t.orgId, t.ownerUserId)]);

/* Personal books only. Fleet books are PROJECTED from machine +
   machine_tag at read time, so a fleet has exactly one source of truth. */
export const abPeer = sqliteTable("ab_peer", {
  bookGuid: text("book_guid").notNull().references(() => abBook.guid, { onDelete: "cascade" }),
  peerId: text("peer_id").notNull(),
  machineId: text("machine_id").references(() => machine.id, { onDelete: "set null" }),
  alias: text("alias").notNull().default(""),
  tags: text("tags").notNull().default("[]"),
  note: text("note"),
  // Peer.hash (peer_model.dart:12) — already a hash, per-user, returned
  // only to this book's owner. Never present on a fleet book.
  personalHash: text("personal_hash"),
  updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
}, (t) => [primaryKey({ columns: [t.bookGuid, t.peerId] })]);

export const abTag = sqliteTable("ab_tag", {
  bookGuid: text("book_guid").notNull().references(() => abBook.guid, { onDelete: "cascade" }),
  name: text("name").notNull(),
  color: integer("color").notNull().default(0),
}, (t) => [primaryKey({ columns: [t.bookGuid, t.name] })]);

/* ─────────────── CONNECT TICKETS (retires the shared password) ─────────────── */
/* One-time, short-lived, org-authorized. Minted by the Worker when a
   technician opens a session; delivered to the TARGET on its own signed
   uplink and to the CONTROLLER on its authenticated console call. The
   target claims it once, using the same semantics RustDesk already
   implements and tests for switch-sides UUIDs
   (src/server/connection.rs:6147, :6170, tests :7122-7136). */

export const connectTicket = sqliteTable("connect_ticket", {
  id: text("id").primaryKey(),
  orgId: text("org_id").notNull()
    .references(() => organization.id, { onDelete: "cascade" }),
  targetMachineId: text("target_machine_id").notNull()
    .references(() => machine.id, { onDelete: "cascade" }),
  controllerPeerId: text("controller_peer_id").notNull(),
  secretHash: text("secret_hash").notNull(),   // sha256Hex; plaintext returned once
  issuedTo: text("issued_to").notNull(),       // user id — WHO opened it
  sessionId: text("session_id"),               // overlay_session.id, when paired
  issuedAt: integer("issued_at").notNull(),
  expiresAt: integer("expires_at").notNull(),  // issuedAt + 120
  deliveredAt: integer("delivered_at"),        // when the target picked it up
  claimedAt: integer("claimed_at"),
}, (t) => [
  index("connect_ticket_target_idx").on(t.targetMachineId, t.expiresAt),
  index("connect_ticket_org_idx").on(t.orgId, t.issuedAt),
]);

/* Cursor for the sliced retention delete, so a run that hits the CPU cap
   resumes where it stopped instead of silently never finishing. */
export const maintenance = sqliteTable("maintenance", {
  key: text("key").primaryKey(),               // "metric_batch_retention", ...
  cursor: integer("cursor").notNull().default(0),
  ranAt: integer("ran_at").notNull(),
});
```

### 1.3 Migration files

- `drizzle/0003_indexes.sql` — **only** `CREATE INDEX overlay_session_open_idx ON overlay_session (ended_at);` and `CREATE INDEX labnet_member_device_idx ON labnet_member (device_id);`. Ships alone, helps immediately, blocks nothing.
- `0004_org.sql` — organization/member/invitation/fleet/member_fleet + `session.active_organization_id`, with the backfill: one org, every existing user a member, the `ADMIN_EMAIL` account `owner`, everyone else `technician` (which is exactly what they can already do — any signed-in account can currently reach any peer it knows).
- `0005_machine.sql` — machine, machine_enrol_token, machine_state, machine_tag, machine_attr, connect_ticket + the `overlay_device` / `labnet` / `overlay_session` / `app_token` column additions.
- `0006_telemetry.sql` — metric_batch, metric_hour, machine_volume, disk, disk_sample, disk_event, maintenance.
- `0007_engine.sql` — health_rule, health_rule_state, health_event, machine_job, ab_book, ab_peer, ab_tag.
- `0008_retire.sql` — one full release later: `DROP TABLE address_book; DROP TABLE device;`

---

## 2. Authorization model

Every row below is enforced by a helper that **returns a `Response` on refusal**, following the shape `ownDeviceId` (`routes/client-api.ts:182`) and `ownedLabnet` (`routes/overlay.ts:333`) already use. There is exactly one such helper for humans and one for machines. A device id in a request body is never an authorization subject anywhere, for anyone.

| # | Principal | Resource | Allowed action | The check that enforces it | File |
|---|---|---|---|---|---|
| 1 | Signed-in human | any org resource | only within orgs `member` lists them in | `actor(c, {machineId\|fleetId\|orgId}, need)` — loads the Better Auth session **fresh** (not the 5-min cookie cache), reads `session.activeOrganizationId`, loads `member`, refuses if absent; if `member_fleet` has rows, refuses a target outside them. Every scoped query *also* carries `eq(machine.orgId, org.id)` so a bug in the capability check still cannot cross an org. | `src/worker/org.ts` (new) |
| 2 | `viewer` | machines, metrics, disks, events, jobs, volumes | read | `actor(..., "read")` | `src/worker/org.ts` |
| 3 | `technician` | machines | rename, retag, set `machine_attr` where `source='manual'`, move between fleets | `actor(..., "machine:write")` | `src/worker/routes/fleet.ts` (new) |
| 4 | `technician` | session | open a session grant to a machine in scope | `actor(..., "session:open")`; replaces `target.userId !== w.r.user.id` at `overlay.ts:~283`. Also caps concurrent grants per actor and records `overlaySession.requestedBy`. | `src/worker/routes/overlay.ts` |
| 5 | `technician` | jobs | request a job whose catalog entry has `run_as='active_user'` | `actor(..., "job:request")` + tool lookup + per-actor rate limit reusing `overLimit` (`overlay.ts:50`) | `src/worker/routes/jobs.ts` (new) |
| 6 | `technician` | health rules | create/edit a rule scoped to a fleet | `actor(..., "rule:write")`; org-wide scope is owner-only | `src/worker/routes/rules.ts` (new) |
| 7 | `owner` | members, roles, enrol tokens, fleets, `update_pin`, machine deletion | all of it | `actor(..., "org:admin")` **plus** a session fresher than 300 s (Better Auth `freshAge` is 3600 s at `src/worker/auth.ts:193`; these routes pass a tighter bound) | `src/worker/routes/org.ts` (new) |
| 8 | `owner` | a `run_as='system'` job | approve one | `approvedBy` non-null **and** `approvedBy !== requestedBy`. One owner alone cannot turn the RMM into a fleet-wide SYSTEM shell. | `src/worker/routes/jobs.ts` |
| 9 | Machine (agent) | its own `machine_state`, `metric_batch`, `disk*`, `machine_attr where source='agent'`, `machine_tag` | write | `agentAuth(c)` → Ed25519 signature over the canonical message, resolved by `machine.agentPk` (globally unique index). Bearer tokens are **ignored** on `/agent/*`. | `src/worker/agent-auth.ts` (new) |
| 10 | Machine | any other machine's anything | **nothing** | there is no `/agent/*` route that returns another machine's data. Enforced by a negative test per route. | `test/agent-auth.test.ts` |
| 11 | Machine | overlay enrolment, self-report, ticket pickup | its own only | same `agentAuth`; `overlay_device.machineId` must equal the authenticated machine. Replaces `who()` (`overlay.ts:19-27`) for the machine half. | `src/worker/routes/agent-overlay.ts` (new) |
| 12 | Worker | agent code delivery | **cannot** | the agent executes only entries from a catalog compiled into its own binary. There is no signing key to steal because there is no code path that delivers code. | `src/labdesk/tools.rs` |
| 13 | Worker | update substitution | **cannot** | the release signature is produced in CI and published as a release asset; the private half never reaches the Worker, which only *serves* the file. The agent pins the public half at build time and verifies the signature **before** the file hash and before any elevation. | `.github/workflows/release-checksums.yml`, `src/updater.rs` |
| 14 | Attacker with a stolen app token | telemetry, enrolment, session grant, jobs | **nothing on the machine plane**; on the human plane, whatever the token's user's role allows, and the token now expires | `/agent/*` ignores `Authorization` entirely; `appToken.expiresAt` bounds the rest | `src/worker/agent-auth.ts`, `routes/client-api.ts` |
| 15 | Attacker who owns one enrolled machine | other machines | **nothing** except through a live, org-authorized grant | the agent key is per-machine and confined to the privileged daemon (§3); `agentAuth` scopes every write to that `machine.id` | `src/labdesk/identity.rs`, `src/worker/agent-auth.ts` |
| 16 | NetBird server | reachability beyond policy | **cannot exceed** what the Worker granted | the existing refusal-while-an-all-to-all-rule-exists check (`overlay.ts:88`, `:~101`) stays and is now covered by a test | `src/worker/routes/overlay.ts` |

**Named honestly:** the Worker is unavoidably the authority for org membership, so a full Worker compromise can *grant sessions* to machines it administers. That is recoverable, audited (`overlay_session.requestedBy`, `connect_ticket.issuedTo`) and revocable. It is a strictly better failure mode than today's, where the Worker holds reusable plaintext unattended passwords in `address_book.data` (`schema.ts:66-72`), which is unrecoverable. **DECISION: we accept "a compromised Worker can open a session" and refuse "a compromised Worker yields permanent credentials",** because the first is bounded and auditable and the second is not.

---

## 3. Machine identity, end to end

### 3.1 The key

**Not `Config::get_key_pair()`** — §0.2 proved that key is synchronised to the unprivileged user process. Instead:

**Rust — `src/labdesk/identity.rs` (new).** On first run inside the privileged daemon, generate an Ed25519 keypair with `hbb_common::sodiumoxide::crypto::sign::gen_keypair()` (the crate is already vendored and already used for the switch-grant signature in `src/hbbs_http/sync.rs`), and persist it to `Config::path("agent-identity.toml")` — a file `Config` does not know about, so `Data::SyncConfig` (`src/ipc.rs:372`) cannot carry it.

- Linux/macOS: `std::fs::set_permissions(path, Permissions::from_mode(0o600))`, written by the root daemon into root's config dir (`Config::path()` resolves through `directories_next::ProjectDirs`, `libs/hbb_common/src/config.rs:783-805`; `patch()` at `:462-471` only rewrites `/root` when `whoami != root`, which is never true in the daemon).
- Windows: the daemon is LocalSystem, so `patch()` rewrites to `ServiceProfiles\LocalService` and the directory's ACL already excludes interactive users; the file is additionally created with an explicit DACL of SYSTEM + Administrators using `Win32_Security_Authorization`, which is already in the `windows` feature list (`Cargo.toml:131`).

A **unit test asserts the file mode on Unix** and asserts that `Config::get()` serialised to TOML contains no substring of the agent secret key — that is the regression guard against someone later "helpfully" moving it into `Config`.

### 3.2 Enrolment

1. An `owner`, signed in, calls `POST /api/org/enrol-token {fleetId?}` → a 15-minute single-use token, stored hashed with the existing `sha256Hex` / `randomToken` (`src/worker/crypto.ts`).
2. The admin runs `labdesk --enrol --token <t>` on the machine. The arm is added in `src/core_main.rs` beside the existing `--assign`, gated identically on `crate::platform::is_installed() && is_root()`.
3. The daemon POSTs `/agent/enrol`:
   ```
   { token, peer_id, agent_pk, id_pk, machine_uuid, sysinfo, ts, sig }
   sig = Ed25519(agent_sk,
       b"labdesk-enrol-v1\0" || sha256_hex(token) || \0 || agent_pk_b64
       || \0 || peer_id || \0 || ts)
   ```
4. The Worker verifies `sig` against the **submitted** `agent_pk` (proof of possession), checks the token is live and unburned, mints `machine.id`, stores `agent_pk`, burns the token, and returns `{ machineId, orgId, sampleSeconds, flushSeconds }`. The daemon pins `machineId`.
5. Moving a machine to another org requires the current owner to revoke it **and** a fresh token. There is no silent takeover.

### 3.3 The uplink signature

Every later `/agent/*` request carries:

```
X-LD-Machine: <machine.id>
X-LD-Ts:      <unix seconds>
X-LD-Sig:     base64(Ed25519(agent_sk, msg))

msg = b"labdesk-agent-v1\0" || METHOD || \0 || PATH || \0 || TS || \0 || sha256_hex(BODY)
```

This is deliberately the same construction the client already ships for switch grants — `switch_grant_signed_msg` in `src/hbbs_http/sync.rs` builds a NUL-separated, domain-prefixed message and calls `sign::sign_detached`. That route has **no server half** (a grep of `labdesk-site/src` and `test` finds no `switch-grant` handler), so there is no live contract to break and the crypto is already vendored.

**Worker — `src/worker/agent-auth.ts` (new).** Load `machine` by `X-LD-Machine`, refuse if `revokedAt`, import the key, verify, require `|now - ts| <= 120`.

**No monotonic sequence counter and no nonce table.** Design A's strictly-increasing `last_seq` locks an agent out permanently on a reinstall or a restored image, and rejects one of any two concurrent uplinks; a nonce table costs a row-write per request forever. **DECISION: replay is defeated by making ingest idempotent instead** —

- `metric_batch` insert is de-duplicated on `(machineId, fromAt)` before insert;
- `machine_state` update carries `WHERE seen_at <= excluded.seen_at`;
- job completion carries `WHERE state IN ('dispatched','running')`;
- `disk_sample` insert is de-duplicated on `(diskId, at)`;
- ticket pickup is read-only.

A replay inside the 120-second window therefore achieves nothing, and there is no lockout failure mode.

**Unproven, must be proven before WP4 code is written:** that `crypto.subtle.importKey("raw", pk, {name:"Ed25519"}, false, ["verify"])` is available at `compatibility_date` `2026-08-22` (`wrangler.jsonc:6`). A three-line vitest in the existing `@cloudflare/vitest-pool-workers` suite settles it. If it is not, the fallback is `node:crypto` `verify` — `nodejs_compat` is already declared (`wrangler.jsonc:7`), so this needs **no new dependency** either way.

### 3.4 What is *not* the identity

`peer_id` remains a nine-digit label. It is unique per org (`machine_org_peer_uidx`) but never resolved against for authentication — `agentPk` carries a **global** unique index precisely so the uplink lookup is unambiguous across orgs, which was the flaw in Design B's scheme.

---

## 4. The telemetry pipeline

### 4.1 Where the collector runs

`src/labdesk/collector.rs` (new), started from `crate::platform::start_os_service()` on each platform — the daemon, per §0.1. Its own thread with its own tokio runtime; it does not touch `--server`, so nothing about it depends on whether a user is logged in.

The console-side PTY probe is deleted for metrics: `flutter/lib/labdesk/services/metrics_collector.dart` (which at `:37` injects bare statements into the far side's PowerShell) and `probe_reader.dart`. The PTY itself stays for `terminal_screen.dart`, which is a human at a keyboard.

### 4.2 What it gathers, at three cadences

| Cadence | Data | Source |
|---|---|---|
| 60 s | cpu %, mem used/total, swap, load1 (unix), fullest fixed mount %, cumulative net rx/tx, process count, logged-in user count, uptime, live LabDesk connection count | `sysinfo` 0.29.10, already in the lockfile as the `rustdesk-org` fork and already used by `get_sysinfo()` in `src/common.rs`. **Zero new crates.** |
| on change, ≤1/6 h | OS + build, hostname, CPU model/cores, RAM, machine uuid, NIC list, per-mount volume table, physical disk inventory, agent version, pending reboot | same, plus §5 |
| 1 h (+ once 60 s after start) | disk health | §5 |

### 4.3 Batching, spool, backoff

A line-delimited spool at `Config::path("agent-spool.jsonl")`. One line per sample. Every `flushSeconds` (default 300, **server-controlled**, echoed in each response) the collector reads up to 64 lines, POSTs, truncates on 2xx. Capped at 4,096 lines (~2.8 days) dropping oldest, so a machine off the network for a week returns with its most recent 2.8 days rather than an unbounded file. Flush jitter is `hash(machineId) % flushSeconds` so 500 agents do not align.

Backoff on failure: double the interval, 5 min → 60 min, reset on success. On **403 machine revoked**: stop collecting and delete the spool. On 401 (signature rejected): back off and keep the spool — a clock skew must not destroy history.

### 4.4 Wire format

```
POST /agent/batch                      (signed)
{
  "machine": { "hostname", "os", "agentVersion", "uptimeS", "conns", "loggedInUser" },
  "batch":   { "from", "to", "step": 60,
               "samples": [[cpu, memPct, fsWorstPct, netRx, netTx], ...] },
  "inventory": { ... }?,               // only when it changed
  "volumes":   [ { mount, fsType, label, used, total, diskId } ]?,
  "disks":     [ { serialHash, model, bus, verdict, source, tempC, ... } ]?,
  "attrs":     { "agent.<key>": "<value>" }?,
  "jobResults":[ { id, exitCode, output, startedAt, finishedAt } ]?
}
→ { ok, sampleSeconds, flushSeconds,
    jobs: [ { id, toolId, params, runAs, timeoutS, expiresAt } ],
    tickets: [ { id, secret, controllerPeerId, expiresAt } ],
    collectNow?: true }
```

Bounded at 64 KiB; over that the agent drops the **oldest** samples, never the newest.

### 4.5 Ingest and storage

`src/worker/routes/agent-ingest.ts` (new). One `db.batch()` (`node_modules/drizzle-orm/d1/driver.d.ts` exposes it) containing: the `machine_state` upsert, the `metric_batch` insert, `machine_volume` upserts, `disk`/`disk_sample`/`disk_event` upserts, `machine_attr` upserts **only where the value changed**, and job-result updates.

Change detection on attrs is not optional — an unconditional per-uplink tag upsert was the single largest uncosted writer in Design A, and at six attrs it alone would exceed the included tier.

### 4.6 Write volume — 500 machines, everything counted

D1 bills a written row for the table **and** for each index the write touches (Cloudflare Workers pricing, D1 note on rows written), and `DELETE` counts as a write.

**Today, measured from the code.** `TIME_HEARTBEAT` 15 s, `TIME_CONN` 3 s (`sync.rs:17,19`), posting every 15 s idle and every 3 s while a connection is live (`sync.rs:249`). Each POST costs three row-writes: the `device` upsert, the `device_user_idx` row it touches (`schema.ts:86`), and the unconditional `app_token.lastSeenAt` update (`client-api.ts:68`).

> 500 idle machines: `500 × 86400/15 × 3` = **8.64 M rows/day = 259 M/month**, carrying no telemetry. The free tier's 100,000 rows/day is exhausted in ~17 minutes.

**Proposed, steady state.**

| Source | Per unit | Per day (500) | Per month |
|---|---|---|---|
| `machine_state` update + `machine_state_seen_idx` | 2 | 500 × 288 × 2 = 288,000 | 8.64 M |
| `metric_batch` insert (rowid PK, one index) | 2 | 288,000 | 8.64 M |
| `metric_batch` delete @ 7-day retention | 2 | 288,000 | 8.64 M |
| `metric_hour` insert (composite PK ⇒ table + index) | 2 | 500 × 24 × 2 = 24,000 | 0.72 M |
| `metric_hour` delete @ 35 days | 2 | 24,000 | 0.72 M |
| `disk_sample` insert, 2 disks/machine hourly | 2 | 500 × 2 × 24 × 2 = 48,000 | 1.44 M |
| `disk_sample` delete @ 90 days | 2 | 48,000 | 1.44 M |
| `health_rule_state`, 10 rules × 500 machines, ~1%/tick changing, written only on change | 2 | ≈ 144,000 | 4.32 M |
| `machine_attr` / `machine_tag`, change-detected | — | ≈ 0 | ≈ 0 |
| **Total** | | **≈ 1.15 M/day** | **≈ 34.5 M/month** |

Inside the 50 M included on the Workers Paid plan, with headroom. That is a **7.5× cut against today's 259 M**, before counting today's in-session bursts, while carrying roughly 25× more information.

**At 5,000 machines** it is ≈ 345 M/month → ≈ 295 M over → ≈ **$295/month**. I would rather state that now than discover it. The escape valve is `machine.flushSeconds` in the batch response, which must be built in WP5, not retrofitted — a client already in the field with a hardcoded cadence cannot be slowed down.

**Storage.** `metric_batch` ≈ 250 B × 1.0 M rows (7 days) ≈ 250 MB; `metric_hour` 35 days ≈ 25 MB; `disk_sample` 90 days ≈ 2.16 M × 120 B ≈ 260 MB (the 4 KiB vendor blob lives on `disk_event`, written only on change, which is why `disk_sample` stays narrow). Under 1 GB against D1's 10 GB ceiling.

**Console polling.** Replace the 15 s `/api/overlay/inbox` poll (`flutter/lib/labdesk/console_page.dart:1221-1222`) with `GET /api/console/state?since=<unix>` at 30 s, returning **204 with no body** when nothing changed. Every read behind it hits an index. The two indexes from WP0 remove today's two full scans (`sweepSessions` at `overlay.ts:229` filters `overlay_session` on `ended_at`, and that table has no index beyond its PK; the `labnet_member` lookup by `device_id` cannot use the `(labnetId, deviceId)` PK).

### 4.7 Rollup and retention

`wrangler.jsonc` declares no triggers today. Add:

```jsonc
"triggers": { "crons": ["* * * * *", "7 * * * *"] }
```

and a `scheduled(controller, env, ctx)` export in `src/worker/scheduled.ts` (new).

- **Minute tick** — health engine only (§6). Bounded: it reads only machines whose `machine_state.seenAt` moved since the last tick, via `machine_state_seen_idx`.
- **Hourly tick** — fold the completed hour into `metric_hour`, then delete **at most 20,000** `metric_batch` rows older than 7 days, oldest first, resuming from `maintenance.cursor`. Steady state needs 12,000/hour, so 20,000 is headroom; a run that hits the CPU cap resumes rather than silently stopping. Then the same slicing for `metric_hour` (35 d), `disk_sample` (90 d), `health_event` (90 d), `machine_job` (180 d), and expired `connect_ticket` rows.

**Unverified:** the exact CPU ceiling for sub-hour versus hourly Cron Triggers. The slice bound makes the design correct either way, but the number must be checked against Cloudflare's limits page before anyone relies on a bigger slice.

---

## 5. Hard drive health

The interactive user was **measured** to be denied `MSStorageDriver_FailurePredictStatus` and `MSFT_StorageReliabilityCounter`. That is not a permissions accident to work around — it is proof that a console-side, session-scoped probe can never read disk health on Windows. The daemon is the only path, which is why §0.1's placement decision matters more than anything else in this section.

### 5.1 Windows

**Cargo change:** add `"Win32_System_Ioctl"` and `"Win32_Storage_Nvme"` to the `windows = { version = "0.61", features = [...] }` list at `Cargo.toml:127-146`. Verified absent today; `Win32_Storage_FileSystem` (`:132`) and `Win32_System_IO` (`:138`, where `DeviceIoControl` actually lives) are already present.

Every constant below was read out of `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows-0.61.1/src/Windows/Win32/System/Ioctl/mod.rs` and independently re-verified by both judges:

| Step | Call | Constant | Privilege |
|---|---|---|---|
| Open | `CreateFileW(L"\\\\.\\PhysicalDriveN", GENERIC_READ\|GENERIC_WRITE, FILE_SHARE_READ\|FILE_SHARE_WRITE, OPEN_EXISTING)` | — | Administrator/SYSTEM. **Read/write is required** — `SMART_RCV_DRIVE_DATA` is `CTL_CODE(..., FILE_READ_ACCESS\|FILE_WRITE_ACCESS)`, so opening with `dwDesiredAccess = 0` (as Design A proposed) fails the entire ATA path with ACCESS_DENIED. On denial, retry with `0`, which suffices for steps 2–4, and record the degraded mode. |
| 2. Identity + bus | `IOCTL_STORAGE_QUERY_PROPERTY`, `StorageDeviceProperty` (0), `PropertyStandardQuery` (0) → `STORAGE_DEVICE_DESCRIPTOR` | 2954240 (`:3392`) | as opened |
| 3. Volume mapping | `IOCTL_STORAGE_GET_DEVICE_NUMBER` → `STORAGE_DEVICE_NUMBER`, also on each `\\.\C:` handle | 2953344 (`:3369`) | as opened |
| 4. **Universal verdict, always first** | `IOCTL_STORAGE_PREDICT_FAILURE` → `STORAGE_PREDICT_FAILURE { PredictFailure: u32, VendorSpecific: [u8;512] }` | 2953472 (`:3390`) | as opened |
| 5. NVMe detail | `IOCTL_STORAGE_QUERY_PROPERTY` with `StorageDeviceProtocolSpecificProperty` (50, `:7064`) + `STORAGE_PROTOCOL_SPECIFIC_DATA { ProtocolTypeNvme=3 (:4129), NVMeDataTypeLogPage=2 (:3867), RequestValue=2, Length=512 }` → `NVME_HEALTH_INFO_LOG` (`Storage/Nvme/mod.rs:2632`) | — | as opened |
| 6. ATA/SATA detail | `SMART_GET_VERSION` (475264, `:5285`) gate, then `SMART_RCV_DRIVE_DATA` (508040, `:5298`) with `SENDCMDINPARAMS { bFeaturesReg: READ_ATTRIBUTES 0xD0, bCommandReg: SMART_CMD 0xB0, bCylLowReg 0x4F, bCylHighReg 0xC2 }`; also `READ_THRESHOLDS` 0xD1 and `RETURN_SMART_STATUS` 0xDA | — | needs the read/write handle |

Step 4 is the one to implement first: it is the same datum `MSStorageDriver_FailurePredictStatus` exposes, without the WMI namespace ACL that produced the measured denial, and it works on every bus type including USB bridges and RAID members.

**Buffer gotcha to expect on first build:** `SENDCMDINPARAMS` ends in a one-byte `bBuffer`, so the input length is `size_of::<SENDCMDINPARAMS>() - 1` and the output buffer must be `size_of::<SENDCMDOUTPARAMS>() - 1 + 512`. Sizing either with a bare `size_of` is the classic failure.

**Never shell out.** No `smartctl`, no `wmic`, no PowerShell, no CIM. Shelling out from a SYSTEM daemon to a bundled executable is a new privilege-escalation surface in the middle of the security-critical process; the IOCTLs are ~300 lines and add none.

### 5.2 Linux

The daemon is root by `res/rustdesk.service` (`User=root`, verified), so both privileged paths are open — **and only because of §0.1's decision**; in `--server` these would fail on every machine with a user logged in. `hbb_common` already re-exports `libc` 0.2, so `libc::ioctl` needs no new crate (`nix` 0.29 is present but only with `["term","process"]`, which excludes its ioctl macros — do not widen it).

**Free tier, no privilege — the honest floor:** `/sys/block/*` (`queue/rotational`, `size`, `device/{model,vendor,serial}`), `/sys/class/nvme/nvme*/{model,serial,firmware_rev}`, `/proc/mdstat`, `statvfs` over `/proc/mounts`.

**NVMe temperature for free:** `/sys/class/nvme/nvmeN/device/hwmon*/temp1_input` (millidegrees). Depends on `CONFIG_NVME_HWMON`; probe for the file, do not assume.

**Privileged:**
- **NVMe** — `ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd)` on the **controller** node `/dev/nvmeN` (not the namespace). `_IOWR('N', 0x41, struct nvme_passthru_cmd)`; `sizeof == 72` on 64-bit, giving `0xC0484E41`. `opcode = 0x02` (Get Log Page), `nsid = 0xFFFFFFFF`, `data_len = 512`, `cdw10 = 0x007F0002` (log id 0x02, NUMDL = 512/4−1 = 127). Needs **CAP_SYS_ADMIN**. Returns byte-for-byte the same log page as the Windows NVMe path, so **one parser serves both**.
- **SATA/SAS** — `ioctl(fd, SG_IO /* 0x2285 */, &sg_io_hdr)` with a 16-byte ATA PASS-THROUGH (16) CDB: `85 08 2E 00 D0 00 01 00 00 00 4F 00 C2 00 B0 00`. Needs **CAP_SYS_RAWIO**. Returns the same 512-byte attribute table as the Windows SMART path, so again one parser.
- USB bridges and hardware RAID usually refuse pass-through → `verdict='unreadable'`, `health_source='none'`. **Never `ok`.**

### 5.3 macOS — an honest gap

There is no stable public user-space path. smartmontools reaches `IONVMeSMARTUserClient` / `IOAHCISMARTUserClient` via IOKit, but that is not public API, `smartctl` is not installed by default, and Apple-silicon internal NVMe does not expose the standard log page through anything I can verify. **v1 ships macOS with capacity, IOKit media identity, `verdict='unknown'`, `health_source='none'`.** The console renders unknown, never a green tick. If the fleet is macOS-heavy, the hard-drive-health bar is not met there, and no amount of design fixes that without a vendor path I could not find.

### 5.4 The parser's shape, and how it is tested

Two **pure** functions, no I/O, no platform code, in `src/labdesk/disk/`:

```rust
// ata.rs
pub struct AtaAttr { pub id: u8, pub flags: u16, pub current: u8, pub worst: u8, pub raw: [u8; 6] }
pub fn parse_ata_attributes(buf: &[u8; 512]) -> Vec<AtaAttr>;   // 2-byte rev, then 30 × 12 bytes
pub fn parse_ata_thresholds(buf: &[u8; 512]) -> HashMap<u8, u8>;

// nvme.rs
pub struct NvmeHealth { pub critical_warning: u8, pub temp_c: i32, pub avail_spare: u8,
                        pub spare_threshold: u8, pub percent_used: u8,
                        pub power_on_hours: u64, pub unsafe_shutdowns: u64,
                        pub media_errors: u64, pub data_written_gb: u64 }
pub fn parse_nvme_health(buf: &[u8; 512]) -> NvmeHealth;

// verdict.rs
pub fn verdict(src: Source, nvme: Option<&NvmeHealth>, ata: &[AtaAttr],
               thresholds: &HashMap<u8,u8>, predict_failure: Option<bool>) -> (Verdict, String);
```

Attributes lifted: 0x05 reallocated, 0x09 power-on hours, 0x0C power cycles, 0xBB reported-uncorrectable, 0xC2 temperature, 0xC5 pending, 0xC6 offline-uncorrectable, 0xC7 UDMA CRC, and the SSD life family 0xE7/0xAD/0xA9.

**Verdict rules** (computed on the agent so the reason travels with the reading, and **re-derived server-side from the stored counters** so the console never trusts an agent's own word for `ok`):

- `failing` — `PredictFailure != 0`; or `RETURN_SMART_STATUS` reports threshold exceeded (returned in the cylinder registers: `0x4F/0xC2` = not exceeded, `0xF4/0x2C` = exceeded); or any NVMe `CriticalWarning` bit set; or `AvailableSpare < AvailableSpareThreshold`; or ATA 5/197/198 raw > 0 with the normalised value at or below threshold.
- `warn` — reallocated > 0; pending > 0; uncorrectable > 0; CRC rising between samples; NVMe `PercentageUsed >= 90`; temp ≥ 60 °C for two consecutive hours.
- `unreadable` — every call refused or unsupported.
- `ok` — at least one call succeeded and nothing above applies.

**Unit tests, CI-provable.** Capture the raw 512-byte buffers once from real hardware (an NVMe log page and an ATA attribute table), commit them as `src/labdesk/disk/fixtures/{nvme_health_*.bin, ata_attrs_*.bin}` with a short provenance note, and test the pure parsers with `cargo test -p labdesk labdesk::disk`. This runs on Linux CI runners with no disks and no privileges, because the parsers are pure. Add a deliberately malformed fixture and assert the parser returns `unreadable` rather than panicking.

**Only provable on real hardware:** every `DeviceIoControl` / `ioctl` call site, the `SENDCMDINPARAMS` buffer sizing, the SG_IO struct layout, the NVMe `cdw10` encoding, and whether `StorageDeviceProtocolSpecificProperty` is answered — it is served by the storage **port** driver rather than the class driver and returns `ERROR_INVALID_FUNCTION` on some vendor stacks. Every call is written as *may-fail, record why, continue*: a disk that answered three of five questions is worth more than a collector that gave up on the first refusal. CI proves it compiles and that the parsers are right; it proves nothing else.

---

## 6. The health engine

This is a **migration** of `flutter/lib/labdesk/services/automation_engine.dart` (476 lines) and `models/automation_models.dart` (640 lines), not a greenfield build.

### 6.1 What moves server-side: the evaluation, all of it

The reason is in the file's own header (`automation_engine.dart:9-10`): *"Close the application and nothing is evaluated until it is opened again."* An RMM cannot have that property.

The port is cheap because the engine is already pure with the clock injected. `tick({now, status, metrics, machines}) -> List<Firing>` becomes a TypeScript function of the same shape in `src/worker/health-engine.ts`. **Port the Dart tests first, then the code** — they are the specification. The three invariants must survive verbatim:

1. **Edges are edges.** A transition fires only between two consecutive evaluations the engine actually watched. `unknown` means "nobody has asked", not "down", and nothing transitions through it.
2. **"for N minutes" means continuously.** Timed from `_trueSince`, discarded the instant the condition goes false; a flap resets it.
3. **Schedules never catch up.** A slot that came due while nothing was evaluating is accounted for and skipped, not replayed.

The eight in-memory maps (`_prevStatus`, `_baselined`, `_offlineSince`, `_trueSince`, `_latched`, `_cooldownUntil`, `_nextDue`, `_lastSlot`) become one `health_rule_state` row per `(ruleId, machineId)` — same names, same fields, durable.

The 200-entry in-memory `RunLog` becomes `health_event` + `machine_job`: durable, queryable, per-org, and it survives a restart.

**Behaviour change, stated rather than papered over:** "for N minutes" precision drops from one second to one cron minute. The ported tests restate that expectation explicitly.

### 6.2 Scheduling, given wrangler declares no cron

`wrangler.jsonc` has no `triggers` key today. Add `"triggers": { "crons": ["* * * * *", "7 * * * *"] }` and export `scheduled()` from `src/worker/scheduled.ts`. One minute is finer than anything the model needs — the smallest unit anywhere in `automation_models.dart` is a minute (`forMinutes`, hour/minute schedules, `UptimeAbove` days). The 1 s console tick was only ever an artefact of a Flutter `Timer`.

Each minute tick, in order:
1. Load enabled rules per org (`health_rule_org_idx`).
2. Reachability from `machine_state.seenAt` against `2 × flushSeconds` — offline means "missed two flushes", which is a definition an operator can be told.
3. Read `machine_state` **only for machines whose `seenAt` moved since the previous tick**, via `machine_state_seen_idx`. This is the index that exists precisely so this is a range scan and not a full table scan every minute.
4. Evaluate; read/write `health_rule_state` in one `db.batch()`, writing a row only when a field changed.
5. Emit: a `health_event` row always; a `machine_job` row for anything a machine must do.

### 6.3 What stays client-side, and what is deleted

- **Stays:** `automation_screen.dart` (1080 lines) as the rule **editor**, backed by `/api/org/rules` instead of a local option. Trigger and action JSON stay byte-identical, so existing rule JSON parses unchanged and the editor keeps working with no rewrite. `tool_catalog.dart` stays as the human-driven tools screen.
- **Deleted in the same release that lands the cron:** the Dart evaluation loop. If both run, every rule fires twice. This is a hard sequencing constraint, and it interacts with §9's Linux update gap — a fleet that cannot receive updates cannot be relied on to stop evaluating, which is why WP17 (Linux update delivery) is not optional.
- **Dropped from the action enum, not left as no-ops:** `MonitorOn` (meaningless once the collector is always on) and `OpenSession` (an RMM that opens remote sessions on a timer with no human present is the lateral-movement tool this design exists to remove).
- **Added triggers:** `DiskHealthBelow{verdict}` and `DiskSpaceAbove{pct}` — the two the hardware work makes possible.

### 6.4 RunCommand and its server-side audit record

`RunCommand` today carries `final String command` — free text executed over the headless link. **That type is deleted.**

**DECISION: the agent's executable surface is a catalog compiled into its own binary,** because that is the only fence that holds when the Worker itself is compromised, and it removes the entire "who holds the job signing key" subsystem that both source designs had to apologise for.

`src/labdesk/tools.rs` (new) mirrors `flutter/lib/labdesk/services/tool_catalog.dart`: each entry is `{ id, platform, argv template, param schema (typed, regex- or enum-bounded), run_as, timeout_s }`. A job names `toolId` + `params`. The **agent** validates every param against its **own compiled schema** and builds an `argv` **array** itself — never a shell string, never `sh -c`, never PowerShell `-Command`. A Worker that lies can only invoke a catalogued tool with in-range parameters. It cannot deliver code, so there is no code-delivery key to steal.

The flow, and the flow **is** the audit record:

1. The minute cron (or a technician) decides to run something.
2. The Worker looks up the catalog entry, checks org + platform, validates params, writes a `machine_job` row with `state='pending'`, `requestedBy` (NULL when a rule fired it), `ruleId`, `expiresAt = now + 3600`. **The row exists before the machine can see the job.** There is no dispatch path that does not write one.
3. If `runAs='system'`, the row stays `pending` until an **owner** sets `approvedBy ≠ requestedBy`. A rule-fired system job therefore always needs a live second human.
4. The agent pulls it on its next signed `/agent/batch` response, refuses any job id it has executed before (bounded persisted set), refuses one past `expiresAt`, executes the argv array with the declared `runAs` and `timeoutS`, captures ≤16 KiB, and returns `exitCode`, `output`, `outputSha256` on the following batch.
5. Anything unacknowledged past `expiresAt` becomes `expired` and is never dispatched.

Ad-hoc runs from the Tools screen take the **same path** and write the **same row**. There is no second, unlogged way to run anything.

Latency is bounded by `flushSeconds`; a job marked urgent sets `collectNow` in the response so the agent's next flush is 10 s. That is an explicit, named regression against today's 3 s tick and it is the price of not keeping a 3 s write cadence.

---

## 7. Machine metadata and the address book

### 7.1 Two mechanisms, deliberately

- `machine_tag(machineId, orgId, tag)` — flat labels, mirroring `Peer.tags` (`flutter/lib/models/peer_model.dart:18`). This is what the address-book projection returns and what fleet search filters on (`machine_tag_org_idx`).
- `machine_attr(machineId, orgId, key, value, source, setBy)` — arbitrary key/value, `source ∈ {manual, agent, rule}`. Agent writes are confined to `source='agent'` and are read-only in the console, so a rooted machine cannot write a field an operator reads as authority. Operator-set values are never overwritten by an agent that later learns the same key.

### 7.2 Extend the protocol, do not replace it

`ab_model.dart` already calls about fifteen endpoints — `/api/ab/settings` (`:233`), `/api/ab/personal` (`:265`), `/api/ab/shared/profiles` (`:297`), `/api/ab/peers` (`:1433`), `/api/ab/tags/<guid>` (`:1500`), peer add/update/delete, tag add/rename/update/delete — with per-profile permissions `ShareRule { read=1, readWrite=2, fullControl=3 }` (`flutter/lib/common/hbbs/hbbs.dart:210-216`) and `AbProfile { guid, name, owner, note, rule, info }`. The Worker answers **404** to the first three (`routes/client-api.ts:134-136`), so the client falls into legacy mode (`ab_model.dart:275-277`) and syncs one opaque blob through `GET/POST /api/ab` into `address_book.data TEXT` (`schema.ts:66-72`).

**DECISION: extend,** because an unmodified installed client gains org fleets in its peer list the moment the Worker starts answering, whereas replacing means rewriting ~2,000 lines of working Dart and shipping a client on every platform before anyone can see a fleet.

The projection:

- `/api/ab/personal` → the caller's personal `ab_book` guid, scoped to the active org.
- `/api/ab/shared/profiles` → **one profile per fleet the caller can see**, `rule` derived from the caller's org role: `viewer → 1`, `technician → 2`, `owner → 3`.
- `/api/ab/peers?ab=<guid>` → for a **fleet** book, `Peer` rows projected from `machine` + `machine_tag`: `id` from `peerId`, `alias` from `displayName`, `tags` from `machine_tag`, platform/hostname/username from `machine_attr` where `source='agent'`.
- `/api/ab/tags/<guid>` → the org tag vocabulary.
- Legacy `GET/POST /api/ab` keeps working for one release, then goes.

**The write-permission trap the judge caught, closed.** A fleet book is *projected*, so it has no rows to write. Handing the client `rule=2` or `3` would invite exactly the writes the server must refuse. Therefore: fleet profiles are returned with `rule` set from the role **and** the peer/tag mutation routes check `abBook.kind`. A write against a `kind='fleet'` book returns a **structured 409 naming the machine field to edit instead**, never a silent strip. Where the client would show an edit affordance it cannot use, `fleet_console.dart` is the surface that owns editing — a one-screen client change, not a protocol rewrite.

### 7.3 The unattended passwords

Today `Peer` carries both `hash` (personal-AB) and `password` (shared-AB) (`peer_model.dart:12-13`), and the whole book lands in one `address_book.data TEXT` column accepted with only a type check and a 512 KiB bound (`client-api.ts:150-151`). The Worker therefore holds, in plaintext at rest, whatever the client put there. One account compromise yields every machine's unattended password. That is the compromise the owner's bar rules out.

Three moves, **in this order**, and the order is the whole point:

1. **`hash` moves out of the blob** into `ab_peer.personalHash` — a typed, length-bounded column on a per-user book, returned only to that book's owner. It is already a hash, not a password, and `try_get_password_from_personal_ab` (`src/client.rs:3802`) keeps working unchanged.

2. **Build the replacement before removing anything.** `POST /api/console/session` (org-role authorized) mints the existing one-way NetBird grant **and** a `connect_ticket`: a 32-byte secret, 120 s, single-use, bound to one target machine and one controller peer id. The secret is returned once to the controller and delivered to the target on its **own signed uplink** (`tickets:` in the batch response), never through the Worker→target trust the client cannot check.

   The target's daemon hands the ticket to `--server` over the **0600 main IPC channel** (`src/ipc.rs:700-704` sets `0o0600` for non-service postfixes), **never over the 0666 `_service` channel** whose allowlist is deliberately `SyncConfig`-only (`ipc.rs:601-611`). `--server` stores it in a claim-once set built on `insert_pending_switch_sides_uuid` / `claim_pending_switch_sides_uuid` (`src/server/connection.rs:6147`, `:6170`), which is already unit-tested for exactly the property we need (`:7122-7136`: inserted once, claimed once, never claimed for the wrong peer). A new branch in `handle_hash` (`src/client.rs:3719`) presents the ticket ahead of the password chain.

3. **Only then** does a fleet book stop accepting `password`. A write containing it is rejected 400 — told, not silently stripped. The migration script parses each `address_book.data`, writes peers into `ab_peer` with `password` dropped, and **writes each owner a one-time note listing exactly which machines were affected** — without that note this reads as data loss rather than as a security decision.

The residual is named in §2: the Worker can grant sessions. It can no longer hand anyone a permanent reusable credential.

---

## 8. Console surfaces

Two consoles, one source of truth. Everything either renders server state or writes it; nothing evaluates locally.

**Owner's standing rule applies throughout: no cards, no glass boxes, no rounded containers.** Borderless editorial layout, full-bleed tables, type and rule-lines carrying the hierarchy. The `.panel` class exists in `app.css` but is **not** used to contain content.

### 8.1 Web — React, `src/app/pages/*`, routes registered in `APP_ROUTES` (`src/worker/index.ts:70`)

Every page reuses: `Shell` and `Notice` (`src/app/shell.tsx`), and from `src/app/app.css` — `.tbl` / `.tbl th` / `.tbl td` for full-bleed tables, `.act` / `.act--quiet` / `.act--danger` for actions (text with an accent rule, never boxes), `.field` for inputs (bottom-rule only), `.mono` for identifiers and measured values, `.hair` for rule-lines, `.dot[data-state="up|down|warn"]` for status, and the `@theme` tokens `--color-{canvas,surface,ink,soft,accent,line,up,down,warn}`.

| Route | File | Content |
|---|---|---|
| `/fleet` | `src/app/pages/fleet.tsx` | Every machine in the org: name, fleet, platform, seen, cpu/mem/disk, `worstDisk`, agent version. Filter by fleet and by tag (`machine_tag_org_idx` serves it). One indexed join, **not** the N+1 the overlay inbox does today. |
| `/machine/:id` | `src/app/pages/machine.tsx` | State, charts (`metric_hour` over 24 h, `metric_batch` under), disks with verdict + reason + `healthSource`, volumes, tags, attrs (`source='agent'` visually distinct and read-only), jobs, sessions, events. |
| `/fleets` | `src/app/pages/fleets.tsx` | Fleet CRUD, owner-only. |
| `/people` | `src/app/pages/people.tsx` | `member` with role editing, owner-only, fresh session required. Invitations reuse `src/worker/mail.ts` and the Access allowlist call in `src/worker/access.ts:47-56`, so inviting a technician opens the wall in the same click. |
| `/enrol` | `src/app/pages/enrol.tsx` | Mint a `machine_enrol_token`; show the exact `labdesk --enrol --token …` line per platform. |
| `/rules` | `src/app/pages/rules.tsx` | Rule list + enable/disable; the editor stays in Flutter for v1. |
| `/jobs` | `src/app/pages/jobs.tsx` | The audit: who asked, who approved, which tool, which params, exit code, output. The screen that answers "what did your software do on my machines last Tuesday". |
| `/alerts` | `src/app/pages/alerts.tsx` | `health_event`, acknowledge. |
| `/updates` | `src/app/pages/updates.tsx` | Channel and pin, owner-only. |

### 8.2 Flutter — `flutter/lib/labdesk/*`

All of these reuse `theme/console_theme.dart` (the `C` token class: `C.bg`, `C.chrome`, `C.surface`, `C.hairline`, `C.text`, `C.textMuted`, `C.textFaint`, `C.accent`, `C.accentDim`) and `theme/ld_icons.dart`.

| Screen | File | Change |
|---|---|---|
| Fleet | `screens/fleet_console.dart` | Fleet selector in the sidebar it already draws; `MachineRow` (`models/machine_row.dart`) gains `fleetName` and a disk verdict; `status` comes from `machine_state.seenAt` against `2 × flushSeconds`, so a machine's dot is honest whether or not a console has ever connected to it. |
| Health board | `screens/health_board.dart` | **Biggest change.** The `monitoredIds` / `probingIds` / `onToggleMonitor` API goes, and with it the copy at `:14-19` telling the operator that monitoring keeps a connection of its own and appears on the far machine as an incoming terminal session — that stops being true and stops being needed. Becomes a read of `metric_batch` / `metric_hour` over a chosen range. |
| Charts | `charts/metric_sparkline.dart`, `charts/reachability_chart.dart` | Draw stored history instead of the current session's ring buffer. |
| Metrics model | `models/machine_metrics.dart` | `MetricSource.remote` is replaced by `MetricSource.collector`; `session` survives for genuinely session-only figures (round trip, throughput, codec). The rule that absence renders `--` and never `0` (`:285-305`) is preserved — it is why `unreadable` can never be shown as healthy. |
| Automation | `screens/automation_screen.dart` | Editor only, backed by `/api/org/rules`. The "rules only run while the application is open" banner is deleted. |
| Tools | `screens/tools_screen.dart`, `services/tool_catalog.dart` | Every run goes through `machine_job`. |
| Disks | `screens/health_screen.dart` | Per-machine disk table; fleet-wide default view is "everything not healthy, worst first". Never renders `unreadable` as healthy; never renders a 98 %-full filesystem as a failing disk. |
| Sessions / Network / This machine | `screens/{sessions,network,this_machine}_screen.dart` | Rewired to server state. |
| Terminal | `screens/terminal_screen.dart` | Unchanged. A human at a keyboard. |
| **Deleted** | `services/metrics_collector.dart`, `services/probe_reader.dart` | Replaced by the collector. |

---

## 9. Build order — file-partitioned work packages

Each WP owns its files exclusively, so any set with satisfied dependencies runs in parallel. Every WP names a **runnable** verifier.

| WP | Owns | Depends on | Verifier |
|---|---|---|---|
| **1. Two indexes, alone** | `drizzle/0003_indexes.sql` | — | `npx vitest run test/indexes.test.ts` — asserts `EXPLAIN QUERY PLAN` for the `overlay_session WHERE ended_at IS NULL` and `labnet_member WHERE device_id = ?` queries reports `USING INDEX`, not `SCAN`. |
| **2. Ed25519-in-Workers spike** | `test/ed25519.test.ts` | — | `npx vitest run test/ed25519.test.ts` — imports a raw key and verifies a known-good vector under WebCrypto; on failure the same test proves the `node:crypto` fallback. **Blocks WP6. Three lines. Do it first.** |
| **3. Schema + migrations** | `src/worker/db/schema.ts`, `src/worker/db/auth-schema.ts`, `drizzle/0004..0007` | 1 | `npx drizzle-kit generate` produces no diff after the hand-written files, and `npx vitest run test/schema.test.ts` applies every migration through `readD1Migrations` in the existing pool-workers harness (`vitest.config.ts`). |
| **4. Org plane + `actor()`** | `src/worker/org.ts`, `src/worker/routes/org.ts`, `src/worker/auth.ts` (plugin list only) | 3 | `npx vitest run test/org.test.ts` — one **negative** test per route per role (viewer cannot open a session, technician cannot mint an enrol token, a member of org A gets 404 on org B's machine). |
| **5. Agent identity (Rust)** | `src/labdesk/identity.rs`, `src/core_main.rs` (`--enrol` arm only) | — | `cargo test -p labdesk labdesk::identity` in CI — key round-trips, file mode is 0600 on Unix, and `toml::to_string(&Config::get())` contains no byte of the secret key. **Cargo is not installed on this machine; CI is the only proof.** |
| **6. Agent auth (Worker)** | `src/worker/agent-auth.ts`, `src/worker/routes/agent.ts` (enrol + middleware) | 2, 3, 4 | `npx vitest run test/agent-auth.test.ts` — a fixed keypair and message signed once in `test/fixtures/agent-sig.json` (the same vector WP5 asserts), plus: bad signature 401, stale ts 401, revoked machine 403, bearer token alone 401. |
| **7. Collector (Rust)** | `src/labdesk/collector.rs`, `src/labdesk/spool.rs`, `src/platform/{windows,linux,macos}.rs` (start hook only) | 5 | `cargo test -p labdesk labdesk::spool` — cap-and-drop-oldest, truncate-on-2xx, backoff schedule, jitter determinism. CI only. |
| **8. Ingest + telemetry storage** | `src/worker/routes/agent-ingest.ts` | 3, 6 | `npx vitest run test/ingest.test.ts` — asserts the exact **row-write count per batch is 4** (the §4.6 arithmetic, as an executable assertion), plus idempotency: the same batch posted twice leaves the database byte-identical. |
| **9. Disk parsers (pure)** | `src/labdesk/disk/{ata.rs,nvme.rs,verdict.rs,fixtures/}` | — | `cargo test -p labdesk labdesk::disk` from committed byte fixtures, including a malformed fixture that must yield `unreadable` and not panic. Runs on a diskless CI runner. |
| **10. Disk platform plumbing** | `src/labdesk/disk/{windows.rs,linux.rs,macos.rs}`, `Cargo.toml` (two feature strings) | 9 | CI proves it **compiles** on all three targets. Correctness is **provable only on real hardware** — one Windows box with an NVMe and one with a SATA drive, one Linux box with each. Land the two `Cargo.toml` feature additions as a **no-op commit first** and let CI confirm before writing code against them. |
| **11. Health engine** | `src/worker/health-engine.ts`, `test/health-engine.test.ts` | 3 | `npx vitest run test/health-engine.test.ts` — the Dart tests ported case for case, with the "for N minutes" expectation restated at minute granularity. **Port the tests before the code.** |
| **12. Cron + retention** | `src/worker/scheduled.ts`, `wrangler.jsonc` (`triggers` only) | 8, 11 | `npx vitest run test/scheduled.test.ts` — the rollup folds a known hour correctly; the retention slice deletes exactly its cap and advances `maintenance.cursor`; a second run resumes and finishes. |
| **13. Tool catalog + jobs** | `src/labdesk/tools.rs`, `src/worker/tool-catalog.ts`, `src/worker/routes/jobs.ts` | 6, 11 | `cargo test labdesk::tools` (param validation rejects every injection shape; argv is always a vec) **and** `npx vitest run test/jobs.test.ts` (a `run_as='system'` job with `approvedBy === requestedBy` is refused; a job row exists before any dispatch is possible). A shared `tools.json` fixture keeps both catalogs in step, asserted by a test on each side. |
| **14. Agent overlay plane** | `src/worker/routes/agent-overlay.ts`, `src/worker/routes/overlay.ts` (human half) | 6 | `npx vitest run test/overlay.test.ts` — extend the existing file: a valid bearer with a chosen `deviceId` can no longer enrol, cannot overwrite another machine's `idPk`, and cannot obtain a grant. |
| **15. Connect tickets** | `src/worker/routes/ticket.ts`, `src/labdesk/ticket.rs`, `src/ipc.rs` (one variant), `src/server/connection.rs` (claim path), `src/client.rs` (one `handle_hash` branch) | 6, 14 | `cargo test claim_once` (extends the existing `test_pending_switch_sides_uuid_is_claimed_once`) **and** `npx vitest run test/ticket.test.ts` (expired ticket refused, second claim refused, ticket for another target refused). Note `src/client.rs` is under concurrent edit — re-read before touching. |
| **16. Address book** | `src/worker/routes/ab.ts`, `scripts/import-address-books.ts` | 3, 4 | `npx vitest run test/ab.test.ts` — a fleet book never returns `password`; a write to a fleet book returns 409 with the machine field named; the import drops every password and emits the per-owner affected-machine list. |
| **17. Web console** | `src/app/pages/{fleet,machine,fleets,people,enrol,rules,jobs,alerts,updates}.tsx`, `src/worker/index.ts` (`APP_ROUTES` only) | 4, 8 | `npm run build` passes and `npx vitest run test/console-api.test.ts` covers each page's data route. Visual quality is **not** machine-verifiable; it is reviewed against §8's design-system list. |
| **18. Flutter console** | `flutter/lib/labdesk/{screens,charts,models}/*` | 8, 11 | `flutter test` + `flutter analyze` in `flutter-ci.yml`. Deletes `metrics_collector.dart` and `probe_reader.dart` in the same commit that lands the collector. |
| **19. Linux delivery** | `res/DEBIAN/postinst`, `res/polkit/net.lab-desk.LabDesk.policy`, `src/updater.rs` (linux arm), `src/platform/linux.rs` (helper call) | 10 | `.github/workflows/ci.yml` builds the `.deb`; a scripted install on a clean container asserts the service starts as root and the polkit action file lands. See the caveat below. |
| **20. Update signing** | `.github/workflows/release-checksums.yml`, `src/updater.rs` (verify arm) | — | A release-dry-run job produces `SHA256SUMS` **and** `SHA256SUMS.sig`; `cargo test updater::verify` checks a good and a tampered fixture against the pinned public key. |
| **21. Access cutover** | Cloudflare Access application `38db8dbf-…` (outside both repos) | 6, 14 | `curl` from **outside the tenant**: `/agent/version` returns 200, `/api/overlay/inbox` still returns 302. Verified before the client release that depends on it. |

**Parallelism:** 1, 2, 5, 9, 20 have no dependencies and start immediately. 3 unblocks 4 and 8. 10 follows 9. 17 and 18 are independent of each other. 19 and 21 are independent of everything except their own prerequisites.

**The Linux polkit caveat, stated because the earlier design got it wrong.** `src/platform/linux.rs` invokes `pkexec dpkg -i` / `pkexec rpm -Uvh`. `pkexec` authorizes through `org.freedesktop.policykit.exec` against the program it launches, taking the action id from *that program's* polkit annotation. Shipping an action file named `net.lab-desk.labdesk.install-update` changes nothing for `pkexec dpkg`. WP19 therefore replaces the raw `pkexec` with `pkexec /usr/share/rustdesk/labdesk-helper install-update <path>` — a small annotated helper that verifies the published signature and digest itself before touching the package manager. The underlying finding is correct and confirmed: `src/updater.rs` has only `windows` and `macos` cfg arms, so **Linux receives no update at all** today, and `res/DEBIAN/postinst` (read in full above) does nothing but symlink the binary and enable the service.

**netbird stays out of `postinst`.** A package post-install script that silently joins a machine to an overlay is exactly the lateral-movement tool this design exists to avoid. Unattended agent enrolment on Linux is `labdesk --enrol --token <t>`, run by an admin or a config-management tool, root-gated like `--assign`.

---

## 10. What we are deliberately NOT building

| Not building | Why |
|---|---|
| **Durable Objects for presence or rule state** | A second storage system, a per-object cost and a new failure mode, to solve what a 5-minute uplink plus a durable `health_rule_state` row already solves. `wrangler.jsonc` declares none today and this keeps it that way. |
| **Queues for telemetry ingest** | Batching already happens in the agent, where the buffer also survives an outage. A component with no job. |
| **A server-held job signing key** | It was the fence both source designs relied on, and both had to admit the private half lives where the Worker can reach it — which retracts the property it was supposed to provide. The compiled-in tool catalog gives the same guarantee with no key at all. |
| **Org-authored custom scripts** | The moment operators can author arbitrary script bodies, we need a signing authority the Worker does not hold, and that is a key-management project. v1 ships the compiled catalog; custom scripts are named as future work, not quietly enabled. |
| **Free-text `RunCommand` over the wire** | It is the lateral-movement shape. The action type is deleted, and existing rules that used it land **disabled**, pointing at a catalog entry the operator must choose deliberately. |
| **`MonitorOn` and `OpenSession` actions** | Meaningless and dangerous respectively (§6.3). Removed from the enum, not left as no-ops. |
| **The console-side PTY probe for metrics** | Needs a stored password, appears on the far machine as an incoming terminal session, only runs while a console is open, and on Windows runs as the account **measured** to be denied every SMART surface. Structurally dead, not merely inconvenient. |
| **`smartctl` / WMI / PowerShell shell-outs** | A binary we do not ship, a driver on Windows, human-readable output whose format changes between versions, and a new privilege-escalation surface inside the security-critical process. |
| **One D1 row per metric sample** | Five times the writes for a resolution nobody queries at fleet scale. |
| **`WITHOUT ROWID` tables** | drizzle-kit does not emit it, so it means hand-editing every generated migration forever and reviewing every regeneration for the regression. Packing samples achieves the same write saving with no maintenance burden. |
| **A monotonic sequence counter or a nonce table for replay** | The counter locks agents out on reinstall and rejects concurrent uplinks; the table costs a row-write per request forever. Idempotent ingest gives the same property for free. |
| **A longer-lived or rotating bearer as the machine credential** | Still a bearer: a stolen file is still a complete impersonation, which is today's defect. |
| **mTLS client certificates for agents** | Strictly stronger, but Cloudflare mTLS is per-hostname configuration outside both repos and the Worker can neither mint nor revoke certs. More moving parts for a property Ed25519 already gives. |
| **Better Auth `teams` as fleets** | Teams group users; a fleet groups machines. It would need a user row per machine. |
| **Replacing the address-book protocol** | Better on paper; strands every installed client through a version-skew window and rewrites ~2,000 lines of working Dart that already implements shared profiles, rw/r rules and per-profile GUIDs. |
| **Encrypting the shared unattended password at rest** | Encryption does not fix a secret that must be decrypted and handed to every reader of a shared book. The connect ticket removes the need for the secret instead of protecting it. |
| **MSP multi-tenancy** | Explicitly out of scope by owner decision 1: an organization owns machines; humans join it with roles. |
| **macOS SMART** | No stable public path exists that I could verify. Shipped as `unknown` from day one so the console never has to retro-fit an honest empty state, and named as an unmet requirement rather than papered over. |

---

## Standing risks

1. **Cloudflare Access is the single most likely silent breakage.** `/api/overlay/*` 302s to a login page today. Every `/agent/*` path must be on the bypass **before** the agent release, and `/api/heartbeat` / `/api/sysinfo` come **off** it afterwards. The change lives in the Access application (`CF_ACCESS_APP_ID 38db8dbf-…`, `wrangler.jsonc`), outside both repos. WP21 is a separate, externally verified change for that reason.
2. **No Cargo on this machine.** Every Rust claim here is read from source, never compiled. The three most likely to be wrong on first build: the two `Cargo.toml` feature additions, the SG_IO / ATA PASS-THROUGH(16) struct layout, and the NVMe `cdw10` encoding. Land the feature additions as a no-op commit first.
3. **D1 is single-writer SQLite.** ~1.15 M row-writes/day at 500 machines is comfortable; 5,000 machines is ~11.5 M/day. I have not measured D1's sustained write throughput, and it may bind before cost does.
4. **`actor()` is the only source of human authority,** so a bug in it is a total authorization bypass. It needs a negative test per route per role, which WP4's verifier makes mandatory rather than aspirational.
5. **The engine port drops "for N minutes" precision** from one second to one minute. Real behaviour change; the ported tests restate it.
6. **Mixed-version fleets double-fire rules** until every client has the release that deletes the Dart evaluation loop — and Linux currently cannot receive an update at all. WP19 is therefore a prerequisite for WP11's rollout, not a nice-to-have.
7. **Several line numbers here will have moved.** `src/updater.rs`, `src/hbbs_http/sync.rs`, `src/client.rs`, `src/rendezvous_mediator.rs`, `worker/routes/{updates,client-api,overlay}.ts`, `worker/netbird.ts` and both `ci.yml` files are under concurrent edit. Symbols are stable; re-read before touching.