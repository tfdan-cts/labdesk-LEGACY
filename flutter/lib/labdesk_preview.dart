// Design harness for the LabDesk console.
//
// Renders the real console screens against fixture data with no FFI, no Rust
// core and no peer connection, so the interface can be looked at and judged in
// seconds. The screens are the shipping widgets; only the data is fixture.
//
//   flutter run -t lib/labdesk_preview.dart -d windows
//
// Desktop only. This project has no `web/` directory, so the web device is not
// available to it and `-d chrome` fails with "This project is not configured
// for the web" before it reaches anything here.
//
// Nothing here may import the FFI layer. The moment it does, the harness stops
// building without the generated bridge and the fast loop is gone.
import 'package:flutter/material.dart';

import 'common/labdesk_peer_status.dart';
import 'labdesk/charts/reachability_chart.dart';
import 'labdesk/models/automation_models.dart';
import 'labdesk/models/labnet.dart';
import 'labdesk/models/machine_metrics.dart';
import 'labdesk/models/machine_row.dart';
import 'labdesk/models/machine_state.dart';
import 'labdesk/models/net_view.dart';
import 'labdesk/models/organization_context.dart';
import 'labdesk/screens/adapters_card.dart';
import 'labdesk/screens/console_shell.dart';
import 'labdesk/screens/enrol_card.dart';
import 'labdesk/screens/home_dashboard.dart';
import 'labdesk/screens/labnet_card.dart';
import 'labdesk/screens/automation_screen.dart';
import 'labdesk/screens/network_screen.dart';
import 'labdesk/screens/selfheal_card.dart';
import 'labdesk/screens/settings_screen.dart';
import 'labdesk/screens/terminal_screen.dart';
import 'labdesk/screens/this_machine_screen.dart';
import 'labdesk/services/overlay_enrolment.dart';
import 'labdesk/theme/console_theme.dart';

void main() => runApp(const LabDeskPreviewApp());

/// Fixed so readouts are deterministic across screenshots and goldens.
final _now = DateTime.utc(2026, 8, 29, 4, 30);

class LabDeskPreviewApp extends StatefulWidget {
  const LabDeskPreviewApp({super.key});

  @override
  State<LabDeskPreviewApp> createState() => _LabDeskPreviewAppState();
}

class _LabDeskPreviewAppState extends State<LabDeskPreviewApp> {
  bool _refreshing = false;
  bool _selfHeal = true;
  var _rules = <Rule>[];
  String _selectedId = '482910337';

  final _terminal = <TerminalLine>[
    const TerminalLine('Session opened on workshop-nas',
        kind: TerminalLineKind.notice),
    const TerminalLine('uptime', kind: TerminalLineKind.input),
    const TerminalLine(
        ' 04:30:12 up 6 days,  2:14,  1 user,  load average: 0.14, 0.09, 0.08'),
    const TerminalLine('df -h /', kind: TerminalLineKind.input),
    const TerminalLine('Filesystem      Size  Used Avail Use% Mounted on'),
    const TerminalLine('/dev/sda2       458G  212G  223G  49% /'),
  ];

  void _submit(String machineId, String command) {
    setState(() {
      _terminal.add(TerminalLine(command, kind: TerminalLineKind.input));
      _terminal.add(const TerminalLine(
        'The design harness has no session, so nothing ran.',
        kind: TerminalLineKind.notice,
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LabDesk console',
      theme: C.theme(),
      home: Scaffold(
        body: ConsoleShell(
          machines: _fixtures,
          samples: _samples,
          profiles: _profiles,
          profileName: 'Workshop',
          isRefreshing: _refreshing,
          lastRefreshed: _now.subtract(const Duration(seconds: 24)),
          now: _now,
          connectedIds: const {'482910337'},
          terminalLines: _terminal,
          healthFor: _healthFor,
          dashboardContextKey: 'fixture-account/workshop',
          accountName: 'Preview account',
          accountDescription: 'Fixture data · no live machines',
          organizations: const [
            OrganizationSummary(
                id: 'workshop', name: 'Workshop · Sample', role: 'owner'),
          ],
          activeOrganizationId: 'workshop',
          onOrganizationSelected: (_) {},
          onSaveDashboard: (_) async {},
          fleets: const [
            DashboardFleet(id: 'fleet-workshop', name: 'Workshop'),
            DashboardFleet(id: 'fleet-office', name: 'Office'),
            DashboardFleet(id: 'fleet-rack', name: 'Rack'),
            DashboardFleet(id: 'fleet-garage', name: 'Garage'),
          ],
          machineFleetIds: {
            for (final machine in _fixtures)
              machine.id: {if (machine.group != null) 'fleet-${machine.group}'},
          },
          onMachineSelected: (id) => _selectedId = id,
          onTerminalSubmit: _submit,
          onRunAction: (id, action) {},
          onRefresh: () async {
            setState(() => _refreshing = true);
            await Future.delayed(const Duration(milliseconds: 1400));
            if (mounted) setState(() => _refreshing = false);
          },
          // The two labnet surfaces, with fixture state, so they can be looked
          // at beside the sections they sit among.
          hosted: {
            ConsoleSection.diagnostics: (_) => SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: AdaptersCard(
                    view: _selectedId == '482910337'
                        ? _netView
                        : MachineNetView.empty,
                    machineName: _fixtures
                        .firstWhere((machine) => machine.id == _selectedId)
                        .displayName,
                  ),
                ),
            ConsoleSection.thisMachine: (_) => ThisMachineScreen(
                  machineId: '482910337',
                  password: 'k7Qm2xLp',
                  passwordIsTemporary: true,
                  serviceRunning: true,
                  displayName: 'Workshop NAS',
                  // A fake daemon: a token that starts with "bad" is refused
                  // the way the server would, anything else is enrolled.
                  enrol: MachineEnrolCard(
                    enrol: (token) async {
                      await Future.delayed(const Duration(milliseconds: 600));
                      return token.startsWith('bad')
                          ? '{"error":"That enrolment token has expired or was already used."}'
                          : '{"machineId":"5f1c2a0e-7b3d-4c9a-9e21-0d4b8a6f3c11"}';
                    },
                  ),
                  labnet: LabnetCard(
                    state:
                        const LabnetCardState(LabnetPhase.on, ip: '100.64.0.3'),
                    onDisable: () {},
                  ),
                  selfHeal: SelfHealCard(
                    on: _selfHeal,
                    reachability: _reachability,
                    onChanged: (v) => setState(() => _selfHeal = v),
                  ),
                ),
            ConsoleSection.automation: (_) => AutomationScreen(
                  rules: _rules,
                  machines: _fixtures,
                  now: _now,
                  onSave: (next) => setState(() => _rules = next),
                  onToggle: (id, on) => setState(() => _rules = [
                        for (final r in _rules)
                          r.id == id ? r.copyWith(enabled: on) : r,
                      ]),
                  onApplyPreset: (p) => setState(
                      () => _rules = [..._rules, p.toRule('rule-${p.id}')]),
                ),
            ConsoleSection.network: (_) => NetworkScreen(
                  inbox: const LabnetInbox(
                    enrolled: true,
                    overlayIp: '100.64.0.3',
                    invitations: [
                      LabnetInvitation(
                          labnetId: 'L9',
                          name: 'Rack',
                          invitedBy: 'owner@lab-desk.net'),
                    ],
                    labnets: [
                      Labnet(
                          id: 'L1',
                          name: 'Workshop',
                          fullAccess: false,
                          owner: true,
                          members: [
                            LabnetMember(
                                deviceId: '482910337',
                                status: 'approved',
                                overlayIp: '100.64.0.3'),
                            LabnetMember(
                                deviceId: '118374662',
                                status: 'approved',
                                overlayIp: '100.64.0.7'),
                            LabnetMember(
                                deviceId: '905513280', status: 'pending'),
                          ]),
                      Labnet(
                          id: 'L2',
                          name: 'Office',
                          fullAccess: true,
                          owner: false,
                          members: [
                            LabnetMember(
                                deviceId: '482910337',
                                status: 'approved',
                                overlayIp: '100.64.0.3'),
                            LabnetMember(
                                deviceId: '330918744',
                                status: 'approved',
                                overlayIp: '100.64.0.12'),
                          ]),
                    ],
                  ),
                  thisMachineId: '482910337',
                  machines: [
                    for (final m in _fixtures)
                      NetworkMachine(id: m.id, name: m.displayName),
                  ],
                  fleets: const [
                    NetworkFleet(id: 'F1', name: 'Workshop'),
                    NetworkFleet(id: 'F2', name: 'Office'),
                  ],
                  mustNameFleet: true,
                  onRename: (_, __) {},
                  onCreate: (_, __) {},
                  onApprove: (_) {},
                  onDecline: (_) {},
                  onInvite: (_, __) {},
                  onFullAccess: (_, __) {},
                  onLeave: (_) {},
                  onRemove: (_, __) {},
                  onDelete: (_) {},
                ),
          },
        ),
      ),
    );
  }
}

/// The machine's own network, as the agent reports it (`net.adapters` and
/// `net.reachability`).
const _netView = MachineNetView(
  reported: true,
  reachability: NetReachability(
      internet: 'online',
      at: 1788480300,
      probe: 'tcp443',
      selfheal: 'watching'),
  adapters: [
    NetAdapter(
      name: 'eth0',
      up: true,
      mac: 'aa:bb:cc:dd:ee:ff',
      kind: 'physical',
      rxBytes: 91234567890,
      txBytes: 4234567890,
      addresses: [
        NetAddress(addr: '192.168.1.20', prefix: 24, family: 'inet'),
        NetAddress(
            addr: 'fe80::1c2d:3e4f:5a6b:7c8d', prefix: 64, family: 'inet6'),
      ],
    ),
    NetAdapter(
      name: 'labdesk-netbird',
      up: true,
      kind: 'overlay',
      rxBytes: 8123456,
      txBytes: 7654321,
      addresses: [NetAddress(addr: '100.64.0.3', prefix: 16, family: 'inet')],
    ),
    NetAdapter(
        name: 'wlan0', up: false, mac: '11:22:33:44:55:66', kind: 'physical'),
  ],
);

final _reachability = _netView.reachability;

/// The hot row the collector sends, per fixture machine, so the board shows
/// what a reporting fleet looks like beside one that reports nothing.
final _seenAt =
    _now.subtract(const Duration(seconds: 18)).millisecondsSinceEpoch ~/ 1000;
final _states = <String, MachineState>{
  '482910337': MachineState(
      status: 'online',
      seenAt: _seenAt,
      flushSeconds: 60,
      cpuPct: 14,
      memPct: 61,
      fsWorstPct: 49,
      uptimeS: 526440,
      loggedInUser: 'dan',
      agentVersion: '1.2.6',
      worstDisk: 'ok'),
  '118374662': MachineState(
      status: 'online',
      seenAt: _seenAt,
      flushSeconds: 60,
      cpuPct: 71,
      memPct: 44,
      fsWorstPct: 93,
      uptimeS: 7200,
      agentVersion: '1.2.6',
      worstDisk: 'warn'),
  '905513280': MachineState(
      status: 'online',
      seenAt: _seenAt,
      flushSeconds: 60,
      cpuPct: 3,
      memPct: 22,
      fsWorstPct: 61,
      uptimeS: 91000,
      agentVersion: '1.2.4',
      worstDisk: 'failing'),
  '204471839': MachineState(
      status: 'online',
      seenAt: _seenAt,
      flushSeconds: 60,
      cpuPct: 38,
      memPct: 77,
      fsWorstPct: 55,
      uptimeS: 2600000,
      agentVersion: '1.2.6',
      worstDisk: 'unreadable'),
};

MachineHealth _healthFor(String id) {
  final connected = id == '482910337';
  MachineRow? row;
  for (final m in _fixtures) {
    if (m.id == id) row = m;
  }
  final state = _states[id];
  return MachineHealth(
    machineId: id,
    connected: connected,
    state: state,
    history: state == null ? null : _history(state),
    identity: [
      Metric(
          label: 'Hostname',
          value: row?.hostname ?? '--',
          source: MetricSource.known),
      Metric(
          label: 'Platform',
          value: row?.platform ?? '--',
          source: MetricSource.known),
      Metric(
          label: 'Group',
          value: row?.group ?? 'Ungrouped',
          source: MetricSource.known),
      Metric(label: 'Machine ID', value: id, source: MetricSource.known),
    ],
    session: connected
        ? const [
            Metric(
                label: 'Round trip',
                value: '14',
                unit: 'ms',
                source: MetricSource.session),
            Metric(
                label: 'Throughput',
                value: '2.4',
                unit: 'MB/s',
                source: MetricSource.session),
            Metric(label: 'Codec', value: 'H264', source: MetricSource.session),
            Metric(label: 'Displays', value: '2', source: MetricSource.session),
          ]
        : const [
            Metric.unavailable('Round trip'),
            Metric.unavailable('Throughput'),
            Metric.unavailable('Codec'),
            Metric.unavailable('Displays'),
          ],
    remote: state?.metrics() ??
        const [
          Metric.unavailable('CPU'),
          Metric.unavailable('Memory'),
          Metric.unavailable('Disk'),
          Metric.unavailable('Uptime'),
        ],
  );
}

MetricHistory _history(MachineState state) {
  final history = MetricHistory();
  for (var i = 0; i < 48; i++) {
    history.add(MetricSample(
      at: _now.subtract(Duration(minutes: (48 - i) * 5)),
      cpu: ((state.cpuPct ?? 0) / 100 + (i % 7 - 3) * .01)
          .clamp(0, 1)
          .toDouble(),
      memory: ((state.memPct ?? 0) / 100 + (i % 5 - 2) * .005)
          .clamp(0, 1)
          .toDouble(),
      disk: (state.fsWorstPct ?? 0) / 100,
    ));
  }
  final latest = state.sampleAt(
      DateTime.fromMillisecondsSinceEpoch(_seenAt * 1000, isUtc: true));
  if (latest != null) history.add(latest);
  return history;
}

const _profiles = <ProfileRow>[
  ProfileRow(
      name: 'Workshop',
      host: 'id.workshop.example',
      hasKey: true,
      active: true),
  ProfileRow(name: 'Office', host: 'id.office.example', hasKey: true),
  ProfileRow(name: 'Public servers', host: ''),
];

final _samples = <ReachSample>[
  for (var i = 0; i < 40; i++)
    ReachSample(
      _now.subtract(Duration(seconds: (39 - i) * 30)),
      i < 8 ? 7 : (i < 14 ? 4 : (i < 22 ? 7 : (i < 30 ? 5 : 6))),
      10,
    ),
];

MachineRow _m(
  String id,
  String host,
  String platform,
  LabDeskPeerStatus status, {
  String? group,
  Duration? seenAgo,
  List<bool?> history = const [],
}) =>
    MachineRow(
      id: id,
      hostname: host,
      platform: platform,
      status: status,
      group: group,
      history: history,
      lastSeenOnline: seenAgo == null ? null : _now.subtract(seenAgo),
      lastChecked: _now.subtract(const Duration(seconds: 24)),
    );

const _up = <bool?>[
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true
];
const _down = <bool?>[
  true,
  true,
  true,
  true,
  true,
  false,
  false,
  false,
  false,
  false,
  false,
  false
];
const _flap = <bool?>[
  true,
  true,
  false,
  true,
  true,
  true,
  false,
  true,
  true,
  true,
  true,
  true
];
const _never = <bool?>[
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null
];
const _gone = <bool?>[
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  false
];

final _fixtures = <MachineRow>[
  _m('482910337', 'workshop-nas', 'linux', LabDeskPeerStatus.online,
      group: 'workshop', seenAgo: const Duration(seconds: 8), history: _up),
  _m('118374662', 'bench-01', 'windows', LabDeskPeerStatus.online,
      group: 'workshop', seenAgo: const Duration(seconds: 12), history: _up),
  _m('905513280', 'bench-02', 'windows', LabDeskPeerStatus.online,
      group: 'workshop', seenAgo: const Duration(seconds: 31), history: _flap),
  _m('771002914', 'printer-host', 'linux', LabDeskPeerStatus.offline,
      group: 'workshop', seenAgo: const Duration(hours: 6), history: _down),
  _m('330918744', 'office-desk', 'windows', LabDeskPeerStatus.online,
      group: 'office', seenAgo: const Duration(seconds: 19), history: _up),
  _m('612847100', 'office-laptop', 'macos', LabDeskPeerStatus.unknown,
      group: 'office', history: _never),
  _m('204471839', 'rack-hypervisor', 'linux', LabDeskPeerStatus.online,
      group: 'rack', seenAgo: const Duration(seconds: 5), history: _up),
  _m('558210946', 'rack-backup', 'linux', LabDeskPeerStatus.offline,
      group: 'rack', seenAgo: const Duration(days: 2), history: _gone),
  _m('887301255', 'shed-pi', 'linux', LabDeskPeerStatus.unknown,
      history: _never),
  _m('149920788', 'garage-tablet', 'android', LabDeskPeerStatus.online,
      group: 'garage', seenAgo: const Duration(minutes: 3), history: _flap),
];
