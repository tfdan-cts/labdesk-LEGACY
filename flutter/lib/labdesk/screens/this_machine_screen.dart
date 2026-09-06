import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/console_theme.dart';
import '../theme/ld_icons.dart';

/// What this machine is, for the operator sitting at it.
///
/// The old home page put the identity in a fixed left rail that was present on
/// every screen whether or not it was wanted. It is a section now, because it
/// is read when setting a machine up and rarely afterwards.
///
/// Deliberately free of the FFI: the client passes the values in, so this
/// renders in the design harness like every other console screen.
class ThisMachineScreen extends StatelessWidget {
  const ThisMachineScreen({
    super.key,
    required this.machineId,
    required this.password,
    this.passwordIsTemporary = true,
    this.serviceRunning,
    this.profileSwitcher,
    this.enrol,
    this.labnet,
    this.selfHeal,
    this.onEditPassword,
    this.onRefreshPassword,
    this.onOpenIdMenu,
    this.onStartService,
    this.displayName,
    this.onEditDisplayName,
  });

  /// This machine's own id, as the client reports it.
  final String machineId;

  /// The password a peer would be asked for. Never rendered as a value the
  /// operator could mistake for permanent when it is not.
  final String password;
  final bool passwordIsTemporary;

  /// Whether the background service is installed and running, or null when the
  /// platform has no such concept.
  final bool? serviceRunning;

  /// The client's own profile switcher, mounted whole rather than reimplemented.
  final Widget? profileSwitcher;

  /// The organization card: enrolling this machine with an enrolment token.
  final Widget? enrol;

  /// The labnet card: whether this machine takes encrypted direct connections.
  final Widget? labnet;

  /// The self-healing card: whether the background service repairs this
  /// machine's own network when it drops.
  final Widget? selfHeal;

  final VoidCallback? onEditPassword;
  final VoidCallback? onRefreshPassword;
  final VoidCallback? onOpenIdMenu;

  /// Offered only while the service is stopped, which is the one moment it is
  /// useful. The old interface put this link under the status line.
  final VoidCallback? onStartService;

  /// The name the far side sees when this machine connects out to it.
  ///
  /// It was never shown anywhere, so an operator only found out what it was by
  /// looking at somebody else's screen — and the default is the account name or
  /// the OS username, which is rarely what anybody wants announced. Null hides
  /// the row entirely, which is what the design harness and any build that
  /// cannot read the option get.
  final String? displayName;

  final VoidCallback? onEditDisplayName;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Card(
            title: 'Identity',
            subtitle: 'What another operator types to reach this machine.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The id is the one thing on this screen somebody reads out
                // over the phone, so it gets the console's data plane — the
                // same box the installer puts its path in and a dialog puts a
                // machine's name in — and nothing else shares its row but the
                // controls that act on it.
                Text('MACHINE ID',
                    style: C.of(context).micro().copyWith(letterSpacing: 0.8)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 46,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                          color: C.of(context).bg,
                          borderRadius: C.roundedSm,
                          border: Border.all(color: C.of(context).hairline),
                        ),
                        child: SelectableText(
                          machineId,
                          maxLines: 1,
                          style: C.of(context).data(size: 20, w: FontWeight.w600),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GhostButton(
                      label: 'Copy',
                      glyph: LdIcons.clipboard,
                      onPressed: machineId.isEmpty
                          ? null
                          : () => Clipboard.setData(
                              ClipboardData(text: machineId)),
                    ),
                    if (onOpenIdMenu != null) ...[
                      const SizedBox(width: 8),
                      GhostButton(
                        label: 'ID options',
                        glyph: LdIcons.more,
                        onPressed: onOpenIdMenu,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 20),
                Container(height: 1, color: C.of(context).hairline),
                const SizedBox(height: 18),
                // The password is a sentence rather than a second field: it is
                // one fact about how this machine is secured, and the value
                // itself is only present in the temporary case. Selectable, so
                // it can still be copied without a control saying so.
                _passwordLine(context),
                if (onRefreshPassword != null || onEditPassword != null) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      if (passwordIsTemporary && onRefreshPassword != null)
                        GhostButton(
                          label: 'New password',
                          glyph: LdIcons.refresh,
                          onPressed: onRefreshPassword,
                        ),
                      if (passwordIsTemporary &&
                          onRefreshPassword != null &&
                          onEditPassword != null)
                        const SizedBox(width: 8),
                      if (onEditPassword != null)
                        GhostButton(
                          label: passwordIsTemporary
                              ? 'Use a permanent password'
                              : 'Change password',
                          glyph: LdIcons.lock,
                          onPressed: onEditPassword,
                        ),
                    ],
                  ),
                ],
                if (displayName != null) ...[
                  const SizedBox(height: 18),
                  Container(height: 1, color: C.of(context).hairline),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText.rich(
                          TextSpan(
                            style: C.of(context).body(color: C.of(context).textMuted),
                            children: [
                              const TextSpan(
                                  text: 'Shown to machines you connect to as '),
                              TextSpan(
                                text: displayName!.isEmpty
                                    ? 'your account or sign-in name'
                                    : displayName!,
                                style: C.of(context).data(
                                    size: 14, color: C.of(context).text, w: FontWeight.w700),
                              ),
                              const TextSpan(text: '.'),
                            ],
                          ),
                        ),
                      ),
                      if (onEditDisplayName != null) ...[
                        const SizedBox(width: 10),
                        GhostButton(
                          label: 'Change',
                          glyph: LdIcons.settings,
                          onPressed: onEditDisplayName,
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (profileSwitcher != null) ...[
            const SizedBox(height: 16),
            _Card(
              // No title: the switcher mounted below prints its own "Server
              // profile" caption, and the card was printing it a second time
              // directly above it.
              title: 'Servers',
              subtitle:
                  'Which ID and relay servers this machine is registered with.',
              child: profileSwitcher!,
            ),
          ],
          if (enrol != null) ...[
            const SizedBox(height: 16),
            enrol!,
          ],
          if (labnet != null) ...[
            const SizedBox(height: 16),
            labnet!,
          ],
          if (selfHeal != null) ...[
            const SizedBox(height: 16),
            selfHeal!,
          ],
          if (serviceRunning != null) ...[
            const SizedBox(height: 16),
            _Card(
              title: 'Background service',
              subtitle: serviceRunning!
                  ? 'Running, so this machine can be reached while nobody is '
                      'signed in.'
                  : 'Not running. This machine can only be reached while '
                      'somebody is signed in and the application is open.',
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: serviceRunning! ? C.of(context).ok : C.of(context).idle,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(serviceRunning! ? 'Running' : 'Stopped', style: C.of(context).body()),
                  if (!serviceRunning! && onStartService != null) ...[
                    const Spacer(),
                    _TextAction(
                        label: 'Start service', onTap: onStartService!),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// What a caller is asked for, in a sentence.
  ///
  /// A permanent password is never handed back to the interface, so there is
  /// no value to print for it — which is why it is stated rather than drawn as
  /// an empty field.
  Widget _passwordLine(BuildContext context) {
    if (!passwordIsTemporary) {
      return SelectableText(
        'This machine uses a permanent password. It is not shown here; set or '
        'change it in Security settings.',
        style: C.of(context).body(color: C.of(context).textMuted),
      );
    }
    if (password.isEmpty || password == '-') {
      return SelectableText(
        'A one-time password changes whenever it is regenerated, so '
        'unattended access needs a permanent one instead.',
        style: C.of(context).body(color: C.of(context).textMuted),
      );
    }
    return SelectableText.rich(
      TextSpan(
        style: C.of(context).body(color: C.of(context).textMuted),
        children: [
          const TextSpan(text: 'A caller is asked for the one-time password '),
          TextSpan(
            text: password,
            style: C.of(context).data(size: 14, color: C.of(context).text, w: FontWeight.w700),
          ),
          const TextSpan(
              text: ', which changes whenever it is regenerated. Unattended '
                  'access needs a permanent password instead.'),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, this.subtitle, required this.child});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: C.of(context).surface,
        borderRadius: C.rounded,
        border: Border.all(color: C.of(context).hairline),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: C.of(context).h2()),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: C.of(context).small()),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// A plain textual action, for the one or two places a button would shout.
class _TextAction extends StatefulWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_TextAction> createState() => _TextActionState();
}

class _TextActionState extends State<_TextAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.label,
          style: C.of(context).small(color: _hover ? C.of(context).accent : C.of(context).textMuted).copyWith(
            decoration: TextDecoration.underline,
            decorationColor: _hover ? C.of(context).accent : C.of(context).textFaint,
          ),
        ),
      ),
    );
  }
}
