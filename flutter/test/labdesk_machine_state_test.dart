import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/machine_metrics.dart';
import 'package:flutter_hbb/labdesk/models/machine_state.dart';

/// The hot row and the stored history, as lab-desk.net answers them
/// (docs/plans/2026-09-05-002-phase1-contracts.md section 5). These are the
/// figures the console draws now that the terminal probe is gone.
void main() {
  group('MachineState', () {
    test('reads the state answer and keeps an absent reading absent', () {
      final s = MachineState.fromJson(const {
        'machineId': 'm1',
        'status': 'online',
        'seenAt': 1788480300,
        'flushSeconds': 300,
        'cpuPct': 7,
        'memPct': null,
        'fsWorstPct': 93,
        'uptimeS': 90061,
        'loggedInUser': 'dan',
        'agentVersion': '1.2.6',
        'worstDisk': 'warn',
      });
      expect(s.isOnline, isTrue);
      expect(s.cpuPct, 7);
      expect(s.memPct, isNull);
      expect(s.loggedInUser, 'dan');

      final metrics = {for (final m in s.metrics()) m.label: m};
      expect(metrics['CPU']!.value, '7');
      expect(metrics['CPU']!.source, MetricSource.collector);
      expect(metrics['Disk']!.ratio, closeTo(0.93, 1e-9));
      // A null column is a reading nobody took, never a zero.
      expect(metrics['Memory']!.isAvailable, isFalse);
      expect(metrics['Memory']!.display, '--');
      expect(metrics['Uptime']!.value, '1d 1h');
    });

    test('a machine with no row at all is unknown and reads nothing', () {
      final s = MachineState.fromJson(const {'status': 'unknown'});
      expect(s.isOnline, isFalse);
      expect(s.metrics().every((m) => !m.isAvailable), isTrue);
      expect(s.sampleAt(DateTime(2026, 9, 5)), isNull);
    });

    test('the per-machine read fills in what the fleet answer does not carry',
        () {
      const detail = MachineState(
          status: 'online', uptimeS: 7200, loggedInUser: 'dan', cpuPct: 1);
      const fleet =
          MachineState(status: 'offline', cpuPct: 9, memPct: 20, seenAt: 5);
      final merged = detail.mergeDetail(fleet);
      // The fleet answer is the fresher one for everything it holds.
      expect(merged.status, 'offline');
      expect(merged.cpuPct, 9);
      expect(merged.seenAt, 5);
      // And the detail keeps what the fleet answer never carries.
      expect(merged.uptimeS, 7200);
      expect(merged.loggedInUser, 'dan');
    });
  });

  test('the stored history reads both resolutions, oldest first', () {
    final samples = parseMetricHistory(const {
      'step': 60,
      'batches': [
        {
          'from': 1788480000,
          'to': 1788480240,
          'samples': [
            [7, 42, 55, 1000, 2000],
            [null, 44, 55, 1100, 2100],
          ],
        }
      ],
      'hours': [
        {'hourAt': 1788476400, 'cpuAvg': 6.5, 'memAvg': 41, 'fsWorstMax': 55},
      ],
    });
    expect(samples.length, 3);
    // The hourly fold is older than the raw window, and sorting says so.
    expect(samples.first.cpu, closeTo(0.065, 1e-9));
    expect(samples[1].cpu, closeTo(0.07, 1e-9));
    // A null in the packed row stays null rather than becoming a zero reading.
    expect(samples[2].cpu, isNull);
    expect(samples[2].memory, closeTo(0.44, 1e-9));
    expect(samples[2].at.isAfter(samples[1].at), isTrue);
  });
}
