import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/machine_metrics.dart';
import 'package:flutter_hbb/labdesk/models/machine_state.dart';
import 'package:flutter_hbb/labdesk/models/machine_row.dart';
import 'package:flutter_hbb/labdesk/models/organization_context.dart';
import 'package:flutter_hbb/labdesk/screens/actions_screen.dart';
import 'package:flutter_hbb/labdesk/screens/fleet_console.dart';
import 'package:flutter_hbb/labdesk/screens/health_board.dart';
import 'package:flutter_hbb/labdesk/screens/home_dashboard.dart';
import 'package:flutter_hbb/labdesk/screens/help_screen.dart';
import 'package:flutter_hbb/labdesk/screens/terminal_screen.dart';
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

Finder _nav(ConsoleSection section) => find.byWidgetPredicate((widget) =>
    widget is Semantics &&
    widget.properties.button == true &&
    widget.properties.label == section.label);

void main() {
  testWidgets('Help opens the current feature manual without a machine action',
      (tester) async {
    await tester.pumpWidget(_wrap(const ConsoleShell(
        machines: [], initialSection: ConsoleSection.network)));
    await tester.tap(find.byTooltip('Help for this page'));
    await tester.pumpAndSettle();
    expect(tester.widget<HelpScreen>(find.byType(HelpScreen)).initialTopic,
        'labnets');
    expect(find.byKey(const ValueKey('help-search')), findsOneWidget);
    await tester.tap(_nav(ConsoleSection.home));
    await tester.pumpAndSettle();
    await tester.tap(_nav(ConsoleSection.help));
    await tester.pumpAndSettle();
    expect(find.byType(HelpScreen), findsOneWidget);
  });

  testWidgets('context changes discard hosted feature drafts', (tester) async {
    Widget shell(String contextKey) => _wrap(ConsoleShell(
          machines: [],
          dashboardContextKey: contextKey,
          initialSection: ConsoleSection.network,
          hosted: {
            ConsoleSection.network: (_) =>
                const TextField(key: ValueKey('draft'))
          },
        ));
    await tester.pumpWidget(shell('1/account-a/org-a'));
    await tester.enterText(
        find.byKey(const ValueKey('draft')), 'Private draft A');
    await tester.pumpWidget(shell('2/account-a/org-b'));
    await tester.pumpAndSettle();
    expect(find.text('Private draft A'), findsNothing);
  });

  _keyboardTests();
  _contextTests();
  _machineRouteTests();
  group('ConsoleShell navigation', () {
    testWidgets(
        'the primary sidebar matches the approved information hierarchy',
        (tester) async {
      await tester.pumpWidget(_wrap(const ConsoleShell(machines: [])));
      expect(primaryConsoleSections, [
        ConsoleSection.home,
        ConsoleSection.fleet,
        ConsoleSection.network,
        ConsoleSection.thisMachine,
      ]);
      expect(primaryConsoleSections.map((s) => s.label),
          ['Home', 'Fleet', 'Labnets', 'This device']);
      for (final section in primaryConsoleSections) {
        expect(_nav(section), findsOneWidget);
      }
      for (final section in [
        ConsoleSection.connect,
        ConsoleSection.sessions,
        ConsoleSection.settings
      ]) {
        expect(_nav(section), findsOneWidget);
      }
      for (final section in [
        ConsoleSection.tools,
        ConsoleSection.terminal,
        ConsoleSection.actions,
        ConsoleSection.automation,
        ConsoleSection.machineHealth,
        ConsoleSection.diagnostics
      ]) {
        expect(_nav(section), findsNothing,
            reason:
                'machine and fleet capabilities belong inside their context');
      }
    });

    testWidgets('Home opens without requiring a selected machine',
        (tester) async {
      await tester.pumpWidget(_wrap(const ConsoleShell(machines: [])));
      expect(ConsoleSection.home.needsMachine, isFalse);
      expect(
          const ConsoleShell(machines: []).initialSection, ConsoleSection.home);
      expect(find.byType(HomeDashboard), findsOneWidget);
      expect(find.textContaining('part of the running client'), findsNothing);
    });

    testWidgets('primary and general sections need no selected machine',
        (tester) async {
      for (final s in [
        ...primaryConsoleSections,
        ConsoleSection.connect,
        ConsoleSection.sessions,
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
      MachineRow(
          id: '1',
          hostname: 'alpha',
          platform: 'Linux',
          status: LabDeskPeerStatus.online),
      MachineRow(
          id: '2',
          hostname: 'beta',
          platform: 'Windows',
          status: LabDeskPeerStatus.offline),
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
      final state = MachineState(
        status: 'online',
        seenAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 8,
        flushSeconds: 60,
        cpuPct: 61,
        memPct: 44,
        worstDisk: 'failing',
      );
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: rows,
        initialSection: ConsoleSection.fleet,
        healthFor: (id) => MachineHealth(
          machineId: id,
          connected: false,
          state: state,
          remote: state.metrics(),
        ),
      )));
      await tester.tap(find.text('Health'));
      await tester.pumpAndSettle();
      expect(find.text('61 %'), findsWidgets);
      expect(find.text('Drive failing'), findsWidgets);
      expect(find.textContaining('Current readings.'), findsWidgets);
    });
  });

  group('server profile control', () {
    const profiles = [
      ProfileRow(
          name: 'Lab network',
          host: 'a',
          relay: 'a',
          api: '',
          hasKey: true,
          active: true),
      ProfileRow(
          name: 'Personal Tailnet',
          host: 'b',
          relay: 'b',
          api: '',
          hasKey: true,
          active: false),
    ];

    testWidgets('profiles stay in Settings and selecting one reports the pick',
        (tester) async {
      String? picked;
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        profiles: profiles,
        profileName: 'Lab network',
        onProfileSelected: (name) => picked = name,
      )));
      expect(find.text('Lab network'), findsNothing);
      expect(find.text('Personal Tailnet'), findsNothing);
      await tester.tap(_nav(ConsoleSection.settings));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Lab network'), findsOneWidget);
      await tester.tap(find.text('Personal Tailnet'));
      await tester.pumpAndSettle();
      expect(picked, 'Personal Tailnet');
      await tester.tap(_nav(ConsoleSection.home));
      await tester.pumpAndSettle();
      expect(find.text('Lab network'), findsNothing);
      expect(find.text('Personal Tailnet'), findsNothing);
    });

    testWidgets(
        'without an activation callback Settings preserves profile data',
        (tester) async {
      await tester.pumpWidget(_wrap(const ConsoleShell(
        machines: [],
        profiles: profiles,
        profileName: 'Lab network',
        initialSection: ConsoleSection.settings,
      )));
      await tester.tap(find.text('Personal Tailnet'));
      await tester.pumpAndSettle();
      final settings =
          tester.widget<SettingsScreen>(find.byType(SettingsScreen));
      expect(settings.onActivate, isNull);
      expect(
          settings.profiles.where((p) => p.active).single.name, 'Lab network');
    });
  });

  group('hosted sections', () {
    testWidgets('a hosted section renders the widget the client supplied',
        (tester) async {
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        initialSection: ConsoleSection.connect,
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
      await tester.pumpWidget(_wrap(const ConsoleShell(
          machines: [], initialSection: ConsoleSection.connect)));

      expect(find.byKey(const Key('hosted-connect')), findsNothing);
      expect(find.textContaining('part of the running client'), findsOneWidget);
    });

    testWidgets('switching sections switches which hosted widget shows',
        (tester) async {
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        initialSection: ConsoleSection.connect,
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

    testWidgets('Home refresh reports the callback', (tester) async {
      var refreshed = 0;
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        onRefresh: () => refreshed++,
      )));
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

    testWidgets(
        'the three states are named once, and named Online, Offline '
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
    testWidgets('Ctrl+1 through Ctrl+4 follow primary navigation order',
        (tester) async {
      final requested = <ConsoleSection>[];
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        initialSection: ConsoleSection.connect,
        onSectionChanged: requested.add,
        hosted: {
          for (final section in primaryConsoleSections)
            section: (_) => Text('BODY ${section.name}'),
        },
      )));
      final digits = [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4
      ];
      for (var i = 0; i < digits.length; i++) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(digits[i]);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.text('BODY ${primaryConsoleSections[i].name}'),
            findsOneWidget);
      }
      expect(requested, primaryConsoleSections);
    });

    testWidgets('sidebar entries are focusable buttons that report selection',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(const ConsoleShell(machines: [])));
      Finder nav(String label) => find.byWidgetPredicate((w) =>
          w is Semantics &&
          w.properties.button == true &&
          w.properties.label == label);
      final home = tester.getSemantics(nav(ConsoleSection.home.label));
      final fleet = tester.getSemantics(nav(ConsoleSection.fleet.label));
      expect(home.hasFlag(SemanticsFlag.isSelected), isTrue);
      expect(fleet.hasFlag(SemanticsFlag.isSelected), isFalse);
      expect(fleet.hasFlag(SemanticsFlag.isFocusable), isTrue);
      expect(fleet.hasFlag(SemanticsFlag.isButton), isTrue);
      handle.dispose();
    });
  });
}

void _contextTests() {
  const organizations = [
    OrganizationSummary(id: 'a', name: 'Team Alpha', role: 'owner'),
    OrganizationSummary(id: 'b', name: 'Team Beta', role: 'member'),
  ];
  testWidgets('organization, account and Terms controls report their callbacks',
      (tester) async {
    String? organization;
    var accounts = 0;
    var terms = 0;
    await tester.pumpWidget(_wrap(ConsoleShell(
      machines: const [],
      organizations: organizations,
      activeOrganizationId: 'a',
      onOrganizationSelected: (id) => organization = id,
      accountName: 'Jordan',
      accountDescription: 'jordan@example.test',
      onAccountPressed: () => accounts++,
      onTermsPressed: () => terms++,
    )));
    expect(find.text('Organization'), findsOneWidget);
    expect(find.text('jordan@example.test'), findsOneWidget);
    await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'Team Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Team Beta').last);
    await tester.pumpAndSettle();
    expect(organization, 'b');
    await tester.tap(find.text('Jordan'));
    await tester.pump();
    expect(accounts, 1);
    await tester.tap(find.text('Terms of Service'));
    await tester.pump();
    expect(terms, 1);
  });

  for (final size in [const Size(800, 600), const Size(1400, 900)]) {
    testWidgets('primary navigation and utilities render at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_wrap(ConsoleShell(
        machines: const [],
        organizations: organizations,
        activeOrganizationId: 'a',
        onOrganizationSelected: (_) {},
        accountName: 'Jordan',
        onAccountPressed: () {},
        onTermsPressed: () {},
      )));
      await tester.pumpAndSettle();
      for (final section in [
        ...primaryConsoleSections,
        ConsoleSection.connect,
        ConsoleSection.sessions,
        ConsoleSection.settings
      ]) {
        await tester.ensureVisible(_nav(section));
        await tester.tap(_nav(section));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: '${section.label} at $size');
        expect(_nav(section).hitTestable(), findsOneWidget);
        expect(find.text('Terms of Service').hitTestable(), findsOneWidget);
      }
    });
  }
}

void _machineRouteTests() {
  const rows = [
    MachineRow(
        id: '1',
        hostname: 'alpha',
        platform: 'Linux',
        status: LabDeskPeerStatus.online),
    MachineRow(
        id: '2',
        hostname: 'beta',
        platform: 'Windows',
        status: LabDeskPeerStatus.offline),
  ];

  testWidgets('Fleet retains Machines, Health, hosted Jobs and Automation',
      (tester) async {
    final changes = <ConsoleSection>[];
    await tester.pumpWidget(_wrap(ConsoleShell(
      machines: rows,
      initialSection: ConsoleSection.fleet,
      onSectionChanged: changes.add,
      hosted: {
        ConsoleSection.tools: (_) => const Text('HOSTED JOBS'),
        ConsoleSection.automation: (_) => const Text('HOSTED AUTOMATION'),
      },
    )));
    expect(find.byType(FleetConsole), findsOneWidget);
    for (final title in ['Machines', 'Health', 'Jobs', 'Automation']) {
      expect(find.widgetWithText(Tab, title), findsOneWidget);
    }
    await tester.tap(find.widgetWithText(Tab, 'Health'));
    await tester.pumpAndSettle();
    expect(find.byType(HealthBoard), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, 'Jobs'));
    await tester.pumpAndSettle();
    expect(find.text('HOSTED JOBS'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, 'Automation'));
    await tester.pumpAndSettle();
    expect(find.text('HOSTED AUTOMATION'), findsOneWidget);
    expect(changes.last, ConsoleSection.automation);
    await tester.tap(find.widgetWithText(Tab, 'Machines'));
    await tester.pumpAndSettle();
    expect(find.byType(FleetConsole), findsOneWidget);
    expect(changes.last, ConsoleSection.fleet);
  });

  testWidgets(
      'selected machine routes retain the machine and hosted capabilities',
      (tester) async {
    final selected = <String>[];
    final changes = <ConsoleSection>[];
    await tester.pumpWidget(_wrap(ConsoleShell(
      machines: rows,
      initialSection: ConsoleSection.fleet,
      onMachineSelected: selected.add,
      onSectionChanged: changes.add,
      machineHealthFooter: (id) => Text('Reporting policy for $id'),
      connectedIds: const {'1'},
      terminalIds: const {},
      hosted: {
        ConsoleSection.tools: (_) => const Text('MACHINE TOOLS'),
        ConsoleSection.diagnostics: (_) => const Text('MACHINE NETWORK'),
      },
    )));
    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();
    expect(selected, ['1']);
    expect(tester.widget<ActionsScreen>(find.byType(ActionsScreen)).machine!.id,
        '1');
    for (final title in [
      'Overview',
      'Health',
      'Terminal',
      'Tools',
      'Network'
    ]) {
      expect(find.widgetWithText(TextButton, title), findsOneWidget);
    }
    await tester.tap(find.widgetWithText(TextButton, 'Health'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<HealthBoard>(find.byType(HealthBoard))
            .machines
            .map((m) => m.id),
        ['1']);
    expect(changes.last, ConsoleSection.machineHealth);
    expect(tester.widget<HealthBoard>(find.byType(HealthBoard)).footer,
        isA<Text>());
    expect(
        (tester.widget<HealthBoard>(find.byType(HealthBoard)).footer! as Text)
            .data,
        'Reporting policy for 1');
    await tester.tap(find.widgetWithText(TextButton, 'Terminal'));
    await tester.pumpAndSettle();
    final terminal = tester.widget<TerminalScreen>(find.byType(TerminalScreen));
    expect(terminal.machine!.id, '1');
    expect(terminal.connected, isFalse,
        reason: 'a desktop connection cannot imply terminal capability');
    for (final route in [
      ('Tools', ConsoleSection.tools, 'MACHINE TOOLS'),
      ('Network', ConsoleSection.diagnostics, 'MACHINE NETWORK'),
    ]) {
      final tab = find.widgetWithText(TextButton, route.$1);
      await tester.ensureVisible(tab);
      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(find.text(route.$3), findsOneWidget);
      expect(changes.last, route.$2);
    }
    final overview = find.widgetWithText(TextButton, 'Overview');
    await tester.ensureVisible(overview);
    await tester.tap(overview);
    await tester.pumpAndSettle();
    expect(tester.widget<ActionsScreen>(find.byType(ActionsScreen)).machine!.id,
        '1');
    await tester.tap(find.text('All machines'));
    await tester.pumpAndSettle();
    expect(find.byType(FleetConsole), findsOneWidget);
    expect(find.byType(ActionsScreen), findsNothing);
  });

  testWidgets('changing account or organization clears a selected peer',
      (tester) async {
    Widget shell(String contextKey) => _wrap(ConsoleShell(
          machines: rows,
          initialSection: ConsoleSection.fleet,
          dashboardContextKey: contextKey,
        ));
    await tester.pumpWidget(shell('account-a/org-a'));
    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Terminal'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TerminalScreen>(find.byType(TerminalScreen)).machine!.id,
        '1');
    await tester.pumpWidget(shell('account-b/org-b'));
    await tester.pumpAndSettle();
    expect(tester.widget<TerminalScreen>(find.byType(TerminalScreen)).machine,
        isNull);
    expect(find.text('Selected'), findsNothing);
  });

  testWidgets('changing context resets the Fleet tab to Machines',
      (tester) async {
    Widget shell(String contextKey) => _wrap(ConsoleShell(
          machines: rows,
          initialSection: ConsoleSection.fleet,
          dashboardContextKey: contextKey,
        ));
    await tester.pumpWidget(shell('account-a/org-a'));
    await tester.tap(find.widgetWithText(Tab, 'Health'));
    await tester.pumpAndSettle();
    expect(find.byType(HealthBoard), findsOneWidget);
    await tester.pumpWidget(shell('account-a/org-b'));
    await tester.pumpAndSettle();
    expect(find.byType(FleetConsole), findsOneWidget);
    expect(find.byType(HealthBoard), findsNothing);
  });
}
