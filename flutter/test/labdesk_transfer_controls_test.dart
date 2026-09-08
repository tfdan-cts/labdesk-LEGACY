import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';
import 'package:flutter_hbb/labdesk/theme/file_manager_skin.dart';
import 'package:flutter_hbb/labdesk/theme/ld_icons.dart';
import 'package:flutter_hbb/labdesk/theme/session_toolbar_skin.dart';

void main() {
  testWidgets(
      'file actions, sort headers and breadcrumbs work from the keyboard',
      (tester) async {
    var refresh = 0, send = 0, sort = 0, crumb = 0;
    await tester.pumpWidget(MaterialApp(
        theme: C.theme(),
        home: Scaffold(
            body: Row(children: [
          FmToolButton(
              glyph: LdIcons.refresh,
              tooltip: 'Refresh',
              onPressed: () => refresh++),
          FmToolButton(
              glyph: LdIcons.trash, tooltip: 'Delete', onPressed: null),
          FmSendButton(
              label: 'Send',
              glyph: LdIcons.fileTransfer,
              onPressed: () => send++),
          FmColumnHead(
              label: 'Name', ascending: true, width: 100, onTap: () => sort++),
          FmCrumb(label: 'Home', current: false, onTap: () => crumb++),
        ]))));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(refresh, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(send, 1, reason: 'Disabled Delete must be skipped');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sort, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(crumb, 1);
  });

  testWidgets('remote toolbar shows keyboard focus and exposes its action',
      (tester) async {
    var presses = 0;
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(MaterialApp(
        theme: C.theme(),
        home: Scaffold(
            body: ToolbarIconButton(
          glyph: LdIcons.close,
          tooltip: 'Disconnect',
          color: C.bad,
          hoverColor: C.text,
          onPressed: () => presses++,
        ))));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final focusedSurface = tester.widget<AnimatedContainer>(find.descendant(
        of: find.byType(ToolbarButtonSurface),
        matching: find.byType(AnimatedContainer)));
    expect((focusedSurface.decoration as BoxDecoration).border!.top.color,
        C.focusRing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(presses, 1);
    expect(find.byTooltip('Disconnect'), findsOneWidget);
    semantics.dispose();
  });
}
