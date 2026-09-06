import 'package:flutter/material.dart';

import '../models/net_view.dart';
import '../theme/console_theme.dart';

/// One machine's network, adapter by adapter, with the reachability verdict the
/// machine itself reached.
///
/// The figures are the agent's own (`net.adapters` and `net.reachability`,
/// contract section 6). Nothing here is measured by the console: an adapter is
/// up or down because the machine said so, and the internet is reachable or not
/// because the machine tried it. That is what makes this answer "is it the
/// network or is it us" for a machine nobody can reach a session to.
class AdaptersCard extends StatelessWidget {
  const AdaptersCard({
    super.key,
    required this.view,
    required this.machineName,
    this.machines = const [],
    this.selectedId = '',
    this.busy = false,
    this.onSelect,
  });

  final MachineNetView view;
  final String machineName;

  /// The machines that can be looked at, for the picker. `(id, name)`.
  final List<(String, String)> machines;
  final String selectedId;
  final bool busy;
  final ValueChanged<String>? onSelect;

  @override
  Widget build(BuildContext context) {
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
          Row(
            children: [
              Expanded(child: Text('Adapters', style: C.h2())),
              if (machines.length > 1 && onSelect != null)
                _MachinePicker(
                  machines: machines,
                  selectedId: selectedId,
                  label: machineName,
                  onSelect: busy ? null : onSelect,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'What the machine reports about its own network. Loopback is left '
            'out; byte counts are since it last booted.',
            style: C.small(),
          ),
          const SizedBox(height: 16),
          _Reachability(reachability: view.reachability),
          const SizedBox(height: 14),
          if (!view.reported)
            Text(
              busy
                  ? 'Reading...'
                  : 'This machine has not reported a network view yet. It is '
                      'sent on the agent\'s own flush, and only when something '
                      'changed.',
              style: C.small(color: C.textFaint),
            )
          else if (view.adapters.isEmpty)
            Text('No adapters reported.', style: C.small(color: C.textFaint))
          else
            for (final a in view.adapters) _AdapterRow(adapter: a),
        ],
      ),
    );
  }
}

class _Reachability extends StatelessWidget {
  const _Reachability({required this.reachability});

  final NetReachability reachability;

  @override
  Widget build(BuildContext context) {
    final colour = switch (reachability.internet) {
      'online' => C.ok,
      'offline' => C.bad,
      _ => C.idle,
    };
    final selfheal = reachability.selfHealRunning
        ? 'Self-healing is ${reachability.selfhealLabel}.'
        : 'Self-healing is off.';
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${reachability.internetLabel}. $selfheal',
            style: C.body(),
          ),
        ),
        if (reachability.probe.isNotEmpty)
          Text(reachability.probe, style: C.small(color: C.textFaint)),
      ],
    );
  }
}

class _AdapterRow extends StatelessWidget {
  const _AdapterRow({required this.adapter});

  final NetAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final addresses = adapter.addresses.map((a) => '$a').join('  ');
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: C.hairline)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: adapter.up ? C.ok : C.idle,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(adapter.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: C.body()),
                    ),
                    const SizedBox(width: 8),
                    Text(adapter.kind, style: C.small(color: C.textFaint)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  addresses.isEmpty
                      ? (adapter.up ? 'Up, no address' : 'Down')
                      : addresses,
                  style: C.data(size: 12, color: C.textMuted),
                ),
                if (adapter.mac.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(adapter.mac, style: C.data(size: 11, color: C.textFaint)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${formatBytes(adapter.rxBytes)} in',
                  style: C.data(size: 12, color: C.textMuted)),
              const SizedBox(height: 2),
              Text('${formatBytes(adapter.txBytes)} out',
                  style: C.data(size: 12, color: C.textMuted)),
            ],
          ),
        ],
      ),
    );
  }
}

class _MachinePicker extends StatelessWidget {
  const _MachinePicker({
    required this.machines,
    required this.selectedId,
    required this.label,
    this.onSelect,
  });

  final List<(String, String)> machines;
  final String selectedId;
  final String label;
  final ValueChanged<String>? onSelect;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Another machine',
      color: C.surfaceHi,
      enabled: onSelect != null,
      initialValue: selectedId.isEmpty ? null : selectedId,
      onSelected: onSelect,
      itemBuilder: (_) => [
        for (final (id, name) in machines)
          PopupMenuItem(
              value: id,
              child: Text(name.isEmpty ? id : name, style: C.body())),
      ],
      child: Text(
        label.isEmpty ? 'Pick a machine' : label,
        style: C.small(color: C.textMuted).copyWith(
            decoration: TextDecoration.underline,
            decorationColor: C.textFaint),
      ),
    );
  }
}
