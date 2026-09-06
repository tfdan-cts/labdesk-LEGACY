import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/machine_metrics.dart';
import 'package:flutter_hbb/labdesk/models/machine_row.dart';
import 'package:flutter_hbb/labdesk/models/machine_state.dart';
import 'package:flutter_hbb/labdesk/screens/health_board.dart';

final _now = DateTime(2026, 9, 5, 18, 40);

MachineRow _row(LabDeskPeerStatus status, {DateTime? seen}) => MachineRow(
      id: '612847100',
      hostname: 'office-laptop',
      platform: 'Mac OS',
      status: status,
      alias: 'Office laptop',
      lastSeenOnline: seen,
    );

Future<void> _pump(WidgetTester tester, MachineRow row) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HealthBoard(
            machines: [row],
            healthFor: (_) =>
                const MachineHealth(machineId: '612847100', connected: false),
            now: _now,
          ),
        ),
      ),
    );

bool _saysOffline() => find
    .byWidgetPredicate((w) => w is Text && (w.data ?? '').contains('Offline'))
    .evaluate()
    .isNotEmpty;

void main() {
  MachineState report(
          {int age = 8, String status = 'online', int? cadence = 60}) =>
      MachineState(
        status: status,
        seenAt: _now.millisecondsSinceEpoch ~/ 1000 - age,
        flushSeconds: cadence,
        cpuPct: 72,
        memPct: 30,
        fsWorstPct: 50,
        worstDisk: 'ok',
        uptimeS: 3600,
      );

  testWidgets('current report identifies source age and current drive state',
      (tester) async {
    await _pumpState(tester, report());
    expect(find.text('Collector report 8s ago. Current readings.'),
        findsOneWidget);
    expect(find.text('72 %'), findsOneWidget);
    expect(find.text('Drives ok'), findsOneWidget);
    expect(find.text('Online.'), findsOneWidget);
    expect(find.textContaining('Desktop session:'), findsNothing);
  });

  testWidgets(
      'expired online report becomes unknown and readings are explicitly cached',
      (tester) async {
    await _pumpState(tester, report(age: 3600));
    expect(find.text('Unknown'), findsOneWidget);
    expect(find.text('Online.'), findsNothing);
    expect(
        find.text(
            'Last collector report 1h ago. Cached readings; not current.'),
        findsOneWidget);
    expect(find.text('72 %'), findsOneWidget);
    expect(find.text('Drives ok'), findsNothing);
    expect(find.text('Last drive report: drives ok'), findsOneWidget);
  });

  for (final status in ['offline', 'unknown']) {
    testWidgets('$status report never labels cached readings current',
        (tester) async {
      await _pumpState(tester, report(status: status));
      expect(
          find.textContaining('Cached readings; not current.'), findsOneWidget);
      expect(find.text('Drives ok'), findsNothing);
      expect(find.text('Online.'), findsNothing);
      if (status == 'offline') expect(find.text('Offline'), findsOneWidget);
    });
  }

  testWidgets('future source timestamp cannot supply current readings',
      (tester) async {
    await _pumpState(tester, report(age: -30));
    expect(find.textContaining('timestamp is in the future'), findsOneWidget);
    expect(find.text('72 %'), findsNothing);
    expect(find.text('--'), findsNWidgets(4));
    expect(find.text('Unknown'), findsOneWidget);
  });

  testWidgets('missing source never implies unenrolled or zero',
      (tester) async {
    await _pumpState(tester, null);
    expect(find.textContaining('No dated collector report available'),
        findsOneWidget);
    expect(find.textContaining('enrolled'), findsNothing);
    expect(find.text('72'), findsNothing);
    expect(find.text('--'), findsNWidgets(4));
  });

  testWidgets('unknown reporting cadence cannot establish current readings',
      (tester) async {
    await _pumpState(tester, report(cadence: null));
    expect(find.text('Unknown'), findsOneWidget);
    expect(
        find.textContaining('Cached readings; not current.'), findsOneWidget);
  });

  testWidgets('narrow enlarged text and footer remain scrollable',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpState(tester, report(),
        scale: 2, footer: const Text('Reporting interval controls'));
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
        find.text('Reporting interval controls'), 200);
    expect(
        find.text('Reporting interval controls').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a machine with no answer reads as unknown, not as offline',
      (tester) async {
    await _pump(
        tester,
        _row(LabDeskPeerStatus.unknown,
            seen: _now.subtract(const Duration(seconds: 8))));

    expect(_saysOffline(), isFalse);
    expect(find.textContaining('Unknown. No answer since it was last seen 8s'),
        findsOneWidget);
    expect(find.text('Offline'), findsNothing);
  });

  testWidgets('a machine that answered and went away reads as offline',
      (tester) async {
    await _pump(
        tester,
        _row(LabDeskPeerStatus.offline,
            seen: _now.subtract(const Duration(hours: 19))));

    expect(find.textContaining('Offline. Last seen 19h ago.'), findsOneWidget);
  });
}

Future<void> _pumpState(WidgetTester tester, MachineState? state,
        {Widget? footer, double scale = 1, bool connected = false}) =>
    tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: HealthBoard(
        machines: [_row(LabDeskPeerStatus.online)],
        healthFor: (_) => MachineHealth(
          machineId: '612847100',
          connected: connected,
          state: state,
          remote: state?.metrics() ??
              const [
                Metric(
                    label: 'CPU', value: '72', source: MetricSource.collector)
              ],
          session: const [
            Metric(
                label: 'Round trip',
                value: '14',
                unit: 'ms',
                source: MetricSource.session)
          ],
        ),
        now: _now,
        footer: footer,
      ),
    ))));
