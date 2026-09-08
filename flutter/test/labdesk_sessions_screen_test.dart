import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/chat_transcript.dart';
import 'package:flutter_hbb/labdesk/screens/sessions_screen.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: C.theme(),
      home: Scaffold(body: child),
    );

void main() {
  final at = DateTime(2026, 9, 1, 14, 5);

  final outgoing = SessionChat(
    id: '1180573903',
    peerLabel: 'workshop-pc',
    direction: SessionDirection.outgoing,
    lines: [
      ChatLine(from: ChatFrom.mine, text: 'rebooting now', at: at),
      ChatLine(from: ChatFrom.peer, text: 'understood', at: at),
    ],
  );
  final incoming = SessionChat(
    id: '4',
    peerLabel: 'front-desk',
    direction: SessionDirection.incoming,
    unread: 3,
    lines: [ChatLine(from: ChatFrom.peer, text: 'can you look at this', at: at)],
  );

  testWidgets('with no session it says so, and how to start one',
      (tester) async {
    await tester.pumpWidget(_wrap(const SessionsScreen(sessions: [])));

    expect(find.text('No session is active'), findsOneWidget);
    expect(
      find.textContaining('Connect to a machine from Connect'),
      findsOneWidget,
      reason: 'an empty screen that does not say what to do next is a dead end',
    );
  });

  testWidgets('every session is listed with its direction and unread count',
      (tester) async {
    await tester.pumpWidget(
        _wrap(SessionsScreen(sessions: [outgoing, incoming])));

    expect(find.text('workshop-pc'), findsWidgets);
    expect(find.text('front-desk'), findsOneWidget);
    expect(find.text('Outgoing'), findsOneWidget);
    expect(find.text('Incoming'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2 active'), findsOneWidget);
  });

  testWidgets('the first session is open, transcript and all', (tester) async {
    await tester.pumpWidget(
        _wrap(SessionsScreen(sessions: [outgoing, incoming])));

    expect(find.text('rebooting now'), findsOneWidget);
    expect(find.text('understood'), findsOneWidget);
    expect(find.text('can you look at this'), findsNothing);
  });

  testWidgets('tapping a session shows that session\'s lines', (tester) async {
    await tester.pumpWidget(
        _wrap(SessionsScreen(sessions: [outgoing, incoming])));

    await tester.tap(find.text('front-desk'));
    await tester.pumpAndSettle();

    expect(find.text('can you look at this'), findsOneWidget);
    expect(find.text('rebooting now'), findsNothing);
    expect(find.text('This machine was connected to'), findsOneWidget);
  });

  testWidgets('submitting hands the text back with the session it belongs to',
      (tester) async {
    final sent = <(String, String)>[];
    await tester.pumpWidget(_wrap(SessionsScreen(
      sessions: [outgoing, incoming],
      onSend: (id, text) => sent.add((id, text)),
    )));

    await tester.tap(find.text('front-desk'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'on it');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(sent, [('incoming/4', 'on it')]);
    // The field is cleared by the screen, not by the client coming back with a
    // new transcript, which can be a poll away.
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
  });

  testWidgets('an empty message is never sent', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(_wrap(SessionsScreen(
      sessions: [outgoing],
      onSend: (_, text) => sent.add(text),
    )));

    await tester.enterText(find.byType(TextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(sent, isEmpty);
  });

  testWidgets('incoming and outgoing ids cannot select or send to each other',
      (tester) async {
    final sent = <(String, String)>[];
    final sameId = SessionChat(
      id: outgoing.id,
      peerLabel: 'incoming caller',
      direction: SessionDirection.incoming,
      lines: [ChatLine(from: ChatFrom.peer, text: 'incoming only', at: at)],
    );
    await tester.pumpWidget(_wrap(SessionsScreen(
      sessions: [outgoing, sameId],
      onSend: (id, text) => sent.add((id, text)),
    )));

    await tester.tap(find.text('incoming caller'));
    await tester.pumpAndSettle();

    expect(find.text('incoming only'), findsOneWidget);
    expect(find.text('rebooting now'), findsNothing);
    await tester.enterText(find.byType(TextField), 'reply to incoming');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(sent, [('incoming/${outgoing.id}', 'reply to incoming')]);
  });

  testWidgets('with no handler the input is disabled, not missing',
      (tester) async {
    await tester.pumpWidget(_wrap(SessionsScreen(sessions: [outgoing])));

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(find.text('Send'), findsOneWidget);
  });

  testWidgets('a draft never follows selection or a closed session to a peer',
      (tester) async {
    final sent = <(String, String)>[];
    Widget screen(List<SessionChat> sessions) => _wrap(SessionsScreen(
          sessions: sessions,
          onSend: (id, text) => sent.add((id, text)),
        ));
    await tester.pumpWidget(screen([outgoing, incoming]));
    await tester.enterText(find.byType(TextField), 'for workshop only');

    await tester.tap(find.text('front-desk'));
    await tester.pumpAndSettle();

    expect(find.text('can you look at this'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    await tester.enterText(find.byType(TextField), 'for front desk only');

    await tester.pumpWidget(screen([outgoing]));
    await tester.pumpAndSettle();

    expect(find.text('rebooting now'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(sent, isEmpty);
  });
}
