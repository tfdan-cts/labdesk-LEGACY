import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/dashboard_layout.dart';
import 'package:flutter_hbb/labdesk/models/machine_metrics.dart';
import 'package:flutter_hbb/labdesk/models/machine_row.dart';
import 'package:flutter_hbb/labdesk/models/machine_state.dart';
import 'package:flutter_hbb/labdesk/screens/dashboard_widgets.dart';
import 'package:flutter_hbb/labdesk/screens/home_dashboard.dart';

final now = DateTime.utc(2026, 9, 6, 12);
const machines = [
  MachineRow(
      id: 'alpha',
      hostname: 'Alpha',
      platform: 'Windows',
      status: LabDeskPeerStatus.online,
      group: 'fake-fleet'),
  MachineRow(
      id: 'beta',
      hostname: 'Beta',
      platform: 'Linux',
      status: LabDeskPeerStatus.offline),
  MachineRow(
      id: 'gamma',
      hostname: 'Gamma',
      platform: 'Linux',
      status: LabDeskPeerStatus.unknown),
];
const fleets = [
  DashboardFleet(id: 'fleet-one', name: 'Server fleet one'),
  DashboardFleet(id: 'fleet-two', name: 'Server fleet two')
];
const memberships = <String, Set<String>>{
  'alpha': {'fleet-one'},
  'beta': {'fleet-two'}
};
MachineHealth healthFor(String id) => MachineHealth(
    machineId: id,
    connected: false,
    state: id == 'gamma'
        ? null
        : MachineState(
            status: id == 'alpha' ? 'online' : 'offline',
            seenAt: now
                    .subtract(Duration(seconds: id == 'alpha' ? 30 : 720))
                    .millisecondsSinceEpoch ~/
                1000,
            flushSeconds: 60,
            cpuPct: id == 'alpha' ? 42 : 90,
            memPct: id == 'alpha' ? 0 : null,
            fsWorstPct: id == 'alpha' ? 97 : null),
    history: id == 'alpha'
        ? (MetricHistory()
          ..add(MetricSample(
              at: now.subtract(const Duration(minutes: 2)), cpu: .21))
          ..add(MetricSample(
              at: now.subtract(const Duration(seconds: 30)), cpu: .42)))
        : null);
DashboardWidgetSpec cpu(
        {String id = 'cpu',
        DashboardScope scope = DashboardScope.fleet,
        List<String> ids = const []}) =>
    DashboardWidgetSpec(
        id: id,
        report: DashboardReport.cpu,
        scope: scope,
        machineIds: ids,
        width: 6,
        height: 4);
DashboardLayout initial() => DashboardLayout(widgets: [cpu()]);

Future<void> mount(WidgetTester tester,
    {DashboardLayout? layout,
    Future<void> Function(DashboardLayout)? save,
    Size size = const Size(1440, 1000),
    double textScale = 1,
    TargetPlatform? platform,
    String contextKey = 'org-one'}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
          platform: platform,
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: Colors.cyan),
      home: MediaQuery(
          data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true),
          child: Scaffold(
              body: HomeDashboard(
                  machines: machines,
                  healthFor: healthFor,
                  now: now,
                  layout: layout ?? initial(),
                  onSaveLayout: save,
                  fleets: fleets,
                  machineFleetIds: memberships,
                  contextKey: contextKey)))));
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [const Size(1440, 1000), const Size(800, 600)]) {
    testWidgets(
        'overflow reports remain reachable by touch and keyboard at $size',
        (tester) async {
      await mount(tester,
          platform: TargetPlatform.windows,
          size: size,
          layout: DashboardLayout(widgets: [
            DashboardWidgetSpec(
                id: 'availability',
                report: DashboardReport.availability,
                width: 4,
                height: 4),
          ]),
          textScale: 2);
      final body = find.byKey(const ValueKey('report-body-availability'));
      final scroll = tester.widget<SingleChildScrollView>(body);
      final controller = scroll.controller!;
      final scrollbar = tester.widget<Scrollbar>(
          find.ancestor(of: body, matching: find.byType(Scrollbar)).first);
      expect(scrollbar.thumbVisibility, isTrue);
      expect(scrollbar.trackVisibility, isTrue);
      expect(scrollbar.controller, same(controller));
      expect(controller.position.maxScrollExtent, greaterThan(0));
      await tester.drag(body, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      // Focus the report itself, so its keyboard scroll never moves the grid.
      Focus.of(tester.element(body)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(controller.offset, controller.position.maxScrollExtent);
      final gamma = find.descendant(of: body, matching: find.text('Gamma'));
      await Scrollable.ensureVisible(tester.element(gamma), alignment: .5);
      await tester.pumpAndSettle();
      expect(
          tester.getRect(body).contains(tester.getRect(gamma).topLeft), isTrue);
      expect(tester.getRect(body).contains(tester.getRect(gamma).bottomRight),
          isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(tester.takeException(), isNull);
    });
  }

  test(
      'cached old or future online reports become unknown; explicit offline stays offline',
      () {
    DashboardReading reading(String status, int offsetSeconds) =>
        DashboardReading(
            machines.first,
            MachineHealth(
                machineId: 'alpha',
                connected: false,
                state: MachineState(
                    status: status,
                    flushSeconds: 60,
                    seenAt: now
                            .add(Duration(seconds: offsetSeconds))
                            .millisecondsSinceEpoch ~/
                        1000)),
            now);
    expect(reading('online', -30).status, 'online');
    expect(reading('online', -121).status, 'unknown');
    expect(reading('online', -3600).status, 'unknown');
    expect(reading('online', 30).status, 'unknown');
    expect(reading('offline', -3600).status, 'offline');
    expect(DashboardReading(machines.first, MachineHealth.empty, now).status,
        'unknown');
  });

  testWidgets(
      'old online reports do not count as online in availability or fleet comparison',
      (tester) async {
    MachineHealth staleHealth(String id) => MachineHealth(
        machineId: id,
        connected: false,
        state: MachineState(
            status: 'online',
            flushSeconds: 60,
            seenAt:
                now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/
                    1000));
    for (final report in [
      DashboardReport.availability,
      DashboardReport.fleets
    ]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: DashboardReportBody(
                      spec: DashboardWidgetSpec(
                          id: 'stale',
                          report: report,
                          style: DashboardStyle.compact),
                      rows: machines,
                      healthFor: staleHealth,
                      now: now,
                      fleets: fleets,
                      machineFleetIds: memberships)))));
      expect(find.textContaining('0 online'), findsWidgets);
      expect(find.textContaining('1 online'), findsNothing);
    }
  });

  testWidgets(
      'compact multi-machine scopes retain names and unavailable saved identities',
      (tester) async {
    await mount(tester,
        layout: DashboardLayout(widgets: [
          DashboardWidgetSpec(
              id: 'availability',
              report: DashboardReport.availability,
              style: DashboardStyle.compact,
              scope: DashboardScope.multiple,
              machineIds: ['alpha', 'beta'],
              width: 6),
          DashboardWidgetSpec(
              id: 'attention',
              report: DashboardReport.attention,
              style: DashboardStyle.compact,
              scope: DashboardScope.multiple,
              machineIds: ['gamma', 'gone'],
              width: 6,
              x: 6),
        ]));
    expect(find.text('Alpha, Beta · 2 of 2 in filter'), findsOneWidget);
    expect(find.text('Gamma, Unavailable (gone) · 1 of 2 in filter'),
        findsOneWidget);
    expect(find.byTooltip('Gamma, Unavailable (gone) · 1 of 2 in filter'),
        findsOneWidget);
  });

  test('projection distinguishes zero, missing, stale and future timestamps',
      () {
    final live = DashboardReading(machines[0], healthFor('alpha'), now);
    final stale = DashboardReading(machines[1], healthFor('beta'), now);
    final missing = DashboardReading(machines[2], healthFor('gamma'), now);
    expect(live.value(MetricKind.cpu), 42);
    expect(live.value(MetricKind.memory), 0);
    expect(live.value(MetricKind.disk), 97);
    expect(stale.value(MetricKind.cpu), isNull);
    expect(stale.raw(MetricKind.cpu), 90);
    expect(stale.stale, isTrue);
    expect(missing.value(MetricKind.cpu), isNull);
    final future = DashboardReading(
        machines[0],
        MachineHealth(
            machineId: 'alpha',
            connected: false,
            state: MachineState(
                cpuPct: 50,
                seenAt: now
                        .add(const Duration(minutes: 1))
                        .millisecondsSinceEpoch ~/
                    1000)),
        now);
    expect(future.value(MetricKind.cpu), isNull);
    expect(future.freshness, 'Source clock ahead');
  });

  test('per-widget scopes intersect server fleet IDs independently', () {
    final a = cpu(scope: DashboardScope.multiple, ids: ['alpha', 'beta']);
    final b = cpu(id: 'other', scope: DashboardScope.single, ids: ['beta']);
    expect(
        dashboardScopeRows(machines, a,
                fleetId: 'fleet-one', machineFleetIds: memberships)
            .map((m) => m.id),
        ['alpha']);
    expect(
        dashboardScopeRows(machines, b,
            fleetId: 'fleet-one', machineFleetIds: memberships),
        isEmpty);
    expect(b.machineIds, ['beta']);
    expect(
        dashboardScopeRows(machines, cpu(),
            fleetId: 'fake-fleet', machineFleetIds: memberships),
        isEmpty);
  });

  testWidgets(
      'named current and missing readings render without invented values',
      (tester) async {
    await mount(tester);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('90%'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.textContaining('No current reading'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'average identifies actual contributors and excludes stale readings',
      (tester) async {
    await mount(tester,
        layout: DashboardLayout(widgets: [cpu(scope: DashboardScope.average)]));
    expect(find.text('Contributors: Alpha'), findsOneWidget);
    expect(find.text('2 excluded: unavailable or stale'), findsOneWidget);
    expect(find.text('42%'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'duplicate, undo, cancel and save preserve explicit draft boundaries',
      (tester) async {
    DashboardLayout? saved;
    await mount(tester, save: (layout) async => saved = layout);
    await tester.tap(find.text('Make it yours'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-cpu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    expect(find.byType(DashboardReportBody), findsNWidgets(2));
    expect(saved, isNull);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.byType(DashboardReportBody), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.text('Make it yours'), findsOneWidget);
    await tester.tap(find.text('Make it yours'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-cpu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved!.widgets.length, 2);
    expect(find.text('Dashboard saved.'), findsOneWidget);
  });

  testWidgets('failed save keeps editable draft and visible retry explanation',
      (tester) async {
    await mount(tester, save: (_) async => throw StateError('disk full'));
    await tester.tap(find.text('Make it yours'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Your draft is still here'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('context change clears drafts and ignores old save completion',
      (tester) async {
    final pending = Completer<void>();
    await mount(tester, save: (_) => pending.future);
    await tester.tap(find.text('Make it yours'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pump();
    await mount(tester, contextKey: 'org-two');
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('Make it yours'), findsOneWidget);
    expect(find.text('Dashboard saved.'), findsNothing);
    expect(find.text('Saving…'), findsNothing);
  });

  testWidgets('keyboard handle moves and resizes the saved draft',
      (tester) async {
    DashboardLayout? saved;
    await mount(tester, save: (layout) async => saved = layout);
    await tester.tap(find.text('Make it yours'));
    await tester.pumpAndSettle();
    final handle = find.byTooltip('Move CPU use');
    await tester.tap(handle);
    await tester.pumpAndSettle();
    final focus = Focus.of(tester.element(handle));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved!.widgets.single.x, 1);
    expect(saved!.widgets.single.height, 5);
  });

  testWidgets(
      'machine picker updates only its report and fleet filter intersects it',
      (tester) async {
    DashboardLayout? saved;
    await mount(tester,
        layout:
            DashboardLayout(widgets: [cpu(), cpu(id: 'other').copyWith(x: 6)]),
        save: (layout) async => saved = layout);
    await tester.tap(find.text('Make it yours'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-cpu')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const ValueKey('cpu-Machine scope-DashboardScope.fleet')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selected machines').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
        saved!.widgets.firstWhere((w) => w.id == 'cpu').machineIds, ['alpha']);
    expect(
        saved!.widgets.firstWhere((w) => w.id == 'other').machineIds, isEmpty);
    await tester.tap(find.text('All fleets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Server fleet two').last);
    await tester.pumpAndSettle();
    final bodies = tester
        .widgetList<DashboardReportBody>(find.byType(DashboardReportBody))
        .toList();
    expect(bodies.firstWhere((b) => b.spec.id == 'cpu').rows, isEmpty);
    expect(bodies.firstWhere((b) => b.spec.id == 'other').rows.map((m) => m.id),
        ['beta']);
  });

  testWidgets('preset is a cancellable draft and Add report opens its settings',
      (tester) async {
    DashboardLayout? saved;
    await mount(tester, save: (layout) async => saved = layout);
    await tester.tap(find.text('Make it yours'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everyday'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Operations').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Preset loaded as a draft'), findsOneWidget);
    expect(saved, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(DashboardReportBody), findsOneWidget);
    await tester.tap(find.text('Make it yours'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add report'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Memory use'));
    await tester.pumpAndSettle();
    expect(find.text('Report settings'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
        saved!.widgets.map((w) => w.report), contains(DashboardReport.memory));
  });

  testWidgets('drag and resize handles apply native grid increments',
      (tester) async {
    DashboardLayout? saved;
    await mount(tester, save: (layout) async => saved = layout);
    await tester.tap(find.text('Make it yours'));
    await tester.pumpAndSettle();
    await tester.drag(find.byTooltip('Move CPU use'), const Offset(120, 78));
    await tester.pumpAndSettle();
    await tester.drag(find.byTooltip('Resize CPU use'), const Offset(120, 78));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved!.widgets.single.x, 1);
    expect(saved!.widgets.single.y, 1);
    expect(saved!.widgets.single.width, 7);
    expect(saved!.widgets.single.height, 5);
  });

  for (final size in [const Size(1440, 1000), const Size(390, 844)]) {
    testWidgets('dashboard and inspector fit $size at larger text',
        (tester) async {
      await mount(tester, size: size, textScale: 1.5);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Make it yours'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-cpu')));
      await tester.pumpAndSettle();
      expect(find.text('Report settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final report in DashboardReport.values) {
    for (final style in DashboardStyle.values) {
      testWidgets(
          '${report.name}/${style.name} renders genuine data in narrow report',
          (tester) async {
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: SizedBox(
                    width: 285,
                    child: SingleChildScrollView(
                        child: DashboardReportBody(
                            spec: DashboardWidgetSpec(
                                id: 'report', report: report, style: style),
                            rows: machines,
                            healthFor: healthFor,
                            now: now,
                            fleets: fleets,
                            machineFleetIds: memberships))))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
