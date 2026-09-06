import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/screens/labnet_card.dart';
import 'package:flutter_hbb/labdesk/services/overlay_enrolment.dart';

/// The labnet card in each of its four states, and which action each offers.
Future<void> _pump(WidgetTester t, LabnetCardState s,
    {VoidCallback? onEnable, VoidCallback? onDisable}) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 600,
        child: LabnetCard(state: s, onEnable: onEnable, onDisable: onDisable),
      ),
    ),
  ));
}

void main() {
  testWidgets('off offers Turn on and says what it changes', (t) async {
    var enabled = 0;
    await _pump(t, LabnetCardState.off, onEnable: () => enabled++);
    expect(find.text('Encrypted direct connections'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Turn on'), findsOneWidget);
    expect(find.text('Turn off'), findsNothing);
    await t.tap(find.text('Turn on'));
    expect(enabled, 1);
  });

  testWidgets('working shows the step and no action', (t) async {
    await _pump(t, const LabnetCardState(LabnetPhase.working, detail: 'Joining labnet'));
    expect(find.text('Joining labnet'), findsOneWidget);
    expect(find.text('Turn on'), findsNothing);
    expect(find.text('Turn off'), findsNothing);
  });

  testWidgets('on shows the address and offers Turn off', (t) async {
    var disabled = 0;
    await _pump(t, const LabnetCardState(LabnetPhase.on, ip: '100.64.0.3'), onDisable: () => disabled++);
    expect(find.text('On at 100.64.0.3'), findsOneWidget);
    await t.tap(find.text('Turn off'));
    expect(disabled, 1);
  });

  testWidgets('error prints the daemon\'s words and offers Try again', (t) async {
    var again = 0;
    await _pump(t, const LabnetCardState(LabnetPhase.error, detail: 'setup key expired'), onEnable: () => again++);
    expect(find.text('setup key expired'), findsOneWidget);
    await t.tap(find.text('Try again'));
    expect(again, 1);
  });

  testWidgets('no shipped string carries an em or en dash', (t) async {
    for (final s in [
      LabnetCardState.off,
      const LabnetCardState(LabnetPhase.working, detail: 'x'),
      const LabnetCardState(LabnetPhase.on, ip: '1.2.3.4'),
      const LabnetCardState(LabnetPhase.error, detail: 'x'),
    ]) {
      await _pump(t, s);
      for (final w in t.widgetList<Text>(find.byType(Text))) {
        expect(w.data ?? '', isNot(matches(RegExp('[–—]'))));
      }
    }
  });
}
