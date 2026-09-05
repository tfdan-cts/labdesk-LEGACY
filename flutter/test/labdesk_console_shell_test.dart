import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/machine_metrics.dart';
import 'package:flutter_hbb/labdesk/models/machine_state.dart';
import 'package:flutter_hbb/labdesk/models/machine_row.dart';
import 'package:flutter_hbb/labdesk/screens/console_shell.dart';
import 'package:flutter_hbb/labdesk/screens/settings_screen.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

/// The shell is what makes the console the whole interface: the client hands it
/// the application's own widgets for the sections that already work, and the
/// shell renders its own screens for the rest. Both halves are pinned here,
/// because getting either wrong means a section of the product goes missing.
Widget _wrap(Widget child) => MaterialApp(
      theme: C.theme(),
      home: Scaffold(body: child),
    );

void main() {
  _keyboardTests();
  group('ConsoleShell navigation', () {
    testWidgets('every section is offered in the sidebar', (tester) async {
      await tester.pumpWidget(_wrap(const ConsoleShell(machines: [])));

      for (final s in ConsoleSection.values) {
        expect(find.text(s.label), findsWidgets,
            reason: '${s.label} must be reachable; a section with no way to '
                'reach it is what this rebuild existed to fix');
      }
    });

    testWidgets('it opens on Connect, not on a per-machine section',
        (tester) async {
      await tester.pumpWidget(_wrap(const ConsoleShell(machines: [])));

      // Landing on a section that needs a machine would greet every launch
      // with "no machine selected".
      expect(ConsoleSection.connect.needsMachine, isFalse);
      expect(
        const ConsoleShell(machines: []).initialSection,
        ConsoleSection.connect,
      );
    });

    testWidgets('Connect, Fleet, This machine and Settings need no machine',
        (tester) async {
      for (final s in [
        ConsoleSection.connect,
        ConsoleSection.fleet,
        ConsoleSection.thisMachine,
        ConsoleSection.settings,
      ]) {
        expect(s.needsMachine, isFalse, reason: s.label);
      }
      for (final s in [
        ConsoleSection.terminal,
        ConsoleSection.actions,
      ]) {
        expect(s.needsMachine, isTrue, reason: s.label);
      }
    });
  });

  group('Fleet tabs', () {
    const rows = [
      MachineRow(id: '1', hostname: 'alpha', platform: 'Linux', status: LabDeskPeerStatus.online),
      MachineRow(id: '2', hostname: 'beta', platform: 'Windows', status: LabDeskPeerStatus.offline),
    ];

    testWidgets('Health is a tab inside Fleet and shows every machine at once',
        (tester) async {
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: rows,
        initialSection: ConsoleSection.fleet,
        healthFor: (id) => MachineHealth(machineId: id, connected: false),
      )));
      // The tab, and the machine table's own heading.
      expect(find.text('Machines'), findsWidgets);
      await tester.tap(find.text('Health'));
      await tester.pumpAndSettle();

      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      // Nothing has to be turned on for a figure to exist any more.
      expect(find.text('Monitor'), findsNothing);
    });

    testWidgets('the board is the fleet, not the peer list', (tester) async {
      // A console that has never connected to anything has an empty peer list,
      // and that is exactly the console a technician installs. Rendering the
      // peer list on the health board showed "No machines yet." over an
      // organization the server was answering with (homebox-devserver,
      // 2026-09-05).
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        healthMachines: rows,
        initialSection: ConsoleSection.fleet,
        healthFor: (id) => MachineHealth(machineId: id, connected: false),
      )));
      await tester.tap(find.text('Health'));
      await tester.pumpAndSettle();

      expect(find.text('No machines yet.'), findsNothing);
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
    });

    testWidgets('the figures come from the machine with no session open',
        (tester) async {
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: rows,
        initialSection: ConsoleSection.fleet,
        healthFor: (id) => MachineHealth(
          machineId: id,
          connected: false,
          state: const MachineState(
              status: 'online', cpuPct: 61, memPct: 44, worstDisk: 'failing'),
          remote: const MachineState(status: 'online', cpuPct: 61, memPct: 44)
              .metrics(),
        ),
      )));
      await tester.tap(find.text('Health'));
      await tester.pumpAndSettle();
      expect(find.text('61'), findsWidgets);
      expect(find.text('Drive failing'), findsWidgets);
    });
  });

  group('server profile control', () {
    const profiles = [
      ProfileRow(name: 'Lab network', host: 'a', relay: 'a', api: '', hasKey: true, active: true),
      ProfileRow(name: 'Personal Tailnet', host: 'b', relay: 'b', api: '', hasKey: true, active: false),
    ];

    testWidgets('the sidebar chevron opens the profiles and reports the pick',
        (tester) async {
      String? picked;
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        profiles: profiles,
        profileName: 'Lab network',
        onProfileSelected: (n) => picked = n,
      )));

      await tester.tap(find.text('Lab network'));
      await tester.pumpAndSettle();
      expect(find.text('Personal Tailnet'), findsOneWidget,
          reason: 'the other profile must be on offer once the control opens');

      await tester.tap(find.text('Personal Tailnet'));
      await tester.pumpAndSettle();
      expect(picked, 'Personal Tailnet');
    });

    testWidgets('with nothing to act on a pick, it is a label without a chevron',
        (tester) async {
      await tester.pumpWidget(_wrap(const ConsoleShell(
        machines: [],
        profiles: profiles,
        profileName: 'Lab network',
      )));
      await tester.tap(find.text('Lab network'));
      await tester.pumpAndSettle();
      expect(find.text('Personal Tailnet'), findsNothing);
    });
  });

  group('hosted sections', () {
    testWidgets('a hosted section renders the widget the client supplied',
        (tester) async {
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        hosted: {
          ConsoleSection.connect: (_) =>
              const Text('the client owns this', key: Key('hosted-connect')),
        },
      )));

      expect(find.byKey(const Key('hosted-connect')), findsOneWidget);
    });

    testWidgets('a section with no builder falls back to the console screen',
        (tester) async {
      // This is what keeps the design harness renderable with no client.
      await tester.pumpWidget(_wrap(const ConsoleShell(machines: [])));

      expect(find.byKey(const Key('hosted-connect')), findsNothing);
      expect(find.textContaining('part of the running client'), findsOneWidget);
    });

    testWidgets('switching sections switches which hosted widget shows',
        (tester) async {
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        hosted: {
          ConsoleSection.connect: (_) => const Text('CONNECT BODY'),
          ConsoleSection.settings: (_) => const Text('SETTINGS BODY'),
        },
      )));

      expect(find.text('CONNECT BODY'), findsOneWidget);
      expect(find.text('SETTINGS BODY'), findsNothing);

      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();

      expect(find.text('SETTINGS BODY'), findsOneWidget);
      expect(find.text('CONNECT BODY'), findsNothing);
    });

    testWidgets('a hosted body wins over the console\'s own screen',
        (tester) async {
      // Settings has a built-in screen. When the client supplies the real
      // settings page, that must be what renders, or the product would show a
      // reduced copy of its own settings.
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        initialSection: ConsoleSection.settings,
        hosted: {
          ConsoleSection.settings: (_) => const Text('REAL SETTINGS'),
        },
      )));

      expect(find.text('REAL SETTINGS'), findsOneWidget);
    });
  });

  group('refreshing reachability', () {
    // The peer list is where an operator reads whether a machine is up, and
    // reachability is polled, not pushed. Without a control to ask again, a
    // stale dot is indistinguishable from a machine that is really down, and
    // the only recourse is restarting the application. The old home screen had
    // this control; the console must not have lost it.
    testWidgets('Connect offers a refresh, and it calls back', (tester) async {
      var refreshed = 0;

      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        initialSection: ConsoleSection.connect,
        hosted: {
          ConsoleSection.connect: (_) => const Text('peer list'),
        },
        onRefresh: () => refreshed++,
      )));

      expect(find.text('Refresh'), findsOneWidget);
      await tester.tap(find.text('Refresh'));
      await tester.pump();

      expect(refreshed, 1);
    });

    testWidgets('Fleet keeps its refresh', (tester) async {
      var refreshed = 0;

      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        initialSection: ConsoleSection.fleet,
        onRefresh: () => refreshed++,
      )));

      await tester.tap(find.text('Refresh'));
      await tester.pump();

      expect(refreshed, 1);
    });

    testWidgets('a section that shows no reachability offers no refresh',
        (tester) async {
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        initialSection: ConsoleSection.terminal,
        onRefresh: () {},
      )));

      expect(find.text('Refresh'), findsNothing);
    });

    testWidgets('with nothing wired to refresh, no control is offered',
        (tester) async {
      await tester.pumpWidget(_wrap(const ConsoleShell(
        machines: [],
        initialSection: ConsoleSection.connect,
      )));

      expect(find.text('Refresh'), findsNothing);
    });
  });

  // A blind audit of fifteen rendered surfaces found Fleet was the one that
  // disagreed with the rest of the product: raw ids where every other surface
  // groups them, and a second set of words for the three states the same card
  // had already named. Both are pinned here, because both are the kind of
  // drift that returns the moment nobody is looking at two screens at once.
  group('Fleet speaks the product\'s language', () {
    const machines = [
      MachineRow(
        id: '914203771',
        alias: 'Build server',
        hostname: 'build-server',
        platform: 'Windows',
        status: LabDeskPeerStatus.online,
      ),
      MachineRow(
        id: '1117890352',
        alias: 'Spare laptop',
        hostname: 'spare-laptop',
        platform: 'Windows',
        status: LabDeskPeerStatus.offline,
      ),
      MachineRow(
        id: '168828561',
        alias: 'CTS Hosted Server',
        hostname: 'cts-hosted-server',
        platform: 'Linux',
        status: LabDeskPeerStatus.unknown,
      ),
    ];

    Future<void> openFleet(WidgetTester tester) async {
      // A desktop surface. The machine table is six columns wide; on the
      // 800x600 test default the name column is 74 pixels and every machine
      // name wraps, which is a measurement of the test window and not of the
      // screen.
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_wrap(const ConsoleShell(
        machines: machines,
        initialSection: ConsoleSection.fleet,
      )));
    }

    testWidgets('an id is printed through the one formatter the product has',
        (tester) async {
      await openFleet(tester);

      for (final m in machines) {
        expect(find.text(formatID(m.id)), findsOneWidget,
            reason: '${m.id} must be grouped the way Connect and the consent '
                'prompt group it');
        expect(find.text(m.id), findsNothing,
            reason: 'a raw run of digits here makes the same number look like '
                'a different field to the one on Connect');
      }
    });

    testWidgets('the ids are grouped in triplets, not merely reformatted',
        (tester) async {
      await openFleet(tester);

      // Guards the assertion above against a formatter that silently starts
      // returning its input: 914203771 has to reach the row as 914 203 771.
      expect(find.text('914 203 771'), findsOneWidget);
    });

    testWidgets('the three states are named once, and named Online, Offline '
        'and Unknown', (tester) async {
      await openFleet(tester);

      // Twice each: the count in the Reachability band, and the legend over
      // the machine list. Both are the same three states, so both say it the
      // same way.
      for (final word in ['Online', 'Offline', 'Unknown']) {
        expect(find.text(word), findsNWidgets(2),
            reason: '$word must be the word in the band and in the legend');
      }

      for (final other in [
        'reachable',
        'unreachable',
        'not checked',
        'Not yet checked',
      ]) {
        expect(find.text(other), findsNothing,
            reason: '"$other" is a second name for a state this screen has '
                'already named');
      }
    });
  });
}

// Appended: the sidebar is usable without a pointer.
void _keyboardTests() {
  group('keyboard navigation', () {
    testWidgets('Ctrl plus a digit opens that section', (tester) async {
      await tester.pumpWidget(_wrap(const ConsoleShell(machines: [])));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      // Fleet is the second section and the only one with a tab strip.
      expect(ConsoleSection.values[1], ConsoleSection.fleet);
      expect(find.text('Health'), findsOneWidget);
    });

    testWidgets('sidebar entries are focusable buttons that report selection',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(const ConsoleShell(machines: [])));
      Finder nav(String label) => find.byWidgetPredicate((w) =>
          w is Semantics && w.properties.button == true && w.properties.label == label);
      final connect = tester.getSemantics(nav(ConsoleSection.connect.label));
      final fleet = tester.getSemantics(nav(ConsoleSection.fleet.label));
      expect(connect.hasFlag(SemanticsFlag.isSelected), isTrue);
      expect(fleet.hasFlag(SemanticsFlag.isSelected), isFalse);
      expect(fleet.hasFlag(SemanticsFlag.isFocusable), isTrue);
      expect(fleet.hasFlag(SemanticsFlag.isButton), isTrue);
      handle.dispose();
    });
  });
}
