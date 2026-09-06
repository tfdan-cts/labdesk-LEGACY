import 'dart:convert';

import '../models/overlay_state.dart';

/// One labnet daemon action, carried out by the privileged LabDesk process.
///
/// `main_overlay_daemon` in `src/flutter_ffi.rs` is the implementation:
/// `action` is `install`, `start`, `up`, `down` or `status`; `setupKey` is
/// read by `up`; `managementUrl` by `install` and `up`. It answers
/// `{"output":...}`, the daemon's stdout, or `{"error":...}`, the daemon's
/// own words. Injected so the daemon can be driven by a fake in tests.
typedef DaemonCall = Future<String> Function(
    String action, String setupKey, String managementUrl);

/// The one file that knows the labnet daemon is NetBird.
///
/// It asks the privileged process to drive the bundled `netbird` command line
/// (`src/labdesk/labnet.rs`): that process holds the service, the socket and
/// the state directory, so installing and starting the service no longer
/// needs a UAC or polkit prompt, and the setup key never passes through this
/// user's files or argv. The daemon's socket is a named pipe on Windows,
/// which Dart cannot open, and streaming status over it is the upgrade path
/// once polling shows a cost.
///
/// Everything here talks to a LabDesk-owned daemon (its own service name,
/// socket and state directory), so a NetBird the user installed for
/// themselves is never touched.
class OverlayDaemon {
  OverlayDaemon({required DaemonCall call}) : _call = call;

  final DaemonCall _call;

  /// What the privileged process answered: the output, or the failure text.
  /// Exactly one of the two is set. An answer that is not the JSON the FFI
  /// writes is read as a failure in its own words rather than as output.
  Future<(String?, String?)> _run(String action,
      {String setupKey = '', String managementUrl = ''}) async {
    final String text;
    try {
      text = await _call(action, setupKey, managementUrl);
    } catch (e) {
      return (null, '$e');
    }
    try {
      final j = jsonDecode(text);
      if (j is Map) {
        final error = j['error'];
        if (error is String) return (null, error);
        final output = j['output'];
        if (output is String) return (output, null);
      }
    } catch (_) {}
    return (null, text);
  }

  /// The failure text of one action, or null when it succeeded.
  Future<String?> _fail(String action,
      {String setupKey = '', String managementUrl = ''}) async {
    final (_, err) =
        await _run(action, setupKey: setupKey, managementUrl: managementUrl);
    return err;
  }

  /// What the daemon reports now. Never throws.
  Future<OverlayState> status() async {
    final (out, err) = await _run('status');
    if (err != null) {
      if (err.contains('failed to connect to daemon')) {
        return OverlayState(
            status: OverlayDaemonStatus.notInstalled, error: err);
      }
      return OverlayState(status: OverlayDaemonStatus.unknown, error: err);
    }
    try {
      final json = jsonDecode(out!);
      if (json is Map<String, dynamic>) return OverlayState.fromStatusJson(json);
    } catch (_) {}
    return OverlayState(status: OverlayDaemonStatus.unknown, error: out!);
  }

  /// Installs the daemon as LabDesk's own service, pointed at
  /// [managementUrl] for good, so no later call needs privilege to change it.
  /// Returns the daemon's own words on failure, null on success.
  Future<String?> install(String managementUrl) =>
      _fail('install', managementUrl: managementUrl);

  Future<String?> start() => _fail('start');

  /// Registers with [managementUrl] using a one-off [setupKey] and connects.
  /// Returns the daemon's own words on failure, null on success.
  Future<String?> up({
    required String setupKey,
    required String managementUrl,
  }) =>
      _fail('up', setupKey: setupKey, managementUrl: managementUrl);

  Future<String?> down() => _fail('down');
}
