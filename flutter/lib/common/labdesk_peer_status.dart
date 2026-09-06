/// Per-peer reachability state.
///
/// This replaces a single global "a query is running" flag, which could only
/// say that something was in flight and had no room for the difference between
/// "this machine answered and is down" and "nobody has asked yet". Those are
/// not the same thing and a dashboard that renders them identically is lying.
///
/// What this tracks is registration with the ID server, which is the only thing
/// the online query actually measures. It is not machine health: a peer can be
/// registered and still be unreachable, out of disk, or refusing connections.
/// Do not label it health in the UI.
library;

enum LabDeskPeerStatus {
  /// Nobody has asked about this peer yet, or the last query failed. The dot
  /// should read as "no information", never as a problem.
  unknown,
  online,
  offline,
}

/// What is known about one peer, and when it was learned.
class LabDeskPeerState {
  const LabDeskPeerState({
    this.status = LabDeskPeerStatus.unknown,
    this.lastChecked,
    this.lastSeenOnline,
  });

  final LabDeskPeerStatus status;

  /// When this peer was last actually included in a response. Null while the
  /// status is unknown.
  final DateTime? lastChecked;

  /// When this peer was last reported online. Kept across going offline, so the
  /// UI can say how long a machine has been away.
  final DateTime? lastSeenOnline;

  LabDeskPeerState _seen(LabDeskPeerStatus next, DateTime at) =>
      LabDeskPeerState(
        status: next,
        lastChecked: at,
        // Only ever moves forward, and only when the peer really answered.
        lastSeenOnline:
            next == LabDeskPeerStatus.online ? at : lastSeenOnline,
      );
}

/// Holds the reachability state of every peer the client has been told about.
///
/// Deliberately plain Dart with no reactive types, so it can be unit tested
/// without a binding. The widget layer wraps it.
class LabDeskPeerStatusStore {
  final Map<String, LabDeskPeerState> _states = {};
  final Set<String> _inFlight = {};

  static const _empty = LabDeskPeerState();

  /// State of a peer. Peers that have never appeared in a response read as
  /// unknown rather than being invented as offline.
  LabDeskPeerState stateOf(String id) => _states[id] ?? _empty;

  Iterable<String> get trackedIds => _states.keys;

  bool get isQuerying => _inFlight.isNotEmpty;

  bool isQueryingPeer(String id) => _inFlight.contains(id);

  /// Record that a query went out. The existing states are left alone: a
  /// refresh must not blank the dots it is refreshing.
  void beginQuery(Iterable<String> ids) {
    _inFlight.addAll(ids.where((id) => id.isNotEmpty));
  }

  /// Clear the in-flight marker. Called on both success and failure, and on
  /// failure it is the only thing that happens, so a query that never came back
  /// leaves every peer exactly as it was.
  void endQuery() => _inFlight.clear();

  /// Fold a response into the store.
  ///
  /// Only the peers actually named are touched. A response about other peers
  /// says nothing about the ones it omits, so their state and their
  /// lastChecked are left untouched.
  void applyResponse({
    required Iterable<String> onlines,
    required Iterable<String> offlines,
    DateTime? at,
  }) {
    final now = at ?? DateTime.now();
    for (final id in onlines) {
      if (id.isEmpty) continue;
      _states[id] = stateOf(id)._seen(LabDeskPeerStatus.online, now);
      _inFlight.remove(id);
    }
    for (final id in offlines) {
      if (id.isEmpty) continue;
      _states[id] = stateOf(id)._seen(LabDeskPeerStatus.offline, now);
      _inFlight.remove(id);
    }
  }

  /// Drop a peer, for when it is removed from the address book.
  void forget(String id) {
    _states.remove(id);
    _inFlight.remove(id);
  }

  void clear() {
    _states.clear();
    _inFlight.clear();
  }

  /// How many known peers are in a given state. Peers the store has never been
  /// told about are not counted, so this cannot report machines that do not
  /// exist as offline.
  int countOf(LabDeskPeerStatus status) =>
      _states.values.where((s) => s.status == status).length;
}

/// What the dot beside a machine should draw.
///
/// Three states, never two. A machine nobody has asked about is [unknown] and
/// must not draw as [offline]: drawing it red tells an operator a healthy
/// machine is down, which is the whole reason this store keeps an unknown
/// state at all.
enum LabDeskDot { checking, online, offline, unknown }

/// [status] is null where a call site has no machine id, and there the
/// caller's own boolean is all there is to go on.
LabDeskDot labdeskDotFor({
  required bool checking,
  required LabDeskPeerStatus? status,
  required bool fallbackOnline,
}) {
  if (checking) return LabDeskDot.checking;
  switch (status) {
    case LabDeskPeerStatus.online:
      return LabDeskDot.online;
    case LabDeskPeerStatus.offline:
      return LabDeskDot.offline;
    case LabDeskPeerStatus.unknown:
      return LabDeskDot.unknown;
    case null:
      return fallbackOnline ? LabDeskDot.online : LabDeskDot.offline;
  }
}
