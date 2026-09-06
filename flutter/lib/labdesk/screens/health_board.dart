import 'package:flutter/material.dart';

import '../../common/labdesk_peer_status.dart';
import '../charts/metric_sparkline.dart';
import '../models/machine_metrics.dart';
import '../models/machine_row.dart';
import '../theme/console_theme.dart';

LabDeskPeerStatus _status(
    MachineRow machine, MachineHealth health, DateTime now) {
  final state = health.state;
  if (state == null) return machine.status;
  return switch (state.statusAt(now)) {
    'online' => LabDeskPeerStatus.online,
    'offline' => LabDeskPeerStatus.offline,
    _ => LabDeskPeerStatus.unknown,
  };
}

String _age(int seconds) {
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  if (seconds < 86400) return '${seconds ~/ 3600}h';
  return '${seconds ~/ 86400}d';
}

/// Collector readings with their source age, grouped by current reachability.
class HealthBoard extends StatelessWidget {
  const HealthBoard({
    super.key,
    required this.machines,
    required this.healthFor,
    this.now,
    this.footer,
  });

  final List<MachineRow> machines;
  final MachineHealth Function(String machineId) healthFor;
  final DateTime? now;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final snapshot = now ?? DateTime.now();
    final health = {for (final m in machines) m.id: healthFor(m.id)};
    List<MachineRow> of(LabDeskPeerStatus s) => machines
        .where((m) => _status(m, health[m.id]!, snapshot) == s)
        .toList(growable: false);
    final online = of(LabDeskPeerStatus.online);
    final offline = of(LabDeskPeerStatus.offline);
    final unknown = of(LabDeskPeerStatus.unknown);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Machine readings, with the age of their last report.',
            style: C.of(context).small(color: C.of(context).textMuted),
          ),
          const SizedBox(height: 16),
          if (machines.isEmpty)
            Text('No machines yet.', style: C.of(context).small())
          else if (online.isEmpty)
            Text('Nothing is online.', style: C.of(context).small())
          else
            _grid(context, online, health, snapshot),
          for (final section in [
            ('Offline', offline),
            ('Unknown', unknown),
          ])
            if (section.$2.isNotEmpty) ...[
              const SizedBox(height: 22),
              Text(section.$1, style: C.of(context).micro()),
              const SizedBox(height: 10),
              _grid(context, section.$2, health, snapshot),
            ],
          if (footer != null) ...[
            const SizedBox(height: 24),
            footer!,
          ],
        ],
      ),
    );
  }

  Widget _grid(BuildContext context, List<MachineRow> rows,
      Map<String, MachineHealth> health, DateTime snapshot) {
    return LayoutBuilder(builder: (context, constraints) {
      final columns = (constraints.maxWidth / 420).floor().clamp(1, 4);
      final width = (constraints.maxWidth - (columns - 1) * 24) / columns;
      return Wrap(
        spacing: 24,
        runSpacing: 24,
        children: [
          for (final m in rows)
            SizedBox(
              width: width,
              child:
                  HealthCard(machine: m, health: health[m.id]!, now: snapshot),
            ),
        ],
      );
    });
  }
}

class HealthCard extends StatelessWidget {
  const HealthCard({
    super.key,
    required this.machine,
    required this.health,
    this.now,
  });

  final MachineRow machine;
  final MachineHealth health;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final snapshot = now ?? DateTime.now();
    final status = _status(machine, health, snapshot);
    final state = health.state;
    final current = state?.statusAt(snapshot) == 'online';
    final age = state?.seenAt == null
        ? null
        : snapshot.millisecondsSinceEpoch ~/ 1000 - state!.seenAt!;
    // An absent or future source timestamp cannot establish a report's age.
    final hasSource = age != null && age >= 0;
    final remote = {for (final m in health.remote) m.label: m};
    final session = health.session
        .where((m) =>
            m.isAvailable && (m.label == 'Round trip' || m.label == 'Codec'))
        .toList();
    final statusColor = switch (status) {
      LabDeskPeerStatus.online => C.of(context).ok,
      LabDeskPeerStatus.offline => C.of(context).bad,
      LabDeskPeerStatus.unknown => C.of(context).idle,
    };
    final samples = health.history?.samples
            .where((s) => !s.at.isAfter(snapshot))
            .toList() ??
        <MetricSample>[];
    samples.sort((a, b) => a.at.compareTo(b.at));
    final showHistory = samples.length >= 2;
    List<MetricPoint>? trail(MetricKind kind) => showHistory
        ? [
            for (final sample in samples)
              if (sample.of(kind) != null && sample.of(kind)!.isFinite)
                MetricPoint(sample.at, sample.of(kind)!),
          ]
        : null;
    final source = !hasSource
        ? (age != null && age < 0
            ? 'Report timestamp is in the future. Current readings unavailable.'
            : 'No dated collector report available. Current readings unavailable.')
        : current
            ? 'Collector report ${_age(age)} ago. Current readings.'
            : 'Last collector report ${_age(age)} ago. Cached readings; not current.';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: C.of(context).hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(machine.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: C.of(context).h2()),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('${machine.id}  ·  ${machine.platform}',
              style:
                  C.of(context).data(size: 11, color: C.of(context).textFaint)),
          const SizedBox(height: 10),
          Text(source,
              style: C.of(context).small(color: C.of(context).textMuted)),
          const SizedBox(height: 14),
          LayoutBuilder(builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(1);
            final columns =
                (constraints.maxWidth / (92 * scale)).floor().clamp(1, 4);
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(spacing: 12, runSpacing: 16, children: [
              for (final entry in [
                ('CPU', trail(MetricKind.cpu)),
                ('Memory', trail(MetricKind.memory)),
                ('Disk', trail(MetricKind.disk)),
                ('Uptime', null),
              ])
                SizedBox(
                    width: width,
                    child: _tile(context, hasSource ? remote[entry.$1] : null,
                        entry.$1, entry.$2, current)),
            ]);
          }),
          if (showHistory) ...[
            const SizedBox(height: 10),
            Text(
                'Recorded history · latest sample ${_age(snapshot.difference(samples.last.at).inSeconds)} ago.',
                style: C.of(context).small(color: C.of(context).textFaint)),
          ],
          if (hasSource && state?.worstDisk != null) ...[
            const SizedBox(height: 12),
            _DriveLabel(verdict: state!.worstDisk!, current: current),
          ],
          const SizedBox(height: 12),
          Text(_footer(status),
              style: C.of(context).small(color: C.of(context).textFaint)),
          if (health.connected && session.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
                'Desktop session: ${session.map((m) => '${m.label}: ${m.value}${m.unit == null ? '' : ' ${m.unit}'}').join(', ')}',
                style: C.of(context).small(color: C.of(context).textFaint)),
          ],
        ],
      ),
    );
  }

  String _footer(LabDeskPeerStatus status) => switch (status) {
        LabDeskPeerStatus.offline => machine.lastSeenOnline == null
            ? 'Offline. No recent connection confirmed.'
            : 'Offline. Last seen ${machine.sinceSeen(now: now)} ago.',
        LabDeskPeerStatus.unknown => machine.lastSeenOnline == null
            ? 'Unknown. Current reachability is not confirmed.'
            : 'Unknown. No answer since it was last seen ${machine.sinceSeen(now: now)} ago.',
        LabDeskPeerStatus.online => 'Online.',
      };

  Widget _tile(BuildContext context, Metric? metric, String label,
      List<MetricPoint>? trail, bool current) {
    final available = metric != null && metric.isAvailable;
    final colour = current ? C.of(context).text : C.of(context).textMuted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: C.of(context).micro()),
        const SizedBox(height: 4),
        Text(
            available
                ? '${metric.value}${metric.unit == null ? '' : ' ${metric.unit}'}'
                : '--',
            style: C.of(context).data(
                size: 16, color: available ? colour : C.of(context).textFaint)),
        const SizedBox(height: 6),
        Container(
          height: 3,
          color: C.of(context).hairline,
          child: available && metric.ratio != null && metric.ratio!.isFinite
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: metric.ratio!.clamp(0.0, 1.0),
                    child: ColoredBox(
                        color: !current
                            ? C.of(context).textFaint
                            : metric.ratio! > 0.9
                                ? C.of(context).bad
                                : C.of(context).ok),
                  ),
                )
              : null,
        ),
        if (trail != null) ...[
          const SizedBox(height: 16),
          SizedBox(
              height: 26,
              child: MetricSparkline(points: trail, label: '$label recorded')),
        ],
      ],
    );
  }
}

class _DriveLabel extends StatelessWidget {
  const _DriveLabel({required this.verdict, required this.current});
  final String verdict;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final (label, colour) = switch (verdict) {
      'ok' => ('Drives ok', C.of(context).ok),
      'warn' => ('Drive warning', C.of(context).accent),
      'failing' => ('Drive failing', C.of(context).bad),
      _ => ('Drives unreadable', C.of(context).idle),
    };
    return Text(current ? label : 'Last drive report: ${label.toLowerCase()}',
        style: C
            .of(context)
            .small(color: current ? colour : C.of(context).textMuted));
  }
}
