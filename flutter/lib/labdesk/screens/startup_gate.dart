import 'package:flutter/material.dart';

import '../theme/console_theme.dart';

/// Protected pages are not mounted until the server has accepted this account.
class StartupGate extends StatelessWidget {
  const StartupGate({
    super.key,
    required this.authenticated,
    required this.verifying,
    required this.onSignIn,
    required this.onCreateAccount,
    required this.onRetry,
    required this.builder,
    this.message,
  });

  final bool authenticated;
  final bool verifying;
  final String? message;
  final Future<void> Function() onSignIn;
  final Future<void> Function() onCreateAccount;
  final Future<void> Function() onRetry;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    if (authenticated) return builder(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Welcome to LabDesk', style: C.of(context).h2()),
              const SizedBox(height: 16),
              const Text('Sign in to your LabDesk account to open your '
                  'workspace and connect to your machines.'),
              if (verifying) ...[
                const SizedBox(height: 24),
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                const Text('Checking your account…'),
              ] else ...[
                if (message?.isNotEmpty == true) ...[
                  const SizedBox(height: 16),
                  Text(message!),
                ],
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                        onPressed: onSignIn, child: const Text('Sign in')),
                    TextButton(
                        onPressed: onCreateAccount,
                        child: const Text('Create an account')),
                    if (message?.isNotEmpty == true)
                      TextButton(
                          onPressed: onRetry, child: const Text('Retry')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
