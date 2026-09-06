import 'package:flutter/material.dart';

import '../services/overlay_enrolment.dart';
import '../theme/console_theme.dart';

/// The labnet card on This machine: whether this machine takes encrypted
/// direct connections from the account's other machines, and the one switch.
///
/// Presentational. The sequence behind the switch lives in
/// `OverlayEnrolment`; this renders its state and hands back intents.
class LabnetCard extends StatelessWidget {
  const LabnetCard({
    super.key,
    required this.state,
    this.onEnable,
    this.onDisable,
  });

  final LabnetCardState state;
  final VoidCallback? onEnable;
  final VoidCallback? onDisable;

  @override
  Widget build(BuildContext context) {
    final (dot, label, subtitle) = switch (state.phase) {
      LabnetPhase.off => (
          C.idle,
          'Off',
          'Other machines reach this one through the ID server. Turn this on '
              'and machines on your account can open a direct encrypted path '
              'to it instead.',
        ),
      LabnetPhase.working => (
          C.accent,
          state.detail,
          'Setting up the encrypted direct path.',
        ),
      LabnetPhase.on => (
          C.ok,
          'On at ${state.ip}',
          'Machines on your account can open a direct encrypted path to this '
              'one. Nothing else can reach it there.',
        ),
      LabnetPhase.error => (
          C.bad,
          'Could not turn on',
          state.detail,
        ),
    };
    final action = switch (state.phase) {
      LabnetPhase.off => ('Turn on', onEnable),
      LabnetPhase.working => (null, null),
      LabnetPhase.on => ('Turn off', onDisable),
      LabnetPhase.error => ('Try again', onEnable),
    };
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
          Text('Encrypted direct connections', style: C.h2()),
          const SizedBox(height: 4),
          Text(subtitle, style: C.small()),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(label, style: C.body())),
              if (action.$1 != null && action.$2 != null)
                _TextAction(label: action.$1!, onTap: action.$2!),
            ],
          ),
        ],
      ),
    );
  }
}

class _TextAction extends StatefulWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_TextAction> createState() => _TextActionState();
}

class _TextActionState extends State<_TextAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.label,
          style: C.small(color: _hover ? C.accent : C.textMuted).copyWith(
            decoration: TextDecoration.underline,
            decorationColor: _hover ? C.accent : C.textFaint,
          ),
        ),
      ),
    );
  }
}
