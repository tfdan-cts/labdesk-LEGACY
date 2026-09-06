import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';
import 'package:flutter_hbb/labdesk/theme/ld_icons.dart';
import 'package:flutter_hbb/labdesk/theme/settings_skin.dart';

double contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
}

void main() {
  test('legacy constants and default theme remain dark', () {
    expect(C.bg, const Color(0xff11171b));
    expect(C.accent, const Color(0xffa5dce7));
    expect(C.body().color, C.text);
    expect(C.theme().brightness, Brightness.dark);
  });

  for (final brightness in Brightness.values) {
    test('palette text and primary states have readable contrast: $brightness',
        () {
      final palette = brightness == Brightness.dark
          ? ConsolePalette.dark
          : ConsolePalette.light;
      for (final surface in [
        palette.bg,
        palette.chrome,
        palette.surface,
        palette.surfaceHi
      ]) {
        for (final foreground in [
          palette.text,
          palette.textMuted,
          palette.textFaint,
          palette.accent,
          palette.ok,
          palette.bad,
          palette.warning
        ]) {
          expect(contrast(foreground, surface), greaterThanOrEqualTo(4.5),
              reason: '$foreground on $surface');
        }
      }
      for (final fill in [
        palette.primaryFill,
        palette.primaryFillHover,
        palette.primaryFillDown
      ]) {
        expect(contrast(palette.primaryFg, fill), greaterThanOrEqualTo(4.5));
      }
      expect(palette.body().fontFamily, 'Manrope');
      expect(palette.body().color, palette.text);
      expect(palette.small().color, palette.textMuted);
      expect(palette.micro().color, palette.textFaint);
      expect(palette.data().fontFamily, 'JetBrainsMono');
    });

    testWidgets(
        'menus inputs tabs and disabled actions share palette: $brightness',
        (tester) async {
      final theme = C.theme(brightness: brightness);
      final palette = brightness == Brightness.dark
          ? ConsolePalette.dark
          : ConsolePalette.light;
      await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(
              body: Column(children: [
            const TextField(
                decoration: InputDecoration(labelText: 'Machine name')),
            DropdownButtonFormField<String>(
                value: 'one',
                items: const [
                  DropdownMenuItem(value: 'one', child: Text('First fleet')),
                  DropdownMenuItem(value: 'two', child: Text('Second fleet')),
                ],
                onChanged: (_) {}),
            PopupMenuButton<String>(
                itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: 'action', child: Text('Machine action'))
                    ]),
            const FilledButton(onPressed: null, child: Text('Unavailable')),
          ]))));
      expect(theme.colorScheme.onSurface, palette.text);
      expect(theme.textTheme.bodyMedium!.fontFamily, 'Manrope');
      expect(theme.inputDecorationTheme.fillColor, palette.surface);
      expect(theme.tabBarTheme.labelColor, palette.accent);
      expect(
          theme.filledButtonTheme.style!.foregroundColor!
              .resolve({WidgetState.disabled}),
          palette.textFaint);
      expect(
          theme.filledButtonTheme.style!.backgroundColor!
              .resolve({WidgetState.disabled}),
          Colors.transparent);
      expect(
          theme.outlinedButtonTheme.style!.side!
              .resolve({WidgetState.focused})!.color,
          palette.focusRing);
      await tester.tap(find.text('First fleet'));
      await tester.pumpAndSettle();
      expect(find.text('Second fleet'), findsOneWidget);
      expect(Theme.of(tester.element(find.text('Second fleet'))).canvasColor,
          palette.surface);
      await tester.tap(find.text('Second fleet'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Machine action'), findsOneWidget);
      expect(
          Theme.of(tester.element(find.text('Machine action')))
              .popupMenuTheme
              .color,
          palette.surfaceHi);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'nested light and dark themes resolve independently without globals',
      (tester) async {
    final colors = <Color>[];
    await tester.pumpWidget(MaterialApp(
        theme: C.theme(),
        home: Column(children: [
          Builder(builder: (context) {
            colors.add(C.of(context).bg);
            return const SizedBox();
          }),
          Theme(
              data: C.theme(brightness: Brightness.light),
              child: Builder(builder: (context) {
                colors.add(C.of(context).bg);
                return const Panel(
                    title: 'Light panel', child: Text('Content'));
              })),
          Builder(builder: (context) {
            colors.add(C.of(context).bg);
            return const SizedBox();
          }),
        ])));
    expect(colors, [C.bg, const Color(0xfff4f7f7), C.bg]);
    expect(tester.widget<Text>(find.text('Light panel')).style!.color,
        ConsolePalette.light.text);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ghost action supports keyboard activation and disabled state',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
        theme: C.theme(brightness: Brightness.light),
        home: Scaffold(
            body: GhostButton(label: 'Run', onPressed: () => taps++))));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 1);
    await tester.pumpWidget(MaterialApp(
        theme: C.theme(),
        home: const Scaffold(body: GhostButton(label: 'Run'))));
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  for (final brightness in Brightness.values) {
    testWidgets('settings page and custom dropdown preserve $brightness',
        (tester) async {
      final p = brightness == Brightness.dark
          ? ConsolePalette.dark
          : ConsolePalette.light;
      final controller = TextEditingController(text: '21116');
      addTearDown(controller.dispose);
      String? chosen;
      await tester.pumpWidget(MaterialApp(
          theme: C.theme(brightness: brightness),
          home: Scaffold(
              body: SettingsPage(children: [
            SettingsGroup(title: 'Connection', children: [
              const SettingsRow(label: 'Network port'),
              LdTextField(controller: controller),
              LdSelect(
                  keys: const ['a', 'b'],
                  values: const ['Automatic', 'Manual'],
                  initialKey: 'a',
                  onChanged: (value) => chosen = value),
              const LdRadioMark(selected: true),
              LdButton(
                  label: 'Apply', onPressed: () {}, kind: LdButtonKind.primary),
            ]),
          ]))));
      expect(tester.widget<Text>(find.text('Connection')).style!.color, p.text);
      expect(tester.widget<TextField>(find.byType(TextField)).style!.color,
          p.text);
      expect(Theme.of(tester.element(find.byType(LdTextField))).brightness,
          brightness);
      expect(
          Theme.of(tester.element(find.byType(LdTextField)))
              .dropdownMenuTheme
              .menuStyle!
              .backgroundColor!
              .resolve({}),
          p.surfaceHi);
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
              .dropdownColor,
          p.surface);
      final option = find.text('Manual').last;
      expect(tester.widget<Text>(option).style!.color, p.text);
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(chosen, 'b');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('toggle supports keyboard activation and theme-aware marks',
      (tester) async {
    var enabled = false;
    await tester.pumpWidget(MaterialApp(
        theme: C.theme(brightness: Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
              builder: (context, setState) => Column(children: [
                    LdToggle(
                        value: enabled,
                        onChanged: (value) => setState(() => enabled = value)),
                    const LdCheckbox(on: true),
                  ])),
        )));
    expect(tester.widget<LdIcon>(find.byType(LdIcon)).color,
        ConsolePalette.light.primaryFg);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(enabled, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
    expect(tester.takeException(), isNull);
  });
}
