import 'package:uuid/uuid.dart';

typedef DesktopSessionContext = (String credential, int revision);

/// Main-window authority is read at dispatch time, never copied into a window.
class DesktopSessionAccess {
  static const verifyMethod = 'labdesk_verify_command_authority';
  static const resetCommandsMethod = 'labdesk_reset_command_sessions';
  DesktopSessionContext? Function()? _readContext;
  DesktopSessionContext? Function()? get readContext => _readContext;
  set readContext(DesktopSessionContext? Function()? reader) {
    if (identical(reader, _readContext)) return;
    _readContext = reader;
    _observed = null;
    _issued = null;
  }
  DesktopSessionContext? _observed;
  DesktopSessionContext? _issued;
  int _revision = 0;
  DesktopSessionContext? _nonceContext;
  String? _nonce;

  DesktopSessionContext? capture() {
    final value = _readContext?.call();
    if (value == null) {
      _observed = null;
      _issued = null;
    } else if (value != _observed) {
      _observed = value;
      _issued = (value.$1, ++_revision);
    }
    return _issued;
  }

  bool accepts(DesktopSessionContext? context) =>
      context != null && context == capture();

  /// Window RPCs carry an opaque context marker, never the account credential.
  String? nonceFor(DesktopSessionContext? context) {
    final current = capture();
    if (current != _nonceContext) {
      _nonceContext = current;
      _nonce = current == null ? null : const Uuid().v4();
    }
    return context != null && context == current ? _nonce : null;
  }

  bool acceptsNonce(Object? nonce) =>
      nonce is String && nonce == nonceFor(capture());
}

final desktopSessionAccess = DesktopSessionAccess();
