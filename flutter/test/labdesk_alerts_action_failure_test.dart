import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/screens/alerts_screen.dart';
import 'package:flutter_hbb/labdesk/services/organization_context.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

// Local HTTP fixture only; this test never contacts a service or peer.
void main() {
  testWidgets('later acknowledgement failure survives an older unverified action',
      (tester) async {
    final writes = <String>[];
    late OrganizationContextController organization;
    final broker = OverlayBroker(
      baseUrl: 'https://example.test',
      token: () => 'account-a',
      organizationId: () => organization.activeId,
      http: (method, url, headers, body) async {
        expectSync(headers['authorization'], 'Bearer account-a');
        if (url.path == '/console/organizations') {
          return (200, jsonEncode({
            'userId': 'user-a',
            'organizations': [
              {'orgId': 'org-a', 'name': 'Fixture organization', 'role': 'owner'}
            ],
          }));
        }
        expectSync(headers['x-labdesk-organization'], 'org-a');
        if (url.path == '/console/org') {
          return (200, '{"orgId":"org-a","role":"owner"}');
        }
        if (method == 'GET' && url.path == '/console/org/events') {
          return (200, jsonEncode({
            'events': [
              for (final id in ['event-a', 'event-b'])
                {
                  'id': id,
                  'orgId': 'org-a',
                  'machineId': 'machine-1',
                  'at': 1788700000,
                  'kind': 'offline',
                  'severity': 'critical',
                  'summary': 'Fixture alert $id',
                  'detail': null,
                  'acknowledgedBy': null,
                  'acknowledgedAt': null,
                }
            ],
          }));
        }
        expectSync(method, 'POST');
        writes.add(url.path);
        if (url.path == '/console/org/events/event-a/ack') {
          return (200, '{"ok":true}');
        }
        expectSync(url.path, '/console/org/events/event-b/ack');
        return (500, '{"error":"Event B acknowledgement failed."}');
      },
    );
    organization = OrganizationContextController(
        broker: broker, readOption: (_) => '', writeOption: (_, __) async {});
    addTearDown(organization.dispose);
    await organization.syncCredential('account-a');
    await tester.pumpWidget(MaterialApp(
      theme: C.theme(),
      home: Scaffold(body: AlertsScreen(organization: organization)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Acknowledge').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('saved acknowledgment is not confirmed'),
        findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Acknowledge').last);
    await tester.pumpAndSettle();
    expect(writes, [
      '/console/org/events/event-a/ack',
      '/console/org/events/event-b/ack',
    ]);
    expect(find.text('Event B acknowledgement failed.'), findsOneWidget);
    expect(find.textContaining('Acknowledged '), findsNothing);
  });
}
