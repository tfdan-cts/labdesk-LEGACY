// Renders the surfaces WP18 changed to PNG so they can be looked at, not
// guessed at: the health board fed by the machine's own collector, the
// per-adapter network view with the reachability verdict, the self-healing
// switch on This machine, and the ready-made automation rules. Not part of the
// CI gate: it lives outside test/ and is run by hand with
// `flutter test tool/shots/wp18_test.dart`.
//
// Shots land in tool/shots/out/wp18-*.png.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/labnet.dart';
import 'package:flutter_hbb/labdesk/models/machine_metrics.dart';
import 'package:flutter_hbb/labdesk/models/machine_row.dart';
import 'package:flutter_hbb/labdesk/models/machine_state.dart';
import 'package:flutter_hbb/labdesk/models/net_view.dart';
import 'package:flutter_hbb/labdesk/screens/automation_screen.dart';
import 'package:flutter_hbb/labdesk/screens/health_board.dart';
import 'package:flutter_hbb/labdesk/screens/labnet_card.dart';
import 'package:flutter_hbb/labdesk/screens/network_screen.dart';
import 'package:flutter_hbb/labdesk/screens/selfheal_card.dart';
import 'package:flutter_hbb/labdesk/screens/this_machine_screen.dart';
import 'package:flutter_hbb/labdesk/services/overlay_enrolment.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

const _out = 'tool/shots/out';
const _size = Size(1440, 900);

final _now = DateTime(2026, 9, 5, 18, 40);

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final p in paths) {
      final bytes = File(p).readAsBytesSync();
      loader
          .addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    }
    await loader.load();
  }

  await load('Manrope', ['assets/fonts/Manrope-Variable.ttf']);
  await load('JetBrainsMono', ['assets/fonts/JetBrainsMono-Medium.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
  final icons = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
  if (icons.existsSync()) await load('MaterialIcons', [icons.path]);
}

Widget _frame(Widget child) => RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: C.theme(),
        home: Scaffold(backgroundColor: C.bg, body: child),
      ),
    );

MachineRow _m(String id, String alias, String host, String platform,
        LabDeskPeerStatus status) =>
    MachineRow(
      id: id,
      hostname: host,
      platform: platform,
      status: status,
      alias: alias,
      group: 'Workshop',
      lastSeenOnline: status == LabDeskPeerStatus.offline
          ? _now.subtract(const Duration(hours: 19))
          : _now.subtract(const Duration(seconds: 8)),
      lastChecked: _now.subtract(const Duration(seconds: 8)),
    );

final _machines = <MachineRow>[
  _m('482910337', 'Workshop NAS', 'workshop-nas', 'Linux',
      LabDeskPeerStatus.online),
  _m('118374662', 'Bench 1', 'bench-01', 'Windows', LabDeskPeerStatus.online),
  _m('905513280', 'Bench 2', 'bench-02', 'Windows', LabDeskPeerStatus.online),
  _m('204471839', 'Rack hypervisor', 'rack-hypervisor', 'Linux',
      LabDeskPeerStatus.online),
  _m('771002914', 'Printer host', 'printer-host', 'Linux',
      LabDeskPeerStatus.offline),
  _m('612847100', 'Office laptop', 'office-laptop', 'Mac OS',
      LabDeskPeerStatus.unknown),
];

/// The hot row each machine's own collector sent. The last two report nothing:
/// one is not enrolled, one has been offline since before it could.
const _states = <String, MachineState>{
  '482910337': MachineState(
      status: 'online',
      cpuPct: 14,
      memPct: 61,
      fsWorstPct: 49,
      uptimeS: 526440,
      loggedInUser: 'ops',
      agentVersion: '1.2.6',
      worstDisk: 'ok'),
  '118374662': MachineState(
      status: 'online',
      cpuPct: 71,
      memPct: 44,
      fsWorstPct: 93,
      uptimeS: 7200,
      loggedInUser: 'bench',
      agentVersion: '1.2.6',
      worstDisk: 'warn'),
  '905513280': MachineState(
      status: 'online',
      cpuPct: 3,
      memPct: 22,
      fsWorstPct: 61,
      uptimeS: 91000,
      agentVersion: '1.2.4',
      worstDisk: 'failing'),
  '204471839': MachineState(
      status: 'online',
      cpuPct: 38,
      memPct: 77,
      fsWorstPct: 55,
      uptimeS: 2600000,
      agentVersion: '1.2.6',
      worstDisk: 'unreadable'),
};

MetricHistory _history() {
  final h = MetricHistory();
  for (var i = 0; i < 40; i++) {
    h.add(MetricSample(
      at: _now.subtract(Duration(minutes: (39 - i) * 5)),
      cpu: 0.10 + (i % 7) * 0.03,
      memory: 0.55 + (i % 5) * 0.02,
      disk: 0.48 + (i % 3) * 0.01,
    ));
  }
  return h;
}

MachineHealth _healthFor(String id) {
  final state = _states[id];
  return MachineHealth(
    machineId: id,
    connected: false,
    state: state,
    remote: state?.metrics() ??
        const [
          Metric.unavailable('CPU'),
          Metric.unavailable('Memory'),
          Metric.unavailable('Disk'),
          Metric.unavailable('Uptime'),
        ],
    history: state == null ? null : _history(),
  );
}

const _netView = MachineNetView(
  reported: true,
  reachability: NetReachability(
      internet: 'online', at: 1788480300, probe: 'tcp443', selfheal: 'watching'),
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
        name: 'wlan0',
        up: false,
        mac: '11:22:33:44:55:66',
        kind: 'physical'),
  ],
);

const _offline = MachineNetView(
  reported: true,
  reachability: NetReachability(
      internet: 'offline', at: 1788480300, probe: 'tcp443', selfheal: 'cycling'),
  adapters: [
    NetAdapter(name: 'eth0', up: true, mac: 'aa:bb:cc:dd:ee:ff', kind: 'physical'),
    NetAdapter(name: 'wlan0', up: false, kind: 'physical'),
  ],
);

const _inbox = LabnetInbox(
  enrolled: true,
  overlayIp: '100.64.0.3',
  invitations: [
    LabnetInvitation(labnetId: 'L9', name: 'Rack', invitedBy: 'owner@lab-desk.net')
  ],
  labnets: [
    Labnet(id: 'L1', name: 'Workshop', fullAccess: false, owner: true, members: [
      LabnetMember(deviceId: '482910337', status: 'approved', overlayIp: '100.64.0.3'),
      LabnetMember(deviceId: '118374662', status: 'approved', overlayIp: '100.64.0.7'),
      LabnetMember(deviceId: '905513280', status: 'pending'),
    ]),
  ],
);

Widget _network(MachineNetView view) => NetworkScreen(
      inbox: _inbox,
      thisMachineId: '482910337',
      machines: [
        for (final m in _machines) NetworkMachine(id: m.id, name: m.displayName)
      ],
      fleets: const [
        NetworkFleet(id: 'F1', name: 'Workshop'),
        NetworkFleet(id: 'F2', name: 'Office'),
      ],
      mustNameFleet: true,
      netMachineId: '482910337',
      netView: view,
      onSelectNetMachine: (_) {},
      onCreate: (_, __) {},
      onRename: (_, __) {},
      onApprove: (_) {},
      onDecline: (_) {},
      onInvite: (_, __) {},
      onFullAccess: (_, __) {},
      onLeave: (_) {},
      onRemove: (_, __) {},
      onDelete: (_) {},
    );

Widget _thisMachine(bool healOn, NetReachability reach, bool waiting) =>
    ThisMachineScreen(
      machineId: '482910337',
      password: 'k7Qm2xLp',
      passwordIsTemporary: true,
      serviceRunning: true,
      displayName: 'Workshop NAS',
      onEditDisplayName: () {},
      onRefreshPassword: () {},
      onEditPassword: () {},
      labnet: LabnetCard(
          state: const LabnetCardState(LabnetPhase.on, ip: '100.64.0.3'),
          onDisable: () {}),
      selfHeal: SelfHealCard(
          on: healOn, reachability: reach, waiting: waiting, onChanged: (_) {}),
    );

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('shot')));
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(_out).createSync(recursive: true);
    File('$_out/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void main() {
  testWidgets('WP18 shots', (tester) async {
    await tester.runAsync(_loadFonts);
    await tester.binding.setSurfaceSize(_size);

    await tester.pumpWidget(_frame(
        HealthBoard(machines: _machines, healthFor: _healthFor, now: _now)));
    await tester.pumpAndSettle();
    await _capture(tester, 'wp18-health-board');

    await tester.pumpWidget(_frame(_network(_netView)));
    await tester.pumpAndSettle();
    await _capture(tester, 'wp18-network-adapters');

    await tester.pumpWidget(_frame(_network(_offline)));
    await tester.pumpAndSettle();
    await _capture(tester, 'wp18-network-offline');

    await tester.pumpWidget(_frame(_network(MachineNetView.empty)));
    await tester.pumpAndSettle();
    await _capture(tester, 'wp18-network-unreported');

    await tester.pumpWidget(_frame(
        _thisMachine(true, _netView.reachability, false)));
    await tester.pumpAndSettle();
    await _capture(tester, 'wp18-this-machine-selfheal-on');

    await tester.pumpWidget(_frame(_thisMachine(
        false, const NetReachability(internet: 'offline'), false)));
    await tester.pumpAndSettle();
    await _capture(tester, 'wp18-this-machine-selfheal-off');

    await tester.pumpWidget(
        _frame(_thisMachine(true, const NetReachability(), true)));
    await tester.pumpAndSettle();
    await _capture(tester, 'wp18-this-machine-selfheal-waiting');

    await tester.pumpWidget(_frame(AutomationScreen(
      rules: const [],
      machines: _machines,
      now: _now,
      onSave: (_) {},
      onApplyPreset: (_) {},
    )));
    await tester.pumpAndSettle();
    await _capture(tester, 'wp18-automation-presets');
  });
}
