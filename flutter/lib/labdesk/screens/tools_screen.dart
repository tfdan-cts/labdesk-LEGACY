import 'package:flutter/material.dart';

import '../../common/labdesk_peer_status.dart';
import '../models/machine_row.dart';
import '../models/tool_models.dart';
import '../services/tool_catalog.dart';
import '../theme/console_theme.dart';
import '../theme/ld_icons.dart';

/// The toolbox: pick machines, pick a tool, read the answers side by side.
///
/// Presentational, like every other console screen. It takes rows, a
/// selection, results and a script library, and hands back what the operator
/// asked for. Nothing here opens a connection or knows a command exists —
/// [ToolCatalog] holds the commands and the caller runs them — so the screen
/// stays renderable and testable without the bridge.
///
/// The shape is deliberate: machines across the top, tools down the left,
/// answers on the right, one table per machine. An operator running a tool on
/// nine machines is comparing them, and a tabbed result would make them do
/// that from memory.
class ToolsScreen extends StatefulWidget {
  const ToolsScreen({
    super.key,
    required this.machines,
    this.selectedIds = const {},
    this.onSelectionChanged,
    this.tool,
    this.onToolChanged,
    this.results = const {},
    this.busyIds = const {},
    this.onRun,
    this.onAction,
    this.library = ScriptLibrary.empty,
    this.onSaveScript,
    this.onDeleteScript,
    this.onRunScript,
  });

  final List<MachineRow> machines;

  /// The machines the operator has ticked. Held by the caller so the selection
  /// survives leaving the screen, which is what an operator working through a
  /// site expects.
  final Set<String> selectedIds;
  final ValueChanged<Set<String>>? onSelectionChanged;

  /// The tool on show. Null lets the screen pick and keep its own, which is
  /// enough for a caller that only wants to hand results back; supply it (with
  /// [onToolChanged]) when the caller needs to know which tool the results in
  /// [results] belong to.
  final ToolId? tool;
  final ValueChanged<ToolId>? onToolChanged;

  /// The last answer from each machine, for the tool currently on show.
  final Map<String, ToolRunResult> results;

  /// Machines with a command in flight.
  final Set<String> busyIds;

  final void Function(ToolId tool, Set<String> machineIds)? onRun;

  /// A row action or a power action. [target] is the service name or process
  /// id the row carried, and is null for the power actions, which need none.
  final void Function(
    ToolId tool,
    ToolAction action,
    String machineId,
    String? target,
  )? onAction;

  final ScriptLibrary library;
  final ValueChanged<SavedScript>? onSaveScript;
  final ValueChanged<String>? onDeleteScript;
  final void Function(SavedScript script, Set<String> machineIds)? onRunScript;

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  ToolId _tool = ToolId.services;

  /// The script being written. Null means the editor is closed; a script with
  /// an empty id means a new one.
  SavedScript? _draft;
  final _name = TextEditingController();
  final _body = TextEditingController();

  /// A table this long is a scroll nobody reads, and rendering three of them
  /// side by side is a stutter. The count above the table says what was cut.
  static const _maxRows = 200;

  @override
  void initState() {
    super.initState();
    _tool = widget.tool ?? ToolId.services;
  }

  @override
  void didUpdateWidget(covariant ToolsScreen old) {
    super.didUpdateWidget(old);
    final t = widget.tool;
    if (t != null && t != _tool) _tool = t;
  }

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  // ---- selection ----------------------------------------------------------

  /// The selection as it can actually be seen.
  ///
  /// A tick is remembered by id and a machine can leave the list under one, so
  /// every count and every run reads through this rather than off the raw set.
  List<MachineRow> get _picked => [
        for (final m in widget.machines)
          if (widget.selectedIds.contains(m.id)) m
      ];

  void _toggle(String id) {
    final next = Set<String>.from(widget.selectedIds);
    if (!next.remove(id)) next.add(id);
    widget.onSelectionChanged?.call(next);
  }

  void _setAll(bool on) {
    widget.onSelectionChanged?.call(on
        ? {
            for (final m in widget.machines)
              if (m.status == LabDeskPeerStatus.online) m.id
          }
        : <String>{});
  }

  void _pickTool(ToolId id) {
    setState(() => _tool = id);
    widget.onToolChanged?.call(id);
  }

  // ---- running ------------------------------------------------------------

  void _run() {
    final ids = {for (final m in _picked) m.id};
    if (ids.isEmpty) return;
    widget.onRun?.call(_tool, ids);
  }

  Future<void> _act(
    ToolAction action,
    MachineRow machine,
    String? target,
  ) async {
    if (action.isDestructive) {
      final what = target == null
          ? action.label.toLowerCase()
          : '${action.label.toLowerCase()} "$target"';
      final ok = await _confirm(
        context,
        title: '${action.label} on ${machine.displayName}?',
        body: 'LabDesk will $what on ${machine.displayName} '
            '(${machine.id}). This happens on the machine straight away and '
            'nothing here can take it back.',
        confirmLabel: action.label,
      );
      if (!ok || !mounted) return;
    }
    widget.onAction?.call(_tool, action, machine.id, target);
  }

  // ---- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _picker(),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 232, child: _toolList()),
                const SizedBox(width: 16),
                Expanded(child: _results()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _picker() {
    final online = [
      for (final m in widget.machines)
        if (m.status == LabDeskPeerStatus.online) m
    ];
    final rest = [
      for (final m in widget.machines)
        if (m.status != LabDeskPeerStatus.online) m
    ];
    final n = _picked.length;
    return Panel(
      title: 'Machines',
      subtitle: n == 0
          ? 'Nothing picked. A tool runs on every machine ticked here.'
          : '$n ${n == 1 ? 'machine' : 'machines'} picked.',
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      actions: [
        GhostButton(
          key: const ValueKey('tools-select-online'),
          label: 'All online',
          onPressed: widget.onSelectionChanged == null || online.isEmpty
              ? null
              : () => _setAll(true),
        ),
        const SizedBox(width: 8),
        GhostButton(
          key: const ValueKey('tools-select-none'),
          label: 'None',
          onPressed:
              widget.onSelectionChanged == null || n == 0 ? null : () => _setAll(false),
        ),
      ],
      child: widget.machines.isEmpty
          ? Text('No machines yet.', style: C.of(context).small(color: C.of(context).textFaint))
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // Online first: they are the only ones a tool can reach, and
                // an operator scanning for one should not read past the dead.
                for (final m in [...online, ...rest])
                  _MachineChip(
                    key: ValueKey('tools-machine-${m.id}'),
                    machine: m,
                    selected: widget.selectedIds.contains(m.id),
                    busy: widget.busyIds.contains(m.id),
                    onTap: widget.onSelectionChanged == null
                        ? null
                        : () => _toggle(m.id),
                  ),
              ],
            ),
    );
  }

  Widget _toolList() {
    return Panel(
      title: 'Tools',
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      fill: true,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final id in ToolId.values)
              _ToolRow(
                key: ValueKey('tool-${id.name}'),
                tool: id,
                selected: id == _tool,
                onTap: () => _pickTool(id),
              ),
          ],
        ),
      ),
    );
  }

  Widget _results() {
    final picked = _picked;
    final runnable = _tool.listsSomething && picked.isNotEmpty;
    return Panel(
      title: _tool.label,
      subtitle: _tool.blurb,
      padding: EdgeInsets.zero,
      fill: true,
      actions: [
        if (_tool.listsSomething)
          GhostButton(
            key: const ValueKey('tools-run'),
            label: 'Run',
            glyph: LdIcons.resume,
            busy: picked.any((m) => widget.busyIds.contains(m.id)),
            onPressed: runnable && widget.onRun != null ? _run : null,
          ),
      ],
      child: picked.isEmpty
          ? Center(
              child: Text('Pick a machine above.',
                  style: C.of(context).small(color: C.of(context).textFaint)),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_tool == ToolId.scripts) ...[
                    _library(picked),
                    const SizedBox(height: 18),
                  ],
                  for (final m in picked) ...[
                    _machineSection(m),
                    const SizedBox(height: 18),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _machineSection(MachineRow m) {
    final result = widget.results[m.id];
    final busy = widget.busyIds.contains(m.id);
    return Column(
      key: ValueKey('tools-result-${m.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: m.status == LabDeskPeerStatus.online ? C.of(context).ok : C.of(context).idle,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Text(m.displayName, style: C.of(context).h2()),
            const SizedBox(width: 10),
            Text(m.platform, style: C.of(context).data(size: 11, color: C.of(context).textFaint)),
          ],
        ),
        const SizedBox(height: 10),
        if (_tool == ToolId.power)
          _powerRow(m)
        else if (busy)
          _note('Asking ${m.displayName}...')
        else if (result == null)
          _note(_tool == ToolId.scripts
              ? 'No script has been run here yet.'
              : 'Not read yet. Press Run.')
        else if (result.error != null)
          _note(result.error!, bad: true)
        else if (result.table == null || result.table!.isEmpty)
          _note('The machine answered with nothing.')
        else
          _table(m, result.table!),
      ],
    );
  }

  Widget _note(String text, {bool bad = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(text,
            style: C.of(context).small(color: bad ? C.of(context).bad : C.of(context).textFaint)),
      );

  Widget _powerRow(MachineRow m) {
    final enabled = widget.onAction != null &&
        ToolCatalog.platformKey(m.platform) != null &&
        m.status == LabDeskPeerStatus.online;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final a in ToolCatalog.powerActions)
          a.isDestructive
              ? _DangerButton(
                  buttonKey: ValueKey('tools-power-${a.name}-${m.id}'),
                  label: a.label,
                  onPressed: enabled ? () => _act(a, m, null) : null,
                )
              : GhostButton(
                  key: ValueKey('tools-power-${a.name}-${m.id}'),
                  label: a.label,
                  glyph: LdIcons.lock,
                  onPressed: enabled ? () => _act(a, m, null) : null,
                ),
      ],
    );
  }

  /// The row actions a tool offers, and which field of the row is their target.
  List<ToolAction> _rowActions() => switch (_tool) {
        ToolId.services => const [
            ToolAction.startService,
            ToolAction.stopService,
            ToolAction.restartService,
          ],
        ToolId.processes => const [ToolAction.killProcess],
        _ => const [],
      };

  Widget _table(MachineRow m, ToolTable table) {
    final actions = _rowActions();
    final shown = table.rows.length > _maxRows
        ? table.rows.sublist(0, _maxRows)
        : table.rows;
    // Wider last column: names and messages are what actually vary in length.
    final flex = [
      for (var i = 0; i < table.columns.length; i++)
        i == table.columns.length - 1 ? 3 : 2
    ];
    return Container(
      decoration: BoxDecoration(
        color: C.of(context).bg,
        borderRadius: C.roundedSm,
        border: Border.all(color: C.of(context).hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            child: Row(
              children: [
                for (var i = 0; i < table.columns.length; i++)
                  Expanded(
                    flex: flex[i],
                    child: Text(table.columns[i], style: C.of(context).micro()),
                  ),
                if (actions.isNotEmpty)
                  const Expanded(flex: 8, child: SizedBox.shrink()),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: C.of(context).hairline),
          for (final row in shown)
            _TableRow(
              cells: row,
              flex: flex,
              actions: [
                for (final a in actions)
                  (
                    label: a.label,
                    destructive: a.isDestructive,
                    onPressed: widget.onAction == null
                        ? null
                        : () => _act(a, m, row.isEmpty ? null : row.first),
                  ),
              ],
            ),
          if (table.rows.length > shown.length)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
              child: Text(
                'Showing the first ${shown.length} of ${table.rows.length}.',
                style: C.of(context).small(color: C.of(context).textFaint),
              ),
            ),
        ],
      ),
    );
  }

  // ---- scripts ------------------------------------------------------------

  void _edit(SavedScript? s) {
    setState(() {
      _draft = s ??
          const SavedScript(
              id: '', name: '', platform: ScriptPlatform.any, body: '');
      _name.text = _draft!.name;
      _body.text = _draft!.body;
    });
  }

  void _save() {
    final draft = _draft;
    if (draft == null) return;
    final name = _name.text.trim();
    final body = _body.text;
    if (name.isEmpty || body.trim().isEmpty) return;
    widget.onSaveScript?.call(SavedScript(
      // A new script is stamped once, here, rather than by the caller: the id
      // has to survive the save that creates it or the next edit makes a
      // second copy instead of replacing the first.
      id: draft.id.isEmpty
          ? 's${DateTime.now().microsecondsSinceEpoch}'
          : draft.id,
      name: name,
      platform: draft.platform,
      body: body,
    ));
    setState(() => _draft = null);
  }

  Widget _library(List<MachineRow> picked) {
    final draft = _draft;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: C.of(context).bg,
        borderRadius: C.roundedSm,
        border: Border.all(color: C.of(context).hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Saved scripts', style: C.of(context).h2())),
              GhostButton(
                key: const ValueKey('tools-script-new'),
                label: 'New script',
                glyph: LdIcons.add,
                onPressed: widget.onSaveScript == null ? null : () => _edit(null),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (widget.library.isEmpty)
            Text(
              'Nothing saved. A script is one or more shell lines; LabDesk '
              'joins them with a semicolon and sends them as one line, '
              'because that is all the channel takes.',
              style: C.of(context).small(color: C.of(context).textFaint),
            )
          else
            for (final s in widget.library.scripts)
              _ScriptRow(
                key: ValueKey('tools-script-${s.id}'),
                script: s,
                targets: picked.where((m) => s.platform.matches(m.platform)).length,
                onEdit: widget.onSaveScript == null ? null : () => _edit(s),
                onDelete: widget.onDeleteScript == null
                    ? null
                    : () => widget.onDeleteScript!(s.id),
                onRun: widget.onRunScript == null || picked.isEmpty
                    ? null
                    : () => widget.onRunScript!(s, {
                          for (final m in picked)
                            if (s.platform.matches(m.platform)) m.id
                        }),
              ),
          if (draft != null) ...[
            const SizedBox(height: 14),
            Divider(height: 1, thickness: 1, color: C.of(context).hairline),
            const SizedBox(height: 14),
            _field('Name', _name, key: const ValueKey('tools-script-name')),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Runs on', style: C.of(context).micro()),
                for (final p in ScriptPlatform.values)
                  _SmallChip(
                    key: ValueKey('tools-script-platform-${p.id}'),
                    label: p.label,
                    selected: draft.platform == p,
                    onTap: () =>
                        setState(() => _draft = draft.copyWith(platform: p)),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _field('Command', _body,
                key: const ValueKey('tools-script-body'), lines: 4),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GhostButton(
                  label: 'Cancel',
                  onPressed: () => setState(() => _draft = null),
                ),
                const SizedBox(width: 8),
                GhostButton(
                  key: const ValueKey('tools-script-save'),
                  label: 'Save script',
                  glyph: LdIcons.check,
                  onPressed: _save,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _field(String label, TextEditingController c,
      {required Key key, int lines = 1}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: C.of(context).micro()),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: C.of(context).surface,
            borderRadius: C.roundedSm,
            border: Border.all(color: C.of(context).hairline),
          ),
          child: TextField(
            key: key,
            controller: c,
            maxLines: lines,
            style: C.of(context).data(size: 12.5, color: C.of(context).text),
            cursorColor: C.of(context).accent,
            cursorWidth: 1.6,
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }
}

// ---- pieces ---------------------------------------------------------------

class _MachineChip extends StatefulWidget {
  const _MachineChip({
    super.key,
    required this.machine,
    required this.selected,
    required this.busy,
    this.onTap,
  });

  final MachineRow machine;
  final bool selected;
  final bool busy;
  final VoidCallback? onTap;

  @override
  State<_MachineChip> createState() => _MachineChipState();
}

class _MachineChipState extends State<_MachineChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.machine;
    final online = m.status == LabDeskPeerStatus.online;
    final enabled = widget.onTap != null;
    final fg = !enabled
        ? C.of(context).textFaint
        : widget.selected
            ? C.of(context).accent
            : (_hover ? C.of(context).text : C.of(context).textMuted);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: C.fast,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? C.of(context).accent.withOpacity(0.14)
                : (_hover && enabled ? C.of(context).surfaceHi : Colors.transparent),
            borderRadius: C.roundedSm,
            border: Border.all(
                color: widget.selected ? C.of(context).accentDim : C.of(context).hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LdCheckbox(
                  on: widget.selected, enabled: enabled, hover: _hover),
              const SizedBox(width: 8),
              // Offline machines still tick: a tool queued against one is the
              // operator's business, and hiding them would hide the fleet.
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                    color: online ? C.of(context).ok : C.of(context).idle, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Text(m.displayName, style: C.of(context).small(color: fg, w: FontWeight.w600)),
              if (widget.busy) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: C.of(context).accent),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolRow extends StatefulWidget {
  const _ToolRow({super.key, required this.tool, required this.selected, required this.onTap});

  final ToolId tool;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.selected ? C.of(context).accent : (_hover ? C.of(context).text : C.of(context).textMuted);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: C.fast,
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
          decoration: BoxDecoration(
            color: widget.selected
                ? C.of(context).accent.withOpacity(0.12)
                : (_hover ? C.of(context).surfaceHi : Colors.transparent),
            borderRadius: C.roundedSm,
            border: Border.all(
                color: widget.selected ? C.of(context).accentDim : Colors.transparent),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.tool.label,
                  style: C.of(context).small(color: fg, w: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(widget.tool.blurb,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: C.of(context).micro()),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _RowAction = ({String label, bool destructive, VoidCallback? onPressed});

class _TableRow extends StatefulWidget {
  const _TableRow({
    required this.cells,
    required this.flex,
    required this.actions,
  });

  final List<String> cells;
  final List<int> flex;
  final List<_RowAction> actions;

  @override
  State<_TableRow> createState() => _TableRowState();
}

class _TableRowState extends State<_TableRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        color: _hover ? C.of(context).surfaceHi : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Row(
          children: [
            for (var i = 0; i < widget.cells.length; i++)
              Expanded(
                flex: i < widget.flex.length ? widget.flex[i] : 2,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    widget.cells[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: C.of(context).data(size: 12, color: C.of(context).textMuted),
                  ),
                ),
              ),
            if (widget.actions.isNotEmpty)
              Expanded(
                flex: 8,
                // Scrolls rather than overflows. The buttons are as wide as
                // the operator's font makes them, and a table narrowed to fit
                // a second machine beside it must not clip the one control
                // that acts on the row.
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final a in widget.actions) ...[
                        const SizedBox(width: 6),
                        GhostButton(label: a.label, onPressed: a.onPressed),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ScriptRow extends StatelessWidget {
  const _ScriptRow({
    super.key,
    required this.script,
    required this.targets,
    this.onEdit,
    this.onDelete,
    this.onRun,
  });

  final SavedScript script;
  final int targets;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onRun;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(script.name, style: C.of(context).small(color: C.of(context).text, w: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  '${script.platform.label}  ·  $targets of the picked machines',
                  style: C.of(context).micro(),
                ),
              ],
            ),
          ),
          GhostButton(label: 'Edit', onPressed: onEdit),
          const SizedBox(width: 6),
          GhostButton(label: 'Delete', glyph: LdIcons.trash, onPressed: onDelete),
          const SizedBox(width: 6),
          GhostButton(
            key: ValueKey('tools-script-run-${script.id}'),
            label: 'Run',
            glyph: LdIcons.resume,
            onPressed: targets == 0 ? null : onRun,
          ),
        ],
      ),
    );
  }
}

class _SmallChip extends StatelessWidget {
  const _SmallChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? C.of(context).accent.withOpacity(0.14) : Colors.transparent,
          borderRadius: C.roundedSm,
          border: Border.all(color: selected ? C.of(context).accentDim : C.of(context).hairline),
        ),
        child: Text(label,
            style: C.of(context).small(
                color: selected ? C.of(context).accent : C.of(context).textMuted, w: FontWeight.w600)),
      ),
    );
  }
}

/// Asks before something irreversible, in the console's own surfaces.
///
/// The same dialog Connect puts in front of forgetting a machine, copied
/// rather than shared: the shared `ldDialog` reaches the FFI layer, and no
/// screen under `labdesk/screens` is allowed to.
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0xAA000000),
    builder: (ctx) => Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          key: const ValueKey('tools-confirm'),
          width: 400,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          decoration: BoxDecoration(
            color: C.of(context).surface,
            borderRadius: C.rounded,
            border: Border.all(color: C.of(context).hairline),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 28,
                  offset: Offset(0, 12)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: C.of(context).h2()),
              const SizedBox(height: 8),
              Text(body, style: C.of(context).small(color: C.of(context).textFaint)),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  GhostButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.pop(ctx, false),
                  ),
                  const SizedBox(width: 8),
                  _DangerButton(
                    label: confirmLabel,
                    onPressed: () => Navigator.pop(ctx, true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return ok ?? false;
}

/// The one button here that is not the accent. A destructive confirmation that
/// looks like every other primary action is a confirmation nobody reads.
class _DangerButton extends StatefulWidget {
  const _DangerButton({
    this.buttonKey = const ValueKey('tools-confirm-go'),
    required this.label,
    required this.onPressed,
  });

  final Key buttonKey;
  final String label;
  final VoidCallback? onPressed;

  @override
  State<_DangerButton> createState() => _DangerButtonState();
}

class _DangerButtonState extends State<_DangerButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: widget.buttonKey,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: C.fast,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: !enabled
                ? Colors.transparent
                : C.of(context).bad.withOpacity(_hover ? 0.2 : 0.12),
            borderRadius: C.roundedSm,
            border: Border.all(color: C.of(context).bad.withOpacity(enabled ? 0.55 : 0.2)),
          ),
          child: Text(
            widget.label,
            style: C.of(context).small(
                color: enabled ? C.of(context).bad : C.of(context).bad.withOpacity(0.45),
                w: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}
