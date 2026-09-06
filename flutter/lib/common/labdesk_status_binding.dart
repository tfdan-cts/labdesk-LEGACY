import 'package:get/get.dart';

import 'labdesk_peer_status.dart';
import '../labdesk/models/reach_sample.dart';

/// Turns the client's online-state events into everything the console renders.
///
/// This sits between peer_model, which owns the FFI, and the widgets, which
/// own none of it. Keeping the parsing and the history here means the whole
/// path can be tested without the generated bridge, which does not exist
/// outside CI, and means the console can be looked at without a peer.
class LabDeskStatusBinding {
  LabDeskStatusBinding(this.store);

  final LabDeskPeerStatusStore store;

  /// How many checks are kept per machine. Twelve at the client's polling
  /// interval is a readable strip that covers the recent past without
  /// pretending to be a time series.
  static const historyLength = 12;

  /// Bumped whenever a fold changes what a widget would draw. Widgets read it
  /// inside an Obx so a per machine state, which the store holds in a plain
  /// map, still repaints when an answer lands. Nothing else reads it.
  final RxInt revision = 0.obs;

  final Map<String, List<bool>> _history = {};
  final List<ReachSample> _samples = [];

  /// Fleet readings for the session chart. Capped for the same reason as the
  /// history: this is a session view, not retained monitoring.
  static const maxSamples = 240;

  List<ReachSample> get samples => List.unmodifiable(_samples);

  bool get isQuerying => store.isQuerying;

  /// How long a query may stay in flight before it is written off. The Rust
  /// side gives up on the ID server well inside this, so anything older is a
  /// query whose answer is never coming.
  static const queryTimeout = Duration(seconds: 8);

  DateTime? _lastQueryAt;
  DateTime? _lastResponseAt;

  /// When the server last answered. Null until it has. This is the honest
  /// "checked" stamp: asking is not the same as being told.
  DateTime? get lastResponseAt => _lastResponseAt;

  /// Whether the poller should ask again: never while a question is still
  /// open, and otherwise once [every] has passed since the last ask.
  bool isDue(DateTime now, Duration every) {
    if (store.isQuerying) return false;
    final last = _lastQueryAt;
    return last == null || now.difference(last) >= every;
  }

  /// Write off a query that has outlived [queryTimeout]. Nothing else changes.
  void expireStale(DateTime now) {
    final last = _lastQueryAt;
    if (store.isQuerying &&
        last != null &&
        now.difference(last) >= queryTimeout) {
      store.endQuery();
    }
  }

  List<bool?> historyOf(String id) => List.unmodifiable(_history[id] ?? const []);

  void beginQuery(Iterable<String> ids, {DateTime? at}) {
    _lastQueryAt = at ?? DateTime.now();
    store.beginQuery(ids);
    revision.value++;
  }

  /// A query that errored or never came back.
  ///
  /// Clears the in-flight marker and nothing else. The Rust side reports a
  /// failure rather than an empty online list, so there is no result to apply
  /// and every machine keeps the state it already had.
  void onQueryFailedOrTimedOut() {
    store.endQuery();
    revision.value++;
  }

  /// Fold one online-state event into the store.
  ///
  /// The client sends comma separated id lists, so an empty list arrives as a
  /// single empty string and must not become a tracked machine.
  void onOnlineStateEvent({
    required String onlines,
    required String offlines,
    DateTime? at,
  }) {
    final now = at ?? DateTime.now();
    final up = _split(onlines);
    final down = _split(offlines);
    if (up.isEmpty && down.isEmpty) {
      store.endQuery();
      revision.value++;
      return;
    }

    _lastResponseAt = now;
    store.applyResponse(onlines: up, offlines: down, at: now);

    for (final id in up) {
      _push(id, true);
    }
    for (final id in down) {
      _push(id, false);
    }

    _samples.add(ReachSample(now, up.length, up.length + down.length));
    if (_samples.length > maxSamples) {
      _samples.removeRange(0, _samples.length - maxSamples);
    }

    store.endQuery();
    revision.value++;
  }

  void forget(String id) {
    _history.remove(id);
    store.forget(id);
    revision.value++;
  }

  void clear() {
    _history.clear();
    _samples.clear();
    _lastQueryAt = null;
    _lastResponseAt = null;
    store.clear();
  }

  void _push(String id, bool up) {
    final list = _history.putIfAbsent(id, () => <bool>[]);
    list.add(up);
    if (list.length > historyLength) {
      list.removeRange(0, list.length - historyLength);
    }
  }

  static List<String> _split(String csv) => csv
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}

/// The client-wide instance. peer_model feeds it; the console reads it.
final labdeskStatus = LabDeskStatusBinding(LabDeskPeerStatusStore());
