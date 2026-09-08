import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/pages/labdesk_terminal_rpc.dart';
import 'package:flutter_hbb/labdesk/services/desktop_session_access.dart';
import 'package:flutter_hbb/labdesk/services/terminal_text.dart';
import 'package:flutter_hbb/models/model.dart';

class _Model implements FfiModel {
  @override
  final pi = PeerInfo()..platform = 'Linux';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection implements FFI {
  @override
  bool closed = false;
  @override
  final ffiModel = _Model();
  final listeners = <int, void Function(Map<String, dynamic>)>{};
  @override
  void setRawTerminalListener(int id, void Function(Map<String, dynamic>)? listener) {
    if (listener == null) { listeners.remove(id); } else { listeners[id] = listener; }
  }
  void opened(int id) => listeners[id]?.call({'type': 'opened', 'success': true});
  void output(int id, String text) => listeners[id]?.call({
    'type': 'data', 'data': base64Encode(utf8.encode('$text\n$kLabDeskEndMarker=0\n')),
  });
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const windowEvents = MethodChannel('mixin.one/flutter_multi_window_channel');
  DesktopSessionContext? authority;
  setUp(() {
    authority = ('account-a', 1);
    desktopSessionAccess.readContext = () => authority;
  });
  tearDown(() {
    LabDeskTerminalRpc.reset();
    desktopSessionAccess.readContext = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(windowEvents, null);
  });

  test('PTY opening cannot send a command after account A to B to A', () async {
    final ffi = _Connection();
    final opening = Completer<int>();
    final sent = <String>[];
    final closed = <int>[];
    final run = LabDeskTerminalRpc.runOn(ffi, 'peer', 'sensitive-command',
      openTerminal: (id) async { opening.complete(id); },
      sendInput: (id, text) async { sent.add(text); },
      closeTerminal: (id) async { closed.add(id); });
    final id = await opening.future;
    authority = ('account-b', 2);
    authority = ('account-a', 3);
    ffi.opened(id);
    expect((await run)['reason'], contains('context changed'));
    expect(sent, isEmpty);
    expect(closed, [id]);
    expect(ffi.closed, isFalse);
  });

  test('window receiver rechecks authority after opening its hidden PTY', () async {
    final ffi = _Connection();
    var checks = 0, sends = 0;
    final result = await LabDeskTerminalRpc.runOn(ffi, 'peer', 'command',
      authorityKey: 'opaque-window-context',
      authorize: () async => ++checks == 1,
      openTerminal: (id) async { ffi.opened(id); },
      sendInput: (_, __) async { sends++; },
      closeTerminal: (_) async {});
    expect(checks, 2);
    expect(sends, 0);
    expect(result['reason'], contains('context changed'));
  });

  test('account reset cancels waiting output while preserving the visible FFI', () async {
    final ffi = _Connection();
    final sent = Completer<int>();
    final closed = <int>[];
    final run = LabDeskTerminalRpc.runOn(ffi, 'peer', 'command',
      openTerminal: (id) async { ffi.opened(id); },
      sendInput: (id, _) async { sent.complete(id); },
      closeTerminal: (id) async { closed.add(id); });
    final id = await sent.future;
    authority = null;
    LabDeskTerminalRpc.reset();
    expect((await run)['reason'], contains('context changed'));
    expect(closed, [id]);
    expect(ffi.closed, isFalse);
    expect(ffi.listeners, isEmpty);
  });

  test('new account receives a fresh PTY and no previous command output', () async {
    final ffi = _Connection();
    final opened = <int>[], closed = <int>[];
    Future<Map<String, dynamic>> run(String result) => LabDeskTerminalRpc.runOn(
      ffi, 'peer', 'command',
      openTerminal: (id) async { opened.add(id); ffi.opened(id); },
      sendInput: (id, _) async { ffi.output(id, result); },
      closeTerminal: (id) async { closed.add(id); });
    expect((await run('private-a'))['lines'], ['private-a']);
    authority = ('account-b', 2);
    expect((await run('private-b'))['lines'], ['private-b']);
    expect(opened.length, 2);
    expect(opened[0], isNot(opened[1]));
    expect(closed, [opened[0]]);
    expect(ffi.closed, isFalse);
  });

  test('concurrent calls cannot open duplicate PTYs while authorization waits', () async {
    final ffi = _Connection();
    final permission = Completer<bool>();
    final first = LabDeskTerminalRpc.runOn(ffi, 'peer', 'command',
      authorityKey: 'scope', authorize: () => permission.future);
    final second = await LabDeskTerminalRpc.runOn(ffi, 'peer', 'other',
      authorityKey: 'scope', authorize: () => permission.future)
        .timeout(const Duration(seconds: 1),
            onTimeout: () => {'reason': 'authorization admission did not return busy'});
    permission.complete(false);
    expect(second['reason'], 'busy');
    expect((await first)['reason'], contains('context changed'));
  });

  test('a delayed reset cannot discard a newer account command session', () async {
    final ffi = _Connection();
    final opened = <int>[], closed = <int>[];
    Future<Map<String, dynamic>> run() => LabDeskTerminalRpc.runOn(
      ffi, 'peer', 'command',
      openTerminal: (id) async { opened.add(id); ffi.opened(id); },
      sendInput: (id, _) async { ffi.output(id, 'result'); },
      closeTerminal: (id) async { closed.add(id); });
    await run();
    final check = Completer<bool>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(windowEvents,
        (call) async => check.future);
    final reset = LabDeskTerminalRpc.resetUnauthorized();
    authority = ('account-b', 2);
    await run();
    check.complete(false);
    await reset;
    await run();
    expect(opened.length, 2);
    expect(closed, [opened.first]);
    expect(ffi.closed, isFalse);
  });

  test('unauthorized direct and window commands stop before touching native FFI', () async {
    authority = null;
    expect((await LabDeskTerminalRpc.runOn(_Connection(), 'peer', 'command'))['reason'],
        contains('Sign in'));
    expect((await LabDeskTerminalRpc.run('peer', 'command'))['reason'], contains('Sign in'));
  });

  test('a rejected old command cannot close the current account hidden PTY', () async {
    final ffi = _Connection();
    final opened = <int>[], closed = <int>[];
    Future<Map<String, dynamic>> runCurrent() => LabDeskTerminalRpc.runOn(
      ffi, 'peer', 'command',
      openTerminal: (id) async { opened.add(id); ffi.opened(id); },
      sendInput: (id, _) async { ffi.output(id, 'current'); },
      closeTerminal: (id) async { closed.add(id); });
    authority = ('current-account', 2);
    await runCurrent();
    final rejected = await LabDeskTerminalRpc.runOn(ffi, 'peer', 'old command',
        authorityKey: 'old-window-authority', authorize: () async => false);
    expect(rejected['reason'], contains('context changed'));
    expect(closed, isEmpty);
    expect((await runCurrent())['lines'], ['current']);
    expect(opened.length, 1);
  });
}
