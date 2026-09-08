import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/chat_transcript.dart';
import 'package:flutter_hbb/labdesk/screens/sessions_screen.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

void main() {
  testWidgets('external selection changes discard the previous session draft',
      (tester) async {
    final at = DateTime.utc(2026, 9, 7);
    final sent = <(String, String)>[];
    final sessions = [
      SessionChat(
        id: '42',
        peerLabel: 'Outgoing fixture',
        direction: SessionDirection.outgoing,
        lines: [ChatLine(from: ChatFrom.peer, text: 'Outgoing transcript', at: at)],
      ),
      SessionChat(
        id: '42',
        peerLabel: 'Incoming fixture',
        direction: SessionDirection.incoming,
        lines: [ChatLine(from: ChatFrom.peer, text: 'Incoming transcript', at: at)],
      ),
    ];
    Widget screen(String selectedId) => MaterialApp(
          theme: C.theme(),
          home: Scaffold(
            body: SessionsScreen(
              sessions: sessions,
              selectedId: selectedId,
              onSend: (id, text) => sent.add((id, text)),
            ),
          ),
        );

    await tester.pumpWidget(screen('outgoing/42'));
    await tester.enterText(find.byType(TextField), 'Only for outgoing');
    await tester.pumpWidget(screen('outgoing/42'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Only for outgoing');

    // The parent changes the public prop; there is no local row tap.
    await tester.pumpWidget(screen('incoming/42'));
    await tester.pumpAndSettle();
    expect(find.text('Incoming transcript'), findsOneWidget);
    expect(find.text('Outgoing transcript'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(sent, isEmpty);
  });
}
