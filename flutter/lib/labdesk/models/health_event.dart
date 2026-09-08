/// A persisted service alert. Times on the wire are Unix seconds, including
/// the original acknowledgment when another operator got there first.
class HealthEvent {
  const HealthEvent({
    required this.id,
    required this.orgId,
    required this.at,
    required this.kind,
    required this.severity,
    required this.summary,
    this.machineId,
    this.detail,
    this.acknowledgedBy,
    this.acknowledgedAt,
  });

  final String id;
  final String orgId;
  final String? machineId;
  final DateTime at;
  final String kind;
  final String severity;
  final String summary;
  final String? detail;
  final String? acknowledgedBy;
  final DateTime? acknowledgedAt;

  static HealthEvent fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid alert');
    String text(String key, int limit) {
      final field = value[key];
      if (field is! String || field.isEmpty || field.length > limit) {
        throw FormatException('Invalid alert $key');
      }
      return field;
    }

    String? optionalText(String key, int limit) =>
        value[key] == null ? null : text(key, limit);

    DateTime timestamp(String key) {
      final field = value[key];
      if (field is! int || field < 0 || field > 8640000000000) {
        throw FormatException('Invalid alert $key');
      }
      return DateTime.fromMillisecondsSinceEpoch(field * 1000, isUtc: true);
    }

    return HealthEvent(
      id: text('id', 128),
      orgId: text('orgId', 128),
      machineId: optionalText('machineId', 128),
      at: timestamp('at'),
      kind: text('kind', 128),
      severity: text('severity', 64),
      summary: text('summary', 4096),
      detail: optionalText('detail', 65536),
      acknowledgedBy: optionalText('acknowledgedBy', 128),
      acknowledgedAt:
          value['acknowledgedAt'] == null ? null : timestamp('acknowledgedAt'),
    );
  }
}
