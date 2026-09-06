import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/dashboard_layout.dart';
import '../models/machine_metrics.dart';
import '../models/machine_row.dart';

class DashboardFleet {
  const DashboardFleet({required this.id, required this.name});
  final String id;
  final String name;
}

String dashboardReportTitle(DashboardReport report) => switch (report) {
      DashboardReport.availability => 'Machine availability',
      DashboardReport.cpu => 'CPU use',
      DashboardReport.memory => 'Memory use',
      DashboardReport.disk => 'Storage used',
      DashboardReport.trends => 'Performance history',
      DashboardReport.attention => 'Needs attention',
      DashboardReport.fleets => 'Fleet comparison',
      DashboardReport.freshness => 'Reporting freshness',
    };

/// A reading retains its identity, age and absence throughout presentation.
class DashboardReading {
  const DashboardReading(this.machine, this.health, this.now);
  final MachineRow machine;
  final MachineHealth health;
  final DateTime now;

  DateTime? get at => health.state?.seenAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(health.state!.seenAt! * 1000);
  Duration? get age => at == null ? null : now.difference(at!);
  int get expectedSeconds =>
      (health.state?.flushSeconds ?? 0) > 0 ? health.state!.flushSeconds! : 60;
  bool get stale =>
      age != null && age!.inSeconds > math.max(180, expectedSeconds * 3);
  bool get current =>
      age != null &&
      !age!.isNegative &&
      !stale &&
      health.state?.status != 'offline';
  String get freshness => at == null
      ? 'No collector report'
      : age!.isNegative
          ? 'Source clock ahead'
          : '${stale ? 'Stale · ' : ''}${dashboardAge(age!)} ago';
  String get status {
    final reported = health.state?.status ?? machine.status.name;
    if (reported != 'online') {
      return reported == 'offline' ? 'offline' : 'unknown';
    }
    final checkedAt = health.state == null ? machine.lastChecked : at;
    if (checkedAt == null) return 'unknown';
    final sinceCheck = now.difference(checkedAt);
    final validSeconds = health.state == null ? 180 : expectedSeconds * 2;
    return sinceCheck.isNegative || sinceCheck.inSeconds > validSeconds
        ? 'unknown'
        : 'online';
  }

  double? raw(MetricKind kind) {
    final state = health.state;
    final value = switch (kind) {
      MetricKind.cpu => state?.cpuPct,
      MetricKind.memory => state?.memPct,
      MetricKind.disk => state?.fsWorstPct,
    };
    return value == null || !value.isFinite || value < 0 || value > 100
        ? null
        : value.toDouble();
  }

  double? value(MetricKind kind) => current ? raw(kind) : null;
  List<String> get issues => [
        if (status == 'offline') 'Machine offline',
        if (stale) 'Collector report overdue',
        if (health.state?.worstDisk == 'failing') 'Drive health failing',
        if (health.state?.worstDisk == 'warn') 'Drive health warning',
        if (health.state?.worstDisk == 'unreadable') 'Drive health unreadable',
        if ((value(MetricKind.cpu) ?? -1) >= 90)
          'CPU at ${raw(MetricKind.cpu)!.round()}%',
        if ((value(MetricKind.memory) ?? -1) >= 90)
          'Memory at ${raw(MetricKind.memory)!.round()}%',
        if ((value(MetricKind.disk) ?? -1) >= 90)
          'Fullest filesystem at ${raw(MetricKind.disk)!.round()}%',
      ];
}

String dashboardAge(Duration age) {
  final seconds = age.inSeconds;
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  if (seconds < 86400) return '${seconds ~/ 3600}h';
  return '${seconds ~/ 86400}d';
}

/// Filter first, then intersect saved per-widget identities. Local peer groups
/// are deliberately absent: organization fleets are server-owned identities.
List<MachineRow> dashboardScopeRows(
        List<MachineRow> machines, DashboardWidgetSpec spec,
        {String? fleetId,
        Map<String, Set<String>> machineFleetIds = const {}}) =>
    machines.where((m) {
      if (fleetId != null &&
          !(machineFleetIds[m.id]?.contains(fleetId) ?? false)) return false;
      return spec.scope == DashboardScope.fleet ||
          spec.scope == DashboardScope.average ||
          (spec.scope == DashboardScope.single
              ? spec.machineIds.isNotEmpty && spec.machineIds.first == m.id
              : spec.machineIds.contains(m.id));
    }).toList();

class DashboardReportBody extends StatelessWidget {
  const DashboardReportBody(
      {super.key,
      required this.spec,
      required this.rows,
      required this.healthFor,
      required this.now,
      this.fleets = const [],
      this.machineFleetIds = const {},
      this.onOpenMachine});
  final DashboardWidgetSpec spec;
  final List<MachineRow> rows;
  final MachineHealth Function(String) healthFor;
  final DateTime now;
  final List<DashboardFleet> fleets;
  final Map<String, Set<String>> machineFleetIds;
  final ValueChanged<String>? onOpenMachine;

  @override
  Widget build(BuildContext context) {
    final readings =
        rows.map((r) => DashboardReading(r, healthFor(r.id), now)).toList();
    if (rows.isEmpty) {
      return const Text(
          'No machines in this selection. Change the fleet filter or choose machines in report settings.');
    }
    return switch (spec.report) {
      DashboardReport.cpu => _resource(context, readings, MetricKind.cpu),
      DashboardReport.memory => _resource(context, readings, MetricKind.memory),
      DashboardReport.disk => _resource(context, readings, MetricKind.disk),
      DashboardReport.availability => _availability(context, readings),
      DashboardReport.trends => _trends(context, readings),
      DashboardReport.attention => _attention(context, readings),
      DashboardReport.fleets => _fleets(context, readings),
      DashboardReport.freshness => _freshness(context, readings),
    };
  }

  Color _muted(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;
  Color _statusColor(BuildContext context, String status) => switch (status) {
        'online' => Theme.of(context).brightness == Brightness.dark
            ? const Color(0xff77c6a1)
            : const Color(0xff27704e),
        'offline' => Theme.of(context).colorScheme.error,
        _ => _muted(context),
      };
  Widget _note(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child:
          Text(text, style: TextStyle(fontSize: 12, color: _muted(context))));
  Widget _machineButton(DashboardReading r, Widget child) => TextButton(
      onPressed:
          onOpenMachine == null ? null : () => onOpenMachine!(r.machine.id),
      style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          foregroundColor: null,
          disabledForegroundColor: null,
          alignment: Alignment.centerLeft),
      child: child);
  Widget _row(BuildContext context, DashboardReading r, String value,
          {String? detail, Widget? chart}) =>
      _machineButton(
          r,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                  child: Text(r.machine.displayName,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface))),
              const SizedBox(width: 8),
              Flexible(
                  child: Text(value,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                          fontSize:
                              spec.style == DashboardStyle.compact ? 24 : 16,
                          color: Theme.of(context).colorScheme.onSurface)))
            ]),
            if (detail != null) _note(context, detail),
            if (chart != null) chart,
            const Divider(height: 10),
          ]));

  Widget _resource(
      BuildContext context, List<DashboardReading> readings, MetricKind kind) {
    final contributors = readings.where((r) => r.value(kind) != null).toList();
    final average = contributors.isEmpty
        ? null
        : contributors.fold<double>(0, (s, r) => s + r.value(kind)!) /
            contributors.length;
    final averageScope = spec.scope == DashboardScope.average;
    final children = <Widget>[
      if (kind == MetricKind.disk)
        _note(context, 'Fullest filesystem on each machine'),
      if (averageScope) ...[
        if (spec.style == DashboardStyle.visual)
          Align(
              alignment: Alignment.centerLeft,
              child: DashboardDial(value: average, label: 'Current average'))
        else
          Text(
              average == null
                  ? 'No current readings'
                  : '${average.round()}% average',
              style: Theme.of(context).textTheme.headlineMedium),
        _note(
            context,
            contributors.isEmpty
                ? 'No contributors'
                : 'Contributors: ${contributors.map((r) => r.machine.displayName).join(', ')}'),
        _note(context,
            '${readings.length - contributors.length} excluded: unavailable or stale'),
      ],
      if (spec.style == DashboardStyle.visual && !averageScope)
        LayoutBuilder(
            builder: (context, c) =>
                Wrap(spacing: 12, runSpacing: 16, children: [
                  for (final r in readings)
                    SizedBox(
                        width: math.min(
                            c.maxWidth, readings.length == 1 ? 190 : 128),
                        child: _machineButton(
                            r,
                            Column(children: [
                              DashboardDial(
                                  value: r.value(kind),
                                  label: r.machine.displayName),
                              Text(r.machine.displayName,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface)),
                              _note(
                                  context,
                                  r.value(kind) == null
                                      ? 'No current reading · ${r.freshness}'
                                      : r.freshness),
                            ]))),
                ])),
      if (spec.style != DashboardStyle.visual || averageScope)
        for (final r in readings)
          _row(context, r,
              r.value(kind) == null ? '—' : '${r.value(kind)!.round()}%',
              detail: spec.style == DashboardStyle.detailed
                  ? '${r.freshness}${r.value(kind) == null && r.raw(kind) != null ? ' · Last recorded ${r.raw(kind)!.round()}%' : ''}'
                  : r.value(kind) == null
                      ? 'No current reading · ${r.freshness}'
                      : null,
              chart:
                  spec.style == DashboardStyle.detailed && r.value(kind) != null
                      ? LinearProgressIndicator(
                          value: r.value(kind)! / 100,
                          minHeight: 5,
                          color: r.value(kind)! >= 90
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.primary)
                      : spec.style == DashboardStyle.compact
                          ? _history(context, r, kind, height: 32)
                          : null),
      _note(context,
          '${contributors.length} current readings · ${readings.length - contributors.length} unavailable'),
    ];
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _availability(BuildContext context, List<DashboardReading> readings) {
    final online = readings.where((r) => r.status == 'online').length;
    final offline = readings.where((r) => r.status == 'offline').length;
    if (spec.style == DashboardStyle.compact) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$online online',
            style: Theme.of(context).textTheme.headlineMedium),
        _note(context,
            '$offline offline · ${readings.length - online - offline} unknown'),
        _note(context, 'Availability is reachability, not overall health.'),
      ]);
    }
    if (spec.style == DashboardStyle.detailed) {
      return Column(children: [
        for (final r in readings)
          _row(context, r, r.status,
              detail: '${r.machine.platform} · ${r.freshness}')
      ]);
    }
    return LayoutBuilder(
        builder: (context, c) => Wrap(spacing: 14, runSpacing: 16, children: [
              for (final r in readings)
                SizedBox(
                    width: math.min(132, c.maxWidth),
                    child: _machineButton(
                        r,
                        Column(children: [
                          Icon(
                              r.machine.platform
                                          .toLowerCase()
                                          .contains('android') ||
                                      r.machine.platform
                                          .toLowerCase()
                                          .contains('ios')
                                  ? Icons.smartphone_outlined
                                  : Icons.desktop_windows_outlined,
                              size: 54,
                              color: _statusColor(context, r.status)),
                          const SizedBox(height: 8),
                          Text(r.machine.displayName,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onSurface)),
                          Text(r.status,
                              style: TextStyle(
                                  color: _statusColor(context, r.status))),
                          if (r.status == 'unknown')
                            _note(context, r.freshness),
                          if (r.issues.isNotEmpty)
                            _note(
                                context, '${r.issues.length} attention items'),
                        ]))),
            ]));
  }

  Widget _history(BuildContext context, DashboardReading r, MetricKind kind,
      {double height = 92}) {
    final samples = r.health.history?.samples ?? const <MetricSample>[];
    final points = samples
        .where((s) =>
            !s.at.isAfter(now) &&
            s.of(kind) != null &&
            s.of(kind)!.isFinite &&
            s.of(kind)! >= 0 &&
            s.of(kind)! <= 1)
        .toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    if (points.isEmpty) {
      return _note(context, 'No recorded ${kind.name} history');
    }
    if (points.length == 1) {
      return _note(context,
          'One ${kind.name} sample: ${(points.first.of(kind)! * 100).round()}% · ${points.first.at.toLocal().toIso8601String()}');
    }
    final all = samples.where((s) => !s.at.isAfter(now)).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
          label:
              '${r.machine.displayName} ${kind.name} history, ${points.length} real samples; latest ${(points.last.of(kind)! * 100).round()} percent',
          child: SizedBox(
              height: height,
              child: CustomPaint(
                  painter: _HistoryPainter(
                      all,
                      kind,
                      Theme.of(context).colorScheme.primary,
                      Theme.of(context).dividerColor,
                      math.max(r.expectedSeconds * 3, 180))))),
      if (height > 40)
        _note(context,
            '${_stamp(points.first.at)} — ${_stamp(points.last.at)} · ${points.length} samples · 0–100%'),
    ]);
  }

  String _stamp(DateTime at) =>
      '${at.toLocal().month}/${at.toLocal().day} ${at.toLocal().hour.toString().padLeft(2, '0')}:${at.toLocal().minute.toString().padLeft(2, '0')}';

  Widget _trends(BuildContext context, List<DashboardReading> readings) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _note(
            context,
            spec.scope == DashboardScope.average
                ? 'Named source histories; samples are not time-aligned, so no fleet average is inferred.'
                : 'CPU history · actual source timestamps; gaps stay gaps'),
        for (final r in readings) ...[
          _machineButton(r, Text(r.machine.displayName)),
          if (spec.style == DashboardStyle.compact)
            _trendSummary(context, r)
          else
            _history(context, r, MetricKind.cpu),
          if (spec.style == DashboardStyle.detailed) ...[
            _note(context, 'Memory'),
            _history(context, r, MetricKind.memory, height: 56),
            _note(context, 'Fullest filesystem'),
            _history(context, r, MetricKind.disk, height: 56),
            _note(context, r.freshness),
          ],
        ],
      ]);
  Widget _trendSummary(BuildContext context, DashboardReading r) {
    final points = r.health.history
            ?.series(MetricKind.cpu)
            .where((p) =>
                !p.at.isAfter(now) &&
                p.value.isFinite &&
                p.value >= 0 &&
                p.value <= 1)
            .toList() ??
        [];
    if (points.isEmpty) return _note(context, 'No recorded CPU history');
    points.sort((a, b) => a.at.compareTo(b.at));
    return _note(context,
        '${(points.last.value * 100).round()}% latest · ${(points.map((p) => p.value).reduce(math.max) * 100).round()}% peak · ${points.length} samples · ${_stamp(points.last.at)}');
  }

  Widget _attention(BuildContext context, List<DashboardReading> readings) {
    final affected = readings.where((r) => r.issues.isNotEmpty).toList();
    final unknown = readings
        .where((r) =>
            !r.current || MetricKind.values.any((k) => r.value(k) == null))
        .length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (spec.style == DashboardStyle.visual)
        Icon(Icons.warning_amber_rounded,
            size: 48,
            color: affected.isEmpty
                ? _muted(context)
                : Theme.of(context).colorScheme.error),
      Text('${affected.length} machines need attention',
          style: spec.style == DashboardStyle.detailed
              ? Theme.of(context).textTheme.titleMedium
              : Theme.of(context).textTheme.headlineSmall),
      _note(context,
          '${affected.fold<int>(0, (n, r) => n + r.issues.length)} detected issues · $unknown machines have incomplete current data'),
      if (affected.isEmpty)
        _note(context, 'No detected exceptions in available readings.'),
      if (spec.style != DashboardStyle.compact)
        for (final r in affected)
          _row(context, r, '${r.issues.length}', detail: r.issues.join(' · ')),
      if (spec.style == DashboardStyle.detailed)
        _note(context,
            'Thresholds: CPU, memory or fullest filesystem ≥90%; drive warnings and overdue reports are included.'),
    ]);
  }

  Widget _fleets(BuildContext context, List<DashboardReading> readings) {
    if (fleets.isEmpty) {
      return _note(context,
          'No organization fleets are available. Local machine groups are not fleets.');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final fleet in fleets)
        Builder(builder: (context) {
          final members = readings
              .where((r) =>
                  machineFleetIds[r.machine.id]?.contains(fleet.id) ?? false)
              .toList();
          final online = members.where((r) => r.status == 'online').length;
          String average(MetricKind kind) {
            final values =
                members.map((r) => r.value(kind)).whereType<double>().toList();
            return values.isEmpty
                ? '—'
                : '${(values.reduce((a, b) => a + b) / values.length).round()}% (${values.length})';
          }

          return Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(fleet.name,
                        style: Theme.of(context).textTheme.titleSmall),
                    _note(context,
                        '$online online / ${members.length} machines in this selection'),
                    if (spec.style == DashboardStyle.visual &&
                        members.isNotEmpty)
                      LinearProgressIndicator(
                          value: online / members.length, minHeight: 9),
                    if (spec.style == DashboardStyle.detailed) ...[
                      _note(context,
                          'Current averages (contributor count) · CPU ${average(MetricKind.cpu)} · Memory ${average(MetricKind.memory)} · Storage ${average(MetricKind.disk)}'),
                      _note(context,
                          'Members: ${members.isEmpty ? 'none in selection' : members.map((r) => r.machine.displayName).join(', ')}'),
                    ],
                  ]));
        }),
      _note(context, 'Machines may belong to more than one fleet.'),
    ]);
  }

  Widget _freshness(BuildContext context, List<DashboardReading> readings) {
    final reported = readings
        .where((r) => r.at != null && !r.age!.isNegative)
        .toList()
      ..sort((a, b) => b.at!.compareTo(a.at!));
    if (spec.style == DashboardStyle.compact) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${readings.where((r) => r.current).length} current',
            style: Theme.of(context).textTheme.headlineMedium),
        _note(context,
            '${readings.where((r) => r.stale).length} stale · ${readings.where((r) => r.at == null).length} never reported'),
        _note(
            context,
            reported.isEmpty
                ? 'No source timestamp available'
                : 'Latest: ${reported.first.machine.displayName} · ${reported.first.freshness}'),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final r in readings)
        _row(
            context,
            r,
            r.current
                ? 'Current'
                : r.stale
                    ? 'Stale'
                    : 'Unknown',
            detail:
                '${r.freshness}${spec.style == DashboardStyle.detailed ? ' · ${r.at?.toLocal().toIso8601String() ?? 'No source timestamp'} · ${r.health.state?.flushSeconds == null || r.health.state!.flushSeconds! <= 0 ? 'Cadence not reported; 3-minute freshness fallback' : 'Expected every ${r.expectedSeconds}s'}' : ''}',
            chart: spec.style == DashboardStyle.visual &&
                    r.age != null &&
                    !r.age!.isNegative
                ? LinearProgressIndicator(
                    value: (r.age!.inSeconds /
                            math.max(180, r.expectedSeconds * 3))
                        .clamp(0.0, 1.0),
                    color: r.stale
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                    minHeight: 5)
                : null),
      _note(context,
          'Stale after three expected reporting intervals (at least 3 minutes).'),
    ]);
  }
}

class DashboardDial extends StatelessWidget {
  const DashboardDial({super.key, required this.value, required this.label});
  final double? value;
  final String label;
  @override
  Widget build(BuildContext context) => Semantics(
      label:
          '$label: ${value == null ? 'no current reading' : '${value!.round()} percent'}',
      child: SizedBox(
          width: 104,
          height: 104,
          child: Stack(alignment: Alignment.center, children: [
            Positioned.fill(
                child: CustomPaint(
                    painter: _DialPainter(
                        value,
                        value != null && value! >= 90
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                        Theme.of(context).dividerColor))),
            Text(value == null ? '—' : '${value!.round()}%',
                style: TextStyle(
                    fontSize: 24,
                    color: Theme.of(context).colorScheme.onSurface)),
          ])));
}

class _DialPainter extends CustomPainter {
  const _DialPainter(this.value, this.color, this.track);
  final double? value;
  final Color color;
  final Color track;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawArc(rect.deflate(8), -math.pi / 2, math.pi * 2, false, paint);
    if (value != null) {
      canvas.drawArc(rect.deflate(8), -math.pi / 2, math.pi * 2 * value! / 100,
          false, paint..color = color);
    }
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      value != old.value || color != old.color || track != old.track;
}

class _HistoryPainter extends CustomPainter {
  const _HistoryPainter(
      this.samples, this.kind, this.color, this.track, this.maxGapSeconds);
  final List<MetricSample> samples;
  final MetricKind kind;
  final Color color;
  final Color track;
  final int maxGapSeconds;
  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    canvas.drawLine(Offset(0, size.height - 1),
        Offset(size.width, size.height - 1), Paint()..color = track);
    final start = samples.first.at.millisecondsSinceEpoch;
    final span = math.max(1, samples.last.at.millisecondsSinceEpoch - start);
    Offset? previous;
    DateTime? previousAt;
    for (final sample in samples) {
      final value = sample.of(kind);
      if (value == null || !value.isFinite || value < 0 || value > 1) {
        previous = null;
        previousAt = null;
        continue;
      }
      final p = Offset(
          (sample.at.millisecondsSinceEpoch - start) / span * size.width,
          2 + (size.height - 4) * (1 - value));
      // No interpolation across missing probes or long collector outages.
      if (previous != null &&
          sample.at.difference(previousAt!).inSeconds <= maxGapSeconds) {
        canvas.drawLine(
            previous,
            p,
            Paint()
              ..color = color
              ..strokeWidth = 2
              ..strokeCap = StrokeCap.round);
      }
      canvas.drawCircle(p, 2, Paint()..color = color);
      previous = p;
      previousAt = sample.at;
    }
  }

  @override
  bool shouldRepaint(_HistoryPainter old) =>
      samples != old.samples ||
      kind != old.kind ||
      color != old.color ||
      track != old.track;
}
