import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/screens/reporting_control.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';

Future<void> mount(WidgetTester tester,
    {int? seconds = 300,
    Future<void> Function(int)? save,
    String contextKey = 'org/machine',
    String? disabledReason,
    double textScale = 1}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: MediaQuery(
          data: MediaQueryData(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true),
          child: Scaffold(
              body: SingleChildScrollView(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: ReportingControl(
                          currentSeconds: seconds,
                          onSave: save,
                          contextKey: contextKey,
                          disabledReason: disabledReason)))))));
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<int>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  test(
      'broker applies an explicit validated interval under the current human scope',
      () async {
    final calls = <String>[];
    final broker = OverlayBroker(
        baseUrl: 'https://example.test',
        token: () => 'token',
        organizationId: () => 'org-a',
        http: (method, uri, headers, body) async {
          calls.add(uri.toString());
          expect(method, 'PATCH');
          expect(headers['authorization'], 'Bearer token');
          expect(headers['x-labdesk-organization'], 'org-a');
          expect(jsonDecode(body!), {'flushSeconds': 60});
          return (
            200,
            jsonEncode({'machineId': 'machine/one', 'flushSeconds': 60})
          );
        });
    await broker.setReportingInterval('machine/one', 60);
    expect(calls.single,
        'https://example.test/console/org/machines/machine%2Fone/reporting');
    for (final seconds in [-1, 0, 59, 86401]) {
      await expectLater(broker.setReportingInterval('machine/one', seconds),
          throwsA(isA<OverlayBrokerException>()));
    }
    expect(calls.length, 1);
  });
  test('broker does not claim success for a refused or mismatched confirmation',
      () async {
    for (final response in [
      (403, '{"error":"A viewer may not do that."}'),
      (200, '{"machineId":"other","flushSeconds":60}'),
      (200, '{"machineId":"one","flushSeconds":300}')
    ]) {
      final broker = OverlayBroker(
          baseUrl: 'https://example.test',
          token: () => 'token',
          http: (_, __, ___, ____) async => response);
      await expectLater(broker.setReportingInterval('one', 60),
          throwsA(isA<OverlayBrokerException>()));
    }
  });
  testWidgets('existing 300 is preserved until an explicit changed Apply',
      (tester) async {
    final saved = <int>[];
    await mount(tester, save: (seconds) async => saved.add(seconds));
    expect(find.text('5 minutes'), findsOneWidget);
    expect(saved, isEmpty);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply'))
            .onPressed,
        isNull);
    await choose(tester, '1 minute');
    expect(saved, isEmpty);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(saved, [60]);
    expect(find.textContaining('next successful upload'), findsWidgets);
    expect(find.textContaining('Configured: 1 minute.'), findsOneWidget);
  });
  testWidgets(
      'custom and unknown configured intervals are not silently replaced',
      (tester) async {
    await mount(tester, seconds: 210, save: (_) async {});
    expect(find.text('210 seconds (current)'), findsOneWidget);
    await mount(tester, seconds: null, save: (_) async {});
    expect(find.textContaining('Configured: Not reported'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply'))
            .onPressed,
        isNull);
  });
  testWidgets('read-only control explains why it cannot apply changes',
      (tester) async {
    await mount(tester, disabledReason: 'Viewer access is read-only.');
    expect(find.text('Viewer access is read-only.'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButtonFormField<int>>(
                find.byType(DropdownButtonFormField<int>))
            .onChanged,
        isNull);
  });
  testWidgets('failed save keeps selection and permits retry', (tester) async {
    var calls = 0;
    await mount(tester, save: (_) async {
      if (++calls == 1) throw StateError('offline');
    });
    await choose(tester, '1 minute');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Your selection is still here'), findsOneWidget);
    expect(find.text('1 minute'), findsOneWidget);
    expect(find.textContaining('Configured: 5 minutes.'), findsOneWidget);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.textContaining('Reporting interval saved.'), findsOneWidget);
  });
  testWidgets(
      'save locks selection and old target completion cannot update a new target',
      (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    await mount(tester, save: (_) {
      calls++;
      return pending.future;
    });
    await choose(tester, '1 minute');
    await tester.tap(find.text('Apply'));
    await tester.pump();
    expect(find.text('Applying…'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButtonFormField<int>>(
                find.byType(DropdownButtonFormField<int>))
            .onChanged,
        isNull);
    await mount(tester, contextKey: 'org/other-machine', save: (_) async {});
    pending.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.textContaining('Configured: 5 minutes.'), findsOneWidget);
    expect(find.textContaining('Reporting interval saved.'), findsNothing);
  });
  testWidgets('updated server policy wins over an old pending completion',
      (tester) async {
    final pending = Completer<void>();
    await mount(tester, save: (_) => pending.future);
    await choose(tester, '1 minute');
    await tester.tap(find.text('Apply'));
    await tester.pump();
    await mount(tester, seconds: 900, save: (_) async {});
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Configured: 15 minutes.'), findsOneWidget);
    expect(find.textContaining('Reporting interval saved.'), findsNothing);
  });
  testWidgets(
      'control fits narrow enlarged text and disposal ignores a pending failure',
      (tester) async {
    final pending = Completer<void>();
    await mount(tester, textScale: 2, save: (_) => pending.future);
    expect(tester.takeException(), isNull);
    await choose(tester, '1 minute');
    await tester.tap(find.text('Apply'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.completeError(StateError('later failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
