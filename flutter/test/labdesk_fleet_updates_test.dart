import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/screens/fleet_updates_screen.dart';
import 'package:flutter_hbb/labdesk/services/organization_context.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

Map<String, Object?> machine(String id,
        {String fleet = 'fleet-a',
        bool supported = true,
        bool reported = true,
        int revision = 2,
        int applied = 1,
        List<Map<String, Object?>> commands = const []}) =>
    {
      'id': id,
      'name': 'Machine $id',
      'fleetId': fleet,
      'platform': 'Windows',
      'policy': {'revision': revision, 'automatic': false, 'weekly': null},
      'status': reported
          ? {
              'policyRevision': applied,
              'currentVersion': '1.0.0',
              'availableVersion': '1.1.0',
              'state': supported ? 'available' : 'unsupported',
              'reportedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
              'capabilities': {
                'check': supported,
                'install': supported,
                'scheduling': supported
              }
            }
          : null,
      'commands': commands,
    };

class UpdatesHarness {
  UpdatesHarness() {
    broker = OverlayBroker(
        baseUrl: 'https://example.test',
        token: () => token,
        organizationId: () => organization.activeId,
        http: (method, url, headers, body) async {
          if (url.path == '/console/organizations')
            return (
              200,
              jsonEncode({
                'userId': 'user-$token',
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
          if (method == 'GET' && url.path == '/console/org/updates') {
            if (read != null) return read!(headers);
            return (
              200,
              jsonEncode({'editable': editable, 'machines': machines})
            );
          }
          writes.add((
            method: method,
            path: url.path,
            headers: Map<String, String>.from(headers),
            body: body == null ? null : jsonDecode(body) as Map<String, dynamic>
          ));
          if (method == 'DELETE')
            return (409, '{"error":"Installation has begun; cannot cancel."}');
          return (200, '{"ok":true,"commands":[]}');
        });
    organization = OrganizationContextController(
        broker: broker,
        readOption: (_) => 'org-a',
        writeOption: (_, __) async {});
  }

  String token = 'token-a';
  bool editable = true;
  List<Map<String, Object?>> machines = [
    machine('canonical-a'),
    machine('canonical-b')
  ];
  Future<(int, String)> Function(Map<String, String>)? read;
  final writes = <({
    String method,
    String path,
    Map<String, String> headers,
    Map<String, dynamic>? body
  })>[];
  late final OverlayBroker broker;
  late final OrganizationContextController organization;

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(organization.dispose);
    await organization.syncCredential(token);
    await tester.pumpWidget(MaterialApp(
        theme: C.theme(),
        home: Scaffold(
            body: FleetUpdatesScreen(
                organization: organization,
                fleetNames: const {
              'fleet-a': 'Production',
              'fleet-b': 'Lab'
            }))));
    await tester.pumpAndSettle();
  }
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

bool enabled(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(find.byKey(ValueKey(key))).onPressed != null;

void main() {
  testWidgets(
      'bulk canonical IDs, UTC windows, weekly limits and pending revision',
      (tester) async {
    final harness = UpdatesHarness();
    await harness.mount(tester);
    // GET authority is editable despite the directory's viewer role.
    await tap(tester, find.text('Select visible (up to 250)'));
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.textContaining('Policy 2 · Pending (reported 1)'),
        findsNWidgets(2));
    final hours = find.widgetWithText(TextField, 'Execution window (hours)');
    await tester.enterText(hours, '0');
    await tester.pump();
    expect(enabled(tester, 'schedule-updates'), isFalse);
    await tester.enterText(hours, '25');
    await tester.pump();
    expect(enabled(tester, 'schedule-updates'), isFalse);
    await tester.enterText(hours, '24');
    await tester.pump();
    expect(enabled(tester, 'schedule-updates'), isTrue);
    final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await tap(tester, find.byKey(const ValueKey('schedule-updates')));
    final command = harness.writes.single;
    expect(command.path, '/console/org/update-commands');
    expect(command.headers['x-labdesk-organization'], 'org-a');
    expect(command.body!['machineIds'], ['canonical-a', 'canonical-b']);
    expect(command.body!['action'], 'check');
    expect(command.body!['startsAt'], greaterThanOrEqualTo(before));
    expect(command.body!['endsAt'] - command.body!['startsAt'], 24 * 3600);

    await tap(tester,
        find.widgetWithText(SwitchListTile, 'Enable automatic updates'));
    expect(enabled(tester, 'save-update-policy'), isFalse);
    await tap(tester, find.widgetWithText(FilterChip, 'Sun'));
    final minutes = find.widgetWithText(TextField, 'Weekly window (minutes)');
    await tester.ensureVisible(minutes);
    await tester.enterText(minutes, '14');
    await tester.pump();
    expect(enabled(tester, 'save-update-policy'), isFalse);
    await tester.enterText(minutes, '1441');
    await tester.pump();
    expect(enabled(tester, 'save-update-policy'), isFalse);
    await tester.enterText(minutes, '1440');
    await tester.pump();
    expect(enabled(tester, 'save-update-policy'), isTrue);
    await tap(tester, find.byKey(const ValueKey('save-update-policy')));
    final policy = harness.writes.last;
    expect(policy.path, '/console/org/update-policies');
    expect(policy.body!['automatic'], isTrue);
    expect(policy.body!['weekly'], {
      'days': [0],
      'startMinute': 180,
      'windowMinutes': 1440
    });
    expect(find.textContaining('Pending until each machine'), findsOneWidget);
  });

  testWidgets(
      'missing reports and unsupported capability cannot enable actions; disable is allowed',
      (tester) async {
    final harness = UpdatesHarness()
      ..machines = [
        machine('legacy', reported: false),
        machine('unsupported', supported: false)
      ];
    await harness.mount(tester);
    expect(find.textContaining('No modern updater report'), findsOneWidget);
    expect(find.textContaining('Install: unsupported'), findsOneWidget);
    await tap(tester, find.text('Select visible (up to 250)'));
    expect(enabled(tester, 'schedule-updates'), isFalse);
    expect(enabled(tester, 'save-update-policy'), isTrue);
    await tap(tester,
        find.widgetWithText(SwitchListTile, 'Enable automatic updates'));
    await tap(tester, find.widgetWithText(FilterChip, 'Sun'));
    expect(enabled(tester, 'save-update-policy'), isFalse);
    await tap(tester,
        find.widgetWithText(SwitchListTile, 'Enable automatic updates'));
    await tap(tester, find.byKey(const ValueKey('save-update-policy')));
    expect(harness.writes.single.body!['automatic'], isFalse);
    expect(harness.writes.single.body!['weekly'], isNull);
    harness.editable = false;
    await tap(tester, find.text('Refresh'));
    expect(enabled(tester, 'save-update-policy'), isFalse);
    expect(find.textContaining('Read-only:'), findsOneWidget);
  });

  testWidgets(
      'chosen local start converts to UTC and future actions require scheduling support',
      (tester) async {
    final harness = UpdatesHarness()..machines = [machine('canonical-a')];
    await harness.mount(tester);
    await tap(tester, find.text('Select visible (up to 250)'));
    await tap(tester, find.widgetWithText(SwitchListTile, 'Start now'));
    expect(enabled(tester, 'schedule-updates'), isFalse);
    await tap(tester, find.text('Choose local date and time'));
    final day = DateTime.now().add(const Duration(days: 2));
    tester
        .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
        .onDateChanged(day);
    await tester.pump();
    await tap(tester, find.text('OK'));
    Navigator.of(tester.element(find.byType(TimePickerDialog)))
        .pop(const TimeOfDay(hour: 16, minute: 30));
    await tester.pumpAndSettle();
    expect(enabled(tester, 'schedule-updates'), isTrue);
    await tap(tester, find.byKey(const ValueKey('schedule-updates')));
    expect(
        harness.writes.single.body!['startsAt'],
        DateTime(day.year, day.month, day.day, 16, 30)
                .toUtc()
                .millisecondsSinceEpoch ~/
            1000);
    final status = harness.machines.single['status'] as Map<String, Object>;
    (status['capabilities'] as Map<String, bool>)['scheduling'] = false;
    await tap(tester, find.text('Refresh'));
    expect(enabled(tester, 'schedule-updates'), isFalse);
    await tap(tester, find.widgetWithText(SwitchListTile, 'Start now'));
    expect(enabled(tester, 'schedule-updates'), isTrue);
  });

  testWidgets('bulk selection is capped at 250 scoped machines',
      (tester) async {
    final harness = UpdatesHarness()
      ..machines = List.generate(251, (index) => machine('machine-$index'));
    await harness.mount(tester);
    await tap(tester, find.text('Select visible (up to 250)'));
    expect(find.text('250 selected'), findsOneWidget);
    expect(harness.writes, isEmpty);
  });

  testWidgets(
      'fleet change clears selection and cancellation reports authoritative 409',
      (tester) async {
    final harness = UpdatesHarness()
      ..machines = [
        machine('canonical-a', commands: [
          {
            'id': 'command-a',
            'machineId': 'canonical-a',
            'action': 'install',
            'startsAt': 1788800000,
            'endsAt': 1788803600,
            'state': 'downloading'
          }
        ]),
        machine('canonical-b', fleet: 'fleet-b')
      ];
    await harness.mount(tester);
    await tap(tester, find.text('Cancel preparation'));
    expect(
        harness.writes.single.path, '/console/org/update-commands/command-a');
    expect(find.text('Installation has begun; cannot cancel.'), findsOneWidget);
    await tap(tester, find.text('Select visible (up to 250)'));
    await tap(
        tester, find.widgetWithText(DropdownButtonFormField<String>, 'Fleet'));
    await tap(tester, find.text('Lab').last);
    expect(find.text('0 selected'), findsOneWidget);
    expect(find.text('Machine canonical-a'), findsNothing);
    await tap(tester, find.text('Select visible (up to 250)'));
    expect(find.text('1 selected'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('schedule-updates')));
    expect(harness.writes.last.body!['machineIds'], ['canonical-b']);
  });

  testWidgets(
      'late A to B to A read cannot restore old authority or invalidate new context',
      (tester) async {
    final harness = UpdatesHarness();
    await harness.mount(tester);
    final lateRead = Completer<(int, String)>();
    harness.read = (_) => lateRead.future;
    await tester.tap(find.text('Refresh'));
    await tester.pump();
    harness.read = (_) async => (
          200,
          jsonEncode({
            'editable': false,
            'machines': [machine('new-scope')]
          })
        );
    await harness.organization.select('org-b');
    await tester.pumpAndSettle();
    await harness.organization.select('org-a');
    await tester.pumpAndSettle();
    lateRead.complete((403, '{"error":"Old forbidden response"}'));
    await tester.pumpAndSettle();
    expect(harness.organization.ready, isTrue);
    expect(find.text('Machine new-scope'), findsOneWidget);
    expect(find.text('Machine canonical-a'), findsNothing);
    expect(find.textContaining('Read-only:'), findsOneWidget);
    expect(find.text('Old forbidden response'), findsNothing);

    final disposedRead = Completer<(int, String)>();
    harness.read = (_) => disposedRead.future;
    await tester.tap(find.text('Refresh'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    disposedRead
        .complete((200, jsonEncode({'editable': true, 'machines': []})));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
