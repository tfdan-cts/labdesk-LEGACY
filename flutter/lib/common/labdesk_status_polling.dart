import 'dart:async';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/common/labdesk_status_binding.dart';
import 'package:get/get.dart';

final RxBool labdeskStatusChecking = false.obs;
Timer? _checkingTimeout;

void labdeskStatusTick() {
  _checkingTimeout?.cancel();
  labdeskStatusChecking.value = false;
}

void labdeskMarkStatusStale() {
  labdeskStatusChecking.value = true;
  _checkingTimeout?.cancel();
  _checkingTimeout = Timer(const Duration(seconds: 10), () {
    labdeskStatusChecking.value = false;
  });
}

Future<void> labdeskRefreshStatus() async {
  labdeskMarkStatusStale();
  bind.mainLoadRecentPeers();
  bind.mainLoadFavPeers();
  final ids = <String>{};
  for (final p in gFFI.recentPeersModel.peers) {
    ids.add(p.id);
  }
  for (final p in gFFI.favoritePeersModel.peers) {
    ids.add(p.id);
  }
  for (final p in gFFI.peerTabModel.currentTabCachedPeers) {
    ids.add(p.id);
  }
  if (ids.isNotEmpty) {
    // Mark the ask before it goes out, so the console can show it as open
    // until the server answers or the binding writes it off.
    labdeskStatus.beginQuery(ids);
    bind.queryOnlines(ids: ids.toList(growable: false));
  }
}
