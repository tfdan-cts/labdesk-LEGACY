import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/pages/labdesk_machine_link.dart';
import 'package:flutter_hbb/labdesk/services/desktop_session_access.dart';
import 'package:flutter_hbb/models/model.dart';

class _LinkModel implements FfiModel {
  _LinkModel({bool ready = true}) { pi.isSet.value = ready; }
  @override
  final pi = PeerInfo();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Link implements FFI {
  _Link({bool ready = true}) : ffiModel = _LinkModel(ready: ready);
  @override
  bool closed = false;
  @override
  final _LinkModel ffiModel;
  @override
  void Function(String, String, String)? headlessMsgBox;
  @override
  Future<void> close({bool closeSession = true}) async => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  DesktopSessionContext? context;
  setUp(() {
    context = ('account-a', 1);
    desktopSessionAccess.readContext = () => context;
  });
  tearDown(() {
    LabDeskMachineLink.closeAll();
    desktopSessionAccess.readContext = null;
  });

  test('signed-out commands never reach connection admission', () async {
    context = null;
    var admitted = false;
    expect(
        await LabDeskMachineLink.open('signed-out', beforeOpen: () async {
          admitted = true;
          return null;
        }),
        isNull);
    expect(admitted, isFalse);
  });

  test('a cached link cannot bypass a new command admission', () async {
    final link = _Link();
    expect(
        await LabDeskMachineLink.open('cached', createLink: () => link), link);
    expect(
        await LabDeskMachineLink.open('cached',
            beforeOpen: () async => 'Membership was revoked.'),
        isNull);
    expect(link.closed, isTrue);
  });

  test('account A to B to A closes cached command authority', () async {
    final link = _Link();
    await LabDeskMachineLink.open('cached', createLink: () => link);
    context = ('account-b', 2);
    expect(LabDeskMachineLink.isOpen('cached'), isFalse);
    expect(
        await LabDeskMachineLink.open('cached',
            beforeOpen: () async => 'Viewer cannot run commands.'),
        isNull);
    expect(link.closed, isTrue);
    context = ('account-a', 3);
    expect(LabDeskMachineLink.isOpen('cached'), isFalse);
    final replacement = _Link();
    expect(
        await LabDeskMachineLink.open('cached', createLink: () => replacement),
        replacement);
  });

  test(
      'old admission cannot replace a newer account link after its final await',
      () async {
    final admission = Completer<String?>();
    var staleCreated = false;
    final old = LabDeskMachineLink.open('pending',
        beforeOpen: () => admission.future,
        createLink: () {
          staleCreated = true;
          return _Link();
        });
    context = ('account-b', 2);
    final replacement = _Link();
    await LabDeskMachineLink.open('pending', createLink: () => replacement);
    admission.complete(null);
    expect(await old, isNull);
    expect(staleCreated, isFalse);
    expect(replacement.closed, isFalse);
    expect(LabDeskMachineLink.isOpen('pending'), isTrue);
  });

  test('closeAll cancels admission before native connection starts', () async {
    final admission = Completer<String?>();
    var created = false;
    final opening = LabDeskMachineLink.open('pending',
        beforeOpen: () => admission.future,
        createLink: () {
          created = true;
          return _Link();
        });
    LabDeskMachineLink.closeAll();
    admission.complete(null);
    expect(await opening, isNull);
    expect(created, isFalse);
  });

  test('old native readiness cannot return or close a new account connection',
      () async {
    final oldLink = _Link(ready: false);
    final old = LabDeskMachineLink.open('waiting', createLink: () => oldLink);
    await Future<void>.delayed(Duration.zero);
    context = ('account-b', 2);
    final replacement = _Link();
    await LabDeskMachineLink.open('waiting', createLink: () => replacement);
    oldLink.ffiModel.pi.isSet.value = true;
    expect(await old, isNull);
    expect(oldLink.closed, isTrue);
    expect(replacement.closed, isFalse);
    expect(LabDeskMachineLink.isOpen('waiting'), isTrue);
  });

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
        beforeOpen: () => throw StateError('offline'));
    expect(
        await LabDeskMachineLink.open('retry-peer',
            beforeOpen: () async => 'retry reached admission'),
        isNull);
    expect(LabDeskMachineLink.reason('retry-peer'),
        contains('retry reached admission'));
  });
}
