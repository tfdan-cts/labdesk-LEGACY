import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/console_rpc.dart';
import 'package:flutter_hbb/labdesk/models/machine_state.dart';
import 'package:flutter_hbb/labdesk/models/machine_metrics.dart';
import 'package:flutter_hbb/labdesk/models/machine_row.dart';

void main() {
  const row = MachineRow(
    id: '1180573903',
    hostname: 'workshop-pc',
    username: 'ops',
    platform: 'Linux',
    group: 'lab',
    status: LabDeskPeerStatus.online,
  );

  Metric byLabel(List<Metric> ms, String label) =>
      ms.firstWhere((m) => m.label == label);

  group('buildMachineHealth', () {
    test('identity comes from what the client already holds', () {
      final h = buildMachineHealth(machine: row, connected: false);
      expect(byLabel(h.identity, 'Hostname').value, 'workshop-pc');
      expect(byLabel(h.identity, 'Group').value, 'lab');
      expect(byLabel(h.identity, 'User').source, MetricSource.known);
    });

    test('with nothing measured, session and remote figures are absent, not zero',
        () {
      final h = buildMachineHealth(machine: row, connected: false);
      expect(h.session.every((m) => !m.isAvailable), isTrue);
      expect(h.remote.every((m) => !m.isAvailable), isTrue);
      expect(h.remote.map((m) => m.display).toSet(), {'--'});
    });

    test('session figures are read from the session window answer', () {
      final h = buildMachineHealth(
        machine: row,
        connected: true,
        sessionStats: {'delay': '12', 'speed': '1.2MB/s', 'fps': '30', 'codecFormat': 'H264'},
      );
      expect(byLabel(h.session, 'Round trip').value, '12');
      expect(byLabel(h.session, 'Round trip').unit, 'ms');
      expect(byLabel(h.session, 'Codec').source, MetricSource.session);
    });

    test('the machine figures are the hot row the collector sent', () {
      final h = buildMachineHealth(
        machine: row,
        connected: false,
        state: const MachineState(
            status: 'online', cpuPct: 7, memPct: 41, fsWorstPct: 93, uptimeS: 3600),
      );
      expect(byLabel(h.remote, 'CPU').ratio, closeTo(0.07, 1e-9));
      expect(byLabel(h.remote, 'Memory').source, MetricSource.collector);
      expect(byLabel(h.remote, 'Disk').value, '93');
      expect(byLabel(h.remote, 'Uptime').value, '1h 0m');
      // No session is needed for any of it: this is what WP18 changed.
      expect(h.connected, isFalse);
    });

    test('a machine that reported no readings shows placeholders, never zeros',
        () {
      final h = buildMachineHealth(
        machine: row,
        connected: true,
        state: const MachineState(status: 'unknown'),
      );
      expect(h.remote.length, 4);
      expect(h.remote.every((m) => !m.isAvailable), isTrue);
      expect(h.remote.map((m) => m.display).toSet(), {'--'});
    });
  });
}
