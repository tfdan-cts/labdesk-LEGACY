import 'machine_metrics.dart';

/// What lab-desk.net holds about one machine right now.
///
/// This is the hot row the agent's own collector writes every flush
/// (`machine_state`), read back by `GET /console/org/machines?state=1` for the
/// whole fleet and by `GET /console/org/machines/:id/state` for one machine
/// (docs/plans/2026-09-05-002-phase1-contracts.md section 5).
///
/// Every reading is nullable and stays null when the column is null. Zero is
/// never substituted: a machine whose agent could not read its memory is not a
/// machine using no memory.
class MachineState {
  const MachineState({
    this.status = 'unknown',
    this.seenAt,
    this.flushSeconds,
    this.cpuPct,
    this.memPct,
    this.fsWorstPct,
    this.uptimeS,
    this.loggedInUser,
    this.agentVersion,
    this.worstDisk,
  });

  /// `online`, `offline` or `unknown`, the one reachability rule every console
  /// uses. Computed by the Worker from `seenAt` and the machine's flush.
  final String status;

  /// Unix seconds of the last uplink, or null when the machine has never sent
  /// one.
  final int? seenAt;
  final int? flushSeconds;

  /// Percentages, 0..100.
  final num? cpuPct;
  final num? memPct;

  /// The fullest filesystem, not the root one.
  final num? fsWorstPct;

  final int? uptimeS;
  final String? loggedInUser;
  final String? agentVersion;

  /// The worst verdict over the machine's drives: `ok`, `warn`, `failing` or
  /// `unreadable`. `unreadable` is its own state and is never drawn as healthy.
  final String? worstDisk;

  bool get isOnline => status == 'online';

  static num? _num(Object? v) => v is num ? v : null;
  static int? _int(Object? v) => v is num ? v.toInt() : null;
  static String? _str(Object? v) =>
      v is String && v.isNotEmpty ? v : null;

  /// Reads either shape: the per-machine `/state` answer and one row of the
  /// `?state=1` inventory carry the same keys, the inventory simply carrying
  /// fewer of them.
  static MachineState fromJson(Map<dynamic, dynamic> j) => MachineState(
        status: j['status'] is String ? j['status'] as String : 'unknown',
        seenAt: _int(j['seenAt']),
        flushSeconds: _int(j['flushSeconds']),
        cpuPct: _num(j['cpuPct']),
        memPct: _num(j['memPct']),
        fsWorstPct: _num(j['fsWorstPct']),
        uptimeS: _int(j['uptimeS']),
        loggedInUser: _str(j['loggedInUser']),
        agentVersion: _str(j['agentVersion']),
        worstDisk: _str(j['worstDisk']),
      );

  /// Fills in what the fleet answer does not carry from a later per-machine
  /// read, so a round-robin detail poll does not blank the figures the
  /// inventory refreshes every fifteen seconds.
  MachineState mergeDetail(MachineState detail) => MachineState(
        status: detail.status,
        seenAt: detail.seenAt ?? seenAt,
        flushSeconds: detail.flushSeconds ?? flushSeconds,
        cpuPct: detail.cpuPct ?? cpuPct,
        memPct: detail.memPct ?? memPct,
        fsWorstPct: detail.fsWorstPct ?? fsWorstPct,
        uptimeS: detail.uptimeS ?? uptimeS,
        loggedInUser: detail.loggedInUser ?? loggedInUser,
        agentVersion: detail.agentVersion ?? agentVersion,
        worstDisk: detail.worstDisk ?? worstDisk,
      );

  /// The four figures the health board draws, in the order it draws them.
  ///
  /// Labels are the ones the automation engine matches on, so a rule written
  /// against `Memory` keeps working now that the reading comes from the
  /// collector instead of a terminal probe.
  List<Metric> metrics() {
    Metric share(String label, num? pct) {
      if (pct == null) return Metric.unavailable(label);
      final ratio = (pct / 100).clamp(0.0, 1.0);
      return Metric(
        label: label,
        value: pct.round().toString(),
        unit: '%',
        ratio: ratio,
        source: MetricSource.collector,
      );
    }

    return [
      share('CPU', cpuPct),
      share('Memory', memPct),
      share('Disk', fsWorstPct),
      uptimeS == null
          ? const Metric.unavailable('Uptime')
          : Metric(
              label: 'Uptime',
              value: formatUptime(uptimeS!),
              source: MetricSource.collector,
            ),
    ];
  }

  /// One sample for the history, or null when the uplink carried no readings
  /// at all. Absent readings stay absent rather than becoming zero.
  MetricSample? sampleAt(DateTime at) {
    if (cpuPct == null && memPct == null && fsWorstPct == null) return null;
    return MetricSample(
      at: at,
      cpu: cpuPct == null ? null : (cpuPct! / 100).clamp(0.0, 1.0).toDouble(),
      memory: memPct == null ? null : (memPct! / 100).clamp(0.0, 1.0).toDouble(),
      disk: fsWorstPct == null
          ? null
          : (fsWorstPct! / 100).clamp(0.0, 1.0).toDouble(),
    );
  }
}

/// The stored history of one machine, as `GET /console/org/machines/:id/metrics`
/// answers it (contract section 5).
///
/// Two resolutions arrive together: `batches` are the packed raw windows the
/// collector sent, `hours` the cron's fold. The raw windows are preferred where
/// they exist because they are what the sparkline was drawn from before, and
/// the hourly rows fill in anything older.
///
/// The packing is the collector's own, `[cpu, memPct, fsWorstPct, netRx,
/// netTx]` with nulls preserved (`collector.rs::pack`).
List<MetricSample> parseMetricHistory(Map<dynamic, dynamic> j) {
  final out = <MetricSample>[];
  double? share(Object? v) =>
      v is num ? (v / 100).clamp(0.0, 1.0).toDouble() : null;

  for (final h in (j['hours'] as List? ?? const [])) {
    if (h is! Map) continue;
    final at = h['hourAt'];
    if (at is! num) continue;
    out.add(MetricSample(
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt() * 1000, isUtc: true)
          .toLocal(),
      cpu: share(h['cpuAvg']),
      memory: share(h['memAvg']),
      disk: share(h['fsWorstMax']),
    ));
  }

  for (final b in (j['batches'] as List? ?? const [])) {
    if (b is! Map) continue;
    final from = b['from'];
    final samples = b['samples'];
    if (from is! num || samples is! List || samples.isEmpty) continue;
    // The window is evenly spaced across the samples it carries, which is what
    // the collector's own step means. `to` is used rather than assumed so a
    // short final window is not stretched over a full one.
    final to = b['to'] is num ? (b['to'] as num).toInt() : from.toInt();
    final span = to - from.toInt();
    for (var i = 0; i < samples.length; i++) {
      final row = samples[i];
      if (row is! List || row.isEmpty) continue;
      final offset = samples.length == 1
          ? 0
          : (span * i / (samples.length - 1)).round();
      out.add(MetricSample(
        at: DateTime.fromMillisecondsSinceEpoch(
                (from.toInt() + offset) * 1000,
                isUtc: true)
            .toLocal(),
        cpu: share(row.length > 0 ? row[0] : null),
        memory: share(row.length > 1 ? row[1] : null),
        disk: share(row.length > 2 ? row[2] : null),
      ));
    }
  }

  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}
