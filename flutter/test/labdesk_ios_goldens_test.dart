import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/machine_row.dart';
import 'package:flutter_hbb/mobile/widgets/first_run.dart';
import 'package:flutter_hbb/mobile/widgets/machine_list.dart';

/// Rendered images of the phone's own screens.
///
/// These are not iOS. Flutter's engine draws them in the test harness, so the
/// text metrics, the fonts and the platform behaviours are the harness's and
/// not a phone's. What they do settle is everything the layout decides:
/// hierarchy, spacing, whether the three reachability states are
/// distinguishable at a glance, whether both appearances are readable, and
/// whether anything overflows at a phone's size.
///
/// They exist because the simulator job cannot build the Rust core for either
/// iOS simulator target yet, and a screen nobody has looked at is a screen
/// nobody can judge. When the simulator job goes green these stay: they are
/// cheap, they run on any runner, and they fail on a visual change rather than
/// waiting for somebody to notice one.
const _phone = Size(390, 844);

/// Real text, not Ahem blocks.
///
/// The test harness draws every glyph as a filled rectangle unless a font is
/// loaded, which is fine for checking layout and useless for reading the copy.
/// Roboto ships inside the Flutter SDK, so it is available wherever these tests
/// run and the images stay reproducible. If the SDK cannot be located the
/// images still render, just in blocks, so this never fails a run on its own.
Future<void> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  // MaterialIcons matters as much as the text face: without it every icon
  // draws as a missing-glyph box, and a reviewer cannot tell that from a real
  // rendering bug.
  const faces = {
    'Roboto': [
      'roboto-regular.ttf',
      'roboto-medium.ttf',
      'roboto-bold.ttf',
    ],
    'MaterialIcons': ['materialicons-regular.otf'],
  };
  for (final family in faces.entries) {
    for (final name in family.value) {
      final file = File('$root/bin/cache/artifacts/material_fonts/$name');
      if (!file.existsSync()) continue;
      final loader = FontLoader(family.key)
        ..addFont(Future.value(file.readAsBytesSync().buffer.asByteData()));
      await loader.load();
    }
  }
}

/// The machine list never appears on its own: the phone's home page wraps it in
/// an app bar and a tab bar. Rendering it bare produced critiques about a
/// missing title and a row under the notch, which are the harness's fault and
/// not the screen's. The frame is included so what is judged is what an
/// operator sees.
Widget _inHomePage(Widget child) => Scaffold(
      appBar: AppBar(title: const Text('LabDesk'), centerTitle: true),
      body: child,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: 1,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.connected_tv), label: 'Connection'),
          BottomNavigationBarItem(
              icon: Icon(Icons.devices_other), label: 'Machines'),
          BottomNavigationBarItem(
              icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );

Widget _frame(Widget child, {required Brightness brightness}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: brightness,
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF8B7DF7),
        fontFamily: 'Roboto',
      ),
      home: Scaffold(body: child),
    );

MachineRow _row(
  String id, {
  String hostname = '',
  LabDeskPeerStatus status = LabDeskPeerStatus.unknown,
  DateTime? lastSeenOnline,
  DateTime? lastChecked,
}) =>
    MachineRow(
      id: id,
      hostname: hostname,
      platform: 'Windows',
      status: status,
      lastSeenOnline: lastSeenOnline,
      lastChecked: lastChecked,
    );

/// Off unless asked for.
///
/// Golden images are bytes, and the bytes differ between platforms: these are
/// rendered on Windows and the repository's Dart tests run on ubuntu, so a
/// comparison across the two fails on font rasterisation rather than on
/// anything anyone changed. Leaving them in the shared gate would hand every
/// other lane a flake they did not cause.
///
/// Their job is to be looked at, and that does not need a gate. To regenerate
/// and inspect:
///
///   LABDESK_GOLDENS=1 flutter test --update-goldens test/labdesk_ios_goldens_test.dart
final _enabled = Platform.environment['LABDESK_GOLDENS'] == '1';

void main() {
  setUpAll(_loadRoboto);

  final now = DateTime(2026, 9, 5, 12, 0);

  final machines = [
    _row('1180573903',
        hostname: 'workshop-pc',
        status: LabDeskPeerStatus.online,
        lastSeenOnline: now,
        lastChecked: now),
    _row('486201933',
        hostname: 'front-desk',
        status: LabDeskPeerStatus.offline,
        lastSeenOnline: now.subtract(const Duration(hours: 3)),
        lastChecked: now),
    _row('820104412', hostname: 'lab-bench-2'),
    _row('55512340',
        hostname: 'reception-kiosk-by-the-front-window',
        status: LabDeskPeerStatus.offline,
        lastSeenOnline: now.subtract(const Duration(days: 2)),
        lastChecked: now),
  ];

  Future<void> shoot(
    WidgetTester tester,
    Widget child,
    String name, {
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = _phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_frame(child, brightness: brightness));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  testWidgets('machine list, light', (tester) async {
    await shoot(
      tester,
      _inHomePage(MachineListView(
        machines: machines,
        onConnect: (_) {},
        savedPasswords: const {'1180573903', '486201933'},
        checking: const {'820104412'},
        now: now,
      )),
      'machine-list-light',
    );
  }, skip: !_enabled);

  testWidgets('machine list, dark', (tester) async {
    await shoot(
      tester,
      _inHomePage(MachineListView(
        machines: machines,
        onConnect: (_) {},
        savedPasswords: const {'1180573903', '486201933'},
        checking: const {'820104412'},
        now: now,
      )),
      'machine-list-dark',
      brightness: Brightness.dark,
    );
  }, skip: !_enabled);

  testWidgets('machine list with nothing in it', (tester) async {
    await shoot(
      tester,
      _inHomePage(MachineListView(
        machines: const [],
        onConnect: (_) {},
        onConnectToFirstMachine: () {},
        now: now,
      )),
      'machine-list-empty',
    );
  }, skip: !_enabled);

  testWidgets('first run, light', (tester) async {
    await shoot(
      tester,
      FirstRunView(
        configuredServer: '',
        onSignIn: () {},
        onAddProfile: () {},
        onSkip: () {},
      ),
      'first-run-light',
    );
  }, skip: !_enabled);

  testWidgets('first run, dark', (tester) async {
    await shoot(
      tester,
      FirstRunView(
        configuredServer: '',
        onSignIn: () {},
        onAddProfile: () {},
        onSkip: () {},
      ),
      'first-run-dark',
      brightness: Brightness.dark,
    );
  }, skip: !_enabled);
}
