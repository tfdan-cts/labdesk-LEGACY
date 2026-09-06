import 'automation_models.dart';

/// The rules a technician sets up first, ready made.
///
/// Writing a useful rule from an empty editor means knowing which figure to
/// pick, what a sensible threshold is and how long it has to hold. These are
/// the answers, as the working rules themselves: applying one drops a real
/// rule into the list, enabled, pointed at the whole fleet, and it can then be
/// edited like any other. Nothing here is a special kind of rule.
///
/// The set matches the technician presets of
/// `docs/plans/2026-09-05-002-phase1-contracts.md` section 8 where the console's
/// own trigger and action vocabulary can express them. `disk_failing` is not
/// here: it needs the `diskHealthBelow` trigger, which only the Worker's health
/// engine has, and a preset that could never fire would be worse than an
/// absent one.
class AutomationPreset {
  const AutomationPreset({
    required this.id,
    required this.title,
    required this.description,
    required this.trigger,
    required this.action,
    required this.cooldown,
  });

  /// The preset's stable name, the same one the Worker's rule presets use for
  /// the rules that exist on both sides.
  final String id;

  final String title;

  /// What it does and why that threshold, in one sentence for the operator
  /// choosing between them.
  final String description;

  final AutomationTrigger trigger;
  final AutomationAction action;
  final Duration cooldown;

  /// A real rule, with [ruleId] minted by the caller so the console's own id
  /// scheme stays in one place.
  Rule toRule(String ruleId) => Rule(
        id: ruleId,
        name: title,
        trigger: trigger,
        action: action,
        cooldown: cooldown,
      );

  static const all = <AutomationPreset>[
    AutomationPreset(
      id: 'disk_nearly_full',
      title: 'A disk is nearly full',
      description:
          'The fullest filesystem on a machine is over 90 percent. Left alone '
          'this is what stops updates and fills logs.',
      trigger: MetricAbove(metric: AutoMetric.disk, threshold: 90),
      action: Notify(message: 'The fullest filesystem is over 90 percent'),
      cooldown: Duration(hours: 1),
    ),
    AutomationPreset(
      id: 'offline_ten_minutes',
      title: 'Offline for ten minutes',
      description:
          'A machine has been unreachable for ten minutes without coming back, '
          'so a blip on the way past does not raise it.',
      trigger: WentOffline(forMinutes: 10),
      action: Notify(message: 'Offline for ten minutes'),
      cooldown: Duration(minutes: 10),
    ),
    AutomationPreset(
      id: 'memory_high',
      title: 'Memory above 90 percent',
      description:
          'Memory has held over 90 percent for fifteen minutes, which is a '
          'leak or a runaway rather than a busy moment.',
      trigger:
          MetricAbove(metric: AutoMetric.memory, threshold: 90, forMinutes: 15),
      action: Notify(message: 'Memory above 90 percent for fifteen minutes'),
      cooldown: Duration(minutes: 30),
    ),
    AutomationPreset(
      id: 'cpu_pegged',
      title: 'CPU pegged',
      description:
          'CPU has held over 95 percent for ten minutes. Long enough that a '
          'build or a scan has finished and something is genuinely stuck.',
      trigger:
          MetricAbove(metric: AutoMetric.cpu, threshold: 95, forMinutes: 10),
      action: Notify(message: 'CPU above 95 percent for ten minutes'),
      cooldown: Duration(minutes: 30),
    ),
    AutomationPreset(
      id: 'back_online_flush_dns',
      title: 'Flush DNS when a Windows machine comes back',
      description:
          'A machine that has just come back often holds stale DNS from the '
          'outage. Windows only; the rule skips anything else and says so.',
      trigger: CameOnline(),
      action: RunCommand(command: 'ipconfig /flushdns', platformHint: 'windows'),
      cooldown: Duration(minutes: 10),
    ),
  ];
}
