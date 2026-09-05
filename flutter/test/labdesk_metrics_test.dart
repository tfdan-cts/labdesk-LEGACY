import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/machine_metrics.dart';

void main() {
  group('Metric', () {
    test('an unavailable metric renders as absent, never as zero', () {
      const m = Metric.unavailable('CPU');
      expect(m.isAvailable, isFalse);
      expect(m.display, '--',
          reason: 'showing 0 would claim a measurement that was never taken');
    });

    test('an available metric renders its value', () {
      const m = Metric(label: 'Round trip', value: '18', unit: 'ms', source: MetricSource.session);
      expect(m.isAvailable, isTrue);
      expect(m.display, '18');
    });

    test('a metric with a null value is not available even if sourced', () {
      const m = Metric(label: 'CPU', value: null, source: MetricSource.collector);
      expect(m.isAvailable, isFalse);
      expect(m.display, '--');
    });
  });

  group('MachineHealth', () {
    test('counts only metrics that actually have a value', () {
      const h = MachineHealth(
        machineId: '1',
        connected: true,
        identity: [Metric(label: 'Host', value: 'nas', source: MetricSource.known)],
        session: [Metric.unavailable('Round trip')],
        remote: [Metric(label: 'CPU', value: '12', unit: '%', source: MetricSource.collector)],
      );
      expect(h.availableCount, 2);
    });

    test('a disconnected machine can still have identity metrics', () {
      const h = MachineHealth(
        machineId: '1',
        connected: false,
        identity: [Metric(label: 'Platform', value: 'linux', source: MetricSource.known)],
      );
      expect(h.connected, isFalse);
      expect(h.availableCount, 1);
    });
  });

  group('formatRate', () {
    test('scales through the units', () {
      expect(formatRate(0), '0 B/s');
      expect(formatRate(512), '512 B/s');
      expect(formatRate(1024), '1.0 KB/s');
      expect(formatRate(1536), '1.5 KB/s');
      expect(formatRate(1024 * 1024), '1.0 MB/s');
      expect(formatRate(1024 * 1024 * 20), '20 MB/s');
    });

    test('a negative rate is not rendered as a negative measurement', () {
      expect(formatRate(-5), '0 B/s');
    });
  });

  group('formatUptime', () {
    test('reads the way an operator expects', () {
      expect(formatUptime(0), '0m');
      expect(formatUptime(90), '1m');
      expect(formatUptime(3600 * 5 + 60 * 12), '5h 12m');
      expect(formatUptime(86400 * 3 + 3600 * 4), '3d 4h');
    });

    test('a negative uptime is absent, not zero', () {
      expect(formatUptime(-1), '--');
    });
  });
}
