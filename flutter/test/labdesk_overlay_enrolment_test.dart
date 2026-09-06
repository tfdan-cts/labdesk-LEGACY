import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';
import 'package:flutter_hbb/labdesk/services/overlay_daemon.dart';
import 'package:flutter_hbb/labdesk/services/overlay_enrolment.dart';

/// The enrolment sequence, with the privileged process behind the daemon and
/// the broker both faked, so the order of what it does is what is under test.
const _connected = '{"daemonStatus":"Connected","netbirdIp":"100.64.0.3/16","publicKey":"wg=","management":{"connected":true,"error":""},"signal":{"connected":true,"error":""},"peers":{"details":[]}}';
const _connecting = '{"daemonStatus":"Connecting","netbirdIp":"","management":{"connected":false,"error":"dial tcp: no route"},"signal":{"connected":false,"error":""}}';

/// What `main_overlay_daemon` answers for one action.
String _out(String s) => jsonEncode({'output': s});
String _err(String s) => jsonEncode({'error': s});

class _World {
  final log = <String>[];
  final statuses = <String>[];
  String daemonReply = _out('');
  int brokerStatus = 200;
  Map<String, Object?> brokerReply = {'setupKey': 'SK', 'managementUrl': 'https://nb.lab-desk.net', 'ok': true};
  final options = <String, String>{};

  /// What each daemon action was handed, so the setup key and the control
  /// plane can be read back.
  final daemonArgs = <String, (String, String)>{};

  /// The body of the last POST to /agent/overlay/self, so what this machine told
  /// lab-desk.net about itself can be read back.
  String? selfBody;

  Future<String> call(String action, String setupKey, String managementUrl) async {
    log.add('daemon $action');
    daemonArgs[action] = (setupKey, managementUrl);
    if (action == 'status') return statuses.isEmpty ? daemonReply : statuses.removeAt(0);
    return daemonReply;
  }

  Future<(int, String)> http(String method, Uri url, Map<String, String> h, String? body) async {
    log.add('broker $method ${url.path}');
    if (url.path == '/agent/overlay/self') selfBody = body;
    return (brokerStatus, '{"setupKey":"SK","managementUrl":"https://nb.lab-desk.net","ok":true}');
  }

  Future<void> setOption(String k, String v) async {
    log.add('option $k=$v');
    options[k] = v;
  }

  OverlayEnrolment enrolment() => OverlayEnrolment(
        daemon: OverlayDaemon(call: call),
        // The enrolment sequence speaks the machine plane, so the broker is
        // given a machine credential; the signature itself is the Rust
        // core's (src/flutter_ffi.rs), and what it covers is asserted in
        // labdesk_overlay_broker_test.dart.
        broker: OverlayBroker(
            baseUrl: 'https://lab-desk.net',
            token: () => 't',
            sign: (m, p, b) async =>
                const MachineSignature(machine: 'm-1', ts: '1788480000', sig: 'sig='),
            http: http),
        setOption: setOption,
        // What the client reads back for this machine. Not the default for
        // anything: there is no default, and these values reaching the broker
        // unchanged is what the identity callback exists to make happen.
        identity: () async => ('idpk=', 21119),
        sleep: (_) async {},
        connectTimeout: const Duration(seconds: 2),
      );
}

void main() {
  test('the consent prompt is due once, only while signed in and not enrolled', () {
    expect(shouldAskLabnetConsent(signedIn: true, consentAsked: false, enrolled: false), isTrue);
    expect(shouldAskLabnetConsent(signedIn: false, consentAsked: false, enrolled: false), isFalse);
    expect(shouldAskLabnetConsent(signedIn: true, consentAsked: true, enrolled: false), isFalse);
    expect(shouldAskLabnetConsent(signedIn: true, consentAsked: false, enrolled: true), isFalse);
  });

  test('the overlay address loses its prefix length before it is used', () {
    expect(bareIp('100.64.0.3/16'), '100.64.0.3');
    expect(bareIp('100.64.0.3'), '100.64.0.3');
  });

  test('a fresh machine installs, enrols, joins, waits for Connected, reports, then opens the direct listener on that address',
      () async {
    final w = _World()
      ..statuses.addAll([
        _err('failed to connect to daemon error: x'),
        _out(_connecting),
        _out(_connected),
      ]);
    final e = w.enrolment();
    final end = await e.enable();
    expect(end.phase, LabnetPhase.on, reason: end.detail);
    expect(end.ip, '100.64.0.3');
    expect(w.log, [
      'daemon status',
      'broker POST /agent/overlay/enrol',
      'daemon install',
      'daemon start',
      'daemon up',
      'daemon status',
      'daemon status',
      'broker POST /agent/overlay/self',
      'option labdesk-direct-bind=100.64.0.3',
      'option direct-server=Y',
    ]);
    // The service is fixed to the control plane lab-desk.net named, and the
    // key it answered reaches up and nothing else. No prompt anywhere: the
    // privileged process does the installing.
    expect(w.daemonArgs['install'], ('', 'https://nb.lab-desk.net'));
    expect(w.daemonArgs['up'], ('SK', 'https://nb.lab-desk.net'));
    expect(w.daemonArgs['start'], ('', ''));
  });

  test('a service the privileged process cannot install ends in its own words, before anything joins', () async {
    final w = _World()..daemonReply = _err('failed to connect to daemon error: x');
    final end = await w.enrolment().enable();
    expect(end.phase, LabnetPhase.error);
    expect(end.detail, 'failed to connect to daemon error: x');
    expect(w.log, ['daemon status', 'broker POST /agent/overlay/enrol', 'daemon install']);
    expect(w.options, isEmpty);
  });

  test('a daemon that never connects ends in error with the management error it reported', () async {
    final w = _World()..daemonReply = _out(_connecting);
    final end = await w.enrolment().enable();
    expect(end.phase, LabnetPhase.error);
    expect(end.detail, 'dial tcp: no route');
    expect(w.options, isEmpty, reason: 'nothing opens until the overlay is up');
  });

  test('a refused enrolment shows the server\'s sentence and touches nothing', () async {
    final w = _World()
      ..daemonReply = _err('failed to connect to daemon error: x')
      ..brokerStatus = 503;
    final end = await w.enrolment().enable();
    expect(end.phase, LabnetPhase.error);
    expect(end.detail, contains('503'));
    expect(w.log.where((l) => l.startsWith('daemon')), ['daemon status']);
    expect(w.options, isEmpty);
  });

  test('a machine whose daemon is already up only re-registers', () async {
    final w = _World()..daemonReply = _out(_connected);
    final end = await w.enrolment().enable();
    expect(end.phase, LabnetPhase.on);
    expect(w.log, ['daemon status', 'broker POST /agent/overlay/self', 'option labdesk-direct-bind=100.64.0.3', 'option direct-server=Y']);
  });

  test('the machine reports the id key and the direct port the client read, not a placeholder', () async {
    final w = _World()..daemonReply = _out(_connected);
    final end = await w.enrolment().enable();
    expect(end.phase, LabnetPhase.on, reason: end.detail);
    expect(jsonDecode(w.selfBody!), {
      'overlayIp': '100.64.0.3',
      'publicKey': 'wg=',
      'idPk': 'idpk=',
      'directPort': 21119,
    });
  });

  test('disable closes the direct listener first, then takes the daemon down and revokes', () async {
    final w = _World();
    final end = await w.enrolment().disable();
    expect(end.phase, LabnetPhase.off);
    expect(w.log, ['option direct-server=N', 'option labdesk-direct-bind=', 'daemon down', 'broker DELETE /agent/overlay/enrol']);
    expect(w.options, {'direct-server': 'N', 'labdesk-direct-bind': ''});
  });

  test('states are streamed as the sequence advances', () async {
    final w = _World()..daemonReply = _out(_connected);
    final e = w.enrolment();
    final seen = <LabnetPhase>[];
    final sub = e.states.listen((s) => seen.add(s.phase));
    await e.enable();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen.first, LabnetPhase.working);
    expect(seen.last, LabnetPhase.on);
  });
}
