import 'machine_state.dart';

/// What LabDesk can actually report about a machine, and how it got it.
///
/// The distinction matters more than the numbers. Some of this is known for
/// any peer the ID server has heard of; the rest exists only while a session
/// is open, because the client has no agent on the far end and no server
/// retaining anything. A screen that renders both identically would be
/// claiming monitoring it does not have.
enum MetricSource {
  /// Known without connecting: identity the client already holds.
  known,

  /// Measured on the live connection: round trip, throughput, codec.
  session,

  /// Read from the machine's own collector, through lab-desk.net. The agent
  /// takes these readings on its own flush whether or not anybody is looking,
  /// so they exist for a machine nobody has a session to.
  collector,

  /// Not available. Rendered as such, never as zero.
  unavailable,
}

class Metric {
  const Metric({
    required this.label,
    required this.value,
    required this.source,
    this.unit,
    this.ratio,
  });

  const Metric.unavailable(this.label)
      : value = null,
        unit = null,
        ratio = null,
        source = MetricSource.unavailable;

  final String label;
  final String? value;
  final String? unit;

  /// 0..1 when the metric is a proportion of something, for a bar. Null when
  /// the number does not represent a share of a whole.
  final double? ratio;

  final MetricSource source;

  bool get isAvailable => source != MetricSource.unavailable && value != null;

  /// What to render when there is nothing. Never "0", which reads as a
  /// measurement of zero rather than an absence of one.
  String get display => isAvailable ? value! : '--';
}

/// Everything the Health screen shows for one machine.
class MachineHealth {
  const MachineHealth({
    required this.machineId,
    required this.connected,
    this.identity = const [],
    this.session = const [],
    this.remote = const [],
    this.state,
    this.history,
  });

  final String machineId;

  /// Whether a session is currently open. Almost everything interesting is
  /// gated on this, and the screen says so rather than showing blanks.
  final bool connected;

  final List<Metric> identity;
  final List<Metric> session;
  final List<Metric> remote;

  /// The hot row lab-desk.net holds, when the machine is one it knows. Null for
  /// a peer the server has never been told about, which is what the screens
  /// say rather than drawing an unenrolled machine as one with no readings.
  final MachineState? state;

  /// What lab-desk.net has stored of this machine over time, plus whatever the
  /// fleet poll has added since. Null when there is no history to draw.
  final MetricHistory? history;

  static const empty = MachineHealth(machineId: '', connected: false);

  /// Metrics that have a real value, for a quick "is there anything to show".
  int get availableCount =>
      [...identity, ...session, ...remote].where((m) => m.isAvailable).length;
}

/// Formats a byte rate for a fixed width column.
String formatRate(num bytesPerSecond) {
  if (bytesPerSecond <= 0) return '0 B/s';
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  var v = bytesPerSecond.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v < 10 && i > 0 ? v.toStringAsFixed(1) : v.round()} ${units[i]}';
}

/// Formats an uptime in seconds the way an operator reads it.
String formatUptime(int seconds) {
  if (seconds < 0) return '--';
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h';
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}

/// The three proportions a probe reads that are worth remembering over time.
/// Uptime is not one: it only ever climbs, and its history says nothing.
enum MetricKind { cpu, memory, disk }

class MetricPoint {
  const MetricPoint(this.at, this.value);
  final DateTime at;

  /// 0..1, the share of the whole at that moment.
  final double value;
}

/// One uplink's proportions, stamped with when the machine took them. Absent
/// readings stay absent; an uplink that carried none produces no sample at all
/// (`MachineState.sampleAt`).
class MetricSample {
  const MetricSample({required this.at, this.cpu, this.memory, this.disk});

  final DateTime at;
  final double? cpu;
  final double? memory;
  final double? disk;

  double? of(MetricKind k) => switch (k) {
        MetricKind.cpu => cpu,
        MetricKind.memory => memory,
        MetricKind.disk => disk,
      };
}

/// A bounded run of samples for one machine.
///
/// Filled from `GET /console/org/machines/:id/metrics`, which is the history
/// lab-desk.net kept while nobody was looking, and extended by each reading the
/// fleet poll brings back. The cap holds a day of hourly rows with room for the
/// raw windows over the last few hours.
class MetricHistory {
  MetricHistory({this.cap = 240});

  final int cap;
  final _samples = <MetricSample>[];

  List<MetricSample> get samples => List.unmodifiable(_samples);

  void add(MetricSample s) {
    _samples.add(s);
    if (_samples.length > cap) _samples.removeRange(0, _samples.length - cap);
  }

  /// One figure over time, skipping the probes that did not read it.
  List<MetricPoint> series(MetricKind k) => [
        for (final s in _samples)
          if (s.of(k) != null) MetricPoint(s.at, s.of(k)!),
      ];

  static final empty = MetricHistory(cap: 0);
}
