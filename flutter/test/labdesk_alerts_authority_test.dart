import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/screens/alerts_screen.dart';
import 'package:flutter_hbb/labdesk/services/organization_context.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

void main() {
  testWidgets('a forbidden acknowledgement immediately clears protected alerts',
      (tester) async {
    var writes = 0;
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
            'events': [{
              'id': 'event-a',
              'orgId': 'org-a',
              'machineId': 'machine-1',
              'at': 1788700000,
              'kind': 'offline',
              'severity': 'critical',
              'summary': 'Protected fixture alert',
              'detail': null,
              'acknowledgedBy': null,
              'acknowledgedAt': null,
            }],
          }));
        }
        expectSync('$method ${url.path}',
            'POST /console/org/events/event-a/ack');
        writes++;
        return (403, '{"error":"Fleet access changed."}');
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
    expect(find.text('Protected fixture alert'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Acknowledge'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.text('Fleet access changed.'), findsOneWidget);
    expect(find.text('Protected fixture alert'), findsNothing);
    expect(find.text('Acknowledge'), findsNothing);
    expect(organization.ready, isFalse);
  });
}
