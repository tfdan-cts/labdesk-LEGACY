import 'package:flutter/material.dart';
import '../theme/console_theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Labnet', style: C.of(context).h2()),
            const SizedBox(height: 12),
            Text(
              'Manage encrypted networks and machine access under Labnets. '
              'Enroll this computer under This machine and turn on Labnet '
              'to connect it to your organization.',
              style: C.of(context).body(),
            ),
          ],
        ),
      );
}
