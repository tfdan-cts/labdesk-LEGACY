import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/screens/terms_dialog.dart';
import 'package:url_launcher/link.dart';

Future<void> _open(WidgetTester tester,
    {ThemeData? theme, FocusNode? triggerFocus, double textScale = 1}) async {
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          autofocus: true,
          focusNode: triggerFocus,
          onPressed: () => showLabDeskTerms(context),
          child: const Text('Open terms'),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Open terms'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the complete review draft and original software links',
      (tester) async {
    await _open(tester);
    expect(find.text('Terms of Service'), findsOneWidget);
    expect(find.text('LabDesk · TrapLab Studios'), findsOneWidget);
    expect(find.textContaining('This draft is not an active agreement.'),
        findsOneWidget);
    expect(
        find.textContaining(
            'Viewing this document does not constitute acceptance.'),
        findsOneWidget);
    expect(
        find.textContaining(
            'Operator jurisdiction and a monitored public contact'),
        findsOneWidget);
    expect(
        find.textContaining('A Privacy Notice must accompany'), findsOneWidget);
    expect(find.text('Accept'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    final headings = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .where((widget) => widget.properties.header == true);
    expect(headings, hasLength(14));
    expect(
        tester
            .widgetList<Link>(find.byType(Link))
            .map((link) => link.uri.toString()),
        [
          'https://www.gnu.org/licenses/agpl-3.0.html',
          'https://github.com/tfdan-cts/LabDesk',
        ]);
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scroll.controller!.position.maxScrollExtent, greaterThan(0));
    scroll.controller!.jumpTo(scroll.controller!.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('14. General provisions').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape and Close dismiss the dialog and restore trigger focus',
      (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await _open(tester, triggerFocus: focus);
    expect(focus.hasFocus, isFalse);
    final close = tester.element(find.byTooltip('Close Terms of Service'));
    expect(Focus.of(close).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(focus.hasFocus, isTrue);

    await tester.tap(find.text('Open terms'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(focus.hasFocus, isTrue);
  });

  for (final brightness in Brightness.values) {
    for (final size in [const Size(320, 568), const Size(640, 320)]) {
      testWidgets('uses $brightness theme at $size with enlarged text',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final theme = ThemeData(brightness: brightness, useMaterial3: true);
        await _open(tester, theme: theme, textScale: 2);
        final dialog = tester.widget<Dialog>(find.byType(Dialog));
        expect(dialog.backgroundColor, theme.colorScheme.surface);
        expect(tester.takeException(), isNull);
        expect(find.text('Close').hitTestable(), findsOneWidget);
        final scroll = tester
            .widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
        expect(scroll.controller!.position.viewportDimension, greaterThan(0));
        await tester.ensureVisible(find.text('14. General provisions'));
        await tester.pumpAndSettle();
        expect(
            find.text('14. General provisions').hitTestable(), findsOneWidget);
        scroll.controller!.jumpTo(scroll.controller!.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.text('Close').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
