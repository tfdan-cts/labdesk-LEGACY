import 'dart:convert';

import 'package:flutter/material.dart';

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
      if (error is String && error.isNotEmpty) return EnrolOutcome(error: error);
    } catch (_) {}
    return EnrolOutcome(error: json.isEmpty ? 'No answer.' : json);
  }
}

/// The organization card on This machine: paste an enrolment token an owner
/// minted, enrol through the privileged process, and read the machine id
/// back, or the refusal verbatim.
///
/// Enrolment is the machine's consent to be owned, so it is asked for here,
/// at the machine, and nowhere else (architecture section 3.2).
class MachineEnrolCard extends StatefulWidget {
  const MachineEnrolCard({super.key, required this.enrol});

  final MachineEnroller enrol;

  @override
  State<MachineEnrolCard> createState() => _MachineEnrolCardState();
}

class _MachineEnrolCardState extends State<MachineEnrolCard> {
  final _token = TextEditingController();
  var _busy = false;
  EnrolOutcome? _outcome;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final token = _token.text.trim();
    if (token.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _outcome = null;
    });
    final String answer;
    try {
      answer = await widget.enrol(token);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _outcome = EnrolOutcome(error: '$e');
        });
      }
      return;
    }
    if (!mounted) return;
    final outcome = EnrolOutcome.decode(answer);
    // The token is single use, so it is cleared once it has been spent.
    if (outcome.machineId.isNotEmpty) _token.clear();
    setState(() {
      _busy = false;
      _outcome = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
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
            'Paste an enrolment token from your organization to put this '
            'machine under it. A token is used once and expires after fifteen '
            'minutes.',
            style: C.small(),
          ),
          const SizedBox(height: 16),
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
                onPressed: _busy ? null : _submit,
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
                      style: C.data(
                          size: 14, color: C.text, w: FontWeight.w700),
                    ),
                    const TextSpan(text: '.'),
                  ],
                ),
              )
            else
              SelectableText(outcome.error, style: C.body(color: C.bad)),
          ],
        ],
      ),
    );
  }
}
