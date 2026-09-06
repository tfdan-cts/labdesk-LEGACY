/// What the labnet daemon reports, reduced to what the console renders.
///
/// Pure data: no process, no FFI. Built from `netbird status --json`, whose
/// field names come from the struct tags in the daemon's own source
/// (client/status/status.go), so this parses the wire shape and nothing else.
enum OverlayDaemonStatus {
  /// No daemon answered at all: the service is not installed or not running.
  notInstalled,
  idle,
  connecting,
  connected,
  needsLogin,
  loginFailed,
  sessionExpired,

  /// The daemon answered something this build does not understand.
  unknown,
}

enum OverlayLinkType { direct, relayed, unknown }

class OverlayPeer {
  const OverlayPeer({
    required this.name,
    required this.ip,
    required this.publicKey,
    required this.connected,
    required this.link,
    this.latencyMs,
  });

  /// The peer's name on the overlay (its fqdn there), never its LabDesk id.
  final String name;
  final String ip;
  final String publicKey;
  final bool connected;
  final OverlayLinkType link;
  final int? latencyMs;
}

class OverlayState {
  const OverlayState({
    required this.status,
    this.ip = '',
    this.publicKey = '',
    this.name = '',
    this.managementConnected = false,
    this.managementError = '',
    this.signalConnected = false,
    this.signalError = '',
    this.peers = const [],
    this.daemonVersion = '',
    this.error = '',
  });

  static const notInstalled =
      OverlayState(status: OverlayDaemonStatus.notInstalled);
  static const unknown = OverlayState(status: OverlayDaemonStatus.unknown);

  final OverlayDaemonStatus status;
  final String ip;
  final String publicKey;
  final String name;
  final bool managementConnected;
  final String managementError;
  final bool signalConnected;
  final String signalError;
  final List<OverlayPeer> peers;
  final String daemonVersion;

  /// Whatever the daemon or the CLI said when nothing else could be read.
  final String error;

  bool get isUp => status == OverlayDaemonStatus.connected;

  /// The peer at [ip], or null while the daemon has not heard of it.
  OverlayPeer? peerAt(String ip) {
    for (final p in peers) {
      if (p.ip == ip) return p;
    }
    return null;
  }

  /// Parses `netbird status --json`. Anything malformed becomes [unknown]
  /// carrying the text, never a throw: the daemon is a foreign process and
  /// the console must keep rendering whatever it prints.
  static OverlayState fromStatusJson(Map<String, dynamic> json) {
    final status = switch (json['daemonStatus']) {
      'Idle' => OverlayDaemonStatus.idle,
      'Connecting' => OverlayDaemonStatus.connecting,
      'Connected' => OverlayDaemonStatus.connected,
      'NeedsLogin' => OverlayDaemonStatus.needsLogin,
      'LoginFailed' => OverlayDaemonStatus.loginFailed,
      'SessionExpired' => OverlayDaemonStatus.sessionExpired,
      _ => OverlayDaemonStatus.unknown,
    };
    final management = _map(json['management']);
    final signal = _map(json['signal']);
    final details = _map(json['peers'])['details'];
    final peers = <OverlayPeer>[];
    if (details is List) {
      for (final d in details) {
        if (d is! Map) continue;
        final latency = d['latency'];
        peers.add(OverlayPeer(
          name: _str(d['fqdn']),
          ip: _str(d['netbirdIp']),
          publicKey: _str(d['publicKey']),
          connected: d['status'] == 'Connected',
          link: switch (d['connectionType']) {
            'P2P' => OverlayLinkType.direct,
            'Relayed' => OverlayLinkType.relayed,
            _ => OverlayLinkType.unknown,
          },
          // Go serialises a Duration as nanoseconds.
          latencyMs: latency is num && latency > 0 ? latency ~/ 1000000 : null,
        ));
      }
    }
    return OverlayState(
      status: status,
      ip: _str(json['netbirdIp']),
      publicKey: _str(json['publicKey']),
      name: _str(json['fqdn']),
      managementConnected: management['connected'] == true,
      managementError: _str(management['error']),
      signalConnected: signal['connected'] == true,
      signalError: _str(signal['error']),
      peers: peers,
      daemonVersion: _str(json['daemonVersion']),
    );
  }

  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const {};
  static String _str(Object? v) => v is String ? v : '';
}
