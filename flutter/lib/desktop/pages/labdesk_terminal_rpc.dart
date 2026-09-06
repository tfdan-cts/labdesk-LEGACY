import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/labdesk/services/terminal_text.dart';
import 'package:flutter_hbb/models/model.dart' show FFI;
import 'package:flutter_hbb/models/terminal_model.dart';

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
  static const _runTerminalId = 1001;

  /// Wide enough that a long line of command output is not wrapped by the PTY,
  /// which would split a value across two lines and lose it.
  static const _rows = 24;
  static const _cols = 200;

  static final Map<String, _RunSession> _runSessions = {};

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
  static Future<Map<String, dynamic>> run(String peerId, String command) async {
    final ffi = TerminalConnectionManager.getExistingConnection(peerId);
    if (ffi == null || ffi.closed) {
      return _runFailed('no terminal session');
    }
    return runOn(ffi, peerId, command);
  }

  /// The same command run over any connection to the peer.
  static Future<Map<String, dynamic>> runOn(
      FFI ffi, String peerId, String command) async {
    if (ffi.closed) return _runFailed('connection closed');
    final session = _runSessions.putIfAbsent(peerId, () => _RunSession());
    if (session.done != null) {
      return _runFailed('busy');
    }

    // Re-registered every call: the peer's FFI is replaced on reconnect, and a
    // listener left on the old one would never be called again.
    ffi.setRawTerminalListener(_runTerminalId, (evt) => session.handle(evt));

    try {
      if (!session.isOpen) {
        final opened = Completer<bool>();
        session.opened = opened;
        await bind.sessionOpenTerminal(
          sessionId: ffi.sessionId,
          terminalId: _runTerminalId,
          rows: _rows,
          cols: _cols,
        );
        final ok = await opened.future
            .timeout(const Duration(seconds: 5), onTimeout: () => false);
        session.opened = null;
        if (!ok) return _runFailed('terminal did not open');
      }

      session.output.clear();
      session.done = Completer<void>();
      var timedOut = false;
      await bind.sessionSendTerminalInput(
        sessionId: ffi.sessionId,
        terminalId: _runTerminalId,
        data: '${CommandFramer.frame(command, ffi.ffiModel.pi.platform)}\r',
      );
      await session.done!.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => timedOut = true,
      );
      final parsed = CommandOutput.parse(session.output.toString(), command);
      return {
        'lines': parsed.lines,
        'exitCode': parsed.exitCode,
        'timedOut': timedOut,
      };
    } catch (e) {
      return _runFailed('$e');
    } finally {
      session.done = null;
      session.opened = null;
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
  final StringBuffer output = StringBuffer();
  Completer<bool>? opened;
  Completer<void>? done;
  bool isOpen = false;

  void handle(Map<String, dynamic> evt) {
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
