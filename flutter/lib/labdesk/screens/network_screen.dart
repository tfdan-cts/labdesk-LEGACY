import 'package:flutter/material.dart';

import '../models/labnet.dart';
import '../theme/console_theme.dart';

/// A machine the operator can add to a labnet: its id and how it is known.
class NetworkMachine {
  const NetworkMachine({required this.id, required this.name});
  final String id;
  final String name;
}

/// A fleet, for the one case where creating a labnet has to name one: a
/// technician narrowed to several fleets. The Worker refuses the create
/// otherwise (`src/worker/routes/overlay.ts`).
class NetworkFleet {
  const NetworkFleet({required this.id, required this.name});
  final String id;
  final String name;
}

/// The Network section: labnets, the invitations waiting on this machine, and
/// who is in each labnet.
///
/// Presentational, like every console screen. It takes the inbox lab-desk.net
/// gave this machine and hands back intents; the broker calls live in the
/// client. Wording: labnet, Approve, Decline, Leave, Remove. Never the
/// daemon's own names.
class NetworkScreen extends StatelessWidget {
  const NetworkScreen({
    super.key,
    required this.inbox,
    required this.thisMachineId,
    this.machines = const [],
    this.fleets = const [],
    this.mustNameFleet = false,
    this.busy = false,
    this.error = '',
    this.onCreate,
    this.onRename,
    this.onApprove,
    this.onDecline,
    this.onInvite,
    this.onFullAccess,
    this.onLeave,
    this.onRemove,
    this.onDelete,
  });

  final LabnetInbox inbox;
  final String thisMachineId;

  /// The machines this account can add, from the address book.
  final List<NetworkMachine> machines;

  /// The fleets this caller may name. Offered on the create form only when
  /// [mustNameFleet] says the server would refuse a create without one.
  final List<NetworkFleet> fleets;
  final bool mustNameFleet;

  final bool busy;
  final String error;
  final void Function(String name, String? fleetId)? onCreate;
  final void Function(String labnetId, String name)? onRename;
  final void Function(String labnetId)? onApprove;
  final void Function(String labnetId)? onDecline;
  final void Function(String labnetId, String deviceId)? onInvite;
  final void Function(String labnetId, bool on)? onFullAccess;
  final void Function(String labnetId)? onLeave;
  final void Function(String labnetId, String deviceId)? onRemove;
  final void Function(String labnetId)? onDelete;

  String _nameOf(String deviceId) {
    for (final m in machines) {
      if (m.id == deviceId) return m.name.isEmpty ? m.id : m.name;
    }
    return deviceId == thisMachineId ? 'This machine' : deviceId;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!inbox.enrolled) ...[
            _Card(
              title: 'Not on labnet',
              subtitle: 'Add this machine to your organization under This '
                  'device, then turn on Labnet.',
              child: const SizedBox.shrink(),
            ),
            const SizedBox(height: 16),
          ],
          if (error.isNotEmpty) ...[
            Text(error, style: C.of(context).small(color: C.of(context).bad)),
            const SizedBox(height: 12),
          ],
          for (final i in inbox.invitations) ...[
            _Card(
              title: '${i.invitedBy} wants to add this machine to ${i.name}',
              subtitle: 'Machines in a labnet can reach each other securely. '
                  'Nothing joins until you say so here.',
              child: Row(
                children: [
                  _TextAction(
                      label: 'Approve',
                      onTap: onApprove == null || busy
                          ? null
                          : () => onApprove!(i.labnetId)),
                  const SizedBox(width: 20),
                  _TextAction(
                      label: 'Decline',
                      onTap: onDecline == null || busy
                          ? null
                          : () => onDecline!(i.labnetId)),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          Row(
            children: [
              const Spacer(),
              if (inbox.enrolled && onCreate != null)
                _TextAction(
                    label: 'New labnet',
                    onTap: busy ? null : () => _askName(context)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            inbox.labnets.isEmpty
                ? 'A labnet is a standing group of machines that reach each '
                    'other through NetBird. Machines join only after approving on '
                    'their own screen.'
                : 'Machines in a labnet reach each other through NetBird, on '
                    'LabDesk\'s port and ping unless full access is on.',
            style: C.of(context).small(),
          ),
          const SizedBox(height: 16),
          for (final l in inbox.labnets) ...[
            _LabnetCard(
              labnet: l,
              thisMachineId: thisMachineId,
              nameOf: _nameOf,
              busy: busy,
              candidates: [
                for (final m in machines)
                  if (!l.members.any((x) => x.deviceId == m.id)) m,
              ],
              onRename: onRename == null
                  ? null
                  : (id) => _askName(context, renaming: id, initial: l.name),
              onInvite: onInvite,
              onFullAccess: onFullAccess,
              onLeave: onLeave,
              onRemove: onRemove,
              onDelete: onDelete,
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  /// The one dialog, for creating and for renaming.
  ///
  /// A caller narrowed to several fleets has to say which fleet a new labnet
  /// belongs to, because the Worker refuses the create without one and there
  /// was previously no way to answer it. Anyone who sees the whole organization
  /// is not asked.
  Future<void> _askName(BuildContext context,
      {String? renaming, String initial = ''}) async {
    final asking = renaming == null && mustNameFleet && fleets.isNotEmpty;
    final answer = await showDialog<(String, String?)>(
      context: context,
      builder: (ctx) => _NameDialog(
        title: renaming == null ? 'New labnet' : 'Rename labnet',
        confirm: renaming == null ? 'Create' : 'Rename',
        initial: initial,
        fleets: asking ? fleets : const [],
      ),
    );
    final name = answer?.$1.trim() ?? '';
    if (name.isEmpty) return;
    if (renaming == null) {
      onCreate?.call(name, answer?.$2);
    } else {
      onRename?.call(renaming, name);
    }
  }
}

/// The name prompt, owning its own controller.
///
/// Stateful because the controller has to outlive the dialog's route exactly:
/// a controller disposed the moment `showDialog` returns is still attached to
/// the field the route is animating away, and Flutter asserts on it.
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.confirm,
    required this.initial,
    required this.fleets,
  });

  final String title;
  final String confirm;
  final String initial;

  /// Empty when the caller need not name a fleet, which is every case but a
  /// technician narrowed to more than one.
  final List<NetworkFleet> fleets;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initial);
  late String? _fleetId = widget.fleets.isEmpty ? null : widget.fleets.first.id;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop((_name.text, _fleetId));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: C.of(context).surface,
      title: Text(widget.title, style: C.of(context).h2()),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              style: C.of(context).body(),
              decoration: const InputDecoration(hintText: 'Name'),
              onSubmitted: (_) => _submit(),
            ),
            if (widget.fleets.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Fleet', style: C.of(context).micro()),
              const SizedBox(height: 6),
              for (final f in widget.fleets)
                GestureDetector(
                  onTap: () => setState(() => _fleetId = f.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _fleetId == f.id ? C.of(context).accent : C.of(context).hairline,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(f.name, style: C.of(context).body()),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        _TextAction(label: 'Cancel', onTap: () => Navigator.of(context).pop()),
        const SizedBox(width: 16),
        _TextAction(label: widget.confirm, onTap: _submit),
      ],
    );
  }
}

class _LabnetCard extends StatelessWidget {
  const _LabnetCard({
    required this.labnet,
    required this.thisMachineId,
    required this.nameOf,
    required this.busy,
    required this.candidates,
    this.onRename,
    this.onInvite,
    this.onFullAccess,
    this.onLeave,
    this.onRemove,
    this.onDelete,
  });

  final Labnet labnet;
  final String thisMachineId;
  final String Function(String) nameOf;
  final bool busy;
  final List<NetworkMachine> candidates;
  final void Function(String labnetId)? onRename;
  final void Function(String labnetId, String deviceId)? onInvite;
  final void Function(String labnetId, bool on)? onFullAccess;
  final void Function(String labnetId)? onLeave;
  final void Function(String labnetId, String deviceId)? onRemove;
  final void Function(String labnetId)? onDelete;

  @override
  Widget build(BuildContext context) {
    final me = labnet.members.where((m) => m.deviceId == thisMachineId);
    // Until this machine is known, no row can be told apart from it, so
    // neither Leave nor Remove is offered: Remove on the wrong row would
    // remove this machine from its own labnet.
    final iAmMember =
        thisMachineId.isNotEmpty && me.isNotEmpty &&
        (me.first.approved || me.first.removalPending);
    final syncPending = labnet.syncPending ||
        labnet.members.any((m) => m.removalPending);
    final approved = labnet.members.where((m) => m.approved).length;
    return _Card(
      title: labnet.name,
      subtitle: syncPending
          ? '${labnet.members.length} machines listed. Network update pending.'
          : '$approved of ${labnet.members.length} machines joined. '
              '${labnet.fullAccess ? 'Full network access between members.' : 'LabDesk\'s port and ping between members.'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (syncPending)
            Text(
              'Network update pending. Access changes are not yet confirmed.',
              style: C.of(context).small(),
            ),
          for (final m in labnet.members)
            Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: C.of(context).hairline)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: m.approved
                          ? (m.overlayIp == null ? C.of(context).idle : C.of(context).ok)
                          : C.of(context).accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(nameOf(m.deviceId), style: C.of(context).body())),
                  Text(
                    m.removalPending
                        ? 'Removal pending'
                        : m.approved
                        ? (m.overlayIp ?? 'Not up')
                        : 'Waiting for approval on that machine',
                    style: C.of(context).small(),
                  ),
                  if (labnet.owner &&
                      onRemove != null &&
                      thisMachineId.isNotEmpty &&
                      m.deviceId != thisMachineId) ...[
                    const SizedBox(width: 16),
                    _TextAction(
                        label: m.removalPending ? 'Retry removal' : 'Remove',
                        onTap: busy
                            ? null
                            : () => onRemove!(labnet.id, m.deviceId)),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 20,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (labnet.owner && onInvite != null && candidates.isNotEmpty)
                _MachinePicker(
                  candidates: candidates,
                  onPick: busy || syncPending
                      ? null : (id) => onInvite!(labnet.id, id),
                ),
              if (labnet.owner && onRename != null)
                _TextAction(
                    label: 'Rename',
                    onTap: busy ? null : () => onRename!(labnet.id)),
              if (labnet.owner && onFullAccess != null)
                _TextAction(
                    label: labnet.fullAccess
                        ? 'Full access: on'
                        : 'Full access: off',
                    onTap: busy || (syncPending && !labnet.fullAccess)
                        ? null
                        : () => onFullAccess!(labnet.id, !labnet.fullAccess)),
              if (iAmMember && onLeave != null)
                _TextAction(
                    label: me.first.removalPending ? 'Retry leave' : 'Leave',
                    onTap: busy ? null : () => onLeave!(labnet.id)),
              if (labnet.owner && onDelete != null)
                _TextAction(
                    label: 'Delete labnet',
                    onTap: busy ? null : () => onDelete!(labnet.id)),
            ],
          ),
        ],
      ),
    );
  }
}

class _MachinePicker extends StatelessWidget {
  const _MachinePicker({required this.candidates, this.onPick});
  final List<NetworkMachine> candidates;
  final void Function(String id)? onPick;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Add a machine',
      color: C.of(context).surfaceHi,
      enabled: onPick != null,
      onSelected: onPick,
      itemBuilder: (_) => [
        for (final m in candidates)
          PopupMenuItem(
              value: m.id,
              child: Text(m.name.isEmpty ? m.id : m.name, style: C.of(context).body())),
      ],
      child: Text(
        'Add machine',
        style: C.of(context).small(color: C.of(context).textMuted).copyWith(
            decoration: TextDecoration.underline, decorationColor: C.of(context).textFaint),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, this.subtitle, required this.child});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
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
          Text(title, style: C.of(context).h2()),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: C.of(context).small()),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _TextAction extends StatefulWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<_TextAction> createState() => _TextActionState();
}

class _TextActionState extends State<_TextAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.label,
          style: C
              .small(
                  color: !enabled
                      ? C.of(context).textFaint
                      : _hover
                          ? C.of(context).accent
                          : C.of(context).textMuted)
              .copyWith(
                decoration: TextDecoration.underline,
                decorationColor: _hover && enabled ? C.of(context).accent : C.of(context).textFaint,
              ),
        ),
      ),
    );
  }
}
