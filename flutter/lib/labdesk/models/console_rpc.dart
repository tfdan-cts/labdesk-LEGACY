import 'machine_metrics.dart';
import 'machine_row.dart';
import 'machine_state.dart';

/// Methods the console sends to a remote-desktop window, keyed by peer id.
///
/// Sessions run in their own windows, so the console asks the window that
/// holds a session rather than the session itself. The arguments and answers
/// are JSON strings, because the window channel's codec is small.
const kLabDeskRpcAction = 'labdesk_action';
const kLabDeskRpcSessionStats = 'labdesk_session_stats';

/// Read one session's chat. Arguments: the peer id, as a bare string.
/// Answers a JSON `SessionChat`, or null when the window holds no such
/// session. See `chat_transcript.dart` for the shape.
const kLabDeskRpcChatGet = 'labdesk_chat_get';

/// Say something in one session's chat. Arguments: `{"id": ..., "text": ...}`
/// as a JSON string. Answers true when the message went to the peer.
///
/// The message goes through the session's own `ChatModel`, which is what the
/// floating chat in the session window uses, so both surfaces show the one
/// conversation rather than two views that drift apart.
const kLabDeskRpcChatSend = 'labdesk_chat_send';

/// What Health shows for one machine: identity the client already holds, the
/// session window's quality figures, and the readings the machine's own
/// collector sent to lab-desk.net.
///
/// The figures no longer come from a terminal probe. The agent takes them on
/// its own flush and the console reads them back, so they exist for every
/// enrolled machine whether or not anyone has a session open and whether or
/// not this console was running when they were taken (WP18, contract section 5).
///
/// A machine lab-desk.net holds nothing for renders as unavailable. "--" is the
/// honest value for a reading nobody took; zero would be a measurement.
MachineHealth buildMachineHealth({
  required MachineRow machine,
  required bool connected,
  Map<String, dynamic>? sessionStats,
  MachineState? state,
  MetricHistory? history,
}) {
  Metric known(String label, String? value) => value == null || value.isEmpty
      ? Metric.unavailable(label)
      : Metric(label: label, value: value, source: MetricSource.known);

  final identity = <Metric>[
    known('ID', machine.id),
    known('Hostname', machine.hostname),
    known('User', machine.username),
    known('Platform', machine.platform),
    known('Group', machine.group),
  ];

  Metric stat(String label, String key, {String? unit}) {
    final v = sessionStats?[key];
    if (v is String && v.isNotEmpty) {
      return Metric(label: label, value: v, unit: unit, source: MetricSource.session);
    }
    return Metric.unavailable(label);
  }

  final session = <Metric>[
    stat('Round trip', 'delay', unit: 'ms'),
    stat('Throughput', 'speed'),
    stat('Frame rate', 'fps', unit: 'fps'),
    stat('Codec', 'codecFormat'),
  ];

  final remote = state?.metrics() ??
      const [
        Metric.unavailable('CPU'),
        Metric.unavailable('Memory'),
        Metric.unavailable('Disk'),
        Metric.unavailable('Uptime'),
      ];

  return MachineHealth(
    machineId: machine.id,
    connected: connected,
    state: state,
    identity: identity,
    session: session,
    remote: remote,
    history: history,
  );
}
