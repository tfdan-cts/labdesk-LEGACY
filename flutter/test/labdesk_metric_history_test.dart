import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/machine_metrics.dart';

void main() {
  final t0 = DateTime(2026, 9, 3, 12);

  group('MetricHistory', () {
    test('keeps samples in order and forgets the oldest past the cap', () {
      final h = MetricHistory(cap: 3);
      for (var i = 0; i < 5; i++) {
        h.add(MetricSample(at: t0.add(Duration(seconds: 30 * i)), cpu: i / 10));
      }
      expect(h.samples.map((s) => s.cpu), [0.2, 0.3, 0.4]);
      expect(h.samples.first.at, t0.add(const Duration(seconds: 60)));
    });

    test('series picks one figure and skips absent readings', () {
      final h = MetricHistory()
        ..add(MetricSample(at: t0, cpu: 0.1, memory: 0.5))
        ..add(MetricSample(at: t0.add(const Duration(seconds: 30)), memory: 0.6))
        ..add(MetricSample(at: t0.add(const Duration(seconds: 60)), cpu: 0.3, memory: 0.7));
      expect(h.series(MetricKind.cpu).map((p) => p.value), [0.1, 0.3]);
      expect(h.series(MetricKind.memory).length, 3);
      expect(h.series(MetricKind.disk), isEmpty);
    });
  });
}
