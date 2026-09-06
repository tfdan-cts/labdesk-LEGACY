import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/labdesk/console_data.dart';

/// The adapter is what turns the client's peer lists and the reachability store
/// into the rows the console renders. It is kept free of the FFI and of
/// peer_model for the same reason the rest of this layer is: so it can be
/// tested without the generated bridge.
ConsolePeer _peer(
  String id, {
  String hostname = '',
  String platform = 'Windows',
  String alias = '',
  String username = '',
}) =>
    (
      id: id,
      hostname: hostname,
      platform: platform,
      alias: alias,
      username: username,
    );

void main() {
  group('buildMachineRows', () {
    test('organization machines appear without any recent or LAN peer', () {
      final rows = buildMachineRows(
        peers: const [],
        organizationPeers: [_peer('201', hostname: 'Remote office')],
        store: LabDeskPeerStatusStore(),
        historyOf: (_) => const [],
        serverStatusOf: (_) => LabDeskPeerStatus.online,
      );
      expect(rows.single.id, '201');
      expect(rows.single.status, LabDeskPeerStatus.online);
    });
    test('a machine listed by several sources appears once, from the first '
        'source that named it', () {
      final rows = buildMachineRows(
        peers: [
          _peer('101', hostname: 'workshop-nas', alias: 'Workshop NAS'),
          // The same machine as the address book holds it, with a stale alias.
          _peer('101', hostname: 'workshop-nas', alias: 'old-name'),
          _peer('102', hostname: 'front-desk'),
        ],
        store: LabDeskPeerStatusStore(),
        historyOf: (_) => const [],
      );

      expect(rows.length, 2,
          reason: 'recent, favourites and the current tab overlap; a machine in '
              'two of them is still one machine');
      expect(rows.firstWhere((r) => r.id == '101').displayName, 'Workshop NAS',
          reason: 'the earlier source wins, so a later store cannot overwrite '
              'the name the operator just saw');
    });

    test('rows carry the status the store holds, not a guess', () {
      final store = LabDeskPeerStatusStore();
      final at = DateTime.utc(2026, 8, 29, 12);
      store.applyResponse(onlines: ['101'], offlines: ['102'], at: at);

      final rows = buildMachineRows(
        peers: [_peer('101'), _peer('102'), _peer('103')],
        store: store,
        historyOf: (_) => const [],
      );

      final byId = {for (final r in rows) r.id: r};
      expect(byId['101']!.status, LabDeskPeerStatus.online);
      expect(byId['102']!.status, LabDeskPeerStatus.offline);
      expect(byId['103']!.status, LabDeskPeerStatus.unknown,
          reason: 'a machine no response has named has not been checked, which '
              'is not the same as being down');
    });

    test('a machine never named by a response carries no timestamps', () {
      final rows = buildMachineRows(
        peers: [_peer('103')],
        store: LabDeskPeerStatusStore(),
        historyOf: (_) => const [],
      );

      expect(rows.single.lastChecked, isNull);
      expect(rows.single.lastSeenOnline, isNull);
      expect(rows.single.sinceSeen(now: DateTime.utc(2026, 8, 29)), '--',
          reason: 'rendering 0s would read as "just now"');
    });

    test('rows are ordered by the name the operator sees', () {
      final rows = buildMachineRows(
        peers: [
          _peer('101', hostname: 'zeta'),
          _peer('102', hostname: 'alpha'),
          _peer('103', hostname: 'zzz', alias: 'beta'),
        ],
        store: LabDeskPeerStatusStore(),
        historyOf: (_) => const [],
      );

      expect(rows.map((r) => r.displayName).toList(),
          ['alpha', 'beta', 'zeta'],
          reason: 'the alias is what is shown, so it is what sorts');
    });

    test('the history comes from the caller, per machine', () {
      final rows = buildMachineRows(
        peers: [_peer('101'), _peer('102')],
        store: LabDeskPeerStatusStore(),
        historyOf: (id) => id == '101' ? const [true, false] : const [],
      );

      final byId = {for (final r in rows) r.id: r};
      expect(byId['101']!.history, [true, false]);
      expect(byId['102']!.history, isEmpty);
    });

    test('group membership is attached when the caller knows it', () {
      final rows = buildMachineRows(
        peers: [_peer('101'), _peer('102')],
        store: LabDeskPeerStatusStore(),
        historyOf: (_) => const [],
        groupOf: (id) => id == '101' ? 'lab' : null,
      );

      final byId = {for (final r in rows) r.id: r};
      expect(byId['101']!.group, 'lab');
      expect(byId['102']!.group, isNull);
    });

    test('an empty hostname falls back to the id rather than an empty row', () {
      final rows = buildMachineRows(
        peers: [_peer('101')],
        store: LabDeskPeerStatusStore(),
        historyOf: (_) => const [],
      );

      expect(rows.single.displayName, '101');
    });
  });
}
