import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';
import 'package:flutter_hbb/labdesk/theme/dialog_skin.dart';

void main() {
  testWidgets('dialog fields work in an overlay without an outer Material',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final entry = OverlayEntry(
      builder: (_) => LdDialog(
        title: const LdDialogTitle(title: 'Rename machine'),
        content: LdDialogField(controller: controller, label: 'Name'),
      ),
    );
    addTearDown(() {
      entry.remove();
      entry.dispose();
    });

    await tester.pumpWidget(MaterialApp(
      theme: C.theme(),
      home: Overlay(initialEntries: [entry]),
    ));
    await tester.pumpAndSettle();

    expect(find.ancestor(of: find.byType(LdDialog), matching: find.byType(Material)),
        findsNothing);
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), 'Office machine');
    await tester.pump();
    expect(controller.text, 'Office machine');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });
}
