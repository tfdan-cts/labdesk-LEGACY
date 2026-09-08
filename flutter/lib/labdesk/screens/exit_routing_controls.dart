import 'package:flutter/material.dart';
import '../models/exit_routing.dart';

class ExitChoice {
  const ExitChoice({required this.id, required this.name, this.reachable});
  final String id;
  final String name;
  final bool? reachable;
}

/// Parent owns scoped broker requests and epoch guards. `onSelect` writes a
/// revision-checked preference; `readback` comes only from the privileged daemon.
class ExitRoutingControls extends StatelessWidget {
  const ExitRoutingControls({super.key, required this.exits, required this.selectedExitId,
    required this.readback, required this.pending, required this.canManage,
    required this.onSelect, required this.onRefresh});
  final List<ExitChoice> exits;
  final String? selectedExitId;
  final ExitRoutingReadback readback;
  final bool pending;
  final bool canManage;
  final ValueChanged<String?> onSelect;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final available = selectedExitId == null || exits.any((exit) => exit.id == selectedExitId);
    final entries = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: '', child: Text('Direct')),
      ...exits.map((exit) => DropdownMenuItem(value: exit.id,
        child: Text('${exit.name}${exit.reachable == false ? ' — offline' : ''}'))),
      if (!available) DropdownMenuItem(value: selectedExitId!, child: const Text('Selected exit unavailable')),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Internet connection'),
      DropdownButton<String>(value: selectedExitId ?? '', isExpanded: true, items: entries,
        onChanged: canManage && !pending && readback.selectionSupported
          ? (id) => onSelect(id == '' ? null : id) : null),
      Text(pending ? 'Pending machine acknowledgement' : switch (readback.status) {
        'selected' => 'Exit selection confirmed by the daemon',
        'direct' => 'Direct selection confirmed by the daemon',
        'unavailable' => 'Selected exit unavailable',
        _ => 'Routing state not confirmed',
      }),
      if (readback.error != null) Text(readback.error!),
      const Text('Public egress, DNS and IPv6 have not been verified.'),
      TextButton(onPressed: onRefresh, child: const Text('Refresh routing state')),
      const Divider(),
      const Text("Allow this device's local network"),
      const Text('Unavailable in this build. This controls the client LAN, independently of the exit machine.'),
      const SizedBox(height: 12),
      const Text("Allow exit users to reach this machine's LAN"),
      const Text('Unavailable until this platform can enforce and verify exit-side isolation.'),
    ]);
  }
}
