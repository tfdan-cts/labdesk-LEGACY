import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/labdesk/services/desktop_session_access.dart';

void main() {
  final previousDesktopType = desktopType;
  setUp(() {
    desktopSessionAccess.readContext = null;
    desktopType = DesktopType.main;
  });
  tearDown(() {
    desktopSessionAccess.readContext = null;
    desktopType = previousDesktopType;
  });

  test('unauthenticated desktop URLs are rejected before native dispatch', () {
    expect(handleUriLink(uri: Uri.parse('labdesk://123456')), isFalse);
    expect(handleUriLink(cmdArgs: ['--terminal-admin', '123456']), isFalse);
    expect(handleUriLink(uriString: 'labdesk://connection/new/123456'), isFalse);
  });

  test('a window connection request cannot bypass startup authentication',
      () async {
    // Native bindings are deliberately absent: rejected calls must not touch
    // the manager, a saved password, or a native connection.
    await connectMainDesktop('123456',
        isFileTransfer: false,
        isViewCamera: false,
        isTerminal: true,
        isTcpTunneling: false,
        isRDP: false);
  });

  test('queued authenticated URLs are cancelled after account A to B to A',
      () async {
    DesktopSessionContext? current = ('account-a', 1);
    desktopSessionAccess.readContext = () => current;
    for (final mode in [
      'connect', 'file-transfer', 'view-camera', 'port-forward', 'rdp',
      'terminal-admin',
    ]) {
      expect(handleUriLink(uri: Uri.parse('labdesk://$mode/123456')), isTrue);
    }
    current = ('account-b', 2);
    current = ('account-a', 3);
    // Every delayed callback must stop before touching native window bindings
    // or terminal-admin environment state, which are absent in this fixture.
    await Future<void>.delayed(Duration.zero);
  });

  testWidgets('direct Connect refuses access before resolving a peer',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox.shrink();
    })));
    await connect(context, '123456');
    expect(tester.takeException(), isNull);
  });
}
