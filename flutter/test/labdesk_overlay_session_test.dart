import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';
import 'package:flutter_hbb/labdesk/services/overlay_daemon.dart';
import 'package:flutter_hbb/labdesk/services/overlay_session.dart';

/// A session grant: asked for, waited on until the target peer is up, handed
/// to the client as hints, and released when the session is gone.
String _status({required bool targetUp}) =>
    '{"daemonStatus":"Connected","netbirdIp":"100.64.0.3/16","peers":{"details":[{"fqdn":"b","netbirdIp":"100.64.0.9","publicKey":"x","status":"${targetUp ? 'Connected' : 'Connecting'}","connectionType":"P2P","latency":0}]}}';

class _World {
  final log = <String>[];
  final options = <String, String>{};
  final statuses = <bool>[];
  int brokerStatus = 200;

  Future<String> call(String action, String setupKey, String managementUrl) async {
    log.add('daemon $action');
    final up = statuses.isEmpty ? true : statuses.removeAt(0);
    return jsonEncode({'output': _status(targetUp: up)});
  }

  Future<(int, String)> http(String method, Uri url, Map<String, String> h, String? body) async {
    log.add('broker $method ${url.path}');
    return (brokerStatus, '{"id":"s1","targetAddr":"100.64.0.9:21118","targetIdPk":"pk=",$ticketJson"error":"That machine has not come up on labnet yet."}');
  }

  /// The connect ticket minted with the grant; empty for a Worker without one.
  String ticketJson = '"ticket":{"id":"t1","secret":"c2VjcmV0","expiresAt":1788480243},';

  OverlaySession session() => OverlaySession(
        broker: OverlayBroker(baseUrl: 'https://lab-desk.net', token: () => 't', http: http),
        daemon: OverlayDaemon(call: call),
        setOption: (k, v) async {
          log.add('option $k=$v');
          options[k] = v;
        },
        sleep: (_) async {},
        readyTimeout: const Duration(seconds: 3),
      );
}

void main() {
  test('a grant whose peer is up writes the address, key and ticket hints for the client', () async {
    final w = _World();
    expect(await w.session().prepare('1180573903'), isTrue);
    expect(w.options, {
      'labdesk-overlay-addr-1180573903': '100.64.0.9:21118',
      'labdesk-overlay-pk-1180573903': 'pk=',
      'labdesk-ticket-1180573903': 'c2VjcmV0',
    });
    expect(w.log, ['broker POST /console/overlay/session', 'daemon status', 'option labdesk-overlay-addr-1180573903=100.64.0.9:21118', 'option labdesk-overlay-pk-1180573903=pk=', 'option labdesk-ticket-1180573903=c2VjcmV0']);
  });

  test('a grant without a ticket writes the two hints and no ticket option', () async {
    final w = _World()..ticketJson = '';
    expect(await w.session().prepare('1'), isTrue);
    expect(w.options, {'labdesk-overlay-addr-1': '100.64.0.9:21118', 'labdesk-overlay-pk-1': 'pk='});
  });

  test('the client waits for the peer to come up, one status read a second, up to the cap', () async {
    final w = _World()..statuses.addAll([false, false, true]);
    expect(await w.session().prepare('1'), isTrue);
    expect(w.log.where((l) => l == 'daemon status'), hasLength(3));
  });

  test('a peer that never comes up within the cap yields no hint and releases the grant', () async {
    final w = _World()..statuses.addAll([false, false, false, false]);
    expect(await w.session().prepare('1'), isFalse);
    expect(w.options, isEmpty);
    expect(w.log.last, 'broker DELETE /console/overlay/session/s1');
  });

  test('a refused grant yields no hint and no error', () async {
    final w = _World()..brokerStatus = 409;
    expect(await w.session().prepare('1'), isFalse);
    expect(w.options, isEmpty);
    expect(w.log, ['broker POST /console/overlay/session']);
  });

  test('a session seen open and then gone is released once and its hints cleared', () async {
    final w = _World();
    final s = w.session();
    await s.prepare('1');
    await s.noteOpenSessions(['1']);
    await s.noteOpenSessions([]);
    await s.noteOpenSessions([]);
    expect(w.options, {'labdesk-overlay-addr-1': '', 'labdesk-overlay-pk-1': '', 'labdesk-ticket-1': ''});
    expect(w.log.where((l) => l == 'broker DELETE /console/overlay/session/s1'), hasLength(1));
    expect(s.hasGrants, isFalse);
  });

  test('a session not yet seen open is kept while the window comes up', () async {
    final w = _World();
    final s = w.session();
    await s.prepare('1');
    await s.noteOpenSessions([]);
    expect(s.hasGrants, isTrue);
    expect(w.log.where((l) => l.startsWith('broker DELETE')), isEmpty);
  });

  test('a session never seen open is released once the window has passed, and its hints cleared', () async {
    final w = _World();
    final s = w.session();
    await s.prepare('1');
    for (var i = 0; i < OverlaySession.unseenPollLimit - 1; i++) {
      await s.noteOpenSessions([]);
    }
    expect(s.hasGrants, isTrue, reason: 'one poll short of the window it is still waiting');
    await s.noteOpenSessions([]);
    expect(s.hasGrants, isFalse);
    expect(w.options, {'labdesk-overlay-addr-1': '', 'labdesk-overlay-pk-1': '', 'labdesk-ticket-1': ''});
    expect(w.log.where((l) => l == 'broker DELETE /console/overlay/session/s1'), hasLength(1));
  });
}
