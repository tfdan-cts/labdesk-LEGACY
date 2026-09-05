import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/automation_models.dart';
import 'package:flutter_hbb/labdesk/models/machine_row.dart';
import 'package:flutter_hbb/labdesk/screens/automation_screen.dart';
import 'package:flutter_hbb/labdesk/services/automation_engine.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

/// The screen's job is to make a rule readable before it runs, and to say out
/// loud that nothing here runs unless the console is open. Both are pinned
/// here, along with the three callbacks the client drives it with.

const _machines = [
  MachineRow(
      id: '1',
      hostname: 'workshop',
      platform: 'Linux',
      status: LabDeskPeerStatus.online),
  MachineRow(
      id: '2',
      hostname: 'nas',
      platform: 'Linux',
      status: LabDeskPeerStatus.offline),
];

Widget _wrap(Widget child) => MaterialApp(
      theme: C.theme(),
      home: Scaffold(body: child),
    );

Rule _rule({
  String id = 'r1',
  String name = 'Wake the NAS',
  AutomationTrigger trigger = const WentOffline(forMinutes: 5),
  AutomationAction action = const Notify(message: 'nas is down'),
  List<String> targets = const ['1'],
  bool enabled = true,
}) =>
    Rule(
      id: id,
      name: name,
      trigger: trigger,
      action: action,
      targets: targets,
      enabled: enabled,
    );

/// A console window, not a phone. The editor is a tall form, and on the default
/// 800x600 test surface half of it sits past the bottom of the world where
/// nothing hit tests.
Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(1400, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_wrap(child));
}

void main() {
  testWidgets('it says rules only run while the console is open',
      (tester) async {
    await _pump(tester, const AutomationScreen(rules: []));

    expect(
      find.textContaining('only while LabDesk is open'),
      findsOneWidget,
      reason: 'an operator arriving from any other automation product will '
          'assume a server is running these unless the screen says otherwise',
    );
    expect(find.textContaining('No rules yet'), findsOneWidget);
  });

  testWidgets('every rule renders as a sentence naming the machine',
      (tester) async {
    await _pump(tester, AutomationScreen(
      rules: [
        _rule(),
        _rule(
            id: 'r2',
            name: 'Nightly report',
            trigger: const Schedule.atTime(hour: 3, minute: 15),
            action: const RunCommand(command: 'df -h'),
            targets: const [Rule.allTargets]),
        _rule(
            id: 'r3',
            name: 'Hot disk',
            trigger: const MetricAbove(
                metric: AutoMetric.disk, threshold: 90, forMinutes: 10),
            action: const WakeOnLan(),
            targets: const ['2']),
      ],
      machines: _machines,
    ));

    expect(
        find.text('When workshop goes offline for 5 minutes → '
            'notify: "nas is down"'),
        findsOneWidget);
    expect(
        find.text('Every day at 03:15, on any machine → run "df -h"'),
        findsOneWidget);
    expect(
        find.text('When nas\'s disk use is above 90% for 10 minutes → '
            'send Wake-on-LAN'),
        findsOneWidget);
    expect(find.text('Wake the NAS'), findsOneWidget);
  });

  testWidgets('a rule that has never fired says so, and one that has says when',
      (tester) async {
    final now = DateTime(2026, 3, 1, 12, 0);
    await _pump(tester, AutomationScreen(
      rules: [_rule(), _rule(id: 'r2', name: 'Quiet one')],
      machines: _machines,
      now: now,
      log: [
        RunLogEntry(
          firingId: 'f1',
          ruleId: 'r1',
          ruleName: 'Wake the NAS',
          machineId: '1',
          action: const Notify(message: 'nas is down'),
          at: now.subtract(const Duration(minutes: 4)),
          ok: true,
        ),
      ],
    ));

    expect(find.text('Fired 4m ago'), findsOneWidget);
    expect(find.text('Never fired'), findsOneWidget);
    expect(find.text('ok'), findsOneWidget);
  });

  testWidgets('an outcome nobody has reported reads as running, not as failed',
      (tester) async {
    await _pump(tester, AutomationScreen(
      rules: [_rule()],
      machines: _machines,
      log: [
        RunLogEntry(
          firingId: 'f1',
          ruleId: 'r1',
          ruleName: 'Wake the NAS',
          machineId: '1',
          action: const RunCommand(command: 'uptime'),
          at: DateTime(2026, 3, 1, 12, 0),
        ),
      ],
    ));

    expect(find.text('running'), findsOneWidget);
    expect(find.text('failed'), findsNothing);
    expect(find.textContaining('workshop'), findsWidgets);
  });

  testWidgets('the toggle reports the rule and the new state', (tester) async {
    String? id;
    bool? value;
    await _pump(tester, AutomationScreen(
      rules: [_rule()],
      machines: _machines,
      onToggle: (r, v) {
        id = r;
        value = v;
      },
    ));

    await tester.tap(find.byType(LdToggle));
    await tester.pumpAndSettle();

    expect(id, 'r1');
    expect(value, isFalse, reason: 'the rule was enabled, so the tap turns it '
        'off');
  });

  testWidgets('Run now asks for that rule by id', (tester) async {
    String? ran;
    await _pump(tester, AutomationScreen(
      rules: [_rule()],
      machines: _machines,
      onRunNow: (r) => ran = r,
    ));

    await tester.tap(find.text('Run now'));
    await tester.pumpAndSettle();

    expect(ran, 'r1');
  });

  testWidgets('adding a rule through the editor saves the whole list',
      (tester) async {
    List<Rule>? saved;
    await _pump(tester, AutomationScreen(
      rules: [_rule()],
      machines: _machines,
      onSave: (rules) => saved = rules,
    ));

    await tester.tap(find.text('New rule'));
    await tester.pumpAndSettle();
    expect(find.text('New rule'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, 'Reboot reminder');
    await tester.pumpAndSettle();

    // Uptime above 7 days, and notify.
    await tester.tap(find.text('Uptime above'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notify'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save rule'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.length, 2, reason: 'the existing rule is kept');
    final added = saved!.last;
    expect(added.name, 'Reboot reminder');
    expect(added.trigger, const UptimeAbove(days: 7));
    expect(added.action, isA<Notify>());
    expect(added.enabled, isTrue);
    // The editor closes once the list is handed back.
    expect(find.text('Save rule'), findsNothing);
  });

  testWidgets('the editor previews the sentence as it is written',
      (tester) async {
    await _pump(tester, AutomationScreen(
      rules: const [],
      machines: _machines,
      onSave: (_) {},
    ));

    await tester.tap(find.text('New rule'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Goes offline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wake-on-LAN'));
    await tester.pumpAndSettle();

    expect(
      find.text('When any machine goes offline for 5 minutes → '
          'send Wake-on-LAN'),
      findsOneWidget,
      reason: 'the operator should read the rule they are writing, not infer '
          'it from a form',
    );
  });

  testWidgets('editing an existing rule keeps its id and offers Delete',
      (tester) async {
    List<Rule>? saved;
    await _pump(tester, AutomationScreen(
      rules: [_rule(), _rule(id: 'r2', name: 'Other')],
      machines: _machines,
      onSave: (rules) => saved = rules,
    ));

    await tester.tap(find.text('Wake the NAS'));
    await tester.pumpAndSettle();
    expect(find.text('Edit rule'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Renamed');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save rule'));
    await tester.pumpAndSettle();

    expect(saved!.length, 2, reason: 'an edit replaces, it does not append');
    expect(saved!.first.id, 'r1');
    expect(saved!.first.name, 'Renamed');
    expect(saved!.first.trigger, const WentOffline(forMinutes: 5));
  });

  testWidgets('Delete removes only that rule', (tester) async {
    List<Rule>? saved;
    await _pump(tester, AutomationScreen(
      rules: [_rule(), _rule(id: 'r2', name: 'Other')],
      machines: _machines,
      onSave: (rules) => saved = rules,
    ));

    await tester.tap(find.text('Wake the NAS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(saved!.map((r) => r.id), ['r2']);
  });

  testWidgets('with no save callback the editor is not offered at all',
      (tester) async {
    await _pump(tester, AutomationScreen(
      rules: [_rule()],
      machines: _machines,
    ));

    // A control that opens nothing is worse than no control.
    final button = tester.widget<GhostButton>(
      find.ancestor(
        of: find.text('New rule'),
        matching: find.byType(GhostButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('the editor names which machines a metric rule can read',
      (tester) async {
    await _pump(tester, AutomationScreen(
      rules: const [],
      machines: _machines,
      onSave: (_) {},
    ));

    await tester.tap(find.text('New rule'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Metric above'));
    await tester.pumpAndSettle();

    expect(find.textContaining('reported on its flush'), findsOneWidget);
    expect(find.text('workshop'), findsWidgets);
  });
}
