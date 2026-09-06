# The console

LabDesk opens on the console. It is the whole interface: connecting, the machine list, the fleet
view, sessions, the toolbox, this machine's identity, and settings, behind one navigation.

Before any of it moved, the existing interface was catalogued so that nothing would be lost in
the move. Six surfaces were read control by control, and each catalogue was then audited by a
second pass hunting for what the first had missed.

| Surface | Catalogued | Found by the audit |
|---|---|---|
| Home page, left pane | 55 | 33 |
| Home page, right pane (ConnectionPage) | 70 | 38 |
| Peer tabs and peer cards | 134 | 37 |
| Settings page, all tabs | 214 | 72 |
| Window chrome, tray, global dialogs | 143 | 96 |
| LabDesk's own additions and the console | 127 | 72 |
| **Total** | **743** | **348** |

**1091 controls.** That number decided the approach. Unverified: the catalogue itself is not in
this repository, so the figures above are a record of that pass rather than something a reader
can check against the code.

## The sections

`ConsoleSection` in `flutter/lib/labdesk/screens/console_shell.dart` declares ten sections, and
the sidebar renders every one of them in that order. Ctrl+1 to Ctrl+9 open the first nine.
Settings is tenth and has no shortcut, because `_NavItem` is given one only for an index below
nine.

Health is not a section. It was one, showing a single machine chosen on Fleet first; it is now a
tab inside Fleet beside Machines, so the whole fleet's figures sit with the reachability table
they belong with.

| Section | Key | What renders it | What is behind it today |
|---|---|---|---|
| Connect | Ctrl+1 | `screens/connect_screen.dart`, with the client's `OnlineStatusWidget` beneath it | The client's five peer stores, folded into one list by `buildMachineRows`. Live. |
| Fleet | Ctrl+2 | `screens/fleet_console.dart` on the Machines tab, `screens/health_board.dart` on the Health tab | Reachability and figures from lab-desk.net for every enrolled machine; the console's own poll answers for peers the server has never been told about. |
| Sessions | Ctrl+3 | `screens/sessions_screen.dart` | Chat read from this client's own remote desktop windows. Incoming connections are not in it. |
| Terminal | Ctrl+4 | `screens/terminal_screen.dart` | One command at a time over a hidden shell. Needs a terminal session, an open link, or a saved password. |
| Tools | Ctrl+5 | `screens/tools_screen.dart` | The same shell path, running the commands in `services/tool_catalog.dart`. |
| Automation | Ctrl+6 | `screens/automation_screen.dart` | Rules evaluated in this process, once a second, only while the console is open, plus the ready-made rules in `models/automation_presets.dart`. |
| Actions | Ctrl+7 | `screens/actions_screen.dart` | Five actions. Three open a session; two need one already open. |
| Network | Ctrl+8 | `screens/network_screen.dart`, with `screens/adapters_card.dart` above it | The machine's own adapters and internet verdict, and the labnets from lab-desk.net over the two planes described under *labnet* below. Nothing in it has yet been exercised from a signed-in console against production. |
| This machine | Ctrl+9 | `screens/this_machine_screen.dart` | The client's `ServerModel`. Live. |
| Settings | none | `settingsPageBody` from `desktop_setting_page.dart`, one page at a time | The client's own settings. Live. |

The sidebar is reachable without a pointer: every entry takes focus, activates on Enter or
Space, and reports itself to assistive technology as a selected or unselected button. Machine
menus carry a glyph per line, keep their text on one column, and put the destructive lines apart
at the end.

## Hosted, and rewritten

Rewriting eleven hundred controls by hand would have meant reimplementing every peer card menu,
every settings row and every dialog, and quietly losing whichever ones were missed. So
`ConsoleShell` takes a `hosted` map from section to `WidgetBuilder`. A section with a builder
renders that; a section without one falls back to the console's own screen.

`console_page.dart` supplies seven of the ten: Connect, This machine, Settings, Sessions,
Automation, Tools and Network. Fleet, Terminal and Actions are rendered by the shell itself from
the values passed in beside the map.

Two of those seven are now the console's own widgets rather than the application's, which is a
change from how this document used to describe them.

* **Connect** no longer mounts `ConnectionPage`. It renders `ConnectScreen`, one dense table
  grouped the way the operator grouped their machines. The peer sets the old tab strip exposed
  are filters over that one list: Recent, Favourites, Address book, Discovered. A set this build
  cannot source renders as a disabled chip carrying the reason, rather than as a filter that
  quietly returns nothing.
* **Settings** no longer mounts `DesktopSettingPage` whole, because that put a second navigation
  rail beside the console's. The client passes its pages up as `ConsoleSubItem`s, the sidebar
  nests them under Settings, and only `settingsPageBody(tab)` renders in the body.

This is what lets `lib/labdesk/**` stay free of the FFI. The shell imports no client code, and
`lib/labdesk/console_page.dart` is the single file in the console that touches it.

The design harness, `lib/labdesk_preview.dart`, is not free of hosted sections. It supplies two
of its own against fixtures, This machine and Network. Fleet, Terminal, Actions and Settings fall
through to the console's screens, with Settings landing on `screens/settings_screen.dart`, a
harness placeholder listing the server profiles that the client never shows. Connect, Sessions,
Automation and Tools land on `_HostedElsewhere`, which says the section is part of the running
client rather than drawing an empty frame.

## A screen nothing opens

`flutter/lib/labdesk/screens/health_screen.dart` defines `HealthScreen`, health for one machine
with its own identity, connection and remote system panels. Nothing in the running application
imports it. Its only caller is `flutter/tool/shots/shots_test.dart`, the screenshot harness, so
it is still rendered into the shot set while no navigation reaches it. The Health tab in Fleet
renders `HealthBoard` instead. Its wording still describes the PTY probe that WP18 removed, which
is one more reason nothing should route to it.

## What the old home page was

`DesktopHomePage` is still mounted, offstage and never painted, from `console_page.dart`. Its
`State` registers the main window's multi-window method handler, the stop-service flag that
`ConnectionPage` and Settings resolve with `Get.find`, the uni-links subscription, the macOS
permission watches, and the once-a-second read of this machine's own id. The console owns the
visible interface; that `State` keeps those responsibilities.

Its left rail is now the **This machine** section. Its right pane was `ConnectionPage`, which
**Connect** has replaced.

Two of its visible parts were rebuilt in the console and are drawn above the shell:

* the install prompt, when Windows is running uninstalled or macOS has no daemon
* the update banner, shown whenever the core has set `stateGlobal.updateUrl`

Three were not, and because `DesktopHomePage` is offstage nobody sees them any more:

* the macOS permission cards for screen recording, accessibility and input monitoring
* the system error banner
* the Linux warnings for SELinux enforcing and for a Wayland session

Those three are still live code in `desktop_home_page.dart` (`buildHelpCards`) and are simply
never painted. Getting them back means rebuilding them in the console, as the two banners above
were.

The main window's first tab keeps `kTabLabelHomePage` as its key, because the rest of the client
asks whether the home page is showing by that key. Only its label and its body changed.

## How the console reaches a machine

There are two paths, and which one is available decides what a section can show.

**A session window.** Each session runs in its own window, so the main window never held a record
of them. The console asks every remote desktop and terminal window what it holds, every two
seconds, over the window channel the tab bar already used (`get_remote_list`,
`labdesk_terminal_list`). That answer is the session registry.

**A link.** `LabDeskMachineLink` in `lib/desktop/pages/labdesk_machine_link.dart` opens a
terminal session from the main window with no window behind it, authenticating with the password
the client has saved for that peer. On the far side this is an ordinary incoming terminal
connection and is listed in that machine's connection manager like any other, which is the honest
shape of an agentless monitor. A link that does not authenticate within twenty seconds is written
off, and the reason the far side gave is the sentence the console prints.

Reachability is separate from both. It is polled from the console itself, every 4 s, or 10 s
against a public server, and the "Checked" stamp in the title bar is the server's last answer
rather than the time the button was pressed.

## What each surface can honestly show

**Fleet, Machines.** The machine list and the availability strips, drawn from the reachability
poll. Before the first answer it draws skeleton rows, because an empty list that is still loading
is not an empty fleet.

**Fleet, Health.** The board accounts for the ORGANIZATION's fleet, which is not the same set as
the Machines tab beside it: that tab is the technician's own peer list, and on a console that has
never connected to anything it is empty. The board is those rows plus every machine lab-desk.net
holds that is not among them, so a freshly installed console shows the fleet on first sign-in. It
rendered the peer list alone until 2026-09-05, and on homebox-devserver it read "No machines yet."
while the server was answering the same console with four machines, one of them that machine,
online and carrying figures.

One card per machine, in the product's three states rather than two: the online
machines first, then a group headed Offline, then a group headed Unknown. A machine LabDesk has had
no answer for is captioned as unknown and never as offline, with the last sighting printed only when
one exists, because "no answer yet" is not a report that a machine is down. There is no monitoring
switch:
every machine the organization has enrolled reports CPU, memory, the fullest filesystem and the
worst drive verdict to lab-desk.net on its own flush, and the console reads them back with the
fleet in one request, `GET /console/org/machines?state=1` (`services/overlay_broker.dart`,
`machines()`). The PTY probe that used to take those figures is gone, with
`services/metrics_collector.dart` and `services/probe_reader.dart`. One machine a poll is also
asked for its own hot row, `GET /console/org/machines/:id/state`, because the fleet answer carries
no uptime and no signed-in user; the first time round it is asked for its stored history too,
`GET /console/org/machines/:id/metrics`, which is what the sparklines are drawn from. Round trip,
throughput, frame rate and codec still come from a remote desktop window
(`labdesk_session_stats`), so they appear only while such a session is open. Anything not obtained
renders as `--`, never zero, and `unreadable` on a drive is drawn as its own state rather than as
healthy. A peer lab-desk.net holds no machine for says so on its card instead of showing four
dashes with no reason.

**Sessions.** Chat for the sessions this client opened, read with `labdesk_chat_get` from each
remote desktop window and sent back the same way, so the floating chat in the session window and
this screen show one conversation. Incoming connections are handled by the connection manager,
which is a separate process this window does not ask, so an incoming session's chat never reaches
this section. The screen's empty state currently invites the operator to "wait for somebody to
connect to this one", which promises more than the section delivers.

**Terminal.** A command runs in a hidden shell, on the terminal window's connection when one is
open (`labdesk_term_run`) and on a link otherwise, and comes back as plain lines with ANSI
stripped plus the exit code. The section treats a machine as having a shell if a terminal window
holds it, a link is already open to it, or the client has a password saved for it. In that last
case the link is opened when the first command is sent, and if it cannot authenticate the failure
is printed as a line rather than swallowed.

**Tools.** Six reading tools (services, processes, event log, software, disk, network), a power
tool that acts rather than reads, and the operator's saved scripts. All of them run over the same
shell path, across a selection of machines at once, with one result table per machine. Each of the
six has a command for Windows, Linux and macOS; where a platform has none, that machine's result
carries the sentence saying so instead of a table.

**Automation.** Rules are evaluated by the console's own one-second timer, in this process. Close
LabDesk and nothing runs, and the screen says so above the list. A rule with a metric condition
reads the figures the machine itself reported, so it works for every enrolled machine and for no
other. Above the list sit the ready-made rules of `models/automation_presets.dart`: a disk nearly
full, ten minutes offline, memory or CPU held high, and flushing DNS on a Windows machine that has
just come back. Applying one adds an ordinary rule, editable and deletable like any other; a
preset whose rule is already in the list reads as added rather than being offered twice.

**Actions.** Connect, Open terminal and Transfer files open a session and are always available.
Capture screen and Restart machine act on a remote desktop session that is already open: they are
routed to the window holding it (`labdesk_action`) and are disabled otherwise, because a terminal
session alone is not enough. Restart is confirmed in the console before it is sent, and the
session window raises no second dialog.

## labnet: the encrypted direct path

labnet is an optional direct path between machines in the same organization, built on the
NetBird client that ships in the `netbird` directory beside the LabDesk executable
(`docs/THIRD-PARTY.md`). A machine that has it on can be reached directly by the organization's
other machines over an encrypted tunnel, with no ID or relay server in the way. Nothing else
can reach it there: every machine sits in a group of its own on LabDesk's own control plane
(`docs/LABNET-SERVER.md`), and no rule lets one group reach another until a session or a
labnet says so.

**Enrolment.** Before either plane answers for a machine, the machine belongs to an
organization. This machine carries an *Organization* card (`screens/enrol_card.dart`): paste an
enrolment token an owner minted on lab-desk.net's `/org` page into the *Enrolment token* field
and press Enrol. The privileged LabDesk process spends it at `POST /agent/enrol`
(`main_agent_enrol`, served over IPC by `src/labdesk/labnet.rs`) and the card reads *Enrolled as
machine* followed by the machine id, or the server's refusal verbatim. The token is held in the
field only, never logged and never persisted.

**The switch.** This machine carries a card, *Encrypted direct connections*, with one
action: Turn on, Turn off, or Try again. The first time an account is signed in on a machine
that has never turned it on, the console asks once (the local option
`labdesk-overlay-consent` records that it asked) and never again. Turning it on raises no
elevation prompt: the privileged process, which is always on, does the privileged part over
IPC (`main_overlay_daemon`, one request served as LocalSystem on Windows and by the root
service on Linux and macOS). The sequence in `services/overlay_enrolment.dart`: the daemon's
status is read; if no service answers, lab-desk.net is asked for a one-off setup key, then the
daemon is installed as LabDesk's own service (`labdesk-netbird`) and started through that
process; the daemon is brought up with the key, its management URL held to `nb.lab-desk.net`;
the console waits for it to report Connected, tells lab-desk.net the address it got together
with this machine's id key and direct port, and opens the client's direct listener on that
address only (options `direct-server=Y` and `labdesk-direct-bind=<address>`). Turning it off
undoes each in the other order and sets `direct-server=N`.

**A session.** Every way the console opens a session goes through `_connectVia`. With the switch
on, lab-desk.net is asked for a grant (`POST /console/overlay/session`), which creates a one-way
rule from this machine's group to the target's on the target's direct port. The console waits
for the target peer to read Connected in the daemon's status (the rule has to be signalled and
the tunnel's handshake completed first, up to ten seconds), then hands the client three options,
`labdesk-overlay-addr-<id>`, `labdesk-overlay-pk-<id>` and `labdesk-ticket-<id>` (the one-time
connect ticket minted with the grant, see "Connect tickets" below; absent when the grant carried
none), and connects as always. The client tries that address before any server, with the
target's own id public key, so the session still runs LabDesk's key exchange and is never the
insecure kind a bare IP connection is. When the session window is gone the grant is released
(`DELETE /console/overlay/session/<id>`) and the three options cleared. If anything short of
that happens, the session simply goes the way it always has.

**Labnets.** The Network section lists the labnets the account owns or this machine belongs
to, and the invitations waiting on this machine. A labnet is a standing group: members reach
each other on LabDesk's port and ping, or on everything when the owner turns full access on.
Adding a machine only creates an invitation; the machine joins when a person approves it on
that machine's own Network section, and may leave the same way. The section is refreshed every
15 s, and only while an account is signed in.

**Labnet's absence costs nothing else.** A server need not have a labnet at all: lab-desk.net
answers `/agent/overlay/inbox` with 503 "labnet is not set up on this server yet" when no NetBird
is configured for it. That answer is confined to the labnet surface. The organization's machines
are read first and on their own, so a 503 from the inbox leaves the fleet, the health board, the
adapter view and the self-healing report exactly as they were; only the labnet card carries the
message. Both reads shared one `try` until 2026-09-05, and on homebox-devserver that 503 blanked
every one of those surfaces.

**The two planes.** The broker (`services/overlay_broker.dart`) speaks two planes of
lab-desk.net, and the split is deliberate. The six machine-side calls (`enrol`, `self`, the
`DELETE` that revokes enrolment, `inbox`, `invites/<id>/decide` and `labnets/<id>/leave`) go to
`/agent/overlay/...`, authenticated by an Ed25519 signature from the agent's own key. That key
lives in the privileged service and never crosses IPC, so the console does not sign: it asks
the service to (`main_agent_sign`, served by `src/labdesk/labnet.rs`), and `serve()` there
refuses from any process that is not the privileged one. The human-side calls (a session grant,
the labnet list and lifecycle, invitations, the organization's machines) go to
`/console/overlay/...` and `/console/org/...` with the app token `/api/login` minted. They
never target `/api/`: the prefix dates from the private phase, when `/api/*` sat behind the
Cloudflare Access wall and answered the desktop's bearer with a 302; the wall came down on
2026-09-05 and the prefix stays served because this build speaks it. The Worker mounts its
`/api/overlay/*` and `/api/org/*` handlers a second time under `/console`, and `actor()` there
resolves the bearer to the same person with the same role as in the browser.
`test/labdesk_overlay_broker_test.dart` asserts that no human-plane call targets `/api/`.

**What is proven, and what is not (2026-09-05).** Production serves the Worker that mounts
`/console`; the Access wall and its bypass are gone since later that day and the site is public; the labnet
tables exist, migrations 0002 through 0009 having been applied that day; and probed with no
bearer and with a junk one, every `/console` route answers JSON 401 rather than a redirect. The
build at `d9d9b23dc` (release `labnet-ready`) is installed on trapLab-Foundry. What has not
happened: no signed-in console has reached those routes, no machine has been enrolled from the
card, labnet has not been turned on from the card, and no session has been opened over an
overlay address. The direct path itself, the listener signing its id, the key check and the
fall-through, was proven on 2026-09-04 between Foundry and homebox with hints written by hand
over Tailscale addresses, which sit in the same 100.64.0.0/10 range the hint validator accepts.
`docs/SECURITY-POSTURE.md` records which of its findings this closed.

**Where the code is.** `lib/labdesk/services/overlay_daemon.dart` is the only file that knows
the daemon is NetBird; `overlay_broker.dart` speaks the lab-desk.net routes;
`overlay_enrolment.dart` and `overlay_session.dart` are the two sequences;
`screens/labnet_card.dart` and `screens/network_screen.dart` render, `console_page.dart`
wires. On the Rust side `_start` in `src/client.rs` tries the address hint, and
`direct_server` in `src/rendezvous_mediator.rs` honours `labdesk-direct-bind`.

## What the service does on its own

Three things run in the privileged service (`--service`) with no console open, and the console
only reads their results.

**Jobs.** A job is one entry of the compiled tool catalog, `src/labdesk/tools.json`, run with the
parameters the entry lists and nothing else: `service_start`, `service_stop`, `service_restart`
(a unit name), `process_kill` (a pid), `power_restart`, `power_shutdown`, `power_logoff`,
`power_lock` and `flush_dns`. The same file sits in the Worker, byte for byte, so what the server
can ask for and what the agent will run is one list. The service picks jobs up in the answer to
its telemetry uplink, runs each entry's argv directly (never through a shell; a parameter is a
whole argument or the job is refused as `bad_params`, and a value beginning with `-` is refused
whatever the entry says), and reports the exit code and the first 16 KiB of output on the next
uplink. A job the service already ran is refused `already_ran` from a ledger beside the identity
file, and one past its expiry is refused `expired`. Seven of the nine entries run as the service;
a technician's request for one of those waits for an owner's approval on lab-desk.net. The two
that run as the logged-in user (`power_logoff`, `power_lock`) go through `labdesk --labdesk-tool
<id>` in that user's session on Windows and macOS, and on Linux run in the service against the
seat0 user, because `loginctl` accepts that from root only.

**Disk health.** `labdesk --disk-health`, run as an administrator or root, prints the drives as
the service would report them, verdict and source included. `unreadable` with source `none` or
`sysfs` means no call answered, which is what an unprivileged run, a USB bridge or a virtual
disk produces; it is never rendered as healthy.

**Self-healing.** The switch is the option `labdesk-selfheal` (`Y` or absent), set from the
console like any other option, plus `labdesk-selfheal-probe-seconds`,
`labdesk-selfheal-fail-threshold` and `labdesk-selfheal-max-restarts-per-day`. The service reads
the switch from its config file on every tick, so a flip takes effect within one probe interval
on every platform, Windows included, and a service started with it off still honours it. What
the service is actually doing travels as the machine attribute `net.reachability`
(`{"internet":"online","at":...,"probe":"tcp443","selfheal":"watching"}`; `selfheal` is `off`,
`watching`, `cycling`, `restarting` or `holdoff`), and the console renders that value beside the
switch rather than the option. While the switch is off the service still probes the internet
once an hour so the verdict exists on every machine. The per-adapter view comes from the
attribute `net.adapters` (name, link state, MAC, addresses, byte counters, `physical`, `overlay`
or `other`), sent when anything but the counters changes and once an hour otherwise. Linux
and macOS read it from `getifaddrs`, Windows from `GetAdaptersAddresses`, where the adapter is
named the way Windows names it in Network Connections (`Ethernet 2`, `Wi-Fi`).

**Connect tickets.** When the console opens a session over labnet, lab-desk.net mints a
one-time ticket with it. The console stores the secret as `labdesk-ticket-<peer id>` beside the
overlay address (`services/overlay_session.dart`, the same `prepare` that writes the other two
hints) and the client spends it on the connect (`handle_hash` in `src/client.rs` reads the
option, clears it, and presents `sha256(sha256Hex(secret) || salt)` as the password); the
target's service receives the ticket's hash on its next uplink and hands it to the login
process, which accepts it once for that controller and refuses a second use like a wrong
password, and the target's service then reports the claim to lab-desk.net so the ticket's row
records that the one-time credential was spent. The controller holds the secret in its options
file only for the seconds between the grant and the connect, and it is cleared on use and again
when the grant is released; the
target keeps the hash in memory only. A ticket lives for two of the target's flushes and never
less than two minutes, because the target is handed it only in the answer to its own uplink and
the default flush is five minutes, so a two minute ticket expired before it could be delivered. The ticket password
is never written to the peer's remembered password and never synced to the personal address
book, even when that peer already has a remembered password (`PasswordSource::is_storable`
in `src/client.rs`, the same rule a shared address book password follows).

Everything above the claim is proven and the claim itself is not. On 2026-09-05 a ticket was
minted, delivered to a real machine inside its own signed uplink and marked delivered; no
`connect_ticket` row anywhere has ever carried `claimed_at`. Claiming needs a controller and a
target both signed in, which needs an enrolment token only the owner mints in production, so the
one-time password's acceptance and the claim report are covered by tests and by nothing else.

## What the console does not show

The console is a client-side interface. At HEAD the only things under `flutter/lib/` that speak
of an organization in the server's sense are the enrolment card on This machine and the broker's
read of the organization's machines. The labnet broker described above is not the only
lab-desk.net API this client calls: `models/user_model.dart` posts to `/api/login` and
`/api/currentUser` and reads `/api/login-options`, and `models/ab_model.dart` speaks the address
book routes. What the console has no surface for is managing the organization. Concretely:

* **The organization is managed on lab-desk.net, not here.** Owner, technician and viewer roles,
  fleets as groups inside an organization, and enrolment tokens live in `src/worker/org.ts` and
  on the web console of the `labdesk-site` repository, which since the evening of 2026-09-05 is
  eight pages LIVE in production: `/fleet`, `/machine/:id`, `/people`, `/enrol`, `/rules`,
  `/jobs`, `/alerts` and `/updates`, beside the `/org` page that creates the organization and its
  fleets, and `/account` and `/accept-invitation`. The merge that brought them was `2960665` and
  its build put version `6203a2e6` in production at 2026-09-06T00:18:03Z; every later commit to
  `dev` deploys a newer one, so read the live version from the dashboard. That is where a person is
  invited, a role is changed, a job is approved and an alert is acknowledged. This client spends
  a token and lists the organization's machines; it has no page that creates a fleet or changes a
  role. The console's
  **Fleet** section is a different thing wearing the same word: this client's own machine list and
  its reachability, held locally.
* **The health engine's own events are not read yet.** `GET /console/org/events` and the
  acknowledgement route exist and the console does not call them, so a rule the worker fired is
  visible on the web console and not here.
* **Health rules are still the console's own, not the organization's.** `GET /console/org/rules`
  and the switch beside it exist on lab-desk.net; there is no create, delete or preset route yet,
  so the Automation section keeps its local rule store (`labdesk-automation`) and its own tick,
  and the presets are applied into that store. The editor moves to the organization's rules when
  those routes land.
* **No update is driven from the console.** The update banner offers the client's own flow, which
  installs in place on Windows and, through the service process, on macOS and, since 2026-09-05, on
  Linux. `crate::updater::start_auto_update_linux` runs in the root service that
  `res/rustdesk.service` starts, asks the desktop user's `--server` over IPC whether a session is
  live, downloads the deb or rpm the release publishes for this platform, checks it against the
  digest lab-desk.net publishes, and hands it to `/usr/share/rustdesk/labdesk-helper` through
  `systemd-run`. The helper is the same program the polkit action
  `net.lab-desk.LabDesk.install-update` names, so the console's own banner and the unattended loop
  install through one gate; the helper fetches the published digest itself and refuses anything
  that is not a package lab-desk.net has published, or that is not newer than the installed
  version. An AppImage, a flatpak or a copy that was never installed from a package still gets the
  download page rather than an install.
