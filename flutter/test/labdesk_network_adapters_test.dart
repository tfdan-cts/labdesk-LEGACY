import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/labnet.dart';
import 'package:flutter_hbb/labdesk/models/net_view.dart';
import 'package:flutter_hbb/labdesk/screens/network_screen.dart';

/// The per-adapter view and the two labnet surfaces that were missing: naming
/// a fleet when creating, and renaming (contract sections 6 and 9).
Future<void> _pump(WidgetTester t, Widget w) => t.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 1000, height: 900, child: w)),
    ));

const _view = MachineNetView(
  reported: true,
  reachability: NetReachability(
      internet: 'offline', selfheal: 'restarting', probe: 'tcp443'),
  adapters: [
    NetAdapter(
      name: 'eth0',
      up: true,
      mac: 'aa:bb:cc:dd:ee:ff',
      kind: 'physical',
      rxBytes: 1024,
      txBytes: 2048,
      addresses: [NetAddress(addr: '192.168.1.20', prefix: 24, family: 'inet')],
    ),
    NetAdapter(name: 'wlan0', up: false, kind: 'physical'),
  ],
);

void main() {
  testWidgets('each adapter is drawn with its address, and the verdict above them',
      (t) async {
    await _pump(
      t,
      const NetworkScreen(
        inbox: LabnetInbox(enrolled: true),
        thisMachineId: '111',
        netMachineId: '111',
        netView: _view,
      ),
    );
    expect(find.text('eth0'), findsOneWidget);
    expect(find.text('192.168.1.20/24'), findsOneWidget);
    // An adapter with no address is down, and says so rather than showing
    // nothing at all.
    expect(find.text('Down'), findsOneWidget);
    expect(
        find.text('No internet. Self-healing is restarting networking.'),
        findsOneWidget);
  });

  testWidgets('a machine that has reported nothing says so instead of showing an empty list',
      (t) async {
    await _pump(
      t,
      const NetworkScreen(
        inbox: LabnetInbox(enrolled: true),
        thisMachineId: '111',
        netMachineId: '111',
      ),
    );
    expect(find.textContaining('has not reported a network view yet'),
        findsOneWidget);
  });

  testWidgets('a technician narrowed to several fleets names one when creating',
      (t) async {
    String? name;
    String? fleet;
    await _pump(
      t,
      NetworkScreen(
        inbox: const LabnetInbox(enrolled: true),
        thisMachineId: '111',
        mustNameFleet: true,
        fleets: const [
          NetworkFleet(id: 'F1', name: 'Workshop'),
          NetworkFleet(id: 'F2', name: 'Office'),
        ],
        onCreate: (n, f) {
          name = n;
          fleet = f;
        },
      ),
    );
    await t.tap(find.text('New labnet'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'Rack');
    await t.tap(find.text('Office'));
    await t.pumpAndSettle();
    await t.tap(find.text('Create'));
    await t.pumpAndSettle();
    expect(name, 'Rack');
    expect(fleet, 'F2');
  });

  testWidgets('a labnet can be renamed from its own card', (t) async {
    String? renamed;
    String? to;
    await _pump(
      t,
      NetworkScreen(
        inbox: const LabnetInbox(enrolled: true, labnets: [
          Labnet(id: 'L1', name: 'Workshop', fullAccess: false, owner: true),
        ]),
        thisMachineId: '111',
        onRename: (id, n) {
          renamed = id;
          to = n;
        },
      ),
    );
    await t.tap(find.text('Rename'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'Workshop rack');
    await t.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Rename')));
    await t.pumpAndSettle();
    expect(renamed, 'L1');
    expect(to, 'Workshop rack');
  });
}
