import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/labnet.dart';
import 'package:flutter_hbb/labdesk/screens/network_screen.dart';

/// The Network section rendered from an inbox, and the intents it hands back.
Future<void> _pump(WidgetTester t, Widget w) => t.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 900, height: 700, child: w)),
    ));

const _machines = [
  NetworkMachine(id: '111', name: 'Foundry'),
  NetworkMachine(id: '222', name: 'Homebox'),
  NetworkMachine(id: '333', name: 'Forge'),
];

void main() {
  testWidgets('an invitation shows who asked and offers Approve and Decline only',
      (t) async {
    String? approved;
    String? declined;
    await _pump(
      t,
      NetworkScreen(
        inbox: const LabnetInbox(
          enrolled: true,
          invitations: [LabnetInvitation(labnetId: 'L1', name: 'Office', invitedBy: 'owner@example.com')],
        ),
        thisMachineId: '999',
        onApprove: (id) => approved = id,
        onDecline: (id) => declined = id,
      ),
    );
    expect(find.text('owner@example.com wants to add this machine to Office'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(find.text('Leave'), findsNothing);
    await t.tap(find.text('Approve'));
    expect(approved, 'L1');
    await t.tap(find.text('Decline'));
    expect(declined, 'L1');
  });

  testWidgets('a labnet lists its members by name with their state, and the full access switch only for its owner',
      (t) async {
    const owned = Labnet(id: 'L2', name: 'Lab', fullAccess: false, owner: true, members: [
      LabnetMember(deviceId: '111', status: 'approved', overlayIp: '100.64.0.7'),
      LabnetMember(deviceId: '222', status: 'pending'),
    ]);
    (String, bool)? flipped;
    await _pump(
      t,
      NetworkScreen(
        inbox: const LabnetInbox(enrolled: true, labnets: [owned]),
        thisMachineId: '999',
        machines: _machines,
        onFullAccess: (id, on) => flipped = (id, on),
        onInvite: (_, __) {},
      ),
    );
    expect(find.text('Foundry'), findsOneWidget);
    expect(find.text('100.64.0.7'), findsOneWidget);
    expect(find.text('Homebox'), findsOneWidget);
    expect(find.text('Waiting for approval on that machine'), findsOneWidget);
    expect(find.text('1 of 2 machines joined. LabDesk\'s port and ping between members.'), findsOneWidget);
    await t.tap(find.text('Full access: off'));
    expect(flipped, ('L2', true));
    // Only machines not yet in the labnet are offered.
    await t.tap(find.text('Add machine'));
    await t.pumpAndSettle();
    expect(find.text('Forge'), findsOneWidget);
    expect(find.text('Foundry'), findsOneWidget, reason: 'the member row, not a menu entry');
  });

  testWidgets('a member that is not the owner may leave but not change or delete',
      (t) async {
    String? left;
    await _pump(
      t,
      NetworkScreen(
        inbox: const LabnetInbox(enrolled: true, labnets: [
          Labnet(id: 'L3', name: 'Site', fullAccess: true, owner: false, members: [
            LabnetMember(deviceId: '999', status: 'approved', overlayIp: '100.64.0.3'),
          ]),
        ]),
        thisMachineId: '999',
        onLeave: (id) => left = id,
        onFullAccess: (_, __) {},
        onDelete: (_) {},
      ),
    );
    expect(find.text('This machine'), findsOneWidget);
    expect(find.textContaining('Full access:'), findsNothing);
    expect(find.text('Delete labnet'), findsNothing);
    await t.tap(find.text('Leave'));
    expect(left, 'L3');
  });

  testWidgets('a machine not on labnet is told where to start', (t) async {
    await _pump(t, const NetworkScreen(inbox: LabnetInbox.empty, thisMachineId: '999'));
    expect(find.text('Not on labnet'), findsOneWidget);
    expect(find.text('New labnet'), findsNothing);
  });

  testWidgets('no shipped string carries an em or en dash', (t) async {
    await _pump(
      t,
      NetworkScreen(
        inbox: const LabnetInbox(
          enrolled: true,
          invitations: [LabnetInvitation(labnetId: 'L1', name: 'Office', invitedBy: 'a@b.c')],
          labnets: [Labnet(id: 'L2', name: 'Lab', fullAccess: true, owner: true, members: [LabnetMember(deviceId: '111', status: 'approved')])],
        ),
        thisMachineId: '999',
        machines: _machines,
        error: 'Something the server said.',
        onInvite: (_, __) {},
        onFullAccess: (_, __) {},
        onDelete: (_) {},
        onRemove: (_, __) {},
        onCreate: (_, __) {},
      ),
    );
    for (final w in t.widgetList<Text>(find.byType(Text))) {
      expect(w.data ?? '', isNot(matches(RegExp('[–—]'))));
    }
  });
}
