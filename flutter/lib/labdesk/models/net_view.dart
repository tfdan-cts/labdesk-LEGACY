import 'dart:convert';

/// The machine's own view of its network, as the agent reports it.
///
/// Two machine attributes carry it (docs/plans/2026-09-05-002-phase1-contracts.md
/// section 6, written by `src/labdesk/netview.rs`): `net.adapters`, the
/// interfaces with their addresses and byte counters, and `net.reachability`,
/// the internet verdict and what the self-healer last did about it. Both ride
/// `GET /console/org/machines/:id` in its `attrs` member, and both are written
/// by the agent, so a console reads them and never writes them.
class NetAddress {
  const NetAddress({required this.addr, this.prefix, this.family = ''});

  final String addr;
  final int? prefix;

  /// `inet` or `inet6`.
  final String family;

  bool get isV6 => family == 'inet6';

  @override
  String toString() => prefix == null ? addr : '$addr/$prefix';
}

class NetAdapter {
  const NetAdapter({
    required this.name,
    required this.up,
    this.mac = '',
    this.addresses = const [],
    this.rxBytes,
    this.txBytes,
    this.kind = 'other',
  });

  final String name;

  /// Link state, not "has an address": an adapter can be up with nothing
  /// configured on it, and that is what an operator needs to see.
  final bool up;
  final String mac;
  final List<NetAddress> addresses;

  /// Cumulative counters since boot, as the sampler reads them.
  final int? rxBytes;
  final int? txBytes;

  /// `physical`, `overlay` or `other`. On Windows this is what the adapter
  /// presents as rather than what is behind it, which is why it is shown
  /// beside the name rather than used to hide anything.
  final String kind;

  bool get isOverlay => kind == 'overlay';

  List<NetAddress> get v4 => [for (final a in addresses) if (!a.isV6) a];
  List<NetAddress> get v6 => [for (final a in addresses) if (a.isV6) a];
}

/// What the machine last found when it asked whether the internet was there,
/// and what the self-healer was doing at that moment.
class NetReachability {
  const NetReachability({
    this.internet = 'unprobed',
    this.at,
    this.probe = '',
    this.selfheal = 'off',
  });

  /// `online`, `offline` or `unprobed`. `unprobed` is the value before the
  /// first probe and is rendered as such, never as offline.
  final String internet;

  /// Unix seconds of the reading.
  final int? at;
  final String probe;

  /// The step the self-healing ladder last took: `off`, `watching`, `cycling`,
  /// `restarting` or `holdoff`. This is the RUNNING value, which is what the
  /// switch renders beside itself; the option is only what was asked for.
  final String selfheal;

  bool get selfHealRunning => selfheal != 'off';

  static const unknown = NetReachability();

  String get internetLabel => switch (internet) {
        'online' => 'Internet reachable',
        'offline' => 'No internet',
        _ => 'Not probed yet',
      };

  String get selfhealLabel => switch (selfheal) {
        'watching' => 'watching connectivity',
        'cycling' => 'cycling the adapter',
        'restarting' => 'restarting networking',
        'holdoff' => 'holding off after a restart',
        _ => 'off',
      };
}

/// The two attributes, read out of the `attrs` member of
/// `GET /console/org/machines/:id`.
class MachineNetView {
  const MachineNetView({
    this.adapters = const [],
    this.reachability = NetReachability.unknown,
    this.reported = false,
  });

  final List<NetAdapter> adapters;
  final NetReachability reachability;

  /// Whether the machine has reported a network view at all. False means the
  /// agent has not sent one yet, which the screen says rather than drawing an
  /// empty adapter list as "no adapters".
  final bool reported;

  static const empty = MachineNetView();

  static MachineNetView fromAttrs(Map<dynamic, dynamic> attrs) {
    Object? valueOf(String key) {
      final entry = attrs[key];
      if (entry is! Map) return null;
      final raw = entry['value'];
      if (raw is! String || raw.isEmpty) return null;
      try {
        return jsonDecode(raw);
      } catch (_) {
        return null;
      }
    }

    final adaptersJson = valueOf('net.adapters');
    final reachJson = valueOf('net.reachability');
    final adapters = <NetAdapter>[];
    if (adaptersJson is List) {
      for (final a in adaptersJson) {
        if (a is! Map) continue;
        adapters.add(NetAdapter(
          name: a['name'] is String ? a['name'] as String : '',
          up: a['up'] == true,
          mac: a['mac'] is String ? a['mac'] as String : '',
          addresses: [
            for (final ad in (a['addresses'] as List? ?? const []))
              if (ad is Map && ad['addr'] is String)
                NetAddress(
                  addr: ad['addr'] as String,
                  prefix: ad['prefix'] is num
                      ? (ad['prefix'] as num).toInt()
                      : null,
                  family: ad['family'] is String ? ad['family'] as String : '',
                ),
          ],
          rxBytes: a['rxBytes'] is num ? (a['rxBytes'] as num).toInt() : null,
          txBytes: a['txBytes'] is num ? (a['txBytes'] as num).toInt() : null,
          kind: a['kind'] is String ? a['kind'] as String : 'other',
        ));
      }
      // Up first, then by name, so the interface carrying traffic is not
      // buried under half a dozen virtual ones.
      adapters.sort((a, b) => a.up == b.up
          ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
          : (a.up ? -1 : 1));
    }
    final reach = reachJson is Map
        ? NetReachability(
            internet: reachJson['internet'] is String
                ? reachJson['internet'] as String
                : 'unprobed',
            at: reachJson['at'] is num ? (reachJson['at'] as num).toInt() : null,
            probe: reachJson['probe'] is String
                ? reachJson['probe'] as String
                : '',
            selfheal: reachJson['selfheal'] is String
                ? reachJson['selfheal'] as String
                : 'off',
          )
        : NetReachability.unknown;
    return MachineNetView(
      adapters: adapters,
      reachability: reach,
      reported: adaptersJson != null || reachJson != null,
    );
  }
}

/// A byte count for a fixed width column, for the cumulative counters.
String formatBytes(int? bytes) {
  if (bytes == null) return '--';
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v < 10 && i > 0 ? v.toStringAsFixed(1) : v.round()} ${units[i]}';
}
