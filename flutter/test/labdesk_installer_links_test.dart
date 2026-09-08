import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/screens/installer_links_screen.dart';
import 'package:flutter_hbb/labdesk/services/organization_context.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

class InstallerHarness {
  InstallerHarness() {
    final broker = OverlayBroker(
        baseUrl: 'https://example.test',
        token: () => 'token',
        organizationId: () => organization.activeId,
        http: (method, url, headers, body) async {
          if (url.path == '/console/organizations')
            return (
              200,
              jsonEncode({
                'userId': 'user',
                'organizations': [
                  {'orgId': 'org-a', 'name': 'A', 'role': 'viewer'},
                  {'orgId': 'org-b', 'name': 'B', 'role': 'viewer'}
                ]
              })
            );
          if (url.path == '/console/org')
            return (
              200,
              jsonEncode({
                'orgId': headers['x-labdesk-organization'],
                'role': 'viewer'
              })
            );
          if (url.path == '/console/org/fleets')
            return (200, jsonEncode({'fleets': fleets}));
          if (method == 'GET' && url.path == '/console/download-links') {
            if (denied)
              return (403, '{"error":"Sharing installers is not permitted."}');
            return (200, jsonEncode({'links': links, 'platforms': platforms}));
          }
          writes.add((
            method: method,
            path: url.path,
            organization: headers['x-labdesk-organization'],
            body: body == null ? null : jsonDecode(body) as Map<String, dynamic>
          ));
          if (method == 'DELETE') {
            links = links
                .map((link) => {
                      ...link,
                      'revokedAt': DateTime.now().toUtc().toIso8601String()
                    })
                .toList();
            return (200, '{"ok":true}');
          }
          if (create != null) return create!();
          final result = generated();
          links = [
            {
              ...result,
              'url': 'must-not-recover-history-secret',
              'fleetId': 'fleet-b',
              'createdBy': 'user',
              'revokedAt': null
            }
          ];
          return (201, jsonEncode(result));
        });
    organization = OrganizationContextController(
        broker: broker,
        readOption: (_) => 'org-a',
        writeOption: (_, __) async {});
  }

  static const secret = 'https://example.test/s/d/creation-secret';
  static Map<String, Object?> generated() => {
        'id': 'link-1',
        'url': secret,
        'platform': 'server-catalog-package',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 24))
            .toUtc()
            .toIso8601String(),
      };
  bool denied = false;
  List<Map<String, Object?>> links = [];
  List<Map<String, String>> platforms = [
    {
      'key': 'server-catalog-package',
      'label': 'Published package',
      'kind': 'exe'
    }
  ];
  List<Map<String, String>> fleets = [
    {'id': 'fleet-a', 'name': 'Production'},
    {'id': 'fleet-b', 'name': 'Lab'}
  ];
  final writes = <({
    String method,
    String path,
    String? organization,
    Map<String, dynamic>? body
  })>[];
  Future<(int, String)> Function()? create;
  late final OrganizationContextController organization;

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(organization.dispose);
    await organization.syncCredential('token');
    await tester.pumpWidget(MaterialApp(
        theme: C.theme(),
        home:
            Scaffold(body: InstallerLinksScreen(organization: organization))));
    await tester.pumpAndSettle();
  }
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'API catalog and explicit fleet choice; creation, failed replacement, copy and revoke',
      (tester) async {
    final harness = InstallerHarness();
    await harness.mount(tester);
    expect(find.text('Published package'), findsOneWidget);
    expect(find.text('Windows 64-bit'), findsNothing);
    final generate = find.byKey(const ValueKey('generate-installer-link'));
    expect(tester.widget<FilledButton>(generate).onPressed, isNull);
    await tap(
        tester, find.widgetWithText(DropdownButtonFormField<String>, 'Fleet'));
    await tap(tester, find.text('Lab').last);
    await tap(tester, generate);
    expect(harness.writes.single.body,
        {'platform': 'server-catalog-package', 'fleetId': 'fleet-b'});
    expect(harness.writes.single.organization, 'org-a');
    expect(find.text(InstallerHarness.secret), findsOneWidget);
    expect(find.text('must-not-recover-history-secret'), findsNothing);

    harness.create = () async => (503, '{"error":"Try again later."}');
    await tap(tester, generate);
    expect(find.text('Try again later.'), findsOneWidget);
    expect(find.text(InstallerHarness.secret), findsOneWidget);

    var clipboardFails = true;
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        if (clipboardFails)
          throw PlatformException(code: 'clipboard-unavailable');
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tap(tester, find.text('Copy link'));
    expect(
        find.textContaining('Could not copy automatically.'), findsOneWidget);
    expect(find.text('Link copied.'), findsNothing);
    clipboardFails = false;
    await tap(tester, find.text('Copy link'));
    expect(copied, InstallerHarness.secret);
    expect(find.text('Link copied.'), findsOneWidget);

    await tap(tester, find.text('Revoke'));
    expect(harness.writes.last.path, '/console/download-links/link-1');
    expect(find.text(InstallerHarness.secret), findsNothing);
    expect(find.text('Revoked'), findsOneWidget);
    expect(find.text('Revoke'), findsNothing);
  });

  testWidgets(
      'metadata never recovers URL, expiry removes revoke, unavailable catalog stays empty',
      (tester) async {
    final harness = InstallerHarness()
      ..platforms = []
      ..links = [
        {
          ...InstallerHarness.generated(),
          'url': 'history-secret',
          'expiresAt': DateTime.now()
              .subtract(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
          'revokedAt': null,
          'fleetId': null,
          'createdBy': 'user'
        }
      ];
    await harness.mount(tester);
    expect(find.text('No stable installers are currently published.'),
        findsOneWidget);
    expect(find.text('Expired'), findsOneWidget);
    expect(find.text('Revoke'), findsNothing);
    expect(find.text('history-secret'), findsNothing);
    expect(find.text('Copy link'), findsNothing);
  });

  testWidgets(
      'permission rejection removes secrets without invalidating unrelated organization access',
      (tester) async {
    final harness = InstallerHarness()
      ..fleets = [
        {'id': 'fleet-a', 'name': 'Only fleet'}
      ];
    await harness.mount(tester);
    await tap(tester, find.text('Generate link'));
    expect(harness.writes.single.body!['fleetId'], 'fleet-a');
    harness.denied = true;
    await tap(tester, find.text('Refresh'));
    expect(harness.organization.ready, isTrue);
    expect(find.text(InstallerHarness.secret), findsNothing);
    expect(find.text('Generate link'), findsNothing);
    expect(find.text('Sharing installers is not permitted.'), findsOneWidget);
  });

  testWidgets(
      'late create across A to B to A and disposal never exposes old secret',
      (tester) async {
    final harness = InstallerHarness()..fleets = [];
    await harness.mount(tester);
    final lateCreate = Completer<(int, String)>();
    harness.create = () => lateCreate.future;
    await tester.tap(find.text('Generate link'));
    await tester.pump();
    await harness.organization.select('org-b');
    await tester.pumpAndSettle();
    await harness.organization.select('org-a');
    await tester.pumpAndSettle();
    lateCreate.complete((201, jsonEncode(InstallerHarness.generated())));
    await tester.pumpAndSettle();
    expect(find.text(InstallerHarness.secret), findsNothing);
    expect(harness.writes.single.organization, 'org-a');
    expect(harness.writes.single.body!.containsKey('fleetId'), isFalse);

    final disposedCreate = Completer<(int, String)>();
    harness.create = () => disposedCreate.future;
    await tester.tap(find.text('Generate link'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    disposedCreate.complete((201, jsonEncode(InstallerHarness.generated())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
