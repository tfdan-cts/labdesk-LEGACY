import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/dashboard_layout.dart';

DashboardWidgetSpec item(String id,
        {int x = 0, int y = 0, int width = 4, int height = 4}) =>
    DashboardWidgetSpec(
        id: id,
        report: DashboardReport.cpu,
        style: DashboardStyle.compact,
        x: x,
        y: y,
        width: width,
        height: height);
bool overlaps(DashboardWidgetSpec a, DashboardWidgetSpec b) =>
    a.x < b.x + b.width &&
    a.x + a.width > b.x &&
    a.y < b.y + b.height &&
    a.y + a.height > b.y;
Object snapshot(List<DashboardWidgetSpec> widgets) =>
    DashboardLayout(widgets: widgets).toJson();
void valid(List<DashboardWidgetSpec> widgets) {
  for (var i = 0; i < widgets.length; i++) {
    final a = widgets[i];
    expect(a.x, greaterThanOrEqualTo(0));
    expect(a.x + a.width, lessThanOrEqualTo(dashboardColumns));
    expect(a.y, greaterThanOrEqualTo(0));
    expect(a.y + a.height, lessThanOrEqualTo(dashboardMaxRows));
    expect(a.width, greaterThanOrEqualTo(a.minimumWidth));
    expect(a.height, inInclusiveRange(a.minimumHeight, 8));
    for (final b in widgets.skip(i + 1)) {
      expect(overlaps(a, b), isFalse, reason: '${a.id} overlaps ${b.id}');
    }
  }
}

void main() {
  test('compaction packing order survives persistence', () {
    final packed = compactDashboard([
      item('a', width: 9, height: 8),
      item('b', width: 9, height: 8),
      item('c', width: 3, height: 3),
    ]);
    expect(packed.map((w) => w.id), ['a', 'b', 'c']);
    final loaded = DashboardLayout.fromJson(snapshot(packed))!;
    expect(loaded.widgets.map((w) => w.id), ['a', 'b', 'c']);
    expect(snapshot(compactDashboard(loaded.widgets)), snapshot(packed));
  });
  test('fragmented ceiling collision repacks without dropping widgets', () {
    final items = [
      for (var i = 0; i < 34; i++)
        item('wall-$i', y: i * 15, width: 12, height: 8),
      item('last-wall', y: 504, width: 12, height: 8),
      item('new', y: 504, width: 12, height: 8)
    ];
    final arranged = arrangeDashboard(items, priorityId: 'last-wall');
    expect(arranged.length, 36);
    valid(arranged);
  });
  test('presets reproduce approved report styles and coordinates', () {
    final daily = dashboardPreset('everyday');
    expect(daily.widgets.length, 7);
    expect(daily.widgets.first.id, 'daily-machines');
    expect(daily.widgets.first.width, 8);
    expect(daily.widgets.last.y, 8);
    final tech = dashboardPreset('technician');
    expect(tech.widgets.length, 7);
    expect(tech.widgets[3].report, DashboardReport.trends);
    expect(tech.widgets[3].style, DashboardStyle.detailed);
    final ops = dashboardPreset('operations');
    expect(ops.widgets.length, 6);
    expect(ops.widgets.first.report, DashboardReport.fleets);
    for (final l in [daily, tech, ops]) {
      valid(l.widgets);
    }
    expect(dashboardPreset('unknown').preset, 'everyday');
  });
  test('move resize priority pushes collisions and leaves unrelated widgets',
      () {
    final original = item('a', width: 6);
    final moved = arrangeDashboard([
      original.copyWith(x: 6, height: 6),
      item('b', x: 6, width: 6),
      item('c', y: 4, width: 6)
    ], priorityId: 'a');
    valid(moved);
    expect(moved.singleWhere((w) => w.id == 'a').y, 0);
    expect(moved.singleWhere((w) => w.id == 'b').y, 6);
    expect(moved.singleWhere((w) => w.id == 'c').y, 4);
    expect(original.x, 0);
  });
  test('1000 seeded moves resizes and compactions remain bounded and stable',
      () {
    final random = Random(9219);
    var items = arrangeDashboard(List.generate(
        36,
        (i) => DashboardWidgetSpec(
            id: 'widget-$i',
            report: DashboardReport.values[i % 8],
            style: DashboardStyle.values[i % 3],
            x: i % 12,
            y: i ~/ 4 * 3)));
    for (var n = 0; n < 1000; n++) {
      final id = items[random.nextInt(items.length)].id;
      items = arrangeDashboard(
          items
              .map((w) => w.id == id
                  ? w.copyWith(
                      x: random.nextInt(18) - 3,
                      y: random.nextInt(700) - 30,
                      width: random.nextInt(18) - 3,
                      height: random.nextInt(14) - 3)
                  : w)
              .toList(),
          priorityId: id);
      valid(items);
      expect(snapshot(arrangeDashboard(items)), snapshot(items));
      if (n % 20 == 0) {
        final packed = compactDashboard(items);
        valid(packed);
        expect(snapshot(compactDashboard(packed)), snapshot(packed));
        expect({
          for (final w in packed) w.id: [w.width, w.height]
        }, {
          for (final w in items) w.id: [w.width, w.height]
        });
      }
    }
  });
  test('row ceiling packs all widgets into bounded free space', () {
    final items = arrangeDashboard(
        List.generate(
            36, (i) => item('widget-$i', y: 511, width: 12, height: 8)),
        priorityId: 'widget-35');
    valid(items);
    expect(items.length, 36);
    expect(items.singleWhere((w) => w.id == 'widget-35').y, 504);
  });
  test('Close gaps fills horizontal holes and preserves dimensions', () {
    final gap = [
      item('left', x: 4, height: 3),
      item('right', x: 8, height: 3),
      item('below', y: 20, height: 3)
    ];
    final packed = compactDashboard(gap);
    expect(packed.map((w) => [w.id, w.x, w.y]), [
      ['left', 0, 0],
      ['right', 4, 0],
      ['below', 8, 0]
    ]);
    expect(snapshot(compactDashboard(packed)), snapshot(packed));
    expect(gap.first.x, 4);
  });
  test('immutable machine scopes survive arrange compact JSON round trips', () {
    for (final scope in DashboardScope.values) {
      final ids = ['workstation-03', 'design-mac'];
      final original = item('scope').copyWith(scope: scope, machineIds: ids);
      ids.add('later');
      final layout = DashboardLayout(preset: 'technician', widgets: [original]);
      final decoded =
          DashboardLayout.fromJson(jsonDecode(jsonEncode(layout.toJson())))!;
      expect(decoded.toJson(), layout.toJson());
      expect(decoded.widgets.single.scope, scope);
      expect(
          decoded.widgets.single.machineIds, ['workstation-03', 'design-mac']);
      expect(compactDashboard(decoded.widgets).single.machineIds,
          original.machineIds);
      expect(() => original.machineIds.add('bad'), throwsUnsupportedError);
      expect(() => layout.widgets.clear(), throwsUnsupportedError);
    }
    expect(
        DashboardLayout.fromJson(
                {'version': 1, 'preset': 'everyday', 'widgets': []})!
            .widgets,
        isEmpty);
  });
  test(
      'malformed stored versions types sizes coordinates and identities reject',
      () {
    final good = DashboardLayout(widgets: [item('valid')]).toJson();
    final w =
        Map<String, Object?>.from((good['widgets'] as List).single as Map);
    for (final bad in [
      null,
      3,
      [],
      {},
      {...good, 'version': 2},
      {...good, 'version': 1.0},
      {...good, 'preset': 3},
      {...good, 'preset': 'unknown'},
      {...good, 'widgets': {}},
      {
        ...good,
        'widgets': [w, w]
      },
      {...good, 'widgets': List.filled(37, w)}
    ]) {
      expect(DashboardLayout.fromJson(bad), isNull, reason: '$bad');
    }
    for (final patch in <Map<String, Object?>>[
      {'id': ''},
      {'id': 'bad id'},
      {'id': 'x' * 61},
      {'report': 'script'},
      {'style': 'detail'},
      {'scope': 'global'},
      {'machineIds': 'machine'},
      {
        'machineIds': [null]
      },
      {
        'machineIds': ['']
      },
      {
        'machineIds': ['x' * 201]
      },
      {'machineIds': List.filled(501, 'machine')},
      {'x': double.nan},
      {'x': double.infinity},
      {'x': 1.5},
      {'x': '1'},
      {'x': -1},
      {'x': 12},
      {'y': -1},
      {'y': 512},
      {'width': 0},
      {'width': 13},
      {'height': 0},
      {'height': 9},
      {'height': null},
    ]) {
      expect(
          DashboardLayout.fromJson({
            ...good,
            'widgets': [
              {...w, ...patch}
            ]
          }),
          isNull,
          reason: '$patch');
    }
    for (final key in w.keys) {
      final missing = {...w}..remove(key);
      expect(
          DashboardLayout.fromJson({
            ...good,
            'widgets': [missing]
          }),
          isNull,
          reason: 'missing $key');
    }
  });
  test('runtime collection bounds and duplicate ids are enforced', () {
    expect(() => arrangeDashboard(List.filled(37, item('same'))),
        throwsArgumentError);
    expect(() => compactDashboard([item('same'), item('same')]),
        throwsArgumentError);
  });
}
