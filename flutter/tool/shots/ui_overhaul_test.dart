// Shipping Flutter widgets with labeled fixture data, never a live machine.
// Run: flutter test tool/shots/ui_overhaul_test.dart
// PNGs: tool/shots/out/ui-*.png (logical pixels, real bundled fonts).
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/machine_metrics.dart';
import 'package:flutter_hbb/labdesk/models/machine_row.dart';
import 'package:flutter_hbb/labdesk/models/machine_state.dart';
import 'package:flutter_hbb/labdesk/models/net_view.dart';
import 'package:flutter_hbb/labdesk/models/organization_context.dart';
import 'package:flutter_hbb/labdesk/screens/adapters_card.dart';
import 'package:flutter_hbb/labdesk/screens/console_shell.dart';
import 'package:flutter_hbb/labdesk/screens/home_dashboard.dart';
import 'package:flutter_hbb/labdesk/screens/terms_dialog.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

final _now = DateTime.utc(2026, 9, 6, 15, 30);
final _seenAt =
    _now.subtract(const Duration(seconds: 18)).millisecondsSinceEpoch ~/ 1000;
const _desktop = Size(1440, 1000);
const _narrow = Size(800, 600);

final _machines = <MachineRow>[
  for (final row in [
    (
      '482910337',
      'Workshop NAS',
      'workshop-nas',
      'Linux',
      LabDeskPeerStatus.online
    ),
    (
      '118374662',
      'Build workstation',
      'build-01',
      'Windows',
      LabDeskPeerStatus.online
    ),
    (
      '905513280',
      'Render station',
      'render-02',
      'Windows',
      LabDeskPeerStatus.online
    ),
    (
      '204471839',
      'Rack hypervisor',
      'rack-hypervisor',
      'Linux',
      LabDeskPeerStatus.online
    ),
    (
      '771002914',
      'Printer host',
      'printer-host',
      'Linux',
      LabDeskPeerStatus.offline
    ),
    (
      '612847100',
      'Office laptop',
      'office-laptop',
      'Mac OS',
      LabDeskPeerStatus.unknown
    ),
  ])
    MachineRow(
        id: row.$1,
        alias: row.$2,
        hostname: row.$3,
        platform: row.$4,
        status: row.$5,
        group: 'Sample machines',
        lastChecked: _now.subtract(const Duration(seconds: 18)),
        lastSeenOnline: row.$5 == LabDeskPeerStatus.unknown
            ? null
            : _now.subtract(row.$5 == LabDeskPeerStatus.offline
                ? const Duration(hours: 19)
                : const Duration(seconds: 18))),
];

final _states = <String, MachineState>{
  '482910337': MachineState(
      status: 'online',
      seenAt: _seenAt,
      flushSeconds: 60,
      cpuPct: 14,
      memPct: 61,
      fsWorstPct: 49,
      uptimeS: 526440,
      loggedInUser: 'ops',
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
      loggedInUser: 'builder',
      agentVersion: '1.2.6',
      worstDisk: 'warn'),
  '905513280': MachineState(
      status: 'online',
      seenAt: _seenAt,
      flushSeconds: 60,
      cpuPct: 34,
      memPct: 94,
      fsWorstPct: 61,
      uptimeS: 91000,
      loggedInUser: 'render',
      agentVersion: '1.2.6',
      worstDisk: 'failing'),
  '204471839': MachineState(
      status: 'online',
      seenAt: _seenAt,
      flushSeconds: 60,
      cpuPct: 38,
      memPct: 77,
      fsWorstPct: 55,
      uptimeS: 2600000,
      loggedInUser: 'ops',
      agentVersion: '1.2.6',
      worstDisk: 'unreadable'),
  '771002914': MachineState(
      status: 'offline',
      seenAt: _seenAt - 19 * 3600,
      flushSeconds: 60,
      agentVersion: '1.2.6'),
  '612847100': const MachineState(status: 'unknown'),
};

MachineHealth _health(String id) {
  final state = _states[id]!;
  final history = MetricHistory();
  if (state.statusAt(_now) == 'online') {
    for (var i = 0; i < 48; i++) {
      history.add(MetricSample(
        at: _now.subtract(Duration(minutes: (48 - i) * 5)),
        cpu: (state.cpuPct! / 100 + math.sin(i * .42) * .09)
            .clamp(0, 1)
            .toDouble(),
        memory: (state.memPct! / 100 + math.sin(i * .16) * .035)
            .clamp(0, 1)
            .toDouble(),
        disk:
            (state.fsWorstPct! / 100 - (48 - i) * .0002).clamp(0, 1).toDouble(),
      ));
    }
    history.add(state.sampleAt(
        DateTime.fromMillisecondsSinceEpoch(_seenAt * 1000, isUtc: true))!);
  }
  return MachineHealth(
      machineId: id,
      connected: false,
      state: state,
      remote: state.metrics(),
      history: history);
}

final _network = MachineNetView(
    reported: true,
    reachability: NetReachability(
        internet: 'online', at: _seenAt, probe: 'tcp443', selfheal: 'watching'),
    adapters: const [
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
          ]),
      NetAdapter(
          name: 'labdesk-netbird',
          up: true,
          kind: 'overlay',
          rxBytes: 8123456,
          txBytes: 7654321,
          addresses: [
            NetAddress(addr: '100.64.0.3', prefix: 16, family: 'inet')
          ]),
      NetAdapter(
          name: 'wlan0', up: false, mac: '11:22:33:44:55:66', kind: 'physical'),
    ]);

Future<void> _fonts() async {
  for (final entry in {
    'Manrope': 'assets/fonts/Manrope-Variable.ttf',
    'JetBrainsMono': 'assets/fonts/JetBrainsMono-Medium.ttf',
    'MaterialIcons':
        '${Platform.environment['FLUTTER_ROOT'] ?? 'C:/sdk/flutter-3.24.5'}/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
  }.entries) {
    final loader = FontLoader(entry.key);
    loader.addFont(Future.value(
        ByteData.sublistView(File(entry.value).readAsBytesSync())));
    await loader.load();
  }
}

Widget _frame(String name, Brightness brightness,
    {ConsoleSection section = ConsoleSection.home}) {
  var selectedId = _machines.first.id;
  return RepaintBoundary(
      key: const ValueKey('ui-shot'),
      child: MaterialApp(
        key: ValueKey(name),
        debugShowCheckedModeBanner: false,
        theme: C.theme(brightness: brightness),
        home: Scaffold(
            body: Builder(
                builder: (context) => ConsoleShell(
                      machines: _machines,
                      healthMachines: _machines,
                      healthFor: _health,
                      now: _now,
                      lastRefreshed: _now.subtract(const Duration(seconds: 8)),
                      initialSection: section,
                      dashboardContextKey: 'fixture-account/sample-org',
                      organizations: const [
                        OrganizationSummary(
                            id: 'sample-org',
                            name: 'Workshop · Sample',
                            role: 'owner')
                      ],
                      activeOrganizationId: 'sample-org',
                      onOrganizationSelected: (_) {},
                      accountName: 'Preview account',
                      accountDescription: 'Fixture data · no live machines',
                      onAccountPressed: () {},
                      onTermsPressed: () => showLabDeskTerms(context),
                      onRefresh: () {},
                      onSaveDashboard: (_) async {},
                      fleets: const [
                        DashboardFleet(id: 'fleet-workshop', name: 'Workshop'),
                        DashboardFleet(
                            id: 'fleet-infrastructure', name: 'Infrastructure')
                      ],
                      machineFleetIds: {
                        for (final m in _machines)
                          m.id: {
                            m.id == '482910337' || m.id == '204471839'
                                ? 'fleet-infrastructure'
                                : 'fleet-workshop'
                          },
                      },
                      onMachineSelected: (id) => selectedId = id,
                      hosted: {
                        ConsoleSection.diagnostics: (_) =>
                            SingleChildScrollView(
                                padding: const EdgeInsets.all(24),
                                child: AdaptersCard(
                                    view: _network,
                                    machineName: _machines
                                        .firstWhere((m) => m.id == selectedId)
                                        .displayName))
                      },
                    ))),
      ));
}

Future<void> _capture(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull, reason: name);
  final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('ui-shot')));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('tool/shots/out').createSync(recursive: true);
    File('tool/shots/out/$name.png')
        .writeAsBytesSync(png!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _mount(WidgetTester tester, String name, Brightness brightness,
    {ConsoleSection section = ConsoleSection.home,
    Size size = _desktop}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(_frame(name, brightness, section: section));
  await tester.pumpAndSettle();
  // This manually invoked widget test lives outside the CI test/ directory.
  // ignore: invalid_use_of_visible_for_testing_member
  await tester.runAsync(vg.waitForPendingDecodes);
  await tester.pumpAndSettle();
}

Future<void> _captureLastMachine(WidgetTester tester, String name) async {
  final body = find.byKey(const ValueKey('report-body-daily-machines'));
  final scroll = tester.widget<SingleChildScrollView>(body);
  await tester.drag(body, const Offset(0, -220));
  await tester.pumpAndSettle();
  final lastMachine =
      find.descendant(of: body, matching: find.text('Office laptop'));
  expect(tester.getRect(body).contains(tester.getRect(lastMachine).topLeft),
      isTrue);
  expect(tester.getRect(body).contains(tester.getRect(lastMachine).bottomRight),
      isTrue);
  await _capture(tester, name);
  scroll.controller!.jumpTo(0);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('UI overhaul shipping widget screenshots', (tester) async {
    await tester.runAsync(_fonts);
    addTearDown(tester.view.reset);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    expect(_states.values.where((s) => s.statusAt(_now) == 'online'),
        hasLength(4));
    expect(_states.values.where((s) => s.statusAt(_now) == 'offline'),
        hasLength(1));
    expect(_states.values.where((s) => s.statusAt(_now) == 'unknown'),
        hasLength(1));
    for (final brightness in [Brightness.dark, Brightness.light]) {
      final name = 'ui-home-${brightness.name}';
      await _mount(tester, name, brightness);
      await _capture(tester, name);
      if (brightness == Brightness.dark) {
        await _captureLastMachine(tester, 'ui-home-dark-scrolled');
      }
      await tester.tap(find.byKey(const ValueKey('customize-dashboard')));
      await tester.pumpAndSettle();
      final cpu = find.byKey(const ValueKey('settings-daily-cpu'));
      await tester.ensureVisible(cpu);
      await tester.tap(cpu);
      await tester.pumpAndSettle();
      await _capture(tester, 'ui-edit-cpu-${brightness.name}');
    }
    await _mount(tester, 'ui-home-narrow', Brightness.dark, size: _narrow);
    await _capture(tester, 'ui-home-narrow');
    await _captureLastMachine(tester, 'ui-home-narrow-scrolled');
    await _mount(tester, 'ui-fleet-health', Brightness.dark,
        section: ConsoleSection.fleet);
    await tester.tap(find.widgetWithText(Tab, 'Health'));
    await tester.pumpAndSettle();
    await _capture(tester, 'ui-fleet-health');
    await _mount(tester, 'ui-machine-network', Brightness.light,
        section: ConsoleSection.fleet);
    await tester.tap(find.text('Workshop NAS'));
    await tester.pumpAndSettle();
    final network = find.widgetWithText(TextButton, 'Network');
    await tester.ensureVisible(network);
    await tester.tap(network);
    await tester.pumpAndSettle();
    await _capture(tester, 'ui-machine-network');
    await tester.tap(find.byTooltip('Help for this page'));
    await tester.pumpAndSettle();
    await _capture(tester, 'ui-help');
  });
}
