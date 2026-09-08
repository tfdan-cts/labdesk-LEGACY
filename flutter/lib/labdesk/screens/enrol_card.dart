import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/overlay_broker.dart';
import '../theme/console_theme.dart';

/// Enrols this machine with an organization: `main_agent_enrol` in
/// `src/flutter_ffi.rs`, which hands the token to the privileged LabDesk
/// process over IPC. Answers `{"machineId":...}` or `{"error":...}`.
/// Injected so the card renders in the design harness and in tests with no
/// FFI at all.
typedef MachineEnroller = Future<String> Function(String token);

/// What an enrolment ended in: the machine id lab-desk.net minted, or the
/// failure text in the server's or the daemon's own words. Exactly one is set.
class EnrolOutcome {
  const EnrolOutcome({this.machineId = '', this.error = ''});

  final String machineId;
  final String error;

  /// Reads what `main_agent_enrol` answers. Anything that is not one of its two
  /// shapes is shown as it came, so a broken answer is never mistaken for
  /// success.
  static EnrolOutcome decode(String json) {
    try {
      final j = jsonDecode(json);
      if (j is! Map) return EnrolOutcome(error: json);
      final id = j['machineId'];
      if (id is String && id.isNotEmpty) return EnrolOutcome(machineId: id);
      final error = j['error'];
      if (error is String && error.isNotEmpty) {
        return EnrolOutcome(error: error);
      }
    } catch (_) {}
    return EnrolOutcome(error: json.isEmpty ? 'No answer.' : json);
  }
}

/// Enrols through the privileged process, using the signed-in owner's fleet
/// or a token supplied by an owner. Account sign-in alone never enrols a host.
///
/// Enrolment is the machine's consent to be owned, so it is asked for here,
/// at the machine, and nowhere else (architecture section 3.2).
class MachineEnrolCard extends StatefulWidget {
  const MachineEnrolCard({
    super.key,
    required this.enrol,
    this.broker,
    this.signedIn = false,
    this.machineId = '',
    this.signIn,
    this.refreshBroker,
    this.checkService,
    this.repairService,
    this.onEnrolled,
  });

  final MachineEnroller enrol;
  final OverlayBroker? broker;
  final bool signedIn;
  final String machineId;
  final Future<bool> Function()? signIn;

  /// Returns refreshed credentials only after verifying the initiating user
  /// and organization. A cancelled or changed context returns null.
  final Future<OverlayBroker?> Function()? refreshBroker;
  final Future<void> Function()? checkService;
  final VoidCallback? repairService;
  final Future<void> Function()? onEnrolled;

  @override
  State<MachineEnrolCard> createState() => _MachineEnrolCardState();
}

class _EnrolRequest {
  _EnrolRequest(this.broker, this.epoch);
  OverlayBroker? broker;
  final int epoch;
}

class _MachineEnrolCardState extends State<MachineEnrolCard> {
  final _token = TextEditingController();
  final _fleetName = TextEditingController();
  var _busy = false;
  var _showToken = false;
  var _creatingFleet = false;
  var _loadFailed = false;
  var _serviceProblem = false;
  var _accountEpoch = 0;
  String? _role;
  String? _fleetId;
  List<OrgFleet> _fleets = [];
  EnrolOutcome? _outcome;
  String _followupError = '';

  @override
  void initState() {
    super.initState();
    if (widget.signedIn && widget.broker != null && widget.machineId.isEmpty) {
      _loadOrganization();
    }
  }

  @override
  void didUpdateWidget(covariant MachineEnrolCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.signedIn && !widget.signedIn) {
      _accountEpoch++;
      _role = null;
      _fleets = [];
      _fleetId = null;
    } else if (!oldWidget.signedIn && widget.signedIn && !_busy) {
      _loadOrganization();
    }
  }

  @override
  void dispose() {
    _token.dispose();
    _fleetName.dispose();
    super.dispose();
  }

  bool _current(_EnrolRequest request) =>
      mounted &&
      request.epoch == _accountEpoch &&
      request.broker?.token() == widget.broker?.token() &&
      request.broker?.organizationId?.call() ==
          widget.broker?.organizationId?.call();

  Future<T> _authenticated<T>(
      _EnrolRequest request, Future<T> Function(OverlayBroker) action) async {
    if (!_current(request)) {
      throw StateError('Organization changed. Try again.');
    }
    try {
      return await action(request.broker!);
    } on OverlayBrokerException catch (e) {
      if ((e.signInAgain || e.needsFreshSignIn) &&
          _current(request) &&
          widget.refreshBroker != null) {
        final broker = await widget.refreshBroker!();
        if (broker != null) {
          final refreshed = broker.captureScope();
          if (refreshed.organizationId?.call() !=
              request.broker!.organizationId?.call()) rethrow;
          request.broker = refreshed;
          if (_current(request)) return action(refreshed);
        }
      }
      rethrow;
    }
  }

  Future<void> _loadOrganization() async {
    final broker = widget.broker?.captureScope();
    if (broker == null || _busy || widget.machineId.isNotEmpty) return;
    final request = _EnrolRequest(broker, _accountEpoch);
    setState(() {
      _busy = true;
      _loadFailed = false;
      _outcome = null;
    });
    try {
      final role = await _authenticated(request, (b) => b.organizationRole());
      final fleets = role == 'owner'
          ? await _authenticated(request, (b) => b.fleets())
          : <OrgFleet>[];
      if (!_current(request)) return;
      setState(() {
        _role = role;
        _fleets = fleets;
        _fleetId = null;
        _creatingFleet = fleets.isEmpty;
      });
    } catch (e) {
      if (_current(request)) {
        setState(() {
          _loadFailed = true;
          _outcome = EnrolOutcome(error: '$e');
        });
      }
    } finally {
      if (_current(request)) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() async {
    if (_busy || widget.signIn == null) return;
    setState(() => _busy = true);
    try {
      final signedIn = await widget.signIn!();
      // The parent replaces the keyed card after account verification. Wait
      // for that frame before reading through this card's captured broker.
      if (signedIn) await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      setState(() => _busy = false);
      if (signedIn) await _loadOrganization();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _outcome = EnrolOutcome(error: '$e');
        });
      }
    }
  }

  Future<void> _enrol(String token, _EnrolRequest request) async {
    if (!_current(request)) return;
    final answer = await widget.enrol(token);
    if (!_current(request)) return;
    final outcome = EnrolOutcome.decode(answer);
    setState(() => _outcome = outcome);
    if (outcome.machineId.isEmpty) return;
    _token.clear();
    // Enrollment is already committed. A failed follow-up must not offer to
    // enroll again or turn a spent token back into a retryable credential.
    try {
      await widget.onEnrolled?.call();
    } catch (e) {
      if (_current(request)) {
        setState(() =>
            _followupError = 'Machine added. Labnet setup needs attention: $e');
      }
    }
  }

  Future<void> _submit({bool fromAccount = false}) async {
    final token = _token.text.trim();
    if (_busy ||
        widget.machineId.isNotEmpty ||
        (!fromAccount && token.isEmpty)) {
      return;
    }
    if (fromAccount && (_role != 'owner' || widget.broker == null)) return;
    if (fromAccount &&
        (_creatingFleet ? _fleetName.text.trim().isEmpty : _fleetId == null)) {
      return;
    }
    setState(() {
      _busy = true;
      _outcome = null;
      _followupError = '';
      _serviceProblem = false;
    });
    final request = _EnrolRequest(widget.broker?.captureScope(), _accountEpoch);
    final fleetName = _fleetName.text.trim();
    try {
      // This probes privileged IPC, not LabDesk's rendezvous start/stop flag.
      // Do it before creating a fleet or spending any enrollment token.
      if (widget.checkService != null) {
        _serviceProblem = true;
        await widget.checkService!();
        _serviceProblem = false;
      }
      if (!_current(request)) return;
      if (fromAccount) {
        if (_creatingFleet) {
          final fleet =
              await _authenticated(request, (b) => b.createFleet(fleetName));
          if (!_current(request)) return;
          // Remember a committed fleet even if the following mint/enrol step
          // fails, so retry cannot create another fleet with the same name.
          setState(() {
            _fleets = [..._fleets, fleet];
            _fleetId = fleet.id;
            _creatingFleet = false;
          });
        }
        final minted = await _authenticated(
            request, (b) => b.mintEnrolmentToken(fleetId: _fleetId));
        if (!_current(request)) return;
        await _enrol(minted, request);
      } else {
        await _enrol(token, request);
      }
    } catch (e) {
      if (_current(request)) {
        setState(() => _outcome = EnrolOutcome(error: '$e'));
      }
    } finally {
      if (_current(request)) setState(() => _busy = false);
    }
  }

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
        isDense: true,
        filled: true,
        fillColor: C.of(context).bg,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(
            borderRadius: C.roundedSm,
            borderSide: BorderSide(color: C.of(context).hairline)),
        border: OutlineInputBorder(borderRadius: C.roundedSm),
        focusedBorder: OutlineInputBorder(
            borderRadius: C.roundedSm,
            borderSide: BorderSide(color: C.of(context).accent)),
        hintText: hint,
        hintStyle: C.of(context).body(color: C.of(context).textMuted),
      );

  List<Widget> _accountFields() {
    if (_role == null) {
      return [
        GhostButton(
          label: _loadFailed
              ? 'Retry organization'
              : 'Sign in to add this machine',
          busy: _busy,
          onPressed: _busy
              ? null
              : _loadFailed
                  ? _loadOrganization
                  : widget.signIn == null
                      ? null
                      : _signIn,
        ),
      ];
    }
    if (_role != 'owner') {
      return [
        Text(
            'Ask an organization owner for an enrolment token to add this machine.',
            style: C.of(context).body(color: C.of(context).textMuted)),
      ];
    }
    return [
      Text(_creatingFleet ? 'New fleet' : 'Fleet',
          style: C.of(context).small()),
      const SizedBox(height: 6),
      if (_creatingFleet)
        TextField(
          key: const Key('enrol-fleet-name'),
          controller: _fleetName,
          enabled: !_busy,
          maxLength: 64,
          style: C.of(context).body(),
          decoration: _fieldDecoration('Fleet name').copyWith(counterText: ''),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(fromAccount: true),
        )
      else
        DropdownButtonFormField<String>(
          key: const Key('enrol-fleet'),
          value: _fleetId,
          isExpanded: true,
          dropdownColor: C.of(context).surface,
          style: C.of(context).body(),
          decoration: _fieldDecoration('Choose a fleet'),
          hint: Text('Choose a fleet',
              style: C.of(context).body(color: C.of(context).textMuted)),
          items: [
            for (final f in _fleets)
              DropdownMenuItem(
                  value: f.id,
                  child: Text(f.name, overflow: TextOverflow.ellipsis))
          ],
          onChanged: _busy ? null : (value) => setState(() => _fleetId = value),
        ),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 8, children: [
        FilledButton(
          key: const Key('enrol-submit'),
          style: FilledButton.styleFrom(
            backgroundColor: C.of(context).primaryFill,
            foregroundColor: C.of(context).primaryFg,
            disabledBackgroundColor: C.of(context).surfaceHi,
            disabledForegroundColor: C.of(context).textFaint,
            textStyle: C.of(context).small(),
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: C.roundedSm),
          ),
          onPressed: _busy ||
                  (_creatingFleet
                      ? _fleetName.text.trim().isEmpty
                      : _fleetId == null)
              ? null
              : () => _submit(fromAccount: true),
          child: Text(
              _busy
                  ? 'Adding this machine...'
                  : _creatingFleet
                      ? 'Create fleet and add this machine'
                      : 'Add this machine',
              textAlign: TextAlign.center),
        ),
        if (!_creatingFleet || _fleets.isNotEmpty)
          GhostButton(
            label: _creatingFleet ? 'Choose existing fleet' : 'New fleet',
            onPressed: _busy
                ? null
                : () => setState(() => _creatingFleet = !_creatingFleet),
          ),
      ]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome ??
        (widget.machineId.isEmpty
            ? null
            : EnrolOutcome(machineId: widget.machineId));
    final accountFlow = widget.broker != null;
    final added = outcome?.machineId.isNotEmpty == true;
    return Container(
      decoration: BoxDecoration(
        color: C.of(context).surface,
        borderRadius: C.rounded,
        border: Border.all(color: C.of(context).hairline),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Organization', style: C.of(context).h2()),
          const SizedBox(height: 4),
          Text(
            accountFlow
                ? 'Add this machine to your fleet and enable Labnet for encrypted '
                    'connections. Your organization can monitor and manage this machine.'
                : 'Paste an enrolment token from your organization to put this '
                    'machine under it. A token is used once and expires after fifteen '
                    'minutes.',
            style: C.of(context).small(),
          ),
          const SizedBox(height: 16),
          if (accountFlow && !added) ...[
            ..._accountFields(),
            const SizedBox(height: 12),
            GhostButton(
              label: _showToken
                  ? 'Hide enrolment token'
                  : 'Use an enrolment token',
              onPressed:
                  _busy ? null : () => setState(() => _showToken = !_showToken),
            ),
            if (_showToken) const SizedBox(height: 10),
          ],
          if (!accountFlow || (_showToken && !added))
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: C.of(context).bg,
                      borderRadius: C.roundedSm,
                      border: Border.all(color: C.of(context).hairline),
                    ),
                    child: Center(
                      child: TextField(
                        key: const Key('enrol-token'),
                        controller: _token,
                        enabled: !_busy,
                        style: C.of(context).data(size: 12.5),
                        cursorColor: C.of(context).accent,
                        cursorWidth: 1.6,
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          border: InputBorder.none,
                          hintText: 'Enrolment token',
                          hintStyle: C
                              .of(context)
                              .data(size: 12.5, color: C.of(context).textFaint),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GhostButton(
                  label: 'Enrol',
                  busy: _busy,
                  onPressed: _busy ? null : () => _submit(),
                ),
              ],
            ),
          if (outcome != null) ...[
            const SizedBox(height: 12),
            if (outcome.machineId.isNotEmpty)
              SelectableText.rich(
                TextSpan(
                  style: C.of(context).body(color: C.of(context).textMuted),
                  children: [
                    const TextSpan(text: 'Enrolled as machine '),
                    TextSpan(
                      text: outcome.machineId,
                      style: C.of(context).data(
                          size: 14,
                          color: C.of(context).text,
                          w: FontWeight.w700),
                    ),
                    const TextSpan(text: '.'),
                  ],
                ),
              )
            else
              SelectableText(outcome.error,
                  style: C.of(context).body(color: C.of(context).bad)),
          ],
          if (_followupError.isNotEmpty) ...[
            const SizedBox(height: 12),
            SelectableText(_followupError,
                style: C.of(context).body(color: C.of(context).bad)),
          ],
          if (_serviceProblem && widget.repairService != null) ...[
            const SizedBox(height: 12),
            GhostButton(
              label: 'Install or repair LabDesk service',
              onPressed: _busy ? null : widget.repairService,
            ),
          ],
        ],
      ),
    );
  }
}
