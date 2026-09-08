import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/organization_context.dart';
import '../services/overlay_broker.dart';
import '../theme/console_theme.dart';
import 'installer_links_screen.dart';

/// Fleet operations use canonical machine IDs from the scoped updates read.
class FleetUpdatesScreen extends StatefulWidget {
  const FleetUpdatesScreen(
      {super.key, required this.organization, this.fleetNames = const {}});

  final OrganizationContextController organization;
  final Map<String, String> fleetNames;

  @override
  State<FleetUpdatesScreen> createState() => _FleetUpdatesScreenState();
}

class _FleetUpdatesScreenState extends State<FleetUpdatesScreen> {
  List<Map<String, dynamic>> _machines = const [];
  final _selected = <String>{};
  final _days = <int>{};
  final _hours = TextEditingController(text: '1');
  final _minutes = TextEditingController(text: '60');
  String _scope = '', _fleet = '', _action = 'check';
  int _generation = 0;
  bool _busy = false, _editable = false, _automatic = false, _startNow = true;
  String? _error, _notice;
  DateTime? _lastRead, _localStart;
  TimeOfDay _weeklyTime = const TimeOfDay(hour: 3, minute: 0);
  static const _dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  static const _cancellable = {'queued', 'running', 'checking', 'downloading'};

  OrganizationContextController get _organization => widget.organization;
  bool get _ready =>
      _organization.ready &&
      !_organization.busy &&
      _organization.matchesCredential(_organization.broker.token());
  bool get _canEdit => _ready && _editable && !_busy && _error == null;
  bool _current(int generation, String credential) =>
      mounted &&
      _ready &&
      generation == _generation &&
      _organization.matchesCredential(credential) &&
      _organization.broker.token() == credential;
  List<Map<String, dynamic>> get _visible => _machines
      .where((machine) => _fleet.isEmpty || machine['fleetId'] == _fleet)
      .toList();
  List<Map<String, dynamic>> get _chosen =>
      _visible.where((machine) => _selected.contains(machine['id'])).toList();
  bool get _validSelection => _chosen.isNotEmpty && _chosen.length <= 250;
  bool _supports(Map<String, dynamic> machine, String capability) =>
      _map(_map(machine['status'])['capabilities'])[capability] == true;
  bool get _canSchedule =>
      _canEdit &&
      _validSelection &&
      _scheduleError == null &&
      _chosen.every((machine) =>
          _supports(machine, _action) &&
          (_startNow || _supports(machine, 'scheduling')));
  bool get _canSave =>
      _canEdit &&
      _validSelection &&
      _weeklyError == null &&
      (!_automatic ||
          _chosen.every((machine) =>
              _supports(machine, 'install') &&
              _supports(machine, 'scheduling')));

  String? get _scheduleError {
    final hours = int.tryParse(_hours.text);
    if (hours == null || hours < 1 || hours > 24) {
      return 'Execution window must be 1–24 hours.';
    }
    if (!_startNow) {
      if (_localStart == null) return 'Choose a local start date and time.';
      final now = DateTime.now();
      if (!_localStart!.isAfter(now) ||
          _localStart!.isAfter(now.add(const Duration(days: 366)))) {
        return 'Start must be in the future, within 366 days.';
      }
    }
    return null;
  }

  String? get _weeklyError {
    if (!_automatic) return null;
    if (_days.isEmpty) return 'Choose at least one day.';
    final minutes = int.tryParse(_minutes.text);
    return minutes == null || minutes < 15 || minutes > 1440
        ? 'Weekly window must be 15–1440 minutes.'
        : null;
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : const {};
  static List<Map<String, dynamic>> _rows(Object? value) => value is List
      ? value.whereType<Map<String, dynamic>>().toList()
      : const [];
  static String _text(Object? value, [String fallback = 'Not reported']) =>
      value is String && value.isNotEmpty ? value : fallback;
  static String _time(DateTime time) => time.toString().split('.').first;
  static String _minuteTime(Object? value) => value is int &&
          value >= 0 &&
          value < 1440
      ? '${(value ~/ 60).toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}'
      : 'unknown time';
  static DateTime? _instant(Object? value) => value is num &&
          value.isFinite &&
          value.abs() <= 8640000000000
      ? DateTime.fromMillisecondsSinceEpoch((value * 1000).round(), isUtc: true)
      : null;

  @override
  void initState() {
    super.initState();
    _organization.addListener(_contextChanged);
    _contextChanged();
  }

  @override
  void didUpdateWidget(FleetUpdatesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.organization != _organization) {
      oldWidget.organization.removeListener(_contextChanged);
      _organization.addListener(_contextChanged);
      _scope = '';
      _contextChanged();
    }
  }

  @override
  void dispose() {
    _generation++;
    _organization.removeListener(_contextChanged);
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  void _contextChanged() {
    final scope =
        '${_organization.revision}/${_organization.contextKey}/$_ready';
    if (!mounted || scope == _scope) return;
    setState(() {
      _scope = scope;
      _generation++;
      _machines = const [];
      _selected.clear();
      _days.clear();
      _fleet = '';
      _busy = _editable = _automatic = false;
      _startNow = true;
      _action = 'check';
      _localStart = _lastRead = null;
      _error = _notice = null;
    });
    scheduleMicrotask(() {
      if (mounted && _ready) _refresh();
    });
  }

  void _failure(Object failure) {
    if (failure is OverlayBrokerException &&
        (failure.signInAgain || failure.status == 403)) {
      _organization.invalidate(failure.message);
      return;
    }
    setState(() {
      _editable = false;
      _error = failure is OverlayBrokerException
          ? failure.message
          : 'Updates could not be read. Refresh to try again.';
    });
  }

  Future<void> _read(
      OverlayBroker broker, int generation, String credential) async {
    try {
      final result = await broker.updates();
      if (!_current(generation, credential)) return;
      final machines = _rows(result['machines']);
      final ids = machines.map((machine) => machine['id']).toSet();
      if (result['machines'] is! List ||
          result['editable'] is! bool ||
          machines.length != (result['machines'] as List).length ||
          ids.length != machines.length ||
          ids.any((id) => id is! String || id.trim().isEmpty)) {
        throw const FormatException('Invalid updates response');
      }
      setState(() {
        _machines = machines;
        _editable = result['editable'] == true;
        if (!_machines.any((machine) => machine['fleetId'] == _fleet))
          _fleet = '';
        _selected.retainAll(_visible.map((machine) => machine['id'] as String));
        _lastRead = DateTime.now();
        _error = null;
      });
    } catch (failure) {
      if (_current(generation, credential)) _failure(failure);
    }
  }

  Future<void> _refresh() async {
    if (!_ready || _busy) return;
    final generation = _generation;
    final broker = _organization.broker.captureScope();
    final credential = broker.token();
    setState(() => _busy = true);
    try {
      await _read(broker, generation, credential);
    } finally {
      if (_current(generation, credential)) setState(() => _busy = false);
    }
  }

  Future<void> _mutate(
      Future<void> Function(OverlayBroker) action, String notice) async {
    if (!_canEdit) return;
    final generation = _generation;
    final broker = _organization.broker.captureScope();
    final credential = broker.token();
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await action(broker);
      if (!_current(generation, credential)) return;
      setState(() => _notice = notice);
      await _read(broker, generation, credential);
    } catch (failure) {
      if (!_current(generation, credential)) return;
      if (failure is OverlayBrokerException &&
          (failure.signInAgain || failure.status == 403)) {
        _organization.invalidate(failure.message);
        return;
      }
      setState(() => _notice = failure is OverlayBrokerException
          ? failure.message
          : 'The request could not be confirmed. Refresh before retrying.');
      await _read(broker, generation, credential);
    } finally {
      if (_current(generation, credential)) setState(() => _busy = false);
    }
  }

  Future<void> _schedule() async {
    if (!_canSchedule) return;
    final ids = _chosen.map((machine) => machine['id'] as String).toList();
    final action = _action;
    final start = (_startNow ? DateTime.now() : _localStart!).toUtc();
    final end = start.add(Duration(hours: int.parse(_hours.text)));
    await _mutate((broker) async {
      await broker.scheduleUpdates(ids,
          action: action, startsAt: start, endsAt: end);
    }, 'Request accepted. Machines execute within the window when ready; installation waits for idle.');
  }

  Future<void> _savePolicy() async {
    if (!_canSave) return;
    final ids = _chosen.map((machine) => machine['id'] as String).toList();
    final automatic = _automatic;
    final weekly = automatic
        ? (
            days: _days.toList()..sort(),
            startMinute: _weeklyTime.hour * 60 + _weeklyTime.minute,
            windowMinutes: int.parse(_minutes.text)
          )
        : null;
    await _mutate(
        (broker) =>
            broker.setUpdatePolicy(ids, automatic: automatic, weekly: weekly),
        'Policy saved. Pending until each machine reports the saved revision.');
  }

  Future<void> _pickStart() async {
    final generation = _generation;
    final credential = _organization.broker.token();
    final now = DateTime.now();
    final initial = _localStart != null && _localStart!.isAfter(now)
        ? _localStart!
        : now.add(const Duration(hours: 1));
    final date = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: now,
        lastDate: now.add(const Duration(days: 366)));
    if (!_current(generation, credential) || date == null) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (!_current(generation, credential) || time == null) return;
    final local =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (local.year != date.year ||
        local.month != date.month ||
        local.day != date.day ||
        local.hour != time.hour ||
        local.minute != time.minute) {
      setState(() {
        _localStart = null;
        _notice =
            'That local time does not exist because the clock changes. Choose another time.';
      });
      return;
    }
    setState(() => _localStart = local);
  }

  Future<void> _pickWeeklyTime() async {
    final generation = _generation;
    final credential = _organization.broker.token();
    final time =
        await showTimePicker(context: context, initialTime: _weeklyTime);
    if (_current(generation, credential) && time != null) {
      setState(() => _weeklyTime = time);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    if (!_ready)
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                  _organization.error ??
                      'Choose an organization to read its updates.',
                  style: p.body())));
    final fleetIds = _machines
        .map((machine) => machine['fleetId'])
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final visible = _visible;
    return ListView(padding: const EdgeInsets.all(24), children: [
      Row(children: [
        Expanded(child: Text('Fleet updates', style: p.h2())),
        TextButton.icon(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Refresh'))
      ]),
      Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('Share an installer'),
            onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => Dialog(
                      child: SizedBox(
                          width: 760,
                          height: MediaQuery.sizeOf(context).height * .8,
                          child: Column(children: [
                            Align(
                                alignment: Alignment.centerRight,
                                child: IconButton(
                                    tooltip: 'Close installer links',
                                    icon: const Icon(Icons.close),
                                    onPressed: () => Navigator.pop(context))),
                            Expanded(
                                child: InstallerLinksScreen(
                                    organization: _organization)),
                          ])),
                    )),
          )),
      Text(
          'Select up to 250 machines. Versions and capabilities come from their latest updater reports.',
          style: p.small()),
      if (_lastRead != null)
        Text(
            '${_error == null ? 'Last read' : 'Showing older data from'} ${_time(_lastRead!)}',
            style: p.small()),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null)
        Semantics(
            liveRegion: true,
            child: Text(_error!, style: p.body(color: p.bad))),
      if (_notice != null)
        Semantics(liveRegion: true, child: Text(_notice!, style: p.body())),
      if (!_editable && !_busy && _error == null)
        Text(
            'Read-only: the service has not granted update management for this scope.',
            style: p.small()),
      const SizedBox(height: 16),
      Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
                width: 260,
                child: DropdownButtonFormField<String>(
                    value: _fleet,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Fleet'),
                    items: [
                      const DropdownMenuItem(
                          value: '', child: Text('All visible fleets')),
                      for (final id in fleetIds)
                        DropdownMenuItem(
                            value: id,
                            child: Text(widget.fleetNames[id] ?? id,
                                overflow: TextOverflow.ellipsis))
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                              _fleet = value ?? '';
                              _selected.clear();
                            }))),
            Text('${_selected.length} selected', style: p.body()),
            TextButton(
                onPressed: !_canEdit || visible.isEmpty
                    ? null
                    : () => setState(() {
                          _selected.clear();
                          _selected.addAll(visible
                              .take(250)
                              .map((machine) => machine['id'] as String));
                        }),
                child: const Text('Select visible (up to 250)')),
            TextButton(
                onPressed: _busy || _selected.isEmpty
                    ? null
                    : () => setState(_selected.clear),
                child: const Text('Clear selection'))
          ]),
      if (_selected.isNotEmpty) ...[
        const SizedBox(height: 24),
        Text('One-time update', style: p.h2()),
        Text(
            'Uses the latest published version at execution time. This does not enable automatic updates.',
            style: p.small()),
        const SizedBox(height: 12),
        Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                  width: 240,
                  child: DropdownButtonFormField<String>(
                      value: _action,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Action'),
                      items: const [
                        DropdownMenuItem(
                            value: 'check', child: Text('Check only')),
                        DropdownMenuItem(
                            value: 'install',
                            child: Text('Download and install', overflow: TextOverflow.ellipsis))
                      ],
                      onChanged: !_canEdit
                          ? null
                          : (value) => setState(() => _action = value!))),
              SizedBox(
                  width: 180,
                  child: _numberField(_hours, 'Execution window (hours)'))
            ]),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Start now'),
            value: _startNow,
            onChanged: !_canEdit
                ? null
                : (value) => setState(() => _startNow = value)),
        if (!_startNow) ...[
          Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                  onPressed: _canEdit ? _pickStart : null,
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text(_localStart == null
                      ? 'Choose local date and time'
                      : '${_time(_localStart!)} local'))),
          if (_localStart != null)
            Text('UTC start: ${_time(_localStart!.toUtc())} UTC',
                style: p.small())
        ],
        if (_scheduleError != null)
          Text(_scheduleError!, style: p.small(color: p.bad)),
        if (!_chosen.every((machine) =>
            _supports(machine, _action) &&
            (_startNow || _supports(machine, 'scheduling'))))
          Text(
              'Some selected machines have not reported support for this action or schedule.',
              style: p.small()),
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
                key: const ValueKey('schedule-updates'),
                onPressed: _canSchedule ? _schedule : null,
                child: Text(_startNow
                    ? 'Run once on selected machines'
                    : 'Schedule selected machines'))),
        const SizedBox(height: 24),
        Text('Automatic weekly updates', style: p.h2()),
        Text(
            'Apply one policy to the selection. Each machine uses its own local time, including overnight windows.',
            style: p.small()),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable automatic updates'),
            value: _automatic,
            onChanged: !_canEdit
                ? null
                : (value) => setState(() => _automatic = value)),
        if (_automatic) ...[
          Wrap(spacing: 8, children: [
            for (var day = 0; day < 7; day++)
              FilterChip(
                  label: Text(_dayNames[day]),
                  selected: _days.contains(day),
                  onSelected: !_canEdit
                      ? null
                      : (value) => setState(() {
                            if (value) {
                              _days.add(day);
                            } else {
                              _days.remove(day);
                            }
                          }))
          ]),
          const SizedBox(height: 12),
          Wrap(
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                    onPressed: _canEdit ? _pickWeeklyTime : null,
                    child: Text(
                        'Machine-local start: ${_weeklyTime.format(context)}')),
                SizedBox(
                    width: 220,
                    child: _numberField(_minutes, 'Weekly window (minutes)'))
              ]),
          if (!_chosen.every((machine) =>
              _supports(machine, 'install') &&
              _supports(machine, 'scheduling')))
            Text(
                'Automatic updates require install and scheduling support on every selected machine. Disabling remains available.',
                style: p.small()),
          if (_weeklyError != null)
            Text(_weeklyError!, style: p.small(color: p.bad))
        ],
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
                key: const ValueKey('save-update-policy'),
                onPressed: _canSave ? _savePolicy : null,
                child: Text(_automatic
                    ? 'Apply weekly policy to selection'
                    : 'Disable automatic updates for selection'))),
      ],
      const SizedBox(height: 20),
      if (visible.isEmpty && !_busy)
        Text('No machines in this scope.', style: p.body()),
      for (final machine in visible) _machineRow(machine),
      const SizedBox(height: 20),
      Text(
          'Installation is complete only when the machine reports the new running version. Cancellation is available during preparation; the service refuses it once installation begins.',
          style: p.small()),
    ]);
  }

  Widget _numberField(TextEditingController controller, String label) =>
      TextField(
          controller: controller,
          enabled: _canEdit,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: label),
          onChanged: (_) => setState(() {}));

  Widget _machineRow(Map<String, dynamic> machine) {
    final p = C.of(context);
    final id = machine['id'] as String;
    final status = _map(machine['status']), policy = _map(machine['policy']);
    final capabilities = _map(status['capabilities']);
    final reported = _instant(status['reportedAt']);
    final age =
        reported == null ? null : DateTime.now().difference(reported).inMinutes;
    final weekly = _map(policy['weekly']);
    final revision = policy['revision'], applied = status['policyRevision'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Divider(color: p.hairline),
      CheckboxListTile(
          key: ValueKey('update-machine-$id'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(_text(machine['name'], id), style: p.body()),
          subtitle: Text(
              '${_text(machine['platform'])} · ${widget.fleetNames[machine['fleetId']] ?? _text(machine['fleetId'], 'No fleet')}',
              style: p.small()),
          value: _selected.contains(id),
          onChanged:
              !_canEdit || (!_selected.contains(id) && _selected.length >= 250)
                  ? null
                  : (value) => setState(() {
                        if (value == true) {
                          _selected.add(id);
                        } else {
                          _selected.remove(id);
                        }
                      })),
      Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (status.isEmpty)
              Text(
                  'No modern updater report. Update this client before remote actions are available.',
                  style: p.small())
            else ...[
              Text(
                  'Running ${_text(status['currentVersion'])} · Available ${_text(status['availableVersion'], 'Not reported')} · ${_text(status['state'])}',
                  style: p.body()),
              Text(
                  reported == null
                      ? 'Report age unknown'
                      : 'Reported ${age! < 1 ? 'just now' : '$age minutes ago'} · ${_time(reported)} UTC',
                  style: p.small()),
              Text(
                  'Check: ${capabilities['check'] == true ? 'supported' : 'unsupported'} · Install: ${capabilities['install'] == true ? 'supported' : 'unsupported'} · Scheduling: ${capabilities['scheduling'] == true ? 'supported' : 'unsupported'}',
                  style: p.small()),
              if (status['error'] is String &&
                  (status['error'] as String).isNotEmpty)
                Text(status['error'] as String, style: p.small(color: p.bad))
            ],
            Text(
                'Automatic: ${policy['automatic'] == true ? 'enabled' : 'disabled'} · Policy ${revision ?? 'unknown'} · ${revision is num && applied == revision ? 'Applied' : 'Pending'} (reported ${applied ?? 'none'})',
                style: p.small()),
            if (policy['automatic'] == true && weekly.isNotEmpty)
              Text(
                  '${weekly['days'] is List ? (weekly['days'] as List).whereType<int>().where((day) => day >= 0 && day < 7).map((day) => _dayNames[day]).join(', ') : 'Days unknown'} · ${_minuteTime(weekly['startMinute'])} machine-local · ${weekly['windowMinutes']} minute window',
                  style: p.small()),
            for (final command in _rows(machine['commands']))
              _commandRow(command),
          ])),
    ]);
  }

  Widget _commandRow(Map<String, dynamic> command) {
    final p = C.of(context);
    final start = _instant(command['startsAt']),
        end = _instant(command['endsAt']);
    final id = _text(command['id'], '');
    final state = _text(command['state']);
    return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(
              spacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                    '${command['action'] == 'install' ? 'Download and install' : 'Check only'} · $state${command['targetVersion'] is String ? ' · Target ${command['targetVersion']}' : ''}',
                    style: p.body()),
                if (_cancellable.contains(state) && id.isNotEmpty)
                  TextButton(
                      onPressed: !_canEdit
                          ? null
                          : () => _mutate((broker) async {
                                await broker.cancelUpdate(id);
                              }, 'Cancellation accepted. Checking command state…'),
                      child: const Text('Cancel preparation'))
              ]),
          Text(
              '${start == null ? 'Start unknown' : _time(start)} — ${end == null ? 'End unknown' : _time(end)} UTC',
              style: p.small()),
          if (command['error'] is String &&
              (command['error'] as String).isNotEmpty)
            Text(command['error'] as String, style: p.small(color: p.bad)),
        ]));
  }
}
