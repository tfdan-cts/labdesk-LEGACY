part 'help_manual.dart';

/// User documentation reviewed against these named native and service sources.
/// References are internal traceability, not links or executable instructions.
class HelpEntry {
  const HelpEntry(this.id, this.title, this.meaning, this.action,
      this.technical, this.references,
      {this.isManual = false});
  final String id;
  final String title;
  final String meaning;
  final String action;
  final String technical;
  final List<String> references;
  final bool isManual;
  String get searchText => '$title $meaning $action $technical'.toLowerCase();
}

class HelpTopic {
  const HelpTopic(this.id, this.title, this.summary, this.entries);
  final String id;
  final String title;
  final String summary;
  final List<HelpEntry> entries;
  List<HelpEntry> get manual => _helpManuals[id] ?? const [];
}

const _home = [
  'flutter/lib/labdesk/screens/home_dashboard.dart',
  'flutter/lib/labdesk/screens/dashboard_widgets.dart',
  'flutter/lib/labdesk/models/dashboard_layout.dart'
];
const _health = [
  'flutter/lib/labdesk/models/machine_metrics.dart',
  'flutter/lib/labdesk/models/machine_state.dart',
  'labdesk-site/src/worker/routes/org.ts::reachability'
];
const _tools = [
  'flutter/lib/labdesk/models/tool_models.dart',
  'flutter/lib/labdesk/screens/tools_screen.dart',
  'flutter/lib/labdesk/services/tool_catalog.dart'
];
const _automation = [
  'flutter/lib/labdesk/models/automation_models.dart',
  'flutter/lib/labdesk/services/automation_engine.dart',
  'flutter/lib/labdesk/screens/automation_screen.dart'
];
const _labnets = [
  'flutter/lib/labdesk/models/labnet.dart',
  'flutter/lib/labdesk/models/overlay_state.dart',
  'flutter/lib/labdesk/services/overlay_enrolment.dart',
  'flutter/lib/labdesk/services/overlay_session.dart'
];
const _device = [
  'flutter/lib/labdesk/screens/this_machine_screen.dart',
  'flutter/lib/labdesk/screens/enrol_card.dart',
  'flutter/lib/labdesk/screens/selfheal_card.dart',
  'flutter/lib/labdesk/models/net_view.dart'
];
const _sessions = [
  'flutter/lib/labdesk/screens/connect_screen.dart',
  'flutter/lib/labdesk/screens/sessions_screen.dart',
  'flutter/lib/labdesk/screens/actions_screen.dart',
  'flutter/lib/labdesk/services/link_verdict.dart'
];
const _organization = [
  'flutter/lib/labdesk/services/organization_context.dart',
  'flutter/lib/labdesk/services/overlay_broker.dart',
  'flutter/lib/labdesk/screens/settings_screen.dart',
  'flutter/lib/labdesk/screens/terms_dialog.dart'
];

const helpTopics = <HelpTopic>[
  HelpTopic('updates', 'Downloads & updates',
      'Understand update requests, recurring maintenance windows and machine progress.', [
    HelpEntry(
        "installer-share-link",
        "Installer share link, expiry & revocation",
        "An installer share link lets its recipient download the selected platform’s current stable installer repeatedly for 24 hours. It is different from a single-use Labnet invitation and does not itself enroll a machine.",
        "Create a link for a published platform and select a fleet when required. Copy the secret URL while it is shown: it appears only at creation and cannot be recovered from the link list. Revoke an unwanted link or create a replacement after expiry.",
        "The service checks the link’s expiry, revocation and issuer’s current authority on each use, then resolves the current stable installer. It streams the download through the grant rather than redirecting the recipient to a permanent artifact URL. Listed metadata does not contain the secret URL.",
        ["labdesk-site/src/worker/routes/download-links.ts", "flutter/lib/labdesk/services/overlay_broker.dart"]),
    HelpEntry("update-version",
        "Reported version, available update & unsupported",
        "The installed version is the version last reported by the machine. An available update is offered by its updater. Missing status means the machine has not supplied a usable report; unsupported means it explicitly lacks that capability.",
        "Read the report time and the Check, Install and Schedule capabilities before choosing machines. An old report does not establish the current installed version.",
        "The GUI displays machine updater status independently of the published release. Version text alone does not prove upgrade ordering, platform compatibility or installation success.",
        ["flutter/lib/labdesk/screens/local_update_controls.dart", "flutter/lib/labdesk/screens/fleet_updates_screen.dart", "labdesk-site/src/app/pages/updates.tsx"]),
    HelpEntry("update-window",
        "One-time request & weekly maintenance window",
        "A one-time check looks for a release without requesting installation. Download and install requests installation during a bounded execution window. Automatic updates repeat within selected weekly windows.",
        "In Fleet Updates, choose machines and either a one-time action or automatic policy. One-time dates use your local timezone; weekly schedules use each machine’s own timezone. Installation waits for idle time.",
        "The GUI converts one-time dates to UTC instants; the service accepts a start within 366 days and an execution window up to 24 hours. Weekly days use Sunday zero and allow a 15–1440 minute window, including overnight windows. Turning off automatic updates does not cancel separate queued requests.",
        ["flutter/lib/labdesk/screens/local_update_controls.dart", "flutter/lib/labdesk/screens/fleet_updates_screen.dart", "labdesk-site/src/app/pages/updates.tsx"]),
    HelpEntry("update-progress",
        "Queued, deferred, installing & completed",
        "Queued means a request is waiting. Deferred means installation is waiting for idle time or its window. Installing means handoff is in progress. Completed requires the machine to report the new running version. Failed, cancelled and expired are different terminal outcomes.",
        "Use the machine report timestamp and request error to decide the next step. Cancel while preparation is still cancellable; once installation begins the service can refuse cancellation. Do not retry blindly after an uncertain response.",
        "A successful save is not an agent acknowledgement. Desired policy revision and reported applied revision remain separate. A machine that misses the execution window must not run that request later.",
        ["flutter/lib/labdesk/screens/local_update_controls.dart", "flutter/lib/labdesk/screens/fleet_updates_screen.dart", "labdesk-site/src/app/pages/updates.tsx"]),
    HelpEntry("update-managed",
        "Managed policy & local update settings",
        "An enrolled machine follows its organization’s update policy. Local settings cannot override it. Unmanaged machines can check, request a one-time installation, or configure automatic updates when their updater supports those actions.",
        "Owners and Fleet Admins manage updates within their assigned fleets. On an unmanaged desktop, use Settings for a weekly window or the available-update prompt for a one-time action. An explicit older automatic preference may appear as every day, all day until narrowed.",
        "Local controls read privileged service state asynchronously and re-read it after writes. A one-time local installation does not enable automatic updates. Unknown capability or management state disables mutations rather than inferring support.",
        ["flutter/lib/labdesk/screens/local_update_controls.dart", "flutter/lib/labdesk/screens/fleet_updates_screen.dart", "labdesk-site/src/app/pages/updates.tsx"]),
  ]),
  HelpTopic(
      'home',
      'Home & dashboard',
      'Home brings machine availability, health and performance into a dashboard you can arrange. Choose the machines and reports that matter to you.',
      [
        HelpEntry(
            'reports',
            'The eight reports',
            'Machine availability shows reported reachability. CPU and Memory show used capacity. Storage shows the fullest filesystem on each machine. Performance history shows stored samples. Needs attention lists detected exceptions. Fleet comparison groups machines by organization fleet. Reporting freshness shows the age of collector reports.',
            'Use a named machine to inspect it, or Explore to open the wider health view. Treat an empty report as a selection or reporting gap; it does not prove that every machine is healthy.',
            'Reports consume the selected organization inventory and health values. Visual, Compact, and Detailed change presentation, not the underlying measurements. Current percentages are accepted only when finite and within 0–100.',
            _home),
        HelpEntry(
            'scope',
            'Fleet filter, one machine, selected machines & average',
            'The fleet filter narrows the dashboard. Each report can then show all matching machines, one saved machine, a saved selection, or a current fleet average. Different reports keep independent selections and retain machine names.',
            'Open Make it yours, choose Report settings, then Machine scope. If a selected machine is outside the filter, change the filter or edit that report. An unavailable saved ID remains visible so you can remove it deliberately.',
            'The report intersects saved machine IDs with the server-owned fleet membership map. Local peer groups do not determine organization fleet membership. An average includes only available current readings and names its contributors; missing and stale readings are excluded.',
            _home),
        HelpEntry(
            'drafts',
            'Draft, Save, Cancel & Undo',
            'Make it yours opens a draft. Add, remove, duplicate, move, resize, or change a presentation while you work. Save keeps the draft; Cancel restores the saved dashboard. Undo reverses the last draft change.',
            'Choose Everyday, Technician, or Operations to try a preset as a draft. Save only after reviewing it. If saving fails, your draft stays open so you can retry. Preview mode explicitly states when persistence is unavailable.',
            'Layouts are versioned local preferences scoped to the signed-in account and organization. They are not cross-device synchronization. A context change clears the editor. Undo retains up to 30 draft states.',
            _home),
        HelpEntry(
            'grid',
            'Move, resize & Close gaps',
            'The desktop uses a 12-column grid. Moving or enlarging one report shifts reports it overlaps. Close gaps packs reports into available spaces without changing their sizes; some gaps may remain because a report cannot fit there.',
            'Drag a move handle or resize corner. Focus a handle and use arrow keys to move; use Shift + arrows to resize. Narrow screens preserve report order and provide the same size and position controls in settings.',
            'The editor bounds report count, dimensions, and coordinates. Packing is deterministic. Reduced-motion settings suppress position animations. On narrow screens the inspector occupies the editing area; close it to return to reports.',
            _home),
        HelpEntry(
            'history',
            'Real history, samples & gaps',
            'A line represents recorded measurements at their source timestamps. Missing history is shown as missing. A single sample is a reading, not a trend. A straight-looking line does not prove that the machine was observed continuously.',
            'Read the time range, sample count, and machine name together. Use Detailed history to compare CPU, memory, and fullest-filesystem use for a machine.',
            'Dashboard charts use elapsed timestamp spacing and a fixed 0–100% axis. Missing readings and long gaps break a trace. Histories from different machines are not automatically aligned into an invented average.',
            _home),
      ]),
  HelpTopic(
      'fleet',
      'Fleet states & Health',
      'Fleet organizes enrolled machines and their reported health. Use it to find a machine, understand its condition and open its management tools.',
      [
        HelpEntry(
            'reachability',
            'Online, offline & unknown',
            'Online means the source recently reported the machine present. Offline means the source reported it absent or its reporting window expired. Unknown means there is not enough current evidence. None of these alone proves that a desktop session will connect or that the machine is healthy.',
            'Check the source age and any load error before acting on a status. If Home marks a previously online machine unknown, refresh and inspect its collector or connection rather than treating the old green state as current.',
            'For organization machines, the service computes unknown when seenAt is absent, online within twice the configured flush interval, and offline after that. Home ages cached online reports to unknown after that interval, or for a future timestamp; explicit offline remains offline. Legacy ID-server registration is a separate reachability source.',
            _health),
        HelpEntry(
            'freshness',
            'Current, stale, never reported & source clock ahead',
            'Current describes a recent usable collector report. Stale means the last report is too old for a current reading. Never reported means no collector source timestamp exists. Source clock ahead means the timestamp is in the future relative to this console.',
            'Inspect Reporting freshness and the configured cadence. A console refresh fetches stored reports; it does not force the machine to take a new sample. Check the machine service, connectivity, and clock when reports do not advance.',
            'Home treats measurements as stale after three configured reporting intervals, with a minimum of three minutes. If cadence is missing, it labels a three-minute fallback. This measurement freshness rule differs from the service reachability rule. A configured reporting interval is not a guaranteed delivery time.',
            _home),
        HelpEntry(
            'reporting-policy',
            'Change a machine’s reporting interval',
            'Reporting interval is the configured collector upload cadence for the selected machine. Existing settings, including five-minute intervals, remain unchanged until you explicitly apply a new choice. A saved policy is not proof that the collector has already received it.',
            'In the selected machine’s Health view, choose 1 minute, 5 minutes, 15 minutes, or 1 hour and press Apply. An existing custom interval remains visible. Owners and technicians need write access to that machine; a read-only explanation appears when the control is unavailable. A failed save keeps your selection for retry.',
            'The service validates flushSeconds as an integer from 60 through 86400 and changes only the authorized machine. The stored value affects service reachability calculations immediately, but the collector receives it in the response to its next successful upload. Allow that upload to occur before judging the new timing. Changing the policy does not request an immediate sample or rewrite another machine’s interval.',
            [
              'flutter/lib/labdesk/screens/reporting_control.dart',
              'flutter/lib/labdesk/services/overlay_broker.dart::setReportingInterval',
              'labdesk-site/src/worker/routes/org.ts::PATCH /org/machines/:id/reporting',
              'labdesk-site/src/worker/routes/agent-ingest.ts'
            ]),
        HelpEntry(
            'metrics',
            'CPU, memory, storage & uptime',
            'CPU and memory are percentages of used capacity. Storage is the highest used percentage among the machine’s filesystems, not necessarily its system disk. Uptime is time since boot. A dash means no available reading; 0% is a real measured zero.',
            'Use the machine name and timestamp when comparing values. Open the Disk tool for individual volumes. Do not interpret missing memory or storage as free capacity.',
            'Collector metrics use cpuPct, memPct, fsWorstPct, and uptimeS. Available values can exist without an open remote session. A machine without organization collector state is not presented as reporting zeros.',
            _health),
        HelpEntry(
            'attention',
            'Needs attention & drive health',
            'Home flags current CPU, memory, or fullest-filesystem use at 90% or above, explicit offline status, overdue collector reports, and drive warnings. Drive states include OK, warning, failing, and unreadable. Unreadable means the drive check could not be read.',
            'Open the affected machine and inspect the named issue. A high percentage calls for investigation, not automatic deletion or restart. “No detected exceptions” applies only to the readings available; incomplete data is counted separately.',
            'The Home summary uses its documented 90% threshold. It is not a configurable automation rule or a complete hardware diagnosis. SMART-related worstDisk states are separate from filesystem capacity.',
            _home),
        HelpEntry(
            'sources',
            'Collector, session & known information',
            'Collector data comes from the machine’s reporting service. Session data is measured on an open connection, such as round-trip time or throughput. Known information includes identity already held by the console. Unavailable means that source has no value to offer.',
            'Connect when you need live connection measurements. Use stored collector history for machine measurements over time. Keep the source label in mind when a value disappears after a session ends.',
            'MetricSource distinguishes known, session, collector, and unavailable. Throughput is a byte rate; a network adapter’s received and transmitted totals are cumulative counters, which are a different quantity.',
            _health),
      ]),
  HelpTopic(
      'jobs',
      'Jobs, tools & terminal',
      'Tools inspect or change a selected machine; Terminal provides an interactive command session. Review the target and expected effect before running work.',
      [
        HelpEntry(
            'tool-selection',
            'Pick machines before running a tool',
            'Jobs provides tools across selected machines; a machine’s Tools tab focuses the work on that machine. Available tools include Services, Processes, Event log, Software, Disk, Network, Power, and Scripts.',
            'Review the selected machine names and operating systems, choose a tool, and run it. A selection alone does not run a command. Select all online selects only machines currently labeled online.',
            'Tools build platform-specific shell commands and parse their output into tables. The result is a response to that run, not a continuously refreshed inventory. Supported commands and actions vary by platform.',
            _tools),
        HelpEntry(
            'tool-results',
            'Loading, results, empty results, errors & timeouts',
            'A run still in progress has not produced a result. A successful empty table means the command returned no rows. An error means LabDesk could not obtain a usable result. A timeout means the allowed wait ended; it is not confirmation that the remote action never started.',
            'Read the per-machine error or output before retrying. Verify the machine state after an interrupted action. For access failures, open an interactive connection and resolve the requested password or login.',
            'ToolRunResult carries a table, error, exit code, and timedOut flag. A successful result requires a table and no error. Errors, unavailable connections, and empty tables are separate outcomes.',
            _tools),
        HelpEntry(
            'tool-actions',
            'Services, processes & power actions',
            'Start, stop, or restart a service; end a process; or request restart, shutdown, log off, or lock where the platform supports it. These actions change the remote machine.',
            'Check the machine and target in the confirmation. Stopping or restarting services, ending processes, restarting, shutting down, and logging off require confirmation. Refresh the relevant tool afterward to verify the outcome.',
            'ToolAction marks interrupting actions as destructive so the UI asks before running them. Confirmation is not an undo mechanism. Starting a service and locking are not classified as destructive by this tool model.',
            _tools),
        HelpEntry(
            'scripts',
            'Saved scripts & platform scope',
            'A saved script keeps a name, command body, and platform choice. Choose Windows, Linux, macOS, or Any machine according to the commands you actually wrote.',
            'Review the script and target machines before running it. Test on a suitable machine before a wider run. Use a platform-specific script when shell syntax differs.',
            'The current shell transport sends one command line. The saved-script conversion drops blank and comment-only lines and joins remaining lines with semicolons. It is not a general-purpose multiline script-file interpreter; shell constructs that depend on file layout may not behave as intended.',
            _tools),
        HelpEntry(
            'terminal',
            'Terminal input, output, error & notice',
            'The Terminal tab is a shell on the selected machine. Input is what you submitted, output is what the shell returned, error is a failure message, and notice is connection or console information.',
            'Confirm the selected machine, connect the terminal, and then submit a command. Use Up and Down to browse the command history in the input. Treat commands as immediate operations on that machine.',
            'The terminal uses a persistent PTY channel. A background connection cannot answer every interactive request: missing or refused saved passwords, 2FA, and OS-login prompts may require an interactive session. Terminal connection modes are labeled beta.',
            [
              'flutter/lib/labdesk/screens/terminal_screen.dart',
              'flutter/lib/labdesk/services/link_verdict.dart',
              'flutter/lib/labdesk/screens/connect_screen.dart'
            ]),
      ]),
  HelpTopic(
      'automation',
      'Automation',
      'Automation runs chosen actions when a rule matches machine state or a schedule. Desktop rules operate while this console is open.',
      [
        HelpEntry(
            'rules',
            'Rule, trigger, target, action & cooldown',
            'A rule combines a condition, target machines, an action, and an optional cooldown. Triggers include coming online, going offline, a metric above a threshold, uptime above a limit, and a schedule. Actions include a command, notification, Wake-on-LAN, and opening a desktop session.',
            'Read the rule sentence, targets, action, and platform before enabling it. Disable a rule to stop future automatic evaluations. Use the run log to check what actually happened.',
            'These desktop rules are evaluated by the local console while LabDesk is open. They are not a promise of server-side scheduling after the application closes. The engine establishes a baseline before firing a newly loaded rule.',
            _automation),
        HelpEntry(
            'rule-timing',
            'Transitions, continuous duration & schedules',
            '“Comes online” and “goes offline” refer to changes the console observed. Unknown is not treated as an offline transition. “For N minutes” requires the condition to stay true continuously. A schedule runs at its next due slot while the console is evaluating rules.',
            'Keep the console open for desktop automation. Expect a condition timer to reset if the condition clears. Do not expect missed schedule slots to replay when you reopen the application.',
            'Online/offline triggers compare consecutive known states. Level conditions latch after firing and re-arm after the condition becomes false. Cooldown bounds repeat firings per rule and machine. Time-of-day schedules use the console clock.',
            _automation),
        HelpEntry(
            'run-now',
            'Run now & run outcomes',
            'Run now deliberately tests a rule’s action against its targets without waiting for its trigger. A run without a reported outcome is still pending, not successful. A reported success or failure applies to that action attempt.',
            'Use Run now only when you intend the action to happen. Read the result detail and inspect the target before retrying a failed or interrupted operation.',
            'Run now bypasses the trigger and cooldown and writes to the same run log. Outcome is nullable: no result yet, success, or failure. Sending a Wake-on-LAN request does not by itself prove that the machine woke up.',
            _automation),
      ]),
  HelpTopic(
      'labnets',
      'Labnets & network',
      'Labnets provide private encrypted connections between approved machines. Membership controls who can join; access rules control which connections are allowed.',
      [
    HelpEntry(
        "membership",
        "Labnet, invitation, pending & approved",
        "A Labnet is an authorized network grouping. An invitation can include a person, a machine or both. A newly invited machine remains pending until it accepts through its own authenticated channel. Approved membership does not prove that the tunnel is currently ready.",
        "Review the selected Labnet and requested access before deciding. If a machine is included, choose an enrolled machine you manage and then review the separate consent request on that machine. Owners and Fleet Admins manage Labnets within their authorized scope.",
        "Account acceptance and machine approval are separate decisions. Choosing an organization does not approve an invitation, enroll a device or enable networking. A machine can belong to multiple Labnets; organization fleets and Labnet memberships remain separate.",
        ["labdesk-site/src/worker/routes/labnet-invitations.ts", "labdesk-site/src/worker/labnet-sharing.ts"]),
    HelpEntry(
        "shared-invitations",
        "Shared Labnet, guest & single-use invitation",
        "A shared Labnet gives an invited account access to that selected network. It does not add the guest to the organization or expose its unrelated fleets. Invitation links expire after 48 hours and can be accepted or refused only once.",
        "Sign in to review the network, invitation kind and granted Connect permissions. Opening the link does not accept it. Use the named recipient account when the invitation is email-bound. Ask for a new invitation if it has expired or already been used.",
        "Acceptance records scoped guest access. Machine access still needs signed machine consent. No Connect capabilities are granted by default, and machine-only invitations cannot grant a person remote-control permissions. Revocation can leave cleanup pending while network changes are confirmed.",
        ["labdesk-site/src/worker/routes/labnet-invitations.ts", "labdesk-site/src/worker/labnet-sharing.ts"]),
    HelpEntry(
        "connect-permissions",
        "Connect capabilities & pending permission changes",
        "Network membership and permission to operate a machine are separate. A session may allow viewing, control, files, terminal or another specific mode. A viewer organization role does not itself grant screen viewing.",
        "Choose the intended connection mode and inspect the target permissions. Wait while the target has not acknowledged a policy change. If LabDesk asks you to update the target, update that machine before retrying the connection.",
        "The signed session grant limits capabilities to target policy, local permissions and any explicit guest grant. Control requires view; administrator terminal requires terminal. Saved passwords and local approval do not replace managed authorization, and a session cannot expand its grant after connection.",
        ["labdesk-site/src/worker/routes/connect-permissions.ts", "labdesk-site/src/worker/routes/overlay.ts", "src/labdesk/ticket.rs"]),
    HelpEntry(
        "exit-routing",
        "Exit node, normal connection & LAN access",
        "An exit node offers an internet route through another approved machine. Normal connection clears the selected exit. Allowing access to the client’s local LAN and allowing access to the exit machine’s LAN are two different permissions.",
        "Use only choices the machine reports as supported. Read the latest report and wait for the applied selection to match the saved choice. Hosting requires consent on the exit machine; offering it from the console does not activate it.",
        "A saved preference is desired state, not a daemon acknowledgement. Exit selection, client-local LAN access and exit-side LAN isolation have separate capability and state reports. An active provider route or acknowledged selection does not establish working internet egress.",
        ["labdesk-site/src/worker/routes/exit-routing.ts", "flutter/lib/labdesk/models/exit_routing.dart", "flutter/lib/labdesk/screens/exit_routing_controls.dart"]),
    HelpEntry(
        "subnet-sharing",
        "Shared subnet, routing host & cleanup pending",
        "A shared subnet offers a specific network range through an approved routing machine. It is separate from an internet exit and does not expose a whole LAN simply because a machine joins a Labnet.",
        "Choose the routing machine, name and intended CIDR range. Review the consent request on that machine. After removing an offer or membership, keep watching pending cleanup until the service confirms the relevant network changes.",
        "Subnet sharing uses NetBird network resources, a routing host and explicit policy. Provider configuration alone is not an endpoint reachability test. Revocation removes the relevant authorization immediately, while provider cleanup can remain pending; independent membership or other grants can still allow a path.",
        ["labdesk-site/src/worker/routes/exit-routing.ts", "flutter/lib/labdesk/models/exit_routing.dart", "flutter/lib/labdesk/screens/exit_routing_controls.dart"]),
        HelpEntry(
            'access',
            'Restricted access & full access',
            'Restricted labnet access permits LabDesk’s connection port and ping between members. Full access permits every port and protocol between members.',
            'Choose full access only when that broader network access is intended. Read permission or fresh-sign-in messages before retrying sensitive changes.',
            'Full access is an explicit labnet property. Ownership and service authorization control changes. A visible labnet name or organization selection does not grant unrestricted connectivity.',
            _labnets),
        HelpEntry(
            'tunnel',
            'Direct, relayed & unknown links',
            'Direct means the overlay reports a peer-to-peer link. Relayed means the overlay reports traffic passing through a relay. Unknown means the link type has not been established. Relayed is a connection path, not automatically an error.',
            'For connection failures, check labnet on both machines and whether the target service is ready. Read the specific failure instead of assuming every network problem has the same cause.',
            'A labnet session waits for the local daemon, peer connection, and server-confirmed target readiness. It requires a complete session ticket and identity. Failure does not silently switch to another provider; that requires an explicit choice.',
            _labnets),
        HelpEntry(
            'network-report',
            'Adapters, internet verdict & network counters',
            'Network shows adapters, addresses, link state, and the machine’s internet probe. An adapter can be up without an address. Internet reachable, No internet, and Not probed yet are distinct. No network report means the collector has not provided one.',
            'Read the source timestamp and probe result. Inspect physical and overlay adapters separately when diagnosing a path. Use the tool result or a new collector report to confirm a change.',
            'Received and transmitted byte totals are cumulative counters, not instantaneous speed. Adapter kind is reported as physical, overlay, or other. Network reports are collected from the machine and are not edited by changing the console view.',
            [
              'flutter/lib/labdesk/models/net_view.dart',
              'flutter/lib/labdesk/screens/network_screen.dart',
              'flutter/lib/labdesk/screens/adapters_card.dart'
            ]),
      ]),
  HelpTopic(
      'device',
      'This device',
      'This device shows the identity, enrollment and local services of the machine you are using. Network enablement and remote-control permissions are separate controls.',
      [
        HelpEntry(
            'identity',
            'Machine ID, display name & password',
            'This device describes the computer running this console. Its machine ID is what another operator uses to reach it. The display name identifies this device to the other side. A temporary password is not a permanent credential.',
            'Copy the machine ID when arranging a connection. Use the available password controls to edit or refresh it, and share credentials only with the intended operator.',
            'Machine identity, display name, and connection password are different values. The screen labels temporary passwords explicitly. Service status can be unavailable on platforms without that service concept.',
            _device),
        HelpEntry(
            'enrollment',
            'Organization enrollment',
            'Enrollment adds this device to an organization so it can report and participate under that organization’s authorization. Signing in and choosing an organization for viewing do not enroll the device.',
            'Use Add this machine with the available account flow, or use an enrollment token from an organization owner. Choose the intended fleet before completing enrollment. Retry a failed follow-up rather than assuming enrollment itself was undone.',
            'The account enrollment flow offers fleet selection to an owner; other roles are directed to request an enrollment token. Machine enrollment is a separate operation from the bearer organization context used to browse inventory.',
            _device),
        HelpEntry(
            'labnet-service',
            'Off, working, on & error',
            'Off means labnet is disabled here. Working means setup or a state change is in progress. On means the enable sequence completed. Error includes the specific setup or connection failure. A requested setting and a confirmed running state can differ.',
            'Enable labnet when you intend this device to participate. Wait for the reported state and address. If it fails, read the service message and retry after addressing it. Disable is a network change, not a navigation action.',
            'The enable sequence prepares the daemon, obtains enrollment material, waits for Connected, reports its overlay address, and opens the direct listener on that address. Daemon status can separately be idle, connecting, connected, needs login, login failed, session expired, not installed, or unknown.',
            _labnets),
        HelpEntry(
            'self-healing',
            'Self-healing: requested versus running',
            'Self-healing asks the background service to repair this device’s internet connection. Watching means it is monitoring; cycling means it is cycling the adapter; restarting means it is restarting networking; holdoff means it is waiting after a restart.',
            'Read the reported service line beside the switch. “Waiting for the service” means the option changed but the service has not reported the new state. A switched-off option can briefly coexist with a still-running reported step.',
            'The option records desired behavior; the network report carries the running step and timestamp. Unprobed internet status is not offline. These local service repairs are distinct from Automation rules in the desktop console.',
            _device),
      ]),
  HelpTopic(
      'sessions',
      'Sessions & Connect',
      'Connect opens remote capabilities such as desktop control, file transfer and terminal. Sessions lets you return to connections that are already open.',
      [
        HelpEntry(
            'connect-modes',
            'Connect, files, camera, terminal, RDP & forwarding',
            'Connect opens a remote desktop. Other available modes include file transfer, camera, terminal, administrator terminal, RDP, and TCP port forwarding. Some modes depend on the local and remote operating systems.',
            'Choose the intended machine and mode. Resolve password, second-factor, or operating-system login prompts in the connection flow. A machine being online does not bypass these requirements.',
            'Terminal modes are labeled beta. RDP and administrator modes have platform gates. A saved connection password may be missing or refused; an unattended tool link cannot supply an arbitrary interactive OS login.',
            _sessions),
        HelpEntry(
            'active-sessions',
            'Active sessions & messages',
            'Sessions shows the conversations for current incoming and outgoing connections. Selecting a conversation lets you read that session’s transcript. A disabled message input means sending is unavailable for that session.',
            'Check the session and machine before sending a message. Use the existing session window for its remote controls. If a selected session ends, the list may select another available conversation.',
            'The console displays the same session chats used by the connection windows; it does not create a separate background messaging service. A session measurement exists only while the relevant connection provides it.',
            _sessions),
        HelpEntry(
            'machine-actions',
            'Overview actions & required connections',
            'A selected machine’s Overview offers actions such as Connect, Open terminal, Transfer files, and Capture screen. Some actions require an open session and remain disabled until one is available.',
            'Read the action description and selected machine name. Open the required session before retrying a disabled action. Review confirmation for an action that interrupts the machine.',
            'Each action declares whether it requires a session and whether it is destructive. Navigation between Overview, Health, Terminal, Tools, and Network does not itself execute one of these actions.',
            _sessions),
      ]),
  HelpTopic(
      'organizations',
      'Organizations & settings',
      'Organizations separate people, fleets and permissions. Settings controls your local preferences and advanced connection configuration.',
      [
        HelpEntry(
            'organization-context',
            'Organization context & membership',
            'An organization is the account boundary for the machines and fleets you may browse. The selector offers memberships returned for your signed-in account. Choosing another organization changes that view after the service verifies membership.',
            'Choose an available organization. If verification fails, the previous verified context stays active. Retry the choice or sign in again when the error requests it. No linked organization means there is no membership to select.',
            'The desktop lists bearer memberships through /console/organizations and verifies the chosen context before adopting it. Organization-scoped requests identify that verified context. Switching does not join a labnet, accept an invitation, or enroll the local device.',
            _organization),
        HelpEntry(
            'local-preferences',
            'Account-scoped local dashboard preferences',
            'Each account and organization has its own saved dashboard on this device. Signing out clears the active account view and draft state. Local saved preferences are not a promise of synchronization to other computers.',
            'Save dashboard changes before switching if you want to keep them. On a save error, keep the draft and retry. If a stored layout cannot be read, the default appears with an explanation.',
            'Preference keys encode account and organization identities. Version checks reject unsupported layout storage. Older request and save completions cannot overwrite a newer active context; preference writes are ordered.',
            _organization),
        HelpEntry(
            'advanced-connections',
            'Labnet connections',
            'Labnet connects enrolled machines through encrypted tunnels. Membership and access rules belong to your organization.',
            'Enroll this computer under This machine and turn on Labnet. Use Labnets to manage membership and allowed access.',
            'Fleet status comes from machine reports. A successful connection also requires the Labnet service and an authorized session.',
            _organization),
        HelpEntry(
            'appearance-terms',
            'Appearance, reduced motion & Terms',
            'Appearance changes how the console is drawn. Reduced motion limits interface animation. Neither changes machine measurements or network permissions. The Terms view is currently labeled as a draft.',
            'Choose readable appearance and motion settings for your environment. Open Terms to read its current text; opening or closing the draft does not record acceptance.',
            'Help follows the application theme and respects reduced motion. Terms are displayed as a review draft under TrapLab Studios; the UI does not convert viewing the text into legal acceptance.',
            _organization),
      ]),
  HelpTopic(
      'glossary',
      'Glossary',
      'Understand the words used throughout LabDesk, including the difference between a machine being online, reporting current data and allowing a connection.',
      [
        HelpEntry(
            'glossary-fleet',
            'Fleet, group & organization',
            'An organization is an account and authorization boundary. A fleet is a server-owned grouping inside an organization. A local group is an organizational label held by the connection inventory.',
            'Use the organization selector for account context and the fleet filter for a narrower set of machines. Do not expect a local group to grant organization access.',
            'Dashboard filtering uses server fleet IDs and machine membership, not MachineRow.group.',
            _home),
        HelpEntry(
            'glossary-collector',
            'Collector, sample, timestamp & cadence',
            'The collector reads measurements on a machine. A sample is one recorded reading. A timestamp states when a reading was taken or reported. Cadence is the configured reporting interval.',
            'Read the timestamp before treating a number as current. A refresh is a request to fetch data, not proof that a fresh sample was collected.',
            'Collector percentages and history can be absent independently. Configured cadence and actual delivery can differ because of service or network conditions.',
            _health),
        HelpEntry(
            'glossary-scope',
            'Scope, contributor & aggregate',
            'Scope is the set of machines a view or report includes. A contributor is a machine with a usable value in a calculation. An aggregate combines values, such as a current average.',
            'Check the names and contributor count before comparing averages. A missing machine is not a zero-valued contributor.',
            'Home’s optional average excludes missing and stale values and identifies contributing machines. Per-machine reports retain individual names.',
            _home),
        HelpEntry(
            'glossary-overlay',
            'Overlay, relay, enrollment & session ticket',
            'An overlay is the labnet connection layer between participating machines. A relay is an intermediate connection path. Enrollment registers a machine. A session ticket authorizes a particular connection attempt.',
            'Check both membership and readiness when a labnet connection fails. Viewing an organization is not enrollment, and receiving a ticket is not proof that a session has opened.',
            'Session preparation checks tunnel and target readiness, then tracks the grant for cleanup when the session ends or setup fails.',
            _labnets),
        HelpEntry(
            'glossary-resource',
            'Filesystem, throughput, counter & uptime',
            'A filesystem is a storage volume or mounted storage area. Throughput is data transferred per unit of time. A counter is a running total. Uptime is elapsed time since boot.',
            'Do not compare cumulative adapter byte totals directly with a session byte-per-second rate. Use the Disk tool to see individual volumes behind the fullest-filesystem summary.',
            'The health model reports worst-filesystem used percentage and uptime seconds. Network adapter counters are cumulative; session rates are formatted separately.',
            _health),
      ]),
];

String helpTopicForContext(String context) => switch (context) {
      'dashboard' => 'home',
      'machines' || 'health' => 'fleet',
      'tools' || 'toolbox' || 'terminal' => 'jobs',
      'network' => 'labnets',
      'thisMachine' || 'this-device' || 'this-machine' || 'install' => 'device',
      'connect' || 'overview' || 'actions' => 'sessions',
      'settings' || 'account' || 'terms' => 'organizations',
      _ => helpTopics.any((topic) => topic.id == context) ? context : 'fleet',
    };

List<({HelpTopic topic, HelpEntry entry})> searchHelp(String query) {
  final words = query
      .toLowerCase()
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return const [];
  return [
    for (final topic in helpTopics)
      for (final entry in [...topic.entries, ...topic.manual])
        if (words.every((word) =>
            '${topic.title.toLowerCase()} ${entry.searchText}'.contains(word)))
          (topic: topic, entry: entry)
  ];
}
