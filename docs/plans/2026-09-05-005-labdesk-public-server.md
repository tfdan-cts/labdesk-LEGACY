---
type: plan
created: 2026-09-05
status: proposed
supersedes: nothing
related:
  - docs/plans/2026-09-05-001-production-program.md
  - docs/plans/2026-09-04-003-rmm-architecture.md
  - docs/plans/2026-09-03-001-feat-labnet-overlay-plan.md
  - docs/LABNET-SERVER.md
  - docs/CONSOLE.md
---

# The LabDesk public server

LabDesk ships today with RustDesk's public server compiled into it. An installed client that
nobody configures registers its id on `rs-ny.rustdesk.com` and trusts RustDesk's public key. That
is a product built on someone else's infrastructure, under someone else's key, with no way to say
who may use it. This plan replaces it with LabDesk's own public server on LabDesk's own hosts and
domain, reached only by machines that carry a lab-desk.net account or an enrolment token, and it
puts labnet where the owner intended it: as the path machines actually take, with the public
server as the fallback and the on-ramp.

Everything asserted here was read or measured on 2026-09-05 and carries its source. Where a claim
could not be checked it says `unverified` beside it, and section 16 collects those in one place.

## 0. The owner's decisions this plan implements

These are settled and are not reopened below.

1. LabDesk defaults to a LabDesk public server, never RustDesk's.
2. The LabDesk public server runs on the LabDesk VM and domain and behaves for a user the way
   RustDesk's hosted public server does, while being functionally secure.
3. Access is signed-in accounts only. A machine registers only if it carries a lab-desk.net
   account or an enrolment token.
4. The rendezvous runs on the existing Oracle VM that already carries labnet-netbird, alongside
   what it runs now. The relay runs, for now, on the Proxmox container CT 102 that already carries
   the owner's own private RustDesk server and which LabDesk replaces on it outright, and is
   migrated to a host of its own when public
   demand justifies one. Both the split and that migration are designed for here (owner
   decision, 2026-09-05, amending the single-host decision this plan was started under).
5. labnet is how machines reach each other. The public server is the fallback and the on-ramp,
   not the path.

---

## 1. What the open source RustDesk server actually is

Fetched 2026-09-05 from `https://raw.githubusercontent.com/rustdesk/rustdesk-server/master/README.md`
and `.../docs/environment-variables.md`, and read against the sources at
`.../src/rendezvous_server.rs` and `.../src/relay_server.rs`. The repository is AGPL-3.0
(`https://api.github.com/repos/rustdesk/rustdesk-server`, `license.spdx_id` reads `AGPL-3.0`).

### 1.1 Two binaries and nothing else

The README lists exactly three executables: `hbbs`, the ID and rendezvous server; `hbbr`, the
relay server; and `rustdesk-utils`, a CLI. There is no third service, no database beyond a SQLite
file (`DB_URL`, default `./db_v2.sqlite3`) and no web interface.

The OSS documentation page `https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/` (fetched
2026-09-05, page `dateModified` 2026-07-12) states the boundary in one sentence:

> If you need a web console, API access, OIDC, LDAP, 2FA, device management, or other centralized
> admin features, compare it with RustDesk Server Pro

That sentence is the whole answer to "does the open source server authenticate accounts or
devices". It does not. Accounts, device management and the API are Pro features. The
environment-variables document says the same thing from the other side: `PORT_FOR_API` and
`KEY_FOR_API` "are only used by RustDesk Server Pro and its API; they have no effect in the
open-source server."

### 1.2 The key, and exactly what it gates

`KEY` / `-k` on `hbbs` may be a public key string, a base64 64 byte secret key, `-` or `_` to load
or generate `id_ed25519` and `id_ed25519.pub` in the working directory, or empty to disable key
validation. `hbbs` defaults to `-`. `hbbr` defaults to empty, which the document calls a
deliberate tradeoff: "An empty key allows clients without a matching key to use the relay, so
choose this tradeoff deliberately on an exposed server."

The source says precisely where the key is checked, and it is a much narrower place than the
phrase "key validation" suggests.

| Where | The check | Line |
|---|---|---|
| `hbbs`, punch hole request | `if !key.is_empty() && ph.licence_key != key` then answer `LICENSE_MISMATCH` | `src/rendezvous_server.rs:711` |
| `hbbr`, relay request | `if !key.is_empty() && rf.licence_key != key` then drop the connection | `src/relay_server.rs:466` |
| `hbbs`, id registration | **no key check anywhere in the RegisterPk arm** | `src/rendezvous_server.rs:371` to `:454` |
| `hbbs`, peer re-registration | no key check in the RegisterPeer arm either | `src/rendezvous_server.rs:355` to `:370` |

The RegisterPk arm refuses an id shorter than six characters, runs `check_ip_blocker`, checks the
uuid against the stored peer, rate limits that peer at more than two registrations in six seconds
(`TOO_FREQUENT`), records an ip change, and answers `OK`. It never looks at a key, because
`handle_udp` receives one but never passes it into that branch. The only enum values the file
imports from `register_pk_response::Result` are `TOO_FREQUENT` and `UUID_MISMATCH`
(`src/rendezvous_server.rs:16`), so `NOT_DEPLOYED` is a value this server never sends.

**So the key gates sessions and the relay, and does not gate registration.** Anyone who can reach
UDP 21116 can take an id on the server whether or not they hold the key. That single fact decides
the shape of section 8.

### 1.3 What the relay does with bandwidth

`hbbr` carries the full session payload for every pair that cannot punch a hole, and it is the
expensive part of running a public server. Its knobs have no CLI flag and are read from the
environment or set live over the loopback console:

| Variable | Default | Meaning |
|---|---|---|
| `SINGLE_BANDWIDTH` | 128 Mb/s | normal cap per relay connection |
| `TOTAL_BANDWIDTH` | 1024 Mb/s | aggregate cap across all relay connections |
| `LIMIT_SPEED` | 32 Mb/s | cap applied after a connection is downgraded, and to `blacklist.txt` addresses |
| `DOWNGRADE_THRESHOLD` | 0.66 | fraction of `SINGLE_BANDWIDTH` a lifetime average must exceed to trigger downgrade |
| `DOWNGRADE_START_CHECK` | 1800 s | delay before a connection becomes eligible for that check |

The defaults are visible in the source as well (`src/relay_server.rs:40` to `:44`). The document
is explicit that "Downgrade is decided independently for each connection; it does not check
aggregate relay congestion", so a single long transfer can be capped on an otherwise idle relay,
and the aggregate cap is a separate ceiling.

`hbbr` also reads two files from its working directory at start: `blacklist.txt`, addresses that
are bandwidth limited, and `blocklist.txt`, addresses refused outright. Both are editable live
through the loopback console (`ba`, `br`, `Ba`, `Br`).

### 1.4 What a public server exposes, and on which ports

From the port reference in `docs/environment-variables.md`:

| Port | Protocol | Server | Purpose |
|---|---|---|---|
| 21115 | TCP | hbbs | NAT type test (`PORT-1`) |
| 21116 | TCP and UDP | hbbs | id registration, rendezvous, hole punching |
| 21117 | TCP | hbbr | relay |
| 21118 | TCP | hbbs | WebSocket rendezvous (`PORT+2`) |
| 21119 | TCP | hbbr | WebSocket relay (`hbbr PORT+2`) |

The document notes that 21118 and 21119 are needed only for the web client. LabDesk has a web
target in tree but the product this plan serves is the desktop and mobile client, so those two
stay closed until a web client is a shipping surface. The loopback consoles listen on 21115 for
`hbbs` and on the relay port for `hbbr` and answer only a loopback source.

`BIND` (`-b`, available since 1.1.17) sets the local address every listener binds, which matters
in section 12.2. Note also that `hbbr` set through the `PORT` environment variable listens on
`PORT + 1` rather than `PORT`, so a second relay beside an existing one is given `-p` and never
the environment variable.

---

## 2. How the client picks and trusts a server today

### 2.1 The sources, in order

`Config::get_rendezvous_server()` at `libs/hbb_common/src/config.rs:913` reads, in order, and
takes the first non-empty:

1. `EXE_RENDEZVOUS_SERVER` (`:914`). Written in exactly one place in the whole tree,
   `src/platform/windows.rs:2197`, from the host embedded in a renamed Windows executable
   (`get_license_from_exe_name`).
2. the `custom-rendezvous-server` option (`:916`).
3. `PROD_RENDEZVOUS_SERVER` (`:919`). Declared at `config.rs:70` and read in three places
   (`config.rs:919`, `config.rs:945`, `src/common.rs:1057`). A search of the whole repository for
   a write to it returns nothing, so this source is dead code today.
4. `CONFIG2.rendezvous_server` (`:922`), the value a server may have pushed with a newer serial.
5. the fallback: the first entry of `Config::get_rendezvous_servers()`, which ends at
   `config.rs:960` returning `RENDEZVOUS_SERVERS`, which is `&["rs-ny.rustdesk.com"]` at
   `config.rs:120`.

`Config::get_rendezvous_servers()` at `:936` walks the same list and ends the same way.

So an installed LabDesk that nobody points anywhere registers on `rs-ny.rustdesk.com`. That is
the behaviour this plan removes.

### 2.2 Where the key comes from and where it is used

`crate::get_key(sync)` at `src/common.rs:1879` reads the `key` option, and when it is empty falls
back to `config::RS_PUB_KEY` at `:1896`, which is
`"OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw="` at `config.rs:121`. That value is RustDesk's
public server key.

The key is used in three distinct ways, and they are worth separating because they fail
differently.

* **As a bearer credential to the server.** The client copies it verbatim into `licence_key` on
  `PunchHoleRequest` (`src/client.rs:693`) and on `RequestRelay` (`src/client.rs:1196` and
  `src/server.rs:331` to `:333`). `hbbs` and `hbbr` compare that string against their own
  configured key. Nothing about this is asymmetric: possession of the string is the whole test.
* **As the server's signing key.** On a TCP rendezvous connection the client runs
  `crate::secure_tcp(&mut conn, &key)` (`src/rendezvous_mediator.rs:427` to `:428`), and
  `secure_tcp_impl` at `src/common.rs:2021` decodes the key, verifies the server's ephemeral
  public key with `sign::verify` and bails with `"Signature mismatch in key exchange"` if that
  fails.
* **As the key that authenticates a peer's identity.** `Client::secure_connection` at
  `src/client.rs:990` calls `get_rs_pk(if key.is_empty() { config::RS_PUB_KEY } else { key })` at
  `:996` and uses it in `decode_id_pk` (`src/common.rs:2087`) to verify that the id and public key
  the server handed over were signed by that server.

`src/client.rs:2158` adds a fourth appearance: an id written `<id>@public` selects
`config::RS_PUB_KEY` explicitly, and `src/client.rs:524` to `:532` maps the same literal onto
`RENDEZVOUS_SERVERS[0]`. `PUBLIC_SERVER` is the constant `"public"` at `src/client.rs:177`.

### 2.3 What happens when the key does not match

Three different failures, in three different places.

* **On the punch hole path.** `hbbs` answers `LICENSE_MISMATCH`, and
  `src/client.rs:728` to `:729` turns that into `bail!("Key mismatch")`, which the user sees as
  the translated string `Key mismatch` (present in every language table, for example
  `src/lang/uk.rs:140`).
* **On the TCP rendezvous handshake.** `secure_tcp_impl` fails with `Signature mismatch in key
  exchange` (`src/common.rs:2034`) and the mediator connection dies and is retried.
* **On the relay.** `hbbr` logs `Relay authentication failed` and returns without pairing
  (`src/relay_server.rs:467` to `:468`), so the client simply never gets a peer and times out.

Registration is unaffected in all three cases, because registration does not carry the key. A
client with the wrong key still appears online on the server and still cannot be connected to.

### 2.4 What writes `custom-rendezvous-server` today

| Writer | Where |
|---|---|
| the installer flags | `install.ps1:305` and `install.sh:193`, from `-Server` and `LABDESK_HOST` |
| the CLI | `rustdesk --option custom-rendezvous-server <host>` (`src/core_main.rs:214`, `:529`) |
| a renamed Windows build | `src/platform/windows.rs:1690` |
| the ID/Relay server dialog | `flutter/lib/common.dart:3752` |
| a server profile | `ServerProfilesModel.applyLive`, `flutter/lib/common/labdesk_profiles.dart:204`, over the four keys at `:18` to `:23` |

Nothing else. In particular a lab-desk.net sign in writes none of them. A search of
`~/TrapLab/labdesk-site` for `custom-rendezvous-server`, `relay-server` or a server key returns
only comments in `routes/overlay.ts` and `routes/agent-overlay.ts` about the rendezvous signature.
The site has never told a client which server to use, and the client has never asked.

`src/hbbs_http/sync.rs:349` onward is the other half of that boundary: the heartbeat reply may
push a list of options onto the machine, and `custom-rendezvous-server`, `relay-server`,
`api-server` and `key` are deliberately excluded, with a test that asserts it
(`sync.rs:578` to `:597`). Any design that has the server hand out server details must therefore
go through a route of its own, not through the strategy channel.

---

## 3. What lab-desk.net already has to stand on

Read from `~/TrapLab/labdesk-site/README.md` (the route table at lines 34 to 38 and the route
lists from line 97), `docs/plans/2026-09-04-003-rmm-architecture.md` sections 2 and 3, and
`docs/plans/2026-09-05-002-phase1-contracts.md`.

**Four principal kinds, four checks.**

| Plane | Credential | Enforced by |
|---|---|---|
| Public | none | nothing |
| Human | Better Auth session cookie | `requireUser` and `actor()` in `src/worker/org.ts` |
| Console | the desktop's app bearer, resolved by the same `actor()` | `/console/*` mounted beside `/api/*` |
| Installed client | bearer minted by `POST /api/login`, stored hashed | `bearerUser()` in `routes/client-api.ts` |
| Machine | Ed25519 signature over the request | `agentAuth` in `src/worker/agent-auth.ts`, `/agent/*` |

**The app token.** `POST /api/login` issues it, counts its own attempts at five per account and
thirty per address a minute, and it now carries an expiry (architecture section 2, row 14). The
desktop console uses it on `/console/org/*` and `/console/overlay/*`.

**The organization plane and `actor()`.** Roles are owner, technician and viewer. `actor()` loads
the Better Auth session fresh, reads the active organization, refuses a caller who is not a
member, and narrows to `member_fleet` rows when they exist. Every scoped query also carries
`eq(machine.orgId, org.id)` so a bug in the capability check cannot cross an organization
(architecture section 2, row 1).

**The signed agent plane.** `/agent/*` ignores bearer tokens entirely. Each request carries
`X-LD-Machine`, `X-LD-Ts` and `X-LD-Sig` over
`b"labdesk-agent-v1\0" || METHOD || \0 || PATH || \0 || TS || \0 || sha256_hex(BODY)`, verified
against `machine.agentPk`, which holds a global unique index, with a 120 second clock window
(architecture section 3.3).

**Enrolment tokens.** `POST /api/org/enrol-token` is owner only and needs a sign in under five
minutes old. The token is single use with a fifteen minute life, stored hashed. A machine spends
it at `POST /agent/enrol`, the one unsigned route on the plane, which verifies a signature over
the submitted `agent_pk` as proof of possession, mints `machine.id`, stores the key and burns the
token (site README line 139 and line 166, architecture section 3.2).

**The machine's own credential.** `src/labdesk/identity.rs` holds an Ed25519 keypair generated
inside the privileged daemon and written to `agent-identity.toml` in a directory `Config` does not
know about, so `Data::SyncConfig` cannot carry it to the unprivileged user process. The file's
header comment states that reason in full, and its `Debug` implementation omits the secret.

That is the whole set this plan needs: an authenticated human, an authenticated console, an
authenticated machine, and a one-time token that turns the first into the third.

---

## 4. What labnet already does, and where it stops

Read from `~/trapLab-brain/30_Projects/LabDesk/network-tool-design.md` (read only, not modified)
and `docs/CONSOLE.md` section "labnet: the encrypted direct path".

**The direct path exists in the client.** `Client::_start` at `src/client.rs:410` onward reads
`labdesk-overlay-addr-<peer>` and `labdesk-overlay-pk-<peer>` and tries that address before any
server. The comment at `:404` to `:409` states the contract: an address that leads nowhere falls
through unchanged, and a machine that answers there and signs an identity that is not the peer's
ends the connect instead. `direct_server` in `src/rendezvous_mediator.rs` binds only to
`labdesk-direct-bind`, and the constant `DIRECT_BIND_RETRIES` at `:853` with the comment from
`:855` to `:861` records why that option is accepted only as a literal address inside
`100.64.0.0/10`.

**The session grant exists on the server.** `POST /api/overlay/session` and its `/console` twin
resolve both machines by `machine.id` through `actor()`, create a one way NetBird policy from the
controller's group to the target's on the target's direct port, and return a one time connect
ticket whose plaintext appears only in that answer (site README line 140).

**The fall through to the rendezvous transport exists.** With no hint, or a hint that does not
answer, `_start` continues into `get_rendezvous_server` exactly as before.

**What is not proven.** The vault design's own list, dated 2026-09-05: no signed-in console has
reached `/console/*` in production, no machine has been enrolled from the card, labnet has not
been turned on from the card, and no session has been opened over an overlay address. The direct
path itself was proven on 2026-09-04 between Foundry and homebox with hints written by hand over
Tailscale addresses, which sit in the same `100.64.0.0/10` range the hint validator accepts. The
production program calls the remaining step phase 0b and marks it owner-only.

**Where it stops, for this plan's purposes.** labnet is opt in, per machine, and only inside one
organization. A machine that has not turned it on, or whose peer has not, has no direct path at
all, and every session it opens goes through a rendezvous server. Today that server is RustDesk's.

---

## 5. The two hosts as they stand

The public server is split across two machines the project already runs. Owner decision,
2026-09-05: the rendezvous stays on the Oracle VM that already carries labnet's control plane, the
relay goes on the Proxmox container CT 102 that already carries the owner's own private RustDesk
server, and the relay is migrated to a host of its own when public demand justifies one. Both
machines were measured on 2026-09-05 and nothing on either was changed.

### 5.1 The rendezvous host: the Oracle VM

`docs/LABNET-SERVER.md` records the shape. The readings below were taken live over the runbook's
own jump host route, `ssh -J ubuntu@100.111.222.91 ubuntu@10.30.20.160`.

**Capacity.**

```
labnet-netbird
 19:26:27 up 1 day, 16:04,  1 user,  load average: 0.00, 0.02, 0.00
1
               total        used        free      shared  buff/cache   available
Mem:            5903         574        4021           5        1476        5329
/dev/sda1        48G  3.3G   45G   7% /
```

One core, 5903 MB of memory with 5329 MB available, 45 GB of disk free, and a load average of
zero. `docker stats` reads `netbird-server 0.10% 83.68MiB`, `netbird-traefik 0.00% 153.6MiB`,
`netbird-dashboard 0.01% 38.7MiB`. There is room for `hbbs`, which is the light half: it exchanges
small messages and holds a peer table, and it does not copy session bytes.

**What listens now.**

```
udp UNCONN  [::]:3478       0.0.0.0:3478
tcp LISTEN  [::]:22         0.0.0.0:22
tcp LISTEN  [::]:443        0.0.0.0:443
udp UNCONN  127.0.0.54:53   127.0.0.53%lo:53
```

Nothing binds anything in the 21115 to 21119 range. There is no port collision.

**What the firewall does now.**

```
-P INPUT DROP
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -s 10.30.20.0/24 -p tcp --dport 22 -j ACCEPT
-A INPUT -p udp --dport 3478 -j ACCEPT
-A INPUT -p tcp --dport 443 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
```

and in `DOCKER-USER`, in order: drop to `169.254.0.0/16`, return established, drop from the
container subnet `172.30.0.0/24` to `10.30.20.0/24`, return Traefik's own address outbound, drop
every other container egress, return anything not arriving on `enp0s6`, return 443/tcp and
3478/udp from `enp0s6`, drop everything else from `enp0s6`.

Three consequences.

1. `hbbs` needs three holes here in steady state: TCP 21115 for the NAT type test, and TCP and
   UDP 21116 for registration and rendezvous. A fourth, TCP 21117, is opened for the length of the
   cutover only, because during it this host also carries the temporary relay that lets the fleet
   leave CT 102 (section 5.5, step 2), and it is closed again at step 6. WebSocket rendezvous on
   21118 stays closed until a web client is a shipping
   surface. Each hole needs a rule in `INPUT`, a rule in `DOCKER-USER` if `hbbs` runs as a
   container, and an entry in the Oracle network security group `labnet-netbird`. The runbook
   records that the subnet's shared security list also allows 444/tcp and 41641/udp from anywhere
   and that the host firewall is what closes them, so the host firewall is the line that matters
   here too.
2. Container egress is dropped. `hbbs` runs a start-up UDP self test against `TEST_HBBS`, which the
   environment-variables document says can be set to `no` to skip. That is the one thing to
   configure rather than discover: the runbook's own account of the GeoLite incident records that a
   blanket egress block does not break a service when it is applied, it breaks it at the next
   unattended reboot at 04:30 with nobody watching.
3. Traefik terminates 443 and is fenced by a file provider. `hbbs` does not speak HTTP on its
   ports and must not be put behind Traefik. It binds its own ports directly.

**Cost.** The runbook records the instance as `VM.Standard.A1.Flex`, 1 OCPU and 6 GB, billing at
$0.01 per OCPU-hour plus $0.0015 per GB-hour, about $14 a month, because the tenancy's free A1
hours are used by other instances. Rendezvous traffic is small and does not move the bill. Oracle's
egress allowance no longer matters to this plan, because the bytes that would have spent it are on
the other host now.

### 5.2 The relay host: Proxmox CT 102, converted

CT 102 is the owner's own private RustDesk ID and relay server today, and it is being converted:
LabDesk replaces that server on the container outright rather than running beside it (owner
decision, 2026-09-05, replacing the coexistence design this plan carried an hour earlier).
Everything below is what is on it now, so the conversion in section 5.5 has a before to be measured
against, and so the decommissioning in section 5.6 knows what it is removing.

Read through the Proxmox REST API on 2026-09-05. These readings supersede the vault's older audit
at `40_Areas/infra/rustdesk.md`, which carries its own note that its facts are as of 2026-04-24 and
unverified.

**The node.** `traphouse`, online, `pve-manager/9.2.3`, 20 cores, 62.1 GB of memory with 19.4 GB in
use, root filesystem 18.2 GB used of 66.4 GB, load average 2.53, 2.94, 3.34, host CPU at 2.8 per
cent. Alongside CT 102 it runs `lxc 101 traplab-vault` (4 cores, 8192 MB), `lxc 200 traplab-docker`
(2 cores, 6144 MB) and `qemu 400 trapmedia` (4 cores, 11444 MB), with `qemu 100 trapLab-Foundry`
(16 cores, 40000 MB) currently stopped. That last one matters: the node's free memory is not a
constant, because Foundry takes 40 GB of it whenever the owner starts it.

**The container.** `102`, `rustdeskserver`, running, uptime 36753 s at the time of reading.
Unprivileged Debian LXC, `arch amd64`, `cores 1`, `memory 512`, `swap 512`, `onboot 1`,
`features nesting=1,keyctl=1`, root filesystem
`Transmission_Docker:102/vm-102-disk-0.raw,size=2G`, network
`name=eth0,bridge=vmbr0,ip=dhcp,type=veth`. Live use is 76 MB of the 512 MB and 1.05 GB of the
1.90 GB usable disk, with 115905890 bytes in and 22311337 out since boot. The 1 core, 512 MB and
2 GB are the current allocation and not a ceiling: the node has headroom and the container can be
grown.

**What it serves today, which is what the conversion removes.** The vault records `rustdesk-hbbs`
on 21115 and 21116, `rustdesk-hbbr` on 21117 and `rustdesk-api` on 21114, deployed from the
community-scripts `rustdeskserver.sh` package. Probed from the workstation on 2026-09-05, TCP
answers on 21114, 21115, 21116, 21117, 21118, 21119 and 22 at `100.71.21.102`, and
`rustdesk.centaur-diminished.ts.net` resolves to that address. `10.90.80.11:21116` answers on the
LAN. The owner's machines depend on all of it right now, which is what section 5.5 is about.

**What is not exposed.** Probed from outside, from the Oracle VM to the home connection's public
address on 2026-09-05, every one of 21114, 21115, 21116, 21117, 21118, 21119 and 443 is closed.
The server is reachable over Tailscale and on the LAN and from nowhere else today. Making CT 102
carry a public relay therefore begins with opening a port on the home router, which is a change to
the owner's home network and not merely to a container. The public address itself is deliberately
not written down here, because this repository is public.

**Standard ports, because there is nothing left to collide with.** The earlier coexistence draft
put LabDesk's relay on 21127 to keep clear of the incumbent on 21117. With the incumbent removed
that reason is gone, and a non-standard port would have been a permanent line of explanation in
every runbook and every firewall rule for no remaining benefit. So the relay takes 21117, which is
the port the client dials by default: the controlling side connects with
`check_port(relay_server, RELAY_PORT)` at `src/client.rs:1189` and the controlled side does the
same at `src/server.rs:326`, `RELAY_PORT` is 21117 at `libs/hbb_common/src/config.rs:124`, and
`check_port` supplies that port only when the address carries none. A bare `relay.lab-desk.net`
therefore means 21117 and nothing needs saying. `get_relay_server`
(`src/rendezvous_mediator.rs:825` to `:834`) arrives at the same number by its own last resort, the
rendezvous host's port plus one.

### 5.3 How each host is reached, so nobody has to search again

| Host | Route | Notes |
|---|---|---|
| Oracle VM `labnet-netbird` | `ssh -J ubuntu@100.111.222.91 ubuntu@10.30.20.160` | port 22 is reachable only from inside `10.30.20.0/24`, so the Safe Sight backend is the jump host; requires the trapLab tailnet, `tailscale switch 186d` |
| Proxmox node `traphouse` | the REST API at `https://100.109.195.123:8006`, a ticket for `root@pam` at `POST /api2/json/access/ticket`, then `PVEAuthCookie` on every later call | the certificate is self signed, so a client must skip verification; requires the trapLab tailnet |
| CT 102 `rustdeskserver` | through the Proxmox API only, or on the LAN and Tailscale for its service ports | `sshd` on `100.71.21.102` offers `publickey,password` and refuses our key for `root`; no key of ours is installed on the node or in the container, so the API ticket is the only way in that this project holds |

The `root@pam` password lives in the owner's own credentials store on the workstation. It is not
named here, and neither is the file that holds it, because this repository is public. Whoever
implements this reads it from there; the point of this table is that the route is the REST API and
not SSH, which is the part that took a search to establish.

### 5.4 What the split means

The client is told two addresses instead of one, and the client already has the machinery for it.
`get_relay_server` at `src/rendezvous_mediator.rs:825` to `:834` reads the `relay-server` option
first, then whatever the rendezvous server provided, then falls back to the rendezvous host's port
plus one. So the relay is set twice, deliberately: `hbbs` on the Oracle VM is started with
`-r relay.lab-desk.net` so that it advertises the relay to every client, which the
environment-variables document says is exactly when `RELAY-SERVERS` should be set ("Set this only
when the relay uses a different IP/hostname or a non-standard port"; the first of those applies
here and the second no longer does), and `GET /api/client/server` also returns the relay address so
a client holds it without having to be told by a server it may not have reached yet.

`relay.lab-desk.net` is a new `A` record in Cloudflare with the proxy off, pointing at the home
connection's public address, for the same reason `nb.lab-desk.net` is DNS only: Cloudflare's proxy
does not carry this protocol. Two consequences follow and neither is optional. The record ties the
owner's home address to the product in public DNS. And a domestic address can change, so the record
needs a dynamic update, which is a small scheduled Cloudflare API call rather than a manual edit.

**The migration this is designed for.** Moving the relay to a dedicated host later must be a change
of one DNS record, and nothing else, because the relay is on the standard port and the `-r` flag
names it by name. That is why the client is told the relay address rather than deriving it, why the
relay has its own name rather than sharing `nb.lab-desk.net`, and why the relay's key is LabDesk's
fleet key rather than anything tied to CT 102. When the dedicated host exists: stand `hbbr` up on it
with the same key and the same caps, point `relay.lab-desk.net` at it, watch both relays until the
old one is idle, then stop the unit on CT 102 and close the router forward. No client changes, no
`hbbs` restart, and no session in flight is broken, because a session already paired on the old
relay stays on the connection it has.

### 5.5 The cutover, and why it cannot start at CT 102

Converting CT 102 breaks every machine that uses it, and those machines are reached through it.
This order exists so that nobody is locked out of a machine while converting it. It is the owner's
to run, not an agent's.

**What is on the old server today, verified from the client side.** This workstation's own live
configuration, `%APPDATA%\LabDesk\config\LabDesk2.toml` read on 2026-09-05, names
`rustdesk.centaur-diminished.ts.net` as both `custom-rendezvous-server` and `relay-server`, with
`api-server` at `http://10.90.80.11:21114`, and carries a `key` whose value is exactly the one the
vault recorded for that server on 2026-04-24. So the vault's key is the live one, now confirmed
from a client rather than from the box. Other machines are on the same profile.

**The order.**

1. **Stand the new rendezvous up first, on the other host.** LabDesk's `hbbs` goes on the Oracle VM
   with the new key. CT 102 is not touched. Two servers are now running and no machine has moved.
2. **Give the new server a relay of its own, temporarily on the Oracle VM.** Started without `-r`,
   `hbbs` lets every client derive the relay as the rendezvous host's port plus one
   (`get_relay_server`, `src/rendezvous_mediator.rs:831`), so opening 21117 on the Oracle VM for
   the length of the cutover is all this takes. This step is what makes the whole sequence safe: the
   new server is complete on a host that is not the one being converted, so CT 102 keeps serving
   the old fleet until the last machine has left it.
3. **Prove it on a machine that is in the room.** The workstation, converted by hand, with its old
   values written down first.
4. **Convert the rest, in this order:** machines an operator can reach without the relay, meaning
   the LAN, an attended keyboard, or labnet where the machine is already enrolled; then machines
   that are remote but on the trapLab tailnet; then anything else.
5. **Decommission the incumbent** only when the last machine has left it (section 5.6).
6. **Move the relay onto CT 102**: LabDesk's `hbbr` on 21117 with the fleet key, `hbbs` restarted
   with `-r relay.lab-desk.net`, the router forward opened, and 21117 closed again on the Oracle VM.

**The remote unattended machine, answered plainly.** A machine whose only path is the server being
replaced cannot be converted safely over that path. Rewriting `custom-rendezvous-server` restarts
the mediator (`src/ipc.rs:795` and `:803`), and if the machine does not come back on the new server
there is no way in. Three honest answers, in order of preference.

* **Most of them already have another path.** This workstation reaches CT 102 over Tailscale, which
  means the tailnet is a route that does not depend on the RustDesk server at all. Any machine on
  the trapLab tailnet can be converted over the relay and recovered over Tailscale if it does not
  come back, and the same is true of a machine already enrolled in labnet.
* **A timed rollback for the ones with no other path.** Before changing anything, schedule a
  one-shot task on the machine that writes the old server, relay and key back in ten minutes; make
  the change; cancel the task once the machine is seen on the new server. On Windows that is
  `schtasks`, on Linux `systemd-run --on-active`. One scheduled task turns an unrecoverable mistake
  into a ten minute outage.
* **Leave it until someone is there.** The incumbent keeps running until the last machine has left
  it, so nothing forces a risky conversion to a deadline.

**If the new server does not come up at all.** Nothing is lost. Steps 1 and 2 changed nothing on
CT 102, and step 3 changed one machine that is in the room. Put that machine's old values back and
stop; the incumbent is still serving the fleet, and the plan waits.

### 5.6 Decommissioning the incumbent

Owner-only, and only after the last machine has left it. In this order, because it is the reverse
of how much the fleet still depends on each part:

1. `rustdesk-api` on 21114. Nothing about transport depends on it.
2. `rustdesk-hbbs` on 21115 and 21116. The rendezvous has already moved.
3. `rustdesk-hbbr` on 21117. Last, because it is the transport of last resort for anything still
   pointed at it, and because LabDesk's relay wants that port.

Each is stopped, then disabled so it does not return at the next boot, then removed. **The data
directory is kept**, not deleted, until LabDesk's relay has been proven on the same container. It
holds the incumbent's peer database and its `id_ed25519` pair, and that pair is the only thing that
could bring the old server back if the cutover has to be reversed. Archive it off the container once
the replacement is proven, and remove it only then.

`unverified`: the exact unit names and the data directory path. This session held no shell inside
CT 102; the ports above were probed from outside and the service names come from the vault's record
of the community-scripts install. Establishing both is the first step of the decommissioning
package, not an assumption it may proceed on.

---

## 6. The goal, stated once

A person installs LabDesk, signs in with a lab-desk.net account, and the application works: their
machines find each other, sessions open, and nothing asks them what a rendezvous server is. A
person who installs it and does not sign in gets an application that is honest about being unable
to connect anywhere, and a clear route to fixing that. Nobody outside a LabDesk account can use
LabDesk's servers. And when two machines in the same organization both carry labnet, their traffic
never touches those servers at all.

There is a second goal underneath that one, because of where the relay now runs. The owner's own
remote access and the owner's own home network must be no worse off on the day LabDesk's public
relay is busiest than they are today. Every control in section 12.2 exists for that sentence.

---

## 7. The user's journey, both ways

Screens are named as `docs/CONSOLE.md` names them. The console declares ten sections in
`ConsoleSection` (`flutter/lib/labdesk/screens/console_shell.dart`), and the two that matter here
are **This machine** (Ctrl+9, `screens/this_machine_screen.dart`) and **Connect** (Ctrl+1,
`screens/connect_screen.dart`), with **Settings** (no shortcut, `settingsPageBody` from
`desktop_setting_page.dart`) behind them.

### 7.1 The person who signs in

1. **Install.** The installer no longer needs a `-Server` value for the ordinary case. On first
   run the application opens on the console with This machine showing no id yet, because with no
   server configured the client has nothing to register with. The status line under Connect reads
   that it is not signed in and no server is configured. It does not say `rs-ny.rustdesk.com`,
   because that string no longer exists in the build.
2. **Sign in.** The person signs in to lab-desk.net from the account surface the client already
   has (the `UserModel` login path against `get_api_server()`, which for a LabDesk build always
   resolves to `https://lab-desk.net` at `src/common.rs:1085` to `:1086`). `POST /api/login`
   returns the app bearer as it does today.
3. **The client is told which server it is on.** Immediately after a successful sign in the
   client calls a new authenticated route, `GET /api/client/server`, and writes the three values
   it returns into `custom-rendezvous-server`, `relay-server` and `key`. This is the whole of
   what changes for the user, and they see none of it except that it happens.
4. **Registration.** The mediator restarts on its own. On desktop the privileged process
   already compares `Config::get_rendezvous_servers()` against what it held and calls
   `RendezvousMediator::restart()` when it differs (`src/ipc.rs:795` and `:803`); on Android
   and iOS the same happens inside the option write itself (`src/flutter_ffi.rs:1018`, `:1028`
   and `:1030`). It then registers the id, and This machine shows the id and a green ready
   state.
5. **Enrolment, when the organization wants the machine managed.** The Organization card on This
   machine (`screens/enrol_card.dart`) takes an enrolment token an owner minted on lab-desk.net's
   `/org` page, and the privileged process spends it at `POST /agent/enrol`. After this the
   machine has its own signed identity and can be revoked by name.
6. **Connecting.** Connect lists the machines. Selecting one opens a session. If both ends carry
   labnet the session goes over the overlay address and the public server is never asked
   (section 10). If not, the session goes the way it always has, through LabDesk's rendezvous
   server and, when a hole cannot be punched, LabDesk's relay.
7. **What they can see if they look.** This machine names the server the client is on, read from
   a new FFI bind rather than from the raw option, so that the name it shows is the one the
   connection code actually resolved. Settings still holds the server profile list
   (`ServerProfilesSettings`, `flutter/lib/common/labdesk_profiles.dart:303`), so an operator with
   their own hbbs can still point a machine at it.

### 7.2 The person who does not sign in

1. **Install and open.** The console opens. This machine shows no id. Connect shows the machine
   list it can source and every action that needs a server is disabled with a reason on it, which
   is the pattern Connect already uses for a peer set it cannot source
   (`docs/CONSOLE.md`, "A set this build cannot source renders as a disabled chip carrying the
   reason").
2. **What the application says.** One sentence, in the same place the id would be:
   `Sign in to lab-desk.net to get this machine an id.` With a second line for the operator case:
   `Or set your own server under Settings, Network.`
3. **What works.** Everything that does not need a rendezvous server. A direct connection to an
   address, which the client already supports (`src/client.rs:384`, `is_domain_port_str`), a
   session to a peer on the local network by address, the terminal against such a session, file
   transfer over it. Settings, the tool catalog and the automation editor all still open.
4. **What does not work.** Registration, so no incoming connection by id. Outgoing connection by
   id, because there is no server to ask. Reachability polling, because it is a server query.
   labnet, because enrolment needs an account.
5. **What it must never do.** Silently fall back to any server the user did not choose. That is
   the behaviour being removed.

### 7.3 The screens, named

| Screen | File | What changes |
|---|---|---|
| This machine | `flutter/lib/labdesk/screens/this_machine_screen.dart` | shows the resolved server name; shows the not-signed-in sentence in place of the id |
| Connect | `flutter/lib/labdesk/screens/connect_screen.dart` | actions that need a server carry a reason when there is none |
| Organization card | `flutter/lib/labdesk/screens/enrol_card.dart` | unchanged; it is already the enrolment surface |
| Encrypted direct connections card | `flutter/lib/labdesk/screens/labnet_card.dart` | unchanged in shape; section 10 changes when it is offered |
| Network | `flutter/lib/labdesk/screens/network_screen.dart` | unchanged |
| Settings, Network | `ServerProfilesSettings`, `flutter/lib/common/labdesk_profiles.dart:303` | the seeded profile is LabDesk's public server rather than an empty host that means RustDesk's |
| Mobile settings, ID/Relay Server | `flutter/lib/mobile/pages/settings_page.dart:749` | unchanged in shape; `_isUsingPublicServer` now means LabDesk's public server |

---

## 8. Signed-in accounts only: where the enforcement can actually live

Decision 3 says a machine registers only if it carries a lab-desk.net account or an enrolment
token. Section 1.2 established that the open source `hbbs` cannot enforce that as shipped: the key
is checked on punch hole and on relay, and the RegisterPk arm has no key check at all. Say that
plainly, because the design that follows exists because of it.

The enforcement is built in two layers, and only the second satisfies decision 3 literally.

### 8.1 Layer one: the key is issued, not compiled

`RENDEZVOUS_SERVERS` becomes empty and `RS_PUB_KEY` becomes an empty string in the client, and
every fallback to them is removed (section 13). A LabDesk binary therefore ships knowing no
server and no key. The server address, the relay address and the key are handed out by
lab-desk.net in the answer to an authenticated request, and only then.

**What this prevents.** A stranger who copies the binary has no server, so the client registers
nowhere and connects to nothing. A stranger who learns the server name from a packet capture or
from this document still cannot open a session or use the relay, because `hbbs` answers
`LICENSE_MISMATCH` and `hbbr` drops the connection without the key.

**What this does not prevent.** Three things, stated because a reader will otherwise assume
otherwise.

* It does not prevent registration. Anyone who can reach UDP 21116 can take an id. That is a
  resource question, answered in section 11, not an access question.
* It does not survive a leak. The key is a shared bearer secret held by every LabDesk machine in
  plain text in that machine's config. One screenshot, one support ticket, one user reading their
  own `RustDesk2.toml` and posting it, and the key is public. It cannot be revoked for one account
  or one machine; it can only be rotated for everybody at once (section 9).
* It does not make abuse attributable. The key is the same for everyone, so a flood carrying a
  valid key names nobody.

### 8.2 Layer two: the registration gate, which needs a patched hbbs

The client already speaks the protocol for this, and neither half was written for LabDesk.

`RegisterPkResponse.Result` in `libs/hbb_common/protos/rendezvous.proto:112` carries
`NOT_DEPLOYED = 8`. The client handles it at `src/rendezvous_mediator.rs:364` to `:376`: it logs
`Server requires deployment. Run rustdesk --deploy --token <api_token> on this device.`, sets
`NEEDS_DEPLOY`, clears `key_confirmed` and `host_key_confirmed` so the interface tells the truth
about the machine not being registered, notifies the Android surface, and throttles further
registration attempts to one every `DEPLOY_RETRY_INTERVAL`, 30 seconds
(`src/rendezvous_mediator.rs:58`, `:70` to `:79`, `:748` to `:763`).

`ui_interface::deploy_device` at `src/ui_interface.rs:1081` posts
`{ id, uuid, pk }` with `Authorization: Bearer <token>` to `get_api_server() + "/api/devices/deploy"`
(`:1102`), and for a LabDesk build `get_api_server()` is always `https://lab-desk.net`
(`src/common.rs:1085`). The arm is wired at `src/core_main.rs:704` and the FFI bind
`main_deploy_device` at `src/flutter_ffi.rs:1158` exists for the mobile surfaces. All of this is
upstream RustDesk (`git log -S "deploy_device"` names commit `d99ddf681`, "Add Android device
deployment flow (#15146)", 2026-06-02), written for RustDesk Server Pro.

So the gate is: a LabDesk `hbbs` that answers `NOT_DEPLOYED` to a RegisterPk whose id and public
key it does not already hold, and a `POST /api/devices/deploy` on lab-desk.net that adds them
after checking the caller's credential.

**The `hbbs` change.** One arm, in the RegisterPk branch of `handle_udp`
(`src/rendezvous_server.rs:395` onward), before the existing uuid and rate limit logic: look the
id up in a LabDesk allow table, and when it is absent answer `NOT_DEPLOYED` through the existing
`send_rk_res` helper (`:1371`). The allow table is a small local store the Worker writes to. The
simplest shape that does not put the Worker in the registration path is a file the server reloads,
the same pattern `hbbr` already uses for `blacklist.txt` and `blocklist.txt`
(`src/relay_server.rs:45` to `:46`). A synchronous call from `hbbs` to the Worker on every
registration is rejected here: it puts a Cloudflare round trip inside a UDP handler on a
single-core VM, and it makes the Worker a hard dependency of every machine coming online.

**The lab-desk.net change.** `POST /api/devices/deploy` accepting either the app bearer, which
answers "this is a signed-in account", or an org enrolment token, which answers "this machine was
invited by an owner", and writing the id, uuid and public key into the allow table. Refusing an id
already held by another machine is what `DeployResult::IdTaken` at `src/ui_interface.rs:1070`
already renders. Revoking a machine (`POST /api/org/machines/:id/revoke`, owner only, site README
line 133) removes it from the table.

**What this buys.** Registration is gated on an account or an owner-minted token, which is decision
3 literally. Abuse becomes attributable to a row. Revocation takes a machine off the server rather
than only off the organization.

**What it costs.** A fork of `rustdesk-server`, and the AGPL obligation that comes with it.
`rustdesk/rustdesk-server` is AGPL-3.0, and section 13 of that licence requires that a modified
version offered to users over a network make its source available to those users. The LabDesk
client repository is already public and AGPL-3.0 (`gh repo view tfdan-cts/LabDesk` reads
`visibility: PUBLIC`, `licenseInfo.key: agpl-3.0`), so the project already lives under this
obligation and meeting it again costs a second public repository, not a change of posture. This is
named as an obligation rather than a decision.

### 8.3 What is honestly not enforced by either layer

* A signed-in user can register as many machines as they like unless a per-account cap is added.
  Section 11 proposes one.
* The relay is gated by the key only. A machine that is on the allow table and later revoked keeps
  a working key until the key rotates, so it can still use the relay between two ids that are both
  still registered. Revocation is not immediate at the relay. Stated rather than solved: solving it
  means a per-machine credential at the relay, which the open source `hbbr` has no concept of.
* Nothing here authenticates the *person* at session time. Session authorization between two
  machines is the client's own password and permission model, unchanged.

---

## 9. The key

**Where the pair is generated.** On the Oracle VM, by `hbbs` itself. The environment-variables document
says `-` or `_` makes the server "load a key pair from the working directory or generate one on
first start, writing `id_ed25519` (private) and `id_ed25519.pub` (public)", and that the working
directory for the supervisor Docker image is `/data`. `hbbs` defaults to `-`, so no flag is needed
to make it generate one. Generating it on the rendezvous host rather than on a workstation means
the private half never travels, and the relay host never needs it at all.

**Where the private half lives.** `/data/id_ed25519` on the Oracle VM, owned by the service user,
mode 600, inside the same volume the boot backup policy `labnet-weekly-keep3` already covers
(`docs/LABNET-SERVER.md`, "As built"). It is never copied to a workstation, never put in a Worker
secret, and never in either git repository.

The public half goes to two places: the public relay unit's `-k` on CT 102, so that relay key
validation is on rather than at its permissive default, and the lab-desk.net Worker as a secret,
so `GET /api/client/server` can hand it out. The split is an improvement here rather than a
complication: because `hbbr` only compares a string (section 1.2), the relay host never holds a
private key at all, and the host that does hold one is the hardened cloud VM rather than the
container on the owner's home network. A compromise of CT 102 yields the fleet's public key,
which is already on every LabDesk machine, and nothing else.

**Where the public half is pinned in the client.** Nowhere. This is the point that is easy to get
wrong. Pinning the public key in the client would put the credential back in the binary and undo
section 8.1, so the client ships with `RS_PUB_KEY` empty and holds a key only after it has been
given one. `Config::get_key_confirmed` (`config.rs:1090`) and the per-host
`Config::get_host_key_confirmed` (`:1106`) already track, per server, whether registration was
accepted, and `set_key_confirmed(false)` clears the per-host map (`:1100` to `:1102`), so the
client's existing bookkeeping already handles a machine that has been given a key and later finds
it wrong.

**Rotation.** Rotating the key is a fleet-wide event, because every machine holds the same string.
The sequence that does not break the fleet:

1. Mint the new pair on the Oracle VM alongside the old one.
2. Change `GET /api/client/server` to return the new public key. Every client that signs in or
   heartbeats after that point picks it up.
3. Leave `hbbs` and `hbbr` on the old key while the fleet turns over, because a client with the
   new key cannot punch a hole against a server holding the old one and would see `Key mismatch`.
4. When the fleet has turned over, switch `hbbs` on the Oracle VM and the public relay unit on
   CT 102 to the new key and restart both. They are on different hosts now, so the two restarts
   are not simultaneous and the runbook has to say which goes first: the relay, because a client
   that cannot reach the relay still punches holes, while a client that cannot pass the
   rendezvous key exchange cannot do anything. Machines still on the old key then see
   `Key mismatch` until they refresh.

The window in step 3 is the whole reason the client must refresh the key on its own rather than
only at sign in. The refresh belongs on the existing heartbeat cadence but not through the
existing strategy channel, because `SERVER_SETTABLE_OPTIONS` deliberately excludes `key`
(`src/hbbs_http/sync.rs:346`, and the test at `:578` to `:597` asserts it). It gets its own
authenticated route, and the client applies the answer itself. `unverified`: whether a rotation
can be completed without any machine seeing `Key mismatch` depends on the fleet's slowest
heartbeat, which no measurement exists for.

**Why the client must never carry upstream key material as a fallback.** Four reasons, in
increasing order of severity.

1. It is not our key. A client that falls back to `RS_PUB_KEY` is trusting a signature made by a
   key RustDesk holds, on a server RustDesk runs, over identities RustDesk's server minted.
2. It defeats the failure mode. The point of removing the fallback is that a client with no
   server configured says so. A fallback turns "misconfigured" into "silently somewhere else",
   which is exactly the shape of failure the owner's decision 1 exists to end.
3. It leaks the fleet. Every LabDesk machine that falls through registers its id, its uuid and its
   public key on `rs-ny.rustdesk.com` (`src/rendezvous_server.rs:447`, `update_pk`), which is a
   third party learning the shape of a customer's estate.
4. It is a supply chain the project does not control. RustDesk can rotate that key, retire that
   host, or change what the server does with a registration, and LabDesk would find out from a
   support ticket.

**The incumbent's key, and why it is not adopted.** The server on CT 102 has its own key pair
that the owner's machines trust today; its public half is in this workstation's live
configuration and in the vault note, and its value is deliberately not repeated here. Adopting
it for LabDesk's server would make the cutover invisible, because no machine's `key` option
would have to change at all. It is still refused. That key has been distributed for months, sits
in plain text in a vault note and in at least one configuration backup directory on this
workstation, and will remain in configurations on machines that are never converted. Section 8.1
makes the key the thing that gates every session and the relay, so starting a public service on
a key with that history would be starting it already leaked. LabDesk's server gets a new pair
from the ceremony above, and the price is that every machine has to be touched, which section
5.5 is the sequence for.

**No machine ever trusts both.** A client holds exactly one key: `Config::get_option("key")`,
returned by `get_key` at `src/common.rs:1879` to `:1898`, is a single string and there is no key
list anywhere in the client. So a machine trusts the incumbent until the moment its `key` option
is rewritten and LabDesk's server from that moment on, with no overlap. That is exactly why the
old server has to stay up until the last machine has left it rather than being switched off on a
date.

**How a machine learns the new key when the thing that would have told it is the server being
replaced.** Three routes, and only the last is self service. An operator writes it over a
session that is open at the time, which is what section 5.5 step 4 describes. An installer
carries it, which covers a machine being rebuilt anyway. Or the machine signs in to
lab-desk.net and `GET /api/client/server` hands it the host, the relay and the key together.
That last route does not depend on the server being replaced in any way, because lab-desk.net is
a Cloudflare Worker on a different plane entirely, and it is the reason P9 and P11 should land
before the cutover rather than after it: a machine that can sign in configures itself, and the
risky manual conversion is then only for machines that cannot.

---

## 10. Where labnet sits

The owner's intent is that labnet is how machines reach each other and the public server is the
fallback and the on-ramp. Today that is true in the code for one narrow case and not true in
behaviour for the general one. This section says exactly what the difference is.

### 10.1 What is already built

* The client tries the overlay address first when it has one (`src/client.rs:410` to `:415`).
* The listener binds only the overlay address when told to (`direct_server` in
  `src/rendezvous_mediator.rs`, `labdesk-direct-bind`).
* The grant, the ticket and the release exist on the Worker and in
  `flutter/lib/labdesk/services/overlay_session.dart`.
* The fall through to the rendezvous transport is the untouched original path.

### 10.2 What has to change for the intent to be true in behaviour

Four things, and none of them is a change to the direct path itself.

1. **The overlay has to be on by default for a signed-in machine, not opt in.** Today the
   Encrypted direct connections card asks once, the first time an account signs in on a machine
   that has never turned it on (`docs/CONSOLE.md`, "The switch"), and a person who declines has no
   direct path ever. If labnet is the path, the answer to that prompt has to default to yes, with
   the prompt kept for a person who wants to say no. This is a change of default, not of
   mechanism, and it is an owner decision because it changes what the product does without being
   asked. `unverified`: whether the owner wants the prompt kept at all.
2. **The grant has to be attempted before the rendezvous path, not only when a hint is already
   present.** `_start` reads a hint that the console wrote. The console writes it only in
   `_connectVia`, only after asking for a grant, and only when the switch is on for both ends. A
   session opened by any other route, and every incoming session, has no hint and goes to the
   server. Making labnet the path means the connect sequence asks for a grant whenever both ends
   are enrolled and the switch is on, and falls through in the same 1.5 second budget the design
   already sets.
3. **The public server has to be the second choice in the client's own words.** Today the log line
   for a direct path exists (`labnet: direct path to <id> at <address>`) and there is no
   corresponding statement in the interface. A session that went over labnet and a session that
   went through the relay look the same to the person who opened it. Naming the path in the
   session toolbar is what makes the fallback visible when it happens, which is what makes a
   quiet regression to the relay noticeable.
4. **The public server has to keep working perfectly for the machines that will never have
   labnet.** A machine outside any organization, a machine whose owner declined, a phone, and
   every first connection before enrolment. That is the on-ramp half of the owner's sentence and
   it is the reason this plan exists at all.

### 10.3 The order the two servers are asked in

| Case | Path |
|---|---|
| both ends enrolled, both switches on, grant answers | overlay address, direct, no server involved |
| grant answers but the address does not, within 1.5 s | LabDesk rendezvous, hole punch |
| hole punch fails | LabDesk relay |
| either end not enrolled or switch off | LabDesk rendezvous, then relay |
| no server configured, because not signed in | nothing, and the interface says so |

---

## 11. Abuse, failure and cost

### 11.1 A stranger with a copied binary

The binary carries no server and no key (section 8.1). It registers nowhere. If the stranger reads
the server name out of this document or a packet capture and sets it by hand, `hbbs` answers
`NOT_DEPLOYED` once layer two is in (section 8.2) and the client backs off to one attempt every
30 seconds and shows the deployment message. Before layer two lands, the stranger's client
registers an id and can still do nothing with it, because every punch hole answers
`LICENSE_MISMATCH` and the relay drops it.

### 11.2 A flood

Three distinct floods, and the split now puts them on two different machines with two very
different amounts of headroom.

**Registration flood on UDP 21116, at the Oracle VM.** The most likely, because it is
unauthenticated in the open source server and cheap to send. `hbbs` is not defenceless here, and
the limits are worth reading before adding more. `check_ip_blocker`
(`src/rendezvous_server.rs:912` to `:940`, called at `:379`) refuses a source address that sends
more than 30 registrations in `IP_BLOCK_DUR`, 60 seconds, and refuses a *new* id from a source
address that has already introduced more than 300 distinct ids in `DAY_SECONDS`
(`src/peer.rs:21` to `:24`). Beside it, `:419` to `:423` limits one peer to two registrations in
six seconds. A refusal answers `TOO_FREQUENT`, which the client handles.

What those limits do not cover is a flood from many source addresses, or a spoofed-source UDP
flood, where every packet still reaches the process and is parsed before the blocker sees it. The
answers, in order of how cheap they are: an `iptables` `hashlimit` on UDP 21116 per source address,
ahead of the `ACCEPT` rule, so the kernel drops the excess before the process sees it; `RMEM`
raised so a burst queues rather than drops the legitimate registration beside it; and
`TEST_HBBS=no` so a start-up self test does not fail the service during one. What the operator
sees: `hbbs` log volume and the sqlite file growing. `unverified`: no measurement exists of how
much registration traffic this one OCPU can absorb.

**Relay saturation, at CT 102.** This is the one that now lands on the owner's home connection,
and after the conversion it lands on the owner's only relay, so it is treated in 11.5 and 12.2
rather than here.
The in-process levers are `TOTAL_BANDWIDTH`, an aggregate cap across all relay connections, and
`SINGLE_BANDWIDTH` per connection, with `blacklist.txt` and the console commands `ba` and `br` to
cap one address and `blocklist.txt` with `Ba` and `Br` to refuse one outright. The defaults, 1024
Mb/s total and 128 Mb/s single, are far above anything a domestic uplink can serve and are the
single most important thing to change before the router forward is opened.

**Connection flood on the relay port.** The TCP handshake plus the key check is cheap and happens
before anything expensive, but the process still accepts the socket, and on a small container the
accept loop is the scarce thing. A `conntrack` or `hashlimit` rule at the container, plus a
connection limit at the home router if it has one, is the answer. `unverified`: what the owner's
router can express.

### 11.3 An account that goes bad

The account is a lab-desk.net row, so the levers are the ones the site already has: revoke the
machine (`POST /api/org/machines/:id/revoke`, owner only and a fresh sign in, site README line
133), delete it (`DELETE /api/org/machines/:id`, line 134), change or remove the member
(`POST /api/org/members/:id/role`, line 136), or disable the account from the admin section built
in phase 2b. With layer two in place, revocation takes the machine off `hbbs`'s allow table, so it
stops being able to register. Without layer two, revocation removes the machine from the
organization and from labnet but leaves it able to register and to use the server, because the key
it holds is still the fleet's key. That gap is the single strongest argument for layer two.

### 11.4 One host is up and the other is down

The split changed this from one failure mode into five, and the good news is in the middle of the
table: a relay outage is survivable in a way a rendezvous outage is not, because most sessions
never needed the relay.

| Situation | What the client does | What the person sees |
|---|---|---|
| both up | normal | normal |
| rendezvous up, relay down | registration and hole punching work; a session that cannot punch a hole fails at `connect_tcp` to the relay, which carries the context string `Failed to connect to relay server` (`src/client.rs:1193`) | most sessions still open; the ones behind two hard NATs do not |
| rendezvous down, relay up | nothing new registers and no new session is brokered, so the relay is never asked for one; sessions already paired on the relay keep running, because `hbbr` pairs on its own connection and does not consult `hbbs` | This machine shows the id it last had and a not ready state; open sessions survive |
| home uplink down | the relay is unreachable, so this is the relay-down row above | most sessions still open; after the conversion the owner's own machines are on this same server, so the owner is in the same position as every other user rather than a worse one |
| Oracle VM down | the rendezvous and labnet's NetBird management, signal, relay and STUN all go at once, because they are on the same box | machines already holding an overlay address and a live tunnel keep it until it needs re-signalling; everything else stops |
| key wrong on the punch hole path | `bail!("Key mismatch")` at `src/client.rs:729` | the translated string `Key mismatch` |
| key wrong on the TCP rendezvous handshake | `Signature mismatch in key exchange` at `src/common.rs:2034` | the mediator never confirms, This machine stays not ready |
| key wrong at the relay | `hbbr` returns without pairing | the connect times out with no specific reason |
| id not on the allow table | `NOT_DEPLOYED`, 30 second backoff | the deployment message, and This machine says the machine is not registered |

The last row of the outage block is the one to weigh. Putting the rendezvous on the same box as
labnet's control plane makes that box the single most concentrated failure in the whole design:
lose it and both the fallback path and the intended path lose their coordination at once. The
split helped the relay and did nothing for this. Naming it is all this plan does about it; a second
region for the control plane is a larger decision than this document.

The operator side: `hbbs` and `hbbr` log to stdout at `RUST_LOG` level, which the
environment-variables document notes must be set in the inherited process environment because both
binaries initialize logging before reading `.env`. There is no metrics endpoint in the open source
server, so the operator's view is the log, the process state and the two loopback consoles. A
minimal watch is a restart policy on each unit plus an external probe that opens TCP 21116 on the
Oracle VM and TCP 21117 on `relay.lab-desk.net` and alerts on a refusal, which also catches a
changed home address before a user does.

### 11.5 The cost question, on a domestic uplink

The relay is no longer on a cloud host with a 10 TB allowance. It is behind the owner's home
connection, and that changes the units the question is asked in: not dollars per gigabyte, but the
household's upstream bandwidth, the ISP's terms, and the owner's own network.

**What a relayed byte costs here.** Every relayed session crosses the home connection twice, in and
out, and on a domestic line the upstream direction is the scarce one. A single relayed remote
desktop session at 5 Mb/s therefore takes 5 Mb/s of upstream that the household no longer has. The
caps have to be set from a measurement of that line, not from the defaults, and the recommended
shape is `TOTAL_BANDWIDTH` at no more than a third of the measured upstream, so the household keeps
the rest, and `SINGLE_BANDWIDTH` at no more than a third of `TOTAL_BANDWIDTH`, so one session
cannot take the whole allowance. `LIMIT_SPEED` and `DOWNGRADE_START_CHECK` are lowered from 32 Mb/s
and 1800 s to bring a long transfer down sooner. `unverified`: the owner's actual upstream speed,
data cap and the terms of the connection, none of which this session could measure.

**What it does to the owner's own network.** Four things, and they are the real cost.

1. Upstream contention, above. Every other device in the house shares that line.
2. NAT state on the home router. A relay holds two long lived TCP connections per session and a
   consumer router's state table is small. A busy relay can degrade the whole household's browsing
   before it degrades itself.
3. The home address is published in DNS as `relay.lab-desk.net`, which ties the owner's home to the
   product for anyone who looks.
4. Many residential connections forbid running a public service in their terms, and a bandwidth
   spike can draw a data cap notice. `unverified` for this connection.

**What it does not do, which matters.** `hbbr` is not an open proxy. It never initiates an outbound
connection: a grep of `src/relay_server.rs` for a connect finds only inbound `handle_connection`
calls at `:350`, `:362` and `:374`, and `make_pair_` at `:461` pairs two connections that both
dialled in, matched by the uuid in their `RequestRelay`. So a stranger cannot use the relay to
reach an arbitrary host on the internet or on the owner's LAN, and the abuse complaint that
normally follows from hosting a relay, that someone used it to reach somewhere else, cannot arise
from this shape. What crosses the home line is opaque encrypted traffic between two LabDesk clients
that both hold the fleet key, and once layer two is in, between two machines that both belong to
accounts.

**The cheapest control of all.** The relay is the failure case. Every pair that reaches each other
over labnet, or punches a hole successfully, costs the home connection nothing but the setup
packets. The strongest cost control in this plan is section 10, and on a domestic uplink it stops
being an efficiency argument and becomes the thing that makes the arrangement viable at all.

---

## 12. Isolation, on the two hosts

The two hosts pose different questions and neither is glossed. The Oracle VM runs a public
service beside a private control plane the whole labnet design depends on, and that is a
coexistence problem. CT 102 runs LabDesk's relay and nothing else once the conversion is done,
so its question is not coexistence at all: it is that a public service now sits on the owner's
home connection, inside the owner's LAN, and is the owner's only relay.

### 12.1 The Oracle VM: rendezvous beside labnet's control plane

**What already helps.** `DOCKER-USER` drops container traffic to `169.254.0.0/16` and to
`10.30.20.0/24`, and drops all container egress except Traefik's route to Let's Encrypt. All three
NetBird containers run digest pinned, unprivileged, with `no-new-privileges` and `cap_drop: ALL`,
and hold no Docker socket. `/api`, `/oauth2` and the dashboard sit behind a Traefik allow list. The
host firewall default drops on INPUT and on both address families.

**What does not help, and must be built.**

1. **A shared core and a shared kernel.** A registration flood on 21116 competes for the one OCPU
   with `netbird-server`, which is what every enrolled machine's management and signal connection
   depends on. Nothing today bounds that. **Proposed:** run `hbbs` as a container with a hard CPU
   share and memory limit (`cpus`, `mem_limit`) so a public-service spike cannot starve the control
   plane, and give the control plane the larger share. This is the most important isolation control
   on this box, because it is the one an attacker does not need a vulnerability to trigger.
2. **A compromise of one reaching the other.** An exploited `hbbs` sits on the same Docker bridge as
   the NetBird containers and can reach `netbird-server` directly, bypassing Traefik and the
   `labnet-admin` allow list. **Proposed:** a separate Docker network for the public server with no
   route to `172.30.0.0/24`, expressed as an explicit `DOCKER-USER` drop between the two subnets in
   the same style as the existing "no container lateral movement into the subnet" rule, so it is
   enforced by the firewall rather than only by Docker's default inter-network policy.
3. **The same egress posture.** The `hbbs` container gets what the NetBird ones have: no route to
   `169.254.0.0/16`, no route to `10.30.20.0/24`, and no general egress, with `TEST_HBBS=no` set
   rather than discovered.
4. **Different failure domains for the data.** `hbbs` writes `db_v2.sqlite3` and its key pair into
   its own volume. It does not share `/var/lib/netbird`.

### 12.2 CT 102: a public relay on the owner's home network

The container runs LabDesk's relay and nothing else once the conversion is done, so the coexistence
problem this section used to describe is gone: there is no second instance, no split of working
directories or blocklists, and no private service on the box for public traffic to disturb. What is
left is that the relay sits on the owner's home connection and inside the owner's LAN, which is a
different question with different answers.

1. **Only the relay's port is forwarded.** The router forwards TCP 21117 and nothing else. The
   container listens on nothing else once the incumbent is removed, so there is no second service
   to reach even by mistake, and the rest of the LAN is not reachable through it.
2. **The relay cannot reach out, and should be stopped from it anyway.** `hbbr` never initiates an
   outbound connection: the only entry points are `handle_connection` at `src/relay_server.rs:350`,
   `:362` and `:374`, all from an accepted socket, and `make_pair_` at `:461` pairs two connections
   that both dialled in. So a stranger cannot use the relay to reach anything on the owner's LAN.
   An exploited process is a different matter, so the container gets a firewall rule dropping
   traffic from it to the LAN except what it needs, in the same shape as the `DOCKER-USER` rule on
   the Oracle VM. **Proposed**, owner-only. `unverified`: the LAN's full addressing beyond the
   `10.90.80.0/24` this session observed.
3. **Grow the container rather than only cap it.** The node has 20 cores and roughly 42 GB of
   memory unused, and the container's 1 core, 512 MB and 2 GB are an allocation, not a ceiling.
   Raising it to 2 cores, 1024 MB and 4 GB through the Proxmox API removes most of the pressure
   before any capping is needed. Growing an LXC's cores and memory is live, and so is growing its
   root filesystem in the increasing direction.
4. **Caps anyway, because the uplink is the real limit.** `TOTAL_BANDWIDTH`, `SINGLE_BANDWIDTH`,
   `LIMIT_SPEED` and `DOWNGRADE_START_CHECK` set from a measurement of the home connection, per
   section 11.5. On a domestic line these are not a nicety; they are the thing that keeps the
   household's browsing working while the relay is busy.
5. **It holds the fleet public key and no private key.** `hbbr` compares a string (section 1.2), so
   the relay host never needs a private half at all, and the host that does hold one is the
   hardened cloud VM. A compromise of CT 102 yields a key that is already on every LabDesk machine
   and nothing else.
6. **Bind narrowing, if the installed build supports it.** Binding the relay to the LAN address
   alone keeps it off the Tailscale interface, so the tailnet is not a second way in to a public
   service. `BIND` is documented as available since 1.1.17. `unverified`: which upstream version
   the replacement is built from is the operator's choice, so this is a build decision rather than
   an unknown, but it has to be a decision rather than an assumption.
7. **A one command retreat, with a cost that is now real.** `systemctl stop` on the relay unit and
   closing the router forward takes the public relay off the internet in one step. What is
   different after the conversion is that there is no incumbent behind it: clients then have no
   relay at all and fall back to hole punching, which is where most of them already are, and the
   owner's own machines are in that same position rather than a protected one. The retreat is still
   the right move in an emergency; it is just no longer free.

**The residual, named honestly.** The relay sits on one unprivileged LXC with `nesting=1` and
`keyctl=1`, which is the community-scripts default rather than a hardening choice, on one node,
behind one domestic uplink. A kernel bug, a container escape, an uplink saturation or a node problem
takes it out, and it takes the owner's own remote access with it, because after the conversion the
owner is a user of this server like everyone else. The structural fix is the migration to a
dedicated host that the owner has already scheduled, and until then the honest summary is that the
public relay is fenced by a single forwarded port and a resource allocation, and that both are real
but neither is a boundary.

### 12.3 The blast radius if either host is lost

The Oracle VM carries the rendezvous and labnet's whole control plane, so losing it stops
coordination on both paths at once (section 11.4). CT 102 carries the relay, and after the
conversion it is the only relay the owner has, so losing it costs LabDesk its fallback path and
costs the owner the same thing at the same moment. Neither is mitigated in this plan beyond the
existing weekly boot volume backup on the Oracle side and Proxmox's own backup on the other.

**Proposed** and owner-only, and now more pressing than it was under the coexistence design:
confirm CT 102 is in the node's backup schedule before it takes public traffic, and keep the
incumbent's archived data directory (section 5.6) somewhere that is not that container. The
container is about to become both harder to rebuild and the only thing standing between the owner
and a lost relay.

---

## 13. The client changes, by file and symbol

| # | File | Symbol | Change |
|---|---|---|---|
| 1 | `libs/hbb_common/src/config.rs:120` | `RENDEZVOUS_SERVERS` | becomes an empty slice, so the last fallback in `get_rendezvous_servers` returns nothing |
| 2 | `libs/hbb_common/src/config.rs:121` | `RS_PUB_KEY` | becomes an empty string |
| 3 | `src/common.rs:1896` | `get_key` | the `if key.is_empty()` fallback to `RS_PUB_KEY` is deleted; an empty key stays empty |
| 4 | `src/client.rs:996` | `Client::secure_connection` | `get_rs_pk(if key.is_empty() { config::RS_PUB_KEY } else { key })` becomes a plain `get_rs_pk(key)` guarded on the key not being empty |
| 5 | `src/client.rs:2158` | `LoginConfigHandler::initialize` | the `<id>@public` branch that selects `RS_PUB_KEY` is deleted; the literal has no meaning once `RENDEZVOUS_SERVERS` is empty |
| 6 | `src/client.rs:524` to `:532` | `Client::_start` | the `other_server == PUBLIC_SERVER` branch, which indexes `RENDEZVOUS_SERVERS[0]` and would panic on an empty slice, is removed with it |
| 7 | `src/common.rs:2108` | `using_public_server` | keeps its shape but is now read as "no server is configured", and all six call sites (`flutter/lib/desktop/pages/connection_page.dart:211`, `flutter/lib/labdesk/console_page.dart:159`, `flutter/lib/common/widgets/peers_view.dart:317`, `flutter/lib/mobile/pages/settings_page.dart:229` and `:753`, `flutter/lib/common/widgets/dialog.dart:1978` and `:1981`, `flutter/lib/desktop/pages/desktop_setting_page.dart:1685`) are re-read so that a poll interval, a hidden quality control and a hidden settings row are not chosen by a value that changed meaning |
| 8 | `src/flutter_ffi.rs` | `main_get_rendezvous_server` (new) | a bind returning `Config::get_rendezvous_server()`, the resolved value rather than the raw option, so a screen can name the server the client is on. A search of the whole repository and of every branch (`git log --all -S`) finds no such symbol today, so this is new rather than moved. The iOS session needs it because iOS reads config in process (`src/common.rs:1886` to `:1887` takes the option directly on iOS rather than over IPC) and has no other way to name the server |
| 9 | `src/hbbs_http/sync.rs` | new `server_config` fetch | an authenticated call on the existing heartbeat cadence that reads `GET /api/client/server` and applies `custom-rendezvous-server`, `relay-server` and `key` itself. It does not go through `SERVER_SETTABLE_OPTIONS`, which excludes all three on purpose (`:346`), and the test at `:578` that asserts the exclusion stays as it is |
| 10 | `flutter/lib/models/user_model.dart` | the sign-in success path | calls the same fetch once immediately, so a fresh install is configured at sign in rather than at the next heartbeat |
| 11 | `flutter/lib/common/labdesk_profiles.dart:150` to `:159` | `ServerProfilesModel._migrate` | the seeded `Default` profile carries LabDesk's public server rather than empty strings, and the subtitle at `:342`, which reads `Public server` for an empty host, keeps that text but now means LabDesk's |
| 12 | `flutter/lib/labdesk/screens/this_machine_screen.dart` | the identity block | names the server from bind 8, and shows the not-signed-in sentence in place of the id |
| 13 | `flutter/lib/labdesk/screens/connect_screen.dart` | the action row | disables server-dependent actions with a reason when no server is configured |
| 14 | `install.ps1:304` to `:309`, `install.sh:193` | the settings block | unchanged in mechanism; the documentation around them stops implying that omitting `-Server` means the public RustDesk server |
| 15 | `src/core_main.rs:704`, `src/ui_interface.rs:1081` | `--deploy`, `deploy_device` | unchanged. They already post to `https://lab-desk.net/api/devices/deploy`; only the server half is missing |

Nothing is needed for the rendezvous and the relay being on different hosts. `get_relay_server` at
`src/rendezvous_mediator.rs:825` to `:834` already prefers the `relay-server` option, then what
the rendezvous server advertised, then the rendezvous host's port plus one, so a relay on another
host at a non-default port is served by the first two of those three and the third is never
reached. That is the whole reason the split costs no client code.

Two things deliberately not changed. `EXE_RENDEZVOUS_SERVER` and the renamed-executable path stay,
because they are how a customer-specific build points itself at a customer's own server. And
`ServerProfilesSettings` stays, because an operator with their own hbbs must still be able to use
it.

---

## 14. Work packages

Same shape as `docs/plans/2026-09-04-003-rmm-architecture.md` section 9: each package owns its
files exclusively, so any set with satisfied dependencies runs in parallel, and every package names
a runnable verifier. Cargo does not build this crate on the development workstation, so every Rust
verifier is a CI run.

| WP | Owns | Depends on | Verifier |
|---|---|---|---|
| **P1. The rendezvous, stood up** (owner-only) | the Oracle VM: the `hbbs` unit or compose file, its `/data` volume, key pair generation, `TEST_HBBS=no`, and a temporary `hbbr` on 21117 for the length of the cutover, with `hbbs` started without `-r` so clients derive it | none | `ss -tulnH` on the VM shows 21115, 21116 TCP and UDP and 21117; from the workstation a TCP connect to 21116 succeeds and a client holding the right key reaches `key_confirmed`, and a forced-relay session between two machines completes without CT 102 being touched |
| **P2. Rendezvous firewall and security group** (owner-only) | `/etc/iptables/rules.v4`, `DOCKER-USER`, the Oracle NSG `labnet-netbird` | P1 | an external port scan from the workstation shows exactly 443, 21115, 21116 and, for the length of the cutover only, 21117 open on that host and nothing else, repeated after a deliberate reboot because a rule that survives only until the next restart is not a rule; the same scan is run again after P7 and must then show 21117 closed here |
| **P3. Rendezvous isolation** (owner-only) | the second Docker network, the CPU and memory limits, the two `DOCKER-USER` drops between subnets | P1, P2 | from inside the `hbbs` container's network namespace, `netbird-server` is unreachable and `169.254.169.254` answers nothing; `docker stats` under a synthetic registration load shows the control plane still scheduled |
| **P4. CT 102 headroom** (owner-only) | the Proxmox config for CT 102: `cores`, `memory`, `rootfs` size | none | the Proxmox API reads back `cores 2`, `memory 1024` and a 4 GB rootfs, and the incumbent's services are still answering on 21114 through 21117 over Tailscale afterwards, because this package runs before the fleet has moved |
| **P5. LabDesk's relay on CT 102** (owner-only) | the `hbbr` systemd unit on CT 102, its working directory, `blocklist.txt`, `blacklist.txt`, `-p 21117`, LabDesk's public key, and the container's outbound firewall rule | P4, P8, P21 | `ss -tulnH` inside CT 102 shows 21117 and nothing from the incumbent; `printf 'tb' \| nc 127.0.0.1 21117` reads back the configured total; a forced-relay session between two converted machines completes through it; `systemctl stop` takes the relay off in one step and clients fall back to hole punching |
| **P6. Bandwidth caps from a measurement** (owner-only) | the public relay unit's `TOTAL_BANDWIDTH`, `SINGLE_BANDWIDTH`, `LIMIT_SPEED`, `DOWNGRADE_START_CHECK` | P5 | the home connection's upstream is measured first and the number recorded; the console reads back a total at no more than a third of it; a scripted transfer is capped at the configured single |
| **P7. The router forward and DNS** (owner-only) | one port forward for TCP 21117 on the home router, the `relay.lab-desk.net` `A` record with the proxy off, the dynamic update for it | P5, P6 | from outside, TCP 21117 on `relay.lab-desk.net` answers and 21114, 21115, 21116, 21118, 21119 and 443 are still closed, which is the same probe section 5.2 ran and is the before and after pair; the dynamic updater is proven by changing the record by hand and watching it be corrected |
| **P8. The key ceremony** (owner-only) | `id_ed25519` and `id_ed25519.pub` on the Oracle VM, the public half into the Worker secret and into the relay unit | P1 | the same public key string reads back from the `hbbs` working directory, from the relay unit's environment and from `GET /api/client/server`, and the private half exists in exactly one place |
| **P9. `GET /api/client/server`** | `src/worker/routes/client-api.ts`, `wrangler` secrets `LABDESK_RENDEZVOUS_HOST`, `LABDESK_RELAY_HOST`, `LABDESK_SERVER_KEY` | none | `npx vitest run test/client-server.test.ts`: an unauthenticated call answers 401, an expired bearer answers 401, a valid bearer answers the three fields with the relay carrying its non-default port, and the key is absent from every other route's answer |
| **P10. Client: remove the upstream fallback** | `libs/hbb_common/src/config.rs` (two constants), `src/common.rs` (`get_key`), `src/client.rs` (rows 4, 5, 6 of section 13) | none | `cargo test` in CI, plus a new test asserting that `Config::get_rendezvous_server()` with no option set returns an empty host rather than `rs-ny.rustdesk.com`, and a grep gate in CI that fails the build if `rustdesk.com` appears in `libs/hbb_common/src/config.rs` |
| **P11. Client: fetch and apply the server config** | `src/hbbs_http/sync.rs` (the new fetch only), `flutter/lib/models/user_model.dart` (the sign-in hook only) | P9, P10 | `cargo test` for the parse and apply, asserting that all three keys are written, that the relay keeps its explicit port, and that nothing else in the answer is applied; the existing `sync.rs` exclusion test stays green |
| **P12. The FFI bind and the screens** | `src/flutter_ffi.rs` (`main_get_rendezvous_server` only), `flutter/lib/labdesk/screens/this_machine_screen.dart`, `flutter/lib/labdesk/screens/connect_screen.dart`, `flutter/lib/common/labdesk_profiles.dart` | P10 | `flutter analyze` and `flutter test`, with a widget test asserting the not-signed-in sentence renders when the bind returns an empty host; the generated bridge is regenerated in the same commit |
| **P13. `POST /api/devices/deploy` and the allow table** | `src/worker/routes/client-api.ts` (the deploy route), the allow table schema and its migration, the publish path to the Oracle VM | P9 | `npx vitest run test/deploy.test.ts`: an app bearer deploys, an enrolment token deploys, neither deploys an id another machine holds, a revoked machine is absent from the published table |
| **P14. The `hbbs` fork** (owner-only to publish) | a public `tfdan-cts/labdesk-server` fork: one arm in the RegisterPk branch, the allow table reader, the AGPL notice | P13 | a unit test in that repository: a RegisterPk for an id on the table answers `OK`, one for an id not on it answers `NOT_DEPLOYED`; then, against the real VM, a client with an unlisted id logs the deployment message and backs off to one attempt every 30 seconds |
| **P15. labnet first** | `flutter/lib/labdesk/services/overlay_session.dart`, `flutter/lib/labdesk/screens/labnet_card.dart` (the default only) | none | `flutter test`, plus the field measurement: two enrolled machines, the zenbook log line `labnet: direct path to <id>` at a `100.64.0.0/10` address, and no `rendezvous server:` line for that session |
| **P16. Name the path in the session** | `flutter/lib/labdesk/theme/session_toolbar_skin.dart` and the session surface it skins | P15 | a widget test per path, and a field check that a relayed session and an overlay session read differently |
| **P17. Rotation runbook** | `docs/LABNET-SERVER.md` (a new section covering both hosts) | P1, P5, P8, P9 | a rehearsed rotation with one test machine: it picks up the new key from `GET /api/client/server`, and the switch on `hbbs` and on the public relay unit is done and read back |
| **P18. The migration runbook** | `docs/LABNET-SERVER.md` (the relay migration section) | P5, P7 | a dry run on paper against the real record and the real `-r` flag, reviewed against section 5.4; the runbook is what the owner follows when the dedicated host exists |
| **P19. Documentation** | `docs/CONSOLE.md`, `docs/SECURITY-POSTURE.md`, `README.md`, `install.ps1` and `install.sh` help text | P10, P12 | a documentation pass that reads every changed sentence against the code it describes, in the same commit as the change |
| **P20. The fleet cutover** (owner-only) | no files; the configuration of every machine currently on the incumbent | P1, P8, P9, P11 | the machine list is built first, with each machine's out-of-band path recorded beside it; then each machine is confirmed online on the new rendezvous before the next is touched, and a forced-relay session to it completes; the incumbent is left running throughout, and the package is done when nothing live is registered on it |
| **P21. Decommission the incumbent** (owner-only) | the `rustdesk-api`, `rustdesk-hbbs` and `rustdesk-hbbr` units on CT 102 and their data directory | P20 | the unit names and data directory path are established first, since section 5.6 marks both unverified; then, from the workstation, 21114, 21115, 21116 and 21117 no longer answer at `100.71.21.102`; the three units read `disabled`; and the data directory, including the incumbent's `id_ed25519` pair, is archived off the container before anything is deleted |

**Parallelism.** P1, P4, P9, P10 and P15 start immediately. P2 and P3 follow P1. P8 follows P1 and
feeds P9 and P20. P11 needs P9 and P10. P12 needs P10. P13 needs P9, and P14 needs P13. P17 and
P18 come last because they document what the others built.

**The one serial chain, and it is the important one.** P1 and P8, then P9 and P11 so that a
machine can configure itself by signing in, then P20 to move the fleet, then P21 to remove the
incumbent, then P5, P6 and P7 to put LabDesk's relay on the port the incumbent has just given up.
Nothing in that chain may be reordered, because each step is what makes the next one safe: the
new server exists before anything moves, the fleet has left before anything is removed, and the
port is free before anything binds it.

**Owner-only.** P1 through P8, P20 and P21 touch the Oracle tenancy, the Proxmox node, the
container the owner's own server runs on, the configuration of the owner's own machines, the home
router and public DNS. P14's publication is a new public repository under the owner's account, and
the AGPL obligation in section 8.2 makes publication part of shipping it rather than optional. The
key ceremony in P8 is owner-only for the same reason the NetBird service token was.

**Nothing in this plan is deployed to either host by an agent.** P20 and P21 are the sharpest
case: P20 changes the configuration of machines the owner reaches through the server being
replaced, and P21 removes a server those machines used that morning. Both are run by the owner,
in the order section 5.5 sets, with the incumbent left running until the last machine has left
it.

---

## 15. What could go wrong with the plan itself

1. **The registration gate is a fork, and a fork is a maintenance liability.** Every upstream
   `rustdesk-server` release has to be re-based onto one arm in one function. The arm is small and
   sits in a function that has been stable, but the risk is real and it compounds over years.
   The mitigation is that the change is one `if` and one call to an existing helper, and that the
   allow table is a file rather than a schema change.
2. **The key is a shared bearer secret, and no amount of design makes it not one.** The open
   source server has exactly one credential and every machine holds it. Layer two gates
   registration, which is what the owner asked for, but the relay stays gated only by the shared
   key. A design that fixes this properly needs a per-machine credential at the relay, which means
   a larger fork than one arm, and it is not proposed here.
3. **Removing the fallback is a one way door for existing installs.** A machine currently running
   with no `custom-rendezvous-server` is on `rs-ny.rustdesk.com` and has an id there. After the
   update it has no server until someone signs in. If any machine in the field is in that state,
   the update silently disconnects it. `unverified`: whether any installed LabDesk is currently
   using the upstream default. The mitigation is a migration on first run after the update that
   detects an empty server and shows the sign-in sentence rather than failing silently.
4. **Both hosts are single core, and that is the plan's weakest physical assumption.** Section
   12.1 proposes CPU shares on the Oracle VM and section 12.2 proposes them on CT 102, but no
   measurement exists of what a registration flood costs on the first shape or what a busy
   relay costs on the second. If either is worse than expected the answer is more allocation,
   which CT 102 has available on its node and the Oracle VM does not.
5. **`GET /api/client/server` becomes a new hard dependency.** A client that cannot reach
   lab-desk.net after a fresh install has no server. Today the same client would at least have
   found RustDesk's. That is the intended tradeoff, but it means the site's availability is now
   the client's availability, and the site is one Worker.
6. **The `<id>@public` syntax is a documented RustDesk feature that this plan deletes.** Anyone
   who has that in a saved peer or a script gets a broken id. It is unlikely to be in use in a
   LabDesk fleet but it is a behaviour change worth naming.
7. **The AGPL obligation is easy to forget.** A modified `hbbs` running as a network service and
   not published is a licence violation. Making publication part of P14's definition of done is
   the mitigation.
8. **Making labnet the default changes what the product does without being asked.** Section 10.2
   flags it as an owner decision rather than deciding it.
9. **The cutover is the riskiest thing in this plan, and it is the owner's to run.** Every machine
   has to leave a server it is reached through, one at a time, and a machine that does not come
   back on the new server is gone unless it has another path. Section 5.5 orders it so that the
   incumbent is still running throughout, and names the timed rollback for machines with no
   tailnet and no labnet. The residual risk is a machine nobody remembered had no other path.
10. **Converting CT 102 removes the owner's own fallback.** Until now the owner had a private
    RustDesk server that was nobody else's business. Afterwards the owner is a user of the public
    service, sharing its uplink, its caps and its outages with strangers. That is what the owner
    asked for, and it is worth writing down that it is a real loss of independence rather than a
    tidy-up. The mitigation is P6's measurement before P7's forward, and the one command retreat.
11. **A domestic uplink is a worse place for a relay than a cloud host, in every way except cost.**
    Asymmetric bandwidth, a consumer NAT table, a possible data cap, terms that may forbid it, and
    an address that changes. The plan sets caps and a dynamic DNS update against those, but the
    honest position is that this arrangement is a stopgap the owner has already scheduled a
    migration away from.
12. **Publishing the home address in DNS is not reversible in the way a config change is.** Once
    `relay.lab-desk.net` has pointed at it, that association is in passive DNS history for good.
13. **The Oracle VM now carries two of the three legs.** The rendezvous and labnet's whole control
    plane are on one box, so the split improved the relay's failure independence and left the more
    concentrated failure exactly where it was (section 11.4).

---

## 16. What could not be verified

* Oracle's 10 TB free outbound allowance and the $0.0085 per GB North America rate. Both Oracle
  pages answer HTTP 403 to a direct fetch from this workstation; the figures come from Oracle's
  own pages as returned in search results on 2026-09-05.
* What the rest of the Oracle tenancy currently spends against that allowance.
* How much registration or relay traffic this one OCPU can absorb. No measurement exists, and none
  was taken, because taking one means load on a live control plane.
* Whether any installed LabDesk in the field is currently registered on `rs-ny.rustdesk.com`. No
  telemetry answers this.
* Whether a key rotation can be completed with no machine seeing `Key mismatch`. It depends on the
  fleet's slowest heartbeat, which is not measured.
* Whether the owner wants the Encrypted direct connections prompt kept once the default flips to
  on (section 10.2, item 1).
* The owner's upstream bandwidth, data cap, ISP terms and what the home router can express for
  connection limiting. None of these could be measured from this session, and P6 and P7 depend on
  the first of them.
* Which upstream `hbbr` version the community-scripts package installed in CT 102, and therefore
  whether `-b` is available for binding the public relay to the LAN address alone (section 12.2,
  item 6). The vault records the package version 0.1.2, which is the packaging version and not the
  upstream one.
* Whether CT 102 is in the Proxmox node's backup schedule. It is about to become harder to rebuild
  than it is today (section 12.3).
* The exact systemd unit names on CT 102 and the path of the incumbent's data directory. This
  session held no shell in the container: the ports were probed from outside and the service
  names come from the vault's record of the community-scripts install. Establishing both is the
  first step of the decommissioning package rather than something it may assume.
* How many machines are on the incumbent, and which of them have a tailnet or labnet path. Only
  this workstation's configuration was read. The cutover in section 5.5 cannot be scheduled until
  that list exists, and building it is the first step of P20.
* The incumbent's public key is **not** in this list any more: it was read from this
  workstation's live configuration on 2026-09-05 and matches what the vault recorded on
  2026-04-24, so the vault's value is confirmed. Its private half is on CT 102 and was not
  inspected.
* The node's free memory as reported here (62.1 GB total, 19.4 GB used) differs from the figure
  this plan was handed (66.7 GB with 16.3 GB free), which matches the node's root filesystem
  instead (66.4 GB with 18.2 GB used). The readings in section 5.2 are this session's own, taken
  from `/nodes` and `/nodes/traphouse/status` on 2026-09-05, and either way the headroom argument
  holds.
* Nothing in this plan has been compiled or run. Cargo does not build this crate on the
  development workstation, and no change has been made to either host, to lab-desk.net or to any
  client. The Oracle VM and the Proxmox API were read from and nothing was written to either.
  Every line number here was read on 2026-09-05 and will move.
