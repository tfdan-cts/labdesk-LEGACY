import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/pages/file_manager_page.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';
import 'package:flutter_hbb/labdesk/theme/file_manager_skin.dart';
import 'package:flutter_hbb/labdesk/theme/ld_icons.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

class TransferBoundary extends Fake implements LabDeskImpl {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString().split('"')[1];
    switch (name) {
      case 'translate':
        return invocation.namedArguments[#name];
      case 'getDoubleClickTime':
        return 500;
      case 'isDisableAb':
      case 'isDisableAccount':
      case 'isDisableGroupPanel':
        return false;
      case 'mainGetLocalOption':
      case 'getLocalFlutterOption':
      case 'mainGetPeerOptionSync':
      case 'mainGetOptionSync':
        return '';
      default:
        throw StateError('Unexpected native call: $name');
    }
  }
}

// Only the session models used by the actual listing. Constructing global FFI
// would also start unrelated server/account pollers.
class TransferFfi extends Fake implements FFI {
  @override
  final sessionId = const Uuid().v4obj();
  @override
  late final FfiModel ffiModel = FfiModel(WeakReference(this));
  @override
  late final FileModel fileModel = FileModel(WeakReference(this));
}

Future<void> fonts() async {
  for (final pair in [
    ('Manrope', 'Manrope-Variable.ttf'),
    ('JetBrainsMono', 'JetBrainsMono-Medium.ttf')
  ]) {
    final loader = FontLoader(pair.$1);
    loader.addFont(Future.value(ByteData.sublistView(
        File('assets/fonts/${pair.$2}').readAsBytesSync())));
    await loader.load();
  }
}

void main() {
  setUpAll(fonts);
  for (final width in [1500.0, 1000.0]) {
    testWidgets(
        'actual transfer panes show live names, selection and search at $width',
        (tester) async {
      platformFFI.ffiBind = TransferBoundary();
      final ffi = TransferFfi();
      ffi.ffiModel.pi.platform = 'Windows';
      final local = ffi.fileModel.localController;
      final remote = ffi.fileModel.remoteController;
      for (final controller in [local, remote]) {
        controller.options.value.isWindows = true;
        controller.homePath = r'C:\Users\Operator';
        controller.directory.value = FileDirectory()
          ..path = r'C:\Users\Operator\Documents'
          ..entries = [
            Entry()
              ..name = 'reports'
              ..entryType = 0
              ..modifiedTime = 1788823200,
            Entry()
              ..name = 'deployment-notes.txt'
              ..size = 3840
              ..modifiedTime = 1788823200,
            Entry()
              ..name = 'machine-inventory.csv'
              ..size = 16984
              ..modifiedTime = 1788823200,
            Entry()
              ..name = 'connection-diagnostics.zip'
              ..size = 1024820
              ..modifiedTime = 1788823200,
          ];
      }
      final focus = MouseFocusScope.none.obs;
      tester.view.physicalSize = Size(width, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(Size(width, 760));
      await tester.pumpWidget(RepaintBoundary(
          key: const ValueKey('transfer-shot'),
          child: MaterialApp(
            theme: C.theme(),
            debugShowCheckedModeBanner: false,
            home: Scaffold(
                backgroundColor: C.bg,
                body: Row(children: [
                  Expanded(flex: 3, child: FileManagerView(local, ffi, focus)),
                  Expanded(flex: 3, child: FileManagerView(remote, ffi, focus)),
                  const Expanded(
                      flex: 2,
                      child: FmPane(rail: true, children: [
                        FmPaneHeader(title: 'Transfers'),
                        Expanded(
                            child: FmEmpty(
                                glyph: LdIcons.fileTransfer,
                                line: 'No transfers',
                                hint: 'Select files, then Send or Receive.')),
                      ])),
                ])),
          )));
      await tester.pumpAndSettle();
      expect(find.text(Platform.localHostname.trim()), findsOneWidget);
      expect(find.text('Remote Computer'), findsOneWidget);
      ffi.ffiModel.pi.hostname = 'Foundry';
      // Simulate the notification emitted after a native peer-info event.
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      ffi.ffiModel.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Foundry'), findsOneWidget);
      expect(find.text('Remote Computer'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('deployment-notes.txt').first);
      await tester.pumpAndSettle();
      expect(local.selectedItems.items.single.name, 'deployment-notes.txt');
      if (width == 1000) {
        final date = local.directory.value.entries.first.lastModified().toString().split(' ').first;
        expect(find.text(date), findsNWidgets(8));
      }
      final send = tester.widget<FmSendButton>(find.byType(FmSendButton).first);
      expect(send.onPressed, isNotNull);
      if (const bool.fromEnvironment('GUI_SHOTS')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('transfer-shot')));
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final out =
              File('tool/shots/out/transfer-actual-${width.toInt()}.png');
          await out.parent.create(recursive: true);
          await out.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byTooltip('Search').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'inventory');
      await tester.pumpAndSettle();
      expect(find.text('deployment-notes.txt'), findsOneWidget,
          reason: 'Search filters only the local pane');
      expect(find.text('machine-inventory.csv'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      ffi.ffiModel.pi.hostname =
          'Foundry-with-a-long-hostname-that-must-stay-inside-its-pane';
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      ffi.ffiModel.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byTooltip(ffi.ffiModel.pi.hostname), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('machine-inventory.csv').first);
      await tester.pumpAndSettle();
      expect(local.selectedItems.items.single.name, 'machine-inventory.csv');
      tester.view.physicalSize = Size(width - 100, 700);
      await tester.binding.setSurfaceSize(Size(width - 100, 700));
      await tester.pumpAndSettle();
      expect(local.selectedItems.items.single.name, 'machine-inventory.csv');
      expect(find.byTooltip(ffi.ffiModel.pi.hostname), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Reach More by keyboard, without a prior pointer position.
      FmToolButton? focusedTool;
      for (var i = 0; i < 80; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        focusedTool = FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<FmToolButton>();
        if (focusedTool?.tooltip == 'More') break;
      }
      expect(focusedTool?.tooltip, 'More');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Select All'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Select All')).dy, greaterThan(100));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Select All'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
