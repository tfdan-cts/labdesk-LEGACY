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
    this.checkService,
    this.repairService,
    this.onEnrolled,
  });

  final MachineEnroller enrol;
  final OverlayBroker? broker;
  final bool signedIn;
  final String machineId;
  final Future<bool> Function()? signIn;
  final Future<void> Function()? checkService;
  final VoidCallback? repairService;
  final Future<void> Function()? onEnrolled;

  @override
  State<MachineEnrolCard> createState() => _MachineEnrolCardState();
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

  Future<T> _authenticated<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on OverlayBrokerException catch (e) {
      if ((e.signInAgain || e.needsFreshSignIn) &&
          mounted &&
          widget.signIn != null &&
          await widget.signIn!()) {
        return action();
      }
      rethrow;
    }
  }

  Future<void> _loadOrganization() async {
    final broker = widget.broker;
    if (broker == null || _busy || widget.machineId.isNotEmpty) return;
    final epoch = _accountEpoch;
    setState(() {
      _busy = true;
      _loadFailed = false;
      _outcome = null;
    });
    try {
      final role = await _authenticated(broker.organizationRole);
      final fleets =
          role == 'owner' ? await _authenticated(broker.fleets) : <OrgFleet>[];
      if (!mounted || epoch != _accountEpoch) return;
      setState(() {
        _role = role;
        _fleets = fleets;
        _fleetId = null;
        _creatingFleet = fleets.isEmpty;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadFailed = true;
          _outcome = EnrolOutcome(error: '$e');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() async {
    if (_busy || widget.signIn == null) return;
    setState(() => _busy = true);
    try {
      final signedIn = await widget.signIn!();
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

  Future<void> _enrol(String token) async {
    final answer = await widget.enrol(token);
    if (!mounted) return;
    final outcome = EnrolOutcome.decode(answer);
    setState(() => _outcome = outcome);
    if (outcome.machineId.isEmpty) return;
    _token.clear();
    // Enrollment is already committed. A failed follow-up must not offer to
    // enroll again or turn a spent token back into a retryable credential.
    try {
      await widget.onEnrolled?.call();
    } catch (e) {
      if (mounted) {
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
    final epoch = _accountEpoch;
    try {
      // This probes privileged IPC, not RustDesk's rendezvous start/stop flag.
      // Do it before creating a fleet or spending any enrollment token.
      if (widget.checkService != null) {
        _serviceProblem = true;
        await widget.checkService!();
        _serviceProblem = false;
      }
      if (!mounted || epoch != _accountEpoch) return;
      if (fromAccount) {
        final broker = widget.broker!;
        if (_creatingFleet) {
          final fleet = await _authenticated(
              () => broker.createFleet(_fleetName.text.trim()));
          if (!mounted || epoch != _accountEpoch) return;
          // Remember a committed fleet even if the following mint/enrol step
          // fails, so retry cannot create another fleet with the same name.
          setState(() {
            _fleets = [..._fleets, fleet];
            _fleetId = fleet.id;
            _creatingFleet = false;
          });
        }
        final minted = await _authenticated(
            () => broker.mintEnrolmentToken(fleetId: _fleetId));
        if (!mounted || epoch != _accountEpoch) return;
        await _enrol(minted);
      } else {
        await _enrol(token);
      }
    } catch (e) {
      if (mounted) setState(() => _outcome = EnrolOutcome(error: '$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
        isDense: true,
        filled: true,
        fillColor: C.bg,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(
            borderRadius: C.roundedSm,
            borderSide: const BorderSide(color: C.hairline)),
        border: OutlineInputBorder(borderRadius: C.roundedSm),
        focusedBorder: OutlineInputBorder(
            borderRadius: C.roundedSm,
            borderSide: const BorderSide(color: C.accent)),
        hintText: hint,
        hintStyle: C.body(color: C.textMuted),
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
            style: C.body(color: C.textMuted)),
      ];
    }
    return [
      Text(_creatingFleet ? 'New fleet' : 'Fleet', style: C.small()),
      const SizedBox(height: 6),
      if (_creatingFleet)
        TextField(
          key: const Key('enrol-fleet-name'),
          controller: _fleetName,
          enabled: !_busy,
          maxLength: 64,
          style: C.body(),
          decoration: _fieldDecoration('Fleet name').copyWith(counterText: ''),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(fromAccount: true),
        )
      else
        DropdownButtonFormField<String>(
          key: const Key('enrol-fleet'),
          value: _fleetId,
          isExpanded: true,
          dropdownColor: C.surface,
          style: C.body(),
          decoration: _fieldDecoration('Choose a fleet'),
          hint: Text('Choose a fleet', style: C.body(color: C.textMuted)),
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
            backgroundColor: C.primaryFill,
            foregroundColor: C.primaryFg,
            disabledBackgroundColor: C.surfaceHi,
            disabledForegroundColor: C.textFaint,
            textStyle: C.small(),
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
        color: C.surface,
        borderRadius: C.rounded,
        border: Border.all(color: C.hairline),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Organization', style: C.h2()),
          const SizedBox(height: 4),
          Text(
            accountFlow
                ? 'Add this machine to your fleet and enable Labnet for encrypted '
                    'connections. Your organization can monitor and manage this machine.'
                : 'Paste an enrolment token from your organization to put this '
                    'machine under it. A token is used once and expires after fifteen '
                    'minutes.',
            style: C.small(),
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
                      color: C.bg,
                      borderRadius: C.roundedSm,
                      border: Border.all(color: C.hairline),
                    ),
                    child: Center(
                      child: TextField(
                        key: const Key('enrol-token'),
                        controller: _token,
                        enabled: !_busy,
                        style: C.data(size: 12.5),
                        cursorColor: C.accent,
                        cursorWidth: 1.6,
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          border: InputBorder.none,
                          hintText: 'Enrolment token',
                          hintStyle: C.data(size: 12.5, color: C.textFaint),
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
                  style: C.body(color: C.textMuted),
                  children: [
                    const TextSpan(text: 'Enrolled as machine '),
                    TextSpan(
                      text: outcome.machineId,
                      style:
                          C.data(size: 14, color: C.text, w: FontWeight.w700),
                    ),
                    const TextSpan(text: '.'),
                  ],
                ),
              )
            else
              SelectableText(outcome.error, style: C.body(color: C.bad)),
          ],
          if (_followupError.isNotEmpty) ...[
            const SizedBox(height: 12),
            SelectableText(_followupError, style: C.body(color: C.bad)),
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
