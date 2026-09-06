# The labnet server

labnet, LabDesk's encrypted direct path, runs on a NetBird control plane that
LabDesk hosts itself: management, signal, relay and STUN in one container,
behind Traefik, on one small Linux VM. Clients never talk to lab-desk.net
about it except to be told which server to register with; the server's API
token lives only in the lab-desk.net Worker.

This is the runbook for standing that server up and for handing its token to
the Worker. Everything a client does is in `docs/CONSOLE.md`.

## What the VM needs

Verified against NetBird's own documentation and the v0.78.0 source:

- A Linux VM with at least 1 CPU and 2 GB of memory. The Oracle free tier
  shape the owner chose (2 CPU, 12 GB) is well above that.
- A public name that resolves to the VM: `nb.lab-desk.net`. Add it in
  Cloudflare DNS as an `A` record with the proxy **off** (grey cloud). The
  clients speak gRPC over HTTP/2 and STUN over UDP, neither of which goes
  through Cloudflare's proxy.
- Inbound TCP 80 and 443, and inbound UDP 3478, open on the VM's firewall and
  on the Oracle security list. Oracle's default list drops UDP; without 3478
  peers still connect, but relayed rather than direct.
- Docker with the compose plugin, `curl`, `jq`.

## Install

```
curl -fsSL https://github.com/netbirdio/netbird/releases/download/v0.78.0/getting-started.sh | bash
```

Pick the bundled Traefik when asked. The script writes `docker-compose.yml`,
`config.yaml` and `dashboard.env` and starts three containers: `traefik`,
`dashboard` and `netbird-server`. TLS comes from Let's Encrypt over port 80.

Then open `https://nb.lab-desk.net`. With no users yet it redirects to
`/setup`, where the first admin account is created. No external identity
provider is needed; NetBird keeps local users itself since 0.62.

## Make the network closed by default

A fresh NetBird account carries a policy named `Default` that lets every
peer reach every other peer. labnet is built on the opposite: a machine is
reachable by nobody until a session rule or a labnet says otherwise. Delete
that policy before any machine enrols. In the dashboard: Access Control,
Policies, delete `Default`. Or by API, once the token below exists:

```
curl -H "Authorization: Token $NETBIRD_TOKEN" https://nb.lab-desk.net/api/policies
curl -X DELETE -H "Authorization: Token $NETBIRD_TOKEN" https://nb.lab-desk.net/api/policies/<id>
```

The Worker refuses to enrol anything while a policy with the `All` group as a
source still exists, so a forgotten step shows up as a plain sentence on the
first machine, not as an open network.

## The Worker's token

Create a service user in the dashboard (Team, Service Users) and a personal
access token for it. Store it on the Worker without ever putting it on a
command line that a transcript records:

```
cd labdesk-site
wrangler secret put NETBIRD_API_URL     # https://nb.lab-desk.net
wrangler secret put NETBIRD_TOKEN       # the personal access token
```

Both are read at request time; nothing needs a redeploy.

## Prove it

From any machine:

```
curl -H "Authorization: Token $NETBIRD_TOKEN" https://nb.lab-desk.net/api/peers
```

answers `200` and `[]` before the first enrolment, and
`https://nb.lab-desk.net/api/policies` answers `[]` once `Default` is gone.
After the first machine turns on encrypted direct connections under This
machine, `netbird status --json` on it reports `management.connected: true`
and `signal.connected: true`.

## What the clients are told

The Worker hands each enrolling machine the management address it holds in
`NETBIRD_API_URL` and a one-off setup key it created for that machine's own
group. Nothing else about the server reaches a client.

## As built, 2026-09-03

The server exists. What follows is what was done, so the next person does not repeat it.

- Oracle Cloud, tenancy `trapadmin`, region us-chicago-1, availability domain 1. Instance
  `labnet-netbird`, `VM.Standard.A1.Flex` with 1 OCPU and 6 GB, Ubuntu 24.04 Minimal aarch64,
  50 GB boot volume. Public address `64.181.204.25`, private `10.30.20.160`. This VM bills
  (the tenancy's free A1 hours are used by other instances): $0.01 per OCPU-hour plus
  $0.0015 per GB-hour, about $14 a month.
- Its own network security group, `labnet-netbird`: ingress 443/tcp and 3478/udp from anywhere
  (80/tcp was removed the same night, see the exposure table below); the VCN's shared security
  list was left alone. The host firewall carries the same two ports, persisted in
  `/etc/iptables/rules.v4` (Oracle's images reject by default).
- SSH from the workstation goes through the Safe Sight backend as a jump host:
  `ssh -J ubuntu@100.111.222.91 ubuntu@10.30.20.160`. Port 22 is reachable only from inside
  the subnet.
- `nb.lab-desk.net` is an `A` record to the public address, proxied off.
- Installed with `getting-started.sh` from the v0.78.0 release, unattended
  (`NETBIRD_DOMAIN`, `NETBIRD_LETSENCRYPT_EMAIL=mgmtsrvr@lab-desk.net`,
  `NETBIRD_REVERSE_PROXY_TYPE=0`, `NETBIRD_NON_INTERACTIVE=true`) as root, in
  `/home/ubuntu/netbird/`. Three containers: `netbird-traefik`, `netbird-server`,
  `netbird-dashboard`. Certificate from Let's Encrypt, valid to 2026-12-03 and renewed by
  Traefik.
- The first admin was created through the setup API with `NB_SETUP_PAT_ENABLED=true` set on
  `netbird-server` for that one step and removed afterwards. Admin: `trapadmin@proton.me`,
  password in `/root/netbird-admin.txt` on the VM, mode 600, nowhere else. Sign in at
  `https://nb.lab-desk.net`.
- Service user `lab-desk-net` (admin) with token `labdesk-worker`, valid to 2027-09-04, in
  `/root/netbird-labdesk-token` on the VM (mode 600) and on the lab-desk.net Worker as
  `NETBIRD_TOKEN`, alongside `NETBIRD_API_URL=https://nb.lab-desk.net`. Renew before it expires.
- The default all-to-all policy was deleted. Verified from outside: `GET /api/peers` 200 `[]`,
  `GET /api/policies` `[]`, a STUN binding request to UDP 3478 answered.

## What is exposed, and why each port exists (verified 2026-09-03)

The owner asked whether the open ports are needed at all. Each was checked against the
server's own configuration and the client source, not the installer's summary.

| Port | Verdict | Evidence |
|---|---|---|
| 80/tcp | **Closed.** | Traefik obtains certificates by TLS-ALPN on 443 (`--certificatesresolvers.letsencrypt.acme.tlschallenge=true`), so 80 only served an HTTP-to-HTTPS redirect. Removed from Traefik, the host firewall and the security group. |
| 443/tcp | **Open, and necessary; the admin paths on it are fenced.** | Peers register and receive their network map over gRPC (`/management.ManagementService/`), exchange connection candidates over gRPC (`/signalexchange.SignalExchange/`), and fall back to the relay over WebSocket (`/relay`, `/ws-proxy/`). Every one of those is TLS, and a peer authenticates with its one-off setup key and its WireGuard key; the server never holds a peer's private key and cannot read relayed traffic. The daemon never calls `/api` or `/oauth2` (no code path in `client/` does), so `/api`, `/oauth2` and the dashboard sit behind a Traefik IP allow list: Cloudflare's published ranges (the lab-desk.net Worker's calls arrive from 172.69.x, measured with a probe Worker), the VM's own address and its Docker network. From anywhere else they answer 403. |
| 3478/udp | **Open, kept by owner decision (2026-09-03).** | STUN. A peer sends one small request and learns the public address and port its NAT gave it, which is what lets two machines behind two NATs connect directly. The server can replace it with external STUN (`server.stuns` in `config.yaml`; the embedded listener switches off when external servers are listed, `combined/cmd/config.go`), or run without STUN (peers then meet only through the relay on 443). |
| 22/tcp | Reachable from inside the subnet only (the shared security list allows it from 10.30.20.8, the jump host). | |
| 111 (rpcbind) | **Disabled.** Ubuntu's default `rpcbind` was listening on every interface for nothing this server does. | |

Operator access to the dashboard and API now goes through the box: from the VM itself
(`curl https://nb.lab-desk.net/api/...`), or through an SSH tunnel from the workstation:

```
ssh -J ubuntu@100.111.222.91 -L 8443:localhost:443 ubuntu@10.30.20.160
```

then `curl --resolve nb.lab-desk.net:8443:127.0.0.1 https://nb.lab-desk.net:8443/api/users`
(the routers match on the host name, so the name must be kept). A browser needs a hosts-file
entry for the same reason.

What the design does not do: expose the network. A machine that enrols becomes reachable to
nobody until a session rule or a labnet names it, and the data path between two machines is
WireGuard between those two machines. The control plane coordinates; it does not carry.

## Hardened, 2026-09-04

The owner asked for one thing: that this VM not be a way in. Seven checks were set as the bar,
and each one below is answered by a measurement taken after the change, not by the config that
was written. Every measurement was repeated after a deliberate reboot, because a rule that only
survives until the next restart is not a rule.

| # | The bar | Measured result |
|---|---|---|
| 1 | From the internet, only 443/tcp and 3478/udp answer | A connect scan of 47 common TCP ports from the workstation returns exactly one open port, 443. Twelve UDP ports are silent to a garbage payload, and 3478 answers a real RFC 5389 binding request with the caller's reflexive address. |
| 2 | SSH key-only, no root, subnet only | `sshd -T` reads back `passwordauthentication no`, `permitrootlogin no`, `pubkeyauthentication yes`, `allowusers ubuntu`, `maxauthtries 3`, `x11forwarding no`, `loglevel VERBOSE`. The host firewall now accepts 22 only from `10.30.20.0/24`, so the security list is no longer the only thing holding that line. |
| 3 | Default drop on INPUT, and the Docker forwarding path closed | `iptables -S INPUT` starts with `-P INPUT DROP`, and the trailing REJECT was kept so a probe still gets an answer rather than a hang. `ip6tables` drops INPUT and FORWARD, which is safe because the VM has no global IPv6 address. `DOCKER-USER` is no longer empty. |
| 4 | Automatic security updates with reboot | `unattended-upgrades` is enabled and active, `Automatic-Reboot "true"` at 04:30. Twenty pending updates were applied by hand first, including `openssl`, `openssh-server`, `libssh` and `zlib`, and `apt list --upgradable` is now empty. |
| 5 | Containers pinned by digest, unprivileged, no new privileges | All three run from a digest, all three report `privileged=false` and `[no-new-privileges:true]` under `docker inspect`. |
| 6 | Kernel network hardening applied and readable back | `/etc/sysctl.d/90-labnet.conf` survives the reboot and reads back live. |
| 7 | A Lynis audit whose remaining findings are defensible | The hardening index moved from 64 to 76. The vulnerable-package warning is gone. The findings that remain are listed below with the reason each was left. |

### What changed

- The host firewall now default-drops. Port 80 was still accepted here even though Traefik had
  stopped serving it and the security group had closed it, so the rule was removed. Port 22 was
  narrowed from anywhere to the subnet. `ip6tables` was given a loopback and established rule and
  then set to drop.
- `DOCKER-USER` was empty, which matters because Docker's forwarding path bypasses INPUT for
  published ports. It now carries an explicit default: established traffic returns, anything not
  arriving on the public interface returns, 443/tcp and 3478/udp return, and everything else from
  the public interface is dropped. A future `-p` on a container cannot open itself to the internet.
- Traefik was running v3.6, which reached end of life on 2026-08-16 and no longer receives
  security patches. It now runs v3.7.12. The one breaking change in that range that touches this
  configuration is that Traefik no longer forwards `Upgrade: h2c` headers to backends, and this
  compose file already declares the gRPC backend with `loadbalancer.server.scheme=h2c`, which is
  the supported form.
- All three containers are pinned by digest rather than by a moving tag: `traefik:v3.7.12`,
  `netbirdio/dashboard:v2.92.0`, `netbirdio/netbird-server:0.78.0`. The server digest matches the
  v0.78.0 source vendored in this repository. Each also carries `no-new-privileges:true`.
- `fail2ban` guards sshd. Its bans land in the nftables table `inet f2b-table` on the input hook
  at priority `filter - 1`, not in iptables, which is worth knowing before concluding it does
  nothing. A test ban was placed and removed to prove the action writes a real rule.
- `auditd` was enabled with an empty ruleset, which watches nothing. It now watches the identity
  files, the sudoers tree, the sshd configuration, the saved firewall rules, the compose file and
  the Docker socket.
- Core dumps are off, `UMASK` is 027, and `/etc/issue` and `/etc/issue.net` carry a banner.
- An Oracle boot-volume backup policy, `labnet-weekly-keep3`, is assigned to the boot volume:
  incremental, Sundays at 04:00 UTC, kept 21 days. A full backup named `labnet-netbird-initial`
  exists and reached `AVAILABLE`, so a restore point exists today rather than next Sunday. The
  earlier attempt failed with "You must specify the offset for offsetType null"; the schedule
  needs `offset_type="STRUCTURED"` alongside `day_of_week` and `hour_of_day`.

### Findings left open, and why

- **Lynis PKGS-7388, "can't find any security repository".** False. `noble-security` is
  configured in `/etc/apt/sources.list.d/ubuntu.sources`, and twenty packages were installed from
  it. Lynis does not parse the deb822 format that Ubuntu 24.04 uses.
- **STUN on 3478/udp served by this box.** Owner decision, recorded above. The relay is TCP and
  cannot reflect the UDP mapping WireGuard needs, public STUN would hand peer addresses to a third
  party, and relay-only forfeits the direct path.
- ~~Traefik mounts the Docker socket read-only.~~ NO LONGER TRUE, and it was never as safe as this
  entry claimed. The `:ro` flag freezes the mount point, not the socket inode, so the process could
  still write to the Docker API, which is host root. The Docker provider was deleted rather than
  wrapped and the socket mount is gone; routing moved to a file provider. See "The Docker socket,
  and why Traefik no longer has one" below. The entry is kept struck through because the reasoning
  in it is exactly the kind that should not be trusted again.
- **`AllowTcpForwarding` stays on.** An SSH tunnel is the operator's only ad-hoc route to the
  dashboard, which is fenced to Cloudflare's ranges and the box itself. SSH is key-only, subnet
  only and watched by fail2ban, so the pivot this would open is already behind three doors.
- **No GRUB password.** Reaching the serial console requires Oracle tenancy credentials, which is
  already a larger compromise than anything a boot password would prevent.
- **Read-only container roots not set.** Traefik writes `acme.json`, the server writes
  `/var/lib/netbird`, and the dashboard's nginx writes its cache and run directories. Each would
  need its own tmpfs mounts for a gain that `no-new-privileges` and an unprivileged user already
  cover. Left as a deliberate choice rather than an oversight.
- **Separate partitions for /home, /tmp and /var, a malware scanner, process accounting, remote
  log shipping, password ageing and PAM strength modules.** This host has no password logins and
  one service. These raise the Lynis score without reducing the ways in.
- **The subnet's shared security list is wider than this VM's own security group.** The group
  `labnet-netbird` allows only 443/tcp and 3478/udp, but Oracle evaluates a security group and a
  security list as a union, and the subnet's default list (shared with the Safe Sight instances)
  also allows 444/tcp and 41641/udp from anywhere. Nothing on this VM listens on either, and the
  host firewall drops both, which the external scan confirms. The list was left alone because it
  is shared: narrowing it would change the other instances on that subnet. Worth knowing that the
  host firewall, not the cloud edge, is what closes those two ports here.

### One claim that was false

`fs.suid_dumpable` was recorded as hardened to 0 the night before. The file
`/etc/sysctl.d/90-labnet.conf` did say 0, but the running kernel said 2, because Ubuntu's
`apport` sets it back to 2 when it starts. A sysctl written to a file is not a sysctl applied.
`apport` is a desktop crash reporter with nothing to do on this server; it is now disabled and
`enabled=0` in `/etc/default/apport`, `fs.suid_dumpable` reads 0 live, and `kernel.core_pattern`
is back to `core` instead of a pipe into apport. Read every hardening value back from the running
kernel, never from the file that was written.

### The Docker socket, and why Traefik no longer has one

A blind critic put the strongest finding plainly: Traefik ran as root with a **writable** Docker
socket. The `:ro` on the bind mount freezes the mount point, not the socket inode, so the process
inside could still write to the Docker API, and write access to the Docker API is host root. One
remote-code-execution bug in the most exposed process on the box would have defeated every other
control at once: no-new-privileges, the digest pinning, the capability drops and the firewall
policy are all bypassed by an attacker who can ask the daemon for a container that mounts `/`.

The answer was to delete the requirement rather than to wrap it. This deployment is three fixed
containers; the Docker provider was discovering nothing that was not already known. Routing moved
to a Traefik file provider at `/home/ubuntu/netbird/traefik-dynamic.yml`, mounted read-only, and
the socket mount is gone. The compose labels that used to carry the routing were deleted, because
configuration that nothing reads is worse than no configuration at all.

Each router, service and middleware in that file is the exact equivalent of the label it replaced,
including the `labnet-admin` IP allow list on the dashboard and on `/api` and `/oauth2`, the
priority 1 catch-all for the dashboard, priority 100 for the peer and admin paths, and the `h2c`
scheme on the gRPC backend. Verified after the change: the dashboard answers 200 from an
allowlisted position and 403 from elsewhere, `/api/peers` and `/api/policies` answer 200 with the
service token from the box and 403 from the workstation, `/relay` answers 426, and a real gRPC
POST to `/management.ManagementService/GetServerKey` answers 200 over HTTP/2. A path with no
router is answered by the dashboard's nginx, and a gRPC path is answered by the Go server, which
is how the two were told apart: on this host a 404 alone proves nothing, because the dashboard
catches unmatched paths and its nginx returns 404 too.

The containers also gave up every Linux capability they do not use. `no-new-privileges` stops a
process gaining more than it started with and says nothing about what root inside a container
already holds. All three now run `cap_drop: ALL`: Traefik and the server keep only
`NET_BIND_SERVICE`, and the dashboard keeps `NET_BIND_SERVICE`, `CHOWN`, `SETUID`, `SETGID` and
`DAC_OVERRIDE`, which is what nginx uses to bind port 80 and drop to its own user.

Both changes were confirmed to survive a second deliberate reboot, along with the firewall
policy, the disabled apport and `fs.suid_dumpable` reading 0.

### Two more gaps, found by the second critic

**The containers could read the cloud's identity.** From inside any of the three containers'
network namespaces, `http://169.254.169.254/opc/v2/identity/cert.pem` answered 200 with a real
certificate. Oracle's default `InstanceServices` rules allow port 80 to the metadata address with
no owner restriction, and NAT'd container traffic reaches it, so any code execution in an
internet-facing container could take the instance's signing key and act as the instance in
Oracle. The blast radius today is small and was measured rather than assumed: the tenancy has
zero dynamic groups, so that principal matches no policy and can do nothing. That is a reason it
is not urgent, not a reason to leave it, because the day someone adds a dynamic group the hole
arms itself silently. `DOCKER-USER` now drops anything from a container to `169.254.0.0/16` as
its first rule. Measured after: the same request from inside the container returns nothing, and
the host still reads its own metadata.

**The IP fence trusted every Cloudflare customer.** The allow list carried Cloudflare's published
egress ranges on the dashboard, `/oauth2` and `/api` alike. Those ranges are shared by everyone
who runs a Worker, so anyone could have reached those paths from their own Worker. Only `/api`
needs them, because that is the one path the lab-desk.net Worker calls, and `/api` is gated by the
service token underneath. The middleware was split: `labnet-admin` on the dashboard and `/oauth2`
now allows only the box, its Docker network, loopback and the subnet, while `labnet-api` on
`/api` keeps the Cloudflare ranges.

That was measured from Cloudflare's edge with a throwaway Worker, and the first measurement
failed in a way worth writing down. The routing file is bind-mounted into the container as a
single file, which binds an inode, so replacing it on the host with `mv` left the container
reading the old file. Traefik logged no error, because from its side nothing had changed. The
Worker probe was what caught it: the dashboard still answered 200 from Cloudflare. After
recreating the container so it binds the current file, the same probe reads `/api` 401, the
dashboard 403 and `/oauth2` 403 from Cloudflare, and from the box the dashboard answers 200,
`/api` answers 200 with the service token, `/relay` answers 426 and a gRPC POST answers 200 over
HTTP/2. When a config lives in a bind-mounted file, compare what the container reads against the
host file. A clean log is not a reload.

`dashboard.env` was world-readable at mode 644 and is now 600. Its `AUTH_CLIENT_SECRET` is empty,
because the dashboard is a public PKCE client, so nothing was leaking; the mode was wrong anyway.

### The third round, and the change that was wrong

The third critic found that `config.yaml` was bind-mounted read-write into `netbird-server`, the
container that terminates peer traffic and runs as uid 0. Code execution there could rewrite the
control plane's own configuration on the host, which the operator would then load on the next
restart. The server only reads that file (`combined/cmd/config.go`, `LoadConfig` is an
`os.ReadFile`, and nothing under `combined/cmd/` writes the config path), so the mount is now
`:ro`. Confirmed from inside the container: not writable, still readable, service healthy.

The same round noted that the container root filesystems were writable, which is persistence
across a restart and a reboot, and that container egress was unrestricted. Acting on both is
where this session made its own mistake, and it is worth writing down properly.

Container egress was restricted to nothing except Traefik's path to Let's Encrypt. Nothing broke,
because nothing restarted. The next `docker compose up -d` recreated `netbird-server`, and it
began to crash-loop. The first hypothesis was the read-only root filesystem applied in the same
step, and that was reverted. It was the wrong hypothesis. The real message was in the log:

```
FATL management/internals/server/modules.go:50: could not initialize geolocation service:
failed to get database filename: Head "https://pkgs.netbird.io/geolocation-dbs/GeoLite2-City/
download?suffix=tar.gz": dial tcp 194.113.73.12:443: i/o timeout
```

`netbird-server` downloads its GeoLite2 database from `pkgs.netbird.io` at every start and treats
failure as fatal. A blanket egress block therefore does not break the control plane when it is
applied. It breaks it at the next restart, which on this box is the unattended-upgrade reboot at
04:30, unattended, with nobody watching. That is a worse failure than the one it was preventing.

So general egress stays open, deliberately, and the two drops that carry the real value stay:
containers cannot reach the cloud metadata service, and containers cannot reach the production
subnet `10.30.20.0/24`, which is where the other machines live. Both were verified from inside
each container's network namespace, and both are persisted.

Two probes in that sequence lied before they told the truth, and both are worth remembering.
`nsenter -t <pid> -n` enters only the network namespace, so `/etc/resolv.conf` is still the host's
and points at `127.0.0.53`, which does not exist inside that namespace; every name lookup from
such a probe fails and looks exactly like a firewall block. And `getent hosts` on this VM returns
the AAAA record, which cannot be reached because the VM has no global IPv6, so an IPv4 test needs
`getent ahostsv4`. Resolve on the host, then use `curl --resolve`.

The read-only root filesystem is applied to Traefik, where it works and `/letsencrypt` stays
writable. It is not applied to the dashboard, whose entrypoint substitutes environment variables
into the built JavaScript under the web root at start.

After all of it the VM was rebooted a third time. All three containers came back with zero
restarts, every route answered, the firewall policy and both container drops persisted, Traefik's
root filesystem was still read-only and the server's config still read-only, the external scan
still showed only 443 open, and STUN still answered.

### The compromise removed

The fourth critic pass confirmed the three previous fixes and then found the root cause of the one
compromise this session had accepted. Container egress had been left open because `netbird-server`
downloads its GeoLite2 database at every start and treats failure as fatal. That was true, but it
was a symptom, not a constraint.

`combined/cmd/config.go:70` defines `disableGeoliteUpdate`, which defaults to false.
`management/internals/server/modules.go:47` passes `autoUpdate = !disableGeoliteUpdate` into
`geolocation.NewGeolocation`, and `management/server/geolocation/geolocation.go:225` fetches over
the network in that branch and returns the error, which `modules.go:50` turns into `log.Fatalf`.
The `else` branch at line 227 reuses the newest matching local file and never touches the network.
Both files the loader globs for were already on the volume: `GeoLite2-City_20260602.mmdb` for
`GeoLite2-City_*.mmdb` and `geonames_20260602.db` for `geonames_*.db`.

So `disableGeoliteUpdate: true` went into `config.yaml`, and the log now reads
`geolocation service has been initialized from /var/lib/netbird` with no fetch and no fatal. With
the dependency gone, the egress rules went back on: containers reach nothing on the internet except
Traefik, which needs Let's Encrypt. Measured after a reboot whose boot id was compared before and
after, so the reboot cannot be assumed: all three containers back with zero restarts, no fatal
lines, every route answering, Traefik reaching Let's Encrypt with 200 and `netbird-server` reaching
nothing.

`DOCKER-USER` now carries, in order: drop to `169.254.0.0/16`, return established, drop from the
container subnet to `10.30.20.0/24`, return Traefik's own address outbound, drop every other
container egress, then the inbound rules that allow only 443/tcp and 3478/udp from the public
interface.

### The health endpoint, and why it stays 503

`/health` on the server's internal port 9000 answered 503. It is not published, nothing consumes
it, and it is not a symptom of a broken relay, but it was worth chasing rather than filing as noise.

Two separate causes, found in order. First, `relay/healthcheck/healthcheck.go:160` dials
`ServiceChecker.InstanceURL()`, which is the relay's exposed address, `rels://nb.lab-desk.net:443`.
From inside the container that is a hairpin back to the host's own public address, which this cloud
does not do, so the dial spent five seconds timing out on every request. Resolving that one name to
Traefik on the internal bridge, with `extra_hosts`, sends the dial down the same route a real peer
takes: TLS to Traefik with the right SNI, the Let's Encrypt certificate, then the `/relay` router
back to the server. The dial now completes in 0.22 s and reports `certificate_valid: true`, which is
a stronger proof of the peer-facing relay path than the 426 an outside probe gets.

Second, the body still reads `"listeners": null`. `relay/server/server.go:127` builds that list from
the relay's own listeners, and the comment at line 142 says plainly that an external HTTP handler
routing to the relay means the relay never starts listeners of its own. That is exactly this
deployment. So `validateListeners` returns empty and the endpoint reports unhealthy structurally,
on every combined-server deployment behind a reverse proxy, regardless of configuration. It is an
upstream defect rather than anything to fix here, and it is recorded so the next person does not
spend the evening on it a second time.
