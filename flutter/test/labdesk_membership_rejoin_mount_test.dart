import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/labdesk/console_page.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

import 'labdesk_full_console_mount_test.dart'
    show NativeBoundary, BrokerBoundary;

class RejoinBoundary extends BrokerBoundary {
  bool invitation = false;
  int intentStatus = 200;
  Completer<(int, Object)>? heldIntent;
  int absentReads = 0;
  String get intentPath => ownerRemoval
      ? '/console/overlay/labnets/labnet-1/invite'
      : '/agent/overlay/invites/labnet-1/decide';

  @override
  Future<(int, Object)> reply(
      String method, Uri url, Map<String, String> headers) async {
    if (method == 'POST' && url.path == intentPath) {
      calls.add('$method ${url.path}');
      if (heldIntent != null) return heldIntent!.future;
      if (intentStatus != 200)
        return (intentStatus, {'error': 'Rejoin refused.'});
      memberStatus = ownerRemoval ? 'pending' : 'approved';
      staleMembershipRead = false;
      invitation = false;
      return (200, {
        'ok': true,
        if (!ownerRemoval) ...{'status': 'approved', 'syncPending': false},
      });
    }
    if (url.path == '/agent/overlay/inbox') {
      calls.add('$method ${url.path}');
      return (
        200,
        {
          'device': {'enrolled': true},
          'invitations': [
            if (invitation)
              {
                'labnetId': 'labnet-1',
                'name': 'Integration network',
                'invitedBy': 'Owner'
              }
          ],
        }
      );
    }
    if (url.path == '/console/overlay/labnets' &&
        memberStatus.isEmpty &&
        !staleMembershipRead) absentReads++;
    return super.reply(method, url, headers);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final ownerRemoval in [true, false]) {
    testWidgets(
        'public ${ownerRemoval ? "Invite" : "Approve"} supersedes completed removal without an absent read',
        (tester) async {
      isTest = true;
      Get.testMode = true;
      final native = NativeBoundary();
      final broker = RejoinBoundary()..ownerRemoval = ownerRemoval;
      platformFFI.ffiBind = native;
      HttpOverrides.global = broker;
      addTearDown(() => HttpOverrides.global = null);
      tester.view.physicalSize = const Size(1400, 1000);
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
            (call) async =>
                call.method == 'getAllSubWindowIds' ? <int>[] : null);
      }
      await initGlobalFFI();
      gFFI.serverModel.serverId.text = '123456789';
      gFFI.userModel.userName.value = 'Account A';
      await tester.pumpWidget(
          const GetMaterialApp(home: Scaffold(body: LabDeskConsolePage())));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.text('Labnets').first);
      await tester.pumpAndSettle();
      final removal = ownerRemoval ? 'Remove' : 'Leave';
      Future<void> refresh() async {
        await tester.tap(find.text('Home').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Refresh').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Labnets').first);
        await tester.pumpAndSettle();
      }

      Future<void> completeRemoval() async {
        broker.leaveStatus = 200;
        broker.staleMembershipRead = true;
        await tester.tap(find.text(removal));
        await tester.pumpAndSettle();
        expect(find.text(removal), findsNothing);
        if (!ownerRemoval) {
          broker.invitation = true;
          broker.memberStatus = 'pending';
          broker.staleMembershipRead = false;
          await refresh();
          expect(find.text('Approve'), findsOneWidget);
        }
      }

      Future<void> beginIntent() async {
        if (ownerRemoval) {
          await tester.tap(find.text('Add machine'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Other test machine').last);
        } else {
          await tester.tap(find.text('Approve'));
        }
        await tester.pumpAndSettle();
      }

      await completeRemoval();
      broker.intentStatus = 500;
      await beginIntent();
      expect(find.text('Rejoin refused.'), findsOneWidget);
      expect(find.text(removal), findsNothing,
          reason: 'A failed newer intent cannot retire completion evidence.');
      expect(find.text('Waiting for approval on that machine'), findsNothing);
      broker.intentStatus = 200;
      await beginIntent();
      expect(broker.calls.where((call) => call == 'POST ${broker.intentPath}'),
          hasLength(2));
      expect(broker.absentReads, 0);
      expect(find.text(removal), findsOneWidget,
          reason:
              'Successful newer membership intent must supersede the old completion.');
      if (ownerRemoval) {
        expect(
            find.text('Waiting for approval on that machine'), findsOneWidget);
      } else {
        expect(find.textContaining('1 of 1 machines joined.'), findsOneWidget);
      }

      // A prior account epoch's response cannot erase a later removal marker.
      await completeRemoval();
      broker.heldIntent = Completer<(int, Object)>();
      await beginIntent();
      broker.memberStatus = 'approved';
      broker.staleMembershipRead = false;
      broker.invitation = false;
      for (final account in ['B', 'A']) {
        native.options['access_token'] = 'account-$account';
        gFFI.userModel.userName.value = 'Account $account';
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Labnets').first);
      await tester.pumpAndSettle();
      expect(find.text(removal), findsOneWidget);
      await completeRemoval();
      broker.heldIntent!.complete((200, {'ok': true}));
      await tester.pumpAndSettle();
      await refresh();
      expect(find.text(removal), findsNothing,
          reason:
              'Stale successful intent cannot clear the current epoch marker.');
      expect(find.text('Waiting for approval on that machine'), findsNothing);
      expect(broker.absentReads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });
  }
}
