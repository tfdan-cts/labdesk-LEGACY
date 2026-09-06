import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../charts/reachability_chart.dart';
import '../models/machine_metrics.dart';
import '../models/machine_row.dart';
import '../models/dashboard_layout.dart';
import '../models/organization_context.dart';
import '../theme/console_theme.dart';
import '../theme/ld_icons.dart';
import 'actions_screen.dart';
import 'fleet_console.dart';
import 'health_board.dart';
import 'home_dashboard.dart';
import 'help_screen.dart';
import 'settings_screen.dart';
import 'terminal_screen.dart';

enum ConsoleSection {
  home,
  help,
  connect,
  fleet,
  sessions,
  terminal,
  tools,
  automation,
  actions,
  network,
  diagnostics,
  machineHealth,
  thisMachine,
  settings,
}

/// The two views of the fleet. Health used to be a section of its own that
/// showed one machine, chosen on Fleet first; it is a tab here so the whole
/// fleet's figures sit beside the reachability table they belong with.
enum FleetTab { machines, health, jobs, automation }

const primaryConsoleSections = [
  ConsoleSection.home,
  ConsoleSection.fleet,
  ConsoleSection.network,
  ConsoleSection.thisMachine,
];

extension ConsoleSectionInfo on ConsoleSection {
  String get label => switch (this) {
        ConsoleSection.home => 'Home',
        ConsoleSection.help => 'Help',
        ConsoleSection.connect => 'Connect',
        ConsoleSection.thisMachine => 'This device',
        ConsoleSection.fleet => 'Fleet',
        ConsoleSection.sessions => 'Sessions',
        ConsoleSection.terminal => 'Terminal',
        ConsoleSection.tools => 'Tools',
        ConsoleSection.automation => 'Automation',
        ConsoleSection.actions => 'Actions',
        ConsoleSection.network => 'Labnets',
        ConsoleSection.diagnostics => 'Network',
        ConsoleSection.machineHealth => 'Health',
        ConsoleSection.settings => 'Settings',
      };

  String get glyph => switch (this) {
        ConsoleSection.home => LdIcons.home,
        ConsoleSection.help => LdIcons.info,
        ConsoleSection.connect => LdIcons.connect,
        ConsoleSection.thisMachine => LdIcons.machine,
        ConsoleSection.fleet => LdIcons.fleet,
        ConsoleSection.sessions => LdIcons.display,
        ConsoleSection.tools => LdIcons.actions,
        ConsoleSection.automation => LdIcons.refresh,
        ConsoleSection.terminal => LdIcons.terminal,
        ConsoleSection.actions => LdIcons.actions,
        ConsoleSection.network => LdIcons.group,
        ConsoleSection.diagnostics => LdIcons.group,
        ConsoleSection.machineHealth => LdIcons.machine,
        ConsoleSection.settings => LdIcons.settings,
      };

  /// Sections that act on one machine show which machine in the title bar, and
  /// prompt to pick one when none is selected.
  bool get needsMachine => switch (this) {
        ConsoleSection.help ||
        ConsoleSection.home ||
        ConsoleSection.connect ||
        ConsoleSection.thisMachine ||
        ConsoleSection.fleet ||
        ConsoleSection.sessions ||
        ConsoleSection.tools ||
        ConsoleSection.automation ||
        ConsoleSection.network ||
        ConsoleSection.settings =>
          false,
        _ => true,
      };
}

/// Carries a request to move the console, and fires every time one is made.
///
/// A plain ValueNotifier only notifies when the value changes, so asking for
/// the same section twice is silently dropped. "Change how this machine is
/// secured" asks for Settings, and after the first time the console would
/// never move again.
class ConsoleSectionRequest extends ValueNotifier<ConsoleSection> {
  ConsoleSectionRequest(super.value);

  void request(ConsoleSection section) {
    if (value == section) {
      notifyListeners();
    } else {
      value = section;
    }
  }
}

/// One nested entry under a section, described by the client.
///
/// Settings has eight pages of its own. Rendering the client's settings widget
/// whole put a second navigation rail beside the console's, which is two
/// sidebars for one interface. The client passes the pages up instead and the
/// console nests them in its own sidebar, so there is one place to navigate.
class ConsoleSubItem {
  const ConsoleSubItem({required this.id, required this.label, this.icon});

  final String id;
  final String label;
  final IconData? icon;
}

/// The console: navigation, the selected machine, and the section bodies.
///
/// Owns no data of its own. Everything is passed in, so the same shell renders
/// in the design harness against fixtures and in the client against the live
/// client state.
class ConsoleShell extends StatefulWidget {
  const ConsoleShell({
    super.key,
    required this.machines,
    this.healthMachines,
    this.samples = const [],
    this.profiles = const [],
    this.profileName = 'Default',
    this.onProfileSelected,
    this.isRefreshing = false,
    this.isLoading = false,
    this.lastRefreshed,
    this.onRefresh,
    this.now,
    this.healthFor,
    this.terminalLines = const [],
    this.terminalLinesFor,
    this.connectedIds = const {},
    this.terminalIds,
    this.onRunAction,
    this.onTerminalSubmit,
    this.initialSection = ConsoleSection.home,
    this.organizations = const [],
    this.activeOrganizationId,
    this.onOrganizationSelected,
    this.accountName = 'Signed out',
    this.accountDescription,
    this.onAccountPressed,
    this.dashboardError,
    this.dashboardLayout,
    this.onSaveDashboard,
    this.dashboardContextKey = 'local',
    this.fleets = const [],
    this.machineFleetIds = const {},
    this.onMachineSelected,
    this.onTermsPressed,
    this.machineHealthFooter,
    this.hosted = const {},
    this.sectionRequest,
    this.subItems = const {},
    this.selectedSubItem,
    this.onSubItemSelected,
    this.onSectionChanged,
  });

  final List<MachineRow> machines;
  final List<OrganizationSummary> organizations;
  final String? activeOrganizationId;
  final ValueChanged<String>? onOrganizationSelected;
  final String accountName;
  final String? accountDescription;
  final VoidCallback? onAccountPressed;
  final String? dashboardError;
  final DashboardLayout? dashboardLayout;
  final Future<void> Function(DashboardLayout)? onSaveDashboard;
  final String dashboardContextKey;
  final List<DashboardFleet> fleets;
  final Map<String, Set<String>> machineFleetIds;
  final ValueChanged<String>? onMachineSelected;
  final VoidCallback? onTermsPressed;
  final Widget Function(String machineId)? machineHealthFooter;

  /// What the Health tab accounts for, when that is not the same list.
  ///
  /// [machines] is the technician's own peer list, which is what the Machines
  /// tab is. The organization's fleet is a different set: on a console that has
  /// never connected to anything the peer list is empty while lab-desk.net is
  /// answering with the whole fleet, and the board said "No machines yet." over
  /// a fleet that was reporting figures (homebox-devserver, 2026-09-05). Null
  /// falls back to [machines], so the design harness is unaffected.
  final List<MachineRow>? healthMachines;
  final List<ReachSample> samples;
  final List<ProfileRow> profiles;
  final String profileName;

  /// The operator picked another server profile in the sidebar. Null leaves
  /// the control as a label: a chevron that opens nothing is worse than none.
  final ValueChanged<String>? onProfileSelected;

  final bool isRefreshing;
  final bool isLoading;
  final DateTime? lastRefreshed;
  final VoidCallback? onRefresh;
  final DateTime? now;

  /// Health for a machine, resolved lazily so the shell holds no state.
  final MachineHealth Function(String machineId)? healthFor;

  final List<TerminalLine> terminalLines;

  /// Terminal output for one machine. When supplied it wins over
  /// [terminalLines], which has no way to keep two machines' shells apart.
  final List<TerminalLine> Function(String machineId)? terminalLinesFor;

  final Set<String> connectedIds;

  /// Machines with a terminal session open. The Terminal screen keys on this
  /// rather than [connectedIds], because a desktop session alone gives it no
  /// shell to run commands in. Null means "same as connectedIds".
  final Set<String>? terminalIds;

  final void Function(String machineId, MachineAction action)? onRunAction;
  final void Function(String machineId, String command)? onTerminalSubmit;
  final ConsoleSection initialSection;

  /// Sections whose body the caller supplies.
  ///
  /// The client mounts the application's own widgets here, which is what lets
  /// the console own the whole interface without this file importing the FFI.
  /// A section with no builder falls back to the console's own screen, which is
  /// what keeps the design harness renderable with no client at all.
  final Map<ConsoleSection, WidgetBuilder> hosted;

  /// Lets the client move the console to a section.
  ///
  /// Some controls have always meant "go to settings" - changing how this
  /// machine is secured, for one. Without this they would open a second
  /// settings surface in a separate tab, which is the duplication this console
  /// exists to remove.
  final ValueListenable<ConsoleSection>? sectionRequest;

  /// Pages nested under a section, shown in the sidebar beneath it.
  final Map<ConsoleSection, List<ConsoleSubItem>> subItems;
  final String? selectedSubItem;
  final void Function(ConsoleSection section, String id)? onSubItemSelected;

  /// Told which section is showing, so the client can stop doing work the
  /// visible section does not need. Only Fleet renders anything that changes
  /// second to second.
  final ValueChanged<ConsoleSection>? onSectionChanged;

  @override
  State<ConsoleShell> createState() => _ConsoleShellState();
}

class _ConsoleShellState extends State<ConsoleShell> {
  late ConsoleSection _section = widget.initialSection;
  FleetTab _fleetTab = FleetTab.machines;
  String? _selectedId;
  String? _busyActionId;

  @override
  void initState() {
    super.initState();
    widget.sectionRequest?.addListener(_onSectionRequested);
  }

  @override
  void didUpdateWidget(covariant ConsoleShell old) {
    super.didUpdateWidget(old);
    if (old.dashboardContextKey != widget.dashboardContextKey) {
      _selectedId = null;
      _fleetTab = FleetTab.machines;
    }
    if (!identical(old.sectionRequest, widget.sectionRequest)) {
      old.sectionRequest?.removeListener(_onSectionRequested);
      widget.sectionRequest?.addListener(_onSectionRequested);
    }
  }

  @override
  void dispose() {
    widget.sectionRequest?.removeListener(_onSectionRequested);
    super.dispose();
  }

  void _onSectionRequested() {
    final s = widget.sectionRequest?.value;
    if (s != null && mounted) _setSection(s);
  }

  String _helpTopic = 'home';
  void _openHelp() {
    _helpTopic = switch (_section) {
      ConsoleSection.home => 'home',
      ConsoleSection.fleet => switch (_fleetTab) {
          FleetTab.jobs => 'jobs',
          FleetTab.automation => 'automation',
          _ => 'fleet'
        },
      ConsoleSection.machineHealth => 'fleet',
      ConsoleSection.diagnostics => 'labnets',
      ConsoleSection.terminal || ConsoleSection.tools => 'jobs',
      ConsoleSection.network => 'labnets',
      ConsoleSection.thisMachine => 'device',
      ConsoleSection.settings => 'organizations',
      _ => 'sessions',
    };
    _setSection(ConsoleSection.help);
  }

  void _setSection(ConsoleSection s) {
    if (s == _section) return;
    setState(() => _section = s);
    widget.onSectionChanged?.call(s);
  }

  MachineRow? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final m in [...?widget.healthMachines, ...widget.machines]) {
      if (m.id == id) return m;
    }
    return null;
  }

  bool get _connected =>
      _selectedId != null && widget.connectedIds.contains(_selectedId);

  void _select(String id) {
    setState(() => _selectedId = id);
    widget.onMachineSelected?.call(id);
  }

  @override
  Widget build(BuildContext context) {
    // Ctrl+1 .. Ctrl+9 open the sections in sidebar order, so an operator
    // living in the terminal never has to reach for the pointer to change
    // rooms. The same numbers are shown in each entry's tooltip.
    final digits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    return CallbackShortcuts(
      bindings: {
        for (var i = 0;
            i < primaryConsoleSections.length && i < digits.length;
            i++)
          SingleActivator(digits[i], control: true): () =>
              _setSection(primaryConsoleSections[i]),
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: C.of(context).bg,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Sidebar(
                section: _section,
                profileName: widget.profileName,
                profiles: widget.profiles,
                onProfileSelected: widget.onProfileSelected,
                selected: _selected,
                onSelect: _setSection,
                subItems: widget.subItems,
                selectedSubItem: widget.selectedSubItem,
                onSubItemSelected: widget.onSubItemSelected,
                organizations: widget.organizations,
                activeOrganizationId: widget.activeOrganizationId,
                onOrganizationSelected: widget.onOrganizationSelected,
                accountName: widget.accountName,
                accountDescription: widget.accountDescription,
                onAccountPressed: widget.onAccountPressed,
                onTermsPressed: widget.onTermsPressed,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TitleBar(
                      section: _section,
                      machine: _selected,
                      isRefreshing: widget.isRefreshing,
                      lastRefreshed: widget.lastRefreshed,
                      onRefresh: widget.onRefresh,
                      now: widget.now,
                      onHelp:
                          _section == ConsoleSection.help ? null : _openHelp,
                    ),
                    Expanded(
                        child: KeyedSubtree(
                            key: ValueKey(widget.dashboardContextKey),
                            child: _body())),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_section == ConsoleSection.settings) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(children: [
            for (final item in widget.subItems[ConsoleSection.settings] ??
                const <ConsoleSubItem>[])
              TextButton(
                  onPressed: () => widget.onSubItemSelected
                      ?.call(ConsoleSection.settings, item.id),
                  child: Text(item.label,
                      style: C.of(context).body(
                          color: item.id == widget.selectedSubItem
                              ? C.of(context).accent
                              : C.of(context).textMuted))),
          ]),
        ),
        Expanded(child: _sectionBody()),
      ]);
    }
    if (_section == ConsoleSection.fleet &&
        _selected != null &&
        _fleetTab == FleetTab.machines) {
      return Column(children: [
        _machineNavigation(),
        Expanded(
            child: ActionsScreen(
          machine: _selected,
          connected: _connected,
          onRun: (action) => widget.onRunAction?.call(_selectedId!, action),
        )),
      ]);
    }
    if ([
      ConsoleSection.terminal,
      ConsoleSection.actions,
      ConsoleSection.tools,
      ConsoleSection.diagnostics,
      ConsoleSection.machineHealth
    ].contains(_section)) {
      return Column(children: [
        _machineNavigation(),
        Expanded(child: _sectionBody()),
      ]);
    }
    return _sectionBody();
  }

  Widget _machineNavigation() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Row(children: [
          TextButton.icon(
            onPressed: () {
              setState(() {
                _selectedId = null;
                _section = ConsoleSection.fleet;
              });
              widget.onSectionChanged?.call(ConsoleSection.fleet);
            },
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('All machines'),
          ),
          const SizedBox(width: 16),
          Expanded(
              child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final item in [
                ('Overview', ConsoleSection.fleet),
                ('Health', ConsoleSection.machineHealth),
                ('Terminal', ConsoleSection.terminal),
                ('Tools', ConsoleSection.tools),
                ('Network', ConsoleSection.diagnostics),
              ])
                TextButton(
                  onPressed: () => _setSection(item.$2),
                  child: Text(item.$1,
                      style: C.of(context).body(
                          color: _section == item.$2
                              ? C.of(context).accent
                              : C.of(context).textMuted)),
                ),
            ]),
          )),
        ]),
      );

  Widget _sectionBody() {
    final host = widget.hosted[_section];
    if (host != null) return host(context);
    switch (_section) {
      case ConsoleSection.help:
        return HelpScreen(initialTopic: _helpTopic);
      case ConsoleSection.home:
        return HomeDashboard(
          machines: widget.healthMachines ?? widget.machines,
          healthFor: (id) => widget.healthFor?.call(id) ?? MachineHealth.empty,
          layout: widget.dashboardLayout,
          onSaveLayout: widget.onSaveDashboard,
          contextKey: widget.dashboardContextKey,
          fleets: widget.fleets,
          machineFleetIds: widget.machineFleetIds,
          now: widget.now,
          isLoading: widget.isLoading,
          error: widget.dashboardError,
          onOpenMachine: (id) {
            _select(id);
            _setSection(ConsoleSection.fleet);
          },
          onExploreHealth: () {
            setState(() {
              _selectedId = null;
              _fleetTab = FleetTab.health;
            });
            _setSection(ConsoleSection.fleet);
          },
        );
      case ConsoleSection.fleet:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FleetTabs(
              tab: _fleetTab,
              onChanged: (t) {
                setState(() {
                  _fleetTab = t;
                  _selectedId = null;
                });
                widget.onSectionChanged?.call(t == FleetTab.automation
                    ? ConsoleSection.automation
                    : ConsoleSection.fleet);
              },
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: MediaQuery.of(context).disableAnimations
                    ? Duration.zero
                    : C.medium,
                child: KeyedSubtree(
                    key: ValueKey(_fleetTab),
                    child: switch (_fleetTab) {
                      FleetTab.machines => FleetConsole(
                          machines: widget.machines,
                          samples: widget.samples,
                          isRefreshing: widget.isRefreshing,
                          isLoading: widget.isLoading,
                          lastRefreshed: widget.lastRefreshed,
                          selectedId: _selectedId,
                          onSelect: _select,
                          now: widget.now,
                          embedded: true,
                        ),
                      FleetTab.health => HealthBoard(
                          machines: widget.healthMachines ?? widget.machines,
                          healthFor: (id) =>
                              widget.healthFor?.call(id) ?? MachineHealth.empty,
                          now: widget.now,
                        ),
                      FleetTab.jobs => widget.hosted[ConsoleSection.tools]
                              ?.call(context) ??
                          const _HostedElsewhere(section: ConsoleSection.tools),
                      FleetTab.automation => widget
                              .hosted[ConsoleSection.automation]
                              ?.call(context) ??
                          const _HostedElsewhere(
                              section: ConsoleSection.automation),
                    }),
              ),
            ),
          ],
        );
      case ConsoleSection.machineHealth:
        return HealthBoard(
            footer: _selectedId == null
                ? null
                : widget.machineHealthFooter?.call(_selectedId!),
            machines: _selected == null ? const [] : [_selected!],
            healthFor: (id) =>
                widget.healthFor?.call(id) ?? MachineHealth.empty,
            now: widget.now);
      case ConsoleSection.terminal:
        return TerminalScreen(
          machine: _selected,
          lines: _selectedId != null && widget.terminalLinesFor != null
              ? widget.terminalLinesFor!(_selectedId!)
              : widget.terminalLines,
          connected: _selectedId != null &&
              (widget.terminalIds ?? widget.connectedIds).contains(_selectedId),
          onSubmit: _selectedId == null
              ? null
              : (cmd) => widget.onTerminalSubmit?.call(_selectedId!, cmd),
          onOpenSession: _selectedId == null
              ? null
              : () =>
                  widget.onRunAction?.call(_selectedId!, kMachineActions[1]),
        );
      case ConsoleSection.actions:
        return ActionsScreen(
          machine: _selected,
          connected: _connected,
          busyActionId: _busyActionId,
          onRun: _selectedId == null
              ? null
              : (a) async {
                  setState(() => _busyActionId = a.id);
                  widget.onRunAction?.call(_selectedId!, a);
                  await Future.delayed(const Duration(milliseconds: 900));
                  if (mounted) setState(() => _busyActionId = null);
                },
        );
      case ConsoleSection.settings:
        return SettingsScreen(
            profiles: widget.profiles,
            onActivate: widget.onProfileSelected == null
                ? null
                : (profile) => widget.onProfileSelected!(profile.name));
      case ConsoleSection.sessions:
      case ConsoleSection.tools:
      case ConsoleSection.automation:
      case ConsoleSection.network:
      case ConsoleSection.diagnostics:
        // Supplied by the client through [hosted] once built; until then the
        // section says so rather than showing an empty frame.
        return _HostedElsewhere(section: _section);
      case ConsoleSection.connect:
      case ConsoleSection.thisMachine:
        // These two are always supplied by the client, because connecting and
        // the machine list are the application's own widgets. Reaching here
        // means the console is running without a client, which is the design
        // harness, so it says that rather than pretending to be either.
        return _HostedElsewhere(section: _section);
    }
  }
}

/// Native tabs provide keyboard traversal and a moving selection indicator.
class _FleetTabs extends StatefulWidget {
  const _FleetTabs({required this.tab, required this.onChanged});
  final FleetTab tab;
  final ValueChanged<FleetTab> onChanged;
  @override
  State<_FleetTabs> createState() => _FleetTabsState();
}

class _FleetTabsState extends State<_FleetTabs> with TickerProviderStateMixin {
  TabController? _controller;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration =
        MediaQuery.of(context).disableAnimations ? Duration.zero : C.medium;
    if (_controller == null || _controller!.animationDuration != duration) {
      _controller?.dispose();
      _controller = TabController(
          length: FleetTab.values.length,
          vsync: this,
          initialIndex: widget.tab.index,
          animationDuration: duration);
    }
  }

  @override
  void didUpdateWidget(covariant _FleetTabs old) {
    super.didUpdateWidget(old);
    if (_controller!.index != widget.tab.index) {
      _controller!.animateTo(widget.tab.index);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TabBar(
        controller: _controller,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        labelStyle: C
            .of(context)
            .body()
            .copyWith(fontSize: 16, fontWeight: FontWeight.w600),
        labelColor: C.of(context).accent,
        unselectedLabelColor: C.of(context).textMuted,
        indicatorColor: C.of(context).accent,
        dividerColor: C.of(context).hairline,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        onTap: (index) => widget.onChanged(FleetTab.values[index]),
        tabs: const [
          Tab(text: 'Machines', height: 52),
          Tab(text: 'Health', height: 52),
          Tab(text: 'Jobs', height: 52),
          Tab(text: 'Automation', height: 52)
        ],
      );
}

/// Stands in for a section the client owns, when there is no client.
class _HostedElsewhere extends StatelessWidget {
  const _HostedElsewhere({required this.section});

  final ConsoleSection section;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LdIcon(section.glyph, size: 28, color: C.of(context).textFaint),
            const SizedBox(height: 12),
            Text('${section.label} is part of the running client',
                style: C.of(context).h2(), textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              'This harness renders the console without a client, so the '
              'sections the client supplies are not here.',
              style: C.of(context).small(),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.section,
    required this.profileName,
    required this.selected,
    required this.onSelect,
    this.profiles = const [],
    this.onProfileSelected,
    this.subItems = const {},
    this.selectedSubItem,
    this.onSubItemSelected,
    this.organizations = const [],
    this.activeOrganizationId,
    this.onOrganizationSelected,
    this.accountName = 'Signed out',
    this.accountDescription,
    this.onAccountPressed,
    this.onTermsPressed,
  });

  final ConsoleSection section;
  final String profileName;
  final List<ProfileRow> profiles;
  final ValueChanged<String>? onProfileSelected;
  final MachineRow? selected;
  final ValueChanged<ConsoleSection> onSelect;
  final Map<ConsoleSection, List<ConsoleSubItem>> subItems;
  final String? selectedSubItem;
  final void Function(ConsoleSection section, String id)? onSubItemSelected;
  final List<OrganizationSummary> organizations;
  final String? activeOrganizationId;
  final ValueChanged<String>? onOrganizationSelected;
  final String accountName;
  final String? accountDescription;
  final VoidCallback? onAccountPressed;
  final VoidCallback? onTermsPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      // Wide enough for "This machine" and a profile name beside its chevron;
      // the 216 it was left a gutter of nothing to the right of every label.
      width: 224,
      color: C.of(context).chrome,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            child: Row(
              children: [
                // The application's own icon, not an approximation of it. A
                // gradient square stood in here before, which meant the mark
                // in the product and the mark on the taskbar were two
                // different things.
                SvgPicture.asset('assets/icon.svg', width: 24, height: 24),
                const SizedBox(width: 10),
                Flexible(
                  child: Text('LabDesk',
                      overflow: TextOverflow.ellipsis,
                      style: C.of(context).h1()),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Organization', style: C.of(context).micro()),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: organizations
                            .any((org) => org.id == activeOrganizationId)
                        ? activeOrganizationId
                        : null,
                    isExpanded: true,
                    dropdownColor: C.of(context).surface,
                    style: C.of(context).body(),
                    decoration: const InputDecoration(
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
                    hint: Text(
                        organizations.isEmpty
                            ? 'Sign in to choose'
                            : 'Choose organization',
                        style: C.of(context).small()),
                    items: [
                      for (final org in organizations)
                        DropdownMenuItem(
                            value: org.id,
                            child: Text(org.name,
                                overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: onOrganizationSelected == null
                        ? null
                        : (id) {
                            if (id != null) onOrganizationSelected!(id);
                          },
                  ),
                ]),
          ),
          // Scrolls rather than overflows. Seven sections plus the eight
          // settings pages nested under one of them is taller than a short
          // window, and a Column that cannot fit its children paints overflow
          // stripes over the interface rather than clipping quietly.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final s in primaryConsoleSections) ...[
                    _NavItem(
                      section: s,
                      active: s == section ||
                          (s == ConsoleSection.fleet &&
                              [
                                ConsoleSection.tools,
                                ConsoleSection.terminal,
                                ConsoleSection.actions,
                                ConsoleSection.automation,
                                ConsoleSection.diagnostics,
                                ConsoleSection.machineHealth
                              ].contains(section)),
                      shortcut: primaryConsoleSections.indexOf(s) < 9
                          ? 'Ctrl+${primaryConsoleSections.indexOf(s) + 1}'
                          : null,
                      onTap: () => onSelect(s),
                    ),
                    // Nested pages appear only under the open section, so the
                    // sidebar does not become a wall of everything at once.
                    if (s == section)
                      for (final sub
                          in (subItems[s] ?? const <ConsoleSubItem>[]))
                        _SubNavItem(
                          item: sub,
                          active: sub.id == selectedSubItem,
                          onTap: () => onSubItemSelected?.call(s, sub.id),
                        ),
                  ],
                  const SizedBox(height: 24),
                  _NavItem(
                      section: ConsoleSection.connect,
                      active: section == ConsoleSection.connect,
                      onTap: () => onSelect(ConsoleSection.connect)),
                  _NavItem(
                      section: ConsoleSection.sessions,
                      active: section == ConsoleSection.sessions,
                      onTap: () => onSelect(ConsoleSection.sessions)),
                ],
              ),
            ),
          ),
          if (selected != null) ...[
            Divider(height: 1, thickness: 1, color: C.of(context).hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Selected', style: C.of(context).micro()),
                  const SizedBox(height: 4),
                  Text(
                    selected!.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: C
                        .of(context)
                        .small(color: C.of(context).text, w: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
          _NavItem(
              section: ConsoleSection.help,
              active: section == ConsoleSection.help,
              onTap: () => onSelect(ConsoleSection.help)),
          _NavItem(
              section: ConsoleSection.settings,
              active: section == ConsoleSection.settings,
              onTap: () => onSelect(ConsoleSection.settings)),
          Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Column(children: [
                Divider(height: 1, color: C.of(context).hairline),
                TextButton(
                    onPressed: onAccountPressed,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(accountName, style: C.of(context).body()),
                          if (accountDescription != null)
                            Text(accountDescription!,
                                style: C.of(context).micro()),
                        ])),
                TextButton(
                    onPressed: onTermsPressed,
                    child: Text('Terms of Service',
                        style: C
                            .micro()
                            .copyWith(decoration: TextDecoration.underline))),
              ])),
        ],
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.section,
    required this.active,
    required this.onTap,
    this.shortcut,
  });

  final ConsoleSection section;
  final bool active;
  final VoidCallback onTap;
  final String? shortcut;

  @override
  State<_NavItem> createState() => _NavItemState();
}

/// Focus, Enter and Space, a ring, and button semantics for a sidebar entry.
/// The entries were pointer-only; a console reached over a remote session is
/// often driven from a keyboard, and a screen reader needs to be told which
/// room it is in.
Widget _navFocusable({
  required String label,
  required bool active,
  required VoidCallback onTap,
  required ValueChanged<bool> onHover,
  required ValueChanged<bool> onFocus,
  required bool focused,
  required Widget child,
}) =>
    Semantics(
      button: true,
      selected: active,
      focusable: true,
      focused: focused,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: onHover,
        onShowFocusHighlight: onFocus,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            onTap();
            return null;
          }),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: child,
        ),
      ),
    );

class _NavItemState extends State<_NavItem> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.active
        ? C.of(context).text
        : (_hover ? C.of(context).text : C.of(context).textMuted);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Tooltip(
        message: widget.shortcut ?? '',
        waitDuration: const Duration(milliseconds: 700),
        child: _navFocusable(
          label: widget.section.label,
          active: widget.active,
          onTap: widget.onTap,
          onHover: (v) => setState(() => _hover = v),
          onFocus: (v) => setState(() => _focused = v),
          focused: _focused,
          child: AnimatedContainer(
            duration: C.fast,
            height: 44,
            padding: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: widget.active
                  ? C.of(context).accent.withOpacity(0.14)
                  : (_hover ? C.of(context).surfaceHi : Colors.transparent),
              borderRadius: C.roundedSm,
              border: Border.all(
                color: _focused ? C.of(context).focusRing : Colors.transparent,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                // Fill plus a leading accent bar. One way of saying "this is
                // the current thing", shared with the selected row in every
                // table in the product, rather than a fill here and a bar
                // there and a bottom border somewhere else.
                Container(
                  width: 2,
                  height: 18,
                  decoration: BoxDecoration(
                    color: widget.active
                        ? C.of(context).accent
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                const SizedBox(width: 8),
                LdIcon(widget.section.glyph,
                    size: 16, color: widget.active ? C.of(context).accent : fg),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    widget.section.label,
                    overflow: TextOverflow.ellipsis,
                    style: C.of(context).small(
                          color: fg,
                          w: widget.active ? FontWeight.w700 : FontWeight.w500,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.section,
    required this.machine,
    required this.isRefreshing,
    required this.lastRefreshed,
    required this.onRefresh,
    this.now,
    this.onHelp,
  });

  final ConsoleSection section;
  final MachineRow? machine;
  final bool isRefreshing;
  final DateTime? lastRefreshed;
  final VoidCallback? onRefresh;
  final DateTime? now;
  final VoidCallback? onHelp;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: C.of(context).bg,
        border: Border(bottom: BorderSide(color: C.of(context).hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Text(section.label, style: C.of(context).h1()),
          if (section.needsMachine && machine != null) ...[
            const SizedBox(width: 12),
            Text('/',
                style: C
                    .of(context)
                    .h1()
                    .copyWith(color: C.of(context).textFaint)),
            const SizedBox(width: 12),
            // Flexible with an ellipsis: a machine can be named anything, and
            // an unbounded Text beside a Spacer overflows the title bar.
            Flexible(
              child: Text(
                machine!.displayName,
                overflow: TextOverflow.ellipsis,
                style:
                    C.of(context).h1().copyWith(color: C.of(context).textMuted),
              ),
            ),
          ],
          const Spacer(),
          if (onHelp != null)
            IconButton(
              tooltip: 'Help for this page',
              onPressed: onHelp,
              icon: const Icon(Icons.help_outline, size: 20),
            ),
          // Both surfaces that show whether a machine is reachable can ask
          // again. Reachability is polled, so without this the operator cannot
          // tell a stale dot from a machine that is genuinely down.
          if (onRefresh != null &&
              (section == ConsoleSection.home ||
                  section == ConsoleSection.fleet ||
                  section == ConsoleSection.connect)) ...[
            Text(_stamp(lastRefreshed, now),
                style: C.of(context).small(color: C.of(context).textFaint)),
            const SizedBox(width: 12),
            GhostButton(
              label: 'Refresh',
              glyph: LdIcons.refresh,
              busy: isRefreshing,
              onPressed: onRefresh,
            ),
          ],
        ],
      ),
    );
  }

  static String _stamp(DateTime? at, DateTime? now) {
    if (at == null) return 'Not checked yet';
    final s = (now ?? DateTime.now()).difference(at).inSeconds;
    if (s < 10) return 'Checked just now';
    if (s < 60) return 'Checked ${s}s ago';
    if (s < 3600) return 'Checked ${s ~/ 60}m ago';
    return 'Checked ${s ~/ 3600}h ago';
  }
}

/// A page nested under the open section. Indented and quieter than a section,
/// so the hierarchy reads without a second rail.
class _SubNavItem extends StatefulWidget {
  const _SubNavItem({
    required this.item,
    required this.active,
    required this.onTap,
  });

  final ConsoleSubItem item;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_SubNavItem> createState() => _SubNavItemState();
}

class _SubNavItemState extends State<_SubNavItem> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.active
        ? C.of(context).text
        : (_hover ? C.of(context).text : C.of(context).textMuted);
    return _navFocusable(
      label: widget.item.label,
      active: widget.active,
      onTap: widget.onTap,
      onHover: (v) => setState(() => _hover = v),
      onFocus: (v) => setState(() => _focused = v),
      focused: _focused,
      child: AnimatedContainer(
        duration: C.fast,
        height: 30,
        margin: const EdgeInsets.fromLTRB(10, 1, 10, 1),
        padding: const EdgeInsets.only(left: 28, right: 10),
        decoration: BoxDecoration(
          color: widget.active ? C.of(context).surfaceHi : Colors.transparent,
          borderRadius: C.roundedSm,
          border: Border.all(
            color: _focused ? C.of(context).focusRing : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            // A rule rather than an icon: the section above already carries
            // one, and repeating icons at both levels flattens the hierarchy.
            Container(
              width: 2,
              height: 12,
              color:
                  widget.active ? C.of(context).accent : C.of(context).hairline,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.item.label,
                overflow: TextOverflow.ellipsis,
                style: C.of(context).small(
                      color: fg,
                      w: widget.active ? FontWeight.w600 : FontWeight.w500,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
