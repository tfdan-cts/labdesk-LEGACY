import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/overlay_state.dart';
import 'package:flutter_hbb/labdesk/services/overlay_daemon.dart';

/// The labnet daemon, driven through the privileged process by a fake that
/// answers the way `main_overlay_daemon` (src/flutter_ffi.rs) does:
/// `{"output":...}` or `{"error":...}`.
///
/// Field names in the fixture follow the struct tags in the daemon's source
/// (client/status/status.go, NetBird v0.78.0). It is a composed sample, not
/// a capture; the first live `status --json` replaces it.
const _statusJson = '''
{
  "peers": {"total": 2, "connected": 1, "details": [
    {"fqdn": "foundry.netbird.cloud", "netbirdIp": "100.64.0.7", "publicKey": "pkA=", "status": "Connected",
     "connectionType": "P2P", "latency": 12500000, "lastWireguardHandshake": "2026-09-03T10:00:00Z"},
    {"fqdn": "homebox.netbird.cloud", "netbirdIp": "100.64.0.9", "publicKey": "pkB=", "status": "Idle",
     "connectionType": "Relayed", "latency": 0}
  ]},
  "cliVersion": "0.78.0", "daemonVersion": "0.78.0", "daemonStatus": "Connected",
  "management": {"url": "https://nb.lab-desk.net:443", "connected": true, "error": ""},
  "signal": {"url": "https://nb.lab-desk.net:443", "connected": true, "error": ""},
  "relays": {"total": 1, "available": 1, "details": []},
  "netbirdIp": "100.64.0.3/16", "publicKey": "me=", "usesKernelInterface": false, "wireguardPort": 51820,
  "fqdn": "zenbook.netbird.cloud"
}
''';

class _Fake {
  final calls = <(String, String, String)>[];
  String next = '{"output":""}';

  Future<String> call(String action, String setupKey, String managementUrl) async {
    calls.add((action, setupKey, managementUrl));
    return next;
  }
}

OverlayDaemon _daemon(_Fake f) => OverlayDaemon(call: f.call);

String _output(String s) => jsonEncode({'output': s});
String _error(String s) => jsonEncode({'error': s});

void main() {
  group('OverlayState.fromStatusJson', () {
    test('reads the daemon status, this machine, and the peers it can reach',
        () {
      final f = _Fake()..next = _output(_statusJson);
      return _daemon(f).status().then((s) {
        expect(s.status, OverlayDaemonStatus.connected);
        expect(s.isUp, isTrue);
        expect(s.ip, '100.64.0.3/16');
        expect(s.name, 'zenbook.netbird.cloud');
        expect(s.managementConnected, isTrue);
        expect(s.signalConnected, isTrue);
        expect(s.peers, hasLength(2));
        final a = s.peerAt('100.64.0.7')!;
        expect(a.name, 'foundry.netbird.cloud');
        expect(a.connected, isTrue);
        expect(a.link, OverlayLinkType.direct);
        expect(a.latencyMs, 12, reason: 'Go serialises a Duration in ns');
        final b = s.peerAt('100.64.0.9')!;
        expect(b.connected, isFalse);
        expect(b.link, OverlayLinkType.relayed);
        expect(b.latencyMs, isNull);
        expect(s.peerAt('100.64.0.99'), isNull);
      });
    });

    test('maps every daemon status the source defines', () {
      const expected = {
        'Idle': OverlayDaemonStatus.idle,
        'Connecting': OverlayDaemonStatus.connecting,
        'Connected': OverlayDaemonStatus.connected,
        'NeedsLogin': OverlayDaemonStatus.needsLogin,
        'LoginFailed': OverlayDaemonStatus.loginFailed,
        'SessionExpired': OverlayDaemonStatus.sessionExpired,
        'SomethingNew': OverlayDaemonStatus.unknown,
      };
      expected.forEach((word, status) {
        expect(OverlayState.fromStatusJson({'daemonStatus': word}).status,
            status,
            reason: word);
      });
    });

    test('carries the management error the daemon gives', () {
      final s = OverlayState.fromStatusJson({
        'daemonStatus': 'LoginFailed',
        'management': {'connected': false, 'error': 'setup key expired'},
      });
      expect(s.status, OverlayDaemonStatus.loginFailed);
      expect(s.managementError, 'setup key expired');
    });
  });

  group('OverlayDaemon.status', () {
    test('asks the privileged process for status and nothing else', () async {
      final f = _Fake()..next = _output(_statusJson);
      await _daemon(f).status();
      expect(f.calls.single, ('status', '', ''));
    });

    test('reads notInstalled when no daemon answers the command line',
        () async {
      final f = _Fake()
        ..next = _error(
            'failed to connect to daemon error: context deadline exceeded\nIf the daemon is not running please run: netbird service install');
      final s = await _daemon(f).status();
      expect(s.status, OverlayDaemonStatus.notInstalled);
      expect(s.error, contains('failed to connect to daemon'));
    });

    test('never throws on output it cannot parse', () async {
      final f = _Fake()..next = _output('not json at all');
      final s = await _daemon(f).status();
      expect(s.status, OverlayDaemonStatus.unknown);
      expect(s.error, 'not json at all');
    });

    test('an answer that is not the FFI\'s shape is a failure in its own words',
        () async {
      final f = _Fake()..next = 'garbage';
      final s = await _daemon(f).status();
      expect(s.status, OverlayDaemonStatus.unknown);
      expect(s.error, 'garbage');
    });

    test('a privileged process that cannot be reached is a failure, not a throw',
        () async {
      final d = OverlayDaemon(call: (_, __, ___) => throw StateError('no ipc'));
      final s = await d.status();
      expect(s.status, OverlayDaemonStatus.unknown);
      expect(s.error, contains('no ipc'));
    });
  });

  group('OverlayDaemon commands', () {
    test('up hands the key and the control plane to the privileged process',
        () async {
      final f = _Fake();
      final err = await _daemon(f).up(
          setupKey: 'SK-1', managementUrl: 'https://nb.lab-desk.net');
      expect(err, isNull);
      expect(f.calls.single, ('up', 'SK-1', 'https://nb.lab-desk.net'));
    });

    test('a failed up returns the daemon\'s own words', () async {
      final f = _Fake()..next = _error('Error: setup key not valid');
      expect(await _daemon(f).up(setupKey: 'x', managementUrl: 'u'),
          'Error: setup key not valid');
    });

    test('install fixes the control plane and start carries nothing', () async {
      final f = _Fake();
      final d = _daemon(f);
      expect(await d.install('https://nb.lab-desk.net'), isNull);
      expect(await d.start(), isNull);
      expect(await d.down(), isNull);
      expect(f.calls, [
        ('install', '', 'https://nb.lab-desk.net'),
        ('start', '', ''),
        ('down', '', ''),
      ]);
    });

    test('a refused control plane is the privileged process\'s sentence',
        () async {
      final f = _Fake()
        ..next = _error('Refusing a control plane other than nb.lab-desk.net');
      expect(await _daemon(f).install('https://evil.example'),
          'Refusing a control plane other than nb.lab-desk.net');
    });
  });
}
