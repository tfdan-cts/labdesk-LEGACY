import '../models/overlay_state.dart';
import 'overlay_broker.dart';
import 'overlay_daemon.dart';
import 'overlay_enrolment.dart' show OptionWriter, bareIp;

/// What the client is told before a session so it dials the overlay first.
const kOverlayAddrOption = 'labdesk-overlay-addr-';
const kOverlayPkOption = 'labdesk-overlay-pk-';

/// The connect ticket's secret, read and cleared by `handle_hash` in
/// `src/client.rs` on the connect, and cleared here with the other two.
const kOverlayTicketOption = 'labdesk-ticket-';

/// A session grant from lab-desk.net, from asking for it to releasing it.
///
/// `prepare` asks for the rule, waits until this machine's daemon reports the
/// target peer Connected (the rule has to be signalled and the WireGuard
/// handshake completed before a socket can cross), then writes the address
/// hint, the target's id key and the one-time connect ticket for the client.
/// Anything short of that writes nothing, and the session goes the way it
/// always has.
///
/// `noteOpenSessions` is fed the ids of the sessions the console can see; a
/// granted id that has gone is released and its hints cleared.
class OverlaySession {
  OverlaySession({
    required this.broker,
    required this.daemon,
    required this.setOption,
    Future<void> Function(Duration) sleep = Future.delayed,
    this.readyTimeout = const Duration(seconds: 10),
  }) : _sleep = sleep;

  final OverlayBroker broker;
  final OverlayDaemon daemon;
  final OptionWriter setOption;
  final Duration readyTimeout;
  final Future<void> Function(Duration) _sleep;

  /// Granted sessions by peer id, and whether the console has seen each open.
  final _grants = <String, ({SessionGrant grant, bool seenOpen})>{};

  /// Polls a grant may sit unseen before it is treated as a connect that
  /// never happened and released. The console polls sessions every second
  /// or so, and a connect that has not opened in this many is not opening.
  static const unseenPollLimit = 30;
  final _unseenPolls = <String, int>{};

  /// True when the client was handed the overlay address for [peerId].
  Future<bool> prepare(String peerId) async {
    final SessionGrant grant;
    try {
      grant = await broker.session(peerId);
    } catch (_) {
      return false;
    }
    final ip = bareIp(grant.targetAddr.split(':').first);
    var status = await daemon.status();
    var ready = status.peerAt(ip)?.connected ?? false;
    for (var i = 1; !ready && i < readyTimeout.inSeconds; i++) {
      await _sleep(const Duration(seconds: 1));
      status = await daemon.status();
      ready = status.peerAt(ip)?.connected ?? false;
    }
    if (!ready) {
      await broker.endSession(grant.id);
      return false;
    }
    await setOption('$kOverlayAddrOption$peerId', grant.targetAddr);
    await setOption('$kOverlayPkOption$peerId', grant.targetIdPk);
    if (grant.ticket.isNotEmpty) {
      await setOption('$kOverlayTicketOption$peerId', grant.ticket);
    }
    _grants[peerId] = (grant: grant, seenOpen: false);
    _unseenPolls[peerId] = 0;
    return true;
  }

  /// The peer ids of sessions the console currently sees open.
  Future<void> noteOpenSessions(Iterable<String> open) async {
    final openSet = open.toSet();
    for (final id in _grants.keys.toList()) {
      final g = _grants[id]!;
      if (openSet.contains(id)) {
        _grants[id] = (grant: g.grant, seenOpen: true);
        _unseenPolls.remove(id);
      } else if (g.seenOpen) {
        await release(id);
      } else if ((_unseenPolls[id] = (_unseenPolls[id] ?? 0) + 1) >=
          unseenPollLimit) {
        // Never seen open: the connect failed or the operator gave up. Left
        // alone, its hint would make every later connect to this peer dial a
        // dead address first, and nothing else would ever clear it.
        await release(id);
      }
    }
  }

  /// Ends the grant for [peerId] whether or not the session ever opened.
  Future<void> release(String peerId) async {
    final g = _grants.remove(peerId);
    _unseenPolls.remove(peerId);
    if (g == null) return;
    await setOption('$kOverlayAddrOption$peerId', '');
    await setOption('$kOverlayPkOption$peerId', '');
    await setOption('$kOverlayTicketOption$peerId', '');
    await broker.endSession(g.grant.id);
  }

  bool get hasGrants => _grants.isNotEmpty;

  /// The daemon state the last readiness check saw, for the screen if wanted.
  OverlayState? lastStatus;
}
