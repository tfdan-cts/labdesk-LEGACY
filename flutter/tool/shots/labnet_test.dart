// Renders the two labnet surfaces to PNG so they can be looked at, not guessed
// at: the card on This machine in each of its states, and the Network section
// with invitations and labnets. Not part of the CI gate: it lives outside
// test/ and is run by hand with `flutter test tool/shots/labnet_test.dart`.
//
// Shots land in tool/shots/out/labnet-*.png.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/labnet.dart';
import 'package:flutter_hbb/labdesk/models/machine_row.dart';
import 'package:flutter_hbb/labdesk/screens/console_shell.dart';
import 'package:flutter_hbb/labdesk/screens/labnet_card.dart';
import 'package:flutter_hbb/labdesk/screens/network_screen.dart';
import 'package:flutter_hbb/labdesk/screens/this_machine_screen.dart';
import 'package:flutter_hbb/labdesk/services/overlay_enrolment.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

const _out = 'tool/shots/out';
const _size = Size(1440, 900);

final _now = DateTime(2026, 9, 3, 18, 40);

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final p in paths) {
      final bytes = File(p).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    }
    await loader.load();
  }

  await load('Manrope', ['assets/fonts/Manrope-Variable.ttf']);
  await load('JetBrainsMono', ['assets/fonts/JetBrainsMono-Medium.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
  final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
  if (icons.existsSync()) await load('MaterialIcons', [icons.path]);
}

MachineRow _m(String id, String alias, String host, String platform, LabDeskPeerStatus status, {String? group}) =>
    MachineRow(id: id, hostname: host, platform: platform, status: status, alias: alias, group: group, lastSeenOnline: _now);

final _machines = <MachineRow>[
  _m('482910337', 'Workshop NAS', 'workshop-nas', 'Linux', LabDeskPeerStatus.online, group: 'Workshop'),
  _m('118374662', 'Bench 1', 'bench-01', 'Windows', LabDeskPeerStatus.online, group: 'Workshop'),
  _m('905513280', 'Bench 2', 'bench-02', 'Windows', LabDeskPeerStatus.online, group: 'Workshop'),
  _m('330918744', 'Office desk', 'office-desk', 'Windows', LabDeskPeerStatus.online, group: 'Office'),
  _m('612847100', 'Office laptop', 'office-laptop', 'Mac OS', LabDeskPeerStatus.unknown, group: 'Office'),
  _m('204471839', 'Rack hypervisor', 'rack-hypervisor', 'Linux', LabDeskPeerStatus.online, group: 'Rack'),
];

const _inbox = LabnetInbox(
  enrolled: true,
  overlayIp: '100.64.0.3',
  invitations: [LabnetInvitation(labnetId: 'L9', name: 'Rack', invitedBy: 'owner@lab-desk.net')],
  labnets: [
    Labnet(id: 'L1', name: 'Workshop', fullAccess: false, owner: true, members: [
      LabnetMember(deviceId: '482910337', status: 'approved', overlayIp: '100.64.0.3'),
      LabnetMember(deviceId: '118374662', status: 'approved', overlayIp: '100.64.0.7'),
      LabnetMember(deviceId: '905513280', status: 'pending'),
    ]),
    Labnet(id: 'L2', name: 'Office', fullAccess: true, owner: false, members: [
      LabnetMember(deviceId: '482910337', status: 'approved', overlayIp: '100.64.0.3'),
      LabnetMember(deviceId: '330918744', status: 'approved', overlayIp: '100.64.0.12'),
      LabnetMember(deviceId: '612847100', status: 'approved'),
    ]),
  ],
);

Widget _frame(ConsoleSection section, WidgetBuilder body) => RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: C.theme(),
        home: Scaffold(
          backgroundColor: C.bg,
          body: ConsoleShell(
            // A new shell per section: initialSection is read once, in initState.
            key: ValueKey(section),
            machines: _machines,
            profileName: 'Lab network',
            lastRefreshed: _now.subtract(const Duration(seconds: 8)),
            onRefresh: () {},
            now: _now,
            initialSection: section,
            hosted: {section: body},
          ),
        ),
      ),
    );

Widget _thisMachine(LabnetCardState state) => ThisMachineScreen(
      machineId: '482910337',
      password: 'k7Qm2xLp',
      passwordIsTemporary: true,
      serviceRunning: true,
      displayName: 'Workshop NAS',
      onEditDisplayName: () {},
      onRefreshPassword: () {},
      onEditPassword: () {},
      labnet: LabnetCard(state: state, onEnable: () {}, onDisable: () {}),
    );

Widget _network(LabnetInbox inbox) => NetworkScreen(
      inbox: inbox,
      thisMachineId: '482910337',
      machines: [for (final m in _machines) NetworkMachine(id: m.id, name: m.displayName)],
      onCreate: (_, __) {},
      onApprove: (_) {},
      onDecline: (_) {},
      onInvite: (_, __) {},
      onFullAccess: (_, __) {},
      onLeave: (_) {},
      onRemove: (_, __) {},
      onDelete: (_) {},
    );

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.firstRenderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(_out).createSync(recursive: true);
    File('$_out/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void main() {
  testWidgets('labnet shots', (tester) async {
    await tester.runAsync(_loadFonts);
    await tester.binding.setSurfaceSize(_size);
    final states = {
      'off': LabnetCardState.off,
      'working': const LabnetCardState(LabnetPhase.working, detail: 'Connecting'),
      'on': const LabnetCardState(LabnetPhase.on, ip: '100.64.0.3'),
      'error': const LabnetCardState(LabnetPhase.error, detail: 'setup key expired'),
    };
    for (final e in states.entries) {
      await tester.pumpWidget(_frame(ConsoleSection.thisMachine, (_) => _thisMachine(e.value)));
      await tester.pumpAndSettle();
      await _capture(tester, 'labnet-this-machine-${e.key}');
    }
    await tester.pumpWidget(_frame(ConsoleSection.network, (_) => _network(_inbox)));
    await tester.pumpAndSettle();
    await _capture(tester, 'labnet-network');
    await tester.pumpWidget(_frame(ConsoleSection.network, (_) => _network(LabnetInbox.empty)));
    await tester.pumpAndSettle();
    await _capture(tester, 'labnet-network-not-enrolled');
    await tester.pumpWidget(_frame(ConsoleSection.network, (_) => _network(const LabnetInbox(enrolled: true, overlayIp: '100.64.0.3'))));
    await tester.pumpAndSettle();
    await _capture(tester, 'labnet-network-empty');
  });
}
