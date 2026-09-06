import '../common/labdesk_peer_status.dart';
import 'models/machine_row.dart';

/// What the console needs to know about a peer.
///
/// A record rather than the application's `Peer`, because `Peer` lives in
/// peer_model, which owns the FFI. Keeping the adapter to the fields it
/// actually reads is what lets this layer, and the whole console behind it, be
/// tested without the generated bridge.
typedef ConsolePeer = ({
  String id,
  String hostname,
  String platform,
  String alias,
  String username,
});

/// Turns the client's peer lists and the reachability store into console rows.
///
/// The caller supplies the peers because there is no single list of them: the
/// recent sessions, the favourites and whichever tab is open are three separate
/// stores that overlap, so the same machine arrives more than once and is
/// folded here rather than rendered twice.
///
/// Status is read and never inferred. For a machine the organization has
/// enrolled it comes from lab-desk.net, which knows when the machine last sent
/// an uplink; for every other peer it is the client's own rendezvous poll. A
/// machine no answer has named is unknown, which is a different thing from
/// being down, and it carries no timestamps at all rather than a zero that
/// would read as "just now".
List<MachineRow> buildMachineRows({
  required Iterable<ConsolePeer> peers,
  Iterable<ConsolePeer> organizationPeers = const [],
  required LabDeskPeerStatusStore store,
  required List<bool?> Function(String id) historyOf,
  String? Function(String id)? groupOf,
  LabDeskPeerStatus? Function(String id)? serverStatusOf,
}) {
  final rows = <String, MachineRow>{};
  for (final p in peers.followedBy(organizationPeers)) {
    if (p.id.isEmpty) continue;
    if (rows.containsKey(p.id)) continue;
    final state = store.stateOf(p.id);
    // A machine the organization has enrolled is reachable or not by the one
    // rule every console uses: two flushes since its last uplink. The local
    // rendezvous poll answers for the peers lab-desk.net has never been told
    // about, which is what it was ever able to speak for.
    final status = serverStatusOf?.call(p.id) ?? state.status;
    rows[p.id] = MachineRow(
      id: p.id,
      hostname: p.hostname,
      platform: p.platform,
      status: status,
      alias: p.alias.isEmpty ? null : p.alias,
      username: p.username.isEmpty ? null : p.username,
      group: groupOf?.call(p.id),
      lastSeenOnline: state.lastSeenOnline,
      lastChecked: state.lastChecked,
      history: historyOf(p.id),
    );
  }

  // Ordered by what the operator actually reads, so the list does not reshuffle
  // as machines change state under them.
  final ordered = rows.values.toList()
    ..sort((a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
  return ordered;
}
