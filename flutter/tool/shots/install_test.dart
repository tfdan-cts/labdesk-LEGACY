// Renders the Windows install screen to PNG so it can be looked at, not
// guessed at. Run: flutter test tool/shots/install_test.dart
//
// The screen's presentation is InstallView, which takes plain values, so the
// shot needs no FFI: only the translator is stubbed.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/labdesk/screens/install_screen.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

const _out = 'tool/shots/out';

// The handful of keys English actually rewrites; everything else falls through
// to the key, exactly as the running product does.
const _en = <String, String>{
  'agreement_tip':
      'By starting the installation, you accept the license agreement.',
  'Accept and Install': 'Accept and install',
  'Change Path': 'Change path',
};

String _t(String key) => _en[key] ?? key;

Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final loader = FontLoader(family);
    final bytes = File(path).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    await loader.load();
  }

  await load('Manrope', 'assets/fonts/Manrope-Variable.ttf');
  await load('JetBrainsMono', 'assets/fonts/JetBrainsMono-Medium.ttf');
  // Material's icon font ships with the SDK, not the app; without it any
  // remaining Material glyph renders as an empty box.
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
  final icons = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
  if (icons.existsSync()) await load('MaterialIcons', icons.path);
}

void main() {
  setUpAll(_loadFonts);

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    bool busy = false,
  }) async {
    await tester.binding.setSurfaceSize(size);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: C.theme(),
        home: Scaffold(
          backgroundColor: C.bg,
          body: InstallView(
            appName: 'LabDesk',
            t: _t,
            installPath: r'C:\Program Files\LabDesk',
            onChangePath: () {},
            startMenu: true,
            onStartMenu: (_) {},
            desktopIcon: true,
            onDesktopIcon: (_) {},
            printer: false,
            onPrinter: (_) {},
            // Everything locks together the moment the install starts.
            enabled: !busy,
            busy: busy,
            hideRunWithoutInstall: false,
            onInstall: () {},
            onCancel: () {},
            onRunWithoutInstall: () {},
            agreementUrl: 'https://lab-desk.net/privacy',
            onOpenAgreement: () {},
          ),
        ),
      ),
    ));

    await tester.pump(const Duration(milliseconds: 300));
    final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('shot')),
    );
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(_out).createSync(recursive: true);
      File('$_out/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  testWidgets('install screen', (tester) async {
    await shoot(tester, 'install', size: const Size(1000, 760));
  });

  // The size the installer window actually opens at, less the tab strip: the
  // layout has to hold there, not only in the roomy shot.
  testWidgets('install screen, installing', (tester) async {
    await shoot(tester, 'install-installing',
        size: const Size(800, 565), busy: true);
  });
}
