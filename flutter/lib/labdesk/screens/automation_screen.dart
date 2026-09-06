import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/automation_models.dart';
import '../models/automation_presets.dart';
import '../models/machine_row.dart';
import '../services/automation_engine.dart';
import '../theme/console_theme.dart';
import '../theme/ld_icons.dart';

/// Rules the console runs against the fleet, and what they have done lately.
///
/// The line at the top of this screen is not decoration. Every other product
/// that offers automation runs it on a server, and an operator arriving here
/// will assume the same unless told otherwise. These rules are evaluated by
/// this console, on this machine, while LabDesk is open; close it and nothing
/// runs. Saying so once, plainly, above the list is the difference between a
/// tool and a promise it cannot keep.
///
/// Presentational like every other screen under `lib/labdesk`: it takes the
/// rules, the log and the machines, and hands back a saved list, a toggle and a
/// run request. Nothing here touches the client, the engine or the FFI.
class AutomationScreen extends StatefulWidget {
  const AutomationScreen({
    super.key,
    required this.rules,
    this.log = const [],
    this.machines = const [],
    this.onSave,
    this.onToggle,
    this.onRunNow,
    this.onApplyPreset,
    this.now,
  });

  final List<Rule> rules;

  /// Newest first, as [RunLog.entries] hands it over.
  final List<RunLogEntry> log;

  final List<MachineRow> machines;

  /// The whole list, after an add, an edit or a delete. One callback rather
  /// than three: the client persists the list as one value.
  final ValueChanged<List<Rule>>? onSave;

  /// One of the ready-made rules, applied. The client mints the id, which is
  /// why this is not just an [onSave] of a rule built here.
  final ValueChanged<AutomationPreset>? onApplyPreset;

  final void Function(String ruleId, bool enabled)? onToggle;
  final ValueChanged<String>? onRunNow;
  final DateTime? now;

  @override
  State<AutomationScreen> createState() => _AutomationScreenState();
}

class _AutomationScreenState extends State<AutomationScreen> {
  /// The rule being edited, or null when the editor is closed. A copy: nothing
  /// the operator types reaches the list until Save.
  _Draft? _draft;

  String _nameOf(String id) {
    for (final m in widget.machines) {
      if (m.id == id) return m.displayName;
    }
    return id;
  }

  void _open(Rule? rule) {
    setState(() {
      _draft?.dispose();
      _draft = _Draft(rule, isNew: rule == null);
    });
  }

  void _close() {
    setState(() {
      _draft?.dispose();
      _draft = null;
    });
  }

  @override
  void dispose() {
    _draft?.dispose();
    super.dispose();
  }

  void _save() {
    final draft = _draft;
    if (draft == null) return;
    final rule = draft.build();
    final next = [...widget.rules];
    final at = next.indexWhere((r) => r.id == rule.id);
    if (at >= 0) {
      next[at] = rule;
    } else {
      next.add(rule);
    }
    widget.onSave?.call(next);
    _close();
  }

  void _delete(String id) {
    widget.onSave?.call([
      for (final r in widget.rules)
        if (r.id != id) r,
    ]);
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Notice(),
          const SizedBox(height: 16),
          if (widget.onApplyPreset != null) ...[
            _Presets(
              applied: {for (final r in widget.rules) r.name},
              onApply: widget.onApplyPreset!,
            ),
            const SizedBox(height: 16),
          ],
          Panel(
            title: 'Rules',
            subtitle: widget.rules.isEmpty
                ? null
                : '${widget.rules.where((r) => r.enabled).length} of '
                    '${widget.rules.length} enabled',
            actions: [
              GhostButton(
                label: 'New rule',
                glyph: LdIcons.add,
                onPressed: widget.onSave == null ? null : () => _open(null),
              ),
            ],
            padding: EdgeInsets.zero,
            child: widget.rules.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(18, 22, 18, 26),
                    child: Text(
                      'No rules yet. A rule watches one thing and does one '
                      'thing: a machine going offline, a disk filling up, a '
                      'time of day.',
                      style:
                          C.of(context).small(color: C.of(context).textFaint),
                    ),
                  )
                : Column(
                    children: [
                      for (final r in widget.rules)
                        _RuleRow(
                          rule: r,
                          sentence: r.sentence(_nameOf),
                          last: _lastFor(r.id),
                          selected: draft?.id == r.id,
                          now: widget.now,
                          onToggle: widget.onToggle == null
                              ? null
                              : (v) => widget.onToggle!(r.id, v),
                          onEdit: widget.onSave == null ? null : () => _open(r),
                          onRunNow: widget.onRunNow == null
                              ? null
                              : () => widget.onRunNow!(r.id),
                        ),
                    ],
                  ),
          ),
          if (draft != null) ...[
            const SizedBox(height: 16),
            _Editor(
              draft: draft,
              machines: widget.machines,
              onChanged: () => setState(() {}),
              onSave: _save,
              onCancel: _close,
              onDelete: draft.isNew ? null : () => _delete(draft.id),
            ),
          ],
          const SizedBox(height: 16),
          Panel(
            title: 'Recent activity',
            subtitle: 'The last ${RunLog.capacity} times a rule fired, and '
                'what came back.',
            padding: EdgeInsets.zero,
            child: widget.log.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(18, 22, 18, 26),
                    child: Text('Nothing has fired yet.',
                        style: C
                            .of(context)
                            .small(color: C.of(context).textFaint)),
                  )
                : Column(
                    children: [
                      for (final e in widget.log.take(50))
                        _LogRow(entry: e, machineName: _nameOf(e.machineId)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  RunLogEntry? _lastFor(String ruleId) {
    for (final e in widget.log) {
      if (e.ruleId == ruleId) return e;
    }
    return null;
  }
}

/// The one thing an operator must read before writing a rule.
class _Notice extends StatelessWidget {
  const _Notice();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: C.of(context).surface,
        borderRadius: C.rounded,
        border: Border.all(color: C.of(context).hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LdIcon(LdIcons.info, size: 16, color: C.of(context).textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Rules run only while LabDesk is open on this machine. The '
                'figures come from the machines themselves, reported to '
                'lab-desk.net on their flush, but this console is what checks the conditions, '
                'once a second, and does the work over its own connection.',
                style: C.of(context).small(color: C.of(context).textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuleRow extends StatefulWidget {
  const _RuleRow({
    required this.rule,
    required this.sentence,
    required this.last,
    required this.selected,
    this.now,
    this.onToggle,
    this.onEdit,
    this.onRunNow,
  });

  final Rule rule;
  final String sentence;
  final RunLogEntry? last;
  final bool selected;
  final DateTime? now;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onEdit;
  final VoidCallback? onRunNow;

  @override
  State<_RuleRow> createState() => _RuleRowState();
}

class _RuleRowState extends State<_RuleRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.rule;
    final last = widget.last;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onEdit,
        child: Container(
          decoration: BoxDecoration(
            color: widget.selected
                ? C.of(context).surfaceHi
                : (_hover
                    ? C.of(context).surfaceHi.withOpacity(0.5)
                    : Colors.transparent),
            border: Border(top: BorderSide(color: C.of(context).hairline)),
          ),
          padding: const EdgeInsets.fromLTRB(18, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.name.isEmpty ? 'Untitled rule' : r.name,
                        style: C.of(context).body(
                            color: r.enabled
                                ? C.of(context).text
                                : C.of(context).textMuted)),
                    const SizedBox(height: 3),
                    Text(widget.sentence,
                        style: C.of(context).small(
                            color: r.enabled
                                ? C.of(context).textMuted
                                : C.of(context).textFaint)),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              SizedBox(
                width: 128,
                child: Text(
                  last == null
                      ? 'Never fired'
                      : 'Fired ${_ago(last.at, widget.now)}',
                  style: C.of(context).data(
                      size: 11,
                      color: last == null
                          ? C.of(context).textFaint
                          : C.of(context).textMuted),
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: 14),
              if (widget.onRunNow != null)
                Opacity(
                  opacity: _hover || widget.selected ? 1 : 0.35,
                  child: GhostButton(
                      label: 'Run now',
                      glyph: LdIcons.resume,
                      onPressed: widget.onRunNow),
                ),
              const SizedBox(width: 12),
              LdToggle(value: r.enabled, onChanged: widget.onToggle),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry, required this.machineName});

  final RunLogEntry entry;
  final String machineName;

  @override
  Widget build(BuildContext context) {
    final ok = entry.ok;
    // Three states, not two. A firing whose outcome nobody has reported yet is
    // still running; painting it red would report a failure that has not
    // happened.
    final (color, word) = switch (ok) {
      null => (C.of(context).textFaint, 'running'),
      true => (C.of(context).ok, 'ok'),
      false => (C.of(context).bad, 'failed'),
    };
    return Container(
      decoration: BoxDecoration(
          border: Border(top: BorderSide(color: C.of(context).hairline))),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 66,
            child: Text(_clock(entry.at),
                style: C
                    .of(context)
                    .data(size: 11, color: C.of(context).textFaint)),
          ),
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(top: 5, right: 10),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.ruleName.isEmpty ? entry.ruleId : entry.ruleName} '
                  '· $machineName · ${entry.action.sentence}',
                  style: C.of(context).small(color: C.of(context).text),
                ),
                if (entry.detail != null && entry.detail!.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(entry.detail!,
                      style: C
                          .of(context)
                          .data(size: 11, color: C.of(context).textMuted)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(word, style: C.of(context).micro(color: color)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------------

/// Which trigger the editor is offering. The trigger classes are values, so the
/// chooser needs its own enumeration of the kinds to pick between.
enum _TriggerKind {
  cameOnline,
  wentOffline,
  metricAbove,
  uptimeAbove,
  every,
  atTime
}

enum _ActionKind { run, notify, wol, session }

/// The editor's working copy of a rule.
///
/// Held as loose fields rather than as a [Rule], because a half-typed threshold
/// is not a rule and building one on every keystroke would mean deciding what a
/// blank field means before the operator has finished saying.
class _Draft {
  _Draft(Rule? rule, {required this.isNew})
      : id = rule?.id ??
            'rule-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
        enabled = rule?.enabled ?? true,
        targets = List.of(rule?.targets ?? const [Rule.allTargets]),
        cooldownText = TextEditingController(
            text: (rule?.cooldown ?? const Duration(minutes: 10))
                .inMinutes
                .toString()),
        name = TextEditingController(text: rule?.name ?? '') {
    final t = rule?.trigger;
    switch (t) {
      case WentOffline(:final forMinutes):
        kind = _TriggerKind.wentOffline;
        forMinutesText.text = (forMinutes ?? 0).toString();
      case MetricAbove(:final metric, :final threshold, :final forMinutes):
        kind = _TriggerKind.metricAbove;
        this.metric = metric;
        thresholdText.text = threshold.round().toString();
        forMinutesText.text = forMinutes.toString();
      case UptimeAbove(:final days):
        kind = _TriggerKind.uptimeAbove;
        daysText.text = days.toString();
      case Schedule(
          :final isAtTime,
          :final every,
          :final hour,
          :final minute,
          weekdays: final days
        ):
        kind = isAtTime ? _TriggerKind.atTime : _TriggerKind.every;
        if (isAtTime) {
          hourText.text = hour!.toString();
          minuteText.text = minute!.toString().padLeft(2, '0');
          weekdays.addAll(days);
        } else {
          everyMinutesText.text = every!.inMinutes.toString();
        }
      case CameOnline():
      case null:
        kind = _TriggerKind.cameOnline;
    }

    final a = rule?.action;
    switch (a) {
      case RunCommand(:final command, :final platformHint):
        actionKind = _ActionKind.run;
        commandText.text = command;
        platformHintText.text = platformHint ?? '';
      case Notify(:final message):
        actionKind = _ActionKind.notify;
        messageText.text = message;
      case OpenSession():
        actionKind = _ActionKind.session;
      case WakeOnLan():
        actionKind = _ActionKind.wol;
      case null:
        actionKind = _ActionKind.notify;
    }
  }

  final String id;
  final bool isNew;
  final TextEditingController name;
  bool enabled;
  List<String> targets;
  final TextEditingController cooldownText;

  late _TriggerKind kind;
  late _ActionKind actionKind;
  AutoMetric metric = AutoMetric.cpu;
  final weekdays = <int>{};

  final forMinutesText = TextEditingController(text: '5');
  final thresholdText = TextEditingController(text: '90');
  final daysText = TextEditingController(text: '7');
  final everyMinutesText = TextEditingController(text: '60');
  final hourText = TextEditingController(text: '7');
  final minuteText = TextEditingController(text: '00');
  final commandText = TextEditingController();
  final platformHintText = TextEditingController();
  final messageText = TextEditingController();

  int _int(TextEditingController c, int fallback) =>
      int.tryParse(c.text.trim()) ?? fallback;

  AutomationTrigger buildTrigger() => switch (kind) {
        _TriggerKind.cameOnline => const CameOnline(),
        _TriggerKind.wentOffline => _int(forMinutesText, 0) <= 0
            ? const WentOffline()
            : WentOffline(forMinutes: _int(forMinutesText, 0)),
        _TriggerKind.metricAbove => MetricAbove(
            metric: metric,
            threshold: _int(thresholdText, 90).toDouble(),
            forMinutes: _int(forMinutesText, 0),
          ),
        _TriggerKind.uptimeAbove => UptimeAbove(days: _int(daysText, 7)),
        _TriggerKind.every => Schedule(
            every:
                Duration(minutes: _int(everyMinutesText, 60).clamp(1, 10080))),
        _TriggerKind.atTime => Schedule.atTime(
            hour: _int(hourText, 0).clamp(0, 23),
            minute: _int(minuteText, 0).clamp(0, 59),
            weekdays: weekdays.toList()..sort(),
          ),
      };

  AutomationAction buildAction() => switch (actionKind) {
        _ActionKind.run => RunCommand(
            command: commandText.text.trim(),
            platformHint: platformHintText.text.trim().isEmpty
                ? null
                : platformHintText.text.trim(),
          ),
        _ActionKind.notify => Notify(message: messageText.text.trim()),
        _ActionKind.wol => const WakeOnLan(),
        _ActionKind.session => const OpenSession(),
      };

  Rule build() => Rule(
        id: id,
        name: name.text.trim(),
        enabled: enabled,
        trigger: buildTrigger(),
        action: buildAction(),
        targets: targets.isEmpty ? const [Rule.allTargets] : List.of(targets),
        cooldown: Duration(minutes: _int(cooldownText, 0)),
      );

  /// The editor owns these, so it lets go of them when it closes.
  void dispose() {
    for (final c in [
      name,
      cooldownText,
      forMinutesText,
      thresholdText,
      daysText,
      everyMinutesText,
      hourText,
      minuteText,
      commandText,
      platformHintText,
      messageText,
    ]) {
      c.dispose();
    }
  }
}

class _Editor extends StatelessWidget {
  const _Editor({
    required this.draft,
    required this.machines,
    required this.onChanged,
    required this.onSave,
    required this.onCancel,
    this.onDelete,
  });

  final _Draft draft;
  final List<MachineRow> machines;
  final VoidCallback onChanged;
  final VoidCallback onSave;
  final VoidCallback onCancel;
  final VoidCallback? onDelete;

  String _nameOf(String id) {
    for (final m in machines) {
      if (m.id == id) return m.displayName;
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    // The rule as it currently stands, so the operator reads the sentence they
    // are writing rather than a form and hopes it means what they meant.
    final preview = draft.build().sentence(_nameOf);

    return Panel(
      title: draft.isNew ? 'New rule' : 'Edit rule',
      subtitle: preview,
      actions: [
        if (onDelete != null) ...[
          GhostButton(
              label: 'Delete', glyph: LdIcons.trash, onPressed: onDelete),
          const SizedBox(width: 8),
        ],
        GhostButton(label: 'Cancel', onPressed: onCancel),
        const SizedBox(width: 8),
        GhostButton(
            label: 'Save rule', glyph: LdIcons.check, onPressed: onSave),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field(
              context,
              'Name',
              _TextBox(
                  controller: draft.name,
                  hint: 'What this rule is for',
                  onChanged: onChanged)),
          const SizedBox(height: 18),
          _field(
            context,
            'When',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _chips<_TriggerKind>(
                  values: _TriggerKind.values,
                  selected: draft.kind,
                  labelOf: _triggerKindLabel,
                  onPick: (k) {
                    draft.kind = k;
                    onChanged();
                  },
                ),
                const SizedBox(height: 12),
                ..._triggerFields(context),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _field(
            context,
            'Then',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _chips<_ActionKind>(
                  values: _ActionKind.values,
                  selected: draft.actionKind,
                  labelOf: _actionKindLabel,
                  onPick: (k) {
                    draft.actionKind = k;
                    onChanged();
                  },
                ),
                const SizedBox(height: 12),
                ..._actionFields(context),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _field(context, 'On which machines', _targets(context)),
          const SizedBox(height: 18),
          _field(
            context,
            'Do not repeat within',
            Row(
              children: [
                SizedBox(
                  width: 90,
                  child: _TextBox(
                      controller: draft.cooldownText,
                      numeric: true,
                      hint: '10',
                      onChanged: onChanged),
                ),
                const SizedBox(width: 10),
                Text('minutes, per machine', style: C.of(context).small()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _triggerFields(BuildContext context) {
    switch (draft.kind) {
      case _TriggerKind.cameOnline:
        return [
          Text(
              'Fires on the change from offline to online, which the console '
              'has to have watched happen.',
              style: C.of(context).small(color: C.of(context).textFaint)),
        ];
      case _TriggerKind.wentOffline:
        return [
          _numberRow(context, 'for', draft.forMinutesText,
              'minutes (0 fires straight away)'),
        ];
      case _TriggerKind.metricAbove:
        return [
          Row(
            children: [
              _chips<AutoMetric>(
                values: AutoMetric.values,
                selected: draft.metric,
                labelOf: (m) => m.label,
                onPick: (m) {
                  draft.metric = m;
                  onChanged();
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          _numberRow(context, 'above', draft.thresholdText, 'percent'),
          const SizedBox(height: 8),
          _numberRow(context, 'for', draft.forMinutesText, 'minutes'),
          const SizedBox(height: 8),
          Text(
            'Figures are the machine\'s own, reported on its flush. A machine '
            'your organization has not enrolled reports none, and a rule over '
            'it does not fire.',
            style: C.of(context).small(color: C.of(context).textFaint),
          ),
        ];
      case _TriggerKind.uptimeAbove:
        return [_numberRow(context, 'more than', draft.daysText, 'days')];
      case _TriggerKind.every:
        return [
          _numberRow(context, 'every', draft.everyMinutesText, 'minutes'),
          const SizedBox(height: 8),
          Text(
              'A slot missed while LabDesk was closed is skipped, not caught '
              'up.',
              style: C.of(context).small(color: C.of(context).textFaint)),
        ];
      case _TriggerKind.atTime:
        return [
          Row(
            children: [
              Text('at', style: C.of(context).small()),
              const SizedBox(width: 10),
              SizedBox(
                  width: 60,
                  child: _TextBox(
                      controller: draft.hourText,
                      numeric: true,
                      hint: '07',
                      onChanged: onChanged)),
              const SizedBox(width: 6),
              Text(':', style: C.of(context).body()),
              const SizedBox(width: 6),
              SizedBox(
                  width: 60,
                  child: _TextBox(
                      controller: draft.minuteText,
                      numeric: true,
                      hint: '30',
                      onChanged: onChanged)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var d = DateTime.monday; d <= DateTime.sunday; d++)
                _Chip(
                  label: weekdayName(d),
                  selected: draft.weekdays.contains(d),
                  onTap: () {
                    if (!draft.weekdays.remove(d)) draft.weekdays.add(d);
                    onChanged();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text('No day picked means every day.',
              style: C.of(context).small(color: C.of(context).textFaint)),
        ];
    }
  }

  List<Widget> _actionFields(BuildContext context) {
    switch (draft.actionKind) {
      case _ActionKind.run:
        return [
          _TextBox(
              controller: draft.commandText,
              mono: true,
              hint: 'A single command, run in the machine\'s shell',
              onChanged: onChanged),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 160,
                child: _TextBox(
                    controller: draft.platformHintText,
                    hint: 'Linux',
                    onChanged: onChanged),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Optional. Leave blank to run everywhere; a shell line is '
                  'rarely portable.',
                  style: C.of(context).small(color: C.of(context).textFaint),
                ),
              ),
            ],
          ),
        ];
      case _ActionKind.notify:
        return [
          _TextBox(
              controller: draft.messageText,
              hint: 'What the notification should say',
              onChanged: onChanged),
        ];
      case _ActionKind.wol:
        return [
          Text(
              'Sends the magic packet. Only reaches machines on a network '
              'this one can broadcast to.',
              style: C.of(context).small(color: C.of(context).textFaint)),
        ];
      case _ActionKind.session:
        return [
          Text('Opens a desktop session in its own window. Loud on purpose.',
              style: C.of(context).small(color: C.of(context).textFaint)),
        ];
    }
  }

  Widget _targets(BuildContext context) {
    final all = draft.targets.contains(Rule.allTargets);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CheckRow(
          label: 'All machines',
          on: all,
          onTap: () {
            draft.targets = all ? [] : [Rule.allTargets];
            onChanged();
          },
        ),
        for (final m in machines)
          _CheckRow(
            label: m.displayName,
            on: !all && draft.targets.contains(m.id),
            enabled: !all,
            onTap: all
                ? null
                : () {
                    if (!draft.targets.remove(m.id)) draft.targets.add(m.id);
                    onChanged();
                  },
          ),
        if (machines.isEmpty)
          Text('No machines yet.',
              style: C.of(context).small(color: C.of(context).textFaint)),
      ],
    );
  }

  Widget _numberRow(BuildContext context, String lead, TextEditingController c,
          String tail) =>
      Row(
        children: [
          Text(lead, style: C.of(context).small()),
          const SizedBox(width: 10),
          SizedBox(
              width: 78,
              child:
                  _TextBox(controller: c, numeric: true, onChanged: onChanged)),
          const SizedBox(width: 10),
          Expanded(child: Text(tail, style: C.of(context).small())),
        ],
      );

  Widget _field(BuildContext context, String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: C.of(context).micro()),
          const SizedBox(height: 8),
          child,
        ],
      );

  Widget _chips<T>({
    required List<T> values,
    required T selected,
    required String Function(T) labelOf,
    required ValueChanged<T> onPick,
  }) =>
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final v in values)
            _Chip(
                label: labelOf(v),
                selected: v == selected,
                onTap: () => onPick(v)),
        ],
      );

  static String _triggerKindLabel(_TriggerKind k) => switch (k) {
        _TriggerKind.cameOnline => 'Comes online',
        _TriggerKind.wentOffline => 'Goes offline',
        _TriggerKind.metricAbove => 'Metric above',
        _TriggerKind.uptimeAbove => 'Uptime above',
        _TriggerKind.every => 'Every so often',
        _TriggerKind.atTime => 'At a time of day',
      };

  static String _actionKindLabel(_ActionKind k) => switch (k) {
        _ActionKind.run => 'Run a command',
        _ActionKind.notify => 'Notify',
        _ActionKind.wol => 'Wake-on-LAN',
        _ActionKind.session => 'Open a session',
      };
}

/// A selectable word. The console's one accent means "the current thing", and
/// this is the only place it appears in the editor.
class _Chip extends StatefulWidget {
  const _Chip({required this.label, required this.selected, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: C.fast,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on
                ? C.of(context).accent.withOpacity(0.14)
                : Colors.transparent,
            borderRadius: C.roundedSm,
            border: Border.all(
                color: on
                    ? C.of(context).accent
                    : (_hover
                        ? C.of(context).textFaint
                        : C.of(context).hairline.withOpacity(0.6))),
          ),
          child: Text(widget.label,
              style: C.of(context).small(
                  color: on ? C.of(context).text : C.of(context).textMuted,
                  w: FontWeight.w600)),
        ),
      ),
    );
  }
}

/// A checkbox with its row as the hit area, which is the rule [LdCheckbox] is
/// drawn to: the mark paints, the row takes the tap.
class _CheckRow extends StatefulWidget {
  const _CheckRow({
    required this.label,
    required this.on,
    this.enabled = true,
    this.onTap,
  });

  final String label;
  final bool on;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  State<_CheckRow> createState() => _CheckRowState();
}

class _CheckRowState extends State<_CheckRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor:
          widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              LdCheckbox(on: widget.on, enabled: widget.enabled, hover: _hover),
              const SizedBox(width: 10),
              Text(widget.label,
                  style: C.of(context).small(
                      color: widget.enabled
                          ? C.of(context).text
                          : C.of(context).textFaint)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The console has no boxed text field of its own, so this is the terminal
/// input's treatment - no Material border, a hairline frame, the accent for the
/// caret - at the size the rest of the editor uses.
class _TextBox extends StatelessWidget {
  const _TextBox({
    required this.controller,
    this.hint,
    this.numeric = false,
    this.mono = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? hint;
  final bool numeric;
  final bool mono;

  /// Called after any keystroke, so the sentence above the form keeps up.
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final style =
        mono || numeric ? C.of(context).data(size: 12.5) : C.of(context).body();
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: C.of(context).bg,
        borderRadius: C.roundedSm,
        border: Border.all(color: C.of(context).hairline),
      ),
      child: Center(
        child: TextField(
          controller: controller,
          style: style,
          cursorColor: C.of(context).accent,
          cursorWidth: 1.6,
          keyboardType: numeric ? TextInputType.number : null,
          inputFormatters:
              numeric ? [FilteringTextInputFormatter.digitsOnly] : null,
          onChanged: (_) => onChanged?.call(),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.zero,
            border: InputBorder.none,
            hintText: hint,
            hintStyle: style.copyWith(color: C.of(context).textFaint),
          ),
        ),
      ),
    );
  }
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'
    ':${t.second.toString().padLeft(2, '0')}';

/// How long ago, for a fixed width column. A dash rather than "0s" when the
/// difference is not a real one.
String _ago(DateTime then, DateTime? now) {
  var s = (now ?? DateTime.now()).difference(then).inSeconds;
  if (s < 0) s = 0;
  if (s < 60) return '${s}s ago';
  if (s < 3600) return '${s ~/ 60}m ago';
  if (s < 86400) return '${s ~/ 3600}h ago';
  return '${s ~/ 86400}d ago';
}

/// The ready-made rules, offered above the list.
///
/// Applying one adds a real, editable rule; there is no second kind of rule and
/// nothing keeps a link back to the preset afterwards. A preset whose rule is
/// already in the list reads as added rather than disappearing, so the set the
/// operator is choosing from does not change shape under them.
class _Presets extends StatelessWidget {
  const _Presets({required this.applied, required this.onApply});

  /// Rule names already in the list. A preset's title is the rule's name, so
  /// this is what says which have been taken.
  final Set<String> applied;
  final ValueChanged<AutomationPreset> onApply;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'Ready-made rules',
      subtitle: 'The ones most technicians set up first',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final p in AutomationPreset.all)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.title, style: C.of(context).body()),
                        const SizedBox(height: 2),
                        Text(p.description,
                            style: C
                                .of(context)
                                .small(color: C.of(context).textFaint)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  if (applied.contains(p.title))
                    Text('Added',
                        style:
                            C.of(context).small(color: C.of(context).textFaint))
                  else
                    GhostButton(
                      label: 'Add',
                      glyph: LdIcons.add,
                      onPressed: () => onApply(p),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
