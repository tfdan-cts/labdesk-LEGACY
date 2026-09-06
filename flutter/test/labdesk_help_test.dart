import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/help_content.dart';
import 'package:flutter_hbb/labdesk/screens/help_screen.dart';

Future<void> mount(WidgetTester tester,
    {String topic = 'fleet',
    Size size = const Size(1280, 900),
    double textScale = 1,
    Brightness brightness = Brightness.dark}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
          useMaterial3: true,
          brightness: brightness,
          colorSchemeSeed: Colors.cyan),
      home: MediaQuery(
          data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true),
          child: Scaffold(body: HelpScreen(initialTopic: topic)))));
  await tester.pumpAndSettle();
}

void main() {
  test('manual covers every destination and glossary with traceable guidance',
      () {
    expect(helpTopics.map((t) => t.id).toSet(), {
      'home',
      'fleet',
      'jobs',
      'automation',
      'labnets',
      'device',
      'sessions',
      'organizations',
      'glossary'
    });
    final ids = <String>{};
    for (final topic in helpTopics) {
      expect(topic.entries.length, greaterThanOrEqualTo(3));
      for (final entry in topic.entries) {
        expect(ids.add(entry.id), isTrue,
            reason: 'Help entry IDs must be unique');
        expect(entry.meaning, isNotEmpty);
        expect(entry.action, isNotEmpty);
        expect(entry.technical, isNotEmpty);
        expect(entry.references, isNotEmpty,
            reason: '${entry.id} needs implementation references');
      }
    }
  });

  test('search finds terms across topics and matches multiple words', () {
    expect(
        searchHelp('cooldown').any((r) => r.topic.id == 'automation'), isTrue);
    expect(searchHelp('source clock').any((r) => r.entry.id == 'freshness'),
        isTrue);
    expect(
        searchHelp('full access').any((r) => r.entry.id == 'access'), isTrue);
    expect(searchHelp('no-such-phrase-947'), isEmpty);
    expect(searchHelp('  '), isEmpty);
    expect(helpTopicForContext('health'), 'fleet');
    expect(helpTopicForContext('thisMachine'), 'device');
    expect(helpTopicForContext('unknown-context'), 'fleet');
  });

  testWidgets(
      'context opens the relevant topic and technical details are expandable',
      (tester) async {
    await mount(tester, topic: 'health');
    expect(find.text('Online, offline & unknown'), findsOneWidget);
    final disclosure =
        find.byKey(const ValueKey('help-technical-reachability'));
    await tester.tap(disclosure);
    await tester.pumpAndSettle();
    expect(find.textContaining('twice the configured flush interval'),
        findsOneWidget);
    final tile = tester.widget<ExpansionTile>(disclosure);
    expect(tile.expansionAnimationStyle!.duration, Duration.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search is global, clearable and keyboard accessible',
      (tester) async {
    await mount(tester, topic: 'home');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('help-search')))
            .focusNode!
            .hasFocus,
        isTrue);
    await tester.enterText(
        find.byKey(const ValueKey('help-search')), 'cooldown');
    await tester.pumpAndSettle();
    expect(find.textContaining('help results'), findsOneWidget);
    expect(
        find.text('Rule, trigger, target, action & cooldown'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('help-search')), 'nonexistent987');
    await tester.pumpAndSettle();
    expect(find.text('No matches. Try another term or choose a topic.'),
        findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('The eight reports'), findsOneWidget);
  });

  testWidgets(
      'topic navigation clears search and context updates reset the guide',
      (tester) async {
    await mount(tester);
    await tester.enterText(
        find.byKey(const ValueKey('help-search')), 'missing');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('help-topic-jobs')));
    await tester.pumpAndSettle();
    expect(find.text('Pick machines before running a tool'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('help-search')))
            .controller!
            .text,
        isEmpty);
    await mount(tester, topic: 'thisMachine');
    expect(find.text('Machine ID, display name & password'), findsOneWidget);
  });

  for (final topic in helpTopics) {
    for (final brightness in Brightness.values) {
      testWidgets(
          '${topic.id} fits narrow enlarged text in ${brightness.name} theme',
          (tester) async {
        await mount(tester,
            topic: topic.id,
            size: const Size(390, 844),
            textScale: 2,
            brightness: brightness);
        await tester.scrollUntilVisible(
            find.text(topic.entries.first.title), 180,
            scrollable: find
                .descendant(
                    of: find.byType(ListView).last,
                    matching: find.byType(Scrollable))
                .first);
        expect(find.text(topic.entries.first.title), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(ListView).last, const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
