import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/labdesk_profiles.dart';
import '../../common/labdesk_status_binding.dart';
import '../../labdesk/console_data.dart';
import '../../labdesk/models/machine_row.dart';
import '../../models/platform_model.dart';
import '../widgets/machine_list.dart';
import 'home_page.dart';

/// The phone's machine list.
///
/// This is the wiring only. Everything that decides what the operator sees is
/// either `buildMachineRows`, which the desktop console reads through as well,
/// or `MachineListView`, which takes its data through its constructor. Keeping
/// the split means the list can be tested without the generated bridge.
class MachinesPage extends StatefulWidget implements PageShape {
  MachinesPage({Key? key}) : super(key: key);

  @override
  final title = translate("Machines");

  @override
  final icon = const Icon(Icons.devices_other);

  @override
  final List<Widget> appBarActions = [];

  @override
  State<MachinesPage> createState() => _MachinesPageState();
}

class _MachinesPageState extends State<MachinesPage> {
  /// While the list is on screen. The phone does not poll in the background;
  /// nothing here runs once the page is disposed.
  static const _pollEvery = Duration(seconds: 30);

  Timer? _poll;
  final Set<String> _savedPasswords = {};

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(_pollEvery, (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    await labdeskRefreshStatus();
    await _readSavedPasswords();
    if (mounted) setState(() {});
  }

  /// Which machines this client already holds a password for, so the list can
  /// say which taps will ask for one. Read rather than assumed: a password the
  /// operator deleted elsewhere must stop being advertised here.
  Future<void> _readSavedPasswords() async {
    final found = <String>{};
    for (final id in {for (final p in _peers) p.id}) {
      if (await bind.mainPeerHasPassword(id: id)) found.add(id);
    }
    if (!mounted) return;
    _savedPasswords
      ..clear()
      ..addAll(found);
  }

  /// Every store the client keeps peers in. They overlap; the adapter folds
  /// them by id. This is the same set the desktop console reads.
  Iterable<ConsolePeer> get _peers sync* {
    for (final list in [
      gFFI.recentPeersModel.peers,
      gFFI.favoritePeersModel.peers,
      gFFI.abModel.peersModel.peers,
      gFFI.lanPeersModel.peers,
      gFFI.peerTabModel.currentTabCachedPeers,
    ]) {
      for (final p in list) {
        yield (
          id: p.id,
          hostname: p.hostname,
          platform: p.platform,
          alias: p.alias,
          username: p.username,
        );
      }
    }
  }

  List<MachineRow> get _machines => buildMachineRows(
        peers: _peers,
        store: labdeskStatus.store,
        historyOf: labdeskStatus.historyOf,
      );

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      // The store keeps its states in a plain map, so a response folded into it
      // changes nothing this widget watches. The binding's revision is what
      // makes an answer arriving repaint the list.
      child: Obx(() {
        labdeskStatus.revision.value;
        final machines = _machines;
        return MachineListView(
          machines: machines,
          savedPasswords: _savedPasswords,
          checking: {
            for (final m in machines)
              if (labdeskStatus.store.isQueryingPeer(m.id)) m.id
          },
          onConnect: (id) => connect(context, id),
          onConnectToFirstMachine: () =>
              HomePage.homeKey.currentState?.showConnectionPage(),
        );
      }),
    );
  }
}
