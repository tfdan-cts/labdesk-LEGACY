// Render the real NetworkScreen with pending API fixtures. No native bridge or network.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/labnet.dart';
import 'package:flutter_hbb/labdesk/screens/network_screen.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

void main() {
  for (final width in [1200.0, 390.0]) {
    testWidgets('pending membership at ${width.toInt()}px', (t) async {
      await t.runAsync(() async {
        final loader = FontLoader('Manrope');
        loader.addFont(Future.value(ByteData.sublistView(
            File('assets/fonts/Manrope-Variable.ttf').readAsBytesSync())));
        await loader.load();
      });
      await t.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final key = GlobalKey();
      await t.pumpWidget(MaterialApp(
        theme: C.theme(),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            body: NetworkScreen(
              inbox: const LabnetInbox(enrolled: true, labnets: [
                Labnet(id: 'workshop', name: 'Workshop', fullAccess: false,
                    owner: true, syncPending: true, members: [
                  LabnetMember(deviceId: 'this-machine', status: 'leaving'),
                  LabnetMember(deviceId: 'bench-02', status: 'removing'),
                ]),
              ]),
              thisMachineId: 'this-machine',
              machines: const [NetworkMachine(id: 'bench-02', name: 'Workshop bench')],
              error: 'Network removal is still pending. Retry to check progress.',
              onLeave: (_) {},
              onRemove: (_, __) {},
              onFullAccess: (_, __) {},
              onDelete: (_) {},
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Removal pending'), findsNWidgets(2));
      expect(find.text('Retry leave'), findsOneWidget);
      expect(find.text('Retry removal'), findsOneWidget);
      await t.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final picture = await boundary.toImage(pixelRatio: 1);
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        final dir = Platform.environment['MEMBERSHIP_SHOT_DIR'] ?? 'tool/shots/out';
        await Directory(dir).create(recursive: true);
        await File('$dir/membership-pending-${width.toInt()}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
    });
  }
}
