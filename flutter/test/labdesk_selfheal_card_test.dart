import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/net_view.dart';
import 'package:flutter_hbb/labdesk/screens/selfheal_card.dart';

/// The self-healing switch on This machine (contract section 7). What it shows
/// beside itself is the RUNNING step the daemon reported, not the option that
/// was set, because the two can disagree and only one of them is the truth.
Future<void> _pump(WidgetTester t, Widget w) => t.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 700, height: 500, child: w)),
    ));

void main() {
  testWidgets('the running step is what is shown, and the switch reports a flip',
      (t) async {
    bool? asked;
    await _pump(
      t,
      SelfHealCard(
        on: true,
        reachability: const NetReachability(
            internet: 'online', selfheal: 'watching', probe: 'tcp443'),
        onChanged: (v) => asked = v,
      ),
    );
    expect(find.text('The service is watching connectivity.'), findsOneWidget);
    await t.tap(find.byType(Switch));
    expect(asked, isFalse);
  });

  testWidgets('between the flip and the first report it says it is waiting',
      (t) async {
    await _pump(
      t,
      const SelfHealCard(
        on: true,
        waiting: true,
        reachability: NetReachability(),
        onChanged: null,
      ),
    );
    expect(find.text('Waiting for the service to pick this up.'), findsOneWidget);
    // Never probed is its own line, not "no internet".
    expect(
        find.text('This machine has not reported an internet check yet.'),
        findsOneWidget);
  });

  testWidgets('a service still healing after the switch went off says so',
      (t) async {
    await _pump(
      t,
      const SelfHealCard(
        on: false,
        reachability: NetReachability(internet: 'offline', selfheal: 'holdoff'),
      ),
    );
    expect(
        find.textContaining('the service is still holding off after a restart'),
        findsOneWidget);
  });
}
