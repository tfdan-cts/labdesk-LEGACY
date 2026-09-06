import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/screens/enrol_card.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

class _Organization {
  final calls = <String>[];
  final spent = <String>[];
  final fleets = <Map<String, String>>[];
  String role = 'owner';
  bool stale = false;
  bool refuseEnrolment = false;
  int refreshed = 0;
  int completed = 0;
  String organizationId = 'org-a';
  String credential = 'signed-in-account';
  final scopes = <String>[];
  Future<void> Function(String method, String path)? beforeReply;

  late final broker = OverlayBroker(
    baseUrl: 'https://lab-desk.net',
    token: () => credential,
    organizationId: () => organizationId,
    http: (method, url, headers, body) async {
      scopes.add(
          '${headers['authorization']}/${headers['x-labdesk-organization']}');
      calls.add('$method ${url.path}${body == null ? '' : ' $body'}');
      if (beforeReply != null) await beforeReply!(method, url.path);
      if (method == 'POST' && stale) {
        return (403, '{"error":"Sign in again to confirm this change."}');
      }
      if (url.path == '/console/org') return (200, jsonEncode({'role': role}));
      if (url.path == '/console/org/fleets' && method == 'GET') {
        return (200, jsonEncode({'fleets': fleets}));
      }
      if (url.path == '/console/org/fleets') {
        final fleet = {
          'id': 'new-fleet',
          'name': jsonDecode(body!)['name'] as String
        };
        fleets.add(fleet);
        return (200, jsonEncode(fleet));
      }
      if (url.path == '/console/org/enrol-token') {
        return (200, '{"token":"single-use-token"}');
      }
      throw StateError('Unexpected request: $method $url');
    },
  );

  Future<String> enrol(String token) async {
    spent.add(token);
    return refuseEnrolment
        ? '{"error":"The LabDesk service is not running."}'
        : '{"machineId":"this-machine"}';
  }

  Future<bool> signIn() async {
    refreshed++;
    stale = false;
    return true;
  }
}

Future<void> _show(WidgetTester t, _Organization org,
    {bool signedIn = true,
    String machineId = '',
    Future<void> Function()? checkService,
    Future<String> Function(String)? enrol,
    Future<OverlayBroker?> Function()? refreshBroker,
    Future<void> Function()? onEnrolled}) async {
  await t.pumpWidget(MaterialApp(
    theme: C.theme(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
            width: 600,
            child: MachineEnrolCard(
              broker: org.broker,
              signedIn: signedIn,
              machineId: machineId,
              checkService: checkService,
              signIn: org.signIn,
              refreshBroker: refreshBroker ??
                  () async {
                    await org.signIn();
                    return org.broker.captureScope();
                  },
              enrol: enrol ?? org.enrol,
              onEnrolled: onEnrolled ??
                  () async {
                    org.completed++;
                  },
            )),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
      'keyed sign-in remount never retries the captured signed-out broker',
      (t) async {
    var signedIn = false;
    var logins = 0;
    var reauths = 0;
    final broker = OverlayBroker(
      baseUrl: 'https://lab-desk.net',
      token: () => signedIn ? 'verified-account' : '',
      organizationId: () => signedIn ? 'org-a' : null,
      http: (method, url, headers, body) async {
        if (headers['authorization'] == 'Bearer ') {
          return (401, '{"error":"Sign in required."}');
        }
        if (url.path == '/console/org') return (200, '{"role":"owner"}');
        if (url.path == '/console/org/fleets') return (200, '{"fleets":[]}');
        throw StateError('Unexpected request: $method $url');
      },
    );
    await t.pumpWidget(MaterialApp(
      theme: C.theme(),
      home: Scaffold(body: StatefulBuilder(builder: (context, setParentState) {
        return SingleChildScrollView(
            child: MachineEnrolCard(
          key: ValueKey(signedIn),
          broker: broker.captureScope(),
          signedIn: signedIn,
          enrol: (_) async => throw StateError('Sign-in must not enroll'),
          signIn: () async {
            logins++;
            // A successful controller sync notifies the parent before its
            // Future returns. The next frame remounts this keyed card.
            setParentState(() => signedIn = true);
            return true;
          },
          refreshBroker: () async {
            reauths++;
            return broker.captureScope();
          },
        ));
      })),
    ));
    await t.tap(find.text('Sign in to add this machine'));
    await t.pumpAndSettle();
    expect(logins, 1);
    expect(reauths, 0);
    expect(find.byKey(const Key('enrol-fleet-name')), findsOneWidget);
  });

  testWidgets('organization change during service check cannot create a fleet',
      (t) async {
    final org = _Organization();
    final service = Completer<void>();
    await _show(t, org, checkService: () => service.future);
    await t.enterText(
        find.byKey(const Key('enrol-fleet-name')), 'Original lab');
    await t.pump();
    await t.tap(find.byKey(const Key('enrol-submit')));
    await t.pump();
    org.organizationId = 'org-b';
    service.complete();
    await t.pumpAndSettle();
    expect(org.calls.where((c) => c.startsWith('POST')), isEmpty);
    expect(org.spent, isEmpty);
  });

  testWidgets('disposed card cannot mutate after service check completes',
      (t) async {
    final org = _Organization();
    final service = Completer<void>();
    await _show(t, org, checkService: () => service.future);
    await t.enterText(
        find.byKey(const Key('enrol-fleet-name')), 'Original lab');
    await t.pump();
    await t.tap(find.byKey(const Key('enrol-submit')));
    await t.pump();
    await t.pumpWidget(const SizedBox.shrink());
    service.complete();
    await t.pumpAndSettle();
    expect(org.calls.where((c) => c.startsWith('POST')), isEmpty);
    expect(org.spent, isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets('cancelled identity verification cannot replay a stale mutation',
      (t) async {
    final org = _Organization()..stale = true;
    final refresh = Completer<OverlayBroker?>();
    await _show(t, org, refreshBroker: () => refresh.future);
    await t.enterText(
        find.byKey(const Key('enrol-fleet-name')), 'Original lab');
    await t.pump();
    await t.tap(find.byKey(const Key('enrol-submit')));
    await t.pump();
    org.credential = 'different-account';
    refresh.complete(null);
    await t.pumpAndSettle();
    expect(org.calls.where((c) => c.startsWith('POST')), hasLength(1));
    expect(org.fleets, isEmpty);
    expect(org.spent, isEmpty);
  });

  testWidgets('disposed card cannot replay after authentication returns',
      (t) async {
    final org = _Organization()..stale = true;
    final refresh = Completer<OverlayBroker?>();
    await _show(t, org, refreshBroker: () => refresh.future);
    await t.enterText(
        find.byKey(const Key('enrol-fleet-name')), 'Original lab');
    await t.pump();
    await t.tap(find.byKey(const Key('enrol-submit')));
    await t.pump();
    await t.pumpWidget(const SizedBox.shrink());
    org.stale = false;
    refresh.complete(org.broker);
    await t.pumpAndSettle();
    expect(org.calls.where((c) => c.startsWith('POST')), hasLength(1));
    expect(org.spent, isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets('verified same-context refresh pins the new bearer for the chain',
      (t) async {
    final org = _Organization()..stale = true;
    await _show(t, org, refreshBroker: () async {
      org.credential = 'fresh-same-account';
      org.stale = false;
      return org.broker.captureScope();
    });
    await t.enterText(
        find.byKey(const Key('enrol-fleet-name')), 'Original lab');
    await t.pump();
    await t.tap(find.byKey(const Key('enrol-submit')));
    await t.pumpAndSettle();
    expect(org.fleets, hasLength(1));
    expect(org.spent, ['single-use-token']);
    expect(org.scopes.skip(org.scopes.length - 2),
        everyElement('Bearer fresh-same-account/org-a'));
  });

  testWidgets(
      'different-organization refresh cannot replay the original action',
      (t) async {
    final org = _Organization()..stale = true;
    await _show(t, org, refreshBroker: () async {
      org.organizationId = 'org-b';
      org.stale = false;
      return org.broker.captureScope();
    });
    await t.enterText(
        find.byKey(const Key('enrol-fleet-name')), 'Original lab');
    await t.pump();
    await t.tap(find.byKey(const Key('enrol-submit')));
    await t.pumpAndSettle();
    expect(org.calls.where((c) => c.startsWith('POST')), hasLength(1));
    expect(org.fleets, isEmpty);
    expect(org.spent, isEmpty);
  });

  testWidgets('organization switch after token dispatch cannot enroll the host',
      (t) async {
    final token = Completer<void>();
    final org = _Organization()
      ..beforeReply = (method, path) async {
        if (path == '/console/org/enrol-token') await token.future;
      };
    await _show(t, org);
    await t.enterText(
        find.byKey(const Key('enrol-fleet-name')), 'Original lab');
    await t.pump();
    await t.tap(find.byKey(const Key('enrol-submit')));
    await t.pump();
    expect(org.calls.last, contains('/console/org/enrol-token'));
    org.organizationId = 'org-b';
    token.complete();
    await t.pumpAndSettle();
    expect(org.fleets, hasLength(1),
        reason: 'original fleet already committed');
    expect(org.spent, isEmpty);
    expect(org.scopes, everyElement('Bearer signed-in-account/org-a'));
  });

  testWidgets('missing privileged service blocks fleet and token creation',
      (t) async {
    final org = _Organization();
    await _show(t, org, checkService: () async {
      throw StateError('Install or repair the LabDesk service, then retry.');
    });
    await t.enterText(find.byKey(const Key('enrol-fleet-name')), 'Home lab');
    await t.pump();
    await t.tap(find.text('Create fleet and add this machine'));
    await t.pumpAndSettle();
    expect(org.calls.where((c) => c.startsWith('POST')), isEmpty);
    expect(org.spent, isEmpty);
    expect(find.textContaining('Install or repair the LabDesk service'),
        findsOneWidget);
  });

  testWidgets(
      'already-enrolled machine is shown without offering enrollment again',
      (t) async {
    final org = _Organization();
    await _show(t, org, machineId: 'previous-machine');
    expect(find.textContaining('previous-machine'), findsOneWidget);
    expect(find.text('Create fleet and add this machine'), findsNothing);
    expect(find.text('Use an enrolment token'), findsNothing);
    expect(org.calls, isEmpty);
  });

  testWidgets(
      'owner creates first fleet and adds this machine without copying a token',
      (t) async {
    final org = _Organization();
    await _show(t, org);
    await t.enterText(
        find.byKey(const Key('enrol-fleet-name')), '  Home lab  ');
    await t.pump();
    await t.tap(find.text('Create fleet and add this machine'));
    await t.pumpAndSettle();
    expect(org.calls.where((c) => c.startsWith('POST')), [
      'POST /console/org/fleets {"name":"Home lab"}',
      'POST /console/org/enrol-token {"fleetId":"new-fleet"}',
    ]);
    expect(org.spent, ['single-use-token']);
    expect(org.completed, 1);
    expect(find.textContaining('this-machine'), findsOneWidget);
    expect(find.text('single-use-token'), findsNothing);
    expect(find.text('Create fleet and add this machine'), findsNothing);
  });

  testWidgets('existing fleet is selected explicitly and passed to enrollment',
      (t) async {
    final org = _Organization()
      ..fleets.addAll([
        {'id': 'home', 'name': 'Home lab'},
        {'id': 'office', 'name': 'Office'},
      ]);
    await _show(t, org);
    await t.tap(find.byKey(const Key('enrol-fleet')));
    await t.pumpAndSettle();
    await t.tap(find.text('Office').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Add this machine'));
    await t.pumpAndSettle();
    expect(org.calls.where((c) => c.startsWith('POST')), [
      'POST /console/org/enrol-token {"fleetId":"office"}',
    ]);
    expect(org.spent, ['single-use-token']);
  });

  testWidgets('signed-out owner is asked to sign in before loading their fleet',
      (t) async {
    final org = _Organization();
    await _show(t, org, signedIn: false);
    expect(org.calls, isEmpty);
    await t.tap(find.text('Sign in to add this machine'));
    await t.pumpAndSettle();
    expect(org.refreshed, 1);
    expect(find.byKey(const Key('enrol-fleet-name')), findsOneWidget);
    expect(org.spent, isEmpty,
        reason: 'signing in is not machine enrollment consent');
  });

  testWidgets(
      'technician is directed to owner token without attempting privileged mint',
      (t) async {
    final org = _Organization()..role = 'technician';
    await _show(t, org);
    expect(find.textContaining('organization owner'), findsOneWidget);
    expect(find.text('Add this machine'), findsNothing);
    expect(org.calls.where((c) => c.startsWith('POST')), isEmpty);
    await t.tap(find.text('Use an enrolment token'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('enrol-token')), 'owner-token');
    await t.tap(find.text('Enrol'));
    await t.pumpAndSettle();
    expect(org.spent, ['owner-token']);
    expect(org.completed, 1);
  });

  testWidgets(
      'stale owner signs in again once then continues same fleet action',
      (t) async {
    final org = _Organization()..stale = true;
    await _show(t, org);
    await t.enterText(find.byKey(const Key('enrol-fleet-name')), 'Home lab');
    await t.pump();
    await t.tap(find.text('Create fleet and add this machine'));
    await t.pumpAndSettle();
    expect(org.refreshed, 1);
    expect(org.fleets, hasLength(1));
    expect(org.spent, ['single-use-token']);
  });

  testWidgets('failed service enrollment keeps created fleet for retry',
      (t) async {
    final org = _Organization()..refuseEnrolment = true;
    await _show(t, org);
    await t.enterText(find.byKey(const Key('enrol-fleet-name')), 'Home lab');
    await t.pump();
    await t.tap(find.text('Create fleet and add this machine'));
    await t.pumpAndSettle();
    expect(find.text('The LabDesk service is not running.'), findsOneWidget);
    expect(org.completed, 0);
    org.refuseEnrolment = false;
    await t.tap(find.text('Add this machine'));
    await t.pumpAndSettle();
    expect(org.calls.where((c) => c.startsWith('POST /console/org/fleets')),
        hasLength(1));
    expect(org.completed, 1);
  });

  testWidgets('pending privileged enrollment cannot spend another token',
      (t) async {
    final org = _Organization()..fleets.add({'id': 'home', 'name': 'Home lab'});
    final answer = Completer<String>();
    await _show(t, org, enrol: (token) {
      org.spent.add(token);
      return answer.future;
    });
    await t.tap(find.byKey(const Key('enrol-fleet')));
    await t.pumpAndSettle();
    await t.tap(find.text('Home lab').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Add this machine'));
    await t.pump();
    await t.tap(find.byKey(const Key('enrol-submit')));
    await t.pump();
    expect(org.spent, hasLength(1));
    answer.complete('{"machineId":"this-machine"}');
    await t.pumpAndSettle();
    expect(org.completed, 1);
  });

  testWidgets(
      'labnet follow-up failure preserves successful machine enrollment',
      (t) async {
    final org = _Organization();
    await _show(t, org, onEnrolled: () async {
      throw StateError('Relay unavailable');
    });
    await t.enterText(find.byKey(const Key('enrol-fleet-name')), 'Home lab');
    await t.pump();
    await t.tap(find.text('Create fleet and add this machine'));
    await t.pumpAndSettle();
    expect(find.textContaining('this-machine'), findsOneWidget);
    expect(find.textContaining('Relay unavailable'), findsOneWidget);
    expect(find.text('Add this machine'), findsNothing);
  });
}
