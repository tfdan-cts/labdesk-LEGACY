import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/labdesk/console_page.dart';
import 'package:flutter_hbb/labdesk/screens/connect_screen.dart';
import 'package:flutter_hbb/labdesk/screens/console_shell.dart';
import 'package:flutter_hbb/labdesk/screens/reporting_control.dart';
import 'package:flutter_hbb/labdesk/screens/this_machine_screen.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

import 'labdesk_full_console_mount_test.dart'
    show NativeBoundary, BrokerBoundary;

class NamingNativeBoundary extends NativeBoundary {
  final aliases = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName == #mainGetPeerOption)
      return Future.value('Local alias');
    if (call.memberName == #mainSetPeerAlias) {
      aliases[call.namedArguments[#id] as String] =
          call.namedArguments[#alias] as String;
      return Future<void>.value();
    }
    return super.noSuchMethod(call);
  }
}

class NamingBrokerBoundary extends BrokerBoundary {
  final profileReply = Completer<(int, Object)>();
  bool rejectProfile = false;
  final writes = <String>[];

  @override
  Future<(int, Object)> reply(
      String method, Uri url, Map<String, String> headers) async {
    if (method == 'PATCH') {
      expectSync(headers['authorization'], 'Bearer account-A');
      expectSync(headers['x-labdesk-organization'], 'org-1');
      writes.add(url.path);
      if (url.path == '/console/me/profile') {
        if (rejectProfile) return (403, {'error': 'Profile change denied.'});
        return profileReply.future;
      }
      if (url.path == '/console/org/machines/machine-1')
        return (200, {'ok': true});
      if (url.path == '/console/org/machines/machine-1/reporting') {
        return (200, {'machineId': 'machine-1', 'flushSeconds': 300});
      }
    }
    final response = await super.reply(method, url, headers);
    if (url.path == '/console/organizations') {
      return (
        200,
        {
          'userId': 'user-A',
          'organizations': [
            {
              'orgId': 'org-1',
              'name': 'Test organization',
              'role': 'fleet_admin'
            }
          ],
        }
      );
    }
    if (url.path == '/console/org')
      return (200, {'orgId': 'org-1', 'role': 'fleet_admin'});
    return response;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'native naming uses canonical writes, retains local aliases and guards account changes',
      (tester) async {
    isTest = true;
    Get.testMode = true;
    final native = NamingNativeBoundary();
    native.options['user_info'] =
        jsonEncode({'name': 'Original name', 'email': 'operator@example.test'});
    final broker = NamingBrokerBoundary();
    platformFFI.ffiBind = native;
    HttpOverrides.global = broker;
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final channel in [
      'desktop_multi_window',
      'uni_links/messages',
      'uni_links/events'
    ]) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (call) async => call.method == 'getAllSubWindowIds' ? <int>[] : null);
    }
    await initGlobalFFI();
    gFFI.serverModel.serverId.text = '123456789';
    gFFI.userModel.userName.value = 'Account A';
    addTearDown(() async {
      if (!broker.profileReply.isCompleted)
        broker.profileReply.complete((200, {'ok': true}));
      gFFI.dialogManager.dismissAll();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
      HttpOverrides.global = null;
    });
    await tester.pumpWidget(GetMaterialApp(
        navigatorKey: globalKey,
        theme: MyTheme.lightTheme,
        darkTheme: MyTheme.darkTheme,
        home: const Scaffold(body: LabDeskConsolePage())));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    ConsoleShell shell() =>
        tester.widget<ConsoleShell>(find.byType(ConsoleShell));
    Future<void> go(ConsoleSection section) async {
      (shell().sectionRequest! as ConsoleSectionRequest).request(section);
      await tester.pumpAndSettle();
    }

    Future<void> submit(String name) async {
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).last, name);
      await tester.tap(find.text('OK').last);
      await tester.pumpAndSettle();
    }

    final reporting =
        shell().machineHealthFooter!('123456789') as ReportingControl;
    expect(reporting.onSave, isNotNull,
        reason: 'Fleet Admin can manage reporting for scoped machines.');
    await reporting.onSave!(300);
    expect(
        broker.writes, contains('/console/org/machines/machine-1/reporting'));

    await go(ConsoleSection.connect);
    tester.widget<ConnectScreen>(find.byType(ConnectScreen)).onAction!(
        '123456789', RowAction.rename);
    await submit('Canonical machine name');
    expect(broker.writes, contains('/console/org/machines/machine-1'));
    expect(native.aliases, isEmpty,
        reason: 'Managed naming must never become a private alias.');

    tester.widget<ConnectScreen>(find.byType(ConnectScreen)).onAction!(
        'unmanaged-peer', RowAction.rename);
    await submit('Personal alias');
    expect(native.aliases, {'unmanaged-peer': 'Personal alias'});

    await go(ConsoleSection.thisMachine);
    tester
        .widget<ThisMachineScreen>(find.byType(ThisMachineScreen))
        .onEditDisplayName!();
    await submit('');
    expect(find.text('Use 1–128 characters without control characters.'),
        findsOneWidget);
    expect(broker.writes, isNot(contains('/console/me/profile')));
    await submit('New profile name');
    expect(broker.writes.last, '/console/me/profile');
    expect(jsonDecode(native.options['user_info']!)['name'], 'Original name',
        reason: 'Local name changes only after server confirmation.');
    broker.profileReply.complete((200, {'ok': true}));
    await tester.pumpAndSettle();
    expect(jsonDecode(native.options['user_info']!), {
      'name': 'New profile name',
      'display_name': 'New profile name',
      'email': 'operator@example.test',
    });

    broker.rejectProfile = true;
    tester
        .widget<ThisMachineScreen>(find.byType(ThisMachineScreen))
        .onEditDisplayName!();
    await submit('Rejected name');
    expect(
        jsonDecode(native.options['user_info']!)['name'], 'New profile name');
    expect(find.text('Profile change denied.'), findsOneWidget);

    final writesBeforeSwitch = List<String>.of(broker.writes);
    tester
        .widget<ThisMachineScreen>(find.byType(ThisMachineScreen))
        .onEditDisplayName!();
    await tester.pumpAndSettle();
    native.options['access_token'] = 'account-B';
    await submit('Stale dialog name');
    expect(broker.writes, writesBeforeSwitch);
    expect(
        jsonDecode(native.options['user_info']!)['name'], 'New profile name');
    await expectLater(reporting.onSave!(300), throwsStateError);
    expect(broker.writes, writesBeforeSwitch);
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });
}
