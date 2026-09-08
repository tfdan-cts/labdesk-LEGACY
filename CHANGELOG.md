# Changelog

LabDesk's own versions. The RustDesk core underneath is stated in the README, not versioned here.
Rules: `docs/VERSIONING.md`.

## 1.4.0-alpha.8+80 — private candidate

- Add expiring installer links, Labnet invitations and scoped sharing controls.
- Align Connect capabilities, fleet administration and naming with account permissions.
- Add exit selection, separate local and exit LAN access, and subnet hosting consent.
- Add update notifications, automatic weekly windows and scheduled fleet updates.
- Package the complete standalone updater and MSI with Labnet runtime 0.78.1-labdesk.3.

Live endpoint, routing and compatible service acceptance remain release gates.

## 1.4.0-alpha.6+78 — private candidate

- Patch dependencies selected for the Windows runtime and pin Rust 1.98.1.
- Require current broker authorization for managed sessions and enforce revocation
  through bounded authorization leases.
- Bundle the repaired, versioned Windows Labnet service and keep installer component
  identities stable across upgrades.
- Reject NTFS alternate-stream filenames supplied through remote file transfers.
- Enforce server-certificate validation in HTTP clients and remove the obsolete
  inventory/configuration polling loop; keep signed machine reporting and session grants.
- Redesign transfer panes and remote controls, displaying machine hostnames.
- Verify offline-signed release inventories with a pinned Ed25519 public key; remove
  automated jobs that could replace the manifest or delete its signature.

This is a test candidate. Matching endpoint installation, separate-network desktop and
file transfer, and live authorization-revocation checks remain release gates.

## Unreleased (`feat/labnet`, built as `labnet-ready` from `d9d9b23dc` on 2026-09-05)

The version number has not moved; the `labnet-ready` build reports 1.2.4. What is on the branch
past that release:

- labnet is turned on from the console with no elevation prompt. The privileged LabDesk process,
  which is always on, installs and starts the bundled NetBird daemon as the `labdesk-netbird`
  service, brings it up with the one-off setup key passed through a file only it can read, and
  signs the machine-plane requests, all over IPC; the console asks and shows the daemon's own
  words when something fails. The setup key never appears on a command line.
- This machine gains an Organization card: paste an enrolment token an owner minted on
  lab-desk.net's organization page and press Enrol; the privileged process spends it and the card
  shows the machine id, or the refusal verbatim.
- The console's human-plane calls to lab-desk.net (session grants, labnets, the organization's
  machines) go to `/console/...`, where the app token reaches a handler while the site is behind
  its private-phase wall. The machine plane stays on `/agent/...`. No console call targets
  `/api/...` any more, and a test holds it.
- lab-desk.net is public since 2026-09-05. The Cloudflare zone was hardened and every setting
  read back live, the site's admin gained a registration switch (default off: a self sign-up
  lands pending and cannot sign in until an admin approves it) and an overview of the
  organizations, machines and open labnet sessions, and the private-phase Access wall came
  down. The `/console` prefix this build speaks stays served.
- The direct listener signs its identity when bound to the overlay address, so a direct session
  completes instead of falling back to the relay every time, and a peer whose key the broker has
  not yet learned is reported as unproven and falls through rather than being called an
  impersonation. Proven between two real machines on 2026-09-04.
- A machine restores its own internet from the privileged service: off unless
  `labdesk-selfheal=Y`, it proves reachability with a real connection, cycles adapters, cycles
  again, then reboots with a per-day cap.
- The update banner renders in the console; the unattended updater downloads into a fresh private
  directory and logs the verify-then-launch at info; a labnet session grant never seen open is
  aged out and its per-peer hints cleared.
- Full Flutter CI runs again: the manifest job inherited a permissions block that failed the
  workflow at startup since it was added, previews with a suffix stay prereleases, and the
  dispatch workflow builds one at a time.
- The console's health figures come from the machine, not from a session. Every machine enrolled
  with your organization reports its own CPU, memory, fullest filesystem and drive verdict on its
  flush, and Fleet reads them back for the whole fleet in one request, with the stored history
  behind the sparklines. The monitoring switch is gone with the terminal probe that needed it:
  there is nothing to turn on, and a figure exists whether or not anybody is connected. A peer
  your organization has not enrolled says so on its card instead of showing four dashes.
- Network shows a machine's own adapters: link state, addresses, MAC and byte counters, with the
  internet verdict the machine reached itself and what self-healing was doing at the time.
- This machine gains the self-healing switch. It sets the option the service reads, and what it
  shows beside itself is the step the service reported, so a switch that has not been picked up
  reads as waiting rather than as done.
- Automation offers ready-made rules: a disk nearly full, ten minutes offline, memory or CPU held
  high, and a DNS flush when a Windows machine comes back. Adding one leaves an ordinary rule you
  can edit or delete. The rule action that turned monitoring on is gone with monitoring.
- Labnets can be renamed, a technician who works across several fleets is asked which fleet a new
  labnet belongs to instead of being refused, and a change lab-desk.net wants a fresh sign-in for
  asks for it and then goes through rather than failing.
- Tools and jobs. A technician asks lab-desk.net to run one of the tools in the compiled
  catalog on one machine. The request is checked against that tool's own parameter rules and
  against the machine's platform before it is stored, a tool that runs as the system waits for a
  second owner's approval, and the machine collects the job on its next uplink, runs it as the
  right user, and returns the exit code and the first 16 KiB of its output. Nine tools ship in
  the first catalog, and the same `tools.json` compiles into both halves of the product so
  neither can drift from the other.
- A connect ticket, not a password. When a technician opens a labnet path to a machine, the
  server mints a one-time credential and hands the plaintext to the console alone; the target
  learns only its hash, inside the answer to its own signed uplink, accepts it once, and reports
  it spent. The ticket is never written to the remembered password for that peer and never
  reaches an address book. A ticket lives for two of the target's flushes and never less than
  120 seconds, because a shorter life expired before the uplink that had to carry it.
- Drive health runs against real drives. The disk module had never been asked a question by
  anything but a byte fixture; on 2026-09-05 it read a Micron 3400 NVMe and a Seagate
  ST1000VX008 on real hardware, and both refused without root as unreadable rather than
  reporting a healthy disk nobody had asked. Two readings the plan had wrong were corrected
  against those drives: the ATA power-on hours field carries a second counter in its upper
  bytes, and the NVMe hwmon node sits on the controller rather than under its device.
- Linux receives unattended updates, through a helper the packages actually ship. `build.py`
  stages `labdesk-helper` and the polkit action on both deb paths and in both rpm specs, the
  root service asks the desktop process whether a session is live before it installs, and the
  install is handed to the helper through `systemd-run` so that stopping the service mid-upgrade
  cannot kill dpkg. The helper refuses a package that is not newer than the installed one and
  refuses any bytes whose digest lab-desk.net has not published, so the console's own button and
  the unattended loop install through one gate.
- lab-desk.net gains the web console, live in production since the evening of 2026-09-05: fleet,
  one machine, people, enrolment, rules, jobs, alerts and updates, each fed by its own route, with
  an owner able to invite a second person into the organization and that invitation able to be
  accepted. The machine page shows a day of stored history, every drive with its verdict and what
  read it, the jobs and the alerts for that machine, and the labels beside the agent's own
  read-only attributes.
- A machine nobody has asked about is drawn as unknown rather than as down. The shared status dot
  carried two states, so the absence of an answer looked the same as a report that a machine was
  offline; it carries three now, and the health board groups the fleet by them and prints a last
  sighting only where one exists.
- Build only, but it costs every lane: the vcpkg binary cache had been caching nothing in every
  workflow since GitHub removed the `x-gha` backend, so each job rebuilt its ports from source. A
  files provider plus `actions/cache` replaces it, measured at 390 seconds down to 3 on a warm
  Linux run. Full Flutter CI also gained a concurrency group, so a branch stops racing itself for
  macOS runners.
- The first end-to-end run on a real machine, 2026-09-05, found five defects no test could see,
  and they are fixed: a machine never reported its own platform, so no really enrolled machine
  could ever be given a job; an urgent job's result still waited a full cadence, because the
  early flush had no line to carry it; a server with no labnet configured blanked the whole
  console, because one read had been paired with the organization's machines; the health board
  rendered the technician's own peers instead of the organization's fleet; and the console never
  recognised itself, because it compared against the formatted machine id the box displays.

Known open at this commit: no session has been opened over a labnet address from the product;
the field test is the owner's. The aarch64 Windows and iOS jobs of the `labnet-ready` dispatch
failed, so no ARM64 Windows or iOS build of this commit exists. A connect ticket has been minted
and delivered to a real machine but never claimed, because claiming it needs two signed-in
consoles and an enrolment token only the owner mints in production. The console still reads no
health events, and its automation rules are still its own rather than the organization's, because
the server has no create or delete route for a rule yet.

## 1.2.4 (2026-09-04)

- No change to the product. This release exists so that an installed client carrying the
  updater below can be watched updating itself through the verified path on a real machine:
  the digest is read out of the release's `SHA256SUMS` and the download is hashed against it
  before the installer runs.

## 1.2.3 (2026-09-04)

Security fixes.

- An update is verified before it installs, on every path that installs one. LabDesk refuses to
  install a download whose bytes do not hash to a published SHA-256. The digest is read out of the release's own `SHA256SUMS`, which the manual build workflow
  publishes beside the assets of every release it makes from this commit on, so a client
  built from this commit can install an update; a release that carries no manifest, which is
  every release before this one, is refused rather than installed unverified. The old check compared the size of any file left
  behind in the temporary directory, which every local user can write, so a file of the right
  size was reused and handed to an elevated installer unverified. A release that publishes no
  digest, the upstream GitHub releases included, no longer installs at all. Nothing signs the
  manifest yet: the pinned key in `src/updater.rs` is an empty placeholder and the key
  ceremony has not been performed, so a manifest proves the bytes, not who published them.
  `docs/SIGNING.md` says what it takes to switch enforcement on.
- The heartbeat and inventory posts to lab-desk.net carry the signed-in account's token. They
  were sent with no authorization header at all, so every one of them was refused by a server
  that already required one, which is why no machine record was ever stored. The write is now
  constrained to a row that is unclaimed or already the caller's own, so one account can no
  longer overwrite another machine's row, its inventory or its public key. Console tokens now
  expire as well: the column carried a ninety day default that no code had ever compared to
  the clock.
- The settings a server may push back in a heartbeat reply are limited to a fixed list of
  session permissions. Everything that decides where this machine listens or what it dials
  (`direct-server`, `labdesk-direct-bind`, every labnet overlay key), who may connect
  (`verification-method`, `approve-mode`, `whitelist`, `id-whitelist`) and whether it installs
  code (`allow-auto-update`) sits outside that list.
- A machine enrolling in labnet reports its real public key and its real listening port. It
  sent an empty key and a fixed port before, and the key is now read without minting one as a
  side effect, so an enrolment cannot publish an identity the machine does not hold.
- A labnet session grant uses only the key the machine itself reported when it enrolled. The
  broker used to fall back to the key on the device row, which a different account could write.
  With no reported key the grant is refused with a reason, rather than issued against a key
  that may not be the machine's.
- On the direct labnet path, a machine that answers the hinted address and signs an identity
  the peer's key does not answer for ends the connection instead of carrying it. An address
  that leads nowhere, or that answers without proving an identity, still falls back to the ID
  server. A hint is dialled only as a literal IPv4 address in 100.64.0.0/10; a name, an IPv6
  address and an IPv4-mapped IPv6 address are all discarded.
- Revoking a machine's labnet enrolment deletes its open session policies before its group and
  records the revocation last, so a revoke that fails part way can be retried instead of
  leaving the machine wedged with its group still on the labnet server. Re-enrolling deletes
  the previous unused setup key rather than leaving a second key that can register a peer.
- The labnet server at nb.lab-desk.net was hardened, and each check was answered by a
  measurement taken after a reboot rather than by the configuration that was written. From the
  internet only 443/tcp and 3478/udp answer; the host firewall drops inbound by default on IPv4
  and IPv6; no container reaches the cloud metadata service or the production subnet; all three
  containers are pinned by digest, drop every capability and then regain only the few they use,
  and cannot gain new privileges;
  Traefik no longer has the Docker socket and runs on a read-only root filesystem. The Lynis
  hardening index moved from 64 to 76. `docs/LABNET-SERVER.md`.

New capability.

- labnet, an encrypted direct path between machines on the same account, on a NetBird client
  bundled beside LabDesk. One consent prompt, then a switch on This machine. A session to a
  machine that has it on goes straight to it over the tunnel, with LabDesk's own key exchange
  intact, and falls back to the ID server otherwise. The Network section holds labnets:
  standing groups a machine joins only after approving on its own screen, with a per-labnet
  full access switch. `docs/CONSOLE.md`, `docs/LABNET-SERVER.md`, `docs/THIRD-PARTY.md`.
- Telemetry collection runs in the always-on service, which is the privileged process on all
  three platforms and the only one that keeps running with nobody logged in. It samples CPU,
  memory, disk space and network counters on a cadence the server sets, writes them to a spool
  file with a hard cap that drops the oldest lines rather than filling the disk, truncates only
  after a send is accepted, and backs off by doubling up to a ceiling when the server is
  unreachable. A machine
  told it has been revoked stops collecting and deletes its spool. Enrolment is
  `labdesk --enrol --token <token>`, run elevated on an installed copy; nothing in the console
  or on lab-desk.net issues that token yet.
- The machine has a credential of its own: an Ed25519 keypair generated inside the privileged
  daemon and kept out of the configuration that is handed to the user process over IPC. The
  key file is mode 0600 on Linux and macOS; Windows has no root, so it is stored under the
  service account's profile with a narrowed access list. lab-desk.net authenticates the machine
  plane on a signature over the method, the request target, a timestamp and a hash of the body,
  and on nothing else, so a stolen console token cannot speak for a machine.
- lab-desk.net gains an organization: owner, technician and viewer roles over machines and
  fleets, with every route resolving the caller's membership and capability before it reads or
  writes, and every lookup carrying the organization alongside the row it names. Telemetry
  ingest, the machine side of labnet and an address book that serves per-fleet books and never
  returns a password sit behind it. None of it is live; see the gaps below.
- Disk health is judged in four states: ok, warn, failing and unreadable, so a disk that could
  not be asked never reports as a disk that is fine, and a disk that is degrading is not yet
  called failing. The parsers cover ATA SMART attributes and the NVMe health log page against
  committed byte fixtures, two of them deliberately malformed, and the platform layer issues DeviceIoControl on Windows and the ATA
  and NVMe passthrough ioctls on Linux. Nothing calls it and it has never run against a real
  disk; see the gaps below.
- The lab-desk.net repository gains a typecheck and test workflow; it had no continuous
  integration at all. It gates nothing yet, and less than it appears to: the workflow exists
  only on the feature branch, so it is absent from `dev`, which is the default branch and the
  one Cloudflare deploys from. `dev` also has no branch protection.
- The decisions and the architecture behind the four entries above are in
  `docs/plans/2026-09-04-002-rmm-decisions.md` and
  `docs/plans/2026-09-04-003-rmm-architecture.md`.

Known gaps, each read out of the committed code rather than assumed.

- None of the server side above is live. Production D1 has migrations `0000` and `0001`
  applied; `0002` through `0009` are pending, and that includes `0002`, which creates the
  labnet tables themselves, so labnet has never worked in production either, not only the
  organization, machine, telemetry, health engine, address book and index tables above it. A read of `d1_migrations` on 2026-09-04
  returned those two rows, zero device rows and no `machine` table.
- The desktop client's labnet calls for enrolling, reporting its address, revoking, the invite
  inbox, approving an invite and leaving a labnet still address `/api/overlay/...`, and those
  routes moved onto the signed `/agent/overlay/...` plane. In a build from this commit the
  machine side of the labnet entry above does not work. A fix is in flight.
- The health engine that evaluates rules on the server has no caller. The Worker has no cron
  trigger and no scheduled handler, and nothing outside its own test imports it. In flight.
- Fleets exist in the schema and behind `/api/org/fleets`. Nothing in the console or on
  lab-desk.net creates or manages one. In flight.
- Nothing reads disk health. The collector samples free space, not SMART, and no code outside
  the disk module calls it. In flight.
- Linux machines receive no unattended updates. The automatic check installs on Windows only,
  macOS installs from its own service path, and a Linux package installs only when a person
  accepts the root prompt. A Linux delivery package was written, reviewed as broken and
  reverted rather than shipped.
- `.github/workflows/flutter-ci.yml` analyzes the Dart sources without generating the Rust
  bridge, so a call that names a bridge function which does not exist is not caught before it
  ships.
- `src/hbbs_http/sync.rs` records a gap of its own: on Windows and macOS the process that sends
  the heartbeat can read a different profile than the one the interface signed in to, and with
  no token every post is refused. Stated in the source; not measured on either platform here.
- An update refused for a digest mismatch on the console's update button is written to the log
  and not shown on screen. The macOS extraction step is the exception: it reports its refusal
  to the dialog that is waiting on it.

## 1.2.2, 2026-09-03

- Health cards remember every reading while monitoring is on and draw CPU, memory and disk
  over the last two hours under each figure, with the time and value under the pointer.
- Machine menus carry a glyph per line; the sidebar takes focus and Enter, reports itself to
  screen readers, and Ctrl+1 to Ctrl+9 open the sections.
- A copy that is not installed is told, in the console, to install: the always-on service,
  unattended access and in-place updates exist only installed.
- Wording is the product's own: sessions require a password or your approval, allowed IPs and
  IDs, privacy screen, lock remote screen, send Ctrl+Alt+Del, port forwarding, wake on LAN.
  Linux menu and service names, Windows support links and package metadata name LabDesk and
  lab-desk.net. The Android store listing inherited from upstream is removed.
- Uninstalling the Debian package removes LabDesk's own configuration directory, not the
  upstream project's.
- Release files are named `labdesk-<version>-<arch>.<kind>` on every platform, and the
  updater asks for them by that name. lab-desk.net serves older releases under the same
  naming and still answers a 1.2.1 asking under the old one.

## 1.2.1, 2026-09-03

- Updates come from lab-desk.net. LabDesk checks for a new version on start and once a day,
  shows a banner in the console, downloads the build the site administrator made public, and
  installs it in place: silently on Windows, through the existing path on macOS, and on Linux
  with one root prompt for a deb or rpm package. AppImage and flatpak copies get the download
  page instead.
- The LabDesk account is global. Sign-in, address book and device presence go to lab-desk.net
  whichever server profile is active; the per-profile API server field is no longer edited.
- The console's machine links no longer raise session dialogs in the main window; a failed
  link reports its reason ("ID does not exist") where it used to guess at the password, and no
  session error can close the application.

## 1.2.0, 2026-09-02

The first version the binaries carry themselves; until now they reported the core's `1.4.9`.

- The console holds a headless connection of its own to each machine, authenticated with the
  saved password. Health, the Terminal section, the tools and automation all run over it; a
  terminal window is no longer required.
- Fleet gains a Health tab: every machine as a card, monitoring per machine, read every 30 s.
- Sessions: chat with every open outgoing session from the console, through the session's own
  chat, so the floating chat and the console show one conversation.
- This machine: a display name, shown to machines you connect to instead of the OS user name.
- Tools: services, processes, event log, software, disk, network, power, and a library of your
  own scripts, run on one machine or many; per-row service and process actions.
- Automation: rules with triggers (came online, went offline for N minutes, metric above,
  uptime above, schedules) and actions (run command, notify, wake, monitor, open session).
  They run while LabDesk is open on this machine.
- Reachability is polled again, every 4 s; Refresh shows a real busy state and stamps the
  server's last answer.
- The wait-for-acceptance dialog names the machine and says why it is waiting.
- The sidebar's server-profile control opens the profiles; the sidebar is narrower.
- The remaining stock-RustDesk surfaces were reworked: dialogs, the file-transfer window, the
  connection manager, the session toolbar, the installer, This machine, and the console's own
  glyphs throughout.
- Probes and tools read what a PTY actually delivers on both platforms (bash's bracketed-paste
  escape on the first line; PowerShell's continuation prompt; ConPTY turning tabs into spaces).

Known: chat with machines connecting to this one is not shown in the console (the connection
manager is a separate process); Terminal and Actions still pick their machine on Fleet.

## 1.1.0, 2026-08-29 (console preview)

- The console becomes the application: navigation, Connect, Fleet, Health, Terminal, Actions,
  This machine and Settings behind one shell, hosting the working client widgets.
- LabDesk's own icon set and brand mark; the installer stops looking like RustDesk.

## 1.0.3, 2026-08-29

- Windows install and uninstall fixed under the LabDesk name; service config removed on
  uninstall; `--remove-service-config`.

## 1.0.1 and 1.0.2, 2026-08-27 and 28

- Build metadata debranded; one-line installers for Windows and Linux with six correctness
  fixes; the click-to-install `LabDesk-<version>-<arch>-install.exe`.

## 1.0.0, 2026-08-27

- Named server profiles, machine groups, per-machine icons, the purple theme, the LabDesk name.
