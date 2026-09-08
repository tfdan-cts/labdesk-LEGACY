# Labnet operations

The checker in `deploy/operations/` provides read-only availability and backup signals
for an existing monitor. It does not deploy, restart services, enroll peers, create
cloud resources, restore production, or send notifications. A green probe is not the
release gate: installed-product transport, restoration and alert delivery have separate
acceptance evidence. Current server procedure: [LABNET-SERVER.md](LABNET-SERVER.md).
Recovery procedure: [LABNET-RECOVERY.md](LABNET-RECOVERY.md).

## Readiness contract

Run from two positions: an external runner using `public` mode and the approved operator
route using `operator` mode. An on-VM check alone cannot detect loss of the VM or its
external route. The public runner must not belong to the NetBird admin allowlist.

| Check | Expected result | Meaning and response |
| --- | --- | --- |
| `broker_tls`, `netbird_tls` | Trusted chain, correct hostname, at least 21 days left | Warn on expiry threshold; urgent on failed validation/handshake. Investigate renewal, DNS, clock and routing. |
| `broker_health` | `/health` 200 and JSON `ok:true` | Worker availability; does not prove every D1 operation. Inspect existing Worker logs on failure. |
| `broker_auth_fence` | Anonymous `/console/org` 401 | Authentication remains enforced. An unexpected 200 needs immediate security review. |
| `relay_router` | `/relay` 426 | Router reaches the upgrade handler. Does not prove relay authentication or a relayed peer session. |
| `stun_binding` | UDP 3478 Binding Success, matching cookie/transaction and mapped-address attribute | Actual STUN response, rather than an open UDP port assumption. Does not prove a direct connection between peers. |
| `netbird_public_fence` | Public anonymous `/api/peers` 403 | External IP fence. Only public mode runs this check. |
| `netbird_authenticated_api` | `/api/peers` 200 and JSON array | Operator mode uses the existing service token. An empty array passes API availability, never enrollment acceptance. |
| `netbird_auth_fence` | Operator-source anonymous `/api/peers` 401 | Allowed source still needs authentication. Only operator mode runs this check. |
| `backup_inventory` | Fresh inventory, correct boot volume, unexpired AVAILABLE point under age threshold, no newer FAULTY attempt | Investigate failed collector, lost credential, failed/late backup or wrong asset. AVAILABLE still does not prove restoration. |

Internal `:9000/health` is deliberately excluded. In the pinned combined server, external
HTTP handling can bypass the relay's own listener list, while the health endpoint requires
that list. The audit observed 503, `listeners:null`, `certificate_valid:true`. Do not turn
this into a permanent alarm or an automatic restart. Validate a real relay session in
product acceptance. [NetBird v0.78.0 relay source](https://github.com/netbirdio/netbird/blob/v0.78.0/relay/server/server.go),
[health-check source](https://github.com/netbirdio/netbird/blob/v0.78.0/relay/healthcheck/healthcheck.go).

## Run and integrate

No new Python dependencies are required for the checker or fixture. Python 3.10+ is
sufficient. The inventory collector uses the operator's already installed OCI Python SDK;
it does not install it or move OCI credentials onto the server.

From the repository root:

```powershell
python -B -m unittest discover -s deploy/operations -p 'test_*.py' -v
python -B deploy/operations/readiness.py --config deploy/operations/readiness.example.json --check-config
python -B deploy/operations/readiness.py --config deploy/operations/readiness.example.json
python -B deploy/operations/restore_rehearsal.py --fixture
```

The example is explicitly unconfigured for backups: parsing succeeds with
`backup_configured:false`; a real run fails the backup check. Create a private operator
copy and set `backup_evidence` to a protected inventory file and `boot_volume_id` to the
independently confirmed target. Never make missing evidence optional to get a green run.
All configuration keys are required; typos, invalid hosts, modes and thresholds exit 2
before any network or token read.

Collect metadata on the existing OCI-authenticated operator machine. The output parent
directory must already exist. In this example `$inventoryPath` is a protected absolute
operator-selected path, not a repository file:

```powershell
python -B deploy/operations/backup_inventory.py --instance-name labnet-netbird --output $inventoryPath
```

The collector defaults to the credential's tenancy root; use `--compartment-id` only
when the instance's compartment has been confirmed. It requires exactly one matching
non-terminated instance and one attached boot volume, paginates results, uses read-only
list calls and writes atomically. It outputs only a count/success result, never credential
or provider error bodies. A failed collection exits 1 and leaves the last successful
inventory unchanged. The checker rejects that old file after 900 seconds.

The JSON inventory contains `observed_at` (Unix seconds), `boot_volume_id`, and `backups`
with string `id`, `state`, `created_at` and nullable `expires_at`. Treat it as trusted
operator input, not an authenticated provider attestation. Keep it private; publish it
to the chosen runner only through the existing approved protected route. Collect at
least every five minutes. The default maximum backup age is 604800 seconds, matching
the observed weekly cadence, with no extra grace. This is an alert threshold, not an
owner-accepted RPO; changing cadence or declaring RPO/RTO requires the recovery decision.

For operator mode set `mode:"operator"`, retain `netbird_host:"nb.lab-desk.net"`, set
`netbird_connect_ip:"127.0.0.1"` on the VM, and set `token_file` to a private readable
file. TLS always validates the public hostname/SNI even when connecting to loopback.
The existing token stays in its private store or systemd credential copy; never pass
its value as an argument or log it. Operator probes were verified over the preserved
Homebox jump route without writing any file on the VM.

## Optional existing-systemd runner

These units are installation artifacts, not enabled services. Choose the runner and
monitor owner before installing them. On the approved Linux runner, an operator installs
the script at `/opt/labnet-operations/readiness.py`, config at
`/etc/labnet-operations/readiness.json`, and the supplied units in `/etc/systemd/system/`.
Script/config/unit files should be root-owned, mode 0644, in root-owned directories;
no configuration contains a secret value. The inventory producer must write the
root-owned mode-0600 file `/var/lib/labnet-operations/backup-inventory.json` atomically.

`LoadCredential` makes that inventory readable to the dynamic service user. Set the
installed config's `backup_evidence` to
`/run/credentials/labnet-readiness.service/backup-inventory.json`. Do not make the source
world-readable to solve access errors. For an operator-mode unit on the VM, add a
root-owned override:

```ini
[Service]
LoadCredential=netbird-token:/root/netbird-labdesk-token
```

Set its config's `token_file` to
`/run/credentials/labnet-readiness.service/netbird-token`. That private credential copy
is accessible to the dynamic user; a raw root-owned 0600 token is not. Confirm the
runner can read the credential copy in a controlled test before enabling its timer.
On the verified systemd runtime that copy reports mode 0440. The checker accepts this
only for a regular file directly inside the exact canonical `CREDENTIALS_DIRECTORY`;
sibling directories, symlink aliases and world-readable files are rejected. Ordinary
Unix token files still require no group/other permission bits. Windows file permissions
must be restricted with ACLs rather than Unix mode bits.

After installation is approved, the operator validates and enables the units on that
runner, then inspects the first result:

```sh
sudo systemd-analyze verify /etc/systemd/system/labnet-readiness.service /etc/systemd/system/labnet-readiness.timer
sudo systemctl daemon-reload
sudo systemctl start labnet-readiness.service
sudo journalctl -u labnet-readiness.service -n 5 --no-pager
sudo systemctl enable --now labnet-readiness.timer
```

The timer samples one minute after the previous run finishes; it does not overlap runs.
`TimeoutStartSec=55` is the whole-process deadline. Python socket timeouts limit socket
inactivity, not total time: slow response headers/bodies or DNS can exceed them. Every
other runner must also impose a 55-second process deadline. A deadline kill, missing
JSON or failed unit is a failed check, never a skipped sample. No service restarts are
performed in response to failures.

## Alert delivery acceptance — open

Required delivery is through LabDesk's built-in notification preferences: authorized
owner/overseer and affected-device recipients, OS push/popups, email and supported
integrations. The product notification service owns durable events, recipient
authorization, preferences, deduplication and delivery. Domain email setup owns the
operator mail route and outbound provider. Neither delivery implementation is proved
by this operations package; do not add a competing email/notification implementation.

An independent runner and outage route are still required when LabDesk itself is down.
The older vault reference to Netdata on CT 200 does not prove current alert routing.
Do not claim journal output means somebody received an alert. Confirm the existing
runner, fallback recipient and escalation route before installing the units, then wire
this contract into the product notification service and independent outage receiver:

- Collect JSON stdout plus process exit status. Exit 0 means listed probes passed;
  exit 1 means a probe failed; exit 2 means invalid config. Unexpected exits, timeouts,
  empty/malformed output, missing expected checks and stale samples fail closed.
- Group by environment, mode and check. Alert availability after three consecutive
  failed samples; recover after two consecutive passing samples. Route auth-fence
  violations immediately. Warn on TLS threshold and backup failure/staleness without
  suppressing them behind an unrelated healthy check.
- Send one opening event, one recovery event, and escalate an unacknowledged ongoing
  incident after 15 minutes. Use the notification service's durable event identity and
  preferences. A global service check has no device identity: let authorized product
  ownership data determine affected recipients; do not broadcast or invent a device
  association from a peer address. Never include token values or raw API response bodies.
- Monitor the runner from outside the VM and outside its own process. Missing samples
  for four minutes must alert, including when the timer or host itself dies. The
  inventory collector also needs failure/missing-run monitoring.
- Acceptance drill: run the loopback HTTP failure/recovery fixture, feed its detector
  results into a dedicated test check on the existing monitor, trigger missing/stale
  backup evidence, then confirm a named recipient receives and acknowledges the
  opening and recovery events with timestamps. Never fail production to test delivery.

The local tests prove detection. They do not test a notification provider, recipient,
deduplication, escalation, remote runner uptime, or timer installation. Those remain
explicit gates until the chosen monitor's real evidence is recorded.

The notification service's proposed internal ingestion shape is `operations.check`,
severity `warn|critical|info`, phase `firing|resolved`, Unix-second `occurredAt`, bounded
title/body and `sourceKey` derived from environment/mode/check. It supplies a durable
occurrence ID and an explicit authorized organization target. This is an integration
contract, not an installed HTTP endpoint. Any external ingestion must authenticate a
narrow publisher bound server-side to the permitted producer/environment/organization;
payload organization or machine IDs never grant authority. Use the broker's existing
service-auth primitive if suitable; otherwise a separately reviewed dedicated publisher
credential is required. Do not reuse the NetBird PAT, cloud-admin key or machine signing
key. Enforce TLS, bounded input, check-name allowlisting, freshness and idempotency.

## Windows endpoint troubleshooting

Start with the endpoint's actual state. A running service alone does not prove a
working tunnel. In an elevated PowerShell window, inspect the owned adapter,
address and daemon:

```powershell
Get-NetAdapter -Name labdesk0 -IncludeHidden
Get-NetIPAddress -InterfaceAlias labdesk0 -AddressFamily IPv4
Get-Service LabDesk,labdesk-netbird
& 'C:\Program Files\LabDesk\netbird\netbird.exe' status --json --daemon-addr npipe://labdesk-netbird
```

If `labdesk0` exists and is the LabDesk tunnel, try an adapter-only reset before
restarting Windows:

```powershell
Restart-NetAdapter -Name labdesk0 -Confirm:$false
```

This disables and re-enables that adapter. It does not reinstall the application,
erase enrollment or restart Windows. Tunnel traffic can be interrupted; have a
local screen or independent administrative route before resetting the adapter
carrying your session. Do not use a wildcard that also selects Ethernet, Wi-Fi,
another VPN or a virtual switch. Microsoft documents the operation in
[Restart-NetAdapter](https://learn.microsoft.com/en-us/powershell/module/netadapter/restart-netadapter).

Afterward, verify the adapter is Up, the expected Labnet IPv4 address is present,
management/signaling are connected, and an actual operation reaches the intended
peer through Labnet. A green daemon status without peer traffic is insufficient.
Check a fresh WireGuard handshake and source interface/address. For independent
network acceptance, verify Tailscale is stopped with no processes on both machines;
Manual startup does not prevent its logon app from starting the service.

If the adapter is missing, there is no existing interface to toggle. Preserve the
daemon's error and Windows Kernel-PnP Configuration events first. A disabled
adapter, failed device creation and an unreachable control plane require different
repairs. An owned-service stop/start is a separate next step; a full Windows restart
is a fallback after narrower recovery is unsuccessful. Do not delete a shared
Wintun driver registration or weaken Windows security as a generic reset procedure.

### Verified reset and delayed recovery — 2026-09-08

On 1.4.0-alpha.3+75 / NetBird 0.78.0, Zenbook's adapter-only reset began at
06:59:26.270Z and returned at 06:59:26.719Z. By 06:59:41.024Z, labdesk0 was Up,
100.84.242.192/16 was retained, and TCP21118 to Foundry succeeded from that Labnet
address. Both owned service process IDs and the Windows boot time were unchanged.
Tailscale was Disabled/Stopped with no processes. Receipt:
`C:/ProgramData/LabDesk/Deploy/alpha3-build75/adapter-reset-test.json` on Zenbook.

This proves successful adapter reset from an already connected state. It does not
prove that reset fixes the earlier adapter-creation failure, nor that active
desktop/file sessions survive; those effects need their own controlled checks.

Before this experiment, the daemon recovered without manual intervention. Its
last failed creation ended at 06:45:03Z. Another automatic attempt started at
06:45:27.459Z; Windows recorded the same Wintun device starting at 06:45:28.024Z,
and the daemon started its engine at 06:45:29.728Z. The process and Windows boot
were unchanged, and the operator confirmed no manual changes. Earlier device-start
events reported problem 0x1F / status 0xC00002F0. The failed and successful attempts
used the same installed driver package. The retry explains how service resumed;
available logs do not establish why Windows stopped rejecting device creation.
Preserve that distinction when reporting the incident. Diagnostic receipt:
`alpha3-build75/spontaneous-recovery-timeline-2.json` on Zenbook.

## Evidence ledger

Recorded 2026-09-07; all live actions were reads, and no production changes were made.

| Verifier | Observed result | Limit |
| --- | --- | --- |
| Final combined unittest suite, Ubuntu 24.04 / Python 3.12 | 16 tests passed in 8.525 seconds, including real loopback HTTP/UDP, failure/recovery, config/backup rejection and credential-path permissions | Local behavior only; no notification recipient tested |
| Public checker with fresh OCI inventory, 02:09 UTC | All 8 checks passed; broker 200/401, NetBird 403/426, STUN binding, trusted TLS with about 86 days remaining; newest backup age 79723 seconds | Public API fence is not authenticated control-plane availability |
| Operator checker through Homebox, 02:08 UTC | Both TLS checks, broker 200/401, relay 426, STUN, authenticated peers 200 and anonymous peers 401 passed | Remote backup input deliberately absent, so its aggregate correctly failed |
| OCI collector | 2 backups read and inventory written; latest AVAILABLE state accepted by checker | No backup created/restored, no D1 consistency proved |
| Final `systemd-analyze verify` on local Ubuntu 24.04 | Exit 0 on root-owned mode-0644 copies in a unique temporary directory | No production install or delivery |
| Actual transient `DynamicUser` + `LoadCredential` service | Real checker token reader accepted the 0440 credential copy; unit and temporary directory cleaned | Synthetic credential only; does not prove a production timer was installed |
| Final restore fixture CLI | Six files, two identities, checksums/integrity/queries passed in 0.0044 seconds; production/service proof false, RPO/RTO null | Actual restore prerequisites and RPO/RTO remain open in LABNET-RECOVERY.md |

Independent review found the private-file/dynamic-user mismatch and added the
`LoadCredential` route; found socket timeout was not a total deadline and made the
supervisor deadline explicit; and tightened backup identity types. The real credential
fixture then caught the 0440 permission mismatch, which was fixed and reverified by
the final checks above. No check was promoted to production delivery or restore proof.
