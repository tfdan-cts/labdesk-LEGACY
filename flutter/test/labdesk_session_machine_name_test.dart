import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class PeerBoundary extends Fake implements LabDeskImpl {
  String peer = '{"info":{"hostname":"Foundry"}}';
  @override
  String mainGetPeerSync({required String id, dynamic hint}) => peer;
}

void main() {
  final native = PeerBoundary();
  setUp(() => platformFFI.ffiBind = native);
  test('session tabs use the stored machine name instead of its transport ID',
      () {
    expect(getDesktopTabLabel('opaque-peer-123', ''), 'Foundry');
    expect(getDesktopTabLabel('100.80.0.4:21118', ''), 'Foundry');
    expect(getDesktopTabLabel('opaque-peer-123', 'Build workstation'),
        'Build workstation');
    native.peer = '{"info":{"hostname":"  "}}';
    expect(getDesktopTabLabel('opaque-peer-123', ''), 'opaque-peer-123');
    native.peer = '{}';
    expect(getDesktopTabLabel('opaque-peer-123', ''), 'opaque-peer-123');
    native.peer = 'invalid';
    expect(getDesktopTabLabel('opaque-peer-123', 'My machine'), 'My machine');
  });
}
