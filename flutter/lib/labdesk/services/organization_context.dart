import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../models/dashboard_layout.dart';
import '../models/organization_context.dart';
import 'overlay_broker.dart';

/// Desktop context and local layout preferences. Network enrollment is owned by
/// the machine and is deliberately absent from this controller.
class OrganizationContextController extends ChangeNotifier {
  OrganizationContextController({
    required this.broker,
    required this.readOption,
    required this.writeOption,
  });

  final OverlayBroker broker;
  final String Function(String key) readOption;
  final Future<void> Function(String key, String value) writeOption;
  String _credential = '';
  String userId = '';
  String? activeId;
  List<OrganizationSummary> organizations = const [];
  DashboardLayout? layout;
  String? error;
  bool busy = false;
  bool _authenticated = false;
  int revision = 0;
  int _credentialRevision = 0;
  int _selection = 0;
  int _layoutSave = 0;
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  bool _disposed = false;

  bool matchesCredential(String value) => value == _credential;
  /// An accepted account can exist without a selected organization.
  bool get authenticated => !_disposed && _authenticated;
  bool get ready => authenticated && userId.isNotEmpty && activeId != null;
  String get contextKey => '${_key(userId)}/${_key(activeId ?? '')}';
  String get _organizationPreference => 'labdesk-ui-org-v1-${_key(userId)}';
  String get _layoutPreference => 'labdesk-dashboard-v1-$contextKey';
  static String _key(String value) => base64Url.encode(utf8.encode(value));
  bool _current(int credential, int selection) =>
      !_disposed &&
      credential == _credentialRevision &&
      selection == _selection;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// A rejected organization read invalidates cached authority immediately.
  /// A later refresh reloads membership using the same current credential.
  void invalidate(String message) {
    if (_disposed) return;
    revision++;
    _credentialRevision++;
    _selection++;
    _loading = null;
    _authenticated = false;
    userId = '';
    activeId = null;
    organizations = const [];
    layout = null;
    busy = false;
    error = message;
    _notify();
  }

  Future<void> syncCredential(String value) async {
    if (_disposed) return;
    if (value != _credential) {
      _credential = value;
      revision++;
      _credentialRevision++;
      _selection++;
      _loading = null;
      _authenticated = false;
      userId = '';
      activeId = null;
      organizations = const [];
      layout = null;
      error = null;
      busy = false;
      _notify();
    }
    if (value.isEmpty || ready) return;
    if (_loading != null) return _loading;
    if (busy) return;
    final loading = _loadDirectory(_credentialRevision, ++_selection);
    _loading = loading;
    try {
      await loading;
    } finally {
      if (identical(_loading, loading)) _loading = null;
    }
  }

  Future<void> _loadDirectory(int credential, int selection) async {
    busy = true;
    error = null;
    // Directory and verification must use the same credential even if the
    // runtime token callback changes while the first request is in flight.
    final scopedBroker = broker.captureScope();
    _notify();
    try {
      final directory = await scopedBroker.organizations();
      if (!_current(credential, selection)) return;
      _authenticated = true;
      userId = directory.userId;
      organizations = List.unmodifiable({
        for (final org in directory.organizations) org.id: org,
      }.values);
      final saved = readOption(_organizationPreference);
      final selected = organizations.any((org) => org.id == saved)
          ? saved
          : organizations.length == 1
              ? organizations.single.id
              : null;
      if (selected != null) {
        await scopedBroker.verifyOrganization(selected);
        if (!_current(credential, selection)) return;
        activeId = selected;
        revision++;
        _readLayout();
      } else {
        error = organizations.isEmpty
            ? 'No organization is linked to this account.'
            : 'Choose an organization to see its machines.';
      }
    } catch (failure) {
      if (_current(credential, selection)) {
        if (failure is OverlayBrokerException && failure.signInAgain) {
          invalidate(failure.message);
          return;
        }
        error = failure is OverlayBrokerException
            ? failure.message
            : 'Organizations could not be loaded. Try refreshing.';
      }
    } finally {
      if (_current(credential, selection)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> select(String id) async {
    if (_disposed) return;
    if (!organizations.any((org) => org.id == id)) {
      error = 'This organization is not available to your account.';
      _notify();
      return;
    }
    final credential = _credentialRevision, selection = ++_selection;
    final preference = _organizationPreference;
    var verified = id == activeId;
    busy = !verified;
    error = null;
    _notify();
    try {
      if (!verified) {
        await broker.captureScope().verifyOrganization(id);
        if (!_current(credential, selection)) return;
        verified = true;
        activeId = id;
        revision++;
      }
      _readLayout();
      // Re-selecting the active organization cancels an older pending switch
      // and also allows a failed preference write to be retried.
      busy = false;
      _notify();
      await _write(preference, id);
    } catch (failure) {
      if (_current(credential, selection)) {
        if (failure is OverlayBrokerException && failure.signInAgain) {
          invalidate(failure.message);
          return;
        }
        error = failure is OverlayBrokerException
            ? failure.message
            : verified
                ? 'The organization preference could not be saved. Select it again to retry.'
                : 'The organization could not be verified. Try selecting it again.';
        busy = false;
        _notify();
      }
    }
  }

  void _readLayout() {
    layout = null;
    try {
      final raw = readOption(_layoutPreference);
      if (raw.isEmpty) return;
      if (raw.length > 262144) {
        throw const FormatException('Layout exceeds limit');
      }
      layout = DashboardLayout.fromJson(jsonDecode(raw));
      if (layout == null) throw const FormatException('Unsupported layout');
    } catch (_) {
      error =
          'The saved layout could not be read. The default layout is shown.';
    }
  }

  /// Serialize the small local preference writes. An older write must never
  /// land after a newer value for the same account; failures cannot jam retries.
  Future<void> _write(String key, String value) {
    final write = _writes.then((_) => writeOption(key, value));
    _writes = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  Future<void> saveLayout(DashboardLayout next) async {
    if (_disposed || !ready) {
      throw StateError('Choose an organization before saving a layout.');
    }
    final version = revision, save = ++_layoutSave;
    final option = _layoutPreference;
    await _write(option, jsonEncode(next.toJson()));
    if (_disposed || version != revision || save != _layoutSave) return;
    layout = next;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    revision++;
    super.dispose();
  }
}
