part of 'help_content.dart';

// Feature chapters match website help-manual.json; update both surfaces together.
const _helpManuals = <String, List<HelpEntry>>{
  'updates': [
    HelpEntry(
        "manual-installer-sharing",
        "Installer grants, current releases and link recovery",
        "An installer link is a time-limited download grant, separate from enrollment and automatic updates.",
        "",
        "An authorized owner or Fleet Admin creates a link for a platform that has an installer in the stable release catalog. Fleet scope is checked when creating and managing the grant. The secret URL is returned only at creation; later listings show metadata such as platform, creation time, expiry and revocation. Copy it before leaving the creation result. If it is lost, create a new link rather than expecting the list to reveal it.\n\nThe grant lasts exactly 24 hours and supports repeated downloads during that period. Each use rechecks expiry, revocation and the issuer’s current authority. The service resolves the selected platform’s current stable asset at download time, so the link is not a permanent pin to the version available when it was created.\n\nThe recipient receives installer bytes through the grant endpoint rather than a redirect exposing a permanent artifact destination. Expired, revoked or no-longer-authorized grants stop admitting new downloads. Revocation does not recall an installer already downloaded. A download link neither enrolls a device nor authorizes a Labnet membership, a managed session or an automatic-update policy.",
        ["labdesk-site/src/worker/routes/download-links.ts", "flutter/lib/labdesk/services/overlay_broker.dart"],
        isManual: true),
    HelpEntry("manual-update-execution",
        "Policy, scheduling and privileged execution",
        "The service stores desired intent; the machine agent is responsible for applying it.",
        "",
        "Fleet update requests carry canonical machine IDs and are authorized against the current organization and fleet scope. Bulk operations accept 1–250 machines. One-time requests carry UTC start/end instants; recurring policy carries local weekdays, start minute and a bounded window. These are different scheduling models.\n\nThe machine reports its update capabilities and the policy revision it has applied. A stored policy remains pending until the reported revision matches. Offline or old clients can remain unacknowledged; refreshing the console does not force execution. Local GUI policy writes cannot override a managed policy.\n\nInstallation waits for idle time and a valid execution window. The agent reauthorizes installation before privileged handoff. Preparing or launching the installer is not completion: a new running version must be reported after restart. Missed windows expire rather than becoming unrestricted delayed installs; cancellation can be refused once installation has begun.",
        ["flutter/lib/labdesk/screens/local_update_controls.dart", "flutter/lib/labdesk/screens/fleet_updates_screen.dart", "labdesk-site/src/app/pages/updates.tsx"], isManual: true),
    HelpEntry("manual-update-trust",
        "Release integrity, local requests and failure recovery",
        "The UI requests an update through the existing updater; it does not choose an arbitrary installer URL.",
        "",
        "The Windows updater uses an Ed25519-signed release manifest and verifies the installer digest against that manifest. Signature or digest failure must prevent installation. This application signature is separate from Windows Authenticode publisher trust and does not itself remove SmartScreen warnings.\n\nUnmanaged desktop Check now and Download and install cross privileged IPC. A fresh queued-local-command receipt confirms acceptance of a bounded one-hour request; a successful void setter alone is insufficient. The same readback supplies rejection details and managed-policy lockout. Installation through this path does not enable recurring updates.\n\nTreat publication, download, installation launch and a confirmed running version as separate states. Preserve a failed settings draft until canonical readback confirms it or a newer policy requires review. Check platform support, request window, actual error and report age before retrying. A website deployment does not publish or install a native release.",
        ["flutter/lib/labdesk/screens/local_update_controls.dart", "flutter/lib/labdesk/screens/fleet_updates_screen.dart", "labdesk-site/src/app/pages/updates.tsx", "src/updater.rs"], isManual: true),
  ],
  'labnets': [
    HelpEntry(
        "manual-labnet-sharing",
        "Invitation decisions, guest scope and machine consent",
        "A human invitation decision creates scoped access; machine participation remains a separate consent step.",
        "",
        "A person, machine or combined invitation names one Labnet and expires 48 hours after creation. Previewing or opening its link does not accept it. The recipient signs in, reviews the kind and capabilities, and explicitly accepts or refuses. The service claims that decision atomically, so a used, revoked or expired invitation cannot be consumed again. An email-bound invitation requires the matching account.\n\nAccepted guest access belongs to the selected shared Labnet. It does not create organization membership or allow browsing unrelated fleets and machines. Connect capabilities default to empty. Machine-only invitations cannot assign human Connect capabilities; receiving network access is not a general remote-control grant.\n\nFor machine or combined invitations, the recipient selects an enrolled machine they currently manage within its existing organization and fleet scope. The invitation creates or retains the appropriate membership request. A newly invited machine remains pending until it accepts through its signed machine channel; the account’s successful acceptance is not proof of an active tunnel.\n\nRevocation invalidates the invitation’s guest grant and the machine attachment originating from it. Provider removal can require retries, reported as cleanup pending. Other independent invitations, direct memberships or Labnet memberships may still apply. Removing one source of access does not prove that every possible network path has been removed.",
        ["labdesk-site/src/worker/routes/labnet-invitations.ts", "labdesk-site/src/worker/labnet-sharing.ts"],
        isManual: true),
    HelpEntry(
        "manual-connect-capabilities",
        "Signed Connect grants and target enforcement",
        "A reachable target must also authorize the exact session mode and capabilities.",
        "",
        "The service reads the target’s canonical Connect policy and intersects it with an explicit shared-guest grant when one is used. The target also applies its local permission limits. The resulting signed ticket carries a bounded mode, capability set and policy revision. Network membership, an organization role or a saved password is not a replacement for this managed session grant.\n\nA changed policy stays pending until the target acknowledges the current revision. Managed connection preparation also requires the target listener’s signed enforcement acknowledgement. An older target that has not supplied it receives an update-required result; opening another connection mode or choosing local approval does not bypass that requirement.\n\nControl depends on view, and administrator terminal depends on terminal. RDP-only access is limited to the target’s loopback RDP service on port 3389; arbitrary TCP destinations require the tunnel capability. Controls inside an established session cannot enlarge the ticket’s authority. Local consent remains an additional requirement where configured.\n\nInspect permission state, target acknowledgement and the specific refusal before retrying. A successful policy save confirms desired intent only. Session preparation, target readiness and network-grant cleanup have their own outcomes; a route becoming reachable is not confirmation that desktop, file or terminal access is authorized.",
        ["labdesk-site/src/worker/routes/connect-permissions.ts", "labdesk-site/src/worker/routes/overlay.ts", "src/labdesk/ticket.rs"],
        isManual: true),
    HelpEntry(
        "manual-exit-subnet-routing",
        "Exit selection, LAN boundaries and subnet routing",
        "Routing offers, machine consent, applied preferences and tested reachability describe different stages.",
        "",
        "An exit offer asks an approved machine to host an internet route for its Labnet. It requires that machine’s consent and current hosting support. A client separately selects an exit, or chooses Normal connection to clear the exit preference. Saving stores a desired revision; the UI waits for a fresh signed daemon report whose acknowledgement and applied exit match that intent.\n\nClient-local LAN access controls whether the client can reach its own nearby network while using the exit. Exit-side LAN access concerns networks reachable from the exit host. These are separate boundaries with separate capability and state reports. Do not infer selection, LAN isolation or hosting support from a platform name, CLI version or another capability.\n\nA subnet offer names a CIDR range and routing machine. The service provisions NetBird network resources, a router and explicit access policy after the required authorization and consent. Joining a Labnet alone neither shares a whole LAN nor selects an internet exit. An active provider resource or acknowledged preference does not establish endpoint reachability or verified internet egress.\n\nUse report timestamps, the current error and pending acknowledgements when diagnosing a route. Stale observations do not establish that a LAN boundary is currently enforced. Revocation stops the relevant authorization, but provider removal may remain pending and continue through retries. Confirm cleanup for the specific offer and inspect other standing grants before concluding that access has ended.",
        ["labdesk-site/src/worker/routes/exit-routing.ts", "flutter/lib/labdesk/models/exit_routing.dart", "flutter/lib/labdesk/screens/exit_routing_controls.dart"],
        isManual: true),
    HelpEntry(
        'manual-wireguard',
        'WireGuard encryption and the private network',
        'Labnet is a private network overlay built with the bundled NetBird client. WireGuard protects packets between authorized machines.',
        '',
        'The overlay creates an encrypted network interface. LabDesk supplies consent, organization permissions and connection preparation around NetBird. The integrated client uses the dedicated labdesk0 interface and UDP listen port 51821, with state separate from another installed VPN. This is a local configuration, not an instruction to expose that port universally.\n\nWireGuard authenticates and encrypts tunnel packets with ChaCha20-Poly1305. Its handshake uses Curve25519, derives session keys and periodically rekeys; the protocol also rejects replayed packets. This protects traffic in transit between endpoints. It does not encrypt their stored files or prevent an authorized or compromised endpoint from reading received data.\n\nA private overlay is not automatically a full-tunnel internet VPN. Joining a Labnet does not configure an internet exit node, expose the whole LAN or grant access to every organization machine. Approved memberships and implemented policy determine connectivity. Upstream NetBird capabilities are not automatically LabDesk features.',
        [
          'src/labdesk/labnet.rs',
          'https://www.wireguard.com/protocol/',
          'https://docs.netbird.io/about-netbird/how-netbird-works'
        ],
        isManual: true),
    HelpEntry(
        'manual-network-components',
        'Control plane, direct traffic and relay traffic',
        'Coordination and application traffic follow different paths.',
        '',
        'LabDesk\'s service authorizes enrollment and network access, then calls NetBird\'s management API with a server-held credential. NetBird distributes permitted peer information and policies. Signaling and NAT traversal help endpoints find a usable path.\n\nWhen endpoints can reach one another, encrypted WireGuard traffic takes the direct path. Otherwise NetBird can forward the encrypted packets through relay infrastructure. The relay does not terminate the inner WireGuard encryption. It can still observe transport metadata such as endpoint connections, timing and volume; it can add latency and bandwidth cost.\n\nA remote-session TCP connection can be called direct at the application layer while its underlying NetBird path is relayed. Inspect daemon peer connection type and recent handshake, then correlate source/destination addresses and routes. An address in 100.64.0.0/10 does not prove which VPN owns that route. Restrictive firewalls can prevent both usable paths.',
        [
          'src/client.rs',
          'src/labdesk/labnet.rs',
          'flutter/lib/labdesk/models/overlay_state.dart',
          'https://docs.netbird.io/about-netbird/how-netbird-works'
        ],
        isManual: true),
    HelpEntry(
        'manual-network-authorization',
        'Consent, membership and session grants',
        'Network reachability and permission to operate a machine are separate decisions.',
        '',
        'Fleet membership organizes inventory and limits management scope. Labnet membership changes network policy. An invited machine accepts or declines through its authenticated machine channel; choosing an organization in the console does not approve an invitation.\n\nA managed session requests a temporary, directional TCP policy between authorized controller and target groups. The service creates a short-lived target login ticket. The target receives it through the signed machine channel, installs it through local IPC, and acknowledges readiness. The controller requires a connected daemon, a known target peer and acknowledgement of the current target login ticket. In lazy connection mode, the authenticated application dial activates the WireGuard path; in regular mode, preparation also waits for the peer to report Connected.\n\nThe target consumes a ticket once. The privileged spent-ticket ledger persists consumed IDs before authentication succeeds; corrupt or unwritable storage rejects authentication rather than forgetting prior use. Failed setup and session termination request network-grant release. The desktop tracks failed release requests for retry; revocation immediately ends broker authorization and expires tickets, while provider-policy cleanup is persisted for scheduled retry. A cleanup request is not evidence that every distributed policy has already disappeared.\n\nStanding Labnet access and Full access can outlive a session grant. Review these as network permissions. A permitted TCP path does not itself authorize a shell command, file operation or desktop login.',
        [
          'labdesk-site/src/worker/routes/overlay.ts',
          'labdesk-site/src/worker/routes/agent-overlay.ts',
          'src/labdesk/ticket.rs',
          'flutter/lib/labdesk/services/overlay_session.dart'
        ],
        isManual: true),
    HelpEntry(
        'manual-network-keys',
        'Keys, identities and server trust',
        'Tunnel identity, signed-report identity and remote-session identity serve different purposes.',
        '',
        'NetBird keeps its WireGuard private identity on the endpoint and shares public identity for coordination. LabDesk seeds a dedicated profile and controls the daemon through its privileged service. The state contains private key material and must be protected during backup and local administration. File permissions are not a claim of hardware-backed or encrypted-at-rest storage.\n\nSeparately, the collector has an Ed25519 identity for signed LabDesk service requests, and the remote-session protocol has a peer identity key for authenticating the far endpoint. These keys are not interchangeable. A display name, bearer token or overlay IP is not a substitute.\n\nControl services remain trusted for identity mapping, authorization and policy distribution. LabDesk checks the reported address against the unique peer in the machine\'s assigned group. The management peer API used here does not expose the WireGuard public key for independent comparison; this address check is not a separate WireGuard key attestation.\n\nReinstallation or state restoration can affect identity. Diagnose mismatches through enrollment and source evidence; do not copy private identity between machines or weaken authentication to force a connection.',
        [
          'src/labdesk/labnet.rs',
          'src/labdesk/identity.rs',
          'labdesk-site/src/worker/netbird.ts',
          'labdesk-site/src/worker/routes/agent-overlay.ts'
        ],
        isManual: true),
    HelpEntry(
        'manual-session-encryption',
        'Remote-session encryption inside the tunnel',
        'Managed Labnet sessions authenticate and encrypt an application stream in addition to WireGuard transport.',
        '',
        'The authorized broker response provides the target\'s reported remote-session identity key. The target must prove this identity in the session handshake. The managed overlay path is accepted only after the stream installs its encryption key; a reachable socket with missing or mismatched identity does not pass.\n\nThe core exchanges a symmetric key through its public-key handshake and protects framed messages with sodium secretbox. This key and protocol are distinct from WireGuard. An ordinary application using a Full access Labnet does not automatically acquire LabDesk\'s additional session layer.\n\nHTTPS also protects service requests in transit, but terminates at the service. The service processes inventory, tickets and job information intentionally submitted to it. Tunnel encryption does not imply that the operator cannot read stored operational data.\n\nManaged connections use the authorized Labnet path. LabDesk does not fall back to an external ID-discovery or remote-desktop relay provider when that path fails. Check machine enrollment, approved membership, target readiness and the session error before retrying.',
        [
          'src/client.rs::secure_connection_with_pk',
          'src/client.rs::secure_with_sign_pk',
          'libs/hbb_common/src/tcp.rs',
          'src/server/connection.rs'
        ],
        isManual: true),
    HelpEntry(
        'manual-network-operations',
        'Deployment and operational evidence',
        'Inspect enrollment, policy, daemon transport and application readiness independently.',
        '',
        'The integration bundles a LabDesk-managed NetBird client. Check the installed daemon version when collecting diagnostics. It uses npipe://labdesk-netbird on Windows and unix:///var/run/labdesk-netbird.sock on Linux, with state at C:/ProgramData/LabDesk/netbird or /var/lib/labdesk/netbird. The UI asks the privileged process over LabDesk IPC; opening Network does not enroll a machine.\n\nUseful evidence includes daemon status, peer ID, assigned address, connection type, handshake age, interface/route, ticket readiness and application authentication. A stale inventory row, enabled preference or running service proves only that individual fact. Adapter RX/TX totals are cumulative bytes, not current speed.\n\nA control-plane outage can prevent new enrollment, policy changes or session preparation even if an already configured tunnel retains a path. Do not assume revocation, existing sessions and recovery have identical timing.\n\nThese chapters describe implemented development source. Real installed-client, direct/relay and independent-network acceptance remains necessary for release claims. Site-to-site routing, exit nodes, general subnet routing and other upstream enterprise capabilities are not promised by the current controls.',
        [
          'src/labdesk/labnet.rs',
          'flutter/lib/labdesk/services/overlay_enrolment.dart',
          'flutter/lib/labdesk/services/overlay_session.dart'
        ],
        isManual: true),
  ],
  'home': [
    HelpEntry(
        'manual-dashboard-pipeline',
        'From machine reports to dashboard graphics',
        'Widget styles are different presentations of the same scoped measurements.',
        '',
        'The console obtains inventory and collector data for the active organization. Each widget intersects its saved selection with server-owned fleet membership and the fleet filter. Visual, Compact and Detailed do not install different monitoring agents.\n\nAverages include only available, current values and name their contributors. Missing readings remain unavailable instead of becoming zero. Fetching a report again does not make an old source timestamp current. Percentage values and timestamps are validated before presentation.\n\nHistory uses elapsed timestamp spacing. Gaps stay visible; unrelated sample times are not combined into an invented synchronized fleet average. Refresh requests stored information, not an immediate sample or upload from every machine.',
        [
          'flutter/lib/labdesk/screens/home_dashboard.dart',
          'flutter/lib/labdesk/screens/dashboard_widgets.dart',
          'flutter/lib/labdesk/models/machine_metrics.dart'
        ],
        isManual: true),
    HelpEntry(
        'manual-dashboard-storage',
        'Layout storage and editing',
        'Customization changes local presentation state, not collection or authorization.',
        '',
        'The twelve-column editor stores a versioned layout containing report type, style, machine scope, position and dimensions. It validates bounds and packs deterministically when closing gaps. Edits remain a draft until Save; Undo keeps up to 30 draft states and Cancel restores the saved layout.\n\nPreference keys include the account and organization. Context changes clear drafts and invalidate older asynchronous results. This is local installation storage, not cross-device synchronization or a backup service.\n\nResizing affects display space, not reporting cadence. Removed authorization is still enforced even if a saved layout contains a machine ID. Narrow screens adapt editing controls, and reduced-motion preferences suppress position animations.',
        [
          'flutter/lib/labdesk/models/dashboard_layout.dart',
          'flutter/lib/labdesk/services/organization_context.dart'
        ],
        isManual: true),
  ],
  'fleet': [
    HelpEntry(
        'manual-telemetry-flow',
        'Collector, service and console data flow',
        'Fleet monitoring is an asynchronous reporting pipeline independent of an open desktop session.',
        '',
        'The collector samples the operating system and initiates signed POST /agent/batch uploads. The Cloudflare Worker validates the request, updates latest machine state in D1 and stores historical batches and optional drive, attribute and job-result data. Browser and native health views read that stored state; session measurements such as round-trip time come from a separate live connection.\n\nEd25519 signs a domain-separated message containing HTTP method, path and query, timestamp and SHA-256 of the raw body. The timestamp window is 120 seconds. The service looks up the enrolled machine public key and checks revocation. A human bearer token does not authenticate this machine route. Signatures authenticate requests; HTTPS supplies transport encryption.\n\nBatch windows and drive samples are deduplicated, older timestamps cannot replace newer hot state, and results update eligible jobs. This is not universal exactly-once execution. The service intentionally receives readable operational data; apply organizational access and data-handling policies to hostnames, addresses, inventory and output.',
        [
          'src/labdesk/collector.rs',
          'labdesk-site/src/worker/agent-auth.ts',
          'labdesk-site/src/worker/routes/agent-ingest.ts',
          'labdesk-site/src/worker/index.ts'
        ],
        isManual: true),
    HelpEntry(
        'manual-health-history',
        'Freshness, aggregation and retention',
        'Measurement time, delivery time and query limits all affect the visible history.',
        '',
        'Service reachability and measurement freshness are different calculations. Home uses three reporting intervals, with a minimum of three minutes, for measurement freshness. The baseline service uses twice the upload interval for reachability. Integration is adding a fixed grace deadline during reporting-policy transitions; verify the deployed version before relying on that change. Missing and future timestamps need explicit unknown/unavailable treatment.\n\nThe hourly task folds completed hours into CPU/memory averages and maxima, fullest-filesystem maximum, sample count and observed minutes. It catches up at most six hours per invocation. Late batches for an already folded hour are not automatically added to that summary.\n\nMaintenance targets are seven days for raw history and 35 days for hourly summaries, but raw batches also have a 4,096-per-machine storage cap and a 2,016-per-query cap. At one new batch each minute those caps represent about 2.8 days stored and 1.4 days per response. Do not interpret seven days as guaranteed continuous raw history. Bounded cleanup and rollup progress also affect deletion timing.\n\nCPU and memory are used percentages; filesystem summary is the fullest reported filesystem, while drive condition is separate. Home\'s 90% attention threshold is a display rule, not the service rule engine.',
        [
          'flutter/lib/labdesk/models/machine_metrics.dart',
          'labdesk-site/src/worker/routes/org.ts',
          'labdesk-site/src/worker/scheduled.ts',
          'labdesk-site/src/worker/routes/agent-ingest.ts'
        ],
        isManual: true),
  ],
  'jobs': [
    HelpEntry(
        'manual-interactive-tools',
        'Native tools and terminal execution',
        'The native tool catalog and service job queue are different execution paths.',
        '',
        'Native tools build platform-specific commands, prepare authorized target connections and parse each run\'s output into tables. Results are snapshots of a run, not continuously refreshed server inventory. A persistent PTY supplies interactive terminal input and output.\n\nA background connection cannot satisfy every password, second-factor or operating-system prompt. Some work requires an interactive session, and tool availability depends on platform and installed utilities. Destructive actions ask for confirmation, but confirmation is not rollback.\n\nA transport response, parsed table and observed process exit are different evidence. The final integration is tightening completion reporting to require observed exit information. Inspect error, timeout and exit state rather than calling a dispatched command complete. Website jobs instead use catalog validation, approval and collector delivery, documented in their own chapter.\n\nThe pending outcome contract maps outcome_unobserved and io_error to terminal service state unconfirmed, shown as Outcome unknown. An active-user command may have launched without an observable exit; an I/O error does not prove whether launch occurred. True policy refusals remain refused. Execution could not be confirmed: check target state before retrying. This mapping still requires integration and installed-version verification.',
        [
          'flutter/lib/labdesk/services/tool_catalog.dart',
          'flutter/lib/labdesk/models/tool_models.dart',
          'flutter/lib/labdesk/screens/tools_screen.dart'
        ],
        isManual: true),
    HelpEntry(
        'manual-scripts',
        'Saved scripts and side effects',
        'Scripts execute in a target environment and require platform-aware validation.',
        '',
        'The current native conversion strips blank/comment-only lines and joins the remaining lines with semicolons for the shell transport. It is not equivalent to transferring and executing an arbitrary multiline script file. Constructs depending on layout, quoting, shell state or a particular interpreter can behave differently.\n\nThe target identity, execution mode and connection permissions determine the effect. Avoid embedding long-lived credentials in commands or assuming output is hidden from authorized viewers. A timeout does not prove the command never ran or that a remote process stopped.\n\nSaved script and automation data is scoped to the account and organization. Importing old unscoped data is explicit. Validate the target\'s resulting state before repeating interrupted work, especially after destructive operations.',
        [
          'flutter/lib/labdesk/models/tool_models.dart',
          'flutter/lib/labdesk/services/tool_catalog.dart',
          'flutter/lib/labdesk/services/organization_context.dart'
        ],
        isManual: true),
  ],
  'automation': [
    HelpEntry(
        'manual-local-rules',
        'The desktop rule engine',
        'Desktop Automation is evaluated locally while the console is open.',
        '',
        'A rule combines trigger, target, action and cooldown. The engine establishes a baseline on load. Availability triggers compare consecutive known states; level conditions latch after firing and re-arm when the condition becomes false. Cooldown limits repeat firings per rule and machine.\n\nTime-of-day rules follow the console clock. Sleep, missing observations and application shutdown affect evaluation; closing the console does not move the rule to an always-on scheduler. Run now bypasses trigger/cooldown and uses the same action and log path.\n\nLocal rules are account/organization-scoped. Imported legacy rules start paused. Actions still need target permissions and a usable connection. Sending Wake-on-LAN, for example, records an attempt rather than proof that the machine woke.',
        [
          'flutter/lib/labdesk/services/automation_engine.dart',
          'flutter/lib/labdesk/models/automation_models.dart'
        ],
        isManual: true),
    HelpEntry(
        'manual-two-engines',
        'Desktop automation versus service health rules',
        'These engines have different storage, clocks and lifetimes.',
        '',
        'Desktop rules are local preferences evaluated by an open console. Website health rules are database records evaluated by the Worker\'s minute scheduler. They are not synchronized versions of one rule, and editing one does not automatically change the other.\n\nService evaluation persists condition/cooldown state per rule and machine and uses stored collector readings. Its schedules use UTC, whereas desktop time-of-day rules follow the local console clock. Neither engine is a continuous sensor stream.\n\nThe current website baseline lists and toggles stored rules; a creation editor is separate integration work. Distinguish the controls in the installed version before promising that an operator can configure a server rule from the desktop Automation page.',
        [
          'flutter/lib/labdesk/services/automation_engine.dart',
          'labdesk-site/src/worker/scheduled.ts',
          'labdesk-site/src/worker/health-engine.ts',
          'labdesk-site/src/worker/routes/rules.ts'
        ],
        isManual: true),
  ],
  'device': [
    HelpEntry(
        'manual-device-services',
        'Local identity, enrollment and services',
        'Registering a collector and enabling its private network are separate operations.',
        '',
        'Enrollment registers a machine signing identity in an organization/fleet. The privileged process holds that identity and performs signed machine operations. The graphical console asks through local IPC rather than using a user bearer as a machine signature.\n\nLabnet enablement separately prepares the owned daemon, obtains enrollment material, waits for connectivity, reports the address and binds the direct listener. Installed, running, connected and ready describe different stages. Service reconciliation can run without the Flutter window and must respect explicit disable.\n\nAccount switching changes the user\'s inventory context. It does not silently enroll the collector in a different organization, approve a Labnet invitation or replace another VPN\'s state. Protect identity/state backups as secret-bearing operational data.',
        [
          'src/labdesk/identity.rs',
          'src/labdesk/labnet.rs',
          'flutter/lib/labdesk/screens/enrol_card.dart',
          'flutter/lib/labdesk/services/overlay_enrolment.dart'
        ],
        isManual: true),
    HelpEntry(
        'manual-device-diagnostics',
        'Diagnostics and self-healing',
        'Observed state and requested repair behavior are not the same thing.',
        '',
        'Machine ID identifies a connection peer, display name labels it, and a temporary or saved password is an authentication secret. Renaming is not key rotation. Service availability differs by platform.\n\nDiagnostics report adapter information, counters and available network observations with source timestamps. An unprobed internet condition stays unprobed instead of becoming offline. Received/transmitted totals are accumulated bytes, not current speed.\n\nThe self-healing preference records desired behavior for the local service. Its reported step and timestamp indicate attempted work; enabling it is not proof of restored connectivity. It is independent of desktop Automation and service health rules.',
        [
          'flutter/lib/labdesk/screens/this_machine_screen.dart',
          'flutter/lib/labdesk/screens/selfheal_card.dart',
          'src/labdesk/netview.rs'
        ],
        isManual: true),
    HelpEntry(
        'manual-linux-display',
        'Linux desktop and login-screen requirements',
        'A logged-in desktop and the display manager\'s login screen have different capture requirements.',
        '',
        'For unattended Linux desktop access, start by identifying the remote display server and selecting an X11/Xorg user session through the distribution\'s login screen. Configure the display manager separately if access before login is required; choosing Xorg for one user does not prove the login screen itself uses X11.\n\nThis implementation explicitly rejects a Wayland login screen. A logged-in Wayland desktop is a separate case. After any display-manager change, verify reconnect after logout before relying on unattended access. Use the distribution\'s documented configuration, not a universal restart command that could terminate working sessions.\n\nFor logged-in Wayland capture failures, inspect the user\'s PipeWire and desktop portal. Clear Wayland screen selection, when available for an existing saved selection, then reconnect and choose the intended display. Portal restore-token support varies, so saved selection is not a guarantee of unattended reconnection. These are source-backed prerequisites and troubleshooting steps, not a claim of validation on every distribution.',
        [
          'src/server/connection.rs',
          'src/platform/linux.rs',
          'flutter/lib/desktop/pages/desktop_setting_page.dart',
          'src/lang/en.rs'
        ],
        isManual: true),
    HelpEntry(
        'manual-linux-headless',
        'Headless Linux session setup',
        'Headless desktop access still needs a graphical session and operating-system authentication.',
        '',
        'Install Xorg, a graphical desktop session represented under /usr/share/xsessions/, and the dummy Xorg video driver used by the packaged configuration. The desktop/PAM configuration must work. A bare command-line installation is not enough; do not infer that every desktop environment is supported.\n\nEnable Allow headless Linux sessions in LabDesk\'s security settings. When prompted, supply the remote Linux operating-system username and password. These credentials authorize starting that user\'s desktop and are separate from the LabDesk account and connection password.\n\nThe package supplies an Xorg configuration and startwm.sh startup script; the script allows distribution-specific adaptation. Review the installed package\'s paths and session command, then verify an actual headless connection and reconnect before treating the setup as unattended-ready. Final identity/package migration is under integration, so legacy-named paths may differ in older builds.',
        [
          'src/platform/linux_desktop_manager.rs',
          'res/xorg.conf',
          'res/startwm.sh',
          'flutter/lib/desktop/pages/desktop_setting_page.dart'
        ],
        isManual: true),
    HelpEntry(
        'manual-macos-permissions',
        'macOS screen and input permissions',
        'macOS grants capture and control permissions locally; a remote account cannot substitute for them.',
        '',
        'Open LabDesk locally and follow its Configure prompts. In System Settings, open Privacy & Security. Enable LabDesk under Screen & System Audio Recording for sharing this Mac\'s desktop (the app calls this Screen Recording), and under Accessibility to allow incoming remote control.\n\nInput Monitoring allows LabDesk to capture local keyboard input when this Mac controls another machine. Follow any macOS request to quit/reopen the app, then retry the intended connection. Permission is granted to the installed application; verify the intended LabDesk entry after an upgrade or identity migration.\n\nOutgoing-only builds skip the incoming screen/control checks. Full Disk Access is not a blanket requirement established by these permission checks. Panel names and prompts can vary with macOS version. These steps reflect source checks and Apple\'s permission controls; final installed macOS acceptance is a separate release gate.',
        [
          'flutter/lib/desktop/pages/desktop_home_page.dart',
          'src/platform/macos.rs',
          'https://support.apple.com/guide/mac-help/mchld6aa7d23/mac',
          'https://support.apple.com/guide/mac-help/mh43185/mac',
          'https://support.apple.com/guide/mac-help/mchl4cedafb6/mac'
        ],
        isManual: true),
  ],
  'sessions': [
    HelpEntry(
        'manual-session-paths',
        'Connection modes and transport layers',
        'The mode selects an application capability; the route carries it to the peer.',
        '',
        'Desktop control, camera viewing, file transfer, terminal and forwarding have distinct behaviors and platform requirements. Managed sessions prepare authorization and the Labnet path first. RDP/administrator modes have platform gates, and terminal modes are labeled beta.\n\nWireGuard encrypts the overlay packets, and LabDesk\'s separate remote-session handshake authenticates the target and encrypts framed application data. A direct application TCP stream can use an underlying relayed NetBird tunnel. Inspect daemon evidence to distinguish those layers.\n\nLabDesk uses its owned machine inventory and Labnet authorization for managed connections. The application does not require users to choose a separate ID server or remote-desktop relay profile. Network reachability alone does not grant permission to operate the target.',
        [
          'flutter/lib/labdesk/screens/connect_screen.dart',
          'flutter/lib/labdesk/services/overlay_session.dart',
          'src/client.rs'
        ],
        isManual: true),
    HelpEntry(
        'manual-session-lifetime',
        'Measurements, actions and session lifetime',
        'Sessions are live application connections, not persistent health collectors.',
        '',
        'The console reuses connection-window measurements and chat streams. It does not create a second background messaging service. Closing a session removes its live-only measurements; stored collector history remains a separate source.\n\nManaged setup and use track network grants. Failed setup and termination request release, while the desktop tracks overlapping grants and failed release requests. Closing a window is not evidence that every remote process stopped or that all distributed policy cleanup completed.\n\nNavigating between machine views does not execute an action. Actions declare session and destructive-operation requirements. If work is interrupted, verify target identity, observed result and final machine state before retrying.',
        [
          'flutter/lib/labdesk/screens/sessions_screen.dart',
          'flutter/lib/labdesk/screens/actions_screen.dart',
          'flutter/lib/labdesk/services/overlay_session.dart'
        ],
        isManual: true),
    HelpEntry(
        'manual-keyboard-modes',
        'Keyboard modes and input translation',
        'Choose a mode according to keyboard layout and peer support, then test ordinary input and shortcuts.',
        '',
        'During a desktop session, open Keyboard Settings in the remote toolbar. Map mode sends mapped physical key codes, so the remote layout determines characters. Translate mode, labeled beta, attempts local Unicode text with mapped-key fallback. Legacy mode generates characters locally and resolves keys remotely as a compatibility path.\n\nAvailable modes depend on peer version, platform and input source. Remote Wayland exposes Map only, and the desktop input-capture path can restrict the list to its supported mode. View-only connections disable changes. The selected mode is saved in that peer\'s configuration.\n\nAfter changing modes, test letters, punctuation, modifiers and application shortcuts using the actual local and remote layouts. A correct text character does not prove every shortcut maps identically. Keyboard mode affects input encoding; it does not grant missing remote-control or operating-system permissions.',
        [
          'flutter/lib/desktop/widgets/remote_toolbar.dart',
          'src/keyboard.rs',
          'src/client.rs'
        ],
        isManual: true),
  ],
  'organizations': [
    HelpEntry(
        'manual-authorization',
        'Organization context and authorization',
        'The selected organization scopes a request; the service still validates authority.',
        '',
        'Native organization discovery resolves memberships for the signed-in bearer, and selection is verified before adoption. Organization requests identify that context. Server checks resolve current account state, membership, capability and fleet restrictions; a caller-supplied machine ID is never proof of ownership.\n\nOwner, technician and viewer have different capabilities. Fleet restrictions further narrow the target set. Browser cookie sessions and native app bearer sessions authenticate differently but share the service authorization boundary.\n\nChanging context clears cached/draft state and invalidates earlier asynchronous results, including rapid A-to-B-to-A switches. Cleanup retains the initiating operation\'s authority. This isolation does not enroll a local device or grant network membership.',
        [
          'flutter/lib/labdesk/services/organization_context.dart',
          'labdesk-site/src/worker/org.ts',
          'labdesk-site/src/worker/routes/client-api.ts'
        ],
        isManual: true),
    HelpEntry(
        'manual-settings',
        'Settings and legacy profiles',
        'Presentation preferences, connection configuration and network policy have different scope.',
        '',
        'Dashboard, scripts and local automation use versioned account/organization preference keys. These are installation-local values, not cross-device synchronization or server backup. Appearance and reduced motion do not change operational thresholds.\n\nChoose the organization that owns the machines you want to manage. Fleet filters narrow its inventory; Labnet membership controls network access. Collector uploads and dashboard refresh are separate operations. Home layouts in the browser are saved for the current account and organization on that browser; native preferences belong to the installation.\n\nTerms remain a review draft under TrapLab Studios pending operator legal details and publication. Viewing Help or Terms sends no remote-machine command and is not recorded by these views as agreement acceptance. A contractual SLA, retention guarantee or compliance certification needs separate evidence and policy.',
        [
          'flutter/lib/labdesk/screens/settings_screen.dart',
          'flutter/lib/labdesk/services/organization_context.dart',
          'flutter/lib/labdesk/screens/terms_dialog.dart'
        ],
        isManual: true),
  ],
  'glossary': [
    HelpEntry(
        'manual-layers',
        'Vocabulary for architecture and security',
        'Identify the layer before interpreting a security or availability claim.',
        '',
        'Control plane means services coordinating identity, policy and setup. Data plane means the path carrying application traffic. A peer is a network participant. An overlay is a virtual network built over another network. WireGuard is the tunnel protocol; NetBird provides coordination and connection management around it.\n\nA relay forwards traffic when endpoints cannot use a direct path. NAT traversal attempts to establish such a path through address translation; it does not guarantee success through every firewall. Private identity keys, public keys and symmetric session keys have different roles and lifetimes.\n\nAuthentication establishes identity. Authorization decides permitted actions. Consent is explicit approval. Encryption protects a defined path; it does not replace those decisions. Revocation removes authority, with enforcement timing affected by the component and already-issued credentials.',
        [
          'src/labdesk/labnet.rs',
          'src/client.rs',
          'labdesk-site/src/worker/org.ts',
          'labdesk-site/src/worker/agent-auth.ts'
        ],
        isManual: true),
    HelpEntry(
        'manual-evidence',
        'Vocabulary for measurements and execution',
        'Time, source and units are part of the value.',
        '',
        'A sample is a measurement at a source time. A batch groups samples for upload. Cadence is a configured interval, not guaranteed delivery. Retention describes storage maintenance subject to caps, and aggregation combines measurements over a defined contributor set and window.\n\nA gauge is a point-in-time value; a counter accumulates activity; a rate divides change by elapsed time. Uptime is time since boot, not historical service availability.\n\nQueued, approved, dispatched, running and completed are different execution stages. Acknowledged means receipt or human review, not necessarily repair. Unknown is missing evidence, not a measured failure. Preserve these distinctions in operational reports.',
        [
          'flutter/lib/labdesk/models/machine_metrics.dart',
          'flutter/lib/labdesk/models/tool_models.dart',
          'labdesk-site/src/worker/routes/agent-ingest.ts'
        ],
        isManual: true),
  ],
};
