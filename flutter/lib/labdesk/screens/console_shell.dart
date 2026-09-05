import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../charts/reachability_chart.dart';
import '../models/machine_metrics.dart';
import '../models/machine_row.dart';
import '../theme/console_theme.dart';
import '../theme/ld_icons.dart';
import 'actions_screen.dart';
import 'console_menu.dart';
import 'fleet_console.dart';
import 'health_board.dart';
import 'settings_screen.dart';
import 'terminal_screen.dart';

enum ConsoleSection {
  connect,
  fleet,
  sessions,
  terminal,
  tools,
  automation,
  actions,
  network,
  thisMachine,
  settings,
}

/// The two views of the fleet. Health used to be a section of its own that
/// showed one machine, chosen on Fleet first; it is a tab here so the whole
/// fleet's figures sit beside the reachability table they belong with.
enum FleetTab { machines, health }

extension ConsoleSectionInfo on ConsoleSection {
  String get label => switch (this) {
        ConsoleSection.connect => 'Connect',
        ConsoleSection.thisMachine => 'This machine',
        ConsoleSection.fleet => 'Fleet',
        ConsoleSection.sessions => 'Sessions',
        ConsoleSection.terminal => 'Terminal',
        ConsoleSection.tools => 'Tools',
        ConsoleSection.automation => 'Automation',
        ConsoleSection.actions => 'Actions',
        ConsoleSection.network => 'Network',
        ConsoleSection.settings => 'Settings',
      };

  String get glyph => switch (this) {
        ConsoleSection.connect => LdIcons.connect,
        ConsoleSection.thisMachine => LdIcons.machine,
        ConsoleSection.fleet => LdIcons.fleet,
        ConsoleSection.sessions => LdIcons.display,
        ConsoleSection.tools => LdIcons.actions,
        ConsoleSection.automation => LdIcons.refresh,
        ConsoleSection.terminal => LdIcons.terminal,
        ConsoleSection.actions => LdIcons.actions,
        ConsoleSection.network => LdIcons.group,
        ConsoleSection.settings => LdIcons.settings,
      };

  /// Sections that act on one machine show which machine in the title bar, and
  /// prompt to pick one when none is selected.
  bool get needsMachine => switch (this) {
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
    this.initialSection = ConsoleSection.connect,
    this.hosted = const {},
    this.sectionRequest,
    this.subItems = const {},
    this.selectedSubItem,
    this.onSubItemSelected,
    this.onSectionChanged,
  });

  final List<MachineRow> machines;
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

  void _setSection(ConsoleSection s) {
    if (s == _section) return;
    setState(() => _section = s);
    widget.onSectionChanged?.call(s);
  }

  MachineRow? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final m in widget.machines) {
      if (m.id == id) return m;
    }
    return null;
  }

  bool get _connected =>
      _selectedId != null && widget.connectedIds.contains(_selectedId);

  void _select(String id) {
    setState(() => _selectedId = id);
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
            i < ConsoleSection.values.length && i < digits.length;
            i++)
          SingleActivator(digits[i], control: true): () =>
              _setSection(ConsoleSection.values[i]),
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: C.bg,
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
                    ),
                    Expanded(child: _body()),
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
    final host = widget.hosted[_section];
    if (host != null) return host(context);
    switch (_section) {
      case ConsoleSection.fleet:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FleetTabs(
              tab: _fleetTab,
              onChanged: (t) => setState(() => _fleetTab = t),
            ),
            Expanded(
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
                    machines: widget.machines,
                    healthFor: (id) =>
                        widget.healthFor?.call(id) ?? MachineHealth.empty,
                    now: widget.now,
                  ),
              },
            ),
          ],
        );
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
        return SettingsScreen(profiles: widget.profiles);
      case ConsoleSection.sessions:
      case ConsoleSection.tools:
      case ConsoleSection.automation:
      case ConsoleSection.network:
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

/// The two views of Fleet, as a strip under the title bar. Plain text tabs on
/// a hairline, the way the table headers sit, not a Material tab bar with its
/// ink and its animated indicator.
class _FleetTabs extends StatelessWidget {
  const _FleetTabs({required this.tab, required this.onChanged});

  final FleetTab tab;
  final ValueChanged<FleetTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: C.bg,
        border: Border(bottom: BorderSide(color: C.hairline)),
      ),
      child: Row(
        children: [
          for (final t in FleetTab.values) ...[
            _FleetTabItem(
              label: t == FleetTab.machines ? 'Machines' : 'Health',
              active: t == tab,
              onTap: () => onChanged(t),
            ),
            const SizedBox(width: 22),
          ],
        ],
      ),
    );
  }
}

class _FleetTabItem extends StatelessWidget {
  const _FleetTabItem(
      {required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.only(top: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? C.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: C.small(
              color: active ? C.text : C.textMuted,
              w: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
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
            LdIcon(section.glyph, size: 28, color: C.textFaint),
            const SizedBox(height: 12),
            Text('${section.label} is part of the running client',
                style: C.h2(), textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              'This harness renders the console without a client, so the '
              'sections the client supplies are not here.',
              style: C.small(),
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

  @override
  Widget build(BuildContext context) {
    return Container(
      // Wide enough for "This machine" and a profile name beside its chevron;
      // the 216 it was left a gutter of nothing to the right of every label.
      width: 184,
      color: C.chrome,
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
                      overflow: TextOverflow.ellipsis, style: C.h1()),
                ),
              ],
            ),
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
                  for (final s in ConsoleSection.values) ...[
                    _NavItem(
                      section: s,
                      active: s == section,
                      shortcut: ConsoleSection.values.indexOf(s) < 9
                          ? 'Ctrl+${ConsoleSection.values.indexOf(s) + 1}'
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
                ],
              ),
            ),
          ),
          if (selected != null) ...[
            Divider(height: 1, thickness: 1, color: C.hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Selected', style: C.micro()),
                  const SizedBox(height: 4),
                  Text(
                    selected!.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: C.small(color: C.text, w: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
          Divider(height: 1, thickness: 1, color: C.hairline),
          _profileControl(),
        ],
      ),
    );
  }

  /// The active server profile, and the way to change it.
  ///
  /// This was a label with a chevron drawn beside it and nothing behind the
  /// chevron. It now opens the console's own menu over the profiles the client
  /// supplied; with no way to act on a pick it stays a label, without the
  /// chevron, so it never promises what it cannot do.
  Widget _profileControl() {
    final canPick = onProfileSelected != null && profiles.isNotEmpty;
    Widget face(bool focused, bool hovered) => Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
          color: hovered ? C.surfaceHi : Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Server profile', style: C.micro()),
              const SizedBox(height: 5),
              Row(
                children: [
                  Expanded(
                    child: Text(profileName,
                        overflow: TextOverflow.ellipsis, style: C.body()),
                  ),
                  if (canPick)
                    LdIcon(LdIcons.chevronDown,
                        size: 15, color: focused ? C.accent : C.textFaint),
                ],
              ),
            ],
          ),
        );
    if (!canPick) return face(false, false);
    return ConsoleMenuButton<String>(
      tooltip: 'Switch server profile',
      entries: () => [
        const ConsoleMenuHeading<String>('Server profile'),
        for (final p in profiles)
          ConsoleMenuAction<String>(p.name, p.name, checked: p.active),
      ],
      onSelected: onProfileSelected!,
      builder: face,
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
    final fg = widget.active ? C.text : (_hover ? C.text : C.textMuted);
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
            height: 34,
            padding: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: widget.active
                  ? C.accent.withOpacity(0.14)
                  : (_hover ? C.surfaceHi : Colors.transparent),
              borderRadius: C.roundedSm,
              border: Border.all(
                color: _focused ? C.focusRing : Colors.transparent,
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
                    color: widget.active ? C.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                const SizedBox(width: 8),
                LdIcon(widget.section.glyph,
                    size: 16, color: widget.active ? C.accent : fg),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    widget.section.label,
                    overflow: TextOverflow.ellipsis,
                    style: C.small(
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
  });

  final ConsoleSection section;
  final MachineRow? machine;
  final bool isRefreshing;
  final DateTime? lastRefreshed;
  final VoidCallback? onRefresh;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: C.bg,
        border: Border(bottom: BorderSide(color: C.hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Text(section.label, style: C.h1()),
          if (section.needsMachine && machine != null) ...[
            const SizedBox(width: 12),
            Text('/', style: C.h1().copyWith(color: C.textFaint)),
            const SizedBox(width: 12),
            // Flexible with an ellipsis: a machine can be named anything, and
            // an unbounded Text beside a Spacer overflows the title bar.
            Flexible(
              child: Text(
                machine!.displayName,
                overflow: TextOverflow.ellipsis,
                style: C.h1().copyWith(color: C.textMuted),
              ),
            ),
          ],
          const Spacer(),
          // Both surfaces that show whether a machine is reachable can ask
          // again. Reachability is polled, so without this the operator cannot
          // tell a stale dot from a machine that is genuinely down.
          if (onRefresh != null &&
              (section == ConsoleSection.fleet ||
                  section == ConsoleSection.connect)) ...[
            Text(_stamp(lastRefreshed, now),
                style: C.small(color: C.textFaint)),
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
    final fg = widget.active ? C.text : (_hover ? C.text : C.textMuted);
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
          color: widget.active ? C.surfaceHi : Colors.transparent,
          borderRadius: C.roundedSm,
          border: Border.all(
            color: _focused ? C.focusRing : Colors.transparent,
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
              color: widget.active ? C.accent : C.hairline,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.item.label,
                overflow: TextOverflow.ellipsis,
                style: C.small(
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
