import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/dashboard_layout.dart';
import '../models/machine_metrics.dart';
import '../models/machine_row.dart';
import 'dashboard_widgets.dart';

export 'dashboard_widgets.dart' show DashboardFleet;

/// Native dashboard: production supplies organization data and persistence;
/// fixtures can edit locally, with that limitation explicitly visible.
class HomeDashboard extends StatefulWidget {
  const HomeDashboard(
      {super.key,
      required this.machines,
      required this.healthFor,
      this.layout,
      this.onSaveLayout,
      this.onOpenMachine,
      this.onExploreHealth,
      this.now,
      this.isLoading = false,
      this.error,
      this.contextKey = 'local',
      this.fleets = const [],
      this.machineFleetIds = const {}});
  final List<MachineRow> machines;
  final MachineHealth Function(String) healthFor;
  final DashboardLayout? layout;
  final Future<void> Function(DashboardLayout)? onSaveLayout;
  final ValueChanged<String>? onOpenMachine;
  final VoidCallback? onExploreHealth;
  final DateTime? now;
  final bool isLoading;
  final String? error;
  final String contextKey;
  final List<DashboardFleet> fleets;
  final Map<String, Set<String>> machineFleetIds;
  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends State<HomeDashboard> {
  late DashboardLayout _saved;
  DashboardLayout? _draft;
  final List<DashboardLayout> _undo = [];
  String? _selected;
  String? _fleetId;
  bool _inspector = false;
  bool _saving = false;
  String? _notice;
  int _serial = 0;
  int _contextRevision = 0;
  DashboardLayout get _layout => _draft ?? _saved;
  bool get _editing => _draft != null;
  DashboardWidgetSpec? get _selection {
    for (final spec in _layout.widgets) {
      if (spec.id == _selected) return spec;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _saved = widget.layout ?? dashboardPreset('everyday');
  }

  @override
  void didUpdateWidget(HomeDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.contextKey != widget.contextKey) {
      _contextRevision++;
      _saved = widget.layout ?? dashboardPreset('everyday');
      _draft = null;
      _undo.clear();
      _selected = null;
      _fleetId = null;
      _inspector = false;
      _saving = false;
      _notice = null;
    } else if (oldWidget.layout != widget.layout &&
        widget.layout != null &&
        !_editing) {
      _saved = widget.layout!;
    }
    if (_fleetId != null && !widget.fleets.any((f) => f.id == _fleetId)) {
      _fleetId = null;
    }
  }

  void _begin() => setState(() {
        _draft ??= _saved;
        _notice = null;
      });
  void _remember(DashboardLayout next, {String? notice}) {
    if (_saving) return;
    setState(() {
      _undo.add(_layout);
      if (_undo.length > 30) _undo.removeAt(0);
      _draft = next;
      _notice = notice;
    });
  }

  void _update(DashboardWidgetSpec next) {
    _remember(
        _layout.copyWith(
            widgets: arrangeDashboard([
          for (final spec in _layout.widgets)
            if (spec.id == next.id) next else spec,
        ], priorityId: next.id)),
        notice: '${dashboardReportTitle(next.report)} updated.');
  }

  void _cancel() => setState(() {
        _draft = null;
        _undo.clear();
        _selected = null;
        _inspector = false;
        _notice = 'Changes discarded.';
      });
  Future<void> _save() async {
    final draft = _draft;
    if (draft == null || _saving) return;
    final revision = _contextRevision;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await widget.onSaveLayout?.call(draft);
      if (!mounted || _contextRevision != revision) return;
      setState(() {
        _saved = draft;
        _draft = null;
        _undo.clear();
        _selected = null;
        _inspector = false;
        _notice = widget.onSaveLayout == null
            ? 'Applied for this preview only. Persistence is not connected.'
            : 'Dashboard saved.';
      });
    } catch (_) {
      if (!mounted || _contextRevision != revision) return;
      setState(() => _notice =
          'Could not save the dashboard. Your draft is still here; retry Save or Cancel to discard it.');
    } finally {
      if (mounted && _contextRevision == revision) {
        setState(() => _saving = false);
      }
    }
  }

  String _newId() {
    String id;
    do {
      id = 'report-${DateTime.now().microsecondsSinceEpoch}-${_serial++}';
    } while (_layout.widgets.any((w) => w.id == id));
    return id;
  }

  void _add(DashboardReport report) {
    if (_layout.widgets.length >= dashboardMaxWidgets) {
      setState(() => _notice =
          'Dashboard limit reached. Remove a report before adding another.');
      return;
    }
    final spec = DashboardWidgetSpec(
        id: _newId(),
        report: report,
        width: 4,
        height: 4,
        y: _layout.widgets
            .fold<int>(0, (bottom, s) => math.max(bottom, s.y + s.height)));
    _remember(_layout.copyWith(
        widgets: arrangeDashboard([..._layout.widgets, spec])));
    setState(() {
      _selected = spec.id;
      _inspector = true;
    });
  }

  void _duplicate(DashboardWidgetSpec spec) {
    if (_layout.widgets.length >= dashboardMaxWidgets) {
      setState(() => _notice =
          'Dashboard limit reached. Remove a report before duplicating.');
      return;
    }
    final duplicate = spec.copyWith(id: _newId(), y: spec.y + spec.height);
    _remember(_layout.copyWith(
        widgets: arrangeDashboard([..._layout.widgets, duplicate])));
    setState(() => _selected = duplicate.id);
  }

  void _move(DashboardWidgetSpec spec, int dx, int dy, {bool resize = false}) {
    if (_saving || (dx == 0 && dy == 0)) return;
    _update(resize
        ? spec.copyWith(
            width: (spec.width + dx).clamp(spec.minimumWidth, 12),
            height: (spec.height + dy).clamp(spec.minimumHeight, 8))
        : spec.copyWith(
            x: (spec.x + dx).clamp(0, 12 - spec.width),
            y: (spec.y + dy).clamp(0, dashboardMaxRows - spec.height)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
        builder: (context, bounds) => Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                      constraints:
                          BoxConstraints(maxHeight: bounds.maxHeight * .42),
                      child: SingleChildScrollView(
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                            Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 16,
                                runSpacing: 8,
                                children: [
                                  Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                            'Your machines, at a glance.'),
                                      ]),
                                  Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        SizedBox(
                                            width: 210,
                                            child: DropdownButtonFormField<
                                                    String>(
                                                key: ValueKey(
                                                    'fleet-filter-${widget.contextKey}'),
                                                value: _fleetId ?? '',
                                                isExpanded: true,
                                                decoration:
                                                    const InputDecoration(
                                                        labelText:
                                                            'Fleet filter',
                                                        isDense: true),
                                                items: [
                                                  const DropdownMenuItem(
                                                      value: '',
                                                      child:
                                                          Text('All fleets')),
                                                  for (final f in widget.fleets)
                                                    DropdownMenuItem(
                                                        value: f.id,
                                                        child: Text(f.name,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis))
                                                ],
                                                onChanged: (id) => setState(
                                                    () => _fleetId =
                                                        id == '' ? null : id))),
                                        if (!_editing)
                                          FilledButton.icon(
                                              key: const ValueKey(
                                                  'customize-dashboard'),
                                              onPressed: _begin,
                                              icon: const Icon(Icons.tune,
                                                  size: 18),
                                              label:
                                                  const Text('Make it yours')),
                                      ]),
                                ]),
                            const SizedBox(height: 14),
                            if (widget.isLoading)
                              const LinearProgressIndicator(minHeight: 2),
                            if (widget.error != null)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Text(widget.error!,
                                      style: TextStyle(
                                          color: theme.colorScheme.error))),
                            if (_editing) ...[
                              const Divider(),
                              Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    OutlinedButton.icon(
                                        onPressed: _saving
                                            ? null
                                            : () => setState(() {
                                                  _selected = null;
                                                  _inspector = true;
                                                }),
                                        icon: const Icon(Icons.add),
                                        label: const Text('Add report')),
                                    OutlinedButton(
                                        onPressed: _saving || _undo.isEmpty
                                            ? null
                                            : () => setState(() {
                                                  _draft = _undo.removeLast();
                                                  if (_selection == null) {
                                                    _selected = null;
                                                  }
                                                  _notice =
                                                      'Last change undone.';
                                                }),
                                        child: const Text('Undo')),
                                    OutlinedButton(
                                        onPressed: _saving
                                            ? null
                                            : () => _remember(
                                                _layout.copyWith(
                                                    widgets: compactDashboard(
                                                        _layout.widgets)),
                                                notice:
                                                    'Gaps closed where report sizes permit. Report sizes are unchanged.'),
                                        child: const Text('Close gaps')),
                                    SizedBox(
                                        width: 160,
                                        child: DropdownButtonFormField<String>(
                                            key: ValueKey(
                                                'preset-${_layout.preset}'),
                                            value: const [
                                              'everyday',
                                              'technician',
                                              'operations'
                                            ].contains(_layout.preset)
                                                ? _layout.preset
                                                : 'everyday',
                                            isExpanded: true,
                                            decoration: const InputDecoration(
                                                labelText: 'Preset draft',
                                                isDense: true),
                                            items: [
                                              for (final name in const [
                                                'everyday',
                                                'technician',
                                                'operations'
                                              ])
                                                DropdownMenuItem(
                                                    value: name,
                                                    child: Text(
                                                        '${name[0].toUpperCase()}${name.substring(1)}'))
                                            ],
                                            onChanged: _saving
                                                ? null
                                                : (name) {
                                                    if (name != null) {
                                                      _remember(
                                                          dashboardPreset(name),
                                                          notice:
                                                              'Preset loaded as a draft. Save to keep it.');
                                                      setState(() {
                                                        _selected = null;
                                                      });
                                                    }
                                                  })),
                                  ]),
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Text(
                                      'Drag a move handle or resize corner. With a handle focused, use arrow keys to move; Shift + arrows to resize. Narrow screens keep report order.',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: theme
                                              .colorScheme.onSurfaceVariant))),
                              if (widget.onSaveLayout == null)
                                const Text(
                                    'Preview mode · layout changes apply only in this session.',
                                    style: TextStyle(fontSize: 12)),
                            ],
                            if (_notice != null)
                              Semantics(
                                  liveRegion: true,
                                  child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 6),
                                      child: Text(_notice!))),
                          ]))),
                  if (_editing)
                    Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      TextButton(
                          onPressed: _saving ? null : _cancel,
                          child: const Text('Cancel')),
                      const SizedBox(width: 8),
                      FilledButton(
                          onPressed: _saving ? null : _save,
                          child: Text(_saving ? 'Saving…' : 'Save')),
                    ]),
                  const SizedBox(height: 8),
                  Expanded(child: LayoutBuilder(builder: (context, c) {
                    final showInspector = _editing && _inspector;
                    final sideInspector = c.maxWidth >= 1120;
                    final grid = _grid(context);
                    if (!showInspector) return grid;
                    if (sideInspector) {
                      return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: grid),
                            const VerticalDivider(width: 28),
                            SizedBox(
                                width: 310, child: _buildInspector(context)),
                          ]);
                    }
                    if (c.maxWidth < 600) return _buildInspector(context);
                    return Column(children: [
                      SizedBox(
                          height: math.min(320, c.maxHeight * .52),
                          child: _buildInspector(context)),
                      const Divider(),
                      Expanded(child: grid),
                    ]);
                  })),
                ])));
  }

  Widget _grid(BuildContext context) => LayoutBuilder(builder: (context, c) {
        if (_layout.widgets.isEmpty) {
          return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('A clear canvas.'),
            const SizedBox(height: 12),
            TextButton(
                onPressed: () {
                  _begin();
                  setState(() => _inspector = true);
                },
                child: const Text('Add your first report')),
          ]));
        }
        final narrow =
            c.maxWidth < 760 || MediaQuery.textScalerOf(context).scale(14) > 21;
        final ordered = [
          ..._layout.widgets
        ]..sort((a, b) => a.y != b.y ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
        if (narrow) {
          return ListView.builder(
              key: ValueKey('dashboard-list-${widget.contextKey}'),
              itemCount: ordered.length,
              itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: SizedBox(
                      height: math.max(310, ordered[i].height * 72.0),
                      child: _tile(context, ordered[i], c.maxWidth / 12, 72))));
        }
        const rowHeight = 78.0;
        final column = c.maxWidth / 12;
        final bottom =
            _layout.widgets.fold<int>(0, (n, w) => math.max(n, w.y + w.height));
        final reduced = MediaQuery.of(context).disableAnimations;
        return SingleChildScrollView(
            key: ValueKey('dashboard-grid-${widget.contextKey}'),
            child: SizedBox(
                height: bottom * rowHeight,
                child: Stack(children: [
                  for (final spec in _layout.widgets)
                    AnimatedPositioned(
                        key: ValueKey('position-${spec.id}'),
                        duration: reduced
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        left: spec.x * column,
                        top: spec.y * rowHeight,
                        width: spec.width * column - 18,
                        height: spec.height * rowHeight - 18,
                        child: _tile(context, spec, column, rowHeight)),
                ])));
      });

  Widget _tile(BuildContext context, DashboardWidgetSpec spec, double column,
      double rowHeight) {
    final rows = dashboardScopeRows(widget.machines, spec,
        fleetId: _fleetId, machineFleetIds: widget.machineFleetIds);
    final selected = _selected == spec.id;
    final theme = Theme.of(context);
    Widget handle({bool resize = false}) {
      Offset delta = Offset.zero;
      return Focus(
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
              return KeyEventResult.ignored;
            }
            final key = event.logicalKey;
            final dx = key == LogicalKeyboardKey.arrowLeft
                ? -1
                : key == LogicalKeyboardKey.arrowRight
                    ? 1
                    : 0;
            final dy = key == LogicalKeyboardKey.arrowUp
                ? -1
                : key == LogicalKeyboardKey.arrowDown
                    ? 1
                    : 0;
            if (dx == 0 && dy == 0) return KeyEventResult.ignored;
            _move(spec, dx, dy,
                resize: resize || HardwareKeyboard.instance.isShiftPressed);
            return KeyEventResult.handled;
          },
          child: GestureDetector(
              onPanStart: _saving
                  ? null
                  : (_) {
                      delta = Offset.zero;
                      setState(() => _selected = spec.id);
                    },
              onPanUpdate: _saving ? null : (d) => delta += d.delta,
              onPanEnd: _saving
                  ? null
                  : (_) => _move(spec, (delta.dx / column).round(),
                      (delta.dy / rowHeight).round(), resize: resize),
              child: IconButton(
                  tooltip: resize
                      ? 'Resize ${dashboardReportTitle(spec.report)}'
                      : 'Move ${dashboardReportTitle(spec.report)}',
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                            _selected = spec.id;
                            _inspector = true;
                          }),
                  icon: Icon(resize ? Icons.open_in_full : Icons.drag_indicator,
                      size: 19))));
    }

    return Container(
        key: ValueKey('report-${spec.id}'),
        padding: const EdgeInsets.only(top: 8),
        decoration: BoxDecoration(
            border: _editing
                ? Border.all(
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.dividerColor)
                : Border(top: BorderSide(color: theme.dividerColor))),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(children: [
                if (_editing) handle(),
                Expanded(
                    child: Text(dashboardReportTitle(spec.report),
                        style: theme.textTheme.titleMedium)),
                if (_editing)
                  IconButton(
                      key: ValueKey('settings-${spec.id}'),
                      tooltip: 'Report settings',
                      onPressed: _saving
                          ? null
                          : () => setState(() {
                                _selected = spec.id;
                                _inspector = true;
                              }),
                      icon: const Icon(Icons.tune, size: 19)),
              ])),
          Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: Tooltip(
                  message: _scopeCaption(spec, rows),
                  child: Text(_scopeCaption(spec, rows),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant)))),
          Expanded(
              child: _ReportScroll(
                  key:
                      ValueKey('report-scroll-${widget.contextKey}-${spec.id}'),
                  id: spec.id,
                  label: dashboardReportTitle(spec.report),
                  child: DashboardReportBody(
                      spec: spec,
                      rows: rows,
                      healthFor: widget.healthFor,
                      now: widget.now ?? DateTime.now(),
                      fleets: widget.fleets,
                      machineFleetIds: widget.machineFleetIds,
                      onOpenMachine: widget.onOpenMachine))),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (widget.onExploreHealth != null)
              TextButton(
                  onPressed: widget.onExploreHealth,
                  child: const Text('Explore')),
            if (_editing) handle(resize: true),
          ]),
        ]));
  }

  String _scopeCaption(DashboardWidgetSpec spec, List<MachineRow> rows) {
    String name(String id) {
      for (final machine in widget.machines) {
        if (machine.id == id) return machine.displayName;
      }
      return 'Unavailable ($id)';
    }

    return switch (spec.scope) {
      DashboardScope.fleet => '${rows.length} machines in fleet filter',
      DashboardScope.average =>
        'Current fleet average · ${rows.length} machines',
      DashboardScope.single => spec.machineIds.isEmpty
          ? 'No machine selected'
          : '${name(spec.machineIds.first)}${rows.isEmpty ? ' · Outside this filter' : ''}',
      DashboardScope.multiple => spec.machineIds.isEmpty
          ? 'No machines selected'
          : '${spec.machineIds.map(name).join(', ')} · ${rows.length} of ${spec.machineIds.length} in filter',
    };
  }

  Widget _buildInspector(BuildContext context) {
    final spec = _selection;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
            child: Text(spec == null ? 'Add a report' : 'Report settings',
                style: Theme.of(context).textTheme.titleLarge)),
        IconButton(
            tooltip: 'Close inspector',
            onPressed: () => setState(() => _inspector = false),
            icon: const Icon(Icons.close))
      ]),
      const Divider(height: 8),
      Expanded(
          child: SingleChildScrollView(
              key: ValueKey('inspector-${spec?.id ?? 'catalog'}'),
              padding: const EdgeInsets.only(right: 8),
              child: spec == null
                  ? Column(children: [
                      for (final report in DashboardReport.values)
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(dashboardReportTitle(report)),
                            subtitle: Text(_description(report)),
                            trailing: const Icon(Icons.add),
                            onTap: _saving ? null : () => _add(report))
                    ])
                  : _settings(context, spec))),
      if (spec != null) ...[
        const Divider(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton(
              onPressed: _saving ? null : () => _duplicate(spec),
              child: const Text('Duplicate')),
          TextButton(
              onPressed: _saving
                  ? null
                  : () {
                      _remember(_layout.copyWith(
                          widgets: _layout.widgets
                              .where((w) => w.id != spec.id)
                              .toList()));
                      setState(() => _selected = null);
                    },
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Remove')),
        ]),
      ],
    ]);
  }

  String _description(DashboardReport report) => switch (report) {
        DashboardReport.availability => 'Reachability of each named machine',
        DashboardReport.cpu => 'Processing load, current readings and history',
        DashboardReport.memory => 'Memory use across reporting machines',
        DashboardReport.disk => 'Used capacity of the fullest filesystem',
        DashboardReport.trends => 'Real performance samples over time',
        DashboardReport.attention =>
          'Thresholds, drive warnings and overdue reports',
        DashboardReport.fleets => 'Compare server-owned fleet membership',
        DashboardReport.freshness =>
          'Collector source timestamps and reporting gaps',
      };
  Widget _settings(BuildContext context, DashboardWidgetSpec spec) {
    Widget dropdown<T>(String label, T value, List<T> values,
            String Function(T) name, ValueChanged<T> changed) =>
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: DropdownButtonFormField<T>(
                key: ValueKey('${spec.id}-$label-$value'),
                value: value,
                isExpanded: true,
                decoration: InputDecoration(labelText: label),
                items: [
                  for (final item in values)
                    DropdownMenuItem(
                        value: item,
                        child:
                            Text(name(item), overflow: TextOverflow.ellipsis))
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) changed(value);
                      }));
    String title(Object value) {
      final text = value.toString().split('.').last;
      return '${text[0].toUpperCase()}${text.substring(1)}';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      dropdown(
          'Report type',
          spec.report,
          DashboardReport.values,
          dashboardReportTitle,
          (report) => _update(spec.copyWith(report: report))),
      dropdown('Presentation', spec.style, DashboardStyle.values, title,
          (style) => _update(spec.copyWith(style: style))),
      dropdown(
          'Machine scope',
          spec.scope,
          DashboardScope.values,
          (scope) => switch (scope) {
                DashboardScope.fleet => 'All machines in fleet filter',
                DashboardScope.single => 'One machine',
                DashboardScope.multiple => 'Selected machines',
                DashboardScope.average => 'Fleet average'
              },
          (scope) => _update(spec.copyWith(
              scope: scope,
              machineIds: scope == DashboardScope.single
                  ? spec.machineIds.take(1).toList()
                  : spec.machineIds))),
      if (spec.scope == DashboardScope.single ||
          spec.scope == DashboardScope.multiple) ...[
        const Text('Machines', style: TextStyle(fontWeight: FontWeight.w600)),
        const Text(
            'Selections stay independent for each report. The fleet filter intersects these IDs.',
            style: TextStyle(fontSize: 12)),
        for (final machine in widget.machines)
          CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(machine.displayName),
              subtitle: Text(machine.id, style: const TextStyle(fontSize: 11)),
              value: spec.machineIds.contains(machine.id),
              onChanged: _saving
                  ? null
                  : (selected) {
                      final ids = [...spec.machineIds];
                      if (selected == true) {
                        if (spec.scope == DashboardScope.single) ids.clear();
                        ids.add(machine.id);
                      } else {
                        ids.remove(machine.id);
                      }
                      _update(spec.copyWith(machineIds: ids));
                    }),
        for (final id in spec.machineIds
            .where((id) => !widget.machines.any((m) => m.id == id)))
          CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Unavailable machine · $id'),
              value: true,
              onChanged: _saving
                  ? null
                  : (_) => _update(spec.copyWith(
                      machineIds:
                          spec.machineIds.where((m) => m != id).toList()))),
      ],
      const SizedBox(height: 12),
      const Text('Size & position',
          style: TextStyle(fontWeight: FontWeight.w600)),
      dropdown(
          'Width (columns)',
          spec.width,
          List.generate(13 - spec.minimumWidth, (i) => spec.minimumWidth + i),
          (n) => '$n',
          (n) => _update(spec.copyWith(width: n))),
      dropdown(
          'Height (rows)',
          spec.height,
          List.generate(9 - spec.minimumHeight, (i) => spec.minimumHeight + i),
          (n) => '$n',
          (n) => _update(spec.copyWith(height: n))),
      dropdown('Column', spec.x, List.generate(13 - spec.width, (i) => i),
          (n) => '${n + 1}', (n) => _update(spec.copyWith(x: n))),
      dropdown(
          'Row',
          spec.y,
          List.generate(dashboardMaxRows - spec.height + 1, (i) => i),
          (n) => '${n + 1}',
          (n) => _update(spec.copyWith(y: n))),
      const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text(
              '12-column layout. Moving or resizing a report shifts overlapping reports. Close gaps packs reports without changing their size.',
              style: TextStyle(fontSize: 12))),
    ]);
  }
}

class _ReportScroll extends StatefulWidget {
  const _ReportScroll(
      {super.key, required this.id, required this.label, required this.child});
  final String id;
  final String label;
  final Widget child;

  @override
  State<_ReportScroll> createState() => _ReportScrollState();
}

class _ReportScrollState extends State<_ReportScroll> {
  final _controller = ScrollController();
  bool _focused = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  KeyEventResult _scroll(FocusNode node, KeyEvent event) {
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        !_controller.hasClients) {
      return KeyEventResult.ignored;
    }
    final position = _controller.position;
    final target = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => position.pixels + 48,
      LogicalKeyboardKey.arrowUp => position.pixels - 48,
      LogicalKeyboardKey.pageDown =>
        position.pixels + position.viewportDimension * .8,
      LogicalKeyboardKey.pageUp =>
        position.pixels - position.viewportDimension * .8,
      LogicalKeyboardKey.home => position.minScrollExtent,
      LogicalKeyboardKey.end => position.maxScrollExtent,
      _ => null,
    };
    if (target == null) return KeyEventResult.ignored;
    _controller.jumpTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
      key: ValueKey('report-focus-${widget.id}'),
      onKeyEvent: _scroll,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: Semantics(
          label: '${widget.label} report, scroll for more machines',
          child: DecoratedBox(
              decoration: BoxDecoration(
                  border: Border.all(
                      color: _focused
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent)),
              child: Scrollbar(
                  controller: _controller,
                  thumbVisibility: true,
                  trackVisibility: true,
                  interactive: true,
                  child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context)
                          .copyWith(scrollbars: false),
                      child: SingleChildScrollView(
                          key: ValueKey('report-body-${widget.id}'),
                          controller: _controller,
                          primary: false,
                          padding: const EdgeInsets.only(left: 10, right: 18),
                          child: widget.child))))));
}
