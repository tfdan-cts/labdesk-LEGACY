import 'dart:async';

import 'package:flutter/material.dart';

import '../models/health_event.dart';
import '../services/organization_context.dart';
import '../services/overlay_broker.dart';
import '../theme/console_theme.dart';

/// Organization alerts share the console's verified authority. This leaf owns
/// its requests, so leaving the tab or changing accounts discards late results.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen(
      {super.key, required this.organization, this.machineNames = const {}});

  final OrganizationContextController organization;
  final Map<String, String> machineNames;

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<HealthEvent> _events = const [];
  String _scope = '', _role = '';
  int _generation = 0;
  bool _loading = false;
  String? _acknowledging, _loadError, _notice, _unverifiedAck;
  DateTime? _lastRead;

  OrganizationContextController get _organization => widget.organization;
  bool get _ready =>
      _organization.ready &&
      !_organization.busy &&
      _organization.matchesCredential(_organization.broker.token());
  bool get _canAcknowledge => _role == 'owner' || _role == 'technician';
  bool get _busy => _loading || _acknowledging != null;
  bool _current(int generation, String credential) =>
      mounted &&
      _ready &&
      generation == _generation &&
      _organization.matchesCredential(credential) &&
      _organization.broker.token() == credential;

  @override
  void initState() {
    super.initState();
    _organization.addListener(_contextChanged);
    _contextChanged();
  }

  @override
  void didUpdateWidget(AlertsScreen oldWidget) {
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
    super.dispose();
  }

  void _contextChanged() {
    final scope =
        '${_organization.revision}/${_organization.contextKey}/$_ready';
    if (!mounted || scope == _scope) return;
    setState(() {
      _scope = scope;
      _generation++;
      _events = const [];
      _role = '';
      _loading = false;
      _acknowledging = _loadError = _notice = _unverifiedAck = null;
      _lastRead = null;
    });
    scheduleMicrotask(() {
      if (mounted && _ready) _refresh();
    });
  }

  String _failure(Object failure) => failure is OverlayBrokerException
      ? failure.message
      : 'The service could not be reached. Refresh to try again.';

  Future<void> _read(
      OverlayBroker broker, int generation, String credential) async {
    try {
      final role = await broker.organizationRole();
      if (!_current(generation, credential)) return;
      if (!const ['owner', 'technician', 'viewer'].contains(role)) {
        throw const OverlayBrokerException(
            502, 'Alert permissions could not be read.');
      }
      final events = await broker.healthEvents();
      if (!_current(generation, credential)) return;
      setState(() {
        _events = events;
        _role = role;
        _lastRead = DateTime.now();
        _loadError = null;
        if (_unverifiedAck != null) {
          final matching = events.where((event) => event.id == _unverifiedAck);
          if (matching.isNotEmpty && matching.first.acknowledgedAt != null) {
            _notice = _unverifiedAck = null;
          } else {
            _notice = matching.isEmpty
                ? 'Acknowledgment accepted. This alert is no longer among the latest 500.'
                : 'The service accepted the request, but its saved acknowledgment is not confirmed. Refresh to check.';
          }
        }
      });
    } catch (failure) {
      if (!_current(generation, credential)) return;
      if (failure is OverlayBrokerException &&
          (failure.signInAgain || failure.status == 403)) {
        _organization.invalidate(failure.message);
        return;
      }
      setState(() {
        _role = '';
        _loadError = _failure(failure);
      });
    }
  }

  Future<void> _refresh() async {
    if (!_ready || _busy) return;
    final generation = _generation;
    final broker = _organization.broker.captureScope();
    final credential = broker.token();
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await _read(broker, generation, credential);
    } finally {
      if (_current(generation, credential)) setState(() => _loading = false);
    }
  }

  Future<void> _acknowledge(HealthEvent event) async {
    if (!_ready ||
        _busy ||
        !_canAcknowledge ||
        event.acknowledgedAt != null ||
        !_events.any((current) => current.id == event.id)) return;
    final generation = _generation;
    final broker = _organization.broker.captureScope();
    final credential = broker.token();
    setState(() {
      _acknowledging = event.id;
      _notice = _unverifiedAck = null;
    });
    try {
      final role = await broker.organizationRole();
      if (!_current(generation, credential)) return;
      if (role != 'owner' && role != 'technician') {
        throw const OverlayBrokerException(
            403, 'Only an owner or technician can acknowledge alerts.');
      }
      await broker.acknowledgeHealthEvent(event.id);
      if (!_current(generation, credential)) return;
      setState(() {
        _unverifiedAck = event.id;
        _notice = 'Acknowledgment accepted. Checking its saved state…';
      });
      await _read(broker, generation, credential);
    } catch (failure) {
      if (!_current(generation, credential)) return;
      if (failure is OverlayBrokerException &&
          (failure.signInAgain || failure.status == 403)) {
        _organization.invalidate(failure.message);
        return;
      }
      setState(() {
        _role = '';
        _notice = _failure(failure);
      });
      await _read(broker, generation, credential);
    } finally {
      if (_current(generation, credential)) {
        setState(() => _acknowledging = null);
      }
    }
  }

  String _time(DateTime time) => time.toLocal().toString().split('.').first;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    if (!_ready) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                  _organization.error ??
                      'Choose an organization to read its alerts.',
                  style: p.body())));
    }
    return Padding(
        padding: const EdgeInsets.all(24),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Recent alerts', style: p.h2())),
            TextButton.icon(
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh')),
          ]),
          Text(
              'Latest 500 events visible to your organization and fleets. Refresh to check for new alerts.',
              style: p.small()),
          if (_lastRead != null)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    '${_loadError == null ? 'Last checked' : 'Showing older alerts from'} ${_time(_lastRead!)}',
                    style: p.small())),
          if (_loadError != null)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                    liveRegion: true,
                    child: Text(_loadError!, style: p.body(color: p.bad)))),
          if (_notice != null)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                    liveRegion: true, child: Text(_notice!, style: p.body()))),
          if (_role == 'viewer')
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                    'Read-only access. An owner or technician can acknowledge alerts.',
                    style: p.small())),
          if (_loading)
            const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator()),
          const SizedBox(height: 16),
          Expanded(
              child: _events.isEmpty
                  ? Center(
                      child: Text(
                          _loading || (_lastRead == null && _loadError == null)
                              ? 'Loading alerts…'
                              : _loadError == null
                                  ? 'No recent alerts.'
                                  : 'Alerts are unavailable.',
                          style: p.body()))
                  : ListView.separated(
                      itemCount: _events.length,
                      separatorBuilder: (_, __) =>
                          Divider(color: p.hairline, height: 32),
                      itemBuilder: (context, index) {
                        final event = _events[index];
                        final color = event.severity == 'critical'
                            ? p.bad
                            : event.severity == 'warn'
                                ? p.warning
                                : p.textMuted;
                        return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(spacing: 16, runSpacing: 4, children: [
                                Text(event.severity.toUpperCase(),
                                    style: p.small(color: color)),
                                Text(_time(event.at), style: p.small()),
                                Text(
                                    event.machineId == null
                                        ? 'Organization'
                                        : widget.machineNames[
                                                event.machineId] ??
                                            event.machineId!,
                                    style: p.small()),
                              ]),
                              const SizedBox(height: 8),
                              SelectableText(event.summary, style: p.body()),
                              if (event.detail != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: SelectableText(event.detail!,
                                        style: p.small())),
                              const SizedBox(height: 8),
                              if (event.acknowledgedAt != null)
                                Text(
                                    'Acknowledged ${_time(event.acknowledgedAt!)}'
                                    '${event.acknowledgedBy == null ? '' : ' · ${event.acknowledgedBy}'}',
                                    style: p.small())
                              else
                                TextButton(
                                    onPressed: _canAcknowledge && !_busy
                                        ? () => _acknowledge(event)
                                        : null,
                                    child: Text(_acknowledging == event.id
                                        ? 'Acknowledging…'
                                        : 'Acknowledge')),
                            ]);
                      })),
        ]));
  }
}
