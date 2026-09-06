import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/labdesk_peer_status.dart';

/// The dot beside a machine has three states, and the one that matters is
/// unknown: a machine nobody has asked about used to draw red, which told an
/// operator a healthy machine was down.
void main() {
  test('a machine nobody has asked about is unknown, not offline', () {
    expect(
        labdeskDotFor(
            checking: false,
            status: LabDeskPeerStatus.unknown,
            fallbackOnline: false),
        LabDeskDot.unknown);
  });

  test('an answered machine is online or offline', () {
    expect(
        labdeskDotFor(
            checking: false,
            status: LabDeskPeerStatus.online,
            fallbackOnline: false),
        LabDeskDot.online);
    expect(
        labdeskDotFor(
            checking: false,
            status: LabDeskPeerStatus.offline,
            fallbackOnline: true),
        LabDeskDot.offline);
  });

  test('a query in flight beats every per machine state', () {
    for (final s in [
      LabDeskPeerStatus.online,
      LabDeskPeerStatus.offline,
      LabDeskPeerStatus.unknown,
      null,
    ]) {
      expect(labdeskDotFor(checking: true, status: s, fallbackOnline: false),
          LabDeskDot.checking);
    }
  });

  test('a call site with no machine id falls back to its own boolean', () {
    expect(
        labdeskDotFor(checking: false, status: null, fallbackOnline: true),
        LabDeskDot.online);
    expect(
        labdeskDotFor(checking: false, status: null, fallbackOnline: false),
        LabDeskDot.offline);
  });
}
