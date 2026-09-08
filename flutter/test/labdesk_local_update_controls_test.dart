import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/screens/local_update_controls.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';

const _statusKey = 'labdesk-update-status';
const _policyKey = 'labdesk-update-policy';

Map<String, dynamic> _status({bool managed = false, String version = '2.0'}) =>
    {
      'managed': managed,
      'legacyMigrated': false,
      'currentVersion': '1.0',
      'availableVersion': version,
      'state': 'available',
      'error': null,
      'reportedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'capabilities': {'check': true, 'install': true, 'scheduling': true},
    };

Future<void> _mount(
  WidgetTester tester, {
  required Future<String> Function(String) read,
  required Future<void> Function(String, String) write,
  bool banner = false,
  double width = 800,
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
      theme: C.theme(),
      home: Scaffold(
        body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: SingleChildScrollView(
                child: LocalUpdateControls(
              readOption: read,
              writeOption: write,
              banner: banner,
            ))),
      )));
  await tester.pump();
}

void main() {
  testWidgets('unknown core and missing capabilities cannot mutate updates',
      (tester) async {
    final status = <String, dynamic>{};
    final writes = <String>[];
    await _mount(tester,
        read: (_) async => jsonEncode(status),
        write: (key, _) async {
          writes.add(key);
        });
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Check now'))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Download and install'))
            .onPressed,
        isNull);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    status.addAll(
        {'managed': false, 'currentVersion': '1.0', 'availableVersion': '2.0'});
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Download and install'))
            .onPressed,
        isNull);
    expect(writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'managed devices direct users to Fleet Updates and disable all local writes',
      (tester) async {
    final status = _status(managed: true);
    final policy = {'revision': 4, 'automatic': false, 'weekly': null};
    final writes = <String>[];
    await _mount(tester,
        read: (key) async => jsonEncode(key == _statusKey ? status : policy),
        write: (key, _) async {
          writes.add(key);
        });
    expect(find.textContaining('Fleet Updates'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Check now'))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Download and install'))
            .onPressed,
        isNull);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final action in ['check', 'install']) {
    testWidgets(
        '$action uses privileged action and fresh queue readback without enabling recurrence',
        (tester) async {
      final status = _status();
      final policy = {'revision': 2, 'automatic': false, 'weekly': null};
      final calls = <String>[];
      await _mount(tester, read: (key) async {
        calls.add('read:$key');
        return jsonEncode(key == _statusKey ? status : policy);
      }, write: (key, value) async {
        calls.add('write:$key:$value');
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        status['queuedLocalCommand'] = {
          'id': 'job-$action',
          'action': value,
          'startsAt': now,
          'endsAt': now + 3600
        };
      });
      calls.clear();
      await tester.tap(
          find.text(action == 'check' ? 'Check now' : 'Download and install'));
      await tester.pump();
      expect(calls, [
        'write:labdesk-update-action:$action',
        'read:$_statusKey',
        'read:$_policyKey'
      ]);
      expect(find.textContaining('job queued:'), findsOneWidget);
      expect(policy['automatic'], false);
      expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Check now'))
              .onPressed,
          isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'weekly policy validates days, saves explicitly and reads canonical result',
      (tester) async {
    final status = _status();
    Map<String, dynamic> policy = {
      'revision': 7,
      'automatic': false,
      'weekly': null
    };
    Map<String, dynamic>? written;
    await _mount(tester,
        read: (key) async => jsonEncode(key == _statusKey ? status : policy),
        write: (key, value) async {
          expect(key, _policyKey);
          written = jsonDecode(value) as Map<String, dynamic>;
          // Canonical serialization may reorder properties.
          policy = {
            'revision': 8,
            'automatic': true,
            'weekly': {
              'windowMinutes': 60,
              'startMinute': 180,
              'days': [1]
            }
          };
        });
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(written, isNull);
    expect(find.text('Choose at least one day.'), findsOneWidget);
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Save update settings'))
            .onPressed,
        isNull);
    await tester.tap(find.text('Mon'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '14');
    await tester.pump();
    expect(
        find.text('Enter a window from 15 to 1440 minutes.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '60');
    await tester.pump();
    await tester.tap(find.text('Save update settings'));
    await tester.pump();
    expect(written, {
      'revision': 7,
      'automatic': true,
      'weekly': {
        'days': [1],
        'startMinute': 180,
        'windowMinutes': 60
      }
    });
    expect(find.text('Update settings saved.'), findsOneWidget);
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Save update settings'))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'action without a fresh queue is not reported as queued, and rejection is shown',
      (tester) async {
    final status = _status();
    var reject = false;
    await _mount(tester,
        read: (key) async => jsonEncode(key == _statusKey
            ? status
            : {'revision': 0, 'automatic': false, 'weekly': null}),
        write: (_, __) async {
          if (reject)
            status['error'] = 'Local updates are managed by your organization.';
        });
    await tester.tap(find.text('Download and install'));
    await tester.pump();
    expect(find.textContaining('did not confirm a new update job'),
        findsOneWidget);
    expect(find.textContaining('job queued:'), findsNothing);
    reject = true;
    await tester.tap(find.text('Download and install'));
    await tester.pump();
    expect(find.text('Local updates are managed by your organization.'),
        findsOneWidget);
    expect(find.textContaining('job queued:'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rejected policy preserves the draft and displays service error',
      (tester) async {
    final status = _status();
    final policy = {
      'revision': 1,
      'automatic': true,
      'weekly': {
        'days': [0, 1, 2, 3, 4, 5, 6],
        'startMinute': 0,
        'windowMinutes': 1440
      }
    };
    status['legacyMigrated'] = true;
    await _mount(tester,
        read: (key) async => jsonEncode(key == _statusKey ? status : policy),
        write: (_, __) async {
          status['error'] = 'Policy changed; reload and retry.';
        });
    expect(find.textContaining('all-day, every-day'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.text('Save update settings'));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, false);
    expect(find.text('Policy changed; reload and retry.'), findsOneWidget);
    expect(find.text('Update settings saved.'), findsNothing);
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Save update settings'))
            .onPressed,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'scheduling without install capability can only disable automatic updates',
      (tester) async {
    final status = _status();
    (status['capabilities'] as Map)['install'] = false;
    Map<String, dynamic> policy = {
      'revision': 1,
      'automatic': false,
      'weekly': null
    };
    final writes = <Map<String, dynamic>>[];
    await _mount(tester,
        read: (key) async => jsonEncode(key == _statusKey ? status : policy),
        write: (key, value) async {
          expect(key, _policyKey);
          policy = jsonDecode(value) as Map<String, dynamic>;
          writes.add(policy);
        });
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    policy = {
      'revision': 2,
      'automatic': true,
      'weekly': {
        'days': [1],
        'startMinute': 180,
        'windowMinutes': 60
      }
    };
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.text('Save update settings'));
    await tester.pump();
    expect(writes, [
      {'revision': 2, 'automatic': false, 'weekly': null}
    ]);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'banner dismissal applies only to that version and survives remount',
      (tester) async {
    final status = _status(version: 'dismiss-test-2');
    Future<String> read(String _) async => jsonEncode(status);
    Future<void> write(String _, String __) async {}
    await _mount(tester, read: read, write: write, banner: true);
    await tester.tap(find.text('Later'));
    await tester.pump();
    expect(find.textContaining('is available.'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _mount(tester, read: read, write: write, banner: true);
    expect(find.textContaining('is available.'), findsNothing);
    status['availableVersion'] = 'dismiss-test-3';
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(find.text('LabDesk dismiss-test-3 is available.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'polls do not overlap and a disposed pending read cannot restart polling',
      (tester) async {
    final pending = Completer<String>();
    var reads = 0;
    await _mount(tester, banner: true, read: (_) {
      reads++;
      return pending.future;
    }, write: (_, __) async {});
    await tester.pump(const Duration(seconds: 45));
    expect(reads, 1);
    await tester.pumpWidget(const SizedBox());
    pending.complete(jsonEncode(_status()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(reads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed reads lock stale controls and recover on next poll',
      (tester) async {
    var fail = false;
    await _mount(tester, read: (key) async {
      if (fail) throw StateError('IPC disconnected');
      return jsonEncode(key == _statusKey
          ? _status()
          : {'revision': 0, 'automatic': false, 'weekly': null});
    }, write: (_, __) async {});
    fail = true;
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(find.textContaining('Cannot read updater status'), findsOneWidget);
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Download and install'))
            .onPressed,
        isNull);
    fail = false;
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(find.textContaining('Cannot read updater status'), findsNothing);
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Download and install'))
            .onPressed,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'schedule and long version remain usable at narrow width and large text',
      (tester) async {
    await _mount(tester,
        width: 320,
        textScale: 2,
        read: (key) async => jsonEncode(key == _statusKey
            ? _status(version: '1.4.0-alpha.very-long-version-label')
            : {
                'revision': 1,
                'automatic': true,
                'weekly': {
                  'days': [6],
                  'startMinute': 1380,
                  'windowMinutes': 120
                }
              }),
        write: (_, __) async {});
    expect(find.text('23:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
