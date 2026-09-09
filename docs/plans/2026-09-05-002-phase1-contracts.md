---
type: contract
created: 2026-09-05
status: active
supersedes: nothing
related:
  - docs/plans/2026-09-04-003-rmm-architecture.md
  - docs/plans/2026-09-04-002-rmm-decisions.md
  - docs/plans/2026-09-05-001-production-program.md
---

# Phase 1 wire contracts

Two lanes build phase 1 at once, one in the client repository (`~/TrapLab/LabDesk`, branch
`feat/labnet`) and one in the site repository (`~/TrapLab/labdesk-site`, branches
`feat/labnet-broker` and `dev`). Both build against the shapes written here. The same file lives
in the site repository as `docs/phase1-contracts.md`; a change lands in both copies in the same
round or it is not a change.

Every claim about existing code names the file and the symbol it was read from. Sections 1 to 9
were read at client `d11800abd` and site `d191d97`, before either lane had built anything;
section 11 is the client lane's corrections and section 12 is the state of both repositories at
client `d572566815` and site `fb3c14e`, which is where a reader should start. Each section says
what EXISTS (read from code) and what is MISSING (fixed here, inside what
`2026-09-04-003-rmm-architecture.md` already says). Nothing here
adds a table, a storage system or a mechanism section 10 of that plan rules out. Where this
document has to choose something the plan left open, the choice is marked "contract decision"
and the reason is inline.

Words used throughout: the DAEMON is the `--service` process (LocalSystem on Windows, root on
Linux and macOS; `crate::platform::start_os_service` in each `src/platform/*.rs` starts the
collector and the self-healer from it). The USER PROCESS is `--server` plus the Flutter console.
The MACHINE PLANE is `/agent/*`, signed with the agent key (`src/worker/agent-auth.ts`). The HUMAN
PLANE is `/api/org/*` and `/api/overlay/*`, mounted a second time under `/console` for the desktop
console (`src/worker/index.ts`, the loop over `["/api", "/console"]`); every human-plane route named
below therefore answers at both prefixes with the same `actor()` (`src/worker/org.ts`).

## 1. The shared tool catalog, tools.json

### What exists

- Client, human driven: `flutter/lib/labdesk/services/tool_catalog.dart` (`ToolCatalog`) holds one
  shell line per tool per platform, run over the PTY link and parsed by `tool_parsers.dart`. The
  ids are `ToolId` in `flutter/lib/labdesk/models/tool_models.dart`: `services`, `processes`,
  `eventLog`, `software`, `disk`, `network`, `power`, `scripts`. The acting entries are
  `ToolCatalog.actionFor` (service start, stop, restart; process kill) and `ToolCatalog._power`
  (restart, shut down, log off, lock). `ToolCatalog._safeTarget` filters a target to
  `[A-Za-z0-9._@:+\-/\\]`; a pid is further held to `^\d+$`.
- Server: `machine_job.tool_id` and `machine_job.params` in `src/worker/db/schema.ts`
  (`machineJob`), with the comment "catalog entry, agent-validated". `test/health-engine.test.ts`
  already carries an action of the shape `{"kind":"runTool","toolId":"flush_dns","params":{}}`
  and `parseRules` in `src/worker/health-engine.ts` passes it through untouched.
- Absent on both sides: there is no `src/labdesk/tools.rs`, no `src/worker/tool-catalog.ts`, no
  `src/worker/routes/jobs.ts`, no `tools.json` anywhere in either repository (checked with
  `grep -rn "tools.json"` and `ls src/labdesk`, `ls src/worker`).

### The contract

One file, byte identical in both repositories:

- client: `src/labdesk/tools.json`, compiled into the binary with `include_str!` by
  `src/labdesk/tools.rs`;
- site: `src/worker/tools.json`, imported by `src/worker/tool-catalog.ts`.

Each side asserts against its own copy: `cargo test labdesk::tools` and
`npx vitest run test/jobs.test.ts` (the verifiers section 9 names for WP13). Compare the
two copies with `cmp` as part of the WP13 verification; any difference fails the check.

Schema (JSON, no comments in the file itself):

```json
{
  "version": 1,
  "tools": [
    {
      "id": "service_restart",
      "label": "Restart a service",
      "runAs": "system",
      "timeoutS": 60,
      "params": {
        "unit": { "type": "pattern", "pattern": "^[A-Za-z0-9._@:+-]{1,128}$" }
      },
      "platforms": {
        "windows": { "steps": [["sc.exe", "stop", "{unit}"], ["sc.exe", "start", "{unit}"]] },
        "linux":   { "steps": [["systemctl", "restart", "{unit}"]] },
        "macos":   { "steps": [["launchctl", "stop", "{unit}"], ["launchctl", "start", "{unit}"]] }
      }
    }
  ]
}
```

Rules, all of them enforced by the agent against its compiled copy and by the Worker against
its copy before a `machine_job` row is written (plan section 6.4):

- `id` matches `^[a-z][a-z0-9_]{1,63}$`.
- `runAs` is `active_user` or `system`, the two values `machine_job.run_as` takes.
- `timeoutS` is 1 to 3600; the job row copies it.
- `params` is an object of named parameters. Three types only:
  `{"type":"pattern","pattern":<anchored regex>}`, `{"type":"enum","values":[...]}`,
  `{"type":"int","min":<n>,"max":<n>}`. Every parameter listed is required; a job carrying a
  parameter the entry does not list is refused. `params` on the wire is at most 4 KiB.
- `platforms` names a subset of `windows`, `linux`, `macos`. A job for a platform the entry does
  not name is refused by the Worker at request time (`machine.platform`) and again by the agent.
- `steps` is a list of argv arrays. The agent runs each with `std::process::Command::new(argv[0])`
  and `.args(&argv[1..])`, in order, stopping at the first non-zero exit. There is no shell:
  never `sh -c`, never `cmd /c`, never `powershell -Command` (section 6.4). A step is more than
  one argv only because Windows and macOS have no single-command restart.
- `{name}` is substituted only when it is the WHOLE argument, after the parameter passed its
  check. A template token inside a longer argument is a catalog error the tests reject; a
  parameter value is never split, quoted or interpreted.
- Output is stdout followed by stderr, truncated to 16 KiB, sha256 over the truncated bytes.

Compiled-in entries for v1 (contract decision: the ACTING tools, taken one for one from
`ToolCatalog.actionFor` and `ToolCatalog._power`, plus `flush_dns`, the one id the site's engine
test already names). The READING tools (`services`, `processes`, `eventLog`, `software`, `disk`,
`network`) stay on the console's PTY path in phase 1, because their shell lines are awk and
PowerShell pipelines that have no argv form; a later round can add argv listings with agent-side
parsers. The `scripts` tool is free text and is not in the catalog by section 10 of the plan.

| id | runAs | params | windows | linux | macos |
|---|---|---|---|---|---|
| `service_start` | system | `unit` pattern above | `sc.exe start {unit}` | `systemctl start {unit}` | `launchctl start {unit}` |
| `service_stop` | system | `unit` | `sc.exe stop {unit}` | `systemctl stop {unit}` | `launchctl stop {unit}` |
| `service_restart` | system | `unit` | stop then start | `systemctl restart {unit}` | stop then start |
| `process_kill` | system | `pid` int 1 to 4194304 | `taskkill.exe /PID {pid} /F` | `kill -9 {pid}` | `kill -9 {pid}` |
| `power_restart` | system | none | `shutdown.exe /r /t 0` | `systemctl reboot` | `osascript -e "tell app \"System Events\" to restart"` |
| `power_shutdown` | system | none | `shutdown.exe /s /t 0` | `systemctl poweroff` | `osascript -e "tell app \"System Events\" to shut down"` |
| `power_logoff` | active_user | none | `shutdown.exe /l` | `loginctl terminate-user {user}` (see below) | `osascript -e "tell app \"System Events\" to log out"` |
| `power_lock` | active_user | none | `rundll32.exe user32.dll,LockWorkStation` | `loginctl lock-sessions` | `pmset displaysleepnow` |
| `flush_dns` | system | none | `ipconfig.exe /flushdns` | `resolvectl flush-caches` | `dscacheutil -flushcache` then `killall -HUP mDNSResponder` |

`unit` uses the `_safeTarget` character class without `/` and `\`, which a unit name never needs
and which would otherwise let a parameter name a path. `power_logoff` on Linux takes the user
from `crate::platform::get_active_username()` (`src/platform/linux.rs`), never from a parameter;
the argv is built by the agent with that value, so the entry has no `{user}` token a caller can
fill. As shipped in `tools.json` the Linux step is `["loginctl", "terminate-user"]` and the agent
appends the username as the final argument (round 1 of the site lane; the file is the contract). `taskkill.exe` and `sc.exe` replace the PowerShell cmdlets of `tool_catalog.dart` because a
cmdlet needs `-Command`.

What `runAs` costs, stated so nobody is surprised in the console: seven of the nine v1 entries
are `system`, so a technician's request sits `pending` until an owner other than the requester
approves it (section 2 row 8). Only `power_logoff` and `power_lock` run on a technician's word
alone. That is the plan's rule, not this document's.

## 2. The job outbox and the result wire

### What exists

- `machine_job` in `src/worker/db/schema.ts` (`machineJob`), with `state` in
  `pending | approved | dispatched | running | done | failed | expired | refused`, `run_as`,
  `approved_by`, `expires_at`, `output` (16 KiB), `output_sha256` and the two indexes
  `machine_job_pickup_idx (machine_id, state)` and `machine_job_org_at_idx`.
- `src/worker/scheduled.ts` retires `machine_job` at 180 days (`RETENTION`, key
  `machine_job_retention`) and is the only code that names the table today; `evaluateOrg` writes
  `health_event` rows for a firing and no job row.
- `POST /agent/batch` (`src/worker/routes/agent-ingest.ts`) answers
  `{ ok, sampleSeconds, flushSeconds }` and nothing else; `jobResults` in the request is accepted
  and ignored (the handler's comment lists it). `collector.rs::adopt_cadences` reads only the two
  cadences out of the answer, so a client in the field ignores unknown members.
- `org.ts` grants: `job:request` belongs to `technician` and `owner`; `org:admin` to `owner`
  (`GRANTS` in `src/worker/org.ts`). `FRESH_SECONDS` is 300.

### The contract

Human plane, `src/worker/routes/jobs.ts`, mounted through the same `["/api", "/console"]` loop
as `org.ts`, so every path below also answers under `/console`:

| Route | Need | Body and answer |
|---|---|---|
| `POST /api/org/jobs` | `job:request`, target `{ machineId }` | `{ machineId, toolId, params, urgent? }`. The Worker looks the tool up, checks `machine.platform` against `platforms`, validates `params`, writes the row with `requestedBy` the caller, `requestedAt` now, `expiresAt` now + 3600, `runAs` and `timeoutS` copied from the entry, `urgent` (a column added by `drizzle/0011_job_urgent.sql`, since the schema had nowhere else to hold it), and `state` `approved` when `runAs` is `active_user`, `pending` when `system`. Answers 201 `{ id, state, expiresAt }`. Unknown tool, wrong platform or a bad parameter is 400 naming the parameter. |
| `POST /api/org/jobs/:id/approve` | `org:admin` with `FRESH_SECONDS` | Refused 409 when `approvedBy` would equal `requestedBy`, 409 when `state` is not `pending`, 410 past `expiresAt`. Sets `approvedBy`, `approvedAt`, `state` `approved`. A rule-fired job (`requestedBy` NULL) needs this call like any other (section 6.4 step 3). |
| `POST /api/org/jobs/:id/refuse` | `org:admin` | `pending` only; `state` `refused`. |
| `GET /api/org/jobs?machineId=&state=&since=` | `read` | The org's rows, newest first, narrowed by `member_fleet` through `actor()` like `/api/org/machines`. Answers `{ jobs: [row] }` with every column of the table except that `output` is present only on `GET /api/org/jobs/:id`. |
| `GET /api/org/jobs/:id` | `read` | One row, `output` included. |

Rate limit: `overLimit(db, "jobs:request:" + userId, 30)` from `src/worker/routes/overlay.ts`, the
same table and helper the labnet routes use (section 2 row 5).

Engine: a `Firing` whose action is `{"kind":"runTool","toolId","params"}` becomes a job row
written by `evaluateOrg` in `src/worker/scheduled.ts` in the same `commit()` as its
`health_event`, with `ruleId` set, `requestedBy` NULL, `machineId` the firing's, and the same
`pending`/`approved` split by `runAs`. A `notify` action stays a `health_event` only, as today.

Machine plane, inside `POST /agent/batch` (no new route; section 4.4):

Answer gains two members:

```json
{
  "ok": true, "sampleSeconds": 60, "flushSeconds": 300,
  "jobs": [
    { "id": "2f1c...", "toolId": "service_restart", "params": { "unit": "spooler" },
      "runAs": "system", "timeoutS": 60, "expiresAt": 1788483600 }
  ],
  "tickets": [ ],
  "collectNow": true
}
```

- `jobs` is every row for this machine with `state` `approved` and `expiresAt` in the future, at
  most 16 per answer, oldest first. Handing them out sets `state` `dispatched` and
  `dispatchedAt` in the same `db.batch()` as the ingest, guarded `WHERE state = 'approved'`, so a
  replayed batch is answered with nothing (section 3.3).
- `collectNow` is present and `true` when the answer carries at least one job whose row was
  requested with `urgent`, and the agent then takes a sample at once and flushes 10 s later rather
  than at `flushSeconds` (section 6.4). Absent otherwise. THE SAMPLE IS HALF THE CONTRACT: `flush()`
  returns without sending anything when the spool holds no line, and ten seconds after a flush it
  never does, so an early flush with no sample brought forward carries nothing at all. Measured on
  homebox-devserver 2026-09-05, before the sample was brought forward with it: an urgent `flush_dns`
  exited 0 at 16:27:13 and its result reached the server on the ordinary 300 s tick.
- Rows left `approved` or `dispatched` past `expiresAt` are moved to `expired` by the minute tick
  in `scheduled.ts` (`minuteTick`), never dispatched, and reported as such.

The batch's own `machine` member names this machine's kind, and that is what makes a job possible
at all: `machine.platform` is the key every catalog entry is looked up by, and until 2026-09-05
nothing in the product wrote that column, so a really enrolled machine was refused every tool with
"That machine has not reported its platform yet."

```json
"machine": { "hostname": "...", "os": "...", "platform": "linux", "arch": "x86_64",
             "agentVersion": "1.2.6", "uptimeS": 41736, "loggedInUser": "homebox" }
```

`platform` is one of `windows`, `linux`, `macos`; the ingest stores a word this build's catalog
knows and leaves the column alone otherwise, so a machine cannot name itself into a tool set.

Request gains one member, sent on the batch AFTER the job ran:

```json
{
  "machine": { "...": "as today" },
  "batch": { "...": "as today" },
  "jobResults": [
    { "id": "2f1c...", "startedAt": 1788480123, "finishedAt": 1788480125,
      "exitCode": 0, "output": "...", "outputSha256": "9c9b...", "refused": null }
  ]
}
```

- `exitCode` is an integer, or `null` with `refused` a short string when the agent did not run
  the job: `expired`, `unknown_tool`, `bad_params`, `wrong_platform`, `already_ran`, `timeout`,
  `no_active_user` (the seventh word, from the `runAs` paragraph below; the Worker accepts all
  seven and refuses the member 400 on any other).
  The Worker maps `exitCode === 0` to `done`, any other integer to `failed`, `refused` to
  `refused`, and writes `startedAt`, `finishedAt`, `exitCode`, `output` (re-truncated to 16 KiB),
  `outputSha256`. The update is guarded `WHERE state IN ('dispatched','running')` (section 3.3),
  so a replay writes nothing.
- Agent side (`src/labdesk/tools.rs`, run from the collector's flush loop in
  `src/labdesk/collector.rs`): the agent refuses an id it has already executed. The executed ids
  are a bounded set of 256 persisted next to the identity file (`AgentIdentity::path()` in
  `src/labdesk/identity.rs` resolves the directory), so a daemon restart cannot re-run a job the
  server re-sends. The agent refuses a job past `expiresAt` by its own clock, and runs the rest
  with `runAs`: `system` in the daemon's own context; `active_user` through the same platform
  arm `crate::platform::run_as_user` uses for `--server` on Linux (`src/platform/linux.rs`, the
  `run_as_user` call in `start_os_service`) and the winlogon-token launch on Windows
  (`src/platform/windows.rs::launch_process` family). Which arm serves `active_user` on macOS is
  the builder's to prove in CI and in the field; the contract only says the job runs as the
  logged-in user or is refused `no_active_user`, never as the daemon.
- `output` in a request counts against the 64 KiB body bound `MAX_BODY_BYTES` in
  `agent-ingest.ts`; the agent sends at most four results per batch and keeps the rest for the
  next one, so results never displace samples.

## 3. The connect ticket

### What exists

- `connect_ticket` in `src/worker/db/schema.ts` (`connectTicket`): `target_machine_id`,
  `controller_peer_id`, `secret_hash`, `issued_to`, `session_id`, `issued_at`, `expires_at`
  (comment: issued_at + 120), `delivered_at`, `claimed_at`, with `connect_ticket_target_idx`.
  `scheduled.ts` retires expired rows (`connect_ticket_retention`, `keepDays: 0`). Nothing writes
  the table today (`grep connectTicket src/worker` finds only the schema and the retention row).
- `POST /api/overlay/session` (`src/worker/routes/overlay.ts`) answers
  `{ id, targetAddr, targetIdPk }` and writes `overlay_session` with `requestedBy`.
- Target side, claim-once machinery: `insert_pending_switch_sides_uuid`,
  `has_pending_switch_sides_uuid`, `claim_pending_switch_sides_uuid` on
  `PENDING_SWITCH_SIDES_UUID` in `src/server/connection.rs` (the map holds
  `(Instant, Uuid, claimed)` and keeps claimed entries until `SWITCH_SIDES_UUID_TTL`), tested by
  `test_pending_switch_sides_uuid_is_claimed_once`.
- Controller side, the credential chain in `handle_hash` (`src/client.rs`): the `switch_uuid`
  block first, then last password, preset, `shared_password` (`PasswordSource::SharedAb`), the
  peer config password, `try_get_password_from_personal_ab`, and the builtin
  `OPTION_DEFAULT_CONNECT_PASSWORD`. `PasswordSource` is the enum above `LoginConfigHandler`.
- IPC: `Data` in `src/ipc.rs` has `Labnet(LabnetRequest)` and `LabnetResult`, served by
  `src/labdesk/labnet.rs::serve` only in the privileged process (`crate::platform::is_root()`).
  On Linux and macOS the `_service` channel (0666) admits only `SyncConfig` and `Labnet`
  (the allowlist at the `POSTFIX_SERVICE` match in `ipc.rs`); the main channel `""` is 0600 and
  is served by `--server` (`crate::ipc::start("")` in `src/server.rs`). On Windows
  `labnet::IPC_POSTFIX` is `""` and the same `--server` process, LocalSystem, serves it.

### The contract

Mint. `POST /api/overlay/session` (and `/console/overlay/session`) keeps its body and gains one
member in the answer:

```json
{ "id": "<overlay_session.id>", "targetAddr": "100.64.0.7:21118", "targetIdPk": "...",
  "ticket": { "id": "<connect_ticket.id>", "secret": "<base64 32 bytes>", "expiresAt": 1788480243 } }
```

The row is written in the same handler: `orgId` and `issuedTo` from the actor,
`targetMachineId` the target's `machine.id`, `controllerPeerId` the controller's
`machine.peerId` (both already resolved by `actor()` in that route), `secretHash` `sha256Hex`
of the secret (`src/worker/crypto.ts`), `sessionId` the session id, `expiresAt` issued + 120.
The plaintext appears in this answer and nowhere else. A ticket is minted only with a session
(contract decision: the session route is the one place both ends are already authorized, so
no second route needs a second authorization story). The console stores the secret in the
option `labdesk-ticket-<peer id>` beside `labdesk-overlay-addr-<id>` and
`labdesk-overlay-pk-<id>` (`docs/CONSOLE.md`, "A session"), and clears it with them.

Deliver. The `tickets` member of the `/agent/batch` answer (section 2 above) carries, for the
signed machine only, every row with `targetMachineId` equal to `c.get("machine").id`,
`claimedAt` NULL and `expiresAt` in the future:

```json
"tickets": [ { "id": "...", "secret": "<base64>", "controllerPeerId": "1935956186", "expiresAt": 1788480243 } ]
```

The row holds only `secret_hash`, so what the Worker can deliver later is the hash, and that
is what it delivers (contract decision, because storing the plaintext would be the reusable
credential section 7.3 exists to remove, and encrypting it needs key material section 10 rules
out). Let `H = sha256Hex(secret)`, the value already in `secret_hash`. The controller presents
`sha256(H || salt)` as its password, computing `H` locally from the secret it was handed once;
the target holds `H` from the delivery above and checks the same derivation. Nothing new is
stored, the plaintext leaves the Worker exactly once, and a replayed delivery mints no second
credential. `handle_hash` hashes `H` with the salt exactly the way its `shared_password` branch
hashes that string. `deliveredAt` is set on first delivery where NULL; delivery is otherwise
read-only (section 3.3).

Claim, on the target. New IPC variant in `src/ipc.rs`:

```rust
Data::ConnectTicket { id: String, controller_peer_id: String, secret_hash: String, expires_at: i64 }
```

sent by the daemon to `--server` over the main channel `""` (0600; on Windows the same
LocalSystem `--server`), never over `_service` (plan section 7.3 step 2). `--server` keys a
claim-once map by `controller_peer_id`, built on the same shape as
`PENDING_SWITCH_SIDES_UUID`: insert once per ticket id, claim once, never for another peer id,
expire at `expires_at`. `cargo test claim_once` extends
`test_pending_switch_sides_uuid_is_claimed_once`. Where the login is checked in
`src/server/connection.rs` (the branch that validates the presented password against the stored
one), a presented password equal to `sha256(secret_hash || salt)` for an unclaimed ticket from
this connection's peer id claims it and passes; a second use of the same ticket is refused like
a wrong password.

Report. `POST /agent/ticket/:id/claimed`, signed, target only: sets `claimedAt` where NULL;
404 for a ticket whose `targetMachineId` is not the signer, 409 when already claimed, 410 past
`expiresAt`. These three refusals are `test/ticket.test.ts` (WP15's verifier). The route lives
in `src/worker/routes/ticket.ts` and mounts below `agentGuard` like every `/agent/*` router
(`src/worker/index.ts`).

Controller branch. In `handle_hash` (`src/client.rs`), a new block between the `switch_uuid`
block and the "last password" read: if `LoginConfigHandler` carries a ticket (read from the
option `labdesk-ticket-<peer id>` at the same point `labdesk-overlay-addr-<id>` is read), the
password becomes `sha256(sha256Hex(secret) || hash.salt)` with `password_source` set to a new
`PasswordSource::Ticket`, and the chain continues unchanged when there is none. The shared
password path is not removed in phase 1 (plan section 0.3).

## 4. The address book: fleet book rules

### What exists, and is the contract as built

`src/worker/routes/ab.ts` implements section 7.2 and is mounted ahead of `client-api.ts`, whose
three stubs answer 404 to select the legacy blob book (`src/worker/index.ts`, the comment above
`app.route("/", ab)`). The rules a consumer relies on:

- `principal()` authenticates with `bearerUser` (`routes/client-api.ts`), not `actor()`, and
  refuses a caller of several organizations with 400 "Choose an organization first."
- A fleet book's guid IS its fleet id (`book()`); `ab_book` holds personal books only. The plan's
  `ab_book.kind = 'fleet'` rows are not written; `kind` is decided in `book()`. This is a
  correction to plan section 1.2 and is recorded here.
- `POST /api/ab/shared/profiles` answers one profile per fleet in reach with
  `rule` from `RULE` (`viewer 1, technician 2, owner 3`) and `owner` the organization name.
- `POST /api/ab/peers?ab=<guid>` on a fleet book projects `machine` rows with `revokedAt` NULL:
  `id` from `peerId`, `alias` from `displayName`, `hostname`, `platform` from `machine`,
  `username` from `machine_attr` where `key = 'username'` and `source = 'agent'`, `tags` from
  `machine_tag`. There is no `hash` and no `password` on a fleet peer.
- Personal book peers carry `hash` from `ab_peer.personal_hash`, returned only to the owner.
- Every write against a fleet book answers 409 through `projected()`:
  `{ error, machineField, peerId? }`, `machineField` from `MACHINE_FIELD` (`alias` names
  `displayName`, `tags`, `note`, `hostname`, `platform`, `username`, `hash` names
  `displayName`; anything else `fleetId`).
- Every write carrying `password` answers 400 through `refusesPassword()` on both kinds of book.
- `PUT /api/ab/peer/update/:guid` on a personal book with `hostname`, `platform` or `username`
  and no machine in reach carrying that peer id answers 409 `{ error, unstoredFields, peerId }`
  after writing whatever else the body asked.
- `POST /api/ab/tags/:guid` on a fleet book answers the distinct tags of that fleet's live
  machines, `color` 0, and not the whole org vocabulary (the comment there records why).
- `unimported()` keeps a caller in legacy mode while they still hold an `address_book` blob and
  no `ab_book` row; `scripts/import-address-books.ts` mints the row.

Nothing in phase 1 changes these. What phase 1 adds beside them: the machine fields the
projection reads (`displayName`, `machine_tag`, `machine_attr` `username`) need a writer.
`username` arrives from the collector as the `attrs` member below (section 6); `displayName`
and tags are set through `PATCH /api/org/machines/:id { displayName?, tags? }` with
`machine:write` (plan section 2 row 3), landed in `src/worker/routes/org.ts` with
`test/console-api.test.ts` in the site lane's round 1 rather than waiting for WP17.

## 5. Health and telemetry read routes for the consoles

### What exists

- Written by the ingest: `machine_state` (hot row), `metric_batch` (packed windows),
  `machine`, `disk`, `disk_sample` (`agent-ingest.ts`, the `db.batch()` list). Written by the
  cron: `metric_hour` (`foldHour`), `health_event` and `health_rule_state` (`evaluateOrg`) in
  `src/worker/scheduled.ts`.
- Read routes: `GET /api/org/machines` answers `machine` columns only (`id, fleetId, peerId,
  displayName, hostname, platform, agentVersion, enrolledAt, revokedAt`);
  `GET /api/org/machines/:id` answers the `machine` row. No route reads `machine_state`,
  `metric_batch`, `metric_hour`, `disk`, `disk_sample` or `health_event` for a human.
- The admin overview reads reachability for the admin only (`GET /api/admin/overview`,
  `src/worker/routes/admin.ts`).
- Reachability rule, already in code: `evaluateOrg` in `scheduled.ts` computes
  `unknown` when `machine_state.seen_at` is NULL, `online` when `now - seenAt <= 2 *
  machine.flushSeconds`, `offline` otherwise. The consoles use this rule and no other.
- The Flutter console today: `console_page.dart::_probe` opens a PTY link
  (`LabDeskMachineLink.open`, `LabDeskTerminalRpc.probeOn`) every 30 s per monitored machine,
  parses with `services/metrics_collector.dart::MetricsCollector.parse` and
  `services/probe_reader.dart`, and holds history in `MetricHistory` (`models/machine_metrics.dart`).
  `MetricSource.remote` marks those readings. `screens/health_board.dart::HealthBoard` takes
  `monitoredIds`, `probingIds`, `onToggleMonitor`.

### The contract

Five human-plane routes in `src/worker/routes/org.ts` (so they answer under `/console` too),
all `read`, all narrowed through `actor()`:

All five landed in the site lane's round 1 with `test/console-api.test.ts`.

`GET /api/org/machines/:id/state`

```json
{ "machineId": "...", "status": "online", "seenAt": 1788480300, "flushSeconds": 300,
  "cpuPct": 7, "memPct": 42, "fsWorstPct": 55, "uptimeS": 86400, "loggedInUser": "dan",
  "agentVersion": "1.2.4", "worstDisk": "ok" }
```

`status` is the reachability rule above; every other field is the `machine_state` row, `null`
when the column is NULL, never 0 (`machine_metrics.dart` renders `--`). A machine with no row
answers `status: "unknown"` and every reading `null`.

`GET /api/org/machines?state=1` extends the inventory answer with the same `status`, `seenAt`,
`cpuPct`, `memPct`, `fsWorstPct`, `worstDisk` per machine in one left join, the way
`evaluateOrg` already reads them, so the fleet list is one query (plan section 8.1, "not the
N+1").

`GET /api/org/machines/:id/metrics?from=<unix>&to=<unix>`

```json
{ "step": 60, "batches": [ { "from": 1788480000, "to": 1788480240, "samples": [[7,42,55,1000,2000], [null,42,55,1100,2100]] } ],
  "hours": [ { "hourAt": 1788476400, "cpuAvg": 6.5, "cpuMax": 30, "memAvg": 41, "memMax": 44, "fsWorstMax": 55, "upMinutes": 60, "samples": 60 } ] }
```

`batches` are `metric_batch` rows overlapping the range, `samples` parsed from the stored JSON
with nulls preserved, the packing `collector.rs::pack` pins (`[cpu, memPct, fsWorstPct, netRx,
netTx]`). `hours` are `metric_hour` rows in the range. A range wider than 7 days answers `hours`
only and `batches: []`. At most 2016 batches per answer (7 days at 300 s).

`GET /api/org/machines/:id/disks`

```json
{ "disks": [ { "id": "...", "serialHash": "...", "deviceIndex": 0, "devicePath": "/dev/nvme0n1", "model": "...",
  "firmware": "...", "bus": "nvme", "sizeBytes": 512110190592, "rotational": false, "healthSource": "nvme_logpage",
  "firstSeenAt": 1788400000, "lastSeenAt": 1788480000, "removedAt": null,
  "latest": { "at": 1788480000, "verdict": "ok", "predictFailure": false, "tempC": 41, "powerOnHours": 1200,
    "percentUsed": 3, "sparePct": 100, "spareThresholdPct": 10, "criticalWarning": 0, "reallocated": null } } ] }
```

`latest` is the newest `disk_sample` for the drive, every counter `null` when the column is
NULL. `healthSource` is one of `DISK_SOURCES` in `agent-ingest.ts` (`Source::as_str` in
`src/labdesk/disk/verdict.rs`), and a console renders `unreadable` as its own state, never as
healthy (plan section 8.2).

`GET /api/org/events?since=<unix>&machineId=`

```json
{ "events": [ { "id": "...", "machineId": "...", "ruleId": "...", "at": 1788480000, "kind": "rule_fired",
  "severity": "warn", "summary": "Disk nearly full", "detail": "{\"kind\":\"notify\",\"message\":\"...\"}",
  "acknowledgedBy": null, "acknowledgedAt": null } ] }
```

with `POST /api/org/events/:id/ack` (`machine:write`) setting the two acknowledgement columns.

What the Flutter console fetches instead of the PTY probe: `HealthBoard` loses `monitoredIds`,
`probingIds`, `onToggleMonitor`; `console_page.dart` polls `GET /console/org/machines?state=1`
on the same 15 s timer it already runs for labnets and fills `MachineHealth.remote` from the
state answer with a new `MetricSource.collector` replacing `MetricSource.remote`;
`MetricHistory` is filled from `GET /console/org/machines/:id/metrics` for the selected range.
`services/metrics_collector.dart`, `services/probe_reader.dart` and their two tests are deleted
in the commit that lands this (plan section 8.2, WP18). `terminal_screen.dart` and the tools
listing path keep the PTY. `machine_row.dart::MachineRow.status` comes from `status` in the
inventory answer for enrolled machines; the local reachability poll stays for peers the server
does not know.

## 6. The machine network view

### What exists

- `collector.rs::Sampler` refreshes `Networks` from the vendored sysinfo fork
  (`rustdesk-org/sysinfo`, branch `rlim_max`, `Cargo.lock`) and sums `total_received` and
  `total_transmitted` over every interface into the two trailing sample columns. That fork's
  `NetworkData` offers `name`, `mac_address`, `total_received`, `total_transmitted`
  (`src/common.rs` of the checkout under `~/.cargo/git/checkouts/sysinfo-7cea62a9ad7b4e33`)
  and has no `ip_networks`, so addresses and link state are not available from it.
- `Cargo.toml` declares no `Win32_NetworkManagement_IpHelper` feature.
- The ingest ignores an `inventory` member and an `attrs` member (`agent-ingest.ts`, the
  "deliberately NOT written" comment). `machine_attr` exists with `source`, `key` matching
  `[a-z0-9_.:-]{1,64}` and `value` at most 4 KiB, 64 keys per machine (`schema.ts`, `machineAttr`).
- `src/labdesk/selfheal.rs::probe_internet` answers `Connectivity::Online` when any of
  `1.1.1.1:443`, `8.8.8.8:443`, `9.9.9.9:443` accepts a TCP connect within 4 s, `Offline`
  otherwise, and runs only while `labdesk-selfheal` is `Y` (`start()`).
- The Flutter `network_screen.dart` renders labnets and invitations only; the `network` tool in
  `tool_catalog.dart` lists interfaces over the PTY.

### The contract

Storage without a new table: the collector sends `attrs` (plan section 4.4) and the ingest
upserts `machine_attr` rows with `source = 'agent'` only where the value changed (section 4.5).
The ingest half and the `attrs` member of `GET /api/org/machines/:id` landed in the site lane's
round 1 (`test/ingest.test.ts`, "attrs"); the collector half is the client lane's. Two keys
carry the network view:

- `net.adapters`, a JSON array, at most 4 KiB (the column bound), sent only when it changed:

```json
[ { "name": "eth0", "up": true, "mac": "aa:bb:cc:dd:ee:ff",
    "addresses": [ { "addr": "192.168.1.20", "prefix": 24, "family": "inet" }, { "addr": "fe80::1", "prefix": 64, "family": "inet6" } ],
    "rxBytes": 123456789, "txBytes": 23456789, "kind": "physical" } ]
```

  `up` is link state (`/sys/class/net/<if>/operstate == "up"` on Linux; `IfOperStatusUp` from
  `GetAdaptersAddresses` on Windows, which needs `Win32_NetworkManagement_IpHelper` added to the
  `windows` features the way WP10 added its two, as a no-op commit first; the `IFF_UP |
  IFF_RUNNING` flags from `getifaddrs` on macOS). `addresses` come from `getifaddrs` through
  `hbb_common`'s re-exported `libc` on Linux and macOS and from the same Windows call. Loopback
  is dropped, as the PTY tool drops it. `kind` is `physical`, `overlay` (the interface whose
  address is `overlay_device.overlay_ip`, named `labdesk-netbird` by `netbird_args` in
  `src/labdesk/labnet.rs`) or `other`. `rxBytes` and `txBytes` are the cumulative counters the
  sampler already reads; throughput is differenced by the console with any decrease read as a
  reset (the comment in `Sampler::sample`).
- `net.reachability`, a JSON object, sent on every change of verdict and at most once an hour
  otherwise:

```json
{ "internet": "online", "at": 1788480300, "probe": "tcp443", "selfheal": "off" }
```

  `internet` is `online`, `offline` or `unprobed`; `selfheal` is `off`, `watching`,
  `cycling`, `restarting` or `holdoff`, the `Step` the ladder last took (`selfheal.rs::Step`).
  When self-healing is off the collector calls `probe_internet` itself on the disk cadence
  (`DISK_INTERVAL`) so the verdict exists on every machine; when it is on, the healer's tick is
  the source. `unprobed` is the value before the first probe and is rendered as such.

Read: the two keys ride `GET /api/org/machines/:id` in a new `attrs` member (`{ key: { value,
source, updatedAt } }`, agent keys read-only in every console) and the per-adapter view in
both consoles is drawn from them. Ingest bound: `attrs` is at most 16 keys per uplink, each key
validated against the schema's pattern, each value at most 4 KiB, refused 400 otherwise, and the
64-key ceiling per machine is enforced by refusing the key, not the batch.

## 7. The self-heal switch

### What exists

- `src/labdesk/selfheal.rs`: `OPTION_ENABLE = "labdesk-selfheal"`, plus
  `labdesk-selfheal-probe-seconds`, `labdesk-selfheal-fail-threshold`,
  `labdesk-selfheal-max-restarts-per-day`, read with `Config::get_option` and clamped by
  `HealConfig::from_options`. `start()` returns at once unless the option is `Y`; `run()`
  re-reads the option every tick and returns when it is no longer `Y`. Started from
  `start_os_service` on all three platforms (`src/platform/{linux,windows,macos}.rs`).
- The option is a `Config2` option (`Config::get_option` reads `CONFIG2` in
  `libs/hbb_common/src/config.rs`). `CONFIG2` is a `lazy_static` loaded once per process
  (`Config2::load`); nothing re-reads the file. `Config2::set` (called by the `SyncConfig`
  handler in `src/ipc.rs`) replaces the in-memory copy and stores it.
- How a console sets an option: `bind.mainSetOption` reaches `ui_interface::set_option`, which
  sends `Data::Options(Some(map))` over the main IPC channel `""` served by `--server`
  (`src/server.rs`, `crate::ipc::start("")`), whose handler calls `Config::set_options`
  (`src/ipc.rs`, the `Data::Options` arm). On Linux and macOS `--server` then syncs its config to
  the root daemon over `_service` every `CONFIG_SYNC_INTERVAL_SECS` (`src/server.rs`, the
  `SyncConfig(Some(cfg))` send), and the daemon's `Config2::set` updates the memory
  `selfheal::run` reads. On Windows `--server` and `--service` are two LocalSystem processes
  reading the same file; `--service` loaded `CONFIG2` at start and never re-reads it, so a switch
  flipped from the console does not reach a running Windows daemon until the service restarts.
  This is a verified gap (`Config::get_option` versus `Config2::load`), not a supposition.
- No Flutter surface sets any `labdesk-selfheal*` option (`grep -rn selfheal flutter/lib` is
  empty).

### The contract

- The switch is the option `labdesk-selfheal` with value `Y` or absent; the three tuning options
  keep their names and clamps. The console sets it through `bind.mainSetOption`, the path above,
  and nothing else; there is no new IPC variant for it.
- The daemon reads the switch from the FILE, not from its process memory: `selfheal::run`
  replaces `Config::get_option(OPTION_ENABLE)` at the top of each tick with a read of
  `Config2::load().options` (a fresh parse of the daemon's own config file), and `start()` is
  changed to spawn the thread always and let `run()` idle on the same check while the option is
  off. Then a switch flipped on either platform takes effect within one probe interval and a
  daemon that was started with it off still honours it. The unit test asserts the ladder is
  untouched (`HealState::advance` is pure) and that `run()`'s gate reads a value written by
  another handle to the file.
- The running value, not the file, is what the consoles show: the daemon reports
  `net.reachability.selfheal` (section 6) on every change, and the console's switch renders that
  value beside the toggle, with "waiting for the service" between a flip and the first report.
  Flutter: a row on `screens/this_machine_screen.dart` next to the labnet card, backed by the
  option and the attr. Web: the machine page's network section.
- Field proof for the piece: on homebox, flip on from the console, then
  `journalctl -u rustdesk | grep '\[selfheal\]'` shows `watching connectivity`; flip off, shows
  `turned off`. On Foundry the same two lines in `C:\Windows\ServiceProfiles\LocalService`'s
  LabDesk log, which is the proof the Windows gap above is closed.

## 8. Technician presets for automation

### What exists

- Rules are the Flutter `Rule` (`flutter/lib/labdesk/models/automation_models.dart::Rule.toJson`):
  `{ id, name, enabled, trigger, action, targets, cooldownSeconds }`, stored locally under
  `labdesk-automation` (`console_page.dart::_kRulesKey`). Triggers: `cameOnline`, `wentOffline`,
  `metricAbove`, `uptimeAbove`, `schedule`. Actions: `runCommand`, `notify`, `wakeOnLan`,
  `monitorOn`, `openSession`.
- Server side, `health_rule` (`schema.ts`, `healthRule`): `trigger` and `action` JSON, byte
  identical to the Dart `toJson`, `target_kind` `org | fleet | machines`, `target_fleet_id`,
  `target_machines`, `cooldown_s`. `src/worker/health-engine.ts` parses the five Dart triggers
  plus `diskSpaceAbove { pct }` and `diskHealthBelow { verdict }`, drops `monitorOn`,
  `openSession` and `runCommand` (`droppedActions`), and passes `notify`, `wakeOnLan` and
  `runTool` through as opaque action JSON.
- There is no `/api/org/rules` route yet (`src/worker/routes/org.ts` has none; the plan's
  `routes/rules.ts` does not exist) and no preset anywhere in either repository
  (`grep -rn preset flutter/lib src/worker` is empty).

### The contract

A preset is a `health_rule` row template. Its JSON is the row's own columns so that applying a
preset is one `POST`:

```json
{ "preset": "disk_failing", "name": "A drive is failing", "trigger": { "kind": "diskHealthBelow", "verdict": "failing" },
  "action": { "kind": "notify", "message": "A drive on this machine reports failing" },
  "targetKind": "org", "targetFleetId": null, "targetMachines": [], "cooldownS": 3600 }
```

Routes, `src/worker/routes/rules.ts`, mounted like `org.ts` under both prefixes:
`GET /api/org/rules` (`read`), `POST /api/org/rules` (`rule:write`; `targetKind: "org"` is
`org:admin`, plan section 2 row 6), `PATCH /api/org/rules/:id` (same), `DELETE /api/org/rules/:id`,
`GET /api/org/rules/presets` (`read`, the list below, served from a constant in `rules.ts`),
`POST /api/org/rules/presets/:preset` (`rule:write`, body `{ targetKind, targetFleetId?,
targetMachines? }`, writes the row and answers it). The Flutter `automation_screen.dart` becomes
the editor over these routes, and its local `labdesk-automation` option and the
`automation_engine.dart` tick are deleted in the same commit (plan section 6.3, the double-fire
rule).

The first five presets, using only triggers and actions the engine already parses and tools
from section 1:

| preset | trigger | action | cooldownS |
|---|---|---|---|
| `disk_failing` | `diskHealthBelow` verdict `failing` | `notify` "A drive on this machine reports failing" | 3600 |
| `disk_nearly_full` | `diskSpaceAbove` pct 90 | `notify` "The fullest filesystem is over 90 percent" | 3600 |
| `offline_ten_minutes` | `wentOffline` forMinutes 10 | `notify` "Offline for ten minutes" | 600 |
| `memory_high` | `metricAbove` metric `memory` threshold 90 forMinutes 15 | `notify` "Memory above 90 percent for fifteen minutes" | 1800 |
| `back_online_flush_dns` | `cameOnline` | `runTool` toolId `flush_dns` params `{}` | 600 |

`back_online_flush_dns` names a `system` tool, so each firing writes a `pending` job an owner
approves (section 2). The preset's description says so; it is the plan's rule and a preset does
not bend it.

## 9. labnet stage 2: the routes as they exist today, and what is missing

### What exists

Human plane, `src/worker/routes/overlay.ts`, every route through `actor()`:

| Route | Need | Notes |
|---|---|---|
| `GET /overlay/labnets` | `read` | `{ labnets: [{ id, name, fullAccess, fleetId, members: [{ machineId, status, overlayIp }] }] }`, narrowed twice (`narrowed()`, `labnetMembers(db, id, a.fleetIds)`). |
| `POST /overlay/labnets` | `rule:write` | `{ name, fleetId? }`; a narrowed caller of several fleets must name one (400); `LABNET_MAX` 50 per org; `tooOften(..., "labnet", 10)`. Answers `{ id, name, fullAccess, fleetId }`. |
| `PATCH /overlay/labnets/:id` | `rule:write`, `FRESH_SECONDS` when `fullAccess: true` | `{ name?, fullAccess? }`; refused 403 by `holdsOutsider()` when a narrowed caller would open full access over a machine outside their fleets. |
| `DELETE /overlay/labnets/:id` | `rule:write`, `FRESH_SECONDS` | NetBird policy and group first, row last. |
| `POST /overlay/labnets/:id/invite` | `rule:write`, target `{ machineId: body.machine }` | 409 when the machine is not on labnet or already approved; writes `labnet_member` `pending`. |
| `DELETE /overlay/labnets/:id/members/:machineId` | `rule:write`, target the machine | `removed`, then `syncLabnetGroup`. |
| `POST /overlay/session`, `GET /overlay/sessions`, `DELETE /overlay/session/:id` | `session:open` / `read` / `session:open` | Section 3 above. |

Machine plane, `src/worker/routes/agent-overlay.ts`: `POST /agent/overlay/enrol`,
`POST /agent/overlay/self`, `DELETE /agent/overlay/enrol`, `GET /agent/overlay/inbox`
(`{ device: { enrolled, overlayIp }, invitations: [{ labnetId, name, invitedBy }], labnets:
[{ id, name, fullAccess, members }] }`), `POST /agent/overlay/invites/:labnetId/decide`
(`{ approve }`, answers `{ ok, status }` with `approved` or `declined`),
`POST /agent/overlay/labnets/:id/leave`.

Client, `flutter/lib/labdesk/services/overlay_broker.dart`: `inbox()` merges
`GET /agent/overlay/inbox` and `GET /console/overlay/labnets`; `createLabnet(name)` posts
`{ name }` only; `setFullAccess`, `deleteLabnet`, `invite(labnetId, machineId)`, `decide`,
`leave`, `removeMember`, `machines()` (`GET /console/org/machines`) all exist and are wired in
`console_page.dart` (the `onCreate` ... `onDelete` callbacks at the `NetworkScreen` construction).
`models/labnet.dart::LabnetInbox.fromJson` reads `owner` and `members[].deviceId`.
`test/labdesk_overlay_broker_test.dart` asserts no human-plane call targets `/api/`.

Web, `src/app/pages/org.tsx`: machines, fleets, enrolment token. No labnet surface.

### What is missing, verified

1. Full access from the desktop cannot be turned on after five minutes of sign-in. `actor()`
   takes `signedInAt` from `r.token.createdAt` for an app bearer (`principal()` in
   `src/worker/org.ts`), so `PATCH /console/overlay/labnets/:id { fullAccess: true }` with
   `FRESH_SECONDS` answers 403 "Sign in again to confirm this change." to any console token
   older than 300 s, and the console has no re-sign-in step that mints a fresh token. The same
   applies to `DELETE /console/overlay/labnets/:id`, `POST /console/org/enrol-token` and
   `POST /console/org/fleets`. Contract: the console, on that 403, asks for the password once
   and calls `POST /api/login` again to hold a fresh token, then retries; the Worker is not
   loosened. `test/console.test.ts` holds the case since the site lane's round 1 (all four
   routes answer 403 "Sign in again to confirm this change." on a token aged past 300 s).
2. `createLabnet` sends no `fleetId`, so a narrowed technician of several fleets is answered 400
   "Name the fleet this labnet belongs to." with no way to name one. Contract: the create form
   offers the fleets from `GET /console/org/fleets` when the caller's `GET /console/org`
   answers `fleetIds` non-null with more than one entry; `LabnetInbox` carries `fleetId`.
3. Rename is a server capability (`PATCH { name }`) with no client surface. Contract: a rename
   action on the labnet card.
4. The web console has no labnet page. Contract: `/org` gains a labnets section using the same
   seven routes under `/api`, with the machine picker from `GET /api/org/machines?state=1`
   (section 5) showing reachability beside each candidate.
5. `members[].deviceId` in the client model is `machine.id` on the wire (`labnetMembers` answers
   `machineId`; the broker maps it). The client shows raw ids where the server's
   `GET /console/org/machines` could name them; contract: the card resolves ids to
   `displayName` or `hostname` from the machines list it already fetches.
6. Approval on the machine is proven only by unit test. The field check for the piece is one
   invitation from a signed-in console, approved on the invited machine's own Network section,
   with `labnet_member.status` read back as `approved` in D1 and the NetBird group listing both
   peers; the standing facts say no production account exists for the program, so that proof is
   against the local `wrangler dev` stack and `test/fakes/netbird-worker.mjs` unless the owner
   mints a token.

## 10. What every lane verifies before calling a contract met

- Site: `npx tsc --noEmit` clean; `npm test` green; the new files named above exist at the
  paths named; `test/jobs.test.ts`, `test/ticket.test.ts`, `test/console-api.test.ts`,
  `test/rules.test.ts` exist and pass; the git blob of `src/worker/tools.json` equals the client's
  blob of `src/labdesk/tools.json` (section 12 correction 4 says why `cmp` between two Windows
  working trees is not that check).
- Client: the CI run id on the exact head for `cargo test` (`labdesk::tools`, `claim_once`,
  `labdesk::selfheal`); `flutter test test/labdesk_*.dart` then `git checkout flutter/pubspec.lock`;
  `git ls-files --error-unmatch src/labdesk/tools.json`.
- Both: `docs/CONSOLE.md`, the site README route table and this file updated in the same
  commit as the change they describe; the architecture plan's corrections block gains an entry
  for the two corrections recorded here (a fleet book's guid is its fleet id, section 4; the
  Windows daemon does not re-read its config, section 7).

## 11. Corrections from the client lane, round 1

Read from the code as built in `src/labdesk/{tools,ticket,netview,selfheal}.rs`; each is a
place the contract above left something open or the code had to diverge, and the site lane
builds against these.

1. Section 1, `pattern`. The agent carries no regex engine (`regex` is not a dependency of the
   crate and `--locked` CI cannot take one). The one shape a `pattern` may have is
   `^[class]{min,max}$`, the class being single characters, `a-z` ranges and `\-` escapes;
   `Catalog::parse` refuses any other pattern, so a catalog author learns at test time.
2. Section 1, values. A parameter value that begins with `-` is refused `bad_params` whatever
   its type, because every step hands the value to a program's option parser and the contract's
   class admits `--force` as a unit name. The Worker may accept such a job; the agent's result
   then says `bad_params`.
3. Section 1, `power_logoff` on Linux. The entry's argv is `["loginctl", "terminate-user"]` in
   both copies of `tools.json` (the Worker's bytes, adopted by the client in this round), and
   the agent appends `get_active_username()` to that one entry on that one platform, refusing
   `no_active_user` when nobody is on seat0. The rule is keyed on the tool id in
   `tools.rs::argv_for`, not on a token, so the shared file carries nothing the Worker's
   catalog check would refuse.
4. Section 2, `active_user` on Linux. `loginctl terminate-user` and `loginctl lock-sessions`
   are refused by polkit to anyone but root, so on Linux the daemon runs both entries itself
   with the seat0 user filled in; `run_as_user` serves Windows and macOS, as `labdesk
   --labdesk-tool <id>`, which is why an `active_user` entry takes no parameters (the command
   line carries the id only). On Windows that launch hands back no handle, so the result is
   `exitCode 0` with an output line saying the exit status was not observed.
5. Section 2, results. `jobResults` carries at most four results a batch, oldest first, and
   when the body is over 64 KiB the optional members give way in this order: `disks`, then
   `attrs`, then results from the newest down; samples never.
6. Section 3, delivery. The daemon computes `H` from the delivered `secret` as follows: a value
   that is already 64 hex characters is `H`; anything else is hashed (`sha256Hex` over the
   string's bytes). So the Worker may deliver either the hash or the plaintext and the target
   holds `H` either way. The console stores the plaintext it was handed at mint time, and
   `handle_hash` hashes it once and clears the option `labdesk-ticket-<peer id>` so the ticket
   is tried exactly once.
7. Section 6, `net.adapters`. Sent when anything but `rxBytes` and `txBytes` changed, and once
   an hour otherwise, so the counters refresh hourly and the attribute write stays near one row
   an hour per machine (section 4.5 of the architecture). The console differences throughput
   from the batch samples, not from this attribute. Windows sends the attribute from
   `GetAdaptersAddresses`. Two corrections to section 6, both read from windows-0.61.1 rather
   than recalled: the call and `IP_ADAPTER_ADDRESSES_LH` are both written
   `#[cfg(all(feature = "Win32_NetworkManagement_Ndis", feature = "Win32_Networking_WinSock"))]`
   (`IpHelper/mod.rs` lines 286 and 1796), so `Win32_NetworkManagement_IpHelper` alone compiles
   to nothing callable and all three features are declared; and the adapter's `name` on Windows
   is its `FriendlyName`, not its `AdapterName`, because the sampler's `Networks` is keyed by
   `MIB_IF_ROW2.Alias` (the sysinfo fork's `src/windows/network.rs`) and the GUID would key
   every adapter away from its byte counters. `kind` on Windows is read from `IfType`, which is
   what an adapter presents as rather than what is behind it, so a Hyper-V or WSL virtual switch
   reads `physical`; the console shows `kind` beside the name, which says which it is.
8. Section 6, `net.reachability`. Sent on a change of `internet` or `selfheal` and once an hour
   otherwise; `at` alone is not a change.
9. Section 7. `selfheal::enabled()` parses the daemon's config file on every tick;
   `net.reachability.selfheal` is the running step and `off` while the switch is off.
10. `labdesk --disk-health` (root or administrator) prints the `disks` member the daemon would
    send, for field checks on any machine.
11. Section 3, the report. `POST /agent/ticket/:id/claimed` is sent by the daemon and never by
    `--server`: the claim happens in the process that answers logins, and that process holds no
    agent key. `--server` keeps the claimed ids and the daemon asks for them over the main
    channel (`Data::ClaimedTickets`, answered from `crate::server::take_claimed_tickets`, which
    hands each id over exactly once). The daemon asks every 5 s while a ticket it delivered is
    still live rather than on the flush cadence, because a ticket lives 120 s, the default flush
    is 300 s and the route answers 410 past `expiresAt`. An id that comes back is checked against
    `ticket::is_ticket_id` before it reaches a URL path: on Linux and macOS it crosses from a
    process running as the logged-in user.

## 12. Built and not built, at client `d572566815` and site `fb3c14e`

Read from the code at those two heads on 2026-09-05, not recalled. A section named here is
otherwise unchanged above; where the code and the contract disagree, the correction is written
out and the code wins.

### Built

| Contract | Client | Site |
|---|---|---|
| 1, the catalog | `src/labdesk/tools.json` compiled by `src/labdesk/tools.rs` (`Catalog::parse`, `Tool`, `CharClass`, `argv_for`, `run_steps`, `execute`, `Ledger`, `run_here`, `platform`) | `src/worker/tools.json` read by `src/worker/tool-catalog.ts` (`checkCatalog`, `TOOLS`, `checkParams`, `initialState`, `PARAMS_MAX_BYTES`, `JOB_TTL_SECONDS`), asserted by `test/jobs.test.ts` |
| 2, jobs and results | `tools.rs::jobs_in`, `JobResult::to_json`, `Ledger` (the executed ids on disk), driven from `src/labdesk/collector.rs` | `src/worker/routes/jobs.ts` (request, approve, refuse, list, one row), the `jobs`, `tickets` and `collectNow` members of the `/agent/batch` answer and the `jobResults` and `attrs` readers in `src/worker/routes/agent-ingest.ts`, `drizzle/0011_job_urgent.sql`, the `runTool` firing and the expiry sweep in `src/worker/scheduled.ts` (`minuteTick`) |
| 3, connect ticket | `src/labdesk/ticket.rs` (`Ticket`, `tickets_in`, `secret_hash`), `Data::ConnectTicket` in `src/ipc.rs` handed to `crate::server::insert_pending_ticket`, the claim-once store `PENDING_TICKETS` in `src/server/connection.rs` (`PendingTicket`, `insert_pending_ticket`, `claim_pending_ticket`, `retain_live_tickets`), claimed at the login check by `claim_pending_ticket(&self.lr.my_id, |h| self.validate_password_plain(h))`, and the `handle_hash` branch in `src/client.rs` behind `PasswordSource::Ticket`, fed by the console writer `kOverlayTicketOption` in `flutter/lib/labdesk/services/overlay_session.dart`, which sets `labdesk-ticket-<peer id>` from `grant.ticket` beside the two overlay options and clears all three on close (`flutter/test/labdesk_overlay_session_test.dart`) | the mint in `src/worker/routes/overlay.ts`, the delivery select in `agent-ingest.ts`, `POST /agent/ticket/:id/claimed` in `src/worker/routes/ticket.ts`, `test/ticket.test.ts`; the daemon reports the claim with `ticket::claimed` over `Data::ClaimedTickets` and `collector::report_claimed_tickets` posting `POST /agent/ticket/:id/claimed` |
| 4, the writer the projection needs | -- | `PATCH /api/org/machines/:id` in `src/worker/routes/org.ts` with `test/console-api.test.ts` |
| 5, console read routes | -- | `GET /org/machines/:id/state`, `/metrics`, `/disks`, `GET /org/events`, `POST /org/events/:id/ack` and `GET /org/machines?state=1` in `src/worker/routes/org.ts` |
| 6, network view | `src/labdesk/netview.rs` (`Adapter`, `Address`, `collect`, `to_value`, `counters`, `adapters`, `windows_kind`, a `walk` per platform) | the `attrs` upsert in `agent-ingest.ts` and the `attrs` member of `GET /api/org/machines/:id` |
| 7, the daemon half of the switch | `selfheal::enabled` and `enabled_in` parse the daemon's config file on every tick, which closes the Windows gap section 7 recorded | -- |

`labdesk --disk-health` prints the `disks` member for a field check (section 11 item 10).

### Not built at these heads

- Section 5, the client half (WP18): `flutter/lib/labdesk/services/metrics_collector.dart` and
  `probe_reader.dart` are still present and `console_page.dart` still probes over the PTY.
  *Closed by the client lane's Flutter console round; see section 13.*
- Section 7, both console surfaces: `grep -rn selfheal flutter/lib` and the same over the site's
  `src/` are empty, so no console can set or show the switch yet. *The Flutter half is closed;
  see section 13.*
- Section 8: there is no `src/worker/routes/rules.ts`, no `test/rules.test.ts`, and `preset`
  appears nowhere in either repository.
- Section 9 items 1 to 6, and the WP17 web pages: `src/app/pages/` holds `account`, `admin`,
  `auth`, `download` and `org` only. *Items 1, 2, 3 and 5 are closed on the desktop; see
  section 13.*

### Corrections to the contract above, from the code as built

1. Section 2, expiry. `minuteTick` (`src/worker/scheduled.ts`) moves `pending`, `approved` AND
   `dispatched` rows past `expiresAt` to `expired`. The contract named the last two only; a
   pending row nobody approved inside its hour has to expire as well or it sits for ever.
2. Section 2, the list route. `GET /api/org/jobs` answers at most 500 rows, newest first
   (`src/worker/routes/jobs.ts`). The contract fixed no bound.
3. Section 2, the dispatch answer. The Worker parses `params` back to an object and strips
   `urgent` from each job it hands out (`agent-ingest.ts`), so the agent reads the shape section 2
   prints and never the requester's urgency flag; `collectNow` is the only thing urgency becomes
   on the wire.
4. Section 1 and section 10, the byte-for-byte check. The two copies of `tools.json` are the same
   git blob (`652f3923addf13646b88498dbf00beaa2e22ac25` at both heads), but the client repository
   pins its copy to LF (`.gitattributes`, `src/labdesk/tools.json text eol=lf`) while the site
   repository has no `.gitattributes` and `core.autocrlf` is true on a Windows checkout, so the
   site's working copy is CRLF and `cmp` between the two working trees fails on a difference that
   is not in either repository. The verifier is therefore the blob:
   `git -C LabDesk rev-parse HEAD:src/labdesk/tools.json` equal to
   `git -C labdesk-site rev-parse HEAD:src/worker/tools.json`. A site lane that would rather keep
   `cmp` adds the same one line to a site `.gitattributes`.

5. Section 3, the claim-once store. The contract said a map keyed by `controller_peer_id`. As
   built it is `PENDING_TICKETS` in `src/server/connection.rs`, a `Vec<PendingTicket>` swept by
   `retain_live_tickets`, so one peer id can hold several live tickets at once and
   `claim_pending_ticket(controller_peer_id, matches)` claims the first unclaimed one whose `H`
   satisfies the caller's own password check; `insert_pending_ticket` refuses a repeated ticket
   id. A claimed row is kept until `expires_at`, which is what makes a replay fail rather than
   mint a second claim. The test is
   `test_pending_ticket_claim_once_per_ticket_never_for_another_peer`, a second test beside
   `test_pending_switch_sides_uuid_is_claimed_once` rather than an extension of it; the filter
   `cargo test claim_once` that section 10 names matches it.

6. Section 3, delivery timing. Open, and the site lane's to close: `connect_ticket.expires_at` is
   `issued_at + 120` while `machine.flush_seconds` defaults to 300, so the batch that would carry
   a ticket usually runs after the row has expired and the delivery select (`claimedAt` NULL,
   `expiresAt` in the future) finds nothing. Nothing on the machine plane can wake an agent:
   `collectNow` rides an answer and the answer only comes with the next batch. Until the ticket
   lives as long as a flush, or opening a session shortens the target's flush the way `urgent`
   shortens it for a job, a session over labnet falls back to the shared password path, which
   phase 1 keeps (plan section 0.3). This is why the client half of section 3 is proven by unit
   test and not in the field.

## 13. The Flutter console, WP18: what the client lane built and where it had to differ

Read from the code at the head this section landed on, not recalled.

### Built

| Contract | Where |
|---|---|
| 5, the client half | `flutter/lib/labdesk/models/machine_state.dart` (`MachineState`, `parseMetricHistory`), read by `services/overlay_broker.dart` (`machines()` on `?state=1`, `machineState`, `metrics`) and rendered by `models/console_rpc.dart::buildMachineHealth` and `screens/health_board.dart`. `services/metrics_collector.dart`, `services/probe_reader.dart`, their two tests, `LabDeskTerminalRpc.probe`/`probeOn` and the window method `labdesk_probe` are deleted in the same commit. `MetricSource.remote` is now `MetricSource.collector`. |
| 5, reachability | `console_data.dart::buildMachineRows` takes `serverStatusOf`, so an enrolled machine's dot is the Worker's `status` and every other peer keeps the client's own poll. |
| 6, the console half | `models/net_view.dart` (`MachineNetView.fromAttrs`, `NetAdapter`, `NetReachability`) and `screens/adapters_card.dart`, at the top of the Network section with a machine picker. |
| 7, the Flutter surface | `screens/selfheal_card.dart` on This machine, setting `labdesk-selfheal` through `bind.mainSetOption` and rendering `net.reachability.selfheal`, with "waiting for the service" between a flip and the first report. |
| 9 items 1, 2, 3, 5 | The fresh-token retry in `console_page.dart::_labnetDo` (on `needsFreshSignIn` it shows the client's own `loginDialog()` and retries the same call); `createLabnet(name, fleetId:)` with the fleet picker the create form offers a caller narrowed to more than one fleet; `renameLabnet`; and member ids already resolved to names by `NetworkScreen._nameOf`. |

### Where it differs from the contract, and why

1. Section 5, uptime. `GET /org/machines?state=1` answers `status`, `seenAt`, `cpuPct`,
   `memPct`, `fsWorstPct`, `worstDisk` and the machine columns, and no `uptimeS` or
   `loggedInUser` (`src/worker/routes/org.ts`, the `hot` projection). The health card wants both.
   Rather than call `/state` per machine per poll, which is the N+1 the plan rules out, the
   console asks ONE machine a poll for its own hot row, round robin, and merges what only that
   answer carries. Uptime on a card is therefore up to `machines * 15 s` old, which for a figure
   that only climbs is not a lie.
2. Section 5, history. The console backfills each machine once from
   `GET /org/machines/:id/metrics` over the last twelve hours, on the same round robin, and adds
   one sample per uplink from the fleet poll after that, keyed on `seenAt` so a fifteen-second
   poll does not record one five-minute flush twenty times.
3. Section 8, the presets. `src/worker/routes/rules.ts` carries `GET /org/rules` and the enabled
   switch only: there is no create, no delete and no `/org/rules/presets` route, so an editor
   over those routes could not work. The Automation section therefore keeps its local rule store
   and its own tick, and the presets are ready-made LOCAL rules
   (`flutter/lib/labdesk/models/automation_presets.dart`). Four of them are the contract's own,
   in the console's vocabulary; `disk_failing` is absent because `diskHealthBelow` is a trigger
   only the Worker's engine has, and a preset that could never fire is worse than an absent one;
   `cpu_pegged` is added because the same shape is the one technicians ask for next. When the
   create, delete and preset routes land, the editor moves to the organization's rules and the
   local store goes with it.
4. The `monitorOn` action is deleted from `automation_models.dart` with the monitoring it turned
   on. A rule stored with it is dropped on load and the rest of the list survives
   (`decodeRules` already drops an entry it cannot parse), which is the right outcome: it named a
   thing that no longer exists, and the rules are a local option on one machine.
