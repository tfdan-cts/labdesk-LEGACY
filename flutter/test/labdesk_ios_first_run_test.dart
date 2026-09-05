import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/first_run.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('whether to ask at all', () {
    test('a client with nothing configured is asked', () {
      expect(
        needsServerSetup(hasProfile: false, isSignedIn: false, skipped: false),
        isTrue,
      );
    });

    test('a client that already has a server profile is not asked', () {
      expect(
        needsServerSetup(hasProfile: true, isSignedIn: false, skipped: false),
        isFalse,
      );
    });

    test('a signed in client is not asked, because signing in set the server',
        () {
      expect(
        needsServerSetup(hasProfile: false, isSignedIn: true, skipped: false),
        isFalse,
      );
    });

    test('a client that was asked once and skipped is not asked again', () {
      expect(
        needsServerSetup(hasProfile: false, isSignedIn: false, skipped: true),
        isFalse,
      );
    });
  });

  group('what it asks for', () {
    testWidgets('it offers the two ways to get a server and nothing else',
        (tester) async {
      await tester.pumpWidget(_wrap(FirstRunView(
        configuredServer: '',
        onSignIn: () {},
        onAddProfile: () {},
        onSkip: () {},
      )));

      expect(find.text('Sign in to lab-desk.net'), findsOneWidget);
      expect(find.text('Add a server profile'), findsOneWidget);
    });

    testWidgets('with no server configured it says the built in default is used',
        (tester) async {
      await tester.pumpWidget(_wrap(FirstRunView(
        configuredServer: '',
        onSignIn: () {},
        onAddProfile: () {},
        onSkip: () {},
      )));

      expect(find.textContaining('built in'), findsOneWidget);
    });

    testWidgets('with a server configured it names that server', (tester) async {
      await tester.pumpWidget(_wrap(FirstRunView(
        configuredServer: 'labnet.lab-desk.net',
        onSignIn: () {},
        onAddProfile: () {},
        onSkip: () {},
      )));

      expect(find.textContaining('labnet.lab-desk.net'), findsOneWidget);
      expect(
        find.textContaining('built in'),
        findsNothing,
        reason: 'a configured server is not the default and must not read as one',
      );
    });

    testWidgets('each choice reports itself once', (tester) async {
      var signIn = 0, addProfile = 0, skip = 0;
      await tester.pumpWidget(_wrap(FirstRunView(
        configuredServer: '',
        onSignIn: () => signIn++,
        onAddProfile: () => addProfile++,
        onSkip: () => skip++,
      )));

      await tester.tap(find.text('Sign in to lab-desk.net'));
      await tester.tap(find.text('Add a server profile'));
      await tester.tap(find.text('Not now'));
      await tester.pump();

      expect([signIn, addProfile, skip], [1, 1, 1]);
    });

    testWidgets('it fits a short screen without overflowing', (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(FirstRunView(
        configuredServer: '',
        onSignIn: () {},
        onAddProfile: () {},
        onSkip: () {},
      )));

      expect(
        tester.takeException(),
        isNull,
        reason: 'the smallest phone still has to be able to get past this screen',
      );
      expect(find.text('Sign in to lab-desk.net'), findsOneWidget);
    });

    testWidgets('it asks for no permission and mentions none', (tester) async {
      await tester.pumpWidget(_wrap(FirstRunView(
        configuredServer: '',
        onSignIn: () {},
        onAddProfile: () {},
        onSkip: () {},
      )));

      for (final word in ['camera', 'Camera', 'notification', 'Notification']) {
        expect(
          find.textContaining(word),
          findsNothing,
          reason: 'first run asks for a server and nothing else',
        );
      }
    });
  });
}
