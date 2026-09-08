import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/labdesk/services/desktop_session_access.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const events = MethodChannel('mixin.one/flutter_multi_window_channel');
  const windows = MethodChannel('mixin.one/flutter_multi_window');
  DesktopSessionContext? authority;
  late Completer<bool> active;
  var created = 0;
  setUp(() {
    authority = ('account-a', 1);
    desktopSessionAccess.readContext = () => authority;
    active = Completer<bool>();
    created = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, (call) async {
      if (call.method == kWindowEventActiveSession) return active.future;
      throw StateError('Unexpected window dispatch: ${call.method}');
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, (call) async {
      if (call.method == 'createWindow') created++;
      throw StateError('Unexpected native window operation: ${call.method}');
    });
  });
  tearDown(() {
    desktopSessionAccess.readContext = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, null);
  });

  test('new session lookup cannot dispatch after A to B to A', () async {
    final manager = LabDeskMultiWindowManager.forTesting();
    final pending = manager.newSession(WindowType.FileTransfer,
        kWindowEventNewFileTransfer, 'peer', [7, 8]);
    authority = ('account-b', 2);
    authority = ('account-a', 3);
    active.complete(false);
    expect((await pending).windowId, kInvalidWindowId);
    expect(created, 0);
  });

  test('terminal lookup cannot create or elevate a window after signout', () async {
    final manager = LabDeskMultiWindowManager.forTesting(terminalWindows: [7]);
    final pending = manager.newTerminal('peer', terminalAdmin: true);
    authority = null;
    active.complete(false);
    expect((await pending).windowId, kInvalidWindowId);
    expect(created, 0);
    expect(manager.windowsOfType(WindowType.Terminal), [7]);
  });

  test('verified lookup can retain the explicitly opened terminal', () async {
    final manager = LabDeskMultiWindowManager.forTesting(terminalWindows: [7]);
    final pending = manager.newTerminal('peer');
    active.complete(true);
    expect((await pending).windowId, 7);
    expect(created, 0);
    expect(manager.windowsOfType(WindowType.Terminal), [7]);
  });
}
