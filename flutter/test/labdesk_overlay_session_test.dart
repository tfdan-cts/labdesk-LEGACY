import 'dart:async';
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
  final requests = <({
    String method,
    String path,
    Map<String, String> headers,
    String? body
  })>[];
  String token = 'token-a';
  String organization = 'org-a';
  String machinePrefix = 'a';
  int brokerStatus = 200;
  int deleteStatus = 200;
  String link = 'P2P';
  String? statusJson;
  Completer<String>? waitingStatus;
  Completer<(int, String)>? waitingReady;
  final acknowledgements = <bool>[];
  bool ticketReady = true;
  bool authorized = true;
  int nextGrant = 0;

  Future<String> call(
      String action, String setupKey, String managementUrl) async {
    log.add('daemon $action');
    if (waitingStatus != null) return waitingStatus!.future;
    final up = statuses.isEmpty ? true : statuses.removeAt(0);
    return jsonEncode(
        {'output': statusJson ?? _status(targetUp: up).replaceAll('P2P', link)});
  }

  Future<(int, String)> http(
      String method, Uri url, Map<String, String> h, String? body) async {
    log.add('broker $method ${url.path}');
    requests
        .add((method: method, path: url.path, headers: Map.of(h), body: body));
    if (method == 'DELETE') return (deleteStatus, '{}');
    if (url.path.endsWith('/ready')) {
      if (waitingReady != null) return waitingReady!.future;
      if (url.queryParameters.containsKey('mode')) {
        return (brokerStatus, jsonEncode({'authorized': authorized}));
      }
      return (
        brokerStatus,
        jsonEncode({
          'ready': acknowledgements.isEmpty
              ? ticketReady
              : acknowledgements.removeAt(0)
        })
      );
    }
    if (method == 'POST') nextGrant++;
    return (
      brokerStatus,
      '{"id":"s$nextGrant","targetAddr":"100.64.0.9:21118","targetIdPk":"pk=",$ticketJson"error":"That machine has not come up on labnet yet."}'
    );
  }

  /// The connect ticket minted with the grant; empty for a Worker without one.
  String ticketJson =
      '"ticket":{"id":"t1","secret":"c2VjcmV0","expiresAt":1788480243},';

  OverlaySession session(
          {Duration readyTimeout = const Duration(seconds: 3)}) =>
      OverlaySession(
        broker: OverlayBroker(
            baseUrl: 'https://lab-desk.net',
            token: () => token,
            organizationId: () => organization,
            machineIdOf: (id) => '$machinePrefix-$id',
            http: http),
        daemon: OverlayDaemon(call: call),
        setOption: (k, v) async {
          log.add('option $k=$v');
          options[k] = v;
        },
        sleep: (_) async {},
        readyTimeout: readyTimeout,
      );
}

void main() {
  test('an existing window revalidates only its original exact mode', () async {
    for (final mode in ['desktop', 'files', 'camera', 'terminal', 'terminal_admin', 'rdp', 'tcp']) {
      final w = _World();
      final session = w.session();
      expect(await session.prepare('1', mode: mode), isTrue);
      expect(await session.revalidate('1', mode: mode), isTrue);
      expect(await session.revalidate('1', mode: mode), isTrue);
      final mismatched = switch (mode) {
        'terminal' => 'terminal_admin',
        'terminal_admin' => 'terminal',
        'rdp' => 'tcp',
        'tcp' => 'rdp',
        _ => 'terminal',
      };
      expect(await session.revalidate('1', mode: mismatched), isFalse);
      expect(w.nextGrant, 1);
    }
  });

  test('repeated commands revalidate their own grant without minting', () async {
    final w = _World();
    final session = w.session();
    expect(await session.prepare('1', mode: 'terminal', owner: 'command'), isTrue);
    for (var i = 0; i < 120; i++) {
      expect(await session.revalidate('1', mode: 'terminal', owner: 'command'), isTrue);
    }
    expect(w.nextGrant, 1);
    expect(await session.revalidate('1', mode: 'terminal'), isFalse);
    expect(await session.revalidate('1', mode: 'desktop', owner: 'command'), isFalse);
    w.authorized = false;
    expect(await session.revalidate('1', mode: 'terminal', owner: 'command'), isFalse);
    expect(w.nextGrant, 1);
  });

  test('reuse refuses account switches and switches during authorization', () async {
    final w = _World();
    final session = w.session();
    await session.prepare('1', mode: 'terminal', owner: 'command');
    w.token = 'token-b';
    expect(await session.revalidate('1', mode: 'terminal', owner: 'command'), isFalse);
    w.token = 'token-a';
    w.waitingReady = Completer<(int, String)>();
    final checking = session.revalidate('1', mode: 'terminal', owner: 'command');
    await Future<void>.delayed(Duration.zero);
    w.organization = 'org-b';
    w.waitingReady!.complete((200, '{"authorized":true}'));
    expect(await checking, isFalse);
  });

  test('closing one mode releases only its grant in either order', () async {
    for (final closed in ['desktop', 'files']) {
      final w = _World();
      final session = w.session();
      await session.prepare('1');
      await session.prepare('1', mode: 'files');
      await session.noteOpenSessions(['1'], owners: {'1': {'desktop', 'files'}});
      final kept = closed == 'desktop' ? 'files' : 'desktop';
      await session.noteOpenSessions(['1'], owners: {'1': {kept}});
      final closedId = closed == 'desktop' ? 's1' : 's2';
      expect(w.requests.where((r) => r.method == 'DELETE').map((r) => r.path),
          ['/console/overlay/session/$closedId']);
      expect(session.hasGrants, isTrue);
      expect(w.options['labdesk-overlay-required-1'], 'Y');
      await session.noteOpenSessions([], owners: {});
      expect(w.requests.where((r) => r.method == 'DELETE'), hasLength(2));
      expect(session.hasGrants, isFalse);
    }
  });

  test('closing a command link preserves a visible terminal grant', () async {
    final w = _World();
    final session = w.session();
    await session.prepare('1', mode: 'terminal');
    await session.prepare('1', mode: 'terminal', owner: 'command');
    await session.noteOpenSessions(['1'], owners: {'1': {'terminal', 'command'}});
    await session.noteOpenSessions(['1'], owners: {'1': {'terminal'}});
    expect(w.requests.where((r) => r.method == 'DELETE').map((r) => r.path),
        ['/console/overlay/session/s2']);
    expect(await session.revalidate('1', mode: 'terminal'), isTrue);
    expect(await session.revalidate('1', mode: 'terminal', owner: 'command'), isFalse);
  });

  test('an acknowledged idle lazy peer can be dialed without a warmup probe',
      () async {
    const idle = '{"daemonStatus":"Connected","netbirdIp":"100.64.0.3/16",'
        '"lazyConnectionEnabled":true,"peers":{"details":[{"fqdn":"b",'
        '"netbirdIp":"100.64.0.9","publicKey":"x","status":"Idle",'
        '"connectionType":"-"}]}}';
    final ready = _World()..statusJson = idle;
    expect(await ready.session().prepare('1'), isTrue);
    expect(ready.options['labdesk-overlay-required-1'], 'Y');
    expect(ready.options['labdesk-ticket-1'], 'c2VjcmV0');

    final unready = _World()
      ..statusJson = idle
      ..ticketReady = false;
    expect(await unready.session().prepare('1'), isFalse);
    expect(unready.options.values, everyElement(isEmpty));
  });

  test('account rejection is reported before stalled grant cleanup', () async {
    final w = _World();
    final releasing = Completer<void>();
    final resumeRelease = Completer<void>();
    addTearDown(() {
      if (!resumeRelease.isCompleted) resumeRelease.complete();
    });
    final session = OverlaySession(
      broker: OverlayBroker(
        baseUrl: 'https://lab-desk.net',
        token: () => w.token,
        organizationId: () => w.organization,
        http: (method, url, headers, body) async {
          final response = await w.http(method, url, headers, body);
          if (url.path.endsWith('/ready')) {
            return (401, '{"error":"Sign in again."}');
          }
          if (method == 'DELETE') {
            releasing.complete();
            await resumeRelease.future;
          }
          return response;
        },
      ),
      daemon: OverlayDaemon(call: w.call),
      setOption: (key, value) async {
        w.log.add('option $key=$value');
        w.options[key] = value;
      },
    );
    OverlayBrokerException? reported;
    var settled = false;
    final preparing = session.prepare('1', onAuthenticationFailure: (error) {
      reported = error;
      w.log.add('account rejected');
      w.token = 'token-b';
      w.organization = 'org-b';
    }).whenComplete(() => settled = true);
    final rejected = expectLater(
        preparing,
        throwsA(isA<OverlayBrokerException>().having(
            (error) => identical(error, reported), 'reported error', isTrue)));

    await releasing.future.timeout(const Duration(seconds: 1));
    expect(reported?.signInAgain, isTrue);
    expect(settled, isFalse);
    expect(w.log.indexOf('account rejected'),
        lessThan(w.log.indexWhere((entry) => entry.startsWith('option '))));
    final deletion =
        w.requests.singleWhere((request) => request.method == 'DELETE');
    expect(deletion.headers['authorization'], 'Bearer token-a');
    expect(deletion.headers['x-labdesk-organization'], 'org-a');
    resumeRelease.complete();
    await rejected;
    expect(settled, isTrue);
    expect(w.options.values, everyElement(isEmpty));
  });

  for (final stage in ['creation', 'readiness']) {
    test('account rejection during $stage remains typed after cleanup', () async {
      final w = _World();
      final session = OverlaySession(
        broker: OverlayBroker(
          baseUrl: 'https://lab-desk.net',
          token: () => w.token,
          organizationId: () => w.organization,
          http: (method, url, headers, body) async {
            if ((stage == 'creation' && method == 'POST') ||
                (stage == 'readiness' && url.path.endsWith('/ready'))) {
              await w.http(method, url, headers, body);
              w.token = 'token-b';
              w.organization = 'org-b';
              return (401, '{"error":"Sign in again."}');
            }
            return w.http(method, url, headers, body);
          },
        ),
        daemon: OverlayDaemon(call: w.call),
        setOption: (key, value) async => w.options[key] = value,
      );

      await expectLater(
          session.prepare('1'),
          throwsA(isA<OverlayBrokerException>()
              .having((error) => error.signInAgain, 'account rejection', isTrue)
              .having((error) => error.message, 'message', 'Sign in again.')));
      expect(session.lastError, 'Sign in again.');
      expect(session.hasGrants, isFalse);
      expect(w.options.values, everyElement(isEmpty));
      final deletions = w.requests.where((request) => request.method == 'DELETE');
      expect(deletions.length, stage == 'readiness' ? 1 : 0);
      for (final request in deletions) {
        expect(request.headers['authorization'], 'Bearer token-a');
        expect(request.headers['x-labdesk-organization'], 'org-a');
      }
    });
  }

  for (final stage in ['creation', 'readiness']) {
    test('context switch during $stage keeps the grant in its original scope',
        () async {
      final w = _World();
      final entered = Completer<void>();
      final resume = Completer<void>();
      var held = false;
      final session = OverlaySession(
        broker: OverlayBroker(
          baseUrl: 'https://lab-desk.net',
          token: () => w.token,
          organizationId: () => w.organization,
          machineIdOf: (id) => '${w.machinePrefix}-$id',
          http: (method, url, headers, body) async {
            final response = await w.http(method, url, headers, body);
            if (!held &&
                ((stage == 'creation' && method == 'POST') ||
                    (stage == 'readiness' && url.path.endsWith('/ready')))) {
              held = true;
              entered.complete();
              await resume.future;
            }
            return response;
          },
        ),
        daemon: OverlayDaemon(call: w.call),
        setOption: (key, value) async => w.options[key] = value,
      );
      final preparing = session.prepare('1');
      await entered.future;
      w.token = 'token-b';
      w.organization = 'org-b';
      w.machinePrefix = 'b';
      resume.complete();
      expect(await preparing, isTrue);
      await session.release('1');
      expect(w.requests.map((r) => r.headers['authorization']),
          everyElement('Bearer token-a'));
      expect(w.requests.map((r) => r.headers['x-labdesk-organization']),
          everyElement('org-a'));
      expect(jsonDecode(w.requests.first.body!)['target'], 'a-1');

      w.requests.clear();
      expect(await session.prepare('1'), isTrue);
      await session.release('1');
      expect(w.requests.map((r) => r.headers['authorization']),
          everyElement('Bearer token-b'));
      expect(w.requests.map((r) => r.headers['x-labdesk-organization']),
          everyElement('org-b'));
      expect(jsonDecode(w.requests.first.body!)['target'], 'b-1');
    });
  }
  for (final stage in [
    'broker',
    'readiness',
    'addr',
    'pk',
    'ticket',
    'required'
  ]) {
    test('disable cancels preparation during $stage and releases its grant',
        () async {
      final w = _World();
      final entered = Completer<void>();
      final resume = Completer<void>();
      final option = {
        'addr': kOverlayAddrOption,
        'pk': kOverlayPkOption,
        'ticket': kOverlayTicketOption,
        'required': kOverlayRequiredOption,
      }[stage];
      final session = OverlaySession(
        broker: OverlayBroker(
          baseUrl: 'https://lab-desk.net',
          token: () => w.token,
          organizationId: () => w.organization,
          http: (method, url, headers, body) async {
            if ((stage == 'broker' && method == 'POST') ||
                (stage == 'readiness' && url.path.endsWith('/ready'))) {
              entered.complete();
              await resume.future;
            }
            return w.http(method, url, headers, body);
          },
        ),
        daemon: OverlayDaemon(call: w.call),
        setOption: (key, value) async {
          if (option != null && key == '${option}1' && value.isNotEmpty) {
            entered.complete();
            await resume.future;
          }
          w.options[key] = value;
        },
      );
      final preparing = session.prepare('1');
      await entered.future;
      w.token = 'token-b';
      w.organization = 'org-b';
      await session.releaseAll();
      resume.complete();
      expect(await preparing, isFalse);
      expect(w.options.values, everyElement(isEmpty));
      expect(session.hasGrants, isFalse);
      expect(w.log, contains('broker DELETE /console/overlay/session/s1'));
      final deletion = w.requests.singleWhere((r) => r.method == 'DELETE');
      expect(deletion.headers['authorization'], 'Bearer token-a');
      expect(deletion.headers['x-labdesk-organization'], 'org-a');
    });
  }

  test('late creation cleanup keeps its scope and preserves newer peer hints',
      () async {
    final w = _World();
    final minted = Completer<(int, String)>();
    final entered = Completer<void>();
    final released = Completer<void>();
    var held = false;
    final session = OverlaySession(
      broker: OverlayBroker(
        baseUrl: 'https://lab-desk.net',
        token: () => w.token,
        organizationId: () => w.organization,
        machineIdOf: (id) => '${w.machinePrefix}-$id',
        http: (method, url, headers, body) async {
          if (method == 'POST' && !held) {
            held = true;
            entered.complete();
            return minted.future;
          }
          final answer = await w.http(method, url, headers, body);
          if (method == 'DELETE' && url.path.endsWith('/late')) {
            released.complete();
          }
          return answer;
        },
      ),
      daemon: OverlayDaemon(call: w.call),
      setOption: (key, value) async => w.options[key] = value,
      readyTimeout: const Duration(seconds: 1),
    );
    final preparing = session.prepare('1');
    await entered.future;
    w.token = 'token-b';
    w.organization = 'org-b';
    w.machinePrefix = 'b';
    expect(await preparing.timeout(const Duration(seconds: 2)), isFalse);
    expect(session.lastError, contains('timed out'));
    expect(await session.prepare('1'), isTrue);
    final newHints = Map.of(w.options);
    minted.complete((
      200,
      '{"id":"late","targetAddr":"100.64.0.9:21118","targetIdPk":"pk",'
          '"ticket":{"secret":"secret"}}'
    ));
    await released.future.timeout(const Duration(seconds: 1));
    expect(session.hasGrants, isTrue);
    expect(w.options, newHints);
    final deletion = w.requests.singleWhere((r) => r.method == 'DELETE');
    expect(deletion.path, '/console/overlay/session/late');
    expect(deletion.headers['authorization'], 'Bearer token-a');
    expect(deletion.headers['x-labdesk-organization'], 'org-a');
    expect(
        w.requests
            .where((r) => r.method != 'DELETE')
            .map((r) => r.headers['authorization']),
        everyElement('Bearer token-b'));
    expect(
        w.requests
            .where((r) => r.method != 'DELETE')
            .map((r) => r.headers['x-labdesk-organization']),
        everyElement('org-b'));
  });

  test('a hung target readiness read obeys the wall-clock readiness budget',
      () async {
    final w = _World()..waitingReady = Completer<(int, String)>();
    final session = w.session(readyTimeout: const Duration(seconds: 1));
    expect(
        await session.prepare('1').timeout(const Duration(milliseconds: 1500)),
        isFalse);
    expect(session.lastError, contains('timed out'));
    w.waitingReady!.complete((200, '{"ready":true}'));
    await Future<void>.delayed(Duration.zero);
    expect(w.options.values, everyElement(isEmpty),
        reason: 'a late read must never publish dial hints');
  });

  test('a hung local daemon read obeys the same wall-clock readiness budget',
      () async {
    final w = _World()..waitingStatus = Completer<String>();
    final session = w.session(readyTimeout: const Duration(seconds: 1));
    expect(
        await session.prepare('1').timeout(const Duration(milliseconds: 1500)),
        isFalse);
    expect(session.lastError, contains('timed out'));
    w.waitingStatus!.complete(jsonEncode({'output': _status(targetUp: true)}));
    await Future<void>.delayed(Duration.zero);
    expect(w.options.values, everyElement(isEmpty));
  });
  test('a release lost during an outage is retried by subsequent session polls',
      () async {
    final w = _World();
    final session = w.session();
    await session.prepare('1');
    await session.noteOpenSessions(['1']);
    w.token = 'token-b';
    w.organization = 'org-b';
    w.machinePrefix = 'b';
    w.deleteStatus = 503;
    await session.noteOpenSessions([]);
    expect(await session.prepare('1'), isTrue);
    final newHints = Map.of(w.options);
    w.deleteStatus = 200;
    await session.noteOpenSessions(['1']);
    expect(w.options, newHints);
    final deletes = w.requests.where((r) => r.method == 'DELETE');
    expect(deletes.map((r) => r.headers['authorization']),
        everyElement('Bearer token-a'));
    expect(deletes.map((r) => r.headers['x-labdesk-organization']),
        everyElement('org-a'));
    expect(
        w.log.where(
            (line) => line == 'broker DELETE /console/overlay/session/s1'),
        hasLength(2));
    await session.noteOpenSessions(['1']);
    expect(
        w.log.where(
            (line) => line == 'broker DELETE /console/overlay/session/s1'),
        hasLength(2));
  });

  test(
      'an acknowledged ticket that expires while waiting for tunnel cannot be dialed',
      () async {
    final w = _World()
      ..statuses.addAll([false, true, true])
      ..acknowledgements.addAll([true, false, false]);
    expect(await w.session().prepare('1'), isFalse);
    expect(w.options.values, everyElement(isEmpty));
  });

  test('an encrypted NetBird relay remains a valid session transport',
      () async {
    final w = _World()..link = 'Relayed';
    final session = w.session();
    expect(await session.prepare('1'), isTrue);
    expect(session.lastLink.name, 'relayed');
    expect(session.lastStatus, isNotNull);
  });
  test(
      'a grant whose peer is up writes the address, key and ticket hints for the client',
      () async {
    final w = _World();
    expect(await w.session().prepare('1180573903'), isTrue);
    expect(w.options, {
      'labdesk-overlay-addr-1180573903': '100.64.0.9:21118',
      'labdesk-overlay-pk-1180573903': 'pk=',
      'labdesk-ticket-1180573903': 'c2VjcmV0',
      'labdesk-overlay-required-1180573903': 'Y',
    });
    expect(w.log, [
      'broker POST /console/overlay/session',
      'daemon status',
      'broker GET /console/overlay/session/s1/ready',
      'option labdesk-overlay-addr-1180573903=100.64.0.9:21118',
      'option labdesk-overlay-pk-1180573903=pk=',
      'option labdesk-ticket-1180573903=c2VjcmV0',
      'option labdesk-overlay-required-1180573903=Y'
    ]);
  });

  test('a grant without a ticket is refused instead of reusing a stale secret',
      () async {
    final w = _World()..ticketJson = '';
    w.options['labdesk-ticket-1'] = 'old-secret';
    expect(await w.session().prepare('1'), isFalse);
    expect(w.options.values, everyElement(isEmpty));
  });

  test(
      'the client waits for the peer to come up, one status read a second, up to the cap',
      () async {
    final w = _World()..statuses.addAll([false, false, true]);
    expect(await w.session().prepare('1'), isTrue);
    expect(w.log.where((l) => l == 'daemon status'), hasLength(3));
  });

  test(
      'a peer that never comes up within the cap yields no hint and releases the grant',
      () async {
    final w = _World()..statuses.addAll([false, false, false, false]);
    expect(await w.session().prepare('1'), isFalse);
    expect(w.options.values, everyElement(isEmpty));
    expect(w.log.last, 'broker DELETE /console/overlay/session/s1');
  });

  test('a refused grant clears old hints and exposes the server reason',
      () async {
    final w = _World()..brokerStatus = 409;
    final session = w.session();
    expect(await session.prepare('1'), isFalse);
    expect(w.options.values, everyElement(isEmpty));
    expect(session.lastError, 'That machine has not come up on labnet yet.');
  });

  test(
      'a session seen open and then gone is released once and its hints cleared',
      () async {
    final w = _World();
    final s = w.session();
    await s.prepare('1');
    await s.noteOpenSessions(['1']);
    await s.noteOpenSessions([]);
    await s.noteOpenSessions([]);
    expect(w.options, {
      'labdesk-overlay-addr-1': '',
      'labdesk-overlay-pk-1': '',
      'labdesk-ticket-1': '',
      'labdesk-overlay-required-1': ''
    });
    expect(w.log.where((l) => l == 'broker DELETE /console/overlay/session/s1'),
        hasLength(1));
    expect(s.hasGrants, isFalse);
  });

  test('a session not yet seen open is kept while the window comes up',
      () async {
    final w = _World();
    final s = w.session();
    await s.prepare('1');
    await s.noteOpenSessions([]);
    expect(s.hasGrants, isTrue);
    expect(w.log.where((l) => l.startsWith('broker DELETE')), isEmpty);
  });

  test(
      'a session never seen open is released once the window has passed, and its hints cleared',
      () async {
    final w = _World();
    final s = w.session();
    await s.prepare('1');
    for (var i = 0; i < OverlaySession.unseenPollLimit - 1; i++) {
      await s.noteOpenSessions([]);
    }
    expect(s.hasGrants, isTrue,
        reason: 'one poll short of the window it is still waiting');
    await s.noteOpenSessions([]);
    expect(s.hasGrants, isFalse);
    expect(w.options, {
      'labdesk-overlay-addr-1': '',
      'labdesk-overlay-pk-1': '',
      'labdesk-ticket-1': '',
      'labdesk-overlay-required-1': ''
    });
    expect(w.log.where((l) => l == 'broker DELETE /console/overlay/session/s1'),
        hasLength(1));
  });

  test(
      'connected WireGuard peer is not dialable until target acknowledges ticket',
      () async {
    final w = _World()..ticketReady = false;
    final session = w.session();
    expect(await session.prepare('1'), isFalse);
    expect(w.options.values, everyElement(isEmpty));
    expect(w.log.last, 'broker DELETE /console/overlay/session/s1');
  });

  test('waits for target acknowledgement before publishing any dial hints',
      () async {
    final w = _World()..acknowledgements.addAll([false, false, true]);
    expect(await w.session().prepare('1'), isTrue);
    final calls = w.log.where((line) => line.endsWith('/ready'));
    expect(calls, hasLength(3));
    expect(
        w.log.indexWhere((line) => line.startsWith('option ')),
        greaterThan(
            w.log.lastIndexOf('broker GET /console/overlay/session/s1/ready')));
  });

  test(
      'overlapping scopes to one peer keep every grant until final window closes',
      () async {
    final w = _World();
    final session = w.session();
    await session.prepare('1');
    await session.noteOpenSessions(['1']);
    w.token = 'token-b';
    w.organization = 'org-b';
    w.machinePrefix = 'b';
    await session.prepare('1');
    await session.noteOpenSessions(['1', '1']);
    await session.noteOpenSessions(['1']);
    expect(w.log.where((line) => line.startsWith('broker DELETE')), isEmpty);
    await session.noteOpenSessions([]);
    expect(w.log.where((line) => line.startsWith('broker DELETE')), [
      'broker DELETE /console/overlay/session/s1',
      'broker DELETE /console/overlay/session/s2'
    ]);
    final deletes = w.requests.where((r) => r.method == 'DELETE').toList();
    expect(deletes.map((r) => r.headers['authorization']),
        ['Bearer token-a', 'Bearer token-b']);
    expect(deletes.map((r) => r.headers['x-labdesk-organization']),
        ['org-a', 'org-b']);
  });
}
