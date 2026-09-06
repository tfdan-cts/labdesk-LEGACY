import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/automation_models.dart';
import 'package:flutter_hbb/labdesk/models/automation_presets.dart';
import 'package:flutter_hbb/labdesk/screens/automation_screen.dart';

/// The technician presets. A preset is a ready-made rule and nothing else:
/// applying one drops a real rule into the list, which is then edited, switched
/// and deleted like any other.
Future<void> _pump(WidgetTester t, Widget w) => t.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 1100, height: 900, child: w)),
    ));

void main() {
  test('every preset builds a rule that survives the store', () {
    for (final p in AutomationPreset.all) {
      final rule = p.toRule('r-${p.id}');
      expect(rule.name, p.title);
      expect(rule.enabled, isTrue);
      expect(rule.targetsAll, isTrue);
      final back = decodeRules(encodeRules([rule])).single;
      expect(back.trigger, rule.trigger);
      expect(back.action, rule.action);
      expect(back.cooldown, rule.cooldown);
    }
  });

  testWidgets('adding a preset hands the client a rule, and it then reads as added',
      (t) async {
    AutomationPreset? applied;
    await _pump(
      t,
      AutomationScreen(
        rules: const [],
        onSave: (_) {},
        onApplyPreset: (p) => applied = p,
      ),
    );
    expect(find.text('Ready-made rules'), findsOneWidget);
    expect(find.text('Offline for ten minutes'), findsOneWidget);

    // The first preset in the list is the first Add.
    await t.tap(find.text('Add').first);
    await t.pumpAndSettle();
    expect(applied?.id, 'disk_nearly_full');

    // With its rule in the list the preset is not offered a second time.
    await _pump(
      t,
      AutomationScreen(
        rules: [AutomationPreset.all.first.toRule('r1')],
        onSave: (_) {},
        onApplyPreset: (p) => applied = p,
      ),
    );
    expect(find.text('Added'), findsWidgets);
  });
}
