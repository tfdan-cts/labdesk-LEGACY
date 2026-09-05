import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/machine_row.dart';
import 'package:flutter_hbb/mobile/widgets/machine_list.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

MachineRow _row(
  String id, {
  String hostname = '',
  LabDeskPeerStatus status = LabDeskPeerStatus.unknown,
  DateTime? lastSeenOnline,
  DateTime? lastChecked,
}) =>
    MachineRow(
      id: id,
      hostname: hostname,
      platform: 'Windows',
      status: status,
      lastSeenOnline: lastSeenOnline,
      lastChecked: lastChecked,
    );

void main() {
  final now = DateTime(2026, 9, 5, 12, 0);

  testWidgets('with no machine it says so and says what to do next',
      (tester) async {
    var pressed = 0;
    await tester.pumpWidget(_wrap(MachineListView(
      machines: const [],
      onConnect: (_) {},
      onConnectToFirstMachine: () => pressed++,
    )));

    expect(find.text('No machines yet'), findsOneWidget);
    expect(
      find.text('Connect to a machine'),
      findsOneWidget,
      reason: 'an empty list that offers no control is a dead end',
    );

    await tester.tap(find.text('Connect to a machine'));
    await tester.pump();
    expect(pressed, 1);
  });

  testWidgets('a machine nobody has asked about reads as unknown, never as down',
      (tester) async {
    await tester.pumpWidget(_wrap(MachineListView(
      machines: [_row('1180573903', hostname: 'workshop-pc')],
      onConnect: (_) {},
      now: now,
    )));

    expect(find.text('workshop-pc'), findsOneWidget);
    expect(find.text('Unknown'), findsOneWidget);
    expect(
      find.text('Offline'),
      findsNothing,
      reason: 'absence of an answer is not an answer',
    );
    expect(
      find.textContaining('Seen'),
      findsNothing,
      reason: 'a machine never seen has no last seen time to render',
    );
  });

  testWidgets('an online machine says so and carries when it was checked',
      (tester) async {
    await tester.pumpWidget(_wrap(MachineListView(
      machines: [
        _row(
          '1180573903',
          hostname: 'workshop-pc',
          status: LabDeskPeerStatus.online,
          lastSeenOnline: now,
          lastChecked: now,
        )
      ],
      onConnect: (_) {},
      now: now,
    )));

    expect(find.text('Online'), findsOneWidget);
    expect(find.textContaining('Seen 0s ago'), findsOneWidget);
  });

  testWidgets('an offline machine says how long it has been away',
      (tester) async {
    await tester.pumpWidget(_wrap(MachineListView(
      machines: [
        _row(
          '4',
          hostname: 'front-desk',
          status: LabDeskPeerStatus.offline,
          lastSeenOnline: now.subtract(const Duration(hours: 3)),
          lastChecked: now,
        )
      ],
      onConnect: (_) {},
      now: now,
    )));

    expect(find.text('Offline'), findsOneWidget);
    expect(find.textContaining('Seen 3h ago'), findsOneWidget);
  });

  testWidgets('one tap on a machine connects to it', (tester) async {
    final connected = <String>[];
    await tester.pumpWidget(_wrap(MachineListView(
      machines: [_row('1180573903', hostname: 'workshop-pc')],
      onConnect: connected.add,
      now: now,
    )));

    await tester.tap(find.text('workshop-pc'));
    await tester.pump();

    expect(connected, ['1180573903']);
  });

  testWidgets('a machine with a saved password says so, and one without does not',
      (tester) async {
    await tester.pumpWidget(_wrap(MachineListView(
      machines: [
        _row('1180573903', hostname: 'workshop-pc'),
        _row('4', hostname: 'front-desk'),
      ],
      onConnect: (_) {},
      savedPasswords: const {'1180573903'},
      now: now,
    )));

    expect(find.byIcon(Icons.vpn_key_outlined), findsOneWidget);
  });

  testWidgets('a machine being checked right now says so, not its stale state',
      (tester) async {
    await tester.pumpWidget(_wrap(MachineListView(
      machines: [
        _row('4',
            hostname: 'front-desk',
            status: LabDeskPeerStatus.offline,
            lastSeenOnline: now.subtract(const Duration(hours: 3)))
      ],
      onConnect: (_) {},
      checking: const {'4'},
      now: now,
    )));

    expect(find.text('Checking'), findsOneWidget);
    expect(
      find.text('Offline'),
      findsNothing,
      reason: 'a question that is still open is not an answer',
    );
  });

  testWidgets('a long name on a narrow phone does not overflow the row',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(MachineListView(
      machines: [
        _row('1180573903',
            hostname: 'workshop-pc-in-the-back-room-by-the-window',
            status: LabDeskPeerStatus.offline,
            lastSeenOnline: now.subtract(const Duration(hours: 3))),
      ],
      onConnect: (_) {},
      savedPasswords: const {'1180573903'},
      now: now,
    )));

    expect(
      tester.takeException(),
      isNull,
      reason: 'the narrowest phone still has to be able to read the list',
    );
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('a machine with no hostname is still named by its identifier',
      (tester) async {
    await tester.pumpWidget(_wrap(MachineListView(
      machines: [_row('1180573903')],
      onConnect: (_) {},
      now: now,
    )));

    expect(find.text('1180573903'), findsWidgets);
  });
}
