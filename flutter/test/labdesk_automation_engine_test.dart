import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/models/automation_models.dart';
import 'package:flutter_hbb/labdesk/models/machine_metrics.dart';
import 'package:flutter_hbb/labdesk/services/automation_engine.dart';

/// The automation engine decides when to run commands on other people's
/// machines. Everything here is about the ways that could be wrong: firing on
/// state that was never observed, firing repeatedly on a condition that has not
/// changed, and replaying a day of missed schedules the moment the console
/// opens. Each one of those is a real command on a real machine, so each one
/// gets a test with a clock that does not move on its own.

const _online = LabDeskPeerStatus.online;
const _offline = LabDeskPeerStatus.offline;
const _unknown = LabDeskPeerStatus.unknown;

/// A Monday, so the weekday schedule test says what it means.
final t0 = DateTime(2026, 1, 5, 9, 0);

List<Metric> _metrics({
  double? cpu,
  double? memory,
  double? disk,
  String? uptime,
}) =>
    [
      if (cpu != null)
        Metric(
            label: 'CPU',
            value: cpu.round().toString(),
            unit: '%',
            source: MetricSource.collector,
            ratio: cpu / 100),
      if (memory != null)
        Metric(
            label: 'Memory',
            value: memory.round().toString(),
            unit: '%',
            source: MetricSource.collector,
            ratio: memory / 100),
      if (disk != null)
        Metric(
            label: 'Disk',
            value: disk.round().toString(),
            unit: '%',
            source: MetricSource.collector,
            ratio: disk / 100),
      if (uptime != null)
        Metric(label: 'Uptime', value: uptime, source: MetricSource.collector),
    ];

Rule _rule(
  AutomationTrigger trigger, {
  String id = 'r1',
  AutomationAction action = const Notify(message: 'hi'),
  List<String> targets = const [Rule.allTargets],
  Duration cooldown = Duration.zero,
  bool enabled = true,
}) =>
    Rule(
      id: id,
      name: 'rule $id',
      trigger: trigger,
      action: action,
      targets: targets,
      cooldown: cooldown,
      enabled: enabled,
    );

extension _Tick on AutomationEngine {
  List<Firing> at(
    DateTime now, {
    Map<String, LabDeskPeerStatus> status = const {},
    Map<String, List<Metric>> metrics = const {},
    Set<String> machines = const {'a'},
  }) =>
      tick(now: now, status: status, metrics: metrics, machines: machines);
}

void main() {
  group('baseline', () {
    test('the first tick fires nothing, whatever the fleet looks like', () {
      final e = AutomationEngine([
        _rule(const CameOnline(), id: 'on'),
        _rule(const MetricAbove(metric: AutoMetric.cpu, threshold: 50),
            id: 'cpu'),
        _rule(Schedule(every: const Duration(minutes: 5)), id: 'every'),
      ]);

      final fired = e.at(t0,
          status: {'a': _online}, metrics: {'a': _metrics(cpu: 99)});

      expect(fired, isEmpty,
          reason: 'the first tick is what establishes what "before" was; '
              'firing on it would run a command for a state nobody watched '
              'change');
    });

    test('a rule added later baselines on its own first tick', () {
      final e = AutomationEngine([_rule(const CameOnline(), id: 'old')]);
      e.at(t0, status: {'a': _offline});

      e.rules = [
        _rule(const CameOnline(), id: 'old'),
        _rule(const MetricAbove(metric: AutoMetric.disk, threshold: 80),
            id: 'new'),
      ];
      final first = e.at(t0.add(const Duration(seconds: 1)),
          status: {'a': _online}, metrics: {'a': _metrics(disk: 95)});

      // The came-online rule was already baselined and sees a real edge; the
      // disk rule is on its first tick and must not fire on a disk that was
      // already full when it was written.
      expect(first.map((f) => f.rule.id), ['old']);
    });
  });

  group('CameOnline', () {
    test('fires on the offline to online edge', () {
      final e = AutomationEngine([_rule(const CameOnline())]);
      e.at(t0, status: {'a': _offline});

      final fired = e.at(t0.add(const Duration(seconds: 1)),
          status: {'a': _online});

      expect(fired, hasLength(1));
      expect(fired.single.machineId, 'a');
      expect(fired.single.action, const Notify(message: 'hi'));
    });

    test('does not fire out of unknown, which is not a state of being down',
        () {
      final e = AutomationEngine([_rule(const CameOnline())]);
      e.at(t0, status: {'a': _unknown});

      expect(e.at(t0.add(const Duration(seconds: 1)), status: {'a': _online}),
          isEmpty,
          reason: 'unknown means nobody has asked; a machine coming out of it '
              'has not been observed coming back');
    });

    test('does not fire again while the machine stays online', () {
      final e = AutomationEngine([_rule(const CameOnline())]);
      e.at(t0, status: {'a': _offline});
      expect(e.at(t0.add(const Duration(seconds: 1)), status: {'a': _online}),
          hasLength(1));

      expect(e.at(t0.add(const Duration(seconds: 2)), status: {'a': _online}),
          isEmpty);
      expect(e.at(t0.add(const Duration(seconds: 3)), status: {'a': _online}),
          isEmpty);
    });
  });

  group('WentOffline', () {
    test('with no duration, fires on the online to offline edge only', () {
      final e = AutomationEngine([_rule(const WentOffline())]);
      e.at(t0, status: {'a': _online});

      expect(e.at(t0.add(const Duration(seconds: 1)), status: {'a': _offline}),
          hasLength(1));
      expect(e.at(t0.add(const Duration(seconds: 2)), status: {'a': _offline}),
          isEmpty);
    });

    test('with a duration, stays quiet until the machine has been down that '
        'long', () {
      final e = AutomationEngine([_rule(const WentOffline(forMinutes: 5))]);
      e.at(t0, status: {'a': _online});
      e.at(t0.add(const Duration(seconds: 1)), status: {'a': _offline});

      expect(e.at(t0.add(const Duration(minutes: 4)), status: {'a': _offline}),
          isEmpty);
      expect(
          e.at(t0.add(const Duration(minutes: 5, seconds: 2)),
              status: {'a': _offline}),
          hasLength(1));
    });

    test('a flap back online resets the clock, so a blip fires nothing', () {
      final e = AutomationEngine([_rule(const WentOffline(forMinutes: 5))]);
      e.at(t0, status: {'a': _online});
      e.at(t0.add(const Duration(minutes: 1)), status: {'a': _offline});
      // Back for one tick, then away again.
      e.at(t0.add(const Duration(minutes: 3)), status: {'a': _online});
      e.at(t0.add(const Duration(minutes: 4)), status: {'a': _offline});

      expect(e.at(t0.add(const Duration(minutes: 7)), status: {'a': _offline}),
          isEmpty,
          reason: 'it has been down three minutes since the flap, not six');
      expect(e.at(t0.add(const Duration(minutes: 9)), status: {'a': _offline}),
          hasLength(1));
    });

    test('never fires for a machine that was already down at baseline', () {
      final e = AutomationEngine([_rule(const WentOffline(forMinutes: 5))]);
      e.at(t0, status: {'a': _offline});

      for (var m = 1; m <= 30; m++) {
        expect(e.at(t0.add(Duration(minutes: m)), status: {'a': _offline}),
            isEmpty);
      }
    });

    test('fires once per outage, not once per tick', () {
      final e = AutomationEngine([_rule(const WentOffline(forMinutes: 1))]);
      e.at(t0, status: {'a': _online});
      e.at(t0.add(const Duration(seconds: 1)), status: {'a': _offline});

      var count = 0;
      for (var s = 61; s < 200; s++) {
        count += e
            .at(t0.add(Duration(seconds: s)), status: {'a': _offline}).length;
      }
      expect(count, 1);
    });
  });

  group('MetricAbove', () {
    Rule cpuRule({int forMinutes = 5}) => _rule(MetricAbove(
        metric: AutoMetric.cpu, threshold: 90, forMinutes: forMinutes));

    test('fires only once the metric has held above the threshold', () {
      final e = AutomationEngine([cpuRule()]);
      final m = {'a': _metrics(cpu: 95)};
      e.at(t0, status: {'a': _online}, metrics: m);

      expect(e.at(t0.add(const Duration(minutes: 4)), status: {'a': _online},
          metrics: m), isEmpty);
      expect(
          e.at(t0.add(const Duration(minutes: 5)),
              status: {'a': _online}, metrics: m),
          hasLength(1));
    });

    test('a dip below the threshold restarts the window', () {
      final e = AutomationEngine([cpuRule()]);
      e.at(t0, status: {'a': _online}, metrics: {'a': _metrics(cpu: 95)});
      e.at(t0.add(const Duration(minutes: 3)),
          status: {'a': _online}, metrics: {'a': _metrics(cpu: 20)});
      e.at(t0.add(const Duration(minutes: 4)),
          status: {'a': _online}, metrics: {'a': _metrics(cpu: 95)});

      expect(
          e.at(t0.add(const Duration(minutes: 8)),
              status: {'a': _online}, metrics: {'a': _metrics(cpu: 95)}),
          isEmpty,
          reason: 'four minutes above, not eight');
      expect(
          e.at(t0.add(const Duration(minutes: 9, seconds: 1)),
              status: {'a': _online}, metrics: {'a': _metrics(cpu: 95)}),
          hasLength(1));
    });

    test('fires once per episode, and again after the metric recovers', () {
      final e = AutomationEngine([cpuRule(forMinutes: 0)]);
      final hot = {'a': _metrics(cpu: 95)};
      final cool = {'a': _metrics(cpu: 10)};
      e.at(t0, status: {'a': _online}, metrics: hot);

      expect(e.at(t0.add(const Duration(minutes: 1)),
          status: {'a': _online}, metrics: hot), hasLength(1));
      expect(e.at(t0.add(const Duration(minutes: 2)),
          status: {'a': _online}, metrics: hot), isEmpty,
          reason: 'the same episode of the same condition is one event');

      e.at(t0.add(const Duration(minutes: 3)),
          status: {'a': _online}, metrics: cool);
      expect(e.at(t0.add(const Duration(minutes: 4)),
          status: {'a': _online}, metrics: hot), hasLength(1));
    });

    test('a machine with no probe figures fires nothing', () {
      final e = AutomationEngine([cpuRule(forMinutes: 0)]);
      e.at(t0, status: {'a': _online});

      // Monitoring is off for this machine, so there is no measurement. An
      // absent figure is not a low one and must not read as either.
      for (var m = 1; m < 10; m++) {
        expect(e.at(t0.add(Duration(minutes: m)), status: {'a': _online}),
            isEmpty);
      }
    });

    test('reads memory and disk by their own labels', () {
      final e = AutomationEngine([
        _rule(const MetricAbove(metric: AutoMetric.disk, threshold: 80),
            id: 'disk'),
        _rule(const MetricAbove(metric: AutoMetric.memory, threshold: 80),
            id: 'mem'),
      ]);
      final m = {'a': _metrics(cpu: 5, memory: 40, disk: 91)};
      e.at(t0, status: {'a': _online}, metrics: m);

      final fired = e.at(t0.add(const Duration(minutes: 1)),
          status: {'a': _online}, metrics: m);
      expect(fired.map((f) => f.rule.id), ['disk']);
    });
  });

  group('UptimeAbove', () {
    test('fires above the threshold and stays quiet below it', () {
      final e = AutomationEngine([_rule(const UptimeAbove(days: 7))]);
      e.at(t0,
          status: {'a': _online}, metrics: {'a': _metrics(uptime: '2d 4h')});

      expect(
          e.at(t0.add(const Duration(minutes: 1)),
              status: {'a': _online},
              metrics: {'a': _metrics(uptime: '2d 4h')}),
          isEmpty);
      expect(
          e.at(t0.add(const Duration(minutes: 2)),
              status: {'a': _online},
              metrics: {'a': _metrics(uptime: '9d 1h')}),
          hasLength(1));
    });

    test('an uptime under a day reads as zero days, not as a parse failure',
        () {
      final e = AutomationEngine([_rule(const UptimeAbove(days: 0))]);
      e.at(t0, status: {'a': _online}, metrics: {'a': _metrics(uptime: '45m')});

      expect(
          e.at(t0.add(const Duration(minutes: 1)),
              status: {'a': _online}, metrics: {'a': _metrics(uptime: '45m')}),
          isEmpty,
          reason: 'zero is not above zero');
    });
  });

  group('Schedule', () {
    test('an interval fires once per interval', () {
      final e = AutomationEngine(
          [_rule(Schedule(every: const Duration(minutes: 10)))]);
      e.at(t0, status: {'a': _online});

      expect(e.at(t0.add(const Duration(minutes: 9)), status: {'a': _online}),
          isEmpty);
      expect(e.at(t0.add(const Duration(minutes: 10)), status: {'a': _online}),
          hasLength(1));
      expect(e.at(t0.add(const Duration(minutes: 11)), status: {'a': _online}),
          isEmpty);
      expect(e.at(t0.add(const Duration(minutes: 21)), status: {'a': _online}),
          hasLength(1));
    });

    test('a long gap produces one run, not the whole backlog', () {
      final e = AutomationEngine(
          [_rule(Schedule(every: const Duration(minutes: 10)))]);
      e.at(t0, status: {'a': _online});

      // The console was shut for six hours. Thirty-six slots came and went.
      final after = e.at(t0.add(const Duration(hours: 6)),
          status: {'a': _online});
      expect(after, hasLength(1),
          reason: 'replaying a backlog would run thirty-six commands at once');

      // And the next slot is measured from the run, not from the backlog.
      expect(
          e.at(t0.add(const Duration(hours: 6, minutes: 9)),
              status: {'a': _online}),
          isEmpty);
      expect(
          e.at(t0.add(const Duration(hours: 6, minutes: 10)),
              status: {'a': _online}),
          hasLength(1));
    });

    test('a time of day fires once for its slot and not again that day', () {
      final e = AutomationEngine(
          [_rule(const Schedule.atTime(hour: 9, minute: 30))]);
      e.at(t0, status: {'a': _online}); // 09:00, baseline.

      expect(e.at(DateTime(2026, 1, 5, 9, 29), status: {'a': _online}),
          isEmpty);
      expect(e.at(DateTime(2026, 1, 5, 9, 30), status: {'a': _online}),
          hasLength(1));
      expect(e.at(DateTime(2026, 1, 5, 9, 31), status: {'a': _online}),
          isEmpty);
      expect(e.at(DateTime(2026, 1, 5, 23, 59), status: {'a': _online}),
          isEmpty);
      expect(e.at(DateTime(2026, 1, 6, 9, 30), status: {'a': _online}),
          hasLength(1), reason: 'the next day is a new slot');
    });

    test('a slot already past when the console opened is not replayed', () {
      final e = AutomationEngine(
          [_rule(const Schedule.atTime(hour: 7, minute: 0))]);
      // Opened at 09:00; 07:00 has been and gone.
      e.at(t0, status: {'a': _online});

      expect(e.at(DateTime(2026, 1, 5, 9, 1), status: {'a': _online}), isEmpty);
      expect(e.at(DateTime(2026, 1, 6, 7, 0), status: {'a': _online}),
          hasLength(1));
    });

    test('weekdays restrict which days a slot exists on', () {
      final e = AutomationEngine([
        _rule(const Schedule.atTime(
            hour: 9, minute: 30, weekdays: [DateTime.wednesday])),
      ]);
      e.at(t0, status: {'a': _online}); // Monday.

      expect(e.at(DateTime(2026, 1, 5, 9, 30), status: {'a': _online}), isEmpty,
          reason: 'Monday is not one of its days');
      expect(e.at(DateTime(2026, 1, 7, 9, 30), status: {'a': _online}),
          hasLength(1), reason: 'Wednesday is');
    });
  });

  group('cooldown and targets', () {
    test('cooldown is per rule and machine', () {
      final e = AutomationEngine([
        _rule(const CameOnline(), cooldown: const Duration(minutes: 30)),
      ]);
      const both = {'a', 'b'};
      e.at(t0, status: {'a': _offline, 'b': _offline}, machines: both);

      final first = e.at(t0.add(const Duration(seconds: 1)),
          status: {'a': _online, 'b': _offline}, machines: both);
      expect(first.map((f) => f.machineId), ['a']);

      // a flaps: still inside its cooldown. b comes up: unaffected by a's.
      e.at(t0.add(const Duration(minutes: 1)),
          status: {'a': _offline, 'b': _offline}, machines: both);
      final second = e.at(t0.add(const Duration(minutes: 2)),
          status: {'a': _online, 'b': _online}, machines: both);
      expect(second.map((f) => f.machineId), ['b']);

      // Once a's cooldown has lapsed it is allowed again.
      e.at(t0.add(const Duration(minutes: 40)),
          status: {'a': _offline, 'b': _online}, machines: both);
      final third = e.at(t0.add(const Duration(minutes: 41)),
          status: {'a': _online, 'b': _online}, machines: both);
      expect(third.map((f) => f.machineId), ['a']);
    });

    test('an explicit target list fires for those machines only, in id order',
        () {
      final e = AutomationEngine(
          [_rule(const CameOnline(), targets: const ['c', 'a'])]);
      const all = {'a', 'b', 'c'};
      e.at(t0,
          status: {'a': _offline, 'b': _offline, 'c': _offline}, machines: all);

      final fired = e.at(t0.add(const Duration(seconds: 1)),
          status: {'a': _online, 'b': _online, 'c': _online}, machines: all);
      expect(fired.map((f) => f.machineId), ['a', 'c'],
          reason: 'b is not a target, and the order is the machine order so '
              'the same tick always produces the same list');
    });

    test('a disabled rule fires nothing and is not armed by being enabled', () {
      final e = AutomationEngine([_rule(const CameOnline(), enabled: false)]);
      e.at(t0, status: {'a': _offline});
      expect(e.at(t0.add(const Duration(seconds: 1)), status: {'a': _online}),
          isEmpty);

      e.rules = [_rule(const CameOnline())];
      // Already online; enabling must not invent an edge.
      expect(e.at(t0.add(const Duration(seconds: 2)), status: {'a': _online}),
          isEmpty);
    });
  });

  group('run log', () {
    test('every firing is logged and the outcome attaches to it', () {
      final e = AutomationEngine([_rule(const CameOnline())]);
      e.at(t0, status: {'a': _offline});
      final f = e.at(t0.add(const Duration(seconds: 1)),
          status: {'a': _online}).single;

      expect(e.log.entries.first.ok, isNull, reason: 'not answered for yet');
      e.recordOutcome(f.id, false, 'no saved password');

      final entry = e.log.entries.first;
      expect(entry.firingId, f.id);
      expect(entry.ruleId, 'r1');
      expect(entry.machineId, 'a');
      expect(entry.ok, isFalse);
      expect(entry.detail, 'no saved password');
      expect(e.log.lastFor('r1'), isNotNull);
    });

    test('the log keeps the last 200, newest first', () {
      final e = AutomationEngine(
          [_rule(Schedule(every: const Duration(minutes: 1)))]);
      e.at(t0, status: {'a': _online});
      for (var m = 1; m <= 260; m++) {
        e.at(t0.add(Duration(minutes: m)), status: {'a': _online});
      }

      expect(e.log.length, RunLog.capacity);
      expect(e.log.entries.first.at.isAfter(e.log.entries.last.at), isTrue);
    });

    test('run now ignores the trigger and the cooldown', () {
      final e = AutomationEngine([
        _rule(const WentOffline(forMinutes: 60),
            cooldown: const Duration(hours: 12)),
      ]);
      e.at(t0, status: {'a': _online});

      final first =
          e.runNow(ruleId: 'r1', now: t0, machines: {'a', 'b'});
      expect(first.map((f) => f.machineId), ['a', 'b']);
      expect(e.runNow(ruleId: 'r1', now: t0, machines: {'a'}), hasLength(1));
      expect(e.runNow(ruleId: 'nope', now: t0, machines: {'a'}), isEmpty);
      expect(e.log.length, 3, reason: 'two machines, then one, then no rule');
    });
  });

  group('json', () {
    test('every trigger and action survives a round trip', () {
      final rules = <Rule>[
        _rule(const CameOnline(), id: '1', action: const WakeOnLan()),
        _rule(const WentOffline(forMinutes: 5),
            id: '2', action: const Notify(message: 'gone')),
        _rule(const WentOffline(), id: '3', action: const OpenSession()),
        _rule(
            const MetricAbove(
                metric: AutoMetric.memory, threshold: 88.5, forMinutes: 15),
            id: '4',
            action: const RunCommand(
                command: 'systemctl restart nginx', platformHint: 'Linux')),
        _rule(const UptimeAbove(days: 30),
            id: '5', action: const Notify(message: 'time to reboot')),
        _rule(Schedule(every: const Duration(hours: 6)),
            id: '6',
            action: const RunCommand(command: 'uptime'),
            targets: const ['a', 'b'],
            cooldown: const Duration(minutes: 90)),
        _rule(
            const Schedule.atTime(
                hour: 7, minute: 5, weekdays: [DateTime.monday, DateTime.friday]),
            id: '7',
            enabled: false),
      ];

      expect(decodeRules(encodeRules(rules)), rules);
    });

    test('one unreadable rule does not take the rest of the list with it', () {
      const raw = '[{"id":"1","name":"n","trigger":{"kind":"martian"},'
          '"action":{"kind":"notify","message":"x"},"targets":["all"],'
          '"cooldownSeconds":0},'
          '{"id":"2","name":"good","trigger":{"kind":"cameOnline"},'
          '"action":{"kind":"wakeOnLan"},"targets":["all"],'
          '"cooldownSeconds":60}]';

      final out = decodeRules(raw);
      expect(out.map((r) => r.id), ['2']);
      expect(out.single.cooldown, const Duration(seconds: 60));
      expect(decodeRules('not json at all'), isEmpty);
      expect(decodeRules(''), isEmpty);
    });
  });

  group('sentences', () {
    String nameOf(String id) => {'a': 'workshop', 'b': 'nas'}[id] ?? id;

    test('a rule reads as one line an operator can check', () {
      expect(
        _rule(const WentOffline(forMinutes: 5), targets: const ['a'])
            .sentence(nameOf),
        'When workshop goes offline for 5 minutes → notify: "hi"',
      );
      expect(
        _rule(const MetricAbove(
                metric: AutoMetric.disk, threshold: 90, forMinutes: 10),
            action: const RunCommand(command: 'df -h')).sentence(nameOf),
        'When any machine\'s disk use is above 90% for 10 minutes → '
        'run "df -h"',
      );
      expect(
        _rule(const CameOnline(), targets: const ['a', 'b'],
                action: const WakeOnLan())
            .sentence(nameOf),
        'When workshop or nas comes online → send Wake-on-LAN',
      );
      expect(
        _rule(const Schedule.atTime(hour: 7, minute: 5, weekdays: [1, 5]),
            action: const WakeOnLan()).sentence(nameOf),
        'Every Mon, Fri at 07:05, on any machine → send Wake-on-LAN',
      );
      expect(
        _rule(Schedule(every: const Duration(hours: 6)),
            action: const OpenSession()).sentence(nameOf),
        'Every 6 hours, on any machine → open a desktop session',
      );
      expect(
        _rule(const UptimeAbove(days: 1)).sentence(nameOf),
        'When any machine has been up for more than 1 day → notify: "hi"',
      );
    });
  });
}
