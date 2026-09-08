import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/screens/startup_gate.dart';
import 'package:flutter_hbb/labdesk/services/desktop_session_access.dart';

void main() {
  testWidgets(
      'signed-out startup offers login and signup without building tools',
      (tester) async {
    var built = 0, signIns = 0, signUps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StartupGate(
          authenticated: false,
          verifying: false,
          onSignIn: () async {
            signIns++;
          },
          onCreateAccount: () async {
            signUps++;
          },
          onRetry: () async {},
          builder: (_) {
            built++;
            return const Text('Protected fleet');
          },
        ),
      ),
    ));
    expect(built, 0);
    expect(find.text('Protected fleet'), findsNothing);
    await tester.tap(find.text('Sign in'));
    await tester.tap(find.text('Create an account'));
    expect(signIns, 1);
    expect(signUps, 1);
  });

  testWidgets('checking a saved session does not expose protected content',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StartupGate(
          authenticated: false,
          verifying: true,
          onSignIn: () async {},
          onCreateAccount: () async {},
          onRetry: () async {},
          builder: (_) => const Text('Protected fleet'),
        ),
      ),
    ));
    expect(find.text('Checking your account…'), findsOneWidget);
    expect(find.text('Protected fleet'), findsNothing);
  });

  testWidgets('verified login opens content; expiry and signout dispose drafts',
      (tester) async {
    final accepted = ValueNotifier(false);
    addTearDown(accepted.dispose);
    final login = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<bool>(
          valueListenable: accepted,
          builder: (_, value, __) => StartupGate(
            authenticated: value,
            verifying: false,
            onSignIn: () => login.future,
            onCreateAccount: () async {},
            onRetry: () async {},
            builder: (_) => const TextField(key: ValueKey('private-draft')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.byKey(const ValueKey('private-draft')), findsNothing);
    login.complete();
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    accepted.value = true;
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Private account draft');
    accepted.value = false;
    await tester.pumpAndSettle();
    expect(find.text('Private account draft'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    accepted.value = true;
    await tester.pumpAndSettle();
    expect(find.text('Private account draft'), findsNothing);
    accepted.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('expired session message stays actionable before sign-in',
      (tester) async {
    var retried = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StartupGate(
      authenticated: false,
      verifying: false,
      message: 'Your session expired. Sign in again.',
      onSignIn: () async {},
      onCreateAccount: () async {},
      onRetry: () async { retried = true; },
      builder: (_) => const Text('Protected fleet'),
    ))));
    expect(find.text('Your session expired. Sign in again.'), findsOneWidget);
    expect(find.text('Protected fleet'), findsNothing);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  test('direct dispatch needs current verified context, including A-B-A', () {
    final access = DesktopSessionAccess();
    expect(access.capture(), isNull);
    expect(access.accepts(null), isFalse);
    DesktopSessionContext? current;
    access.readContext = () => current;
    expect(access.capture(), isNull);
    current = ('token-a', 1);
    final pending = access.capture();
    expect(access.accepts(pending), isTrue);
    current = null;
    expect(access.accepts(pending), isFalse);
    current = ('token-a', 2);
    expect(access.accepts(pending), isFalse);
    final active = access.capture();
    current = ('token-b', 3);
    current = ('token-a', 4);
    expect(access.accepts(active), isFalse);
    expect(access.accepts(access.capture()), isTrue);
    access.readContext = null;
    expect(access.accepts(current), isFalse);
  });

  test('a remounted main window cannot reuse a previous authority marker', () {
    final access = DesktopSessionAccess();
    access.readContext = () => ('same-account', 1);
    final previous = access.capture();
    final nonce = access.nonceFor(previous);
    expect(access.acceptsNonce(nonce), isTrue);
    expect(nonce, isNot(contains('same-account')));
    access.readContext = null;
    access.readContext = () => ('same-account', 1);
    expect(access.accepts(previous), isFalse);
    expect(access.acceptsNonce(nonce), isFalse);
    expect(access.nonceFor(access.capture()), isNot(nonce));
  });
}
