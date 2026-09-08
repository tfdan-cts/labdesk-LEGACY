import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/labdesk/screens/alerts_screen.dart';
import 'package:flutter_hbb/labdesk/services/organization_context.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

Map<String, Object?> event(
        {String id = 'event-1', String org = 'org-a', int? acknowledgedAt}) =>
    {
      'id': id,
      'orgId': org,
      'machineId': 'machine-1',
      'at': 1788700000,
      'kind': 'offline',
      'severity': 'critical',
      'summary': 'Homebox is offline',
      'detail': null,
      'acknowledgedBy': acknowledgedAt == null ? null : 'user-a',
      'acknowledgedAt': acknowledgedAt,
    };

void main() {
  test('alerts read and acknowledgment use captured account and organization',
      () async {
    var token = 'token-a', org = 'org-a';
    var acknowledged = false;
    final requests = <String>[];
    final broker = OverlayBroker(
        baseUrl: 'https://example.test',
        token: () => token,
        organizationId: () => org,
        http: (method, url, headers, body) async {
          expect(headers['authorization'], 'Bearer token-a');
          expect(headers['x-labdesk-organization'], 'org-a');
          requests.add('$method ${url.path}');
          if (method == 'POST') {
            acknowledged = true;
            return (200, '{"ok":true}');
          }
          return (
            200,
            jsonEncode({
              'events': [
                event(acknowledgedAt: acknowledged ? 1788700200 : null)
              ]
            })
          );
        });
    final scoped = broker.captureScope();
    token = 'token-b';
    org = 'org-b';
    expect((await scoped.healthEvents()).single.summary, 'Homebox is offline');
    await scoped.acknowledgeHealthEvent('event-1');
    expect((await scoped.healthEvents()).single.acknowledgedAt,
        DateTime.fromMillisecondsSinceEpoch(1788700200000, isUtc: true));
    expect(requests, [
      'GET /console/org/events',
      'POST /console/org/events/event-1/ack',
      'GET /console/org/events'
    ]);
  });

  testWidgets(
      'operator reads and acknowledges alerts, reopens, then switches account',
      (tester) async {
    var token = 'token-a';
    var acknowledged = false;
    var writes = 0;
    late OrganizationContextController organization;
    final broker = OverlayBroker(
        baseUrl: 'https://example.test',
        token: () => token,
        organizationId: () => organization.activeId,
        http: (method, url, headers, body) async {
          final account =
              headers['authorization'] == 'Bearer token-a' ? 'a' : 'b';
          final org = 'org-$account';
          if (url.path == '/console/organizations') {
            return (
              200,
              jsonEncode({
                'userId': 'user-$account',
                'organizations': [
                  {
                    'orgId': org,
                    'name': 'Org $account',
                    'role': account == 'a' ? 'technician' : 'viewer'
                  }
                ]
              })
            );
          }
          expectSync(headers['x-labdesk-organization'], org);
          if (url.path == '/console/org') {
            return (
              200,
              jsonEncode({
                'orgId': org,
                'role': account == 'a' ? 'technician' : 'viewer'
              })
            );
          }
          if (method == 'GET' && url.path == '/console/org/events') {
            return (
              200,
              jsonEncode({
                'events': account == 'b'
                    ? []
                    : [event(acknowledgedAt: acknowledged ? 1788700200 : null)]
              })
            );
          }
          expectSync(account, 'a');
          expectSync('$method ${url.path}', 'POST /console/org/events/event-1/ack');
          writes++;
          acknowledged = true;
          return (200, '{"ok":true}');
        });
    organization = OrganizationContextController(
        broker: broker, readOption: (_) => '', writeOption: (_, __) async {});
    addTearDown(organization.dispose);
    await organization.syncCredential(token);
    Widget screen() => MaterialApp(
        theme: C.theme(),
        home: Scaffold(
            body: AlertsScreen(
                organization: organization,
                machineNames: const {'machine-1': 'Homebox'})));

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    expect(find.text('Homebox is offline'), findsOneWidget);
    await tester.tap(find.text('Acknowledge'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.textContaining('Acknowledged'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    expect(find.textContaining('Acknowledged'), findsOneWidget);

    token = 'token-b';
    await organization.syncCredential(token);
    await tester.pumpAndSettle();
    expect(find.text('Homebox is offline'), findsNothing);
    expect(find.text('No recent alerts.'), findsOneWidget);
    expect(find.text('Acknowledge'), findsNothing);
  });
}
