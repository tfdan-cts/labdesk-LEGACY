import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/labdesk/console_page.dart';
import 'package:flutter_hbb/labdesk/models/labnet.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

import 'native_boundary_types.dart';

class NativeBoundary extends Fake implements LabDeskImpl {
  final options = <String, String>{
    'access_token': 'account-A',
    'labdesk-overlay-consent': 'asked',
  };
  final calls = <String>{};
  @override
  dynamic noSuchMethod(Invocation call) {
    final name = call.memberName.toString().split('"')[1];
    calls.add(name);
    if (name == 'translate') return call.namedArguments[#name];
    if (name == 'mainGetLocalOption')
      return options[call.namedArguments[#key]] ?? '';
    if (name == 'mainSetLocalOption') {
      options[call.namedArguments[#key] as String] =
          call.namedArguments[#value] as String;
      return Future<void>.value();
    }
    if (name == 'mainAgentSign')
      return Future.value(
          '{"machine":"machine-1","ts":"1","sig":"test-signature"}');
    if (name == 'mainOverlayDaemon') {
      if (call.namedArguments[#action] != 'status')
        throw StateError('Unexpected daemon mutation: $call');
      return Future.value('{"error":"failed to connect to daemon"}');
    }
    if (name == 'mainGetMyId') return Future.value('123456789');
    if (name == 'mainIsInstalled') return true;
    if (name == 'mainGetAppNameSync') return 'LabDesk';
    if (name == 'mainGetOptions') return Future.value('{}');
    if (name == 'mainGetConnectStatus') return Future.value('{"status_num":0}');
    switch (nativeBoundaryTypes[name]) {
      case 'String':
        return '';
      case 'bool':
        return false;
      case 'int':
        return 0;
      case 'Future<String>':
        return Future<String>.value('');
      case 'Future<bool>':
        return Future<bool>.value(false);
      case 'Future<int>':
        return Future<int>.value(0);
      case 'Future<void>':
        return Future<void>.value();
      case 'void':
        return null;
      default:
        throw StateError(
            'Unconfigured native boundary: $name ${nativeBoundaryTypes[name]}');
    }
  }
}

class BrokerBoundary extends HttpOverrides {
  final calls = <String>[];
  bool ownerRemoval = false;
  String get targetMachine => ownerRemoval ? 'machine-2' : 'machine-1';
  int leaveStatus = 202;
  String memberStatus = 'approved';
  String message = 'Removal queued. Network update pending.';
  String? failedRead;
  bool staleMembershipRead = false;
  bool unrelatedGroupPending = false;
  final failedReadCalls = <String>[];
  Completer<(int, Object)>? heldLeave;
  Future<(int, Object)> reply(
      String method, Uri url, Map<String, String> headers) async {
    calls.add('$method ${url.path}');
    if (method == 'GET' &&
        url.path == failedRead &&
        memberStatus != 'approved') {
      failedReadCalls.add(url.path);
      return (500, {'error': 'Membership refresh unavailable.'});
    }
    final account = headers['authorization'] ?? '';
    if (url.path == '/console/organizations')
      return (
        200,
        {
          'userId': account.endsWith('account-B') ? 'user-B' : 'user-A',
          'organizations': [
            {'orgId': 'org-1', 'name': 'Test organization', 'role': 'owner'}
          ],
        }
      );
    if (url.path == '/console/org')
      return (200, {'orgId': 'org-1', 'role': 'owner'});
    if (url.path == '/console/org/machines')
      return (
        200,
        {
          'machines': [
            {
              'id': 'machine-1',
              'peerId': '123456789',
              'displayName': 'This test machine',
              'platform': 'Windows'
            },
            if (ownerRemoval)
              {
                'id': 'machine-2',
                'peerId': '987654321',
                'displayName': 'Other test machine',
                'platform': 'Windows'
              },
          ]
        }
      );
    if (url.path == '/console/org/fleets') return (200, {'fleets': []});
    if (url.path == '/agent/overlay/inbox')
      return (
        200,
        {
          'device': {'enrolled': true},
          'invitations': []
        }
      );
    if (url.path == '/console/overlay/labnets')
      return (
        200,
        {
          'labnets': [
            {
              'id': 'labnet-1',
              'name': 'Integration network',
              'fullAccess': false,
              'syncPending': unrelatedGroupPending ||
                  !staleMembershipRead &&
                      (memberStatus == 'leaving' || memberStatus == 'removing'),
              'members': memberStatus.isEmpty && !staleMembershipRead
                  ? []
                  : [
                      {
                        'machineId': targetMachine,
                        'status':
                            staleMembershipRead ? 'approved' : memberStatus
                      }
                    ],
            }
          ]
        }
      );
    if (url.path.endsWith('/leave') ||
        (method == 'DELETE' && url.path.endsWith('/members/machine-2'))) {
      if (heldLeave != null) return heldLeave!.future;
      if (leaveStatus == 202)
        memberStatus = ownerRemoval ? 'removing' : 'leaving';
      if (leaveStatus == 200) memberStatus = '';
      return (leaveStatus, {'message': message, 'error': message});
    }
    if (method == 'GET' && url.path.startsWith('/console/org/machines/'))
      return (200, {});
    throw StateError('Unexpected HTTP boundary: $method $url');
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) => ClientBoundary(this);
}

class ClientBoundary extends Fake implements HttpClient {
  ClientBoundary(this.broker);
  final BrokerBoundary broker;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      RequestBoundary(broker, method, url);
  @override
  void close({bool force = false}) {}
}

class HeadersBoundary extends Fake implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = '$value';
}

class RequestBoundary extends Fake implements HttpClientRequest {
  RequestBoundary(this.broker, this.method, this.url);
  final BrokerBoundary broker;
  final String method;
  final Uri url;
  @override
  final HeadersBoundary headers = HeadersBoundary();
  @override
  void write(Object? value) {}
  @override
  Future<HttpClientResponse> close() async {
    final (status, body) = await broker.reply(method, url, headers.values);
    return ResponseBoundary(status, utf8.encode(jsonEncode(body)));
  }
}

class ResponseBoundary extends Stream<List<int>> implements HttpClientResponse {
  ResponseBoundary(this.statusCode, this.bytes);
  @override
  final int statusCode;
  final List<int> bytes;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream.value(bytes).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation call) =>
      throw StateError('Unexpected response call: $call');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'completed removal preserves another member pending state and permissions',
      () {
    const inbox = LabnetInbox(labnets: [
      Labnet(
        id: 'labnet-1',
        name: 'Shared network',
        fullAccess: false,
        owner: false,
        fleetId: 'fleet-1',
        syncPending: true,
        members: [
          LabnetMember(deviceId: 'completed', status: 'removing'),
          LabnetMember(deviceId: 'other', status: 'removing'),
        ],
      )
    ]);
    final network = inbox
        .withRemovalResults({('labnet-1', 'completed'): 'removed'})
        .labnets
        .single;
    expect(network.members.single.deviceId, 'other');
    expect(network.members.single.removalPending, isTrue);
    expect(network.syncPending, isTrue);
    expect(network.fullAccess, isFalse);
    expect(network.owner, isFalse);
    expect(network.fleetId, 'fleet-1');
  });
  test(
      'completed member preserves a group reservation with no pending member rows',
      () {
    const inbox = LabnetInbox(labnets: [
      Labnet(
        id: 'labnet-1',
        name: 'Shared network',
        fullAccess: false,
        owner: true,
        syncPending: true,
        members: [
          LabnetMember(deviceId: 'completed', status: 'approved'),
          LabnetMember(deviceId: 'unrelated', status: 'approved'),
        ],
      )
    ]);
    final network = inbox
        .withRemovalResults({('labnet-1', 'completed'): 'removed'})
        .labnets
        .single;
    expect(network.members.single.deviceId, 'unrelated');
    expect(network.members.single.approved, isTrue);
    expect(network.syncPending, isTrue,
        reason:
            'The group reservation/revision is independent of this member completion.');
  });
  for (final ownerRemoval in [false, true]) {
    for (final (failedRead, completedRead) in <(String?, String?)>[
      (null, null),
      ('/agent/overlay/inbox', null),
      ('/console/overlay/labnets', null),
      (null, '/agent/overlay/inbox'),
      (null, '/console/overlay/labnets'),
      (null, 'stale-approved'),
      (null, 'group-pending'),
    ]) {
      testWidgets(
          'actual ConsolePage handles 202, refresh, 500, 200 and stale A-B-A; owner removal: $ownerRemoval; failed read: $failedRead; completed read: $completedRead',
          (tester) async {
        isTest = true;
        Get.testMode = true;
        final native = NativeBoundary();
        final broker = BrokerBoundary()
          ..ownerRemoval = ownerRemoval
          ..failedRead = failedRead;
        final actionLabel = ownerRemoval ? 'Remove' : 'Leave';
        final retryLabel = ownerRemoval ? 'Retry removal' : 'Retry leave';
        final operation = ownerRemoval
            ? 'DELETE /console/overlay/labnets/labnet-1/members/machine-2'
            : 'POST /agent/overlay/labnets/labnet-1/leave';
        platformFFI.ffiBind = native;
        HttpOverrides.global = broker;
        addTearDown(() {
          HttpOverrides.global = null;
          debugPrint('NATIVE CALLS: ${native.calls}');
        });
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final channel in [
          'desktop_multi_window',
          'uni_links/messages',
          'uni_links/events'
        ]) {
          tester.binding.defaultBinaryMessenger
              .setMockMethodCallHandler(MethodChannel(channel), (call) async {
            if (call.method == 'getAllSubWindowIds') return <int>[];
            return null;
          });
        }
        await initGlobalFFI();
        gFFI.serverModel.serverId.text = '123456789';
        gFFI.userModel.userName.value = 'Account A';
        final captureKey = GlobalKey();
        final shotDirectory = Platform.environment['LABDESK_TEST_ARTIFACT_DIR'];
        if (shotDirectory != null) {
          await tester.runAsync(() async {
            for (final font in {
              'Manrope': 'assets/fonts/Manrope-Variable.ttf',
              'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
            }.entries) {
              final loader = FontLoader(font.key)
                ..addFont(rootBundle.load(font.value));
              await loader.load();
            }
          });
        }
        await tester.pumpWidget(GetMaterialApp(
            home: RepaintBoundary(
                key: captureKey,
                child: const Scaffold(body: LabDeskConsolePage()))));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(tester.takeException(), isNull);
        expect(find.text('Labnets'), findsOneWidget);
        await tester.tap(find.text('Labnets'));
        await tester.pumpAndSettle();
        expect(find.text('Integration network'), findsOneWidget);
        expect(find.text(actionLabel), findsOneWidget);
        await tester.tap(find.text(actionLabel));
        await tester.pumpAndSettle();
        expect(broker.calls.where((call) => call == operation), hasLength(1));
        expect(find.text(broker.message), findsOneWidget);
        expect(find.text(retryLabel), findsOneWidget);
        expect(find.text('1 machines listed. Network update pending.'),
            findsOneWidget);
        expect(find.text(actionLabel), findsNothing);
        expect(find.textContaining('1 of 1 machines joined.'), findsNothing);
        expect(
            tester
                .widget<GestureDetector>(find
                    .ancestor(
                        of: find.text('Full access: off'),
                        matching: find.byType(GestureDetector))
                    .first)
                .onTap,
            isNull,
            reason:
                'Acknowledged removal must disable access expansion even if refresh fails.');
        if (failedRead != null) {
          expect(broker.failedReadCalls, [failedRead],
              reason:
                  'The first 202 must be followed by the failing real broker read.');
        }
        broker.failedRead = null;
        broker.staleMembershipRead = true;
        if (shotDirectory != null && failedRead == '/console/overlay/labnets') {
          for (final width in [1400.0, 800.0]) {
            tester.view.physicalSize = Size(width, 1000);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text(broker.message), findsOneWidget);
            await tester.runAsync(() async {
              final boundary = captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
              final picture = await boundary.toImage(pixelRatio: 1);
              final bytes =
                  await picture.toByteData(format: ui.ImageByteFormat.png);
              await Directory(shotDirectory).create(recursive: true);
              await File(
                      '$shotDirectory/full-console-pending-${ownerRemoval ? 'remove' : 'leave'}-${width.toInt()}.png')
                  .writeAsBytes(bytes!.buffer.asUint8List());
              picture.dispose();
            });
          }
          tester.view.physicalSize = const Size(1400, 1000);
          await tester.pumpAndSettle();
        }

        await tester.tap(find.text('Home').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Labnets').first);
        await tester.pumpAndSettle();
        expect(find.text(broker.message), findsOneWidget,
            reason:
                'Successful background reads must not erase the pending operation response.');
        expect(find.text(retryLabel), findsOneWidget);
        expect(find.text('1 machines listed. Network update pending.'),
            findsOneWidget,
            reason:
                'A stale successful read must not undo acknowledged removal.');
        broker.staleMembershipRead = false;

        broker.leaveStatus = 500;
        broker.message =
            'Network removal failed. Retry when the service recovers.';
        await tester.tap(find.text(retryLabel));
        await tester.pumpAndSettle();
        expect(find.text(broker.message), findsOneWidget);
        expect(find.text(retryLabel), findsOneWidget);
        expect(find.text('1 machines listed. Network update pending.'),
            findsOneWidget);

        broker.leaveStatus = 200;
        final staleCompletedRead = completedRead == 'stale-approved' ||
            completedRead == 'group-pending';
        final groupStillPending =
            completedRead != null && completedRead != 'stale-approved';
        broker.failedRead = staleCompletedRead ? null : completedRead;
        broker.staleMembershipRead = staleCompletedRead;
        broker.unrelatedGroupPending = completedRead == 'group-pending';
        await tester.tap(find.text(retryLabel));
        await tester.pumpAndSettle();
        if (completedRead?.startsWith('/') == true) {
          expect(broker.failedReadCalls.last, completedRead,
              reason:
                  'The confirmed 200 must be followed by the intended failed read.');
        }
        expect(broker.calls.where((call) => call == operation), hasLength(3));
        expect(find.text(broker.message), findsNothing);
        expect(find.text(retryLabel), findsNothing);
        expect(find.text('Removal pending'), findsNothing);
        expect(find.textContaining('Network update pending.'),
            groupStillPending ? findsWidgets : findsNothing);
        expect(find.text(actionLabel), findsNothing);
        expect(
            tester
                .widget<GestureDetector>(find
                    .ancestor(
                        of: find.text('Full access: off'),
                        matching: find.byType(GestureDetector))
                    .first)
                .onTap,
            groupStillPending ? isNull : isNotNull,
            reason:
                'Only a settled group read releases group-level access restrictions.');
        if (shotDirectory != null &&
            completedRead == '/console/overlay/labnets') {
          for (final width in [1400.0, 800.0]) {
            tester.view.physicalSize = Size(width, 1000);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.runAsync(() async {
              final boundary = captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
              final picture = await boundary.toImage(pixelRatio: 1);
              final bytes =
                  await picture.toByteData(format: ui.ImageByteFormat.png);
              await Directory(shotDirectory).create(recursive: true);
              await File(
                      '$shotDirectory/full-console-completed-${ownerRemoval ? 'remove' : 'leave'}-${width.toInt()}.png')
                  .writeAsBytes(bytes!.buffer.asUint8List());
              picture.dispose();
            });
          }
          tester.view.physicalSize = const Size(1400, 1000);
          await tester.pumpAndSettle();
        }

        if (completedRead != null) {
          await tester.tap(find.text('Home').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Labnets').first);
          await tester.pumpAndSettle();
          expect(find.text(retryLabel), findsNothing);
          expect(find.text(actionLabel), findsNothing);
          expect(find.text('Removal pending'), findsNothing);
          expect(find.textContaining('Network update pending.'),
              groupStillPending ? findsWidgets : findsNothing);
          broker.failedRead = null;
          broker.staleMembershipRead = false;
          broker.unrelatedGroupPending = false;
          await tester.tap(find.text('Home').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Labnets').first);
          await tester.pumpAndSettle();
        }

        broker.memberStatus = 'approved';
        await tester.tap(find.text('Home').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Labnets').first);
        await tester.pumpAndSettle();
        expect(find.text(actionLabel), findsOneWidget);
        broker.heldLeave = Completer<(int, Object)>();
        await tester.tap(find.text(actionLabel));
        await tester.pump();
        expect(broker.calls.where((call) => call == operation), hasLength(4));
        native.options['access_token'] = 'account-B';
        gFFI.userModel.userName.value = 'Account B';
        await tester.pumpAndSettle();
        expect(find.text('Account B'), findsOneWidget);
        native.options['access_token'] = 'account-A';
        gFFI.userModel.userName.value = 'Account A';
        await tester.pumpAndSettle();
        expect(find.text('Account A'), findsOneWidget);
        await tester.tap(find.text('Labnets').first);
        await tester.pumpAndSettle();
        broker.heldLeave!
            .completeError(StateError('stale account operation failed'));
        await tester.pumpAndSettle();
        expect(find.textContaining('stale account operation failed'),
            findsNothing);
        expect(find.text(actionLabel), findsOneWidget);
        expect(tester.takeException(), isNull);
        broker.heldLeave = null;
        broker.leaveStatus = 202;
        await tester.tap(find.text(actionLabel));
        await tester.pumpAndSettle();
        expect(find.text(retryLabel), findsOneWidget);
        broker.memberStatus = 'approved';
        for (final account in ['B', 'A']) {
          native.options['access_token'] = 'account-$account';
          gFFI.userModel.userName.value = 'Account $account';
          await tester.pumpAndSettle();
          await tester.tap(find.text('Labnets').first);
          await tester.pumpAndSettle();
          expect(find.text('Account $account'), findsOneWidget);
          expect(find.text(actionLabel), findsOneWidget,
              reason:
                  'Acknowledged pending state must not cross an account epoch.');
          expect(find.text(retryLabel), findsNothing);
          expect(find.textContaining('Network update pending.'), findsNothing);
        }
        if (completedRead == 'stale-approved') {
          broker.heldLeave = Completer<(int, Object)>();
          await tester.tap(find.text(actionLabel));
          await tester.pump();
          for (final account in ['B', 'A']) {
            native.options['access_token'] = 'account-$account';
            gFFI.userModel.userName.value = 'Account $account';
            await tester.pumpAndSettle();
          }
          await tester.tap(find.text('Labnets').first);
          await tester.pumpAndSettle();
          broker.heldLeave!.complete((200, {}));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Home').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Labnets').first);
          await tester.pumpAndSettle();
          expect(find.textContaining('Network update pending.'), findsNothing);
          expect(find.text(actionLabel), findsOneWidget,
              reason:
                  'An old account epoch completion cannot remove current membership.');
          expect(find.text(retryLabel), findsNothing);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 11));
      });
    }
  }
}
