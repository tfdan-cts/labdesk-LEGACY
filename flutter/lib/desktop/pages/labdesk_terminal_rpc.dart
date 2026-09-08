import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/labdesk/services/terminal_text.dart';
import 'package:flutter_hbb/models/model.dart' show FFI;
import 'package:flutter_hbb/models/terminal_model.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/labdesk/services/desktop_session_access.dart';

import '../../models/platform_model.dart';
import 'terminal_connection_manager.dart';

/// Answers the console's questions about a peer over the terminal window's
/// already-open connections.
///
/// The console runs in its own engine with no session of its own, so it cannot
/// talk to a peer directly. The terminal window can: it holds one FFI per peer.
/// These calls borrow that connection for headless PTYs the user never sees,
/// which is why they must not disturb the visible TerminalModels.
class LabDeskTerminalRpc {
  LabDeskTerminalRpc._();

  /// Command runs. Kept open between calls so a working directory and any
  /// shell state the user built up survive from one command to the next.
  static int _nextRunTerminalId = 1001;

  /// Wide enough that a long line of command output is not wrapped by the PTY,
  /// which would split a value across two lines and lose it.
  static const _rows = 24;
  static const _cols = 200;

  static final Map<String, _RunSession> _runSessions = {};
  static final Set<String> _authorizing = {};

  /// The distinct peers the terminal window currently has tabs for.
  static String peerList(DesktopTabController tabController) {
    final ids = <String>[];
    for (final tab in tabController.state.value.tabs) {
      // Tab keys are '<peerId>_<terminalId>' and a peer id may contain '_'.
      final cut = tab.key.lastIndexOf('_');
      final id = cut > 0 ? tab.key.substring(0, cut) : tab.key;
      if (!ids.contains(id)) ids.add(id);
    }
    return ids.join(',');
  }

  /// Run one command on the peer and read back what it printed, over the
  /// terminal window's connection.
  static Future<Map<String, dynamic>> run(String peerId, String command,
      {String? authority}) async {
    if (authority == null) return _runFailed('Sign in before running commands.');
    final ffi = TerminalConnectionManager.getExistingConnection(peerId);
    if (ffi == null || ffi.closed) {
      return _runFailed('no terminal session');
    }
    return runOn(ffi, peerId, command, authorityKey: authority,
        authorize: () => _windowAuthorized(authority));
  }

  static Future<bool> _windowAuthorized(String authority) async {
    try {
      return await DesktopMultiWindow.invokeMethod(kMainWindowId,
          DesktopSessionAccess.verifyMethod, authority)
          .timeout(const Duration(seconds: 5)) == true;
    } catch (_) {
      return false;
    }
  }

  /// The same command run over any connection to the peer.
  static Future<Map<String, dynamic>> runOn(
      FFI ffi, String peerId, String command,
      {String? authorityKey,
      Future<bool> Function()? authorize,
      Future<void> Function(int terminalId)? openTerminal,
      Future<void> Function(int terminalId, String data)? sendInput,
      Future<void> Function(int terminalId)? closeTerminal}) async {
    final authority = desktopSessionAccess.capture();
    final scope = authorityKey ?? desktopSessionAccess.nonceFor(authority);
    if (scope == null) return _runFailed('Sign in before running commands.');
    final check = authorize ?? () async => desktopSessionAccess.accepts(authority);
    if (ffi.closed) return _runFailed('connection closed');
    // Refuse concurrent admission immediately; never queue stale commands.
    if (!_authorizing.add(peerId)) return _runFailed('busy');
    try {
      if (!await check() ||
          (authorize == null && !desktopSessionAccess.accepts(authority))) {
        return _runFailed('Cancelled: account context changed.');
      }
    } catch (error) {
      return _runFailed('$error');
    } finally {
      _authorizing.remove(peerId);
    }
    final previous = _runSessions[peerId];
    if (previous != null &&
        (!identical(previous.ffi, ffi) || previous.scope != scope)) {
      _runSessions.remove(peerId);
      previous.cancel();
    }
    final session = _runSessions.putIfAbsent(peerId, () {
      final terminalId = _nextRunTerminalId++;
      return _RunSession(ffi, scope, terminalId, () =>
          closeTerminal?.call(terminalId) ?? bind.sessionCloseTerminal(
              sessionId: ffi.sessionId, terminalId: terminalId));
    });
    if (session.busy) {
      return _runFailed('busy');
    }
    session.busy = true;
    bool current() => !ffi.closed && !session.cancelled &&
        identical(_runSessions[peerId], session) &&
        (authorize != null || desktopSessionAccess.accepts(authority));
    Future<bool> accepted() async {
      final allowed = await check();
      if (allowed && current()) return true;
      if (identical(_runSessions[peerId], session)) _runSessions.remove(peerId);
      session.cancel();
      return false;
    }
    try {
      if (!current()) return _runFailed('Cancelled: account context changed.');
      ffi.setRawTerminalListener(session.terminalId, session.handle);
      if (!session.isOpen) {
        final opened = Completer<bool>();
        session.opened = opened;
        session.requested = true;
        await (openTerminal?.call(session.terminalId) ?? bind.sessionOpenTerminal(
          sessionId: ffi.sessionId,
          terminalId: session.terminalId,
          rows: _rows,
          cols: _cols,
        ));
        if (!current()) return _runFailed('Cancelled: account context changed.');
        final ok = await opened.future
            .timeout(const Duration(seconds: 5), onTimeout: () => false);
        session.opened = null;
        if (!ok) return _runFailed('terminal did not open');
      }
      // Opening a PTY and window authorization both await other processes.
      // Recheck at the command boundary, before any input can reach the peer.
      if (!await accepted() || !current()) return _runFailed('Cancelled: account context changed.');
      session.output.clear();
      final done = session.done = Completer<void>();
      var timedOut = false;
      final data = '${CommandFramer.frame(command, ffi.ffiModel.pi.platform)}\r';
      await (sendInput?.call(session.terminalId, data) ?? bind.sessionSendTerminalInput(
        sessionId: ffi.sessionId,
        terminalId: session.terminalId,
        data: data,
      ));
      await done.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => timedOut = true,
      );
      if (!await accepted() || !current()) return _runFailed('Cancelled: account context changed.');
      final parsed = CommandOutput.parse(session.output.toString(), command);
      return {
        'lines': parsed.lines,
        'exitCode': parsed.exitCode,
        'timedOut': timedOut,
      };
    } catch (e) {
      return _runFailed('$e');
    } finally {
      session.busy = false;
      session.done = null;
      session.opened = null;
      if (!current()) session.cancel();
    }
  }

  /// Reset only hidden command PTYs. Visible terminal tabs stay connected.
  static void reset() {
    final sessions = _runSessions.values.toList();
    _runSessions.clear();
    for (final session in sessions) {
      session.cancel();
    }
  }

  /// A delayed reset message must not cancel a newer account's command.
  static Future<void> resetUnauthorized() async {
    for (final entry in _runSessions.entries.toList()) {
      if (await _windowAuthorized(entry.value.scope)) continue;
      if (identical(_runSessions[entry.key], entry.value)) {
        _runSessions.remove(entry.key);
      }
      entry.value.cancel();
    }
  }

  static Map<String, dynamic> _runFailed(String reason) => {
        'lines': <String>[],
        'exitCode': null,
        'timedOut': false,
        'reason': reason,
      };

  /// Terminal data arrives base64 encoded on desktop, plain on some paths, and
  /// as a byte list on others, the same three shapes TerminalModel handles.
  static String _decodeData(dynamic data) {
    if (data is String) {
      try {
        return utf8.decode(base64Decode(data), allowMalformed: true);
      } catch (_) {
        return data;
      }
    }
    if (data is List) {
      return utf8.decode(List<int>.from(data), allowMalformed: true);
    }
    return '';
  }
}

/// Only a marker followed by a number is the shell reporting a status; the
/// PTY's echo of the command carries the marker text but no number yet.
final _endMarker = RegExp('${RegExp.escape(kLabDeskEndMarker)}=-?\\d+');

/// The persistent command terminal for one peer.
class _RunSession {
  _RunSession(this.ffi, this.scope, this.terminalId, this.closeTerminal);
  final FFI ffi;
  final String scope;
  final int terminalId;
  final Future<void> Function() closeTerminal;
  final StringBuffer output = StringBuffer();
  Completer<bool>? opened;
  Completer<void>? done;
  bool isOpen = false;
  bool busy = false;
  bool requested = false;
  bool cancelled = false;

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    if (opened != null && !opened!.isCompleted) opened!.complete(false);
    if (done != null && !done!.isCompleted) done!.complete();
    output.clear();
    ffi.setRawTerminalListener(terminalId, null);
    if (requested && !ffi.closed) {
      Future<void>.sync(closeTerminal).catchError((Object _) {});
    }
    isOpen = false;
  }

  void handle(Map<String, dynamic> evt) {
    if (cancelled) return;
    switch (evt['type']) {
      case 'opened':
        isOpen = TerminalModel.getSuccessFromEvt(evt);
        if (opened != null && !opened!.isCompleted) opened!.complete(isOpen);
        break;
      case 'data':
        output.write(LabDeskTerminalRpc._decodeData(evt['data']));
        if (done != null &&
            !done!.isCompleted &&
            _endMarker.hasMatch(output.toString())) {
          done!.complete();
        }
        break;
      case 'closed':
      case 'error':
        isOpen = false;
        if (opened != null && !opened!.isCompleted) opened!.complete(false);
        if (done != null && !done!.isCompleted) done!.complete();
        break;
    }
  }
}
