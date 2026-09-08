import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/labnet.dart';
import 'package:flutter_hbb/labdesk/screens/labnet_sharing_controls.dart';
import 'package:flutter_hbb/labdesk/screens/network_screen.dart';
import 'package:flutter_hbb/labdesk/services/organization_context.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';
import 'package:flutter_hbb/labdesk/services/overlay_daemon.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

class SharingHarness {
  SharingHarness({this.guest = false}) {
    broker = OverlayBroker(
        baseUrl: 'https://example.test',
        token: () => token,
        organizationId: () => organization.activeId,
        sign: (_, __, ___) async => const MachineSignature(machine: 'machine-a', ts: '1', sig: 'test'),
        http: (method, url, headers, body) async {
          if (method == 'GET' && url.path == '/agent/overlay/routing') {
            if (hostingError != null) return (403, jsonEncode({'error': hostingError}));
            return (200, jsonEncode({'machineId': hostingMachineId,
              'hostedExits': exits.where((offer) => offer['machineId'] == 'machine-a')
                  .map((offer) => Map<String, dynamic>.from(offer)..remove('machineId')).toList(),
              'hostedSubnets': subnets.where((offer) => offer['machineId'] == 'machine-a')
                  .map((offer) => Map<String, dynamic>.from(offer)..remove('machineId')).toList()}));
          }
          if (url.path == '/console/organizations')
            return (
              200,
              jsonEncode({
                'userId': 'user-$token',
                'organizations': guest
                    ? []
                    : [
                        {'orgId': 'org-a', 'name': 'A', 'role': 'owner'},
                        {'orgId': 'org-b', 'name': 'B', 'role': 'owner'}
                      ]
              })
            );
          if (url.path == '/console/org')
            return (
              200,
              jsonEncode(
                  {'orgId': headers['x-labdesk-organization'], 'role': 'owner'})
            );
          if (method != 'GET') {
            writes.add((
              path: url.path,
              method: method,
              headers: headers,
              body:
                  body == null ? null : jsonDecode(body) as Map<String, dynamic>
            ));
            if (mutation != null) return mutation!.future;
            if (url.path.endsWith('/invitations'))
              return (
                201,
                '{"id":"invite-new","url":"https://example.test/s/i/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","delivery":"link"}'
              );
            if (url.path.endsWith('/routing')) {
              final input = jsonDecode(body!) as Map<String, dynamic>;
              preference = {
                ...preference,
                'revision': 3,
                'exitId': input['exitId'],
                'status': 'pending'
              };
            }
            return (200, '{"ok":true}');
          }
          if (url.path == '/console/shared-labnets')
            return (
              200,
              jsonEncode({
                'labnets': [
                  {
                    'id': 'access-a',
                    'name': 'Guest network',
                    'labnetId': 'guest-net',
                    'capabilities': []
                  }
                ]
              })
            );
          if (url.path.endsWith('/invitations'))
            return (200, jsonEncode({'invitations': invitations, 'users': []}));
          if (url.path.endsWith('/exits'))
            return (
              200,
              jsonEncode({'exits': exits, 'capabilities': {'exitLan': true, 'subnetSharing': true}})
            );
          if (url.path.endsWith('/subnets')) return (200, jsonEncode({'subnets': subnets}));
          if (url.path.endsWith('/routing'))
            return (
              200,
              jsonEncode({
                'preference': preference,
                'capabilities': capabilities,
                'exits': [
                  {
                    'id': 'exit-a',
                    'machineId': 'source',
                    'machineName': 'Gateway',
                    'reachable': false
                  }
                ]
              })
            );
          return (404, '{"error":"Unexpected request"}');
        });
    organization = OrganizationContextController(
        broker: broker,
        readOption: (_) => 'org-a',
        writeOption: (_, __) async {});
  }
  final bool guest;
  String token = 'token-a';
  late final OverlayBroker broker;
  late final OrganizationContextController organization;
  Completer<(int, String)>? mutation;
  List<Map<String, dynamic>> invitations = [];
  List<Map<String, dynamic>> exits = [], subnets = [];
  OverlayDaemon? daemon;
  String localMachineId = '';
  bool localEnrolled = false;
  String hostingMachineId = 'machine-a';
  String? hostingError;
  final writes = <({
    String path,
    String method,
    Map<String, String> headers,
    Map<String, dynamic>? body
  })>[];
  Map<String, dynamic> capabilities = {};
  Map<String, dynamic> preference = {
    'exitId': null,
    'revision': 2,
    'ackRevision': 2,
    'appliedExitId': null,
    'status': 'direct',
    'stateFresh': true,
    'allowLocalLan': true,
    'reportedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  };

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(organization.dispose);
    await organization.syncCredential(token);
    await tester.pumpWidget(MaterialApp(
        theme: C.theme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: LabnetSharingControls(
                    organization: organization,
                    daemon: daemon,
                    localMachineId: localMachineId,
                    localEnrolled: localEnrolled,
                    canManageMachines: true,
                    machines: const [
              NetworkMachine(id: 'machine-a', name: 'Workstation')
            ],
                    labnets: const [
              Labnet(
                  id: 'labnet-a',
                  name: 'Production',
                  owner: true,
                  fullAccess: false,
                  members: [
                    LabnetMember(deviceId: 'machine-a', status: 'approved')
                  ])
            ])))));
    await tester.pumpAndSettle();
  }
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

List<({String action, Map<String, dynamic>? body})> hostFixture(
    SharingHarness harness, {bool supported = true, String? error}) {
  final calls = <({String action, Map<String, dynamic>? body})>[];
  harness.localMachineId = 'machine-a';
  harness.localEnrolled = true;
  harness.exits = [
    {'id': 'host-exit', 'machineId': 'machine-a', 'labnetName': 'Other organization network',
      'status': 'pending', 'allowExitLan': false},
    {'id': 'remote-exit', 'machineId': 'other-machine', 'status': 'pending', 'allowExitLan': false},
  ];
  harness.subnets = [{'id': 'host-subnet', 'machineId': 'machine-a', 'labnetName': 'Other organization network', 'name': 'Office LAN',
    'cidr': '192.168.20.0/24', 'status': 'pending'}];
  harness.daemon = OverlayDaemon(call: (action, payload, managementUrl) async {
    calls.add((action: action, body: payload.isEmpty ? null : jsonDecode(payload) as Map<String, dynamic>));
    expect(managementUrl, isEmpty);
    if (action == 'exit-consent' || action == 'subnet-consent') {
      return jsonEncode(error == null ? {'output': '{}'} : {'error': error});
    }
    return jsonEncode({'output': jsonEncode({'status': 'direct', 'revision': 2,
      'hostingSupported': supported, 'exitLanSupported': supported,
      'subnetSharingSupported': supported})});
  });
  return calls;
}

void main() {
  test('signed inbox canonical identity survives removal reconciliation; old responses have no fallback', () {
    final inbox = LabnetInbox.fromJson({'device': {'enrolled': true, 'machineId': 'canonical-local'},
      'labnets': [{'id': 'net', 'name': 'Network', 'members': [
        {'deviceId': 'canonical-local', 'machineName': 'Workstation', 'status': 'approved'}]}]});
    final reconciled = inbox.withRemovalResults({('net', 'canonical-local'): 'leaving'});
    expect(reconciled.machineId, 'canonical-local');
    expect(reconciled.labnets.single.members.single.machineName, 'Workstation');
    expect(LabnetInbox.fromJson({'device': {'enrolled': true}}).machineId, isNull);
  });

  testWidgets('host accepts only its local offers through typed bridge and waits for real state', (tester) async {
    final harness = SharingHarness();
    final calls = hostFixture(harness);
    await harness.mount(tester);
    expect(find.byKey(const ValueKey('accept-host-exit-remote-exit')), findsNothing);
    await tap(tester, find.byKey(const ValueKey('accept-host-exit-host-exit')));
    await tap(tester, find.widgetWithText(FilledButton, 'Accept exit offer'));
    final consent = calls.where((call) => call.action == 'exit-consent').single;
    expect(consent.body, {'offerId': 'host-exit', 'accept': true});
    expect(calls.any((call) => call.action == 'routing-sync'), isTrue);
    expect(harness.writes, isEmpty);
    expect(find.textContaining('Decision submitted; waiting for offer state'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('accept-host-exit-host-exit'))).onPressed, isNull);
    await tap(tester, find.byKey(const ValueKey('accept-host-subnet-host-subnet')));
    await tap(tester, find.widgetWithText(FilledButton, 'Accept subnet offer'));
    expect(calls.where((call) => call.action == 'subnet-consent').single.body,
      {'offerId': 'host-subnet', 'accept': true});
    expect(find.text('Exit selection acknowledged by machine'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unsupported host can decline; a service rejection remains visible', (tester) async {
    final harness = SharingHarness();
    final calls = hostFixture(harness, supported: false, error: 'The local service refused this offer.');
    await harness.mount(tester);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('accept-host-exit-host-exit'))).onPressed, isNull);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('accept-host-subnet-host-subnet'))).onPressed, isNull);
    await tap(tester, find.byKey(const ValueKey('decline-host-subnet-host-subnet')));
    await tap(tester, find.widgetWithText(FilledButton, 'Decline subnet offer'));
    expect(calls.where((call) => call.action == 'subnet-consent').single.body,
      {'offerId': 'host-subnet', 'accept': false});
    expect(find.text('The local service refused this offer.'), findsOneWidget);
    expect(harness.organization.ready, isTrue);
    expect(calls.any((call) => call.action == 'routing-sync'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('missing local identity cannot consent or fall back to selected machine', (tester) async {
    final harness = SharingHarness();
    final calls = hostFixture(harness);
    harness.localMachineId = '';
    await harness.mount(tester);
    expect(find.textContaining('Hosting decisions require verified local enrollment'), findsOneWidget);
    expect(find.byKey(const ValueKey('accept-host-exit-host-exit')), findsNothing);
    expect(calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('own signed hosting offers work without an organization selection', (tester) async {
    final harness = SharingHarness(guest: true);
    final calls = hostFixture(harness);
    await harness.mount(tester);
    expect(harness.organization.ready, isFalse);
    expect(find.text('Internet exit for Other organization network'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('decline-host-exit-host-exit')));
    await tap(tester, find.widgetWithText(FilledButton, 'Decline exit offer'));
    expect(calls.where((call) => call.action == 'exit-consent').single.body,
      {'offerId': 'host-exit', 'accept': false});
    expect(harness.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('own hosting read failure does not disable organization invitations', (tester) async {
    final harness = SharingHarness();
    final calls = hostFixture(harness);
    harness.hostingError = 'The local machine credential was refused.';
    await harness.mount(tester);
    expect(find.text('The local machine credential was refused.'), findsOneWidget);
    expect(harness.organization.ready, isTrue);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('create-labnet-invitation'))).onPressed, isNotNull);
    expect(find.byKey(const ValueKey('accept-host-exit-host-exit')), findsNothing);
    expect(calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mismatched signed hosting identity cannot approve', (tester) async {
    final harness = SharingHarness();
    final calls = hostFixture(harness);
    harness.hostingMachineId = 'different-machine';
    await harness.mount(tester);
    expect(find.text('Local hosting offers could not be verified. Refresh before deciding.'), findsOneWidget);
    expect(find.byKey(const ValueKey('accept-host-exit-host-exit')), findsNothing);
    expect(calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('context change while confirming cannot submit stale host approval', (tester) async {
    final harness = SharingHarness();
    final calls = hostFixture(harness);
    await harness.mount(tester);
    await tap(tester, find.byKey(const ValueKey('accept-host-exit-host-exit')));
    await harness.organization.select('org-b');
    await tester.pumpAndSettle();
    await tap(tester, find.widgetWithText(FilledButton, 'Accept exit offer'));
    expect(calls.any((call) => call.action == 'exit-consent'), isFalse);
    expect(harness.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  test(
      'invitation URLs stay HTTPS, same-origin, and on explicit acceptance paths',
      () {
    const origin = 'https://example.test';
    const token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    expect(verifiedLabnetInvitation('$origin/s/i/$token', origin), isNotNull);
    expect(
        verifiedLabnetInvitation(
            '$origin/accept-labnet-invitation#$token', origin),
        isNotNull);
    for (final value in [
      'http://example.test/s/i/abc',
      'https://evil.test/s/i/abc',
      '$origin/s/i/abc?next=bad',
      '$origin/console',
      'https://user@example.test/s/i/abc',
      '$origin/s/i/abc#token=abc',
      '$origin/accept-labnet-invitation#token=$token',
      '$origin/accept-labnet-invitation#token=abc&next=bad'
    ]) {
      expect(verifiedLabnetInvitation(value, origin), isNull, reason: value);
    }
  });

  test('only fresh matching signed routing acknowledgement is confirmed', () {
    final now = DateTime.utc(2026, 9, 8);
    final preference = <String, dynamic>{
      'revision': 4,
      'ackRevision': 4,
      'exitId': 'exit-a',
      'appliedExitId': 'exit-a',
      'status': 'selected',
      'stateFresh': true,
      'reportedAt': now.millisecondsSinceEpoch ~/ 1000
    };
    expect(routingAcknowledgement(preference, now),
        'Exit selection acknowledged by machine');
    expect(routingAcknowledgement({...preference, 'ackRevision': 3}, now),
        'Pending machine acknowledgement');
    expect(
        routingAcknowledgement(
            preference, now.add(const Duration(seconds: 46))),
        'Routing report stale or unavailable');
    expect(
        routingReportFresh(
            preference, now.subtract(const Duration(seconds: 1))),
        isFalse);
    expect(routingAcknowledgement({...preference, 'appliedExitId': null}, now),
        isNot(contains('acknowledged')));
    expect(routingAcknowledgement({}, now), isNot(contains('acknowledged')));
  });

  testWidgets(
      'account-only guest discovery does not require organization or local enrollment',
      (tester) async {
    final harness = SharingHarness(guest: true);
    await harness.mount(tester);
    expect(find.text('Guest network'), findsOneWidget);
    expect(find.text('Machine routing'), findsNothing);
    expect(find.text('Create invitation'), findsNothing);
    await tap(tester, find.text('Leave shared Labnet'));
    await tap(tester, find.widgetWithText(FilledButton, 'Leave shared Labnet'));
    expect(harness.writes.single.path, '/console/shared-labnets/access-a');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'unknown routing capabilities disable controls; invitation grants preserve dependencies',
      (tester) async {
    final harness = SharingHarness();
    await harness.mount(tester);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('apply-machine-routing')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(
                FilledButton, 'Offer selected machine as exit'))
            .onPressed,
        isNull);
    await tap(tester, find.widgetWithText(FilterChip, 'Control screen'));
    await tap(tester, find.byKey(const ValueKey('create-labnet-invitation')));
    final write = harness.writes.single;
    expect(write.headers['x-labdesk-organization'], 'org-a');
    expect(write.body!['capabilities'], containsAll(['view', 'control']));
    expect(write.body!['kind'], 'person');
    expect(
        find.text(
            'https://example.test/s/i/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
        findsOneWidget);
    expect(harness.writes.any((write) => write.path.startsWith('/agent')),
        isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('context switch hides a delayed invitation secret',
      (tester) async {
    final harness = SharingHarness();
    await harness.mount(tester);
    harness.mutation = Completer<(int, String)>();
    await tap(tester, find.byKey(const ValueKey('create-labnet-invitation')));
    await harness.organization.select('org-b');
    await tester.pumpAndSettle();
    harness.mutation!.complete((
      201,
      '{"id":"late","url":"https://example.test/s/i/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
        findsNothing);
    expect(harness.writes.single.headers['x-labdesk-organization'], 'org-a');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'revoked invitation 403 hides secret without invalidating organization',
      (tester) async {
    final harness = SharingHarness();
    await harness.mount(tester);
    await tap(tester, find.byKey(const ValueKey('create-labnet-invitation')));
    expect(
        find.text(
            'https://example.test/s/i/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
        findsOneWidget);
    harness.invitations = [
      {
        'id': 'invite-new',
        'kind': 'person',
        'status': 'pending',
        'expiresAt': '2026-09-10T00:00:00Z',
        'revokedAt': null
      }
    ];
    await tap(tester, find.text('Refresh sharing and routing'));
    harness.mutation = Completer<(int, String)>()
      ..complete(
          (403, '{"error":"This invitation can no longer be managed."}'));
    await tap(tester, find.text('Revoke invitation'));
    await tap(tester, find.widgetWithText(FilledButton, 'Revoke invitation'));
    expect(harness.organization.ready, isTrue);
    expect(harness.organization.activeId, 'org-a');
    expect(
        find.text(
            'https://example.test/s/i/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
        findsNothing);
    expect(
        find.text('This invitation can no longer be managed.'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('create-labnet-invitation')))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'routing save uses canonical machine and revision but never fabricates acknowledgement',
      (tester) async {
    final harness = SharingHarness();
    harness.capabilities = {
      'selection': true,
      'clientLocalLan': true,
      'exitLan': true
    };
    await harness.mount(tester);
    await tap(
        tester,
        find.widgetWithText(
            DropdownButtonFormField<String>, 'Internet connection'));
    await tap(tester, find.text('Gateway · unreachable').last);
    await tap(tester, find.byKey(const ValueKey('apply-machine-routing')));
    expect(harness.writes.single.path,
        '/console/overlay/machines/machine-a/routing');
    expect(harness.writes.single.body,
        {'exitId': 'exit-a', 'revision': 2, 'allowLocalLan': true});
    expect(find.text('Pending machine acknowledgement'), findsOneWidget);
    expect(find.text('Exit selection acknowledged by machine'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
