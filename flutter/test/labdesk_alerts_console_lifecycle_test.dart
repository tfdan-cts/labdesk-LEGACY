import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/labdesk_status_polling.dart';
import 'package:flutter_hbb/labdesk/console_page.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

import 'labdesk_full_console_mount_test.dart'
    show NativeBoundary, BrokerBoundary;

class CountingAlertNativeBoundary extends NativeBoundary {
  int invocationCount = 0;

  @override
  dynamic noSuchMethod(Invocation call) {
    invocationCount++;
    return super.noSuchMethod(call);
  }
}

class DeferredAlertBoundary extends BrokerBoundary {
  final heldAcknowledgement = Completer<(int, Object)>();
  final acknowledgedOrganizations = <String>{};
  final acknowledgementScopes = <String>[];
  int generation = 0;

  String summary(String organization) =>
      'Fixture alert $organization generation $generation';

  @override
  Future<(int, Object)> reply(
      String method, Uri url, Map<String, String> headers) async {
    if (url.path == '/console/organizations') {
      calls.add('$method ${url.path}');
      expectSync(headers['authorization'], 'Bearer account-A');
      return (200, {
        'userId': 'user-A',
        'organizations': [
          {'orgId': 'org-1', 'name': 'Org A', 'role': 'owner'},
          {'orgId': 'org-2', 'name': 'Org B', 'role': 'owner'},
        ],
      });
    }
    if (url.path == '/console/org' ||
        url.path == '/console/org/events' ||
        url.path == '/console/org/events/fixture-alert/ack') {
      calls.add('$method ${url.path}');
      expectSync(headers['authorization'], 'Bearer account-A');
      final organization = headers['x-labdesk-organization'] ?? '';
      expectSync(organization, anyOf('org-1', 'org-2'));
      if (url.path == '/console/org') {
        return (200, {'orgId': organization, 'role': 'owner'});
      }
      if (url.path.endsWith('/ack')) {
        expectSync(method, 'POST');
        acknowledgementScopes.add(organization);
        if (acknowledgementScopes.length == 1) {
          return heldAcknowledgement.future;
        }
        acknowledgedOrganizations.add(organization);
        return (200, {'ok': true});
      }
      expectSync(method, 'GET');
      final acknowledged = acknowledgedOrganizations.contains(organization);
      return (200, {
        'events': [{
          'id': 'fixture-alert',
          'orgId': organization,
          'machineId': null,
          'at': 1788700000,
          'kind': 'rule_fired',
          'severity': 'warn',
          'summary': summary(organization),
          'detail': null,
          'acknowledgedBy': acknowledged ? 'user-A' : null,
          'acknowledgedAt': acknowledged ? 1788700200 : null,
        }],
      });
    }
    return super.reply(method, url, headers);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('late ACK403 cannot invalidate ConsolePage after same-user organization A-B-A',
      (tester) async {
    isTest = true;
    Get.testMode = true;
    final native = CountingAlertNativeBoundary();
    native.options[
        'labdesk-ui-org-v1-${base64Url.encode(utf8.encode('user-A'))}'] = 'org-1';
    final broker = DeferredAlertBoundary();
    platformFFI.ffiBind = native;
    HttpOverrides.global = broker;
    addTearDown(() => HttpOverrides.global = null);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final channel in [
      'desktop_multi_window', 'uni_links/messages', 'uni_links/events'
    ]) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (call) async => call.method == 'getAllSubWindowIds' ? <int>[] : null);
    }
    await initGlobalFFI();
    gFFI.serverModel.serverId.text = '123456789';
    gFFI.userModel.userName.value = 'Account A';
    addTearDown(() async {
      if (!broker.heldAcknowledgement.isCompleted) {
        broker.heldAcknowledgement.complete((403, {'error': 'Old scope denied.'}));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });
    await tester.pumpWidget(
        const GetMaterialApp(home: Scaffold(body: LabDeskConsolePage())));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.text('Fleet').first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Tab, 'Alerts'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, 'Alerts'));
    await tester.pumpAndSettle();
    var previousSummary = broker.summary('org-1');
    expect(find.text(previousSummary), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Acknowledge'));
    await tester.pump();
    expect(broker.acknowledgementScopes, ['org-1']);
    expect(broker.heldAcknowledgement.isCompleted, isFalse);

    for (final (organization, label) in [('org-2', 'Org B'), ('org-1', 'Org A')]) {
      broker.generation++;
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pump();
      expect(find.text(previousSummary), findsNothing,
          reason: 'Protected rows clear before the outgoing tab finishes its transition.');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fleet').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Alerts'));
      await tester.pumpAndSettle();
      previousSummary = broker.summary(organization);
      expect(find.text(previousSummary), findsOneWidget);
      expect(native.options['access_token'], 'account-A');
    }

    broker.heldAcknowledgement.complete((403, {'error': 'Old scope denied.'}));
    await tester.pumpAndSettle();
    expect(find.text(previousSummary), findsOneWidget);
    expect(find.text('Old scope denied.'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Acknowledge'));
    await tester.pumpAndSettle();
    expect(broker.acknowledgementScopes, ['org-1', 'org-1']);
    expect(find.textContaining('Acknowledged '), findsOneWidget);
    expect(find.text('Account A'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    final requestsAtDisposal = List<String>.of(broker.calls);
    final nativeCallsAtDisposal = native.invocationCount;
    final optionsAtDisposal = Map<String, String>.of(native.options);
    // The shared peer-status timeout is finite; console poll timers are disposed.
    // Cross two 15-second inbox periods and the 10-second status timeout.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 11));
      expect(broker.calls, requestsAtDisposal);
      expect(native.invocationCount, nativeCallsAtDisposal);
      expect(native.options, optionsAtDisposal);
      expect(tester.takeException(), isNull);
    }
    expect(labdeskStatusChecking.value, isFalse);
  });
}
