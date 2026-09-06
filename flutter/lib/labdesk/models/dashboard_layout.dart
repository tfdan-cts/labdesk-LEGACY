/// Dashboard geometry and local preference schema, independent of Flutter.
const dashboardColumns = 12;
const dashboardMaxWidgets = 36;
const dashboardMaxRows = 512;
const _presets = ['everyday', 'technician', 'operations'];
final _widgetId = RegExp(r'^[a-z0-9-]{1,60}$');

enum DashboardReport {
  availability,
  cpu,
  memory,
  disk,
  trends,
  attention,
  fleets,
  freshness
}

enum DashboardStyle { visual, compact, detailed }

enum DashboardScope { fleet, single, multiple, average }

class DashboardWidgetSpec {
  DashboardWidgetSpec({
    required this.id,
    required this.report,
    this.style = DashboardStyle.visual,
    this.scope = DashboardScope.fleet,
    List<String> machineIds = const [],
    this.x = 0,
    this.y = 0,
    this.width = 4,
    this.height = 4,
  }) : machineIds = List.unmodifiable(machineIds);

  final String id;
  final DashboardReport report;
  final DashboardStyle style;
  final DashboardScope scope;
  final List<String> machineIds;
  final int x;
  final int y;
  final int width;
  final int height;

  int get minimumWidth => report == DashboardReport.trends ||
          (report == DashboardReport.availability &&
              style == DashboardStyle.visual)
      ? 6
      : 3;
  int get minimumHeight => style == DashboardStyle.compact ? 3 : 4;

  DashboardWidgetSpec copyWith(
          {String? id,
          DashboardReport? report,
          DashboardStyle? style,
          DashboardScope? scope,
          List<String>? machineIds,
          int? x,
          int? y,
          int? width,
          int? height}) =>
      DashboardWidgetSpec(
        id: id ?? this.id,
        report: report ?? this.report,
        style: style ?? this.style,
        scope: scope ?? this.scope,
        machineIds: machineIds ?? this.machineIds,
        x: x ?? this.x,
        y: y ?? this.y,
        width: width ?? this.width,
        height: height ?? this.height,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'report': report.name,
        'style': style.name,
        'scope': scope.name,
        'machineIds': machineIds.toList(),
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };
}

class DashboardLayout {
  DashboardLayout(
      {this.preset = 'everyday', required List<DashboardWidgetSpec> widgets})
      : widgets = List.unmodifiable(widgets) {
    if (!_presets.contains(preset)) throw ArgumentError.value(preset, 'preset');
    _checkWidgets(this.widgets);
  }

  final String preset;
  final List<DashboardWidgetSpec> widgets;

  DashboardLayout copyWith(
          {String? preset, List<DashboardWidgetSpec>? widgets}) =>
      DashboardLayout(
          preset: preset ?? this.preset, widgets: widgets ?? this.widgets);

  Map<String, Object?> toJson() => {
        'version': 1,
        'preset': preset,
        'widgets': widgets.map((w) => w.toJson()).toList(),
      };

  /// Invalid preferences return null so callers can load a known preset.
  static DashboardLayout? fromJson(Object? value) {
    if (value is! Map ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['preset'] is! String ||
        !_presets.contains(value['preset'])) return null;
    final stored = value['widgets'];
    if (stored is! List || stored.length > dashboardMaxWidgets) return null;
    final seen = <String>{};
    final widgets = <DashboardWidgetSpec>[];
    for (final entry in stored) {
      if (entry is! Map) return null;
      final id = entry['id'];
      final machineIds = entry['machineIds'];
      if (id is! String ||
          id.length > 60 ||
          !_widgetId.hasMatch(id) ||
          !seen.add(id) ||
          !DashboardReport.values.any((r) => r.name == entry['report']) ||
          !DashboardStyle.values.any((s) => s.name == entry['style']) ||
          !DashboardScope.values.any((s) => s.name == entry['scope']) ||
          machineIds is! List ||
          machineIds.length > 500 ||
          machineIds.any((m) => m is! String || m.isEmpty || m.length > 200)) {
        return null;
      }
      for (final field in ['x', 'y', 'width', 'height']) {
        final coordinate = entry[field];
        final max = field == 'y'
            ? dashboardMaxRows - 1
            : field == 'x'
                ? dashboardColumns - 1
                : field == 'width'
                    ? dashboardColumns
                    : 8;
        final min = field == 'width' || field == 'height' ? 1 : 0;
        if (coordinate is! int || coordinate < min || coordinate > max) {
          return null;
        }
      }
      widgets.add(DashboardWidgetSpec(
        id: id,
        report: DashboardReport.values.byName(entry['report'] as String),
        style: DashboardStyle.values.byName(entry['style'] as String),
        scope: DashboardScope.values.byName(entry['scope'] as String),
        machineIds: machineIds.cast<String>().toSet().toList(),
        x: entry['x'] as int,
        y: entry['y'] as int,
        width: entry['width'] as int,
        height: entry['height'] as int,
      ));
    }
    final arranged = {for (final w in arrangeDashboard(widgets)) w.id: w};
    return DashboardLayout(
        preset: value['preset'] as String,
        widgets: [for (final w in widgets) arranged[w.id]!]);
  }
}

void _checkWidgets(List<DashboardWidgetSpec> widgets) {
  if (widgets.length > dashboardMaxWidgets) {
    throw ArgumentError(
        'Dashboard supports at most $dashboardMaxWidgets widgets');
  }
  final seen = <String>{};
  for (final w in widgets) {
    if (w.id.length > 60 ||
        !_widgetId.hasMatch(w.id) ||
        !seen.add(w.id) ||
        w.machineIds.length > 500 ||
        w.machineIds.any((id) => id.isEmpty || id.length > 200)) {
      throw ArgumentError('Invalid or duplicate dashboard widget identity');
    }
  }
}

DashboardWidgetSpec _clean(DashboardWidgetSpec w) {
  final width = w.width.clamp(w.minimumWidth, dashboardColumns);
  final height = w.height.clamp(w.minimumHeight, 8);
  return w.copyWith(
      width: width,
      height: height,
      x: w.x.clamp(0, dashboardColumns - width),
      y: w.y.clamp(0, dashboardMaxRows - height));
}

bool _overlaps(DashboardWidgetSpec a, DashboardWidgetSpec b) =>
    a.x < b.x + b.width &&
    a.x + a.width > b.x &&
    a.y < b.y + b.height &&
    a.y + a.height > b.y;

List<DashboardWidgetSpec> _ordered(Iterable<DashboardWidgetSpec> widgets) =>
    widgets.toList()
      ..sort((a, b) {
        final row = a.y.compareTo(b.y);
        if (row != 0) return row;
        final column = a.x.compareTo(b.x);
        return column != 0 ? column : a.id.compareTo(b.id);
      });

DashboardWidgetSpec? _firstFit(
    DashboardWidgetSpec source, List<DashboardWidgetSpec> placed) {
  for (var y = 0; y <= dashboardMaxRows - source.height; y++) {
    for (var x = 0; x <= dashboardColumns - source.width; x++) {
      if (!placed.any((other) =>
          x < other.x + other.width &&
          x + source.width > other.x &&
          y < other.y + other.height &&
          y + source.height > other.y)) {
        return source.copyWith(x: x, y: y);
      }
    }
  }
  return null;
}

/// Keep the moved/resized widget in place and push its collisions downward.
List<DashboardWidgetSpec> arrangeDashboard(List<DashboardWidgetSpec> widgets,
    {String? priorityId}) {
  _checkWidgets(widgets);
  final sorted = _ordered(widgets.map(_clean));
  final priority = sorted.indexWhere((w) => w.id == priorityId);
  if (priority > 0) sorted.insert(0, sorted.removeAt(priority));
  final result = <DashboardWidgetSpec>[];
  for (var item in sorted) {
    // Each collision moves below at least one previous widget, never back up.
    for (var attempt = 0; attempt <= result.length; attempt++) {
      var nextY = item.y;
      for (final other in result) {
        if (_overlaps(item, other) && other.y + other.height > nextY) {
          nextY = other.y + other.height;
        }
      }
      if (nextY == item.y) break;
      if (nextY + item.height > dashboardMaxRows) {
        final free = _firstFit(item, result);
        // Fragmented space can have enough area but no rectangle large enough.
        if (free == null) {
          return List.unmodifiable(_ordered(compactDashboard(sorted)));
        }
        item = free;
        break;
      }
      item = item.copyWith(y: nextY);
    }
    result.add(item);
  }
  return List.unmodifiable(_ordered(result));
}

/// Row-major first fit closes horizontal holes as well as empty rows.
/// Preserve list order: sorting the packed result would change the next packing.
List<DashboardWidgetSpec> compactDashboard(List<DashboardWidgetSpec> widgets) {
  _checkWidgets(widgets);
  final result = <DashboardWidgetSpec>[];
  for (final source in widgets.map(_clean)) {
    // First-fit packing from an empty grid uses at most 36 * 8 rows.
    result.add(_firstFit(source, result)!);
  }
  return List.unmodifiable(result);
}

DashboardLayout dashboardPreset(String preset) {
  final key = _presets.contains(preset) ? preset : 'everyday';
  DashboardWidgetSpec w(String id, DashboardReport report, DashboardStyle style,
          int x, int y, int width, int height) =>
      DashboardWidgetSpec(
          id: id,
          report: report,
          style: style,
          x: x,
          y: y,
          width: width,
          height: height);
  final List<DashboardWidgetSpec> widgets;
  switch (key) {
    case 'technician':
      widgets = [
        w('tech-online', DashboardReport.availability, DashboardStyle.compact,
            0, 0, 4, 3),
        w('tech-cpu', DashboardReport.cpu, DashboardStyle.compact, 4, 0, 4, 3),
        w('tech-memory', DashboardReport.memory, DashboardStyle.compact, 8, 0,
            4, 3),
        w('tech-history', DashboardReport.trends, DashboardStyle.detailed, 0, 3,
            8, 4),
        w('tech-storage', DashboardReport.disk, DashboardStyle.detailed, 8, 3,
            4, 4),
        w('tech-reports', DashboardReport.freshness, DashboardStyle.detailed, 0,
            7, 6, 4),
        w('tech-issues', DashboardReport.attention, DashboardStyle.detailed, 6,
            7, 6, 4),
      ];
      break;
    case 'operations':
      widgets = [
        w('ops-fleets', DashboardReport.fleets, DashboardStyle.visual, 0, 0, 7,
            4),
        w('ops-attention', DashboardReport.attention, DashboardStyle.visual, 7,
            0, 5, 4),
        w('ops-history', DashboardReport.trends, DashboardStyle.visual, 0, 4, 8,
            4),
        w('ops-coverage', DashboardReport.availability, DashboardStyle.compact,
            8, 4, 4, 4),
        w('ops-resources', DashboardReport.fleets, DashboardStyle.detailed, 0,
            8, 7, 4),
        w('ops-freshness', DashboardReport.freshness, DashboardStyle.visual, 7,
            8, 5, 4),
      ];
      break;
    default:
      widgets = [
        w('daily-machines', DashboardReport.availability, DashboardStyle.visual,
            0, 0, 8, 4),
        w('daily-attention', DashboardReport.attention, DashboardStyle.visual,
            8, 0, 4, 4),
        w('daily-cpu', DashboardReport.cpu, DashboardStyle.visual, 0, 4, 4, 4),
        w('daily-memory', DashboardReport.memory, DashboardStyle.visual, 4, 4,
            4, 4),
        w('daily-storage', DashboardReport.disk, DashboardStyle.visual, 8, 4, 4,
            4),
        w('daily-history', DashboardReport.trends, DashboardStyle.visual, 0, 8,
            8, 4),
        w('daily-reporting', DashboardReport.freshness, DashboardStyle.visual,
            8, 8, 4, 4),
      ];
  }
  return DashboardLayout(preset: key, widgets: widgets);
}
