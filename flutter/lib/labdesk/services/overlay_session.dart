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

typedef _ScopedGrant = ({SessionGrant grant, OverlayBroker broker, String mode});
typedef _GrantOwner = ({String peerId, String owner});

/// A session grant from lab-desk.net, from asking for it to releasing it.
///
/// `prepare` asks for the rule, waits for the daemon's target peer and the
/// target's ticket acknowledgement, then writes the address hint,
/// the target's id key and the one-time connect ticket for the client.
/// With lazy connections, the authenticated dial activates WireGuard; waiting
/// for Connected first would prevent the traffic needed to start the tunnel.
/// Anything short of that clears stale hints and exposes the failure.
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

  /// A command link and each window family own separate grants to one peer.
  final _grants = <_GrantOwner, ({List<_ScopedGrant> grants, bool seenOpen})>{};
  final _preparing = <String>{};
  final _pendingReleases = <({String id, OverlayBroker broker})>{};
  int _generation = 0;

  String lastError = '';
  OverlayLinkType lastLink = OverlayLinkType.unknown;

  /// Polls a grant may sit unseen before it is treated as a connect that
  /// never happened and released. The console polls sessions every second
  /// or so, and a connect that has not opened in this many is not opening.
  static const unseenPollLimit = 30;
  final _unseenPolls = <_GrantOwner, int>{};

  static String _modeOwner(String mode) => switch (mode) {
    'terminal_admin' => 'terminal',
    'rdp' => 'tcp',
    _ => mode,
  };

  /// True when the client was handed the overlay address for [peerId].
  /// Account rejection is rethrown so callers require sign-in before fallback.
  /// [onAuthenticationFailure] runs synchronously before awaited cleanup.
  Future<bool> prepare(String peerId,
      {String mode = 'desktop', String? owner, void Function(OverlayBrokerException)? onAuthenticationFailure}) async {
    if (!_preparing.add(peerId)) {
      lastError =
          'A labnet connection to this machine is already being prepared.';
      return false;
    }
    SessionGrant? grant;
    late final OverlayBroker scopedBroker;
    var prepared = false;
    final generation = _generation;
    final key = (peerId: peerId, owner: owner ?? _modeOwner(mode));
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
      // Every await may outlive a console account or organization switch.
      // Keep creation, readiness and all cleanup under the original scope.
      scopedBroker = broker.captureScope(targetPeerId: peerId);
      var creationTimedOut = false;
      final creating = scopedBroker.session(peerId, mode: mode).then((created) async {
        // Creation changes server state. Retain ownership of a late answer
        // so timing out the caller cannot abandon the returned grant.
        if (creationTimedOut) await _endGrant(created.id, scopedBroker);
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
        ticketReady =
            await scopedBroker.sessionReady(grant.id).timeout(remaining());
        if (cancelled()) return false;
        if (status.isUp && peer != null &&
            (peer.connected || status.lazyConnectionEnabled) && ticketReady) {
          lastLink = peer.link;
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
      final previous = _grants[key];
      _grants[key] = (
        grants: [...?previous?.grants, (grant: grant, broker: scopedBroker, mode: mode)],
        seenOpen: previous?.seenOpen ?? false,
      );
      _unseenPolls[key] = 0;
      grant = null; // The active-session tracker now owns its release.
      prepared = true;
      return true;
    } on TimeoutException {
      lastError = 'The labnet connection timed out while waiting for the '
          'tunnel and target service. Check both machines and try again.';
      return false;
    } on OverlayBrokerException catch (e) {
      lastError = e.message;
      if (e.signInAgain) {
        onAuthenticationFailure?.call(e);
        rethrow;
      }
      return false;
    } catch (e) {
      lastError = '$e';
      return false;
    } finally {
      try {
        if (!prepared) await _clearHints(peerId);
      } finally {
        try {
          if (grant != null) await _endGrant(grant.id, scopedBroker);
        } finally {
          _preparing.remove(peerId);
        }
      }
    }
  }

  /// Admission for an existing connection must reuse that connection's grant,
  /// never mint an unused ticket or borrow another window's authority.
  Future<bool> revalidate(String peerId,
      {required String mode, String? owner,
      void Function(OverlayBrokerException)? onAuthenticationFailure}) async {
    lastError = 'This connection has no matching authorized grant. Close and reopen it.';
    final key = (peerId: peerId, owner: owner ?? _modeOwner(mode));
    final held = _grants[key];
    if (held == null || held.grants.length != 1 || held.grants.single.mode != mode) return false;
    final grant = held.grants.single;
    final scoped = grant.broker;
    final generation = _generation;
    bool current() => generation == _generation &&
        _grants[key]?.grants.length == 1 && _grants[key]?.grants.single == grant &&
        scoped.baseUrl == broker.baseUrl && scoped.token() == broker.token() &&
        scoped.organizationId?.call() == broker.organizationId?.call() &&
        scoped.peerId() == broker.peerId() &&
        scoped.machineIdOf(scoped.peerId()) == broker.machineIdOf(broker.peerId()) &&
        scoped.machineIdOf(peerId) == broker.machineIdOf(peerId);
    if (!current()) return false;
    try {
      final allowed = await scoped.sessionAuthorized(grant.grant.id, peerId, mode)
          .timeout(const Duration(seconds: 15));
      if (!current()) return false;
      if (!allowed) {
        lastError = 'This session is no longer authorized. Close and reopen it.';
        return false;
      }
      lastError = '';
      return true;
    } on OverlayBrokerException catch (e) {
      lastError = e.message;
      if (e.signInAgain) {
        onAuthenticationFailure?.call(e);
        rethrow;
      }
      return false;
    } catch (_) {
      lastError = 'Could not confirm this session’s permissions. Try again.';
      return false;
    }
  }

  /// The peer ids of sessions the console currently sees open.
  Future<void> noteOpenSessions(Iterable<String> open,
      {Map<String, Set<String>>? owners}) async {
    await _retryReleases();
    final openSet = open.toSet();
    for (final id in _grants.keys.toList()) {
      final g = _grants[id];
      if (g == null) continue;
      if (openSet.contains(id.peerId) &&
          (owners == null || (owners[id.peerId]?.contains(id.owner) ?? false))) {
        _grants[id] = (grants: g.grants, seenOpen: true);
        _unseenPolls.remove(id);
      } else if (g.seenOpen) {
        await release(id.peerId, owner: id.owner);
      } else if ((_unseenPolls[id] = (_unseenPolls[id] ?? 0) + 1) >=
          unseenPollLimit) {
        // Never seen open: the connect failed or the operator gave up. Left
        // alone, its hint would make every later connect to this peer dial a
        // dead address first, and nothing else would ever clear it.
        await release(id.peerId, owner: id.owner);
      }
    }
  }

  /// Ends the grant for [peerId] whether or not the session ever opened.
  Future<void> release(String peerId, {String? owner}) async {
    final keys = _grants.keys.where((key) => key.peerId == peerId &&
        (owner == null || key.owner == owner)).toList();
    final grants = <_ScopedGrant>[];
    for (final key in keys) {
      grants.addAll(_grants.remove(key)!.grants);
      _unseenPolls.remove(key);
    }
    if (grants.isEmpty) return;
    try {
      if (!_grants.keys.any((key) => key.peerId == peerId)) await _clearHints(peerId);
    } finally {
      for (final grant in grants) {
        await _endGrant(grant.grant.id, grant.broker);
      }
    }
  }

  Future<void> _endGrant(String id, OverlayBroker scopedBroker) async {
    final release = (id: id, broker: scopedBroker);
    _pendingReleases.add(release);
    try {
      // DELETE is idempotent. A late response can safely be ignored and the
      // release retried, unlike session creation or publishing dial hints.
      if (await scopedBroker.endSession(id).timeout(const Duration(seconds: 10),
          onTimeout: () => false)) _pendingReleases.remove(release);
    } catch (_) {
      // A failed release remains owned here until the next session poll.
    }
  }

  Future<void> _retryReleases() async {
    for (final release in _pendingReleases.toList()) {
      await _endGrant(release.id, release.broker);
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
    for (final peerId in _grants.keys.map((key) => key.peerId).toSet()) {
      await release(peerId);
    }
  }

  bool get hasGrants => _grants.isNotEmpty;

  /// The daemon state the last readiness check saw, for the screen if wanted.
  OverlayState? lastStatus;
}
