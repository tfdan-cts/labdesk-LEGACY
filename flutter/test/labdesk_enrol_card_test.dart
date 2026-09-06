import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/screens/enrol_card.dart';

/// The organization card on This machine: a token goes in, the privileged
/// process (faked here) answers, and the machine id or the refusal comes out.
Future<void> _pump(WidgetTester t, MachineEnroller enrol) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 600, child: MachineEnrolCard(enrol: enrol)),
    ),
  ));
}

void main() {
  test('the answer is read the way main_agent_enrol writes it', () {
    expect(EnrolOutcome.decode('{"machineId":"m-1"}').machineId, 'm-1');
    expect(EnrolOutcome.decode('{"machineId":"m-1"}').error, '');
    final refused = EnrolOutcome.decode('{"error":"That token has expired."}');
    expect(refused.machineId, '');
    expect(refused.error, 'That token has expired.');
    // Anything short of the two shapes is a failure shown as it came, never
    // a success.
    expect(EnrolOutcome.decode('').error, 'No answer.');
    expect(EnrolOutcome.decode('garbage').error, 'garbage');
    expect(EnrolOutcome.decode('{"machineId":""}').error, '{"machineId":""}');
    expect(EnrolOutcome.decode('[1]').error, '[1]');
  });

  testWidgets('a pasted token is spent once and the machine id is shown', (t) async {
    final spent = <String>[];
    await _pump(t, (token) async {
      spent.add(token);
      return '{"machineId":"5f1c2a0e-7b3d-4c9a-9e21-0d4b8a6f3c11"}';
    });
    expect(find.text('Organization'), findsOneWidget);
    await t.enterText(find.byType(TextField), '  tok-abc  ');
    await t.tap(find.text('Enrol'));
    await t.pumpAndSettle();
    expect(spent, ['tok-abc'], reason: 'trimmed, and sent exactly once');
    expect(find.textContaining('5f1c2a0e-7b3d-4c9a-9e21-0d4b8a6f3c11'), findsOneWidget);
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, '',
        reason: 'a single-use token is cleared once spent');
  });

  testWidgets('a refusal is shown verbatim and the token is kept for a retry', (t) async {
    await _pump(t, (_) async => '{"error":"That enrolment token has expired or was already used."}');
    await t.enterText(find.byType(TextField), 'tok-old');
    await t.tap(find.text('Enrol'));
    await t.pumpAndSettle();
    expect(find.text('That enrolment token has expired or was already used.'), findsOneWidget);
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, 'tok-old');
  });

  testWidgets('a privileged process that cannot be reached is a failure in its own words', (t) async {
    await _pump(t, (_) async => throw StateError('no ipc'));
    await t.enterText(find.byType(TextField), 'tok');
    await t.tap(find.text('Enrol'));
    await t.pumpAndSettle();
    expect(find.textContaining('no ipc'), findsOneWidget);
  });

  testWidgets('an empty token sends nothing', (t) async {
    var calls = 0;
    await _pump(t, (_) async {
      calls++;
      return '{"machineId":"m"}';
    });
    await t.tap(find.text('Enrol'));
    await t.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('no shipped string carries an em or en dash', (t) async {
    await _pump(t, (_) async => '{"error":"x"}');
    for (final w in t.widgetList<Text>(find.byType(Text))) {
      expect(w.data ?? '', isNot(matches(RegExp('[–—]'))));
    }
  });
}
