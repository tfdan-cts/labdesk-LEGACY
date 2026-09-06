import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';

/// The labnet routes on lab-desk.net, spoken by a broker over a fake wire.
///
/// [byPath] answers one route with its own body, which is what the two-plane
/// reads need: the inbox is composed from two routes that answer different
/// halves of it, and a test that could not tell them apart could not prove
/// which half came from where.
class _Wire {
  final calls = <({String method, String url, Map<String, String> headers, String? body})>[];
  final byPath = <String, Object>{};
  int status = 200;
  Object reply = const {};
  Future<(int, String)> call(String method, Uri url, Map<String, String> headers, String? body) async {
    calls.add((method: method, url: url.toString(), headers: headers, body: body));
    return (status, jsonEncode(byPath[url.path] ?? reply));
  }
}

/// The machine credential, as `main_agent_sign` (src/flutter_ffi.rs) answers
/// it. The signature is spelled out rather than random so a test can read what
/// was signed; the real one is Ed25519 over `uplink_signed_msg`
/// (src/labdesk/identity.rs), which is exactly these three plus the hash of the
/// body.
class _Key {
  final asked = <String>[];
  bool enrolled = true;
  static const ts = '1788480000';

  Future<MachineSignature?> sign(String method, String path, String body) async {
    asked.add('$method $path $body');
    if (!enrolled) return null;
    return MachineSignature(machine: 'm-1', ts: ts, sig: 'over|$method|$path|$body');
  }
}

/// Which credential a request went out with, read off the wire. A request
/// carrying both, or neither, is named as such so it cannot match either plane.
String _planeOf(Map<String, String> h) {
  final signed = h.keys.any((k) => k.startsWith('x-ld-'));
  final tokened = h.containsKey('authorization');
  if (signed && !tokened) return 'machine';
  if (tokened && !signed) return 'human';
  return signed ? 'both' : 'neither';
}

String _row(({String method, String url, Map<String, String> headers, String? body}) c) =>
    '${_planeOf(c.headers)} ${c.method} ${Uri.parse(c.url).path} ${c.body ?? '-'}';

/// What `GET /agent/overlay/inbox` answers, transcribed from the `c.json` that
/// ends that route (src/worker/routes/agent-overlay.ts): this machine's own
/// standing and the invitations waiting on it, plus the labnets THIS MACHINE
/// has joined, which the console deliberately does not read.
const _machineInbox = {
  'device': {'enrolled': true, 'overlayIp': '100.64.0.3'},
  'invitations': [
    {'labnetId': 'L1', 'name': 'Office', 'invitedBy': 'owner@example.com'}
  ],
  'labnets': [
    {
      'id': 'L9',
      'name': 'Joined by this machine only',
      'fullAccess': false,
      'members': [
        {'machineId': 'm-1', 'status': 'approved', 'overlayIp': '100.64.0.3'}
      ]
    }
  ],
};

/// What `GET /console/overlay/labnets` answers, transcribed from that route and
/// from `labnetMembers` (src/worker/routes/overlay.ts). A member is
/// `{machineId,status,overlayIp}` and NOTHING here carries `owner`: both were
/// what the client used to read, and reading them off this shape is how the two
/// suites stayed green while disagreeing.
const _humanLabnets = {
  'labnets': [
    {
      'id': 'L2',
      'name': 'Lab',
      'fullAccess': true,
      'fleetId': null,
      'members': [
        {'machineId': 'm-1', 'status': 'approved', 'overlayIp': '100.64.0.5'},
        {'machineId': 'M3', 'status': 'pending', 'overlayIp': null},
      ]
    }
  ],
};

/// What `GET /console/org/machines` answers (src/worker/routes/org.ts), cut to the
/// keys this client reads.
const _orgMachines = {
  'machines': [
    {'id': 'm-1', 'peerId': '1180573903', 'displayName': 'Bench', 'hostname': 'zenbook'},
    {'id': 'M2', 'peerId': '900000001', 'displayName': '', 'hostname': 'reception'},
  ],
};

void main() {
  var token = 'tok-1';
  _Wire wire = _Wire();
  _Key key = _Key();
  // The map the console builds from `GET /console/org/machines` and gives the
  // broker: this machine is peer 1180573903 and machine m-1.
  var fleet = <String, String>{};
  OverlayBroker broker() => OverlayBroker(
      baseUrl: 'https://lab-desk.net',
      token: () => token,
      sign: key.sign,
      peerId: () => '1180573903',
      machineIdOf: (peer) => fleet[peer] ?? '',
      http: wire.call);
  setUp(() {
    token = 'tok-1';
    wire = _Wire();
    key = _Key();
    fleet = {'1180573903': 'm-1', '900000001': 'M2'};
  });

  /// THE CONTRACT TEST, and the reason it exists: until this landed, the Dart
  /// suite asserted the routes the Dart called and the Worker suite asserted
  /// the routes the Worker served, so the six machine-side routes could move
  /// onto the signed plane with both suites staying green.
  ///
  /// WHAT IT PROVES: every call this client makes goes to the route that
  /// serves it, on the right plane, carrying that plane's credential and no
  /// other, with the body keys that route reads; and what the machine plane
  /// signs is the request that is sent, which is what `agentAuth` rebuilds and
  /// verifies (src/worker/agent-auth.ts).
  ///
  /// WHAT IT DOES NOT PROVE: that the table below still matches the Worker.
  /// The Worker is a different repository (labdesk-site) with its own CI, and
  /// the two jobs share no artifact, so a route renamed there is caught by a
  /// person reading this list and by nothing else. Closing that needs a
  /// contract artifact the Worker's suite publishes and this one asserts; it
  /// is not something a Flutter test can reach on its own. The table was
  /// transcribed from `src/worker/routes/agent-overlay.ts` (machine plane),
  /// `src/worker/routes/overlay.ts` and `src/worker/routes/org.ts` (human
  /// plane) on feat/labnet-broker.
  test('every labnet call goes to its Worker route, on its plane, with that plane\'s credential', () async {
    wire.reply = {
      'setupKey': 'SK',
      'managementUrl': 'https://nb.lab-desk.net',
      'id': 's1',
      'targetAddr': '100.64.0.9:21118',
      'targetIdPk': 'pk=',
      'name': 'Office',
      'fullAccess': true,
    };
    final b = broker();
    // The machine plane: this machine's own labnet identity, and nothing in
    // any of these names a machine.
    await b.enrol();
    await b.reportSelf(overlayIp: '100.64.0.3', publicKey: 'wg=', idPk: 'id=', directPort: 21118);
    await b.decide('L1', approve: false);
    await b.leave('L1');
    await b.revoke();
    // The human plane: what a person does to an organization's labnets.
    await b.machines();
    await b.session('900000001');
    await b.endSession('s1');
    await b.createLabnet('Office');
    await b.setFullAccess('L1', true);
    await b.invite('L1', 'M3');
    await b.removeMember('L1', 'M3');
    await b.deleteLabnet('L1');
    // Both planes at once: the machine says what it is, the account says what
    // the organization holds.
    await b.inbox();

    expect(wire.calls.map(_row), [
      'machine POST /agent/overlay/enrol {}',
      'machine POST /agent/overlay/self {"overlayIp":"100.64.0.3","publicKey":"wg=","idPk":"id=","directPort":21118}',
      'machine POST /agent/overlay/invites/L1/decide {"approve":false}',
      'machine POST /agent/overlay/labnets/L1/leave {}',
      'machine DELETE /agent/overlay/enrol -',
      'human GET /console/org/machines -',
      'human POST /console/overlay/session {"controller":"m-1","target":"M2"}',
      'human DELETE /console/overlay/session/s1 -',
      'human POST /console/overlay/labnets {"name":"Office"}',
      'human PATCH /console/overlay/labnets/L1 {"fullAccess":true}',
      'human POST /console/overlay/labnets/L1/invite {"machine":"M3"}',
      'human DELETE /console/overlay/labnets/L1/members/M3 -',
      'human DELETE /console/overlay/labnets/L1 -',
      'machine GET /agent/overlay/inbox -',
      'human GET /console/overlay/labnets -',
    ]);

    // The signature covers the request as sent, under the timestamp the header
    // carries. A signature over a different path, or over a body re-encoded
    // after signing, is refused by the Worker and is caught here instead.
    for (final c in wire.calls.where((c) => _planeOf(c.headers) == 'machine')) {
      expect(c.headers['x-ld-machine'], 'm-1');
      expect(c.headers['x-ld-ts'], _Key.ts);
      expect(c.headers['x-ld-sig'],
          'over|${c.method}|${Uri.parse(c.url).path}|${c.body ?? ''}');
    }
    // Nothing on the human plane is signed. Every request that was is a
    // machine-plane one, in the order they were made.
    expect(key.asked, [
      'POST /agent/overlay/enrol {}',
      'POST /agent/overlay/self {"overlayIp":"100.64.0.3","publicKey":"wg=","idPk":"id=","directPort":21118}',
      'POST /agent/overlay/invites/L1/decide {"approve":false}',
      'POST /agent/overlay/labnets/L1/leave {}',
      'DELETE /agent/overlay/enrol ',
      'GET /agent/overlay/inbox ',
    ]);
  });

  /// THE OTHER HALF OF THE SAME CONTRACT. The request direction was repointed
  /// at the agent plane while the client went on reading the answers the OLD
  /// routes gave: a member was `deviceId` and a labnet carried `owner`, and
  /// neither is on either route that answers now. Both suites stayed green
  /// through that, because each read its own fixture.
  ///
  /// WHAT IT PROVES: the bodies below, transcribed from the Worker source, are
  /// read into the model the Network section renders. WHAT IT DOES NOT PROVE:
  /// that the Worker still writes them, for the same reason the request table
  /// above cannot.
  test('the inbox is read the way the two routes that answer it write it', () async {
    wire.byPath['/agent/overlay/inbox'] = _machineInbox;
    wire.byPath['/console/overlay/labnets'] = _humanLabnets;
    final inbox = await broker().inbox();

    // This machine's own half, from the machine plane.
    expect(inbox.enrolled, isTrue);
    expect(inbox.overlayIp, '100.64.0.3');
    expect(inbox.invitations.single.labnetId, 'L1');
    expect(inbox.invitations.single.name, 'Office');
    expect(inbox.invitations.single.invitedBy, 'owner@example.com');

    // The organization's half, from the human plane. L9 is the machine's own
    // list and must not be here: it holds only what this machine has joined,
    // so reading it back would lose every labnet the account has just made or
    // whose members are still deciding.
    expect(inbox.labnets.map((l) => l.id), ['L2']);
    final l = inbox.labnets.single;
    expect(l.name, 'Lab');
    expect(l.fullAccess, isTrue);
    // Neither route answers `owner`. Every labnet this one does answer is
    // scoped to the caller's organization and narrowed to their fleets by the
    // same predicate every write applies, so the console offers the owner's
    // actions on all of them and the server decides.
    expect(l.owner, isTrue);
    // The member id is `machineId`, which is what `invite` and `removeMember`
    // send back and what the Network section matches this machine against.
    expect(l.members.map((m) => m.deviceId), ['m-1', 'M3']);
    expect(l.members.map((m) => m.approved), [true, false]);
    expect(l.members.first.overlayIp, '100.64.0.5');
    expect(l.members.last.overlayIp, isNull);
  });

  test('the organization\'s machines are read with both ids, named by whichever name it has', () async {
    wire.byPath['/console/org/machines'] = _orgMachines;
    final machines = await broker().machines();
    expect(machines.map((m) => '${m.id} ${m.peerId} ${m.name}'),
        ['m-1 1180573903 Bench', 'M2 900000001 reception']);
  });

  /// The id domains: the console names a machine by the peer id in its connect
  /// box, every labnet route resolves `machine.id`, and a peer id sent as one
  /// is answered "No such machine."
  test('a session names both ends by the machine id, never by the peer id', () async {
    wire.reply = {'id': 's1', 'targetAddr': '100.64.0.9:21118', 'targetIdPk': 'pk='};
    await broker().session('900000001');
    expect(jsonDecode(wire.calls.single.body!), {'controller': 'm-1', 'target': 'M2'});
    // A machine the organization's list does not hold is named to nobody
    // rather than named by a peer id the server would look up as a machine id.
    wire.calls.clear();
    await broker().session('700000002');
    expect(jsonDecode(wire.calls.single.body!), {'controller': 'm-1', 'target': ''});
  });

  test('a machine with no key of its own is refused before anything is sent', () async {
    key.enrolled = false;
    await expectLater(
        broker().enrol(),
        throwsA(isA<OverlayBrokerException>()
            .having((e) => e.signInAgain, 'signInAgain', isFalse)
            .having((e) => e.message, 'message', contains('not enrolled'))));
    expect(wire.calls, isEmpty);
    // The human plane needs no machine key, so the labnets an account manages
    // are still read; what is missing is only what the machine says about
    // itself, and a machine with no key is not enrolled.
    wire.byPath['/console/overlay/labnets'] = _humanLabnets;
    final inbox = await broker().inbox();
    expect(inbox.enrolled, isFalse);
    expect(inbox.invitations, isEmpty);
    expect(inbox.labnets.single.members.map((m) => m.deviceId), ['m-1', 'M3']);
    expect(wire.calls.map(_row), ['human GET /console/overlay/labnets -']);
  });

  /// The private-phase Cloudflare Access wall answers `/api/*` with a 302 to
  /// its sign-in page, and the bypass that lets the desktop through carries
  /// `/agent` and `/console` and must never gain `/api`. So the app token is
  /// good on `/console/*` only, and a human-plane call built on `/api/` would
  /// never reach a handler.
  test('no human-plane call ever targets /api/', () async {
    wire.reply = {'id': 's1', 'targetAddr': '100.64.0.9:21118', 'targetIdPk': 'pk=', 'name': 'Office', 'fullAccess': true};
    final b = broker();
    await b.machines();
    await b.session('900000001');
    await b.endSession('s1');
    await b.createLabnet('Office');
    await b.setFullAccess('L1', true);
    await b.invite('L1', 'M3');
    await b.removeMember('L1', 'M3');
    await b.deleteLabnet('L1');
    await b.inbox();
    final human = wire.calls.where((c) => _planeOf(c.headers) == 'human').map((c) => Uri.parse(c.url).path);
    expect(human, hasLength(9));
    expect(human, everyElement(startsWith('/console/')));
    expect(human, everyElement(isNot(startsWith('/api/'))));
  });

  test('the human plane carries the account token read at that moment', () async {
    wire.reply = {'id': 'L1', 'name': 'Office', 'fullAccess': false};
    final b = broker();
    await b.createLabnet('Office');
    token = 'tok-2';
    await b.createLabnet('Lab');
    expect(wire.calls.map((c) => c.headers['authorization']), ['Bearer tok-1', 'Bearer tok-2']);
  });

  test('a session grant carries the address, the id key and the connect ticket', () async {
    wire.reply = {'id': 's1', 'targetAddr': '100.64.0.9:21118', 'targetIdPk': 'pk=', 'ticket': {'id': 't1', 'secret': 'c2VjcmV0', 'expiresAt': 1788480243}};
    final g = await broker().session('900000001');
    expect(g.id, 's1');
    expect(g.targetAddr, '100.64.0.9:21118');
    expect(g.targetIdPk, 'pk=');
    expect(g.ticket, 'c2VjcmV0');
    // A Worker that mints no ticket (contracts section 3) hands back an empty one.
    wire.reply = {'id': 's1', 'targetAddr': '100.64.0.9:21118', 'targetIdPk': 'pk='};
    expect((await broker().session('900000001')).ticket, '');
  });

  test('a refusal surfaces the server\'s own sentence, and only the human plane\'s 401 is a sign-in', () async {
    wire.status = 401;
    wire.reply = {'error': 'Sign in first'};
    await expectLater(broker().session('900000001'), throwsA(isA<OverlayBrokerException>().having((e) => e.signInAgain, 'signInAgain', isTrue)));
    // The machine plane reads no Authorization header at all, so its 401 means
    // the signature was refused and there is no sign-in to ask for again. It
    // is raised rather than swallowed: only the refusal this client makes for
    // itself, with no key at all, leaves the rest of the inbox to be read.
    wire.reply = {'error': 'That signature was refused.'};
    await expectLater(broker().inbox(), throwsA(isA<OverlayBrokerException>()
        .having((e) => e.message, 'message', 'That signature was refused.')
        .having((e) => e.signInAgain, 'signInAgain', isFalse)));
    wire.status = 409;
    wire.reply = {'error': 'That machine has not come up on labnet yet.'};
    await expectLater(broker().session('900000001'), throwsA(isA<OverlayBrokerException>()
        .having((e) => e.message, 'message', 'That machine has not come up on labnet yet.')
        .having((e) => e.signInAgain, 'signInAgain', isFalse)));
  });

  test('ending a session never throws', () async {
    wire.status = 500;
    wire.reply = 'not json';
    await broker().endSession('s1');
    expect(wire.calls.single.method, 'DELETE');
    expect(wire.calls.single.url, endsWith('/console/overlay/session/s1'));
  });

  test('the machine credential is read the way main_agent_sign writes it', () {
    expect(
        MachineSignature.decode('{"machine":"m-1","ts":"1788480000","sig":"AAA="}')?.headers,
        {'x-ld-machine': 'm-1', 'x-ld-ts': '1788480000', 'x-ld-sig': 'AAA='});
    // "" is what a process that cannot read the key answers, and a partial
    // answer is not a credential either.
    expect(MachineSignature.decode(''), isNull);
    expect(MachineSignature.decode('not json'), isNull);
    expect(MachineSignature.decode('{"machine":"m-1","ts":"1788480000"}'), isNull);
    expect(MachineSignature.decode('{"machine":"","ts":"1","sig":"AAA="}'), isNull);
  });
}
