import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/labnet.dart';
import '../models/exit_routing.dart';
import '../services/organization_context.dart';
import '../services/overlay_broker.dart';
import '../services/overlay_daemon.dart';
import '../theme/console_theme.dart';
import 'network_screen.dart';

const _permissions = <String, String>{
  'view': 'View screen',
  'control': 'Control screen',
  'files': 'Files',
  'clipboard': 'Clipboard',
  'audio': 'Audio',
  'camera': 'Camera',
  'terminal': 'Terminal',
  'terminalAdmin': 'Administrator terminal',
  'rdp': 'RDP',
  'tunnel': 'TCP tunnel',
  'remotePrinter': 'Remote printer',
  'restart': 'Restart',
  'recording': 'Recording',
  'blockInput': 'Block input',
  'privacyMode': 'Privacy mode',
  'remoteConfig': 'Remote settings',
};

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : const {};
String _text(Object? value, [String fallback = 'Not reported']) =>
    value is String && value.isNotEmpty ? value : fallback;
List<String> _caps(Object? value) => value is List
    ? value.whereType<String>().where(_permissions.containsKey).toList()
    : [];
List<Map<String, dynamic>> _rows(Object? value) {
  if (value is! List ||
      value.any((row) =>
          row is! Map<String, dynamic> ||
          row['id'] is! String ||
          (row['id'] as String).isEmpty)) {
    throw const FormatException('Invalid sharing response');
  }
  final rows = value.cast<Map<String, dynamic>>();
  if (rows.map((row) => row['id']).toSet().length != rows.length) {
    throw const FormatException('Duplicate sharing rows');
  }
  return rows;
}

/// A broker assertion of freshness also needs a locally checked timestamp.
bool routingReportFresh(Map<String, dynamic> preference, DateTime now) {
  final reported = preference['reportedAt'];
  if (preference['stateFresh'] != true ||
      reported is! num ||
      !reported.isFinite) return false;
  final age = now.millisecondsSinceEpoch / 1000 - reported;
  return age >= 0 && age <= 45;
}

String routingAcknowledgement(Map<String, dynamic> preference, DateTime now) {
  if (preference['status'] == 'pending' ||
      preference['revision'] != preference['ackRevision']) {
    return 'Pending machine acknowledgement';
  }
  if (!routingReportFresh(preference, now))
    return 'Routing report stale or unavailable';
  if (preference['revision'] is! int ||
      (preference['revision'] as int) < 0 ||
      !preference.containsKey('exitId') ||
      !preference.containsKey('appliedExitId')) {
    return 'Routing state not confirmed';
  }
  if (preference['exitId'] == preference['appliedExitId']) {
    if (preference['status'] == 'direct' && preference['exitId'] == null) {
      return 'Direct connection acknowledged by machine';
    }
    if (preference['status'] == 'selected' &&
        preference['exitId'] is String &&
        (preference['exitId'] as String).isNotEmpty) {
      return 'Exit selection acknowledged by machine';
    }
  }
  return 'Routing state: ${_text(preference['status'], 'not confirmed')}';
}

Uri? verifiedLabnetInvitation(String value, String brokerUrl) {
  final uri = Uri.tryParse(value.trim()), origin = Uri.tryParse(brokerUrl);
  if (uri == null ||
      origin == null ||
      uri.scheme != 'https' ||
      origin.scheme != 'https' ||
      !uri.hasAuthority ||
      !origin.hasAuthority ||
      uri.origin != origin.origin ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery) return null;
  if (RegExp(r'^/s/i/[A-Za-z0-9_-]{43}$').hasMatch(uri.path) &&
      !uri.hasFragment) return uri;
  if (uri.path == '/accept-labnet-invitation' &&
      RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(uri.fragment)) return uri;
  return null;
}

/// Human management uses the broker; host consent uses only the local typed bridge.
class LabnetSharingControls extends StatefulWidget {
  const LabnetSharingControls(
      {super.key,
      required this.organization,
      required this.labnets,
      this.machines = const [],
      this.canManageMachines = false,
      this.daemon,
      this.localMachineId = '',
      this.localEnrolled = false});
  final OrganizationContextController organization;
  final List<Labnet> labnets;
  final List<NetworkMachine> machines;
  final bool canManageMachines;
  final OverlayDaemon? daemon;
  /// Canonical identity verified from this machine's local enrollment.
  final String localMachineId;
  final bool localEnrolled;

  @override
  State<LabnetSharingControls> createState() => _LabnetSharingControlsState();
}

class _LabnetSharingControlsState extends State<LabnetSharingControls> {
  final _email = TextEditingController(), _link = TextEditingController();
  final _subnetName = TextEditingController(), _cidr = TextEditingController();
  final _grants = <String>{};
  List<Map<String, dynamic>> _shared = [],
      _invitations = [],
      _people = [],
      _exits = [],
      _subnets = [];
  Map<String, dynamic> _routing = {}, _offerCapabilities = {};
  String _scope = '',
      _labnet = '',
      _machine = '',
      _kind = 'person',
      _delivery = 'link';
  String? _error, _notice, _createdUrl, _createdId, _draftExit;
  bool _busy = false,
      _dirty = false,
      _allowLocalLan = true,
      _allowExitLan = false;
  int _generation = 0;
  Timer? _poll;
  List<Map<String, dynamic>> _hostExits = [], _hostSubnets = [];
  final _hostSubmitted = <String>{};
  ExitRoutingReadback _localRouting = const ExitRoutingReadback();
  DateTime? _localReadAt;
  String? _hostError;

  OrganizationContextController get _org => widget.organization;
  bool get _ready =>
      _org.authenticated &&
      !_org.busy &&
      _org.matchesCredential(_org.broker.token());
  bool get _enabled => _ready && !_busy && _error == null;
  bool get _localAvailable => widget.localEnrolled &&
      widget.localMachineId.isNotEmpty && widget.daemon != null;
  bool get _localFresh {
    final at = _localReadAt;
    if (at == null || _localRouting.error != null) return false;
    final age = DateTime.now().difference(at);
    return !age.isNegative && age <= const Duration(seconds: 45);
  }
  bool _canDecideHost(Map<String, dynamic> offer, {required bool subnet, required bool accept}) {
    final key = '$subnet/${offer['id']}';
    return _ready && !_busy && _hostError == null && _localAvailable &&
        offer['machineId'] == widget.localMachineId &&
        offer['status'] == 'pending' && !_hostSubmitted.contains(key) &&
        (subnet ? _hostSubnets : _hostExits).any((row) =>
            row['id'] == offer['id'] && row['status'] == 'pending') &&
        (!accept || (_localFresh && (subnet
            ? _localRouting.subnetSharingSupported && offer['cidr'] is String &&
                (offer['cidr'] as String).isNotEmpty
            : _localRouting.hostingSupported && _localRouting.exitLanSupported &&
                offer['allowExitLan'] is bool)));
  }
  List<Labnet> get _owned =>
      _org.ready ? widget.labnets.where((l) => l.owner).toList() : [];
  Labnet? get _selected {
    for (final labnet in _owned) {
      if (labnet.id == _labnet) return labnet;
    }
    return null;
  }

  Map<String, dynamic> get _preference => _map(_routing['preference']);
  Map<String, dynamic> get _capabilities => _map(_routing['capabilities']);
  bool get _fresh => routingReportFresh(_preference, DateTime.now());
  bool get _approvedSource =>
      _selected?.members.any((m) => m.deviceId == _machine && m.approved) ==
      true;
  bool _current(int generation, String credential) =>
      mounted &&
      _ready &&
      generation == _generation &&
      _org.matchesCredential(credential) &&
      _org.broker.token() == credential;

  @override
  void initState() {
    super.initState();
    _org.addListener(_contextChanged);
    _contextChanged();
  }

  @override
  void didUpdateWidget(LabnetSharingControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.organization != _org) {
      oldWidget.organization.removeListener(_contextChanged);
      _org.addListener(_contextChanged);
      _scope = '';
    }
    if (oldWidget.daemon != widget.daemon) _scope = '';
    _contextChanged();
  }

  @override
  void dispose() {
    _generation++;
    _poll?.cancel();
    _org.removeListener(_contextChanged);
    for (final controller in [_email, _link, _subnetName, _cidr]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _contextChanged() {
    final scope = '${_org.revision}/${_org.contextKey}/$_ready/${_org.ready}/'
        '${_owned.map((l) => l.id).join(',')}/${widget.machines.map((m) => m.id).join(',')}/'
        '${widget.localMachineId}/${widget.localEnrolled}';
    if (!mounted || scope == _scope) return;
    _poll?.cancel();
    setState(() {
      _scope = scope;
      _generation++;
      _busy = _dirty = _allowExitLan = false;
      _error = _notice = _createdUrl = _createdId = _draftExit = null;
      _shared = [];
      _invitations = [];
      _people = [];
      _exits = [];
      _subnets = [];
      _routing = {};
      _offerCapabilities = {};
      _hostExits = []; _hostSubnets = []; _hostSubmitted.clear();
      _localRouting = const ExitRoutingReadback(); _localReadAt = null; _hostError = null;
      _labnet = _owned.isEmpty ? '' : _owned.first.id;
      _machine = _org.ready && widget.machines.isNotEmpty
          ? widget.machines.first.id
          : '';
      _grants.clear();
      _email.clear();
      _link.clear();
      _subnetName.clear();
      _cidr.clear();
    });
    scheduleMicrotask(() {
      if (mounted && _ready) _refresh();
    });
  }

  Future<void> _read(
      OverlayBroker broker, int generation, String credential) async {
    await _readHosting(broker, generation, credential);
    if (!_current(generation, credential)) return;
    final shared = _rows((await broker.sharedLabnets())['labnets']);
    if (!_current(generation, credential)) return;
    var invitations = <Map<String, dynamic>>[],
        people = <Map<String, dynamic>>[];
    var exits = <Map<String, dynamic>>[], subnets = <Map<String, dynamic>>[];
    var routing = <String, dynamic>{}, offerCapabilities = <String, dynamic>{};
    if (_selected != null) {
      final invitationData = await broker.labnetInvitations(_labnet);
      if (!_current(generation, credential)) return;
      invitations = _rows(invitationData['invitations']);
      people = _rows(invitationData['users']);
      final offers = await broker.exitOffers(_labnet);
      if (!_current(generation, credential)) return;
      exits = _rows(offers['exits']);
      offerCapabilities = _map(offers['capabilities']);
      subnets = _rows((await broker.subnets(_labnet))['subnets']);
      if (!_current(generation, credential)) return;
    }
    if (_org.ready && _machine.isNotEmpty) {
      routing = await broker.machineRouting(_machine);
      if (!_current(generation, credential)) return;
      _rows(routing['exits']);
      if (routing['preference'] is! Map<String, dynamic>)
        throw const FormatException('Invalid routing');
    }
    setState(() {
      _shared = shared;
      _invitations = invitations;
      _people = people;
      _exits = exits;
      _subnets = subnets;
      _routing = routing;
      _offerCapabilities = offerCapabilities;
      if (!_dirty) {
        _draftExit = _preference['exitId'] is String
            ? _preference['exitId'] as String
            : null;
        _allowLocalLan = _preference['allowLocalLan'] != false;
      }
      _error = null;
    });
  }

  Future<void> _readHosting(OverlayBroker broker, int generation, String credential) async {
    if (!_localAvailable) return;
    try {
      final hosting = await broker.hostingOffers();
      if (!_current(generation, credential)) return;
      if (hosting['machineId'] != widget.localMachineId) {
        throw const FormatException('Hosting identity mismatch');
      }
      List<Map<String, dynamic>> ownOffers(Object? value) => [
        for (final offer in _rows(value))
          if (offer['machineId'] == null || offer['machineId'] == widget.localMachineId)
            {...offer, 'machineId': widget.localMachineId},
      ];
      final exits = ownOffers(hosting['hostedExits']);
      final subnets = ownOffers(hosting['hostedSubnets']);
      final readStarted = DateTime.now();
      final routing = await widget.daemon!.routing();
      if (!_current(generation, credential)) return;
      setState(() {
        _hostExits = exits; _hostSubnets = subnets;
        _localRouting = routing; _localReadAt = readStarted; _hostError = null;
        _hostSubmitted.retainAll({
          for (final offer in exits) if (offer['status'] == 'pending') 'false/${offer['id']}',
          for (final offer in subnets) if (offer['status'] == 'pending') 'true/${offer['id']}',
        });
      });
    } catch (failure) {
      if (!_current(generation, credential)) return;
      setState(() {
        _localReadAt = null;
        _hostError = failure is OverlayBrokerException ? failure.message
            : 'Local hosting offers could not be verified. Refresh before deciding.';
      });
    }
  }

  Future<void> _refresh() async {
    if (!_ready || _busy) return;
    await _run(null);
  }

  Future<void> _decideHost(Map<String, dynamic> offer,
      {required bool subnet, required bool accept}) async {
    if (!_canDecideHost(offer, subnet: subnet, accept: accept)) return;
    final generation = _generation, credential = _org.broker.token();
    final daemon = widget.daemon!, id = offer['id'] as String;
    final label = '${accept ? 'Accept' : 'Decline'} ${subnet ? 'subnet' : 'exit'} offer';
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(label),
      content: Text(accept
        ? subnet
          ? 'Allow this machine to route ${_text(offer['cidr'])} for ${_text(offer['labnetName'])}. '
              'The local service verifies router support and conflicting exit isolation before signing approval.'
          : 'Allow this machine to provide internet routing for ${_text(offer['labnetName'])}. '
              '${offer['allowExitLan'] == true ? 'Exit users may reach this machine’s LAN.' : 'Exit users must be isolated from this machine’s LAN.'} '
              'The local service verifies the exact policy before signing approval.'
        : 'Refuse this hosting request on this machine. No other Labnet membership changes.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(label))]));
    if (confirmed != true || !_current(generation, credential) ||
        !_canDecideHost(offer, subnet: subnet, accept: accept)) return;
    await _run((_) async {
      final error = subnet ? await daemon.decideSubnet(id, accept: accept)
          : await daemon.decideExit(id, accept: accept);
      if (!_current(generation, credential)) return null;
      if (error != null) throw OverlayBrokerException(0, error, machinePlane: true);
      setState(() => _hostSubmitted.add('$subnet/$id'));
      final readback = await daemon.routing(applyPending: true);
      if (!_current(generation, credential)) return null;
      setState(() { _localRouting = readback; _localReadAt = DateTime.now(); });
      if (readback.error != null) throw OverlayBrokerException(0, readback.error!, machinePlane: true);
      return null;
    }, hostAction: true, notice: '${accept ? 'Approval' : 'Decline'} submitted by this machine. '
        'Waiting for the reported offer state; reachability is not confirmed.');
  }

  Widget _hostOffer(Map<String, dynamic> offer, {required bool subnet}) {
    final submitted = _hostSubmitted.contains('$subnet/${offer['id']}');
    final revoked = offer['status'] == 'revoked';
    return _row(subnet ? _text(offer['name']) : 'Internet exit for ${_text(offer['labnetName'])}',
      '${subnet ? '${_text(offer['cidr'])} · ${_text(offer['labnetName'])} · ' : ''}'
      '${submitted ? 'Decision submitted; waiting for offer state' : _text(offer['status'])}'
      '${revoked && offer['cleanupConfirmed'] != true ? ' · cleanup pending' : ''}'
      '${offer['error'] is String ? ' · ${offer['error']}' : ''}', [
        if (offer['status'] == 'pending') ...[
          TextButton(key: ValueKey('accept-host-${subnet ? 'subnet' : 'exit'}-${offer['id']}'),
            onPressed: _canDecideHost(offer, subnet: subnet, accept: true)
                ? () => _decideHost(offer, subnet: subnet, accept: true) : null,
            child: Text('Accept ${subnet ? 'subnet' : 'exit'} offer')),
          TextButton(key: ValueKey('decline-host-${subnet ? 'subnet' : 'exit'}-${offer['id']}'),
            onPressed: _canDecideHost(offer, subnet: subnet, accept: false)
                ? () => _decideHost(offer, subnet: subnet, accept: false) : null,
            child: Text('Decline ${subnet ? 'subnet' : 'exit'} offer')),
        ],
      ]);
  }

  Future<void> _run(
      Future<Map<String, dynamic>?> Function(OverlayBroker)? action,
      {String? notice,
      String? revokedInvitationId,
      bool hostAction = false}) async {
    if (!_ready || _busy) return;
    final generation = _generation, broker = _org.broker.captureScope();
    final credential = broker.token();
    _poll?.cancel();
    setState(() {
      _busy = true;
      if (action != null) _notice = null;
    });
    try {
      final result = action == null ? null : await action(broker);
      if (!_current(generation, credential)) return;
      if (action != null) {
        setState(() {
          _notice = result?['cleanupPending'] == true
              ? 'Removal requested. Network cleanup pending; access removal is not confirmed.'
              : notice;
          if (revokedInvitationId != null &&
              revokedInvitationId == _createdId) {
            _createdUrl = _createdId = null;
          }
          if (result != null && result['url'] is String) {
            final verified = verifiedLabnetInvitation(
                result['url'] as String, broker.baseUrl);
            if (verified == null)
              throw const FormatException('Invalid invitation URL');
            _createdUrl = verified.toString();
            _createdId = result['id'] is String ? result['id'] as String : null;
          }
          _dirty = false;
        });
      }
      await _read(broker, generation, credential);
    } catch (failure) {
      if (!_current(generation, credential)) return;
      if (failure is OverlayBrokerException && failure.signInAgain) {
        _org.invalidate(failure.message);
      } else {
        setState(() {
          if (hostAction) {
            _localReadAt = null;
            _hostError = failure is OverlayBrokerException ? failure.message
                : 'The local hosting decision could not be confirmed. Refresh before retrying.';
            return;
          }
          if (failure is OverlayBrokerException && failure.status == 403) {
            _createdUrl = _createdId = null;
          }
          _error = failure is OverlayBrokerException
              ? failure.message
              : 'The request could not be confirmed. Refresh before retrying.';
        });
      }
    } finally {
      if (_current(generation, credential)) {
        setState(() => _busy = false);
        _poll = Timer(const Duration(seconds: 15), _refresh);
      }
    }
  }

  void _select({String? labnet, String? machine}) {
    if (!_enabled) return;
    setState(() {
      if (labnet != null) _labnet = labnet;
      if (machine != null) _machine = machine;
      _dirty = false;
      _createdUrl = _createdId = _notice = null;
      _routing = {};
      _invitations = [];
      _people = [];
      _exits = [];
      _subnets = [];
      _offerCapabilities = {};
      _allowExitLan = false;
    });
    _refresh();
  }

  Future<void> _confirm(String title, String explanation,
      Future<Map<String, dynamic>> Function(OverlayBroker) action,
      {String? revokedInvitationId}) async {
    final generation = _generation, credential = _org.broker.token();
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(title),
                content: Text(explanation),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(title)),
                ]));
    if (accepted == true && _current(generation, credential) && _enabled) {
      await _run(action,
          notice:
              'Removal confirmed. Other independent memberships remain unchanged.',
          revokedInvitationId: revokedInvitationId);
    }
  }

  Future<void> _editAccess(Map<String, dynamic> person) async {
    final generation = _generation,
        credential = _org.broker.token(),
        labnet = _labnet;
    final grants = _caps(person['capabilities']).toSet();
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: Text('Access for ${_text(person['name'])}'),
                    content: SizedBox(
                        width: 480,
                        child: SingleChildScrollView(
                            child: _permissionPicker(grants, update))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Save access'))
                    ])));
    if (accepted != true || !_current(generation, credential) || !_enabled)
      return;
    await _run((broker) async {
      await broker.setLabnetAccess(
          labnet, person['id'] as String, grants.toList());
      return null;
    },
        notice:
            'Shared Connect permissions saved. Target permissions still apply.');
  }

  Widget _permissionPicker(Set<String> grants, StateSetter update) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(
            'No selections grants network access only. Target permissions remain an additional limit.'),
        Wrap(spacing: 8, children: [
          for (final entry in _permissions.entries)
            FilterChip(
                label: Text(entry.value),
                selected: grants.contains(entry.key),
                onSelected: (selected) => update(() {
                      if (selected) {
                        grants.add(entry.key);
                        if (entry.key == 'control') grants.add('view');
                        if (entry.key == 'terminalAdmin')
                          grants.add('terminal');
                      } else {
                        grants.remove(entry.key);
                        if (entry.key == 'view') grants.remove('control');
                        if (entry.key == 'terminal')
                          grants.remove('terminalAdmin');
                      }
                    }))
        ]),
      ]);

  Future<void> _copy() async {
    final value = _createdUrl,
        generation = _generation,
        credential = _org.broker.token();
    if (value == null || !_enabled) return;
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (_current(generation, credential))
        setState(() => _notice = 'Invitation link copied.');
    } catch (_) {
      if (_current(generation, credential))
        setState(() => _notice =
            'Clipboard unavailable. Select and copy the link manually.');
    }
  }

  Future<void> _openInvitation() async {
    final generation = _generation, credential = _org.broker.token();
    final url = verifiedLabnetInvitation(_link.text, _org.broker.baseUrl);
    if (url == null) {
      setState(() =>
          _notice = 'Paste an HTTPS invitation link from this LabDesk server.');
      return;
    }
    try {
      final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (_current(generation, credential))
        setState(() => _notice = opened
            ? 'Review and accept or refuse in your browser, then refresh here.'
            : 'The browser could not open. Copy the link into your browser.');
    } catch (_) {
      if (_current(generation, credential))
        setState(() => _notice =
            'The browser could not open. Copy the link into your browser.');
    }
  }

  Widget _heading(String title) => Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 12),
      child: Text(title, style: C.of(context).h2()));
  Widget _row(String title, String detail, List<Widget> actions) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: C.of(context).body()),
        Text(detail, style: C.of(context).small()),
        if (actions.isNotEmpty) Wrap(spacing: 8, children: actions),
      ]));
  Widget _choice(String label, String value, Map<String, String> choices,
          ValueChanged<String> onChanged,
          {bool enabled = true}) =>
      DropdownButtonFormField<String>(
          decoration: InputDecoration(labelText: label),
          value: choices.containsKey(value) ? value : null,
          isExpanded: true,
          items: [
            for (final entry in choices.entries)
              DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value, overflow: TextOverflow.ellipsis))
          ],
          onChanged: _enabled && enabled
              ? (value) {
                  if (value != null) onChanged(value);
                }
              : null);

  @override
  Widget build(BuildContext context) {
    if (!_ready)
      return Padding(
          padding: const EdgeInsets.all(12),
          child: Text(_org.error ?? 'Sign in to manage sharing and routing.',
              style: C.of(context).body()));
    final routingExits = _routing['exits'] is List
        ? _rows(_routing['exits'])
        : <Map<String, dynamic>>[];
    final exitChoices = <String, String>{
      '': 'Direct',
      for (final exit in routingExits)
        exit['id'] as String:
            '${_text(exit['machineName'], _text(exit['machineId']))} · '
                '${exit['reachable'] == true ? 'reachable' : exit['reachable'] == false ? 'unreachable' : 'reachability unknown'}'
    };
    if (_draftExit != null && !exitChoices.containsKey(_draftExit))
      exitChoices[_draftExit!] = 'Selected exit unavailable';
    final revision = _preference['revision'];
    final canSelect = widget.canManageMachines &&
        _capabilities['selection'] == true &&
        _fresh &&
        revision is int &&
        revision >= 0;
    final sourceSupported =
        _approvedSource && _fresh && _capabilities['exitLan'] == true;
    final emailValid = _email.text.trim().isEmpty
        ? _delivery == 'link'
        : RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim());
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _heading('Sharing and routing'),
      Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
                onPressed: _busy ? null : _refresh,
                child: const Text('Refresh sharing and routing')),
            if (_busy) const Text('Refreshing…'),
          ]),
      if (_error != null)
        Text(_error!, style: C.of(context).small(color: C.of(context).bad)),
      if (_notice != null) Text(_notice!, style: C.of(context).small()),
      _heading('Hosting requests for this machine'),
      if (!_localAvailable)
        const Text('Hosting decisions require verified local enrollment, a canonical local machine identity, '
            'and the privileged LabDesk service. Remote machines cannot approve here.')
      else ...[
        Text('Local daemon reports: ${_localRouting.status}. '
            'Offer state below comes from the server; configured routes do not prove endpoint reachability.'),
        if (_localRouting.error != null)
          Text(_localRouting.error!, style: C.of(context).small(color: C.of(context).bad)),
        if (_hostError != null)
          Text(_hostError!, style: C.of(context).small(color: C.of(context).bad)),
        if (!_localFresh || !_localRouting.hostingSupported || !_localRouting.exitLanSupported)
          const Text('Exit approval unavailable until this local daemon reports hosting and exit LAN policy support.'),
        if (!_localFresh || !_localRouting.subnetSharingSupported)
          const Text('Subnet approval unavailable until this local daemon reports subnet routing support.'),
        if (_hostError == null && _hostExits.isEmpty && _hostSubnets.isEmpty)
          const Text('No hosting offers for this machine.'),
        for (final offer in _hostExits) _hostOffer(offer, subnet: false),
        for (final offer in _hostSubnets) _hostOffer(offer, subnet: true),
      ],
      _heading('Shared with me'),
      const Text(
          'Access to selected Labnets only. This does not add you to their organization or fleet.'),
      if (_shared.isEmpty) const Text('No shared Labnets.'),
      for (final access in _shared)
        _row(
            _text(access['name']),
            _caps(access['capabilities']).isEmpty
                ? 'Network access only'
                : _caps(access['capabilities'])
                    .map((cap) => _permissions[cap])
                    .join(', '),
            [
              TextButton(
                  onPressed: !_enabled
                      ? null
                      : () => _confirm(
                          'Leave shared Labnet',
                          'Remove your shared access and invitation-derived machine attachments. Other independent memberships remain.',
                          (broker) =>
                              broker.leaveSharedLabnet(access['id'] as String)),
                  child: const Text('Leave shared Labnet')),
            ]),
      TextField(
          controller: _link,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: 'Invitation link')),
      Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
              onPressed: _enabled ? _openInvitation : null,
              child: const Text('Review invitation in browser'))),
      if (_owned.isNotEmpty) ...[
        _heading('People and invitations'),
        _choice(
            'Labnet to manage',
            _labnet,
            {for (final l in _owned) l.id: l.name},
            (value) => _select(labnet: value)),
        for (final person in _people)
          _row(
              _text(person['name']),
              _caps(person['capabilities']).isEmpty
                  ? 'Network access only'
                  : _caps(person['capabilities'])
                      .map((cap) => _permissions[cap])
                      .join(', '),
              [
                TextButton(
                    onPressed: _enabled ? () => _editAccess(person) : null,
                    child: const Text('Edit access')),
                TextButton(
                    onPressed: !_enabled
                        ? null
                        : () => _confirm(
                            'Remove person',
                            'Revoke this person’s shared access and invitation-derived machine attachments from this Labnet.',
                            (broker) => broker.revokeLabnetInvitation(
                                _labnet, person['invitationId'] as String),
                            revokedInvitationId:
                                person['invitationId'] as String),
                    child: const Text('Remove person')),
              ]),
        if (_people.isEmpty) const Text('No accepted people yet.'),
        for (final invite in _invitations)
          _row(
              _text(invite['email'], 'Anyone with this link'),
              '${_text(invite['kind'])} · ${invite['revokedAt'] != null ? 'revoked' : _text(invite['status'])} · '
              'Expires ${_text(invite['expiresAt'])}',
              [
                if (invite['revokedAt'] == null)
                  TextButton(
                      onPressed: !_enabled
                          ? null
                          : () => _confirm(
                              'Revoke invitation',
                              'Revoke this invitation and any access or machine attachments accepted through it.',
                              (broker) => broker.revokeLabnetInvitation(
                                  _labnet, invite['id'] as String),
                              revokedInvitationId: invite['id'] as String),
                      child: const Text('Revoke invitation')),
              ]),
        _heading('Create invitation'),
        _choice(
            'Invite',
            _kind,
            const {
              'person': 'Person',
              'machine': 'Machine',
              'both': 'Person and machine'
            },
            (value) => setState(() {
                  _kind = value;
                  if (value == 'machine') _grants.clear();
                })),
        _choice(
            'Delivery',
            _delivery,
            const {'link': 'Copy invitation link', 'email': 'Email'},
            (value) => setState(() => _delivery = value)),
        TextField(
            controller: _email,
            enabled: _enabled,
            keyboardType: TextInputType.emailAddress,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: _delivery == 'email'
                    ? 'Recipient email'
                    : 'Restrict to email (optional)')),
        if (_kind != 'machine')
          AbsorbPointer(
              absorbing: !_enabled,
              child: _permissionPicker(_grants, setState)),
        const Text(
            'Single use, expires in 48 hours. Unrestricted links go to the first eligible signed-in user. '
            'Machine invitations still require approval on that machine.'),
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
                key: const ValueKey('create-labnet-invitation'),
                onPressed: !_enabled || !emailValid || _selected == null
                    ? null
                    : () {
                        _run(
                            (broker) => broker.createLabnetInvitation(_labnet,
                                kind: _kind,
                                delivery: _delivery,
                                email: _email.text.trim().isEmpty
                                    ? null
                                    : _email.text.trim(),
                                capabilities: _grants.toList()),
                            notice: _delivery == 'email'
                                ? 'Invitation email sent.'
                                : 'Invitation created.');
                      },
                child: Text(_delivery == 'email'
                    ? 'Send invitation'
                    : 'Create invitation link'))),
        if (_createdUrl != null) ...[
          SelectableText(_createdUrl!),
          const Text(
              'Copy this secret link now. It cannot be recovered after leaving this view.'),
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  onPressed: _enabled ? _copy : null,
                  child: const Text('Copy invitation link'))),
        ],
      ],
      if (_org.ready && widget.machines.isNotEmpty) ...[
        _heading('Machine routing'),
        _choice(
            'Machine',
            _machine,
            {
              for (final m in widget.machines)
                m.id: m.name.isEmpty ? m.id : m.name
            },
            (value) => _select(machine: value)),
        _choice(
            'Internet connection',
            _draftExit ?? '',
            exitChoices,
            (value) => setState(() {
                  _draftExit = value.isEmpty ? null : value;
                  _dirty = true;
                }),
            enabled: canSelect),
        Text(routingAcknowledgement(_preference, DateTime.now())),
        if (_preference['error'] is String)
          Text(_preference['error'] as String,
              style: C.of(context).small(color: C.of(context).bad)),
        if (!canSelect)
          const Text(
              'Routing changes require current machine authority and a fresh report of selection support.'),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow this device’s local network'),
            subtitle: Text(_capabilities['clientLocalLan'] == true && _fresh
                ? 'Reach the selected client machine’s current LAN while using an exit node.'
                : 'Client-local LAN enforcement has not been confirmed by this machine.'),
            value: _allowLocalLan,
            onChanged:
                _enabled && canSelect && _capabilities['clientLocalLan'] == true
                    ? (value) => setState(() {
                          _allowLocalLan = value;
                          _dirty = true;
                        })
                    : null),
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
                key: const ValueKey('apply-machine-routing'),
                onPressed: !_enabled || !canSelect || !_dirty
                    ? null
                    : () => _run(
                        (broker) => broker.setMachineRouting(_machine,
                            exitId: _draftExit,
                            revision: revision as int,
                            allowLocalLan: _allowLocalLan),
                        notice: 'Routing requested; waiting for the machine.'),
                child: const Text('Apply internet connection'))),
        const Text(
            'Acknowledgement reports daemon selection. Public egress, DNS and IPv6 need a separate reachability check.'),
        if (_selected != null) ...[
          _heading('Exit nodes offered to this Labnet'),
          const Text(
              'The selected routing machine above is the source for new exit and subnet offers.'),
          if (_exits.isEmpty) const Text('No exit offers.'),
          for (final offer in _exits)
            _row(
                _text(offer['machineName'], _text(offer['machineId'])),
                '${_text(offer['status'])} · Exit LAN ${offer['allowExitLan'] == true ? 'allowed' : 'blocked by requested policy'}'
                '${offer['cleanupConfirmed'] == false && offer['status'] == 'revoked' ? ' · cleanup pending' : ''}'
                '${offer['error'] is String ? ' · ${offer['error']}' : ''}',
                [
                  if (offer['status'] != 'revoked' ||
                      offer['cleanupConfirmed'] != true)
                    TextButton(
                        onPressed: !_enabled
                            ? null
                            : () => _confirm(
                                'Revoke exit',
                                'Remove this exit offer from this Labnet. Clients may lose their selected internet route until they choose another.',
                                (broker) =>
                                    broker.revokeExit(offer['id'] as String)),
                        child: const Text('Revoke exit')),
                ]),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow exit users to reach this machine’s LAN'),
              subtitle: const Text(
                  'Separate from the client LAN control. Off requests an internet-only exit.'),
              value: _allowExitLan,
              onChanged: _enabled &&
                      sourceSupported &&
                      _offerCapabilities['exitLan'] == true
                  ? (value) => setState(() => _allowExitLan = value)
                  : null),
          if (!sourceSupported)
            const Text(
                'Offering an exit requires an approved Labnet member with fresh exit-hosting support.'),
          Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                  onPressed: !_enabled || !sourceSupported
                      ? null
                      : () => _run(
                          (broker) => broker.offerExit(_labnet, _machine,
                              allowExitLan: _allowExitLan),
                          notice:
                              'Exit offered. Awaiting approval and policy enforcement on that machine.'),
                  child: const Text('Offer selected machine as exit'))),
          _heading('Shared subnets'),
          for (final subnet in _subnets)
            _row(
                _text(subnet['name']),
                '${_text(subnet['cidr'])} · ${_text(subnet['status'])} · Provider configuration is not endpoint reachability.'
                '${subnet['status'] == 'revoked' && subnet['cleanupConfirmed'] != true ? ' Cleanup pending.' : ''}'
                '${subnet['error'] is String ? ' ${subnet['error']}' : ''}',
                [
                  if (subnet['status'] != 'revoked' ||
                      subnet['cleanupConfirmed'] != true)
                    TextButton(
                        onPressed: !_enabled
                            ? null
                            : () => _confirm(
                                'Remove subnet',
                                'Remove this subnet resource and its access policy from this Labnet.',
                                (broker) => broker
                                    .removeSubnet(subnet['id'] as String)),
                        child: Text(subnet['status'] == 'revoked'
                            ? 'Retry subnet cleanup'
                            : 'Remove subnet')),
                ]),
          if (_subnets.isEmpty) const Text('No shared subnets.'),
          TextField(
              controller: _subnetName,
              enabled: _enabled,
              onChanged: (_) => setState(() {}),
              maxLength: 64,
              decoration: const InputDecoration(labelText: 'Subnet name')),
          TextField(
              controller: _cidr,
              enabled: _enabled,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                  labelText: 'IPv4 or IPv6 CIDR', hintText: '192.168.10.0/24')),
          Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                  onPressed: !_enabled ||
                          !_approvedSource ||
                          _offerCapabilities['subnetSharing'] != true ||
                          _subnetName.text.trim().isEmpty ||
                          _cidr.text.trim().isEmpty
                      ? null
                      : () => _run(
                          (broker) => broker.shareSubnet(_labnet,
                              machineId: _machine,
                              name: _subnetName.text.trim(),
                              cidr: _cidr.text.trim()),
                          notice:
                              'Subnet offered. Awaiting approval on the router; reachability remains unverified.'),
                  child: const Text('Share subnet'))),
        ],
      ],
    ]);
  }
}
