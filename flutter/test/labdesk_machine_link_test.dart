import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/pages/labdesk_machine_link.dart';

void main() {
  test('a refused labnet admission prevents a headless RMM connection',
      () async {
    final link = await LabDeskMachineLink.open('test-peer',
        beforeOpen: () async => 'The labnet tunnel is unavailable.');
    expect(link, isNull);
    expect(LabDeskMachineLink.isOpen('test-peer'), isFalse);
    expect(LabDeskMachineLink.reason('test-peer'), contains('labnet tunnel'));
  });

  test('concurrent RMM callers share one admission attempt', () async {
    final readiness = Completer<String?>();
    var preparations = 0;
    Future<String?> prepare() {
      preparations++;
      return readiness.future;
    }

    final first = LabDeskMachineLink.open('shared-peer', beforeOpen: prepare);
    final second = LabDeskMachineLink.open('shared-peer', beforeOpen: prepare);
    expect(preparations, 1);
    readiness.complete('The target did not acknowledge its ticket.');
    expect(await first, isNull);
    expect(await second, isNull);
  });

  test('failed admission can be retried without a stuck opening lock',
      () async {
    await LabDeskMachineLink.open('retry-peer',
        beforeOpen: () async => throw StateError('offline'));
    expect(
        await LabDeskMachineLink.open('retry-peer',
            beforeOpen: () async => 'retry reached admission'),
        isNull);
    expect(LabDeskMachineLink.reason('retry-peer'),
        contains('retry reached admission'));
  });
}
