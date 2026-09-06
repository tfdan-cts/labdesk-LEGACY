import 'package:flutter/material.dart';

import '../models/net_view.dart';
import '../theme/console_theme.dart';

/// The option the daemon's ladder is gated on (`selfheal.rs::OPTION_ENABLE`).
/// `Y` or absent, and set through the client's ordinary option path so the
/// daemon picks it up out of its own config file.
const kSelfHealOption = 'labdesk-selfheal';

/// The self-healing switch on This machine.
///
/// The switch itself is one option, `labdesk-selfheal`, which the console sets
/// through the client's own option path; the daemon re-reads it from its config
/// file on every tick, so a flip here reaches a running service within one
/// probe interval (`src/labdesk/selfheal.rs`, contract section 7).
///
/// What is rendered beside it is the RUNNING value, not the option: the daemon
/// reports the step its ladder last took in `net.reachability.selfheal`, and
/// that is what says whether the service actually picked the switch up. Between
/// a flip and the first report the card says it is waiting, because at that
/// moment nobody knows.
class SelfHealCard extends StatelessWidget {
  const SelfHealCard({
    super.key,
    required this.on,
    this.reachability = NetReachability.unknown,
    this.waiting = false,
    this.onChanged,
  });

  /// The option as it stands on this machine.
  final bool on;

  /// The machine's last reported verdict, which carries the running step.
  final NetReachability reachability;

  /// The option was changed and the machine has not reported since.
  final bool waiting;

  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final running = reachability.selfHealRunning;
    final (dot, line) = waiting
        ? (C.of(context).accent, 'Waiting for the service to pick this up.')
        : on
            ? running
                ? (C.of(context).ok, 'The service is ${reachability.selfhealLabel}.')
                : (
                    C.of(context).idle,
                    'Switched on here. The service has not reported yet.',
                  )
            : running
                ? (
                    C.of(context).accent,
                    'Switched off here, but the service is still '
                        '${reachability.selfhealLabel}.',
                  )
                : (C.of(context).idle, 'Off. Nothing watches this machine\'s connection.');

    return Container(
      decoration: BoxDecoration(
        color: C.of(context).surface,
        borderRadius: C.rounded,
        border: Border.all(color: C.of(context).hairline),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Self-healing', style: C.of(context).h2())),
              Switch(
                value: on,
                activeColor: C.of(context).accent,
                onChanged: onChanged,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'When this machine loses the internet, the background service '
            'cycles the network adapter and restarts networking rather than '
            'waiting for somebody to notice. It never touches a connection '
            'that is working.',
            style: C.of(context).small(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(line, style: C.of(context).body())),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: switch (reachability.internet) {
                    'online' => C.of(context).ok,
                    'offline' => C.of(context).bad,
                    _ => C.of(context).idle,
                  },
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  reachability.internet == 'unprobed'
                      ? 'This machine has not reported an internet check yet.'
                      : '${reachability.internetLabel}, last checked by the '
                          'machine itself.',
                  style: C.of(context).small(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
