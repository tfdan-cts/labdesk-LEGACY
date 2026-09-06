import 'package:flutter/material.dart';

import '../services/overlay_enrolment.dart';
import '../theme/console_theme.dart';

/// An unavailable labnet path never silently changes connection providers.
class LabnetConnectionFailure extends StatelessWidget {
  const LabnetConnectionFailure({super.key, required this.detail});

  final String detail;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Labnet connection unavailable', style: C.h2()),
        content: SizedBox(
          width: 480,
          child: Text(
              '$detail\n\nYou can cancel and repair labnet, or explicitly '
              'try the configured RustDesk ID and relay servers.',
              style: C.body()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: C.small()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child:
                Text('Use RustDesk instead', style: C.small(color: C.accent)),
          ),
        ],
      );
}

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
          'Labnet uses NetBird to connect your enrolled machines. Add this '
              'machine to your organization above, then turn labnet on.',
        ),
      LabnetPhase.working => (
          C.accent,
          state.detail,
          'Setting up the encrypted NetBird connection.',
        ),
      LabnetPhase.on => (
          C.ok,
          'On at ${state.ip}',
          'NetBird is connected. Authorized machines use an encrypted tunnel, '
              'directly when possible or through a relay when needed.',
        ),
      LabnetPhase.error => (
          C.bad,
          'Labnet needs attention',
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
          Text('Labnet', style: C.h2()),
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
              if (state.phase == LabnetPhase.error && onDisable != null) ...[
                const SizedBox(width: 20),
                _TextAction(label: 'Turn off', onTap: onDisable!),
              ],
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
