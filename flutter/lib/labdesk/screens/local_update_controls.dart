import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/console_theme.dart';
import '../theme/settings_skin.dart';

/// Both surfaces read the privileged service, never the GUI's option cache.
class LocalUpdateControls extends StatefulWidget {
  const LocalUpdateControls({
    super.key,
    required this.readOption,
    required this.writeOption,
    this.banner = false,
  });

  final Future<String> Function(String key) readOption;
  final Future<void> Function(String key, String value) writeOption;
  final bool banner;

  @override
  State<LocalUpdateControls> createState() => _LocalUpdateControlsState();
}

class _LocalUpdateControlsState extends State<LocalUpdateControls> {
  static final _dismissedVersions = <String>{};
  static const _policyKey = 'labdesk-update-policy';
  static const _statusKey = 'labdesk-update-status';
  final _window = TextEditingController(text: '60');
  Timer? _poll;
  Map<String, dynamic> _status = {};
  Map<String, dynamic>? _policy;
  bool _busy = true;
  bool _dirty = false;
  bool _automatic = false;
  Set<int> _days = {};
  int _startMinute = 180;
  String? _readError;
  String? _message;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _window.dispose();
    super.dispose();
  }

  Map<String, dynamic> _object(String raw) {
    if (raw.isEmpty) return {};
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid updater response');
    }
    return value;
  }

  bool _validPolicy(Map<String, dynamic> value) {
    final revision = value['revision'];
    if (revision is! int || revision < 0 || value['automatic'] is! bool) {
      return false;
    }
    final weekly = value['weekly'];
    if (weekly == null) return value['automatic'] == false;
    if (weekly is! Map) return false;
    final days = weekly['days'];
    final start = weekly['startMinute'];
    final window = weekly['windowMinutes'];
    return days is List &&
        days.isNotEmpty &&
        days.every((d) => d is int && d >= 0 && d <= 6) &&
        days.toSet().length == days.length &&
        start is int &&
        start >= 0 &&
        start <= 1439 &&
        window is int &&
        window >= 15 &&
        window <= 1440;
  }

  void _resetDraft() {
    final weekly = _policy?['weekly'] as Map?;
    _automatic = _policy?['automatic'] == true;
    _days = weekly == null ? {} : Set<int>.from(weekly['days']);
    _startMinute = weekly?['startMinute'] as int? ?? 180;
    _window.text = '${weekly?['windowMinutes'] ?? 60}';
    _dirty = false;
  }

  bool _matchesPolicy(Map<String, dynamic> wanted) {
    if (_policy == null || _policy!['automatic'] != wanted['automatic'])
      return false;
    final actual = _policy!['weekly'] as Map?;
    final weekly = wanted['weekly'] as Map?;
    if (actual == null || weekly == null) return actual == weekly;
    return actual['startMinute'] == weekly['startMinute'] &&
        actual['windowMinutes'] == weekly['windowMinutes'] &&
        listEquals(List<int>.from(actual['days'])..sort(),
            List<int>.from(weekly['days'])..sort());
  }

  Future<void> _read() async {
    final status = _object(await widget.readOption(_statusKey));
    if (!mounted) return;
    final policy =
        widget.banner ? null : _object(await widget.readOption(_policyKey));
    if (!mounted) return;
    final changed = _policy?['revision'] != policy?['revision'];
    final wasDirty = _dirty;
    _status = status;
    _policy = policy != null && _validPolicy(policy) ? policy : null;
    _readError = null;
    if (!_dirty || changed || status['managed'] != false) {
      _resetDraft();
      if (wasDirty && changed) {
        _message = 'Update settings changed. Review the current schedule.';
      }
    }
  }

  void _schedulePoll() {
    if (mounted) _poll = Timer(const Duration(seconds: 15), _refresh);
  }

  Future<void> _refresh() async {
    _poll?.cancel();
    if (mounted) setState(() => _busy = true);
    try {
      await _read();
    } catch (_) {
      if (mounted) _readError = 'Cannot read updater status. Retrying shortly.';
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _schedulePoll();
      }
    }
  }

  bool _capability(String key) =>
      !_busy &&
      _readError == null &&
      _status['managed'] == false &&
      _status['capabilities'] is Map &&
      (_status['capabilities'] as Map)[key] == true;

  String _text(String key) =>
      _status[key] is String ? _status[key] as String : '';
  String get _available => _text('availableVersion');
  bool get _hasUpdate =>
      _available.isNotEmpty && _available != _text('currentVersion');
  bool get _working =>
      const ['checking', 'downloading', 'deferred', 'installing']
          .contains(_text('state')) ||
      _queue != null;

  Map? get _queue {
    final queue = _status['queuedLocalCommand'];
    if (queue is! Map ||
        queue['id'] is! String ||
        queue['id'].isEmpty ||
        !const ['check', 'install'].contains(queue['action']) ||
        queue['startsAt'] is! int ||
        queue['endsAt'] is! int ||
        queue['endsAt'] <= DateTime.now().millisecondsSinceEpoch ~/ 1000) {
      return null;
    }
    return queue;
  }

  Future<void> _write(String key, String value) async {
    if (_busy) return;
    _poll?.cancel();
    final previousCommand = _queue?['id'];
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.writeOption(key, value);
      if (!mounted) return;
      await _read();
      if (!mounted) return;
      if (_text('error').isEmpty) {
        if (key == _policyKey) {
          final applied = _matchesPolicy(_object(value));
          if (applied) _resetDraft();
          _message = applied
              ? 'Update settings saved.'
              : 'Settings were not applied. Review the current policy and try again.';
        } else if (_queue == null ||
            _queue?['id'] == previousCommand ||
            _queue?['action'] != value) {
          _message =
              'The service did not confirm a new update job. Refresh status before trying again.';
        }
      }
    } catch (_) {
      if (mounted) {
        _readError =
            'Cannot confirm the update request. Refresh status before trying again.';
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _schedulePoll();
      }
    }
  }

  String? get _scheduleError {
    if (!_automatic) return null;
    if (_days.isEmpty) return 'Choose at least one day.';
    final minutes = int.tryParse(_window.text);
    if (minutes == null || minutes < 15 || minutes > 1440) {
      return 'Enter a window from 15 to 1440 minutes.';
    }
    return null;
  }

  void _save() {
    if (!_capability('scheduling') ||
        (_automatic && !_capability('install')) ||
        _policy == null ||
        _scheduleError != null) return;
    _write(
        _policyKey,
        jsonEncode({
          'revision': _policy!['revision'],
          'automatic': _automatic,
          'weekly': _automatic
              ? {
                  'days': _days.toList()..sort(),
                  'startMinute': _startMinute,
                  'windowMinutes': int.parse(_window.text),
                }
              : null,
        }));
  }

  String _time(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

  String _date(dynamic epoch) {
    if (epoch is! int || epoch < 0 || epoch > 8640000000000)
      return 'Not reported';
    final date = DateTime.fromMillisecondsSinceEpoch(epoch * 1000).toLocal();
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${_time(date.hour * 60 + date.minute)}';
  }

  String get _stateLabel =>
      const {
        'checking': 'Checking for updates',
        'available': 'Update available',
        'up-to-date': 'Up to date',
        'downloading': 'Downloading update',
        'deferred': 'Waiting for idle time or the update window',
        'installing': 'Preparing installation; completion not yet confirmed',
        'completed': 'Updated running version confirmed',
        'failed': 'Update failed',
        'unsupported': 'Updates are not supported on this device',
        'idle': 'Idle',
      }[_text('state')] ??
      'Updater status not available';

  List<Widget> _feedback() => [
        if (_queue != null)
          SettingsNote(
              '${_queue!['action'] == 'install' ? 'Download and install' : 'Check'} job queued: '
              '${_date(_queue!['startsAt'])} to ${_date(_queue!['endsAt'])}, local time. '
              'Installation waits until this device is idle.'),
        if (_readError != null || _text('error').isNotEmpty)
          Semantics(
              liveRegion: true,
              child: SettingsNote(_readError ?? _text('error'),
                  tone: C.of(context).bad)),
        if (_message != null)
          Semantics(liveRegion: true, child: SettingsNote(_message!)),
      ];

  Widget _actions() => Wrap(spacing: 8, runSpacing: 8, children: [
        if (!widget.banner)
          TextButton(
              onPressed: _capability('check') && !_working
                  ? () => _write('labdesk-update-action', 'check')
                  : null,
              child: const Text('Check now')),
        ElevatedButton(
            onPressed: _capability('install') && _hasUpdate && !_working
                ? () => _write('labdesk-update-action', 'install')
                : null,
            child: const Text('Download and install')),
        if (widget.banner)
          TextButton(
              onPressed: () =>
                  setState(() => _dismissedVersions.add(_available)),
              child: const Text('Later')),
      ]);

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    final managed = _status['managed'] == true;
    final editable = _capability('scheduling') && _policy != null;
    if (widget.banner) {
      if (!_hasUpdate || _dismissedVersions.contains(_available))
        return const SizedBox.shrink();
      return Material(
          color: p.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('LabDesk $_available is available.', style: p.body()),
              Text(
                  managed
                      ? 'Managed device. Use Fleet Updates to schedule installation.'
                      : 'Installation waits for idle time and does not enable recurring updates.',
                  style: p.small()),
              Text('$_stateLabel · Reported ${_date(_status['reportedAt'])}',
                  style: p.small()),
              if (!managed && !_busy && !_capability('install'))
                const SettingsNote(
                    'Installation is unavailable from this updater.'),
              ..._feedback(),
              _actions(),
            ]),
          ));
    }
    return SettingsGroup(title: 'Software updates', children: [
      SettingsNote(
          _busy && _status.isEmpty ? 'Reading updater status…' : _stateLabel),
      SettingsNote(
          'Installed: ${_text('currentVersion').isEmpty ? 'Not reported' : _text('currentVersion')}'
          '${_hasUpdate ? ' · Available: $_available' : ''}\n'
          'Reported: ${_date(_status['reportedAt'])} (local time)'),
      if (managed)
        const SettingsNote(
            'Managed by your organization. Change update policy and queue jobs in Fleet Updates.')
      else if (_status['managed'] != false)
        const SettingsNote(
            'This updater has not reported local update support. Controls remain unavailable.')
      else
        const SettingsNote(
            'One-time installation waits for idle time. It does not enable recurring updates.'),
      _actions(),
      ..._feedback(),
      const SizedBox(height: 12),
      if (_policy != null)
        SettingsNote('Policy revision ${_policy!['revision']} · '
            'Applied revision ${_status['policyRevision'] ?? 'Not reported'}'
            '${_status['policyRevision'] == _policy!['revision'] ? '' : ' · Waiting for service confirmation'}'),
      SettingsRow(
          label: 'Install updates automatically',
          explain:
              'Install the latest published version during a weekly window, when this device is idle.',
          enabled: editable,
          control: Switch(
              value: _automatic,
              onChanged: editable && (_automatic || _capability('install'))
                  ? (value) => setState(() {
                        _automatic = value;
                        _dirty = true;
                      })
                  : null)),
      if (_status['legacyMigrated'] == true)
        const SettingsNote(
            'Your previous automatic-update preference was retained as an all-day, every-day window. Choose a narrower window below.'),
      if (_status['managed'] == false &&
          _status['capabilities'] is Map &&
          (_status['capabilities'] as Map)['install'] != true)
        const SettingsNote(
            'This updater cannot install updates. Existing automatic updates can still be disabled.'),
      if (!managed && !_busy && (!editable))
        const SettingsNote(
            'Weekly scheduling is unavailable until this updater reports scheduling support and a valid policy.'),
      if (_automatic) ...[
        const SettingsNote(
            'Weekly window · this device’s local time. Windows may continue into the next day.'),
        Wrap(spacing: 4, runSpacing: 4, children: [
          for (var day = 0; day < 7; day++)
            SizedBox(
                width: 94,
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                      const [
                        'Sun',
                        'Mon',
                        'Tue',
                        'Wed',
                        'Thu',
                        'Fri',
                        'Sat'
                      ][day],
                      style: p.small()),
                  value: _days.contains(day),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: editable
                      ? (value) => setState(() {
                            value == true ? _days.add(day) : _days.remove(day);
                            _dirty = true;
                          })
                      : null,
                )),
        ]),
        SettingsRow(
            label: 'Start time',
            controlAbove: true,
            control: TextButton(
                onPressed: editable
                    ? () async {
                        final revision = _policy?['revision'];
                        final time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay(
                                hour: _startMinute ~/ 60,
                                minute: _startMinute % 60));
                        if (!mounted ||
                            time == null ||
                            revision != _policy?['revision'] ||
                            !_capability('scheduling')) return;
                        setState(() {
                          _startMinute = time.hour * 60 + time.minute;
                          _dirty = true;
                        });
                      }
                    : null,
                child: Text(_time(_startMinute)))),
        SettingsRow(
            label: 'Window length (minutes)',
            controlAbove: true,
            control: SizedBox(
                width: 180,
                child: TextField(
                  controller: _window,
                  enabled: editable,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4)
                  ],
                  decoration: const InputDecoration(
                      hintText: '15–1440', border: OutlineInputBorder()),
                  onChanged: (_) => setState(() => _dirty = true),
                ))),
        if (_scheduleError != null) SettingsNote(_scheduleError!, tone: p.bad),
      ],
      Wrap(spacing: 8, children: [
        ElevatedButton(
            onPressed: editable &&
                    (!_automatic || _capability('install')) &&
                    _dirty &&
                    _scheduleError == null
                ? _save
                : null,
            child: const Text('Save update settings')),
        TextButton(
            onPressed: !_busy && _dirty ? () => setState(_resetDraft) : null,
            child: const Text('Discard changes')),
      ]),
    ]);
  }
}
