import 'package:flutter/material.dart';

import '../../common/labdesk_peer_status.dart';
import '../../labdesk/models/machine_row.dart';

/// The phone's machine list, with the console's reachability semantics.
///
/// Deliberately free of the FFI and of any model import, so it can be tested
/// and looked at without the generated bridge, the same split the console
/// screens use. Everything it renders arrives through the constructor.
///
/// The three states are the point. A machine no response has named is unknown,
/// which is drawn as a hollow ring and carries no times at all: it is not the
/// same as a machine that answered and is down, and a list that renders them
/// identically is lying to whoever is holding the phone.
class MachineListView extends StatelessWidget {
  const MachineListView({
    super.key,
    required this.machines,
    required this.onConnect,
    this.savedPasswords = const {},
    this.checking = const {},
    this.now,
    this.onConnectToFirstMachine,
  });

  final List<MachineRow> machines;
  final void Function(String id) onConnect;

  /// Machines with a reachability query still in flight. Their dot says the
  /// question is open rather than repeating a stale answer as if it were fresh.
  final Set<String> checking;

  /// Machines this client already holds a password for. Shown so the operator
  /// knows which taps will ask for one and which will not.
  final Set<String> savedPasswords;

  /// Fixed clock for tests. Null means now.
  final DateTime? now;

  /// Where an operator with no machines goes next. When absent the empty state
  /// still explains itself but offers no control, which is a dead end, so the
  /// page that owns this list is expected to supply it.
  final VoidCallback? onConnectToFirstMachine;

  @override
  Widget build(BuildContext context) {
    // Always scrollable, empty or not, so a pull to refresh still works when
    // there is nothing in the list yet, which is exactly when it is wanted.
    if (machines.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 80),
          _Empty(onConnect: onConnectToFirstMachine),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: machines.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) => _MachineTile(
        machine: machines[i],
        hasSavedPassword: savedPasswords.contains(machines[i].id),
        isChecking: checking.contains(machines[i].id),
        onConnect: onConnect,
        now: now,
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({this.onConnect});

  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.color?.withOpacity(0.7);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.devices_other_outlined, size: 44, color: muted),
          const SizedBox(height: 12),
          Text('No machines yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Machines you connect to are kept here, '
            'so the next time is one tap.',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted),
          ),
          if (onConnect != null) ...[
            const SizedBox(height: 20),
            // The way out. An empty screen that names a mechanism and offers
            // no control leaves the operator to work out where to go next.
            FilledButton.icon(
              onPressed: onConnect,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Connect to a machine'),
            ),
          ],
        ],
      ),
    );
  }
}

class _MachineTile extends StatelessWidget {
  const _MachineTile({
    required this.machine,
    required this.hasSavedPassword,
    required this.isChecking,
    required this.onConnect,
    this.now,
  });

  final MachineRow machine;
  final bool hasSavedPassword;
  final bool isChecking;
  final void Function(String id) onConnect;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color?.withOpacity(0.7);
    // The shared decision, so the phone's dot and the console's cannot drift.
    final dot = labdeskDotFor(
      checking: isChecking,
      status: machine.status,
      fallbackOnline: false,
    );
    return ListTile(
      onTap: () => onConnect(machine.id),
      leading: _StatusDot(dot: dot),
      // Two lines, because a truncated name is a machine an operator cannot
      // tell from another one, and this row is a one-tap connect. The width
      // beside it was going spare.
      title: Text(machine.displayName,
          maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _subtitle(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: muted),
      ),
      // The state gets its own word on the right rather than being buried in a
      // run of subtitle text, because it is the one thing being read.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _word(dot),
            style: theme.textTheme.bodySmall?.copyWith(
              color: _dotColour(context, dot),
              fontWeight: FontWeight.w500,
            ),
          ),
          if (hasSavedPassword) ...[
            const SizedBox(width: 8),
            Icon(Icons.vpn_key_outlined, size: 18, color: muted),
          ],
        ],
      ),
    );
  }

  String _subtitle() {
    // A machine that has never answered has nothing to say about when it was
    // last seen, and rendering a dash there would only invite reading it as a
    // time. It is left out entirely.
    if (machine.lastSeenOnline == null) return machine.id;
    // A middle dot, not a full stop: a period after an identifier reads as the
    // end of a sentence and makes the identifier itself look truncated.
    return '${machine.id}  ·  Seen ${machine.sinceSeen(now: now)} ago';
  }
}

String _word(LabDeskDot dot) => switch (dot) {
      LabDeskDot.checking => 'Checking',
      LabDeskDot.online => 'Online',
      LabDeskDot.offline => 'Offline',
      LabDeskDot.unknown => 'Unknown',
    };

/// One decision about colour, read by both the dot and the word beside it.
///
/// A dot is about ten pixels and the word next to it is bigger, so leaving the
/// word a uniform grey put the whole state signal on the smallest thing in the
/// row. Colouring both means the state survives a glance.
Color _dotColour(BuildContext context, LabDeskDot dot) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return switch (dot) {
    LabDeskDot.online => dark ? Colors.green.shade400 : Colors.green.shade700,
    LabDeskDot.offline => theme.colorScheme.error,
    // Amber has to change with the background rather than stay one value.
    // Measured on the rendered image, amber 700 text came out at roughly two
    // to one against the light surface, which is the exact "controls you
    // cannot see" complaint the bar was written against. The dark amber below
    // measures about five and a half to one on light; on dark the light amber
    // is the one that carries.
    LabDeskDot.checking =>
      dark ? Colors.amber.shade300 : const Color(0xFF8A5A00),
    LabDeskDot.unknown =>
      theme.textTheme.bodySmall?.color?.withOpacity(0.6) ?? Colors.grey,
  };
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.dot});

  final LabDeskDot dot;

  @override
  Widget build(BuildContext context) {
    // Hollow covers both states where nothing is known: nobody has asked, and
    // the asking is still out. Neither may be drawn as an answer.
    final unknown = dot == LabDeskDot.unknown || dot == LabDeskDot.checking;
    final colour = _dotColour(context, dot);
    return SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // Hollow for unknown, so it reads as an absent answer at a glance
            // rather than as a quieter colour of the same thing.
            color: unknown ? Colors.transparent : colour,
            border: unknown ? Border.all(color: colour, width: 1.5) : null,
          ),
        ),
      ),
    );
  }
}
