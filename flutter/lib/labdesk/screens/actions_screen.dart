import 'package:flutter/material.dart';

import '../models/machine_row.dart';
import '../theme/console_theme.dart';
import '../theme/ld_icons.dart';

/// One thing the operator can do to a machine.
class MachineAction {
  const MachineAction({
    required this.id,
    required this.label,
    required this.description,
    required this.glyph,
    this.requiresSession = true,
    this.destructive = false,
  });

  final String id;
  final String label;
  final String description;

  /// A path from [LdIcons], not an [IconData]. The console draws its own
  /// glyphs; a row of Material icons down the left of this list was the
  /// loudest remaining tell that the product was derived from another one.
  final String glyph;

  /// Most actions run over an open connection. The screen disables rather than
  /// hides them when there is none, so the operator can see what exists.
  final bool requiresSession;

  /// Interrupts the machine. Confirmed before running, never one click.
  final bool destructive;
}

/// The actions LabDesk can genuinely perform today.
///
/// Deliberately short. Every entry maps to something the client already
/// implements; nothing here is aspirational, because a button that does
/// nothing is worse than an absent one.
const kMachineActions = <MachineAction>[
  MachineAction(
    id: 'connect',
    label: 'Connect',
    description: 'Open a remote desktop session.',
    glyph: LdIcons.display,
    requiresSession: false,
  ),
  MachineAction(
    id: 'terminal',
    label: 'Open terminal',
    description: 'Start a shell on the machine without opening its desktop.',
    glyph: LdIcons.terminal,
    requiresSession: false,
  ),
  MachineAction(
    id: 'transfer',
    label: 'Transfer files',
    description: 'Browse and move files between this machine and that one.',
    glyph: LdIcons.fileTransfer,
    requiresSession: false,
  ),
  MachineAction(
    id: 'screenshot',
    label: 'Capture screen',
    description: 'Save a still of the remote display.',
    glyph: LdIcons.screenshot,
  ),
  MachineAction(
    id: 'reboot',
    label: 'Restart machine',
    description: 'Reboot the remote machine. Any open session ends.',
    glyph: LdIcons.restart,
    destructive: true,
  ),
];

class ActionsScreen extends StatelessWidget {
  const ActionsScreen({
    super.key,
    required this.machine,
    required this.connected,
    this.onRun,
    this.busyActionId,
  });

  final MachineRow? machine;
  final bool connected;

  /// Called once the operator has confirmed anything destructive.
  final void Function(MachineAction action)? onRun;

  final String? busyActionId;

  @override
  Widget build(BuildContext context) {
    if (machine == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The set's own bolt, which is the mark the Actions tab carries.
            LdIcon(LdIcons.actions, size: 26, color: C.of(context).textFaint),
            const SizedBox(height: 14),
            Text('No machine selected', style: C.of(context).h2()),
            const SizedBox(height: 6),
            // Fixed height, matching the health and terminal screens: see the
            // note on HealthScreen's empty state.
            SizedBox(
              width: 320,
              height: 34,
              child: Text(
                'Choose a machine on the Fleet screen to act on it.',
                textAlign: TextAlign.center,
                style: C.of(context).small(color: C.of(context).textFaint),
              ),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Panel(
            title: 'Actions',
            subtitle: 'On ${machine!.displayName}',
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < kMachineActions.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: C.of(context).hairline),
                  _ActionRow(
                    action: kMachineActions[i],
                    enabled: !kMachineActions[i].requiresSession || connected,
                    busy: busyActionId == kMachineActions[i].id,
                    onRun: onRun,
                    machineName: machine!.displayName,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatefulWidget {
  const _ActionRow({
    required this.action,
    required this.enabled,
    required this.busy,
    required this.onRun,
    required this.machineName,
  });

  final MachineAction action;
  final bool enabled;
  final bool busy;
  final void Function(MachineAction action)? onRun;
  final String machineName;

  @override
  State<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends State<_ActionRow> {
  bool _hover = false;

  Future<void> _run() async {
    final a = widget.action;
    if (a.destructive) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => _ConfirmDialog(action: a, machineName: widget.machineName),
      );
      if (ok != true) return;
    }
    widget.onRun?.call(a);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.action;
    final enabled = widget.enabled && widget.onRun != null && !widget.busy;
    final fg = enabled ? C.of(context).text : C.of(context).textFaint;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? _run : null,
        child: AnimatedContainer(
          duration: C.fast,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          color: _hover && enabled ? C.of(context).surfaceHi : Colors.transparent,
          child: Row(
            children: [
              LdIcon(a.glyph, size: 17, color: a.destructive && enabled ? C.of(context).bad : fg),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.label, style: C.of(context).body(color: fg)),
                    const SizedBox(height: 2),
                    Text(
                      enabled || !a.requiresSession
                          ? a.description
                          : '${a.description} Needs an open session.',
                      style: C.of(context).small(color: C.of(context).textFaint),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              if (widget.busy)
                LdSpinner(size: 14, color: C.of(context).accent)
              else
                LdIcon(LdIcons.chevronRight,
                    size: 18, color: enabled ? C.of(context).textMuted : C.of(context).textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({required this.action, required this.machineName});

  final MachineAction action;
  final String machineName;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: C.of(context).surface,
      shape: RoundedRectangleBorder(
        borderRadius: C.rounded,
        side: BorderSide(color: C.of(context).hairline),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(action.label, style: C.of(context).h2()),
              const SizedBox(height: 8),
              Text(
                'This restarts $machineName. Any open session ends and the machine '
                'is unreachable until it comes back.',
                style: C.of(context).small(color: C.of(context).textMuted),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  GhostButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 10),
                  _DangerButton(
                    label: 'Restart',
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DangerButton extends StatefulWidget {
  const _DangerButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  State<_DangerButton> createState() => _DangerButtonState();
}

class _DangerButtonState extends State<_DangerButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: C.fast,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hover ? C.of(context).bad : C.of(context).bad.withOpacity(0.85),
            borderRadius: C.roundedSm,
          ),
          child: Text(widget.label,
              style: C.of(context).small(color: const Color(0xFF1A0B0B), w: FontWeight.w700)),
        ),
      ),
    );
  }
}
