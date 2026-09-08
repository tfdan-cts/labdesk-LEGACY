import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/labnet.dart';
import 'package:flutter_hbb/labdesk/screens/network_screen.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';

const _message =
    'Network removal is still pending. Retry to check progress.';

OverlayBroker _broker({
  int status = 200,
  Map<String, dynamic> response = const {},
}) => OverlayBroker(
      baseUrl: 'https://lab-desk.test',
      token: () => 'test-token',
      sign: (_, __, ___) async => const MachineSignature(
          machine: 'this-machine', ts: '1', sig: 'test-signature'),
      http: (_, url, __, ___) async => url.path == '/agent/overlay/inbox'
          ? (200, jsonEncode({'device': {'enrolled': true}}))
          : (status, jsonEncode(response)),
    );

Map<String, dynamic> _labnets(String status, {String machineId = 'this-machine'}) => {
      'labnets': [
        {
          'id': 'L1',
          'name': 'Workshop',
          'fullAccess': false,
          'owner': true,
          'syncPending': true,
          'members': [
            {'machineId': machineId, 'deviceId': machineId, 'status': status},
          ],
        },
      ],
    };

Future<void> _pump(WidgetTester t, Widget child) async {
  await t.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  test('a pending leave is surfaced instead of completing successfully', () async {
    final broker = _broker(status: 202, response: {
      'ok': false,
      'status': 'leaving',
      'syncPending': true,
      'message': _message,
    });
    await expectLater(
      broker.leave('L1'),
      throwsA(isA<OverlayBrokerException>()
          .having((e) => e.status, 'status', 202)
          .having((e) => e.message, 'message', _message)
          .having((e) => e.machinePlane, 'machine plane', isTrue)),
    );
  });

  test('a pending owner removal is surfaced instead of completing successfully', () async {
    final broker = _broker(status: 202, response: {
      'ok': false,
      'status': 'removing',
      'syncPending': true,
      'message': _message,
    });
    await expectLater(
      broker.removeMember('L1', 'other-machine'),
      throwsA(isA<OverlayBrokerException>()
          .having((e) => e.status, 'status', 202)
          .having((e) => e.message, 'message', _message)
          .having((e) => e.machinePlane, 'machine plane', isFalse)),
    );
  });

  test('confirmed leave and owner removal still complete normally', () async {
    final broker = _broker(response: {'ok': true});
    await expectLater(broker.leave('L1'), completes);
    await expectLater(broker.removeMember('L1', 'other-machine'), completes);
  });

  test('pending responses without a message still explain the retry', () async {
    final broker = _broker(status: 202);
    for (final action in [() => broker.leave('L1'), () => broker.removeMember('L1', 'other')]) {
      await expectLater(action(), throwsA(isA<OverlayBrokerException>()
          .having((e) => e.status, 'status', 202)
          .having((e) => e.message, 'message', _message)
          .having((e) => e.signInAgain, 'sign-in retry', isFalse)));
    }
  });

  test('HTTP errors keep their message and authentication plane', () async {
    for (final status in [401, 403, 500]) {
      final broker = _broker(status: status, response: {'error': 'Service refused'});
      await expectLater(broker.leave('L1'), throwsA(isA<OverlayBrokerException>()
          .having((e) => e.status, 'status', status)
          .having((e) => e.message, 'message', 'Service refused')
          .having((e) => e.machinePlane, 'machine plane', isTrue)
          .having((e) => e.signInAgain, 'account sign-in', isFalse)));
      await expectLater(broker.removeMember('L1', 'other'), throwsA(isA<OverlayBrokerException>()
          .having((e) => e.status, 'status', status)
          .having((e) => e.message, 'message', 'Service refused')
          .having((e) => e.machinePlane, 'machine plane', isFalse)
          .having((e) => e.signInAgain, 'account sign-in', status == 401)));
    }
  });

  testWidgets('a leaving machine stays visible with an actionable retry', (t) async {
    final inbox = await _broker(response: _labnets('leaving')).inbox();
    String? retried;
    var expanded = false;
    var deleted = false;
    await _pump(t, NetworkScreen(
      inbox: inbox,
      thisMachineId: 'this-machine',
      onLeave: (id) => retried = id,
      onFullAccess: (_, __) => expanded = true,
      onDelete: (_) => deleted = true,
    ));

    expect(find.text('This machine'), findsOneWidget);
    expect(find.text('Removal pending'), findsOneWidget);
    expect(find.text('Waiting for approval on that machine'), findsNothing);
    expect(find.text('Network update pending. Access changes are not yet confirmed.'), findsOneWidget);
    await t.tap(find.text('Retry leave'));
    expect(retried, 'L1');
    await t.tap(find.text('Full access: off'));
    expect(expanded, isFalse);
    await t.tap(find.text('Delete labnet'));
    expect(deleted, isTrue, reason: 'Explicit network cleanup remains available.');
  });

  testWidgets('an owner can retry a removing member without an approval label', (t) async {
    final inbox = await _broker(response: _labnets('removing', machineId: 'other-machine')).inbox();
    (String, String)? retried;
    await _pump(t, NetworkScreen(
      inbox: inbox,
      thisMachineId: 'this-machine',
      onRemove: (labnet, machine) => retried = (labnet, machine),
    ));

    expect(find.text('other-machine'), findsOneWidget);
    expect(find.text('Removal pending'), findsOneWidget);
    expect(find.text('Waiting for approval on that machine'), findsNothing);
    await t.tap(find.text('Retry removal'));
    expect(retried, ('L1', 'other-machine'));
  });

  testWidgets('this machine can retry an owner-initiated removal through leave', (t) async {
    final inbox = await _broker(response: _labnets('removing')).inbox();
    String? retried;
    await _pump(t, NetworkScreen(
      inbox: inbox,
      thisMachineId: 'this-machine',
      onLeave: (id) => retried = id,
    ));

    expect(find.text('Removal pending'), findsOneWidget);
    await t.tap(find.text('Retry leave'));
    expect(retried, 'L1');
  });

  testWidgets('pending synchronization still permits reducing full access', (t) async {
    final response = _labnets('leaving');
    (response['labnets'] as List).single['fullAccess'] = true;
    final inbox = await _broker(response: response).inbox();
    (String, bool)? changed;
    await _pump(t, NetworkScreen(
      inbox: inbox,
      thisMachineId: 'this-machine',
      onFullAccess: (id, on) => changed = (id, on),
    ));

    await t.tap(find.text('Full access: on'));
    expect(changed, ('L1', false));
  });

  testWidgets('the server pending flag prevents expanding full access even before a removal row arrives', (t) async {
    final inbox = await _broker(response: _labnets('approved')).inbox();
    var expanded = false;
    await _pump(t, NetworkScreen(
      inbox: inbox,
      thisMachineId: 'this-machine',
      onFullAccess: (_, __) => expanded = true,
    ));

    expect(find.text('Network update pending. Access changes are not yet confirmed.'), findsOneWidget);
    await t.tap(find.text('Full access: off'));
    expect(expanded, isFalse);
  });

  testWidgets('JSON inbox pending state survives the pure model parser', (t) async {
    final inbox = LabnetInbox.fromJson(_labnets('approved'));
    var expanded = false;
    await _pump(t, NetworkScreen(
      inbox: inbox,
      thisMachineId: 'this-machine',
      onFullAccess: (_, __) => expanded = true,
    ));

    expect(find.text('Network update pending. Access changes are not yet confirmed.'), findsOneWidget);
    await t.tap(find.text('Full access: off'));
    expect(expanded, isFalse);
  });
}
