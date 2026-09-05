import 'package:flutter/material.dart';

import '../../common/labdesk_peer_status.dart';
import '../charts/metric_sparkline.dart';
import '../models/machine_metrics.dart';
import '../models/machine_row.dart';
import '../theme/console_theme.dart';

/// Health for the whole fleet at once: one card per machine.
///
/// The figures are the machine's own. Every enrolled machine's agent takes them
/// on its own flush and sends them to lab-desk.net, and the console reads them
/// back with the fleet: no session, no terminal channel and nobody watching is
/// needed for a reading to exist (WP18). A machine the organization has not
/// enrolled has no readings at all, and the card says so rather than showing
/// four dashes with no reason.
///
/// Presentational: it takes rows and health per row. Nothing here touches the
/// client.
class HealthBoard extends StatelessWidget {
  const HealthBoard({
    super.key,
    required this.machines,
    required this.healthFor,
    this.now,
  });

  final List<MachineRow> machines;
  final MachineHealth Function(String machineId) healthFor;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    if (machines.isEmpty) {
      return Center(
        child: Text('No machines yet.', style: C.small(color: C.textFaint)),
      );
    }
    final online = machines
        .where((m) => m.status == LabDeskPeerStatus.online)
        .toList(growable: false);
    final rest = machines
        .where((m) => m.status != LabDeskPeerStatus.online)
        .toList(growable: false);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Every enrolled machine reports its own figures to lab-desk.net on '
            'its flush, and the console reads them back with the fleet. A '
            'machine that is not enrolled with your organization reports '
            'nothing, and reads as such.',
            style: C.small(color: C.textMuted),
          ),
          const SizedBox(height: 16),
          _grid(context, online),
          if (rest.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text('Not reachable', style: C.micro()),
            const SizedBox(height: 10),
            _grid(context, rest),
          ],
        ],
      ),
    );
  }

  Widget _grid(BuildContext context, List<MachineRow> rows) {
    if (rows.isEmpty) {
      return Text('Nothing is online.', style: C.small(color: C.textFaint));
    }
    return LayoutBuilder(builder: (context, c) {
      final columns = (c.maxWidth / 420).floor().clamp(1, 4);
      final width = (c.maxWidth - (columns - 1) * 16) / columns;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final m in rows)
            SizedBox(
              width: width,
              child: HealthCard(
                machine: m,
                health: healthFor(m.id),
                now: now,
              ),
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
    final online = machine.status == LabDeskPeerStatus.online;
    final statusColor = switch (machine.status) {
      LabDeskPeerStatus.online => C.ok,
      LabDeskPeerStatus.offline => C.bad,
      LabDeskPeerStatus.unknown => C.idle,
    };
    final remote = {for (final m in health.remote) m.label: m};
    final session = {for (final m in health.session) m.label: m};
    final history = health.history;
    // Sparklines appear for every tile at once or not at all, so the four
    // never sit at different heights while the first samples arrive.
    final showHistory = history != null && history.samples.length >= 2;
    List<MetricPoint>? trail(MetricKind k) =>
        showHistory ? history.series(k) : null;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: C.rounded,
        border: Border.all(color: C.hairline),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(machine.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: C.h2()),
                    const SizedBox(height: 2),
                    Text(
                      '${machine.id}  ·  ${machine.platform}',
                      style: C.data(size: 11, color: C.textFaint),
                    ),
                  ],
                ),
              ),
              if (health.state?.worstDisk != null)
                _DriveChip(verdict: health.state!.worstDisk!),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _tile(remote['CPU'], 'CPU', trail(MetricKind.cpu)),
              const SizedBox(width: 10),
              _tile(remote['Memory'], 'Memory', trail(MetricKind.memory)),
              const SizedBox(width: 10),
              _tile(remote['Disk'], 'Disk', trail(MetricKind.disk)),
              const SizedBox(width: 10),
              _tile(remote['Uptime'], 'Uptime', showHistory ? const [] : null),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _footer(online, session),
            style: C.small(color: C.textFaint),
          ),
        ],
      ),
    );
  }

  String _footer(bool online, Map<String, Metric> session) {
    if (!online) {
      return machine.lastSeenOnline == null
          ? 'Offline. Not seen online this session.'
          : 'Offline. Last seen ${machine.sinceSeen(now: now)} ago.';
    }
    final rtt = session['Round trip'];
    final codec = session['Codec'];
    final parts = <String>[];
    if (rtt != null && rtt.isAvailable) parts.add('${rtt.value} ms round trip');
    if (codec != null && codec.isAvailable) parts.add('${codec.value}');
    if (parts.isNotEmpty) return 'Desktop session: ${parts.join(', ')}.';
    final state = health.state;
    if (state == null) {
      return 'Not enrolled with your organization, so it reports no figures.';
    }
    final said = <String>[];
    if (state.loggedInUser != null) said.add('${state.loggedInUser} signed in');
    if (state.agentVersion != null) said.add('agent ${state.agentVersion}');
    if (said.isEmpty) {
      return health.remote.any((m) => m.isAvailable)
          ? 'Reported by the machine itself.'
          : 'Enrolled; no readings sent yet.';
    }
    return 'Reported by the machine itself: ${said.join(', ')}.';
  }

  /// [trail] is null when the card shows no history row, and empty for a
  /// tile that has a row but nothing to draw in it (uptime).
  Widget _tile(Metric? m, String label, List<MetricPoint>? trail) {
    final available = m != null && m.isAvailable;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: C.micro()),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(available ? m.value! : '--',
                  style: C.data(
                      size: 16,
                      color: available ? C.text : C.textFaint)),
              if (available && m.unit != null) ...[
                const SizedBox(width: 3),
                Text(m.unit!, style: C.small(color: C.textFaint)),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Container(
            height: 3,
            decoration: BoxDecoration(
              color: C.hairline,
              borderRadius: BorderRadius.circular(2),
            ),
            child: available && m.ratio != null
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: m.ratio!.clamp(0.0, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          color: m.ratio! > 0.9 ? C.bad : C.ok,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  )
                : null,
          ),
          if (trail != null) ...[
            const SizedBox(height: 22),
            SizedBox(
              height: 26,
              child: MetricSparkline(points: trail, label: label),
            ),
          ],
        ],
      ),
    );
  }
}

/// The worst verdict over the machine's drives, in the one place on the card
/// that carries a colour of its own. `unreadable` is not green: a drive nobody
/// could read is not a drive that is fine (plan section 8.2).
class _DriveChip extends StatelessWidget {
  const _DriveChip({required this.verdict});

  final String verdict;

  @override
  Widget build(BuildContext context) {
    final (label, colour) = switch (verdict) {
      'ok' => ('Drives ok', C.ok),
      'warn' => ('Drive warning', C.accent),
      'failing' => ('Drive failing', C.bad),
      _ => ('Drives unreadable', C.idle),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colour.withOpacity(0.14),
        borderRadius: C.roundedSm,
        border: Border.all(color: colour.withOpacity(0.4)),
      ),
      child: Text(label, style: C.small(color: colour)),
    );
  }
}
