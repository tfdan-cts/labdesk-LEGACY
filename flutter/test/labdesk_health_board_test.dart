import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/machine_metrics.dart';
import 'package:flutter_hbb/labdesk/models/machine_row.dart';
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
            healthFor: (_) => const MachineHealth(
                machineId: '612847100', connected: false),
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
