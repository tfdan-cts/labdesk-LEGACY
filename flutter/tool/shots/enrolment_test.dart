// Actual Flutter rendering of the machine enrollment flow. Run with the
// pinned SDK: flutter test --no-pub tool/shots/enrolment_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/screens/enrol_card.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

void main() {
  setUpAll(() async {
    for (final pair in [
      ['Manrope', 'assets/fonts/Manrope-Variable.ttf'],
      ['JetBrainsMono', 'assets/fonts/JetBrainsMono-Medium.ttf'],
    ]) {
      final loader = FontLoader(pair[0]);
      loader.addFont(
          Future.value(ByteData.sublistView(File(pair[1]).readAsBytesSync())));
      await loader.load();
    }
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root != null) {
      final loader = FontLoader('MaterialIcons');
      loader.addFont(Future.value(ByteData.sublistView(File(
              '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf')
          .readAsBytesSync())));
      await loader.load();
    }
  });

  for (final width in [600.0, 360.0]) {
    for (final state in [
      'new-fleet',
      'fleet-picker',
      'signed-out',
      'service-missing'
    ]) {
      testWidgets('enrolment $state at $width', (t) async {
        await t.binding.setSurfaceSize(Size(width, 620));
        t.view.physicalSize = Size(width, 620);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final broker = OverlayBroker(
          baseUrl: 'https://lab-desk.net',
          token: () => 'fixture',
          http: (method, url, headers, body) async => (
            200,
            jsonEncode(
              url.path == '/console/org'
                  ? {'role': 'owner'}
                  : {
                      'fleets': state == 'fleet-picker'
                          ? [
                              {'id': 'home', 'name': 'Home lab'}
                            ]
                          : []
                    },
            )
          ),
        );
        await t.pumpWidget(RepaintBoundary(
          key: const Key('enrolment-shot'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: C.theme(),
            home: Scaffold(
              backgroundColor: C.bg,
              body: SingleChildScrollView(
                  child: Padding(
                padding: const EdgeInsets.all(16),
                child: MachineEnrolCard(
                  broker: broker,
                  signedIn: state != 'signed-out',
                  signIn: () async => true,
                  checkService: () async {
                    throw StateError(
                        'The LabDesk service could not be reached. Install or repair it, then retry.');
                  },
                  repairService: () {},
                  enrol: (_) async => '{"machineId":"fixture"}',
                ),
              )),
            ),
          ),
        ));
        await t.pumpAndSettle();
        if (state == 'new-fleet' || state == 'service-missing') {
          await t.enterText(
              find.byKey(const Key('enrol-fleet-name')), 'Home lab');
          await t.pumpAndSettle();
        }
        if (state == 'service-missing') {
          await t.tap(find.text('Create fleet and add this machine'));
          await t.pumpAndSettle();
        }
        expect(t.takeException(), isNull,
            reason: 'no layout overflow at $width');
        final boundary = t.firstRenderObject<RenderRepaintBoundary>(
            find.byKey(const Key('enrolment-shot')));
        await t.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file =
              File('tool/shots/out/enrolment-$state-${width.toInt()}.png');
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
      });
    }
  }
}
