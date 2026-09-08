import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/labdesk/services/link_verdict.dart';
import 'package:flutter_hbb/labdesk/services/desktop_session_access.dart';
import 'package:flutter_hbb/models/model.dart';

/// The console's own connection to a machine, with no window behind it.
///
/// Health, the Terminal section and the tools all need a shell on the far
/// machine. Until now they could only borrow one from an open terminal window,
/// which meant nothing worked until the operator had opened one. A link is a
/// terminal-type session started from the main window itself: it authenticates
/// with the password the client has saved for the peer, carries the hidden
/// PTYs the probe and the command runner use, and shows nothing.
///
/// On the far side this is an ordinary incoming terminal connection: it is
/// listed in that machine's connection manager like any other, which is the
/// honest shape of an agentless monitor.
class LabDeskMachineLink {
  LabDeskMachineLink._();

  static final Map<String, FFI> _links = {};
  static final Map<String, Future<FFI?>> _opening = {};
  static final Map<String, DesktopSessionContext> _scopes = {};
  static final Map<String, Object> _attempts = {};

  /// Why the last attempt to reach a peer failed, in the far side's words
  /// ("ID does not exist", "the machine refused the saved password"). Cleared
  /// when a link opens.
  static final Map<String, String> lastFailure = {};

  /// The sentence the console prints when [open] returned null.
  static String reason(String peerId) =>
      'Could not connect: ${lastFailure[peerId] ?? 'no answer in ${readyTimeout.inSeconds} s'}.';

  /// How long a link may take to authenticate before it is written off. A
  /// peer that wants a password nobody saved, or one that needs a click on its
  /// side, never sets its peer info, and this is what stops that waiting forever.
  static const readyTimeout = Duration(seconds: 20);

  static bool isOpen(String peerId) {
    final f = _links[peerId];
    return desktopSessionAccess.accepts(_scopes[peerId]) &&
        f != null &&
        !f.closed &&
        f.ffiModel.pi.isSet.value;
  }

  static Iterable<String> get openIds =>
      _links.keys.where(isOpen).toList(growable: false);

  /// The link to a peer, opened if there is none. Null when it could not be
  /// authenticated in time; the reason is whatever the far side wanted, and
  /// the caller says so rather than guessing.
  static Future<FFI?> open(String peerId,
      {Future<String?> Function()? beforeOpen, FFI Function()? createLink}) {
    final authority = desktopSessionAccess.capture();
    if (authority == null) {
      close(peerId);
      lastFailure[peerId] = 'Sign in before running machine commands';
      return Future.value(null);
    }
    if (_scopes[peerId] != authority) close(peerId);
    _scopes[peerId] = authority;
    return _opening.putIfAbsent(peerId, () async {
      final attempt = Object();
      _attempts[peerId] = attempt;
      bool current() =>
          identical(_attempts[peerId], attempt) &&
          desktopSessionAccess.accepts(authority);
      FFI? created;
      try {
        // All headless RMM tools use this same admission point. A prepared
        // labnet ticket must exist before FFI starts its connection, and a
        // failure must not silently fall through to another provider.
        final admissionError =
            await Future<String?>.sync(() => beforeOpen?.call());
        if (!current()) return null;
        if (admissionError != null) {
          _links.remove(peerId)?.close();
          lastFailure[peerId] = admissionError;
          return null;
        }
        // Recheck admission for each command, including a cached connection.
        final existing = _links[peerId];
        if (existing != null &&
            !existing.closed &&
            existing.ffiModel.pi.isSet.value) return existing;
        _links[peerId]?.close();
        final ffi = created = createLink?.call() ?? FFI(null);
        _links[peerId] = ffi;
        lastFailure.remove(peerId);
        final ready = Completer<bool>();
        // No window, nobody watching: a dialog the client would raise is
        // either the reason this link failed, or progress to wait through.
        ffi.headlessMsgBox = (type, title, text) {
          if (!desktopSessionAccess.accepts(authority) ||
              !identical(_links[peerId], ffi)) {
            if (!ready.isCompleted) ready.complete(false);
            return;
          }
          final why = linkFailure(type, title, text);
          if (why == null) return;
          lastFailure[peerId] = why;
          if (!ready.isCompleted) ready.complete(false);
        };
        ffi.start(peerId, isTerminal: true);
        final sub = ffi.ffiModel.pi.isSet.listen((set) {
          if (set && !ready.isCompleted) ready.complete(true);
        });
        if (ffi.ffiModel.pi.isSet.value && !ready.isCompleted) {
          ready.complete(true);
        }
        final ok =
            await ready.future.timeout(readyTimeout, onTimeout: () => false);
        await sub.cancel();
        if (!current() || !ok || ffi.closed) {
          debugPrint('labdesk: link to $peerId: ${reason(peerId)}');
          ffi.close();
          if (identical(_links[peerId], ffi)) _links.remove(peerId);
          return null;
        }
        return ffi;
      } catch (e) {
        created?.close();
        if (current()) {
          lastFailure[peerId] = '$e';
          _links.remove(peerId)?.close();
        }
        return null;
      } finally {
        if (identical(_attempts[peerId], attempt)) {
          _attempts.remove(peerId);
          _opening.remove(peerId);
          if (!_links.containsKey(peerId)) _scopes.remove(peerId);
        }
      }
    });
  }

  static void close(String peerId) {
    _attempts.remove(peerId);
    _opening.remove(peerId);
    _scopes.remove(peerId);
    _links.remove(peerId)?.close();
  }

  static void closeAll() {
    _attempts.clear();
    _opening.clear();
    _scopes.clear();
    for (final f in _links.values) {
      f.close();
    }
    _links.clear();
  }
}
