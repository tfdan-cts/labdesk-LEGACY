import 'package:flutter/material.dart';

/// Whether the phone should ask for a server before anything else.
///
/// It asks when it has nothing: no server profile and no sign in. Signing in
/// counts because a sign in is what writes the server, so a signed in client
/// already has one. Skipping counts because asking twice for something the
/// operator declined is nagging, not onboarding.
///
/// Deliberately a plain function over three booleans rather than a read of the
/// configuration, so the rule can be stated and tested on its own.
bool needsServerSetup({
  required bool hasProfile,
  required bool isSignedIn,
  required bool skipped,
}) =>
    !hasProfile && !isSignedIn && !skipped;

/// The first thing a new install shows.
///
/// It asks for one thing, a server, by the two routes that provide one. It asks
/// for no permission: there is no camera prompt and no notification prompt
/// here, because nothing on this screen uses either, and a permission asked for
/// before the feature that needs it is a permission asked for without a reason.
///
/// The line about the current server is read rather than assumed. When a server
/// is configured it is named. When none is, the screen says the built in
/// default is in use and does not invent its name, because this client cannot
/// currently read the effective server back out of the core.
///
/// That line has room to grow on purpose. A default server is not only a
/// hostname: the client pins a key for it, and this screen is where somebody
/// learns which server and which key they are trusting. When there is a
/// rendezvous server to name, both belong here.
class FirstRunView extends StatelessWidget {
  const FirstRunView({
    super.key,
    required this.configuredServer,
    required this.onSignIn,
    required this.onAddProfile,
    required this.onSkip,
  });

  /// The configured rendezvous server, or empty when none is set.
  final String configuredServer;

  final VoidCallback onSignIn;
  final VoidCallback onAddProfile;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Centred when it fits and scrollable when it does not. A fixed column with
    // spacers overflowed by 60 pixels on a 320 by 480 screen, and a first run
    // screen that cannot be got past is the worst possible one to break.
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Choose a server',
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                _situation(),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: onSignIn,
                child: const Text('Sign in to lab-desk.net'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: onAddProfile,
                child: const Text('Use a server I run'),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: onSkip,
                child: const Text('Not now'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The whole reason this screen exists, so it sits above the buttons and at
  /// body weight rather than under them in a footnote. A fact that arrives
  /// after the decision has been made is not disclosure.
  String _situation() {
    final server = configuredServer.trim();
    if (server.isEmpty) {
      return 'Your machines connect through a server. Until you choose one, '
          'LabDesk falls back to a server built into the app, so your '
          'connections would go through one you did not pick.';
    }
    return 'Your machines connect through a server. This app is currently '
        'set to use $server.';
  }
}
