import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';

/// The console read routes on lab-desk.net (contract section 5) and the two
/// labnet writes that were unreachable from the desktop (section 9).
class _Wire {
  final calls = <String>[];
  final byPath = <String, Object>{};
  int status = 200;
  Object reply = const {};

  Future<(int, String)> call(
      String method, Uri url, Map<String, String> headers, String? body) async {
    calls.add('$method ${url.path}${url.hasQuery ? '?${url.query}' : ''}'
        '${body == null ? '' : ' $body'}');
    return (status, jsonEncode(byPath[url.path] ?? reply));
  }
}

OverlayBroker _broker(_Wire w) =>
    OverlayBroker(baseUrl: 'https://lab-desk.net', token: () => 't', http: w.call);

void main() {
  test('the fleet is read with its hot row in one request', () async {
    final w = _Wire()
      ..byPath['/console/org/machines'] = {
        'machines': [
          {
            'id': 'm1',
            'peerId': '482910337',
            'displayName': 'Workshop NAS',
            'hostname': 'workshop-nas',
            'platform': 'linux',
            'fleetId': 'F1',
            'status': 'online',
            'seenAt': 1788480300,
            'cpuPct': 7,
            'memPct': null,
            'fsWorstPct': 55,
            'worstDisk': 'ok',
          }
        ]
      };
    final machines = await _broker(w).machines();
    // One request, with the state join asked for, and not one per machine.
    expect(w.calls.single, 'GET /console/org/machines?state=1');
    expect(machines.single.name, 'Workshop NAS');
    expect(machines.single.peerId, '482910337');
    expect(machines.single.fleetId, 'F1');
    expect(machines.single.state.isOnline, isTrue);
    expect(machines.single.state.cpuPct, 7);
    expect(machines.single.state.memPct, isNull);
  });

  test('the network view is read off the machine attributes', () async {
    final w = _Wire()
      ..byPath['/console/org/machines/m1'] = {
        'machine': {'id': 'm1'},
        'attrs': {
          'net.reachability': {
            'value': '{"internet":"online","selfheal":"watching"}',
            'source': 'agent',
            'updatedAt': 1788480300,
          }
        }
      };
    final view = await _broker(w).netView('m1');
    expect(w.calls.single, 'GET /console/org/machines/m1');
    expect(view.reachability.internet, 'online');
    expect(view.reachability.selfHealRunning, isTrue);
  });

  test('creating a labnet can name the fleet it belongs to', () async {
    final w = _Wire()..reply = {'id': 'L1', 'name': 'Rack', 'fleetId': 'F2'};
    final made = await _broker(w).createLabnet('Rack', fleetId: 'F2');
    expect(w.calls.single,
        'POST /console/overlay/labnets {"name":"Rack","fleetId":"F2"}');
    expect(made.fleetId, 'F2');

    // A caller who sees the whole organization sends no fleet at all.
    final w2 = _Wire()..reply = {'id': 'L2', 'name': 'Rack'};
    await _broker(w2).createLabnet('Rack');
    expect(w2.calls.single, 'POST /console/overlay/labnets {"name":"Rack"}');
  });

  test('a labnet is renamed over the same patch route', () async {
    final w = _Wire();
    await _broker(w).renameLabnet('L1', 'Rack two');
    expect(w.calls.single,
        'PATCH /console/overlay/labnets/L1 {"name":"Rack two"}');
  });

  test('a refusal for a stale sign-in is told apart from every other 403',
      () async {
    const stale = OverlayBrokerException(
        403, 'Sign in again to confirm this change.');
    const forbidden =
        OverlayBrokerException(403, 'Your role cannot do that.');
    const gone = OverlayBrokerException(401, 'Sign in again.');
    expect(stale.needsFreshSignIn, isTrue);
    expect(forbidden.needsFreshSignIn, isFalse);
    // A 401 is a sign-in that is gone, which the account surface reports; it is
    // not the fresh-token retry.
    expect(gone.needsFreshSignIn, isFalse);
    expect(gone.signInAgain, isTrue);
  });
}
