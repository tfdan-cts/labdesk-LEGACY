# Labnet recovery

Recovery must restore a consistent relationship between the NetBird control plane and the
LabDesk broker's D1 database. A boot-volume backup marked `AVAILABLE` proves a restore point
exists; it does not prove the database opens, the service starts, or old access is safely revoked.

No cloud restoration or production change was performed for this runbook. The executable below
proves an offline fixture contract only. Use [LABNET-SERVER.md](LABNET-SERVER.md) for current
deployment and administrative access, and [LABNET-OPERATIONS.md](LABNET-OPERATIONS.md) for readiness.

## Recovery objectives and current evidence

| Item | Evidence or required decision |
| --- | --- |
| Required recovery point objective (RPO) | **Unresolved:** the operations owner must specify the maximum acceptable loss of committed state. |
| Required recovery time objective (RTO) | **Unresolved:** the operations owner must specify the maximum time from incident declaration to validated service availability. |
| OCI restore points | Independent read-only audit, 2026-09-07 01:45–01:52 UTC: initial FULL created 2026-09-04 02:23:57 UTC and INCREMENTAL created 2026-09-06 04:00:32 UTC, both `AVAILABLE`. |
| Scheduled coverage | `labnet-weekly-keep3`, Sunday 04:00 UTC, retained 21 days. Nearly seven days can pass between scheduled restore points; additional time is possible after a failed backup. Retention is not the RPO. |
| Coordinated D1/NetBird checkpoint | No matching recovery pair or completed coordinated capture was established by the audit. |
| Actual restoration and RTO | **Unproven:** no isolated OCI restoration, real NetBird startup, D1 restoration, or timed product acceptance run. |
| Production data at audit time | NetBird: zero peers and policies. D1: one machine, zero overlay devices/sessions. Empty production enrollment cannot exercise identity recovery. |

Do not infer a seven-day *accepted* RPO from the current schedule. Set the objectives before
approving a cadence change or declaring recovery readiness. An old OCI snapshot paired with a
new D1 database can recreate stale permissions or strand a machine, even when both databases pass
their own integrity checks.

## Safe rehearsal available now

From the LabDesk repository root with Python 3.10 or later:

```powershell
python -B -m unittest discover -s deploy/operations -p test_restore_rehearsal.py -v
python -B deploy/operations/restore_rehearsal.py --fixture
```

The CLI requires `--fixture`. It takes no credentials, archive, source, network target, or output
directory. It creates synthetic backup files, restores into another unique temporary directory,
reads the restored data, and removes its own temporary files. It does not invoke a shell, cloud
SDK, container runtime, network socket, service, or production command. Database handles are
explicitly closed before cleanup, including on Windows.

The fixture contains a reduced broker SQLite schema, normalized NetBird JSON inventory, a
configuration document, certificate/MaxMind **sentinels**, and a tiny geonames SQLite database.
These are not real NetBird database formats, valid certificates, or a complete D1 schema. The
contract checks:

- SHA-256 before copying and after reading each of the six restored files.
- SQLite `integrity_check`, `foreign_key_check`, and application-shaped read queries.
- Matching coordinated checkpoint; machine/device UUID and organization; peer key, IP, and
  per-device group; no missing or duplicate identity; no orphan peer.
- Closed sessions and no remaining policies. Restored authorization needs reconciliation.
- Configuration/certificate fingerprint binding and the local geolocation-file prerequisite.
- Fixed filenames only, bounded regular-file reads, and rejection of unexpected files,
  traversal names in manifests, hardlinks, symlinks, and Windows reparse points. No archive is
  extracted. Checksums detect damage; a manifest stored alongside data is not authenticity proof.

Success is `status: fixture_pass`; `production_restore_proven` and `service_start_proven` remain
`false`. `fixture_elapsed_seconds` measures the local fixture run. `rpo_seconds` and `rto_seconds`
remain `null`. The script deliberately cannot convert unavailable production prerequisites into
a passing production result. A real service-start and two-machine transport test remains required.

## The coordinated recovery set

Capture these together during an approved quiescent interval. Preserve sensitive files in the
existing protected backup/evidence location, with restricted access and encryption; never place
them, their contents, exports, private keys, passwords, or tokens in this repository or logs.

| State | Contents that must travel together |
| --- | --- |
| Oracle/NetBird | Selected boot-volume backup identity and completion status, attached-volume inventory, application capture start/end UTC times, and the complete actual NetBird state mount. Preserve SQLite WAL/journal sidecars when present; a live file copy of a SQLite main file alone is not a consistent backup. |
| Configuration | Compose file, `config.yaml`, `dashboard.env`, Traefik file-provider routes, pinned image digests, mount mapping, file ownership/modes, and relevant persisted host/service/firewall configuration. Record secret references separately and keep actual secrets protected. |
| Certificates and keys | Complete Traefik ACME/certificate volume and control-plane identity/key material. Restoring only a database while losing identity keys is not a valid restore. Do not allow a drill to renew certificates or use production service credentials. |
| Geolocation | Local `GeoLite2-City_*.mmdb` and `geonames_*.db` in the state volume. `disableGeoliteUpdate: true` is required by current blocked server egress. Losing these files can prevent startup. |
| D1/broker | Full schema and data, applied migrations, exact Worker source/build/version and compatibility, active deployment/binding identifiers, a same-window Time Travel bookmark where supported, and credential-version references. Record machines, device UUIDs/keys, memberships, policies, enrollments, and sessions for reconciliation. |
| Evidence | A checkpoint identifier, UTC timestamps, source resource identifiers, file SHA-256 values, tool versions, and the protected location of the manifest. Preserve a trusted manifest separately from the copied data. |

The actual mount names and database engine must be read back before capture. Do not assume a
generic `store.db` filename, a JSON export, or the fixture schema represents production storage.
The 2026-09-07 audit verified NetBird state writable and configuration read-only, with Traefik's
certificate volume writable. It did not enumerate or restore every state file.

## Coordinated capture procedure — approval required

1. Resolve the exact production VM, volumes, Worker and D1 identifiers, the accepted RPO/RTO,
   protected evidence destination, maintenance window, and responsible recovery operator.
2. Preserve the existing Homebox Tailscale administrative route. Do not disable its tailnet,
   change DNS/firewalls, or rely on LabDesk itself as the only means of reaching a failed server.
3. During the approved window, stop new enrollment/session requests and all writers, including
   scheduled sweeps/jobs, user/admin changes and NetBird management writes. Drain in-flight work.
   Use a reviewed maintenance mechanism; no global write-freeze switch was verified by this work.
   If a service stop is needed for consistency, obtain that authorization first.
4. Record quiescence start UTC. Capture the complete state with the deployed engine's supported
   consistency mechanism or from stopped services, plus the config/certificate/geolocation files.
   Capture the Oracle backup/volume checkpoint and D1 export/bookmark while writers stay frozen.
   An ordinary crash-consistent OCI backup alone does not establish application consistency.
5. Verify copy checksums, read-only database integrity and migration compatibility. Record
   quiescence end UTC, the exact paired artifacts, and whether every writer was actually stopped.
   If a writer escaped the freeze, mark the pair inconsistent and repeat only after the cause is
   resolved. Two timestamps near each other are not evidence of a consistent pair.
6. Resume only through the approved maintenance procedure. Check readiness and record any lost
   or deferred operations. No step in this document has been executed against production.

## D1 operations and their limits

Use the repository's installed Wrangler, with its verified account/configuration and credentials
kept inside the process. These commands inspect backend support and the current bookmark:

```powershell
npx --no-install wrangler d1 info labdesk-site
npx --no-install wrangler d1 time-travel info labdesk-site
```

Time Travel on the production storage backend restores **in place**, cancelling in-flight
queries. It cannot clone a database into an isolated target. Verify the account's actual retention
window and bookmark availability: documented retention is seven days on Free and thirty on Paid.
Record a current rollback bookmark before an authorized recovery; keep the prior bookmark returned
by restoration. A bookmark alone does not back up NetBird. [Cloudflare Time Travel documentation,
checked 2026-09-07](https://developers.cloudflare.com/d1/reference/time-travel/).

For an isolated copy, export SQL during the approved capture window, then import into an
**already approved, empty, dedicated recovery database**, using its exact identifier and a
separate Wrangler configuration without production bindings. Export blocks other database
requests while running, so do not treat it as a zero-impact probe. Inspect export limitations
first; do not delete virtual tables to make an export work. D1 imports SQL, not a raw SQLite
file. [Cloudflare import/export documentation, checked 2026-09-07](https://developers.cloudflare.com/d1/best-practices/import-export-data/).

After resolving the protected output path, scratch database identity and scratch config, the
operator can use the installed Wrangler's `d1 export ... --remote --output=...` and
`d1 execute ... --remote --file=... --config=...` forms. This runbook intentionally supplies no
production `time-travel restore` invocation: approving a cloud drill does not approve replacing
the live database. Recovering an old bookmark without a matching saved export requires a separate
reviewed plan; do not restore production just to obtain an isolated historical copy.

## Isolated real restore procedure — still pending

1. **Authorize and identify the target first.** A dedicated scratch OCI target/storage and an
   empty scratch D1 database must already exist or have explicit resource/cost approval. Record
   exact IDs, ownership, quota and cleanup limits. Neither target may be production or shared
   with another task. No such target was allocated or accepted by this work.
2. **Fence before starting.** Attach the restored volume for offline read-only inspection before
   booting a cloned OS. Prove that the target cannot route to the production subnet, production
   control plane, Worker or public clients, or expose copied management services. No public DNS,
   public ingress, certificate renewal, enrollment, cloud-agent startup, or production credentials
   may operate from the clone. Use a separately approved administration path. Do not boot a
   production image and plan to fix its network afterward.
3. Restore the selected OCI recovery point and record the provider result, target volume identity,
   start/finish timestamps and bytes restored. Read back its mount/device identity before any
   filesystem operation. Verify the complete state/config/certificate/geolocation manifest and
   database integrity offline; create a separate writable scratch copy for service startup.
4. Import the paired D1 export into the empty scratch database. Verify applied migrations,
   schema, row counts, integrity/foreign keys and identity inventory. A local SQLite import can
   test portable SQL, but cannot prove D1-specific behavior. Match the broker build to the schema.
5. Reconcile access while client traffic is still fenced. End every recovered open session and
   disable/revoke its temporary policy; do not replay it. Verify machine UUID, organization,
   public key, per-device group, peer ID and assigned IP across the restored stores. Disable
   enrollment credentials and queued privileged work until reviewed. Orphan peers, policies,
   group memberships, changed/revoked identities and unknown ownership fail closed. Quarantine
   conflicts for operator review; never merge them by display name, IP alone, or newest timestamp.
6. Start the exact pinned services with scratch endpoints/credentials only. Verify startup logs,
   database queries, migration compatibility, management/API authentication, certificate/SNI
   configuration and STUN protocol response. The combined relay's internal `/health` 503 with
   `listeners:null` is not a valid sole restart/restore gate; use the operations readiness contract.
7. With dedicated consenting test identities, obtain **new** session authorization and exercise
   management/signal, direct and forced relay paths, transfer checksum, expiry/revocation and
   cleanup through the installed product. Integration owns the two-machine acceptance procedure.
   No product session was proved by the empty production inventory or by this fixture.
8. Record pass/fail and durations. Return access to production only under a separate cutover
   approval, after protected rollback points and fail-closed reconciliation are accepted. Cleanup
   is limited to the exact scratch IDs approved at step 1; never delete a production backup.

## Evidence needed to close the recovery gate

The final ledger must include the accepted RPO/RTO, incident-declared UTC, snapshot/capture UTC,
restore-start UTC, volume-ready UTC, databases-verified UTC, and product-acceptance-complete UTC.
Measure data loss using the newest verified recovered committed operation against the incident's
last known committed operation. If that cannot be established, report RPO as unmeasured. Measure
RTO from incident declaration through validated availability, including approval/provisioning and
reconciliation delay; do not substitute VM boot time or fixture execution time.

Attach provider restore results, trusted checksums, database/schema checks, restored identity
counts and conflict dispositions, service startup evidence, two-machine acceptance, cleanup
scope, and the operator's acceptance. Keep sensitive raw evidence protected; the review ledger
contains identifiers/digests and results only. Until those exist, recovery remains **unproven**.
