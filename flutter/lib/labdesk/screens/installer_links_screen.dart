import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/organization_context.dart';
import '../services/overlay_broker.dart';
import '../theme/console_theme.dart';

class InstallerLinksScreen extends StatefulWidget {
  const InstallerLinksScreen({super.key, required this.organization});

  final OrganizationContextController organization;

  @override
  State<InstallerLinksScreen> createState() => _InstallerLinksScreenState();
}

class _InstallerLinksScreenState extends State<InstallerLinksScreen> {
  List<Map<String, dynamic>> _links = const [], _platforms = const [];
  List<OrgFleet> _fleets = const [];
  Map<String, dynamic>? _generated;
  String _scope = '', _platform = '', _fleet = '';
  String? _error, _notice;
  int _generation = 0;
  bool _busy = false, _copying = false, _authorized = false;
  DateTime? _lastRead;
  Timer? _clock;

  OrganizationContextController get _organization => widget.organization;
  bool get _ready =>
      _organization.ready &&
      !_organization.busy &&
      _organization.matchesCredential(_organization.broker.token());
  bool get _canWrite => _ready && _authorized && !_busy;
  bool get _canGenerate =>
      _canWrite &&
      _platforms.any((platform) => platform['key'] == _platform) &&
      (_fleets.isEmpty || _fleets.any((fleet) => fleet.id == _fleet));
  bool _current(int generation, String credential) =>
      mounted &&
      _ready &&
      generation == _generation &&
      _organization.matchesCredential(credential) &&
      _organization.broker.token() == credential;

  static String _text(Object? value, [String fallback = 'Unknown']) =>
      value is String && value.isNotEmpty ? value : fallback;
  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
  static String _time(Object? value) {
    final date = _date(value);
    return date == null
        ? 'Unknown'
        : '${date.toLocal().toString().split('.').first} local';
  }

  static List<Map<String, dynamic>> _rows(Object? value) {
    if (value is! List || value.any((row) => row is! Map<String, dynamic>)) {
      throw const FormatException('Invalid installer links response');
    }
    return value.cast<Map<String, dynamic>>();
  }

  String _state(Map<String, dynamic> link) {
    if (link['revokedAt'] != null) return 'Revoked';
    final expires = _date(link['expiresAt']);
    if (expires == null) return 'Expiry unknown';
    return expires.isAfter(DateTime.now()) ? 'Active' : 'Expired';
  }

  @override
  void initState() {
    super.initState();
    _organization.addListener(_contextChanged);
    _contextChanged();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(InstallerLinksScreen oldWidget) {
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
    _clock?.cancel();
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
      _links = _platforms = const [];
      _fleets = const [];
      _generated = null;
      _platform = _fleet = '';
      _busy = _copying = _authorized = false;
      _error = _notice = null;
      _lastRead = null;
    });
    scheduleMicrotask(() {
      if (mounted && _ready) _refresh();
    });
  }

  void _failure(Object failure) {
    if (failure is OverlayBrokerException && failure.signInAgain) {
      _organization.invalidate(failure.message);
      return;
    }
    setState(() {
      _error = failure is OverlayBrokerException
          ? failure.message
          : 'The request could not be confirmed. Refresh before trying again.';
      // This route requires download:share; a refusal does not imply the
      // account lost access to every other organization feature.
      if (failure is OverlayBrokerException && failure.status == 403) {
        _authorized = false;
        _generated = null;
        _links = _platforms = const [];
        _fleets = const [];
        _platform = _fleet = '';
      }
    });
  }

  Future<void> _read(
      OverlayBroker broker, int generation, String credential) async {
    try {
      // GET checks the same download:share permission as create and revoke.
      final result = await broker.downloadLinks();
      if (!_current(generation, credential)) return;
      final links = _rows(result['links']),
          platforms = _rows(result['platforms']);
      if (links.any((link) => _text(link['id'], '').isEmpty) ||
          platforms.any((platform) =>
              _text(platform['key'], '').isEmpty ||
              _text(platform['label'], '').isEmpty) ||
          platforms.map((platform) => platform['key']).toSet().length !=
              platforms.length) {
        throw const FormatException('Invalid installer catalog');
      }
      final fleets = await broker.fleets();
      if (!_current(generation, credential)) return;
      if (fleets.any((fleet) => fleet.id.isEmpty) ||
          fleets.map((fleet) => fleet.id).toSet().length != fleets.length) {
        throw const FormatException('Invalid fleet selection');
      }
      setState(() {
        _links = links;
        _platforms = platforms;
        _fleets = fleets;
        _authorized = true;
        _error = null;
        _lastRead = DateTime.now();
        if (!_platforms.any((platform) => platform['key'] == _platform)) {
          _platform = platforms.isEmpty ? '' : platforms.first['key'] as String;
        }
        if (!_fleets.any((fleet) => fleet.id == _fleet)) {
          _fleet = fleets.length == 1 ? fleets.single.id : '';
        }
        if (_generated != null &&
            links.any((link) =>
                link['id'] == _generated!['id'] && link['revokedAt'] != null)) {
          _generated = null;
        }
      });
    } catch (failure) {
      if (!_current(generation, credential)) return;
      setState(() => _authorized = false);
      _failure(failure);
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

  Future<void> _write({String? revokeId}) async {
    if (!_canWrite || (revokeId == null && !_canGenerate)) return;
    if (revokeId != null &&
        !_links
            .any((link) => link['id'] == revokeId && _state(link) == 'Active'))
      return;
    final generation = _generation;
    final broker = _organization.broker.captureScope();
    final credential = broker.token();
    final platform = _platform, fleet = _fleet;
    setState(() {
      _busy = true;
      _error = _notice = null;
    });
    try {
      if (revokeId != null) {
        await broker.revokeDownloadLink(revokeId);
        if (!_current(generation, credential)) return;
        setState(() {
          if (_generated?['id'] == revokeId) _generated = null;
          _notice = 'Revocation accepted. Checking saved state…';
        });
      } else {
        final result = await broker.createDownloadLink(platform,
            fleetId: fleet.isEmpty ? null : fleet);
        if (!_current(generation, credential)) return;
        final uri = Uri.tryParse(_text(result['url'], ''));
        if (_text(result['id'], '').isEmpty ||
            result['platform'] != platform ||
            _date(result['expiresAt']) == null ||
            uri == null ||
            !const ['https', 'http'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const FormatException('Invalid generated link');
        }
        setState(() {
          _generated = result;
          _notice = 'Link created. Copy it before leaving this page.';
        });
      }
      await _read(broker, generation, credential);
    } catch (failure) {
      if (_current(generation, credential)) _failure(failure);
    } finally {
      if (_current(generation, credential)) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    final link = _generated;
    if (!_canWrite || _copying || link == null || _state(link) != 'Active')
      return;
    final generation = _generation;
    final credential = _organization.broker.token();
    setState(() {
      _copying = true;
      _notice = null;
    });
    try {
      await Clipboard.setData(ClipboardData(text: link['url'] as String));
      if (_current(generation, credential))
        setState(() => _notice = 'Link copied.');
    } catch (_) {
      if (_current(generation, credential))
        setState(() => _notice =
            'Could not copy automatically. Select the link and copy it manually.');
    } finally {
      if (_current(generation, credential)) setState(() => _copying = false);
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
                      'Choose an organization to share installers.',
                  style: p.body())));
    final names = {for (final fleet in _fleets) fleet.id: fleet.name};
    final labels = {
      for (final platform in _platforms) platform['key']: platform['label']
    };
    return ListView(padding: const EdgeInsets.all(24), children: [
      Row(children: [
        Expanded(child: Text('Share an installer', style: p.h2())),
        TextButton.icon(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Refresh'))
      ]),
      Text(
          'Anyone with the link can download the latest published installer repeatedly for 24 hours. It does not enroll a machine or grant network access.',
          style: p.body()),
      const SizedBox(height: 8),
      Text(
          'The URL is shown only when created. Copy it before leaving; it cannot be recovered from the history.',
          style: p.small()),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null)
        Semantics(
            liveRegion: true,
            child: Text(_error!, style: p.body(color: p.bad))),
      if (_notice != null)
        Semantics(liveRegion: true, child: Text(_notice!, style: p.body())),
      const SizedBox(height: 20),
      if (_authorized) ...[
        if (_platforms.isEmpty)
          Text('No stable installers are currently published.', style: p.body())
        else
          Wrap(
              spacing: 16,
              runSpacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                    width: 280,
                    child: DropdownButtonFormField<String>(
                        value: _platform,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: 'Operating system and package'),
                        items: [
                          for (final platform in _platforms)
                            DropdownMenuItem(
                                value: platform['key'] as String,
                                child: Text(platform['label'] as String,
                                    overflow: TextOverflow.ellipsis))
                        ],
                        onChanged: !_canWrite
                            ? null
                            : (value) => setState(() => _platform = value!))),
                if (_fleets.isNotEmpty)
                  SizedBox(
                      width: 240,
                      child: DropdownButtonFormField<String>(
                          value: _fleet,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Fleet'),
                          items: [
                            const DropdownMenuItem(
                                value: '', child: Text('Choose fleet')),
                            for (final fleet in _fleets)
                              DropdownMenuItem(
                                  value: fleet.id,
                                  child: Text(fleet.name,
                                      overflow: TextOverflow.ellipsis))
                          ],
                          onChanged: !_canWrite
                              ? null
                              : (value) => setState(() => _fleet = value!))),
                FilledButton(
                    key: const ValueKey('generate-installer-link'),
                    onPressed: _canGenerate ? () => _write() : null,
                    child: const Text('Generate link'))
              ]),
        if (_fleets.length > 1 && _fleet.isEmpty)
          Text('Choose which fleet this link belongs to.', style: p.small()),
      ],
      if (_generated case final link?) ...[
        const SizedBox(height: 24),
        Text('Created download link', style: p.h2()),
        const SizedBox(height: 8),
        SelectableText(link['url'] as String,
            key: const ValueKey('generated-installer-url'), style: p.body()),
        Text('${_state(link)} · Expires ${_time(link['expiresAt'])}',
            style: p.small()),
        Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
                onPressed: _canWrite && !_copying && _state(link) == 'Active'
                    ? _copy
                    : null,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy link'))),
      ],
      const SizedBox(height: 24),
      Text('Recent links', style: p.h2()),
      if (_lastRead != null)
        Text(
            '${_error == null ? 'Last read' : 'Showing older metadata from'} ${_time(_lastRead!.toIso8601String())}',
            style: p.small()),
      if (_links.isEmpty && !_busy && _authorized)
        Text('No installer links have been created in this scope.',
            style: p.small()),
      for (final link in _links) ...[
        Divider(color: p.hairline),
        Wrap(
            spacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_text(labels[link['platform']], _text(link['platform'])),
                  style: p.body()),
              Text(_state(link), style: p.small()),
              if (_state(link) == 'Active')
                TextButton(
                    onPressed: _canWrite
                        ? () => _write(revokeId: link['id'] as String)
                        : null,
                    child: const Text('Revoke'))
            ]),
        Text(
            '${link['fleetId'] == null ? 'Organization' : names[link['fleetId']] ?? _text(link['fleetId'])} · Created ${_time(link['createdAt'])} · Expires ${_time(link['expiresAt'])}',
            style: p.small()),
        Text('Created by ${_text(link['createdBy'])}', style: p.small()),
        if (link['revokedAt'] != null)
          Text('Revoked ${_time(link['revokedAt'])}', style: p.small()),
      ],
    ]);
  }
}
