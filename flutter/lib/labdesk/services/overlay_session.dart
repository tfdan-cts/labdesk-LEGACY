import 'dart:async';

import '../models/overlay_state.dart';
import 'overlay_broker.dart';
import 'overlay_daemon.dart';
import 'overlay_enrolment.dart' show OptionWriter, bareIp;

/// What the client is told before a session so it dials the overlay first.
const kOverlayAddrOption = 'labdesk-overlay-addr-';
const kOverlayPkOption = 'labdesk-overlay-pk-';
const kOverlayRequiredOption = 'labdesk-overlay-required-';

/// The connect ticket's secret, read and cleared by `handle_hash` in
/// `src/client.rs` on the connect, and cleared here with the other two.
const kOverlayTicketOption = 'labdesk-ticket-';

/// A session grant from lab-desk.net, from asking for it to releasing it.
///
/// `prepare` asks for the rule, waits until this machine's daemon reports the
/// target peer Connected (the rule has to be signalled and the WireGuard
/// handshake completed before a socket can cross), then writes the address
/// hint, the target's id key and the one-time connect ticket for the client.
/// Anything short of that clears stale hints and exposes the failure. A
/// different connection provider requires an explicit choice in the console.
///
/// `noteOpenSessions` is fed the ids of the sessions the console can see; a
/// granted id that has gone is released and its hints cleared.
class OverlaySession {
  OverlaySession({
    required this.broker,
    required this.daemon,
    required this.setOption,
    Future<void> Function(Duration) sleep = Future.delayed,
    this.readyTimeout = const Duration(seconds: 30),
  }) : _sleep = sleep;

  final OverlayBroker broker;
  final OverlayDaemon daemon;
  final OptionWriter setOption;
  final Duration readyTimeout;
  final Future<void> Function(Duration) _sleep;

  /// Granted sessions by peer id, and whether the console has seen each open.
  final _grants = <String, ({List<SessionGrant> grants, bool seenOpen})>{};
  final _preparing = <String>{};
  final _pendingReleases = <String>{};
  int _generation = 0;

  String lastError = '';
  OverlayLinkType lastLink = OverlayLinkType.unknown;

  /// Polls a grant may sit unseen before it is treated as a connect that
  /// never happened and released. The console polls sessions every second
  /// or so, and a connect that has not opened in this many is not opening.
  static const unseenPollLimit = 30;
  final _unseenPolls = <String, int>{};

  /// True when the client was handed the overlay address for [peerId].
  Future<bool> prepare(String peerId) async {
    if (!_preparing.add(peerId)) {
      lastError =
          'A labnet connection to this machine is already being prepared.';
      return false;
    }
    SessionGrant? grant;
    var prepared = false;
    final generation = _generation;
    bool cancelled() {
      if (generation == _generation) return false;
      lastError = 'Labnet connection cancelled.';
      return true;
    }

    final elapsed = Stopwatch()..start();
    Duration remaining() => readyTimeout - elapsed.elapsed;
    lastError = '';
    lastStatus = null;
    lastLink = OverlayLinkType.unknown;
    try {
      var creationTimedOut = false;
      final creating = broker.session(peerId).then((created) async {
        // Creation changes server state. Retain ownership of a late answer
        // so timing out the caller cannot abandon the returned grant.
        if (creationTimedOut) await _endGrant(created.id);
        return created;
      });
      grant = await creating.timeout(remaining(), onTimeout: () {
        creationTimedOut = true;
        throw TimeoutException('Labnet session creation timed out');
      });
      if (cancelled()) return false;
      if (grant.ticket.isEmpty ||
          grant.id.isEmpty ||
          grant.targetIdPk.isEmpty) {
        lastError =
            'The server did not provide a complete labnet session ticket.';
        return false;
      }
      final ip = bareIp(grant.targetAddr.split(':').first);
      var ready = false;
      var ticketReady = false;
      for (var i = 0; i < readyTimeout.inSeconds; i++) {
        if (i > 0) {
          await _sleep(const Duration(seconds: 1)).timeout(remaining());
          if (cancelled()) return false;
        }
        final status = lastStatus = await daemon.status().timeout(remaining());
        if (cancelled()) return false;
        final peer = status.peerAt(ip);
        ticketReady = await broker.sessionReady(grant.id).timeout(remaining());
        if (cancelled()) return false;
        if (status.isUp && (peer?.connected ?? false) && ticketReady) {
          lastLink = peer!.link;
          ready = true;
          break;
        }
      }
      if (!ready) {
        lastError = !ticketReady
            ? 'The target has not confirmed that it is ready for this session. '
                'Check that its LabDesk service is running and can reach lab-desk.net.'
            : 'The labnet tunnel to this machine did not become ready. '
                'Check labnet on both machines and try again.';
        return false;
      }
      await setOption('$kOverlayAddrOption$peerId', grant.targetAddr);
      if (cancelled()) return false;
      await setOption('$kOverlayPkOption$peerId', grant.targetIdPk);
      if (cancelled()) return false;
      await setOption('$kOverlayTicketOption$peerId', grant.ticket);
      if (cancelled()) return false;
      await setOption('$kOverlayRequiredOption$peerId', 'Y');
      if (cancelled()) return false;
      final previous = _grants[peerId];
      _grants[peerId] = (
        grants: [...?previous?.grants, grant],
        seenOpen: previous?.seenOpen ?? false,
      );
      _unseenPolls[peerId] = 0;
      grant = null; // The active-session tracker now owns its release.
      prepared = true;
      return true;
    } on TimeoutException {
      lastError = 'The labnet connection timed out while waiting for the '
          'tunnel and target service. Check both machines and try again.';
      return false;
    } on OverlayBrokerException catch (e) {
      lastError = e.message;
      return false;
    } catch (e) {
      lastError = '$e';
      return false;
    } finally {
      try {
        if (!prepared) await _clearHints(peerId);
      } finally {
        try {
          if (grant != null) await _endGrant(grant.id);
        } finally {
          _preparing.remove(peerId);
        }
      }
    }
  }

  /// The peer ids of sessions the console currently sees open.
  Future<void> noteOpenSessions(Iterable<String> open) async {
    await _retryReleases();
    final openSet = open.toSet();
    for (final id in _grants.keys.toList()) {
      final g = _grants[id]!;
      if (openSet.contains(id)) {
        _grants[id] = (grants: g.grants, seenOpen: true);
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
    try {
      await _clearHints(peerId);
    } finally {
      for (final grant in g.grants) {
        await _endGrant(grant.id);
      }
    }
  }

  Future<void> _endGrant(String id) async {
    _pendingReleases.add(id);
    try {
      // DELETE is idempotent. A late response can safely be ignored and the
      // release retried, unlike session creation or publishing dial hints.
      if (await broker.endSession(id).timeout(const Duration(seconds: 10),
          onTimeout: () => false)) _pendingReleases.remove(id);
    } catch (_) {
      // A failed release remains owned here until the next session poll.
    }
  }

  Future<void> _retryReleases() async {
    for (final id in _pendingReleases.toList()) {
      await _endGrant(id);
    }
  }

  Future<void> _clearHints(String peerId) async {
    await setOption('$kOverlayAddrOption$peerId', '');
    await setOption('$kOverlayPkOption$peerId', '');
    await setOption('$kOverlayTicketOption$peerId', '');
    await setOption('$kOverlayRequiredOption$peerId', '');
  }

  Future<void> releaseAll() async {
    _generation++;
    for (final peerId in _grants.keys.toList()) {
      await release(peerId);
    }
  }

  /// Explicit fallback changes only the next dial, preserving any other open
  /// session's WireGuard grant to the same machine.
  Future<void> useRustDesk(String peerId) => _clearHints(peerId);

  bool get hasGrants => _grants.isNotEmpty;

  /// The daemon state the last readiness check saw, for the screen if wanted.
  OverlayState? lastStatus;
}
