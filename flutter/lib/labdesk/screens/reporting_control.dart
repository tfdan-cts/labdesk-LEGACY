import 'package:flutter/material.dart';

/// Explicit collector-policy control. A context key identifies account,
/// organization and machine so switching targets invalidates pending UI work.
class ReportingControl extends StatefulWidget {
  const ReportingControl(
      {super.key,
      required this.currentSeconds,
      this.onSave,
      this.disabledReason,
      this.contextKey = 'local'});
  final int? currentSeconds;
  final Future<void> Function(int)? onSave;
  final String? disabledReason;
  final String contextKey;

  @override
  State<ReportingControl> createState() => _ReportingControlState();
}

class _ReportingControlState extends State<ReportingControl> {
  int? _applied;
  int? _selected;
  int _revision = 0;
  bool _saving = false;
  String? _message;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _applied = _selected = widget.currentSeconds;
  }

  @override
  void didUpdateWidget(ReportingControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.disabledReason != widget.disabledReason ||
        (oldWidget.onSave == null) != (widget.onSave == null)) {
      _revision++;
      _saving = false;
    }
    if (oldWidget.contextKey != widget.contextKey ||
        oldWidget.currentSeconds != widget.currentSeconds) {
      _revision++;
      _applied = _selected = widget.currentSeconds;
      _saving = false;
      _message = null;
      _failed = false;
    }
  }

  String _duration(int? seconds) {
    if (seconds == null) return 'Not reported';
    if (seconds == 3600) return '1 hour';
    if (seconds == 60) return '1 minute';
    if (seconds % 60 == 0) return '${seconds ~/ 60} minutes';
    return '$seconds seconds';
  }

  Future<void> _apply() async {
    final seconds = _selected, save = widget.onSave;
    if (_saving ||
        save == null ||
        widget.disabledReason != null ||
        seconds == null ||
        seconds == _applied ||
        seconds < 60 ||
        seconds > 86400) return;
    final version = _revision;
    setState(() {
      _saving = true;
      _message = null;
      _failed = false;
    });
    try {
      await save(seconds);
      if (!mounted || version != _revision) return;
      setState(() {
        _applied = seconds;
        _message =
            'Reporting interval saved. The collector receives it on its next successful upload.';
      });
    } catch (_) {
      if (!mounted || version != _revision) return;
      setState(() {
        _failed = true;
        _message =
            'Could not save the reporting interval. Your selection is still here; retry Apply or refresh the machine.';
      });
    } finally {
      if (mounted && version == _revision) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = <int>{60, 300, 900, 3600, if (_applied != null) _applied!}
        .toList()
      ..sort();
    final enabled =
        widget.onSave != null && widget.disabledReason == null && !_saving;
    final changed = _selected != null &&
        _selected != _applied &&
        _selected! >= 60 &&
        _selected! <= 86400;
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Reporting interval', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
              'Configured: ${_duration(_applied)}. Existing settings stay unchanged until you apply a new interval.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 270),
                    child: DropdownButtonFormField<int>(
                        key: ValueKey(
                            'reporting-interval-${widget.contextKey}-$_selected'),
                        value: _selected,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: 'Collector reporting cadence'),
                        hint: const Text('Choose an interval'),
                        items: [
                          for (final value in options)
                            DropdownMenuItem(
                                value: value,
                                child: Text(
                                    '${_duration(value)}${const [
                                      60,
                                      300,
                                      900,
                                      3600
                                    ].contains(value) ? '' : ' (current)'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis))
                        ],
                        onChanged: !enabled
                            ? null
                            : (value) => setState(() {
                                  _selected = value;
                                  _message = null;
                                  _failed = false;
                                }))),
                FilledButton(
                    onPressed: enabled && changed ? _apply : null,
                    child: Text(_saving ? 'Applying…' : 'Apply')),
              ]),
          const SizedBox(height: 10),
          const Text(
              'A change takes effect after the machine’s next successful upload. It does not request an immediate sample. More frequent reporting sends more uploads.',
              style: TextStyle(fontSize: 12)),
          if (widget.onSave == null || widget.disabledReason != null)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    widget.disabledReason ??
                        'Reporting policy is read-only in this view.',
                    style:
                        TextStyle(color: theme.colorScheme.onSurfaceVariant))),
          if (_message != null)
            Semantics(
                liveRegion: true,
                child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_message!,
                        style: TextStyle(
                            color: _failed
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant)))),
        ]));
  }
}
