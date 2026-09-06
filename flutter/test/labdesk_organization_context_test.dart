import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/dashboard_layout.dart';
import 'package:flutter_hbb/labdesk/services/organization_context.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';

class _Request {
  _Request(this.url, this.headers);
  final Uri url;
  final Map<String, String> headers;
  final result = Completer<(int, String)>();
  void reply(Object body, {int status = 200}) =>
      result.complete((status, jsonEncode(body)));
}

class _Write {
  _Write(this.key, this.value);
  final String key;
  final String value;
  final result = Completer<void>();
}

class _Harness {
  _Harness() {
    broker = OverlayBroker(
        baseUrl: 'https://example.test',
        token: () => token,
        organizationId: () => controller.activeId,
        http: (method, url, headers, body) {
          final request = _Request(url, headers);
          requests.add(request);
          return request.result.future;
        });
    controller = OrganizationContextController(
        broker: broker,
        readOption: (key) => options[key] ?? '',
        writeOption: (key, value) async {
          final write = _Write(key, value);
          writes.add(write);
          if (holdWrites) await write.result.future;
          options[key] = value;
        });
  }
  late final OverlayBroker broker;
  late final OrganizationContextController controller;
  String token = '';
  bool holdWrites = false;
  final options = <String, String>{};
  final requests = <_Request>[];
  final writes = <_Write>[];
  Future<void> sync(String next) {
    token = next;
    return controller.syncCredential(next);
  }

  _Request take(String path) =>
      requests.firstWhere((r) => r.url.path == path && !r.result.isCompleted);
  void directory(
          {String user = 'user-one',
          List<String> organizations = const ['a', 'b']}) =>
      take('/console/organizations').reply({
        'userId': user,
        'organizations': [
          for (final id in organizations)
            {'orgId': id, 'name': 'Org $id', 'role': 'owner'}
        ]
      });
  void verify(String id, {int status = 200}) => requests
      .firstWhere((r) =>
          r.url.path == '/console/org' &&
          r.headers['x-labdesk-organization'] == id &&
          !r.result.isCompleted)
      .reply(status == 200 ? {'orgId': id} : {'error': 'Verification refused'},
          status: status);
  Future<void> ready({String user = 'user-one'}) async {
    final loading = sync('token-$user');
    directory(user: user);
    await loading;
    final selecting = controller.select('a');
    verify('a');
    await selecting;
  }
}

Future<void> tick() => Future<void>.delayed(Duration.zero);
String pref(String user) =>
    'labdesk-ui-org-v1-${base64Url.encode(utf8.encode(user))}';

void main() {
  test('rejected authority clears context and permits membership refresh',
      () async {
    final h = _Harness();
    await h.ready();
    final oldRevision = h.controller.revision;
    h.controller.invalidate('Membership revoked');
    expect(h.controller.ready, isFalse);
    expect(h.controller.organizations, isEmpty);
    expect(h.controller.revision, greaterThan(oldRevision));
    final retry = h.sync(h.token);
    h.directory(organizations: const []);
    await retry;
    expect(h.controller.ready, isFalse);
    expect(h.controller.error, contains('No organization'));
    h.controller.dispose();
  });

  test('initial verification failure can retry the same credential', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    final first = h.sync('token');
    h.directory(organizations: ['a']);
    await tick();
    h.verify('a', status: 503);
    await first;
    expect(h.controller.ready, isFalse);
    final retry = h.sync('token');
    expect(
        h.requests.where((r) => r.url.path == '/console/organizations').length,
        2);
    h.directory(organizations: ['a']);
    await tick();
    h.verify('a');
    await retry;
    expect(h.controller.ready, isTrue);
  });
  test('selecting active A cancels pending B verification', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.ready();
    final pendingB = h.controller.select('b');
    await h.controller.select('a');
    h.verify('b');
    await pendingB;
    expect(h.controller.activeId, 'a');
    expect(h.controller.busy, isFalse);
    expect(h.options[pref('user-one')], 'a');
  });
  test('manual selection supersedes initial automatic verification', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    h.options[pref('user-one')] = 'a';
    final loading = h.sync('token');
    h.directory();
    await tick();
    final selectingB = h.controller.select('b');
    h.verify('a');
    await loading;
    expect(h.controller.activeId, isNull);
    expect(h.controller.busy, isTrue);
    h.verify('b');
    await selectingB;
    expect(h.controller.activeId, 'b');
  });
  test('layout save completion cannot reapply after A to B to A', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.ready();
    h.holdWrites = true;
    final saving = h.controller.saveLayout(dashboardPreset('operations'));
    await tick();
    final layoutWrite = h.writes.last;
    final toB = h.controller.select('b');
    h.verify('b');
    await tick();
    final toA = h.controller.select('a');
    h.verify('a');
    await tick();
    layoutWrite.result.complete();
    await saving;
    expect(h.controller.layout?.preset, isNot('operations'));
    for (var i = 0; i < 5; i++) {
      for (final write in h.writes.where((w) => !w.result.isCompleted)) {
        write.result.complete();
      }
      await tick();
    }
    await Future.wait([toB, toA]);
  });
  test('organization preference writes preserve latest selection order',
      () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.ready();
    h.holdWrites = true;
    final toB = h.controller.select('b');
    h.verify('b');
    await tick();
    final firstWrite = h.writes.last;
    final toA = h.controller.select('a');
    h.verify('a');
    await tick();
    final secondWrite = h.writes.last;
    if (secondWrite != firstWrite) {
      secondWrite.result.complete();
      await tick();
    }
    firstWrite.result.complete();
    await tick();
    for (final write in h.writes.where((w) => !w.result.isCompleted)) {
      write.result.complete();
    }
    await Future.wait([toB, toA]);
    expect(h.options[pref('user-one')], 'a');
  });
  test('stale directory success cannot cross account boundary or signout',
      () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    final old = h.sync('old-token');
    final oldRequest = h.take('/console/organizations');
    final current = h.sync('new-token');
    h.requests.last.reply({
      'userId': 'new-user',
      'organizations': [
        {'orgId': 'b', 'name': 'Org b', 'role': 'owner'}
      ]
    });
    await tick();
    h.verify('b');
    await current;
    oldRequest.reply({
      'userId': 'old-user',
      'organizations': [
        {'orgId': 'a', 'name': 'Org a', 'role': 'owner'}
      ]
    });
    await old;
    expect(h.controller.userId, 'new-user');
    expect(h.controller.activeId, 'b');
    final selection = h.controller.select('b');
    await selection;
    await h.sync('');
    expect(h.controller.ready, isFalse);
    expect(h.controller.layout, isNull);
    expect(h.controller.organizations, isEmpty);
    expect(h.controller.error, isNull);
  });

  test('stale selection failure cannot overwrite newer account state',
      () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.ready();
    final old = h.controller.select('b');
    final next = h.sync('new-token');
    h.directory(user: 'new-user', organizations: ['a']);
    await tick();
    h.verify('a');
    await next;
    h.verify('b', status: 403);
    await old;
    expect(h.controller.userId, 'new-user');
    expect(h.controller.error, isNull);
    expect(h.controller.busy, isFalse);
    expect(h.controller.activeId, 'a');
  });

  test('signout invalidates pending verification and saved layout completion',
      () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.ready();
    h.holdWrites = true;
    final save = h.controller.saveLayout(dashboardPreset('operations'));
    await tick();
    final selection = h.controller.select('b');
    await h.sync('');
    h.verify('b');
    await selection;
    h.writes.last.result.complete();
    await save;
    expect(h.controller.ready, isFalse);
    expect(h.controller.layout, isNull);
    expect(h.controller.userId, isEmpty);
    expect(h.controller.busy, isFalse);
    expect(
        h.options.keys
            .where((key) => key.startsWith('labdesk-dashboard-'))
            .length,
        1);
  });

  test('directory HTTP failure retries without changing credentials', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    final failed = h.sync('token');
    h
        .take('/console/organizations')
        .reply({'error': 'Unavailable'}, status: 503);
    await failed;
    expect(h.controller.error, 'Unavailable');
    final retry = h.sync('token');
    h.directory(organizations: ['a']);
    await tick();
    h.verify('a');
    await retry;
    expect(h.controller.ready, isTrue);
    expect(h.controller.error, isNull);
  });

  test('selection verification failure can retry and retains old context',
      () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.ready();
    final oldRevision = h.controller.revision;
    final failed = h.controller.select('b');
    h.verify('b', status: 403);
    await failed;
    expect(h.controller.activeId, 'a');
    expect(h.controller.revision, oldRevision);
    final retry = h.controller.select('b');
    h.verify('b');
    await retry;
    expect(h.controller.activeId, 'b');
    expect(h.controller.error, isNull);
  });

  test('layout preference keys isolate accounts and organizations', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.ready();
    final firstKey = h.controller.contextKey;
    await h.controller.saveLayout(dashboardPreset('operations'));
    final toB = h.controller.select('b');
    h.verify('b');
    await toB;
    expect(h.controller.layout, isNull);
    await h.controller.saveLayout(dashboardPreset('technician'));
    final toA = h.controller.select('a');
    h.verify('a');
    await toA;
    expect(h.controller.layout!.preset, 'operations');
    await h.sync('');
    final other = h.sync('other-token');
    h.directory(user: 'other-user', organizations: ['a']);
    await tick();
    h.verify('a');
    await other;
    expect(h.controller.contextKey, isNot(firstKey));
    expect(h.controller.layout, isNull);
    await h.controller.saveLayout(dashboardPreset('everyday'));
    expect(
        h.options.keys
            .where((key) => key.startsWith('labdesk-dashboard-'))
            .length,
        3);
  });

  test('failed preference write is retryable and does not block later writes',
      () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.ready();
    h.holdWrites = true;
    final select = h.controller.select('b');
    h.verify('b');
    await tick();
    h.writes.last.result.completeError(StateError('storage failed'));
    await select;
    expect(h.controller.activeId, 'b');
    expect(h.controller.error, contains('could not be saved'));
    final retry = h.controller.select('b');
    await tick();
    h.writes.last.result.complete();
    await retry;
    expect(h.options[pref('user-one')], 'b');
    expect(h.controller.error, isNull);
    final before = h.controller.layout;
    final save = h.controller.saveLayout(dashboardPreset('operations'));
    final assertion = expectLater(save, throwsStateError);
    await tick();
    h.writes.last.result.completeError(StateError('disk full'));
    await assertion;
    expect(h.controller.layout, same(before));
    final retrySave = h.controller.saveLayout(dashboardPreset('operations'));
    await tick();
    h.writes.last.result.complete();
    await retrySave;
    expect(h.controller.layout!.preset, 'operations');
  });

  test(
      'malformed layout uses default and active selection retries layout loading',
      () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.ready();
    final key = 'labdesk-dashboard-v1-${h.controller.contextKey}';
    h.options[key] = '{broken';
    await h.controller.select('a');
    expect(h.controller.ready, isTrue);
    expect(h.controller.layout, isNull);
    expect(h.controller.error, contains('default layout'));
    h.options[key] = jsonEncode(dashboardPreset('technician').toJson());
    await h.controller.select('a');
    expect(h.controller.layout!.preset, 'technician');
    expect(h.controller.error, isNull);
  });

  test('captured directory verification retains its original bearer', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    final loading = h.sync('original-token');
    h.token = 'later-token';
    h.directory(organizations: ['a']);
    await tick();
    expect(h.take('/console/org').headers['authorization'],
        'Bearer original-token');
    h.verify('a');
    await loading;
  });

  test(
      'duplicate and header-invalid memberships cannot reach organization picker',
      () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    final loading = h.sync('token');
    h.take('/console/organizations').reply({
      'userId': 'user-one',
      'organizations': [
        {'orgId': 'a', 'name': 'Org a', 'role': 'owner'},
        {'orgId': 'a', 'name': 'Org a again', 'role': 'owner'},
        {'orgId': 'bad\r\nid', 'name': 'Bad', 'role': 'owner'}
      ]
    });
    await tick();
    h.verify('a');
    await loading;
    expect(h.controller.organizations.length, 1);
    expect(h.controller.activeId, 'a');
  });

  test('dispose ignores pending notifications and rejects layout saves',
      () async {
    final h = _Harness();
    final loading = h.sync('token');
    h.controller.dispose();
    h.directory(organizations: ['a']);
    await loading;
    expect(h.controller.ready, isFalse);
    await expectLater(
        h.controller.saveLayout(dashboardPreset('everyday')), throwsStateError);
  });
}
