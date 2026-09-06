/// Rules the console runs against the fleet, and the words it says them in.
///
/// The honest shape of this feature is the thing to keep hold of while reading
/// it. There is no server and no agent on the far machines: a rule is evaluated
/// by the console's own tick, on this machine, while LabDesk is open. Nothing
/// here schedules anything anywhere else, and the screen that renders these
/// says so in a line the operator cannot miss.
///
/// Plain values with no Flutter and no FFI, so the engine that evaluates them
/// and the screen that draws them can both be tested without either.
library;

import 'dart:convert';

/// The three measured shares the probe returns that a rule can be built on.
///
/// Uptime is a measurement too, but it is a duration rather than a share of a
/// whole, so it gets its own trigger rather than being a fourth member here
/// with a percentage threshold that would mean nothing.
enum AutoMetric { cpu, memory, disk }

extension AutoMetricInfo on AutoMetric {
  /// The label the probe puts on this metric. Matching on it is how the engine
  /// finds the figure in a machine's metric list.
  String get label => switch (this) {
        AutoMetric.cpu => 'CPU',
        AutoMetric.memory => 'Memory',
        AutoMetric.disk => 'Disk',
      };

  /// How the metric reads inside a sentence, which is not always its label.
  String get phrase => switch (this) {
        AutoMetric.cpu => 'CPU',
        AutoMetric.memory => 'memory use',
        AutoMetric.disk => 'disk use',
      };
}

AutoMetric _metricFrom(Object? wire) => AutoMetric.values.firstWhere(
      (m) => m.name == wire,
      orElse: () => throw FormatException('unknown metric: $wire'),
    );

// ---------------------------------------------------------------------------
// Triggers
// ---------------------------------------------------------------------------

/// What makes a rule fire.
///
/// Sealed, so the engine's evaluation and the screen's sentence both have to
/// account for every kind: a trigger the engine silently ignored would be a
/// rule the operator wrote, saw listed as enabled, and that never ran.
sealed class AutomationTrigger {
  const AutomationTrigger();

  Map<String, dynamic> toJson();

  /// The trigger as the first half of a sentence, about [subject].
  String sentence(String subject);

  /// A short name for the kind, for the editor's chooser.
  String get kindLabel;

  static AutomationTrigger fromJson(Map<String, dynamic> j) {
    switch (j['kind']) {
      case 'cameOnline':
        return const CameOnline();
      case 'wentOffline':
        return WentOffline(forMinutes: (j['forMinutes'] as num?)?.toInt());
      case 'metricAbove':
        return MetricAbove(
          metric: _metricFrom(j['metric']),
          threshold: (j['threshold'] as num).toDouble(),
          forMinutes: (j['forMinutes'] as num?)?.toInt() ?? 0,
        );
      case 'uptimeAbove':
        return UptimeAbove(days: (j['days'] as num).toInt());
      case 'schedule':
        if (j['hour'] != null) {
          return Schedule.atTime(
            hour: (j['hour'] as num).toInt(),
            minute: (j['minute'] as num?)?.toInt() ?? 0,
            weekdays: [
              for (final d in (j['weekdays'] as List? ?? const []))
                (d as num).toInt(),
            ],
          );
        }
        return Schedule(
          every: Duration(seconds: (j['everySeconds'] as num).toInt()),
        );
      default:
        throw FormatException('unknown trigger: ${j['kind']}');
    }
  }
}

/// A machine the console watched go from offline to online.
///
/// Only that transition. A machine that is already online when the console
/// opens did not come online while anyone was watching, and neither did one
/// that appeared out of the unknown status, which means "nobody has asked yet"
/// rather than "it was down".
class CameOnline extends AutomationTrigger {
  const CameOnline();

  @override
  Map<String, dynamic> toJson() => {'kind': 'cameOnline'};

  @override
  String sentence(String subject) => 'When $subject comes online';

  @override
  String get kindLabel => 'Comes online';

  @override
  bool operator ==(Object other) => other is CameOnline;

  @override
  int get hashCode => 'cameOnline'.hashCode;
}

/// A machine the console watched go from online to offline.
///
/// [forMinutes] delays the firing until it has stayed offline that long
/// without interruption. A blip that comes back inside the window fires
/// nothing, which is the whole point of the option.
class WentOffline extends AutomationTrigger {
  const WentOffline({this.forMinutes});

  /// Null fires on the transition itself.
  final int? forMinutes;

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'wentOffline', if (forMinutes != null) 'forMinutes': forMinutes};

  @override
  String sentence(String subject) => forMinutes == null
      ? 'When $subject goes offline'
      : 'When $subject goes offline for ${_plural(forMinutes!, 'minute')}';

  @override
  String get kindLabel => 'Goes offline';

  @override
  bool operator ==(Object other) =>
      other is WentOffline && other.forMinutes == forMinutes;

  @override
  int get hashCode => Object.hash('wentOffline', forMinutes);
}

/// A measured share over a threshold, held for a while.
///
/// The figures are the machine's own, reported to lab-desk.net by its collector
/// and read back with the fleet, so every enrolled machine has them whether or
/// not anyone is connected to it. A machine the organization has not enrolled
/// reports nothing and a rule over it does not fire.
class MetricAbove extends AutomationTrigger {
  const MetricAbove({
    required this.metric,
    required this.threshold,
    this.forMinutes = 0,
  });

  final AutoMetric metric;

  /// A percentage, 0..100.
  final double threshold;

  /// How long it must hold. Zero fires as soon as the console sees it over.
  final int forMinutes;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'metricAbove',
        'metric': metric.name,
        'threshold': threshold,
        'forMinutes': forMinutes,
      };

  @override
  String sentence(String subject) {
    final head = "When $subject's ${metric.phrase} is above ${_pct(threshold)}";
    return forMinutes <= 0
        ? head
        : '$head for ${_plural(forMinutes, 'minute')}';
  }

  @override
  String get kindLabel => 'Metric above';

  @override
  bool operator ==(Object other) =>
      other is MetricAbove &&
      other.metric == metric &&
      other.threshold == threshold &&
      other.forMinutes == forMinutes;

  @override
  int get hashCode => Object.hash('metricAbove', metric, threshold, forMinutes);
}

/// A machine that has been up longer than [days], from the probe's uptime.
///
/// Fires once per boot: it clears when the machine comes back under the
/// threshold, which only happens when it restarts.
class UptimeAbove extends AutomationTrigger {
  const UptimeAbove({required this.days});

  final int days;

  @override
  Map<String, dynamic> toJson() => {'kind': 'uptimeAbove', 'days': days};

  @override
  String sentence(String subject) =>
      'When $subject has been up for more than ${_plural(days, 'day')}';

  @override
  String get kindLabel => 'Uptime above';

  @override
  bool operator ==(Object other) => other is UptimeAbove && other.days == days;

  @override
  int get hashCode => Object.hash('uptimeAbove', days);
}

/// The clock, either as an interval or as a time of day.
///
/// Both forms fire once per due slot and neither catches up. A console that was
/// closed over the weekend comes back and runs the next slot, not the sixty it
/// missed, because sixty simultaneous commands on a machine is not what anybody
/// meant by "every hour".
class Schedule extends AutomationTrigger {
  const Schedule({required Duration this.every})
      : hour = null,
        minute = null,
        weekdays = const [];

  const Schedule.atTime({
    required int this.hour,
    required int this.minute,
    this.weekdays = const [],
  }) : every = null;

  /// Set on the interval form.
  final Duration? every;

  /// Set on the time-of-day form.
  final int? hour;
  final int? minute;

  /// [DateTime.monday]..[DateTime.sunday]. Empty means every day.
  final List<int> weekdays;

  bool get isAtTime => hour != null;

  @override
  Map<String, dynamic> toJson() => isAtTime
      ? {
          'kind': 'schedule',
          'hour': hour,
          'minute': minute,
          'weekdays': weekdays,
        }
      : {'kind': 'schedule', 'everySeconds': every!.inSeconds};

  @override
  String sentence(String subject) {
    if (!isAtTime) return 'Every ${humanDuration(every!)}, on $subject';
    final at = '${_two(hour!)}:${_two(minute!)}';
    final days = weekdays.isEmpty
        ? 'Every day'
        : 'Every ${weekdays.map(weekdayName).join(', ')}';
    return '$days at $at, on $subject';
  }

  @override
  String get kindLabel => 'On a schedule';

  @override
  bool operator ==(Object other) =>
      other is Schedule &&
      other.every == every &&
      other.hour == hour &&
      other.minute == minute &&
      _sameInts(other.weekdays, weekdays);

  @override
  int get hashCode =>
      Object.hash('schedule', every, hour, minute, Object.hashAll(weekdays));
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

/// What a rule does when it fires.
///
/// Every member is something the console can actually carry out from this
/// machine with what it already has. Nothing here is aspirational.
sealed class AutomationAction {
  const AutomationAction();

  Map<String, dynamic> toJson();

  /// The action as the second half of a sentence.
  String get sentence;

  String get kindLabel;

  static AutomationAction fromJson(Map<String, dynamic> j) {
    switch (j['kind']) {
      case 'runCommand':
        return RunCommand(
          command: (j['command'] as String?) ?? '',
          platformHint: j['platformHint'] as String?,
        );
      case 'notify':
        return Notify(message: (j['message'] as String?) ?? '');
      case 'wakeOnLan':
        return const WakeOnLan();
      case 'openSession':
        return const OpenSession();
      default:
        throw FormatException('unknown action: ${j['kind']}');
    }
  }
}

/// Run one command in the machine's shell, over the same headless link the
/// health probe uses.
class RunCommand extends AutomationAction {
  const RunCommand({required this.command, this.platformHint});

  final String command;

  /// Only run on machines whose platform starts with this, case insensitively.
  /// A shell line is rarely portable, and running a Linux one against Windows
  /// produces a failure the operator then has to read.
  final String? platformHint;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'runCommand',
        'command': command,
        if (platformHint != null) 'platformHint': platformHint,
      };

  @override
  String get sentence {
    final hint = platformHint;
    final tail = hint == null || hint.isEmpty ? '' : ' (on $hint only)';
    return 'run "$command"$tail';
  }

  @override
  String get kindLabel => 'Run a command';

  @override
  bool operator ==(Object other) =>
      other is RunCommand &&
      other.command == command &&
      other.platformHint == platformHint;

  @override
  int get hashCode => Object.hash('runCommand', command, platformHint);
}

/// Put a line in the console's notification list and raise a toast.
class Notify extends AutomationAction {
  const Notify({required this.message});

  final String message;

  @override
  Map<String, dynamic> toJson() => {'kind': 'notify', 'message': message};

  @override
  String get sentence => message.isEmpty ? 'notify' : 'notify: "$message"';

  @override
  String get kindLabel => 'Notify';

  @override
  bool operator ==(Object other) => other is Notify && other.message == message;

  @override
  int get hashCode => Object.hash('notify', message);
}

/// Send the magic packet. Only useful on a machine that is off, which is why
/// it pairs with [WentOffline] rather than with a metric.
class WakeOnLan extends AutomationAction {
  const WakeOnLan();

  @override
  Map<String, dynamic> toJson() => {'kind': 'wakeOnLan'};

  @override
  String get sentence => 'send Wake-on-LAN';

  @override
  String get kindLabel => 'Wake-on-LAN';

  @override
  bool operator ==(Object other) => other is WakeOnLan;

  @override
  int get hashCode => 'wakeOnLan'.hashCode;
}

/// Open a desktop session in its own window. Loud on purpose: a rule that
/// throws windows at the operator is one they will notice and reconsider.
class OpenSession extends AutomationAction {
  const OpenSession();

  @override
  Map<String, dynamic> toJson() => {'kind': 'openSession'};

  @override
  String get sentence => 'open a desktop session';

  @override
  String get kindLabel => 'Open a session';

  @override
  bool operator ==(Object other) => other is OpenSession;

  @override
  int get hashCode => 'openSession'.hashCode;
}

// ---------------------------------------------------------------------------
// Rule
// ---------------------------------------------------------------------------

/// One rule: a trigger, an action, the machines it applies to, and how often it
/// is allowed to repeat itself.
class Rule {
  const Rule({
    required this.id,
    required this.name,
    required this.trigger,
    required this.action,
    this.enabled = true,
    this.targets = const [allTargets],
    this.cooldown = const Duration(minutes: 10),
  });

  /// The sentinel that stands in [targets] for the whole fleet. Kept as a
  /// value inside the list rather than as a separate flag so a rule has exactly
  /// one place that says what it points at.
  static const allTargets = 'all';

  final String id;
  final String name;
  final bool enabled;
  final AutomationTrigger trigger;
  final AutomationAction action;
  final List<String> targets;

  /// The shortest gap between two firings of this rule against one machine.
  /// Zero lets it fire on consecutive ticks, which for an edge trigger is
  /// harmless and for a schedule is impossible.
  final Duration cooldown;

  bool get targetsAll => targets.contains(allTargets);

  Rule copyWith({
    String? id,
    String? name,
    bool? enabled,
    AutomationTrigger? trigger,
    AutomationAction? action,
    List<String>? targets,
    Duration? cooldown,
  }) =>
      Rule(
        id: id ?? this.id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        trigger: trigger ?? this.trigger,
        action: action ?? this.action,
        targets: targets ?? this.targets,
        cooldown: cooldown ?? this.cooldown,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'trigger': trigger.toJson(),
        'action': action.toJson(),
        'targets': targets,
        'cooldownSeconds': cooldown.inSeconds,
      };

  factory Rule.fromJson(Map<String, dynamic> j) => Rule(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        enabled: j['enabled'] as bool? ?? true,
        trigger: AutomationTrigger.fromJson(
            Map<String, dynamic>.from(j['trigger'] as Map)),
        action: AutomationAction.fromJson(
            Map<String, dynamic>.from(j['action'] as Map)),
        targets: [
          for (final t in (j['targets'] as List? ?? const [])) t as String,
        ],
        cooldown: Duration(seconds: (j['cooldownSeconds'] as num?)?.toInt() ?? 0),
      );

  /// The rule as one line, resolving machine ids through [nameOf].
  String sentence(String Function(String machineId) nameOf) =>
      '${trigger.sentence(subject(nameOf))} → ${action.sentence}';

  /// What the sentence calls the machines this rule points at.
  String subject(String Function(String machineId) nameOf) {
    if (targetsAll) return 'any machine';
    final named = targets.where((t) => t != allTargets).toList();
    if (named.isEmpty) return 'no machine';
    if (named.length == 1) return nameOf(named.first);
    if (named.length == 2) return '${nameOf(named[0])} or ${nameOf(named[1])}';
    return '${named.length} machines';
  }

  @override
  bool operator ==(Object other) =>
      other is Rule &&
      other.id == id &&
      other.name == name &&
      other.enabled == enabled &&
      other.trigger == trigger &&
      other.action == action &&
      other.cooldown == cooldown &&
      _sameStrings(other.targets, targets);

  @override
  int get hashCode => Object.hash(
      id, name, enabled, trigger, action, cooldown, Object.hashAll(targets));
}

/// The whole list as one string, for the local option the client persists it
/// in. A list rather than an object so appending a rule never rewrites the
/// shape of the stored value.
String encodeRules(List<Rule> rules) =>
    jsonEncode([for (final r in rules) r.toJson()]);

/// Read the list back.
///
/// A rule that will not parse is dropped rather than taking the rest of the
/// list with it: one bad entry from an older build must not silently disable
/// every rule the operator wrote.
List<Rule> decodeRules(String raw) {
  if (raw.trim().isEmpty) return const [];
  final List<dynamic> list;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    list = decoded;
  } catch (_) {
    return const [];
  }
  final out = <Rule>[];
  for (final entry in list) {
    if (entry is! Map) continue;
    try {
      out.add(Rule.fromJson(Map<String, dynamic>.from(entry)));
    } catch (_) {
      continue;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Wording helpers, shared by the sentences and the screen.
// ---------------------------------------------------------------------------

String _two(int n) => n.toString().padLeft(2, '0');

String _pct(double v) =>
    '${v == v.roundToDouble() ? v.round() : v.toStringAsFixed(1)}%';

String _plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String weekdayName(int weekday) =>
    weekday >= 1 && weekday <= 7 ? _weekdayNames[weekday - 1] : '?';

/// A duration in the words an operator would use for it.
String humanDuration(Duration d) {
  if (d.inSeconds < 60) return _plural(d.inSeconds, 'second');
  if (d.inMinutes < 60) return _plural(d.inMinutes, 'minute');
  if (d.inHours < 24) return _plural(d.inHours, 'hour');
  return _plural(d.inDays, 'day');
}

bool _sameStrings(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameInts(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
