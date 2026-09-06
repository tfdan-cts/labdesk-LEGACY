import 'package:flutter/material.dart';

import '../theme/console_theme.dart';
import '../theme/ld_icons.dart';
import '../theme/settings_skin.dart';

/// A server profile as the settings screen renders it.
///
/// Mirrors what the fork already stores, without importing the profile store,
/// so the screen stays renderable and testable without the FFI layer.
class ProfileRow {
  const ProfileRow({
    required this.name,
    required this.host,
    this.relay = '',
    this.api = '',
    this.hasKey = false,
    this.active = false,
  });

  final String name;
  final String host;
  final String relay;
  final String api;
  final bool hasKey;
  final bool active;
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.profiles,
    this.onActivate,
    this.onEdit,
    this.onDelete,
    this.onAdd,
    this.pollSeconds = 30,
    this.onPollSecondsChanged,
  });

  final List<ProfileRow> profiles;
  final ValueChanged<ProfileRow>? onActivate;
  final ValueChanged<ProfileRow>? onEdit;
  final ValueChanged<ProfileRow>? onDelete;
  final VoidCallback? onAdd;

  final int pollSeconds;
  final ValueChanged<int>? onPollSecondsChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Panel(
            title: 'Server profiles',
            subtitle: 'Named ID, relay, API and key sets. Switching applies immediately.',
            padding: EdgeInsets.zero,
            actions: [
              GhostButton(label: 'Add profile', glyph: LdIcons.add, onPressed: onAdd),
            ],
            child: profiles.isEmpty
                ? const _NoProfiles()
                : Column(
                    children: [
                      for (var i = 0; i < profiles.length; i++) ...[
                        if (i > 0) Divider(height: 1, thickness: 1, color: C.of(context).hairline),
                        _ProfileTile(
                          profile: profiles[i],
                          onActivate: onActivate,
                          onEdit: onEdit,
                          onDelete: onDelete,
                        ),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 20),
          Panel(
            title: 'Status checks',
            subtitle: 'How often LabDesk asks the ID server which machines are registered.',
            child: _PollInterval(
              seconds: pollSeconds,
              onChanged: onPollSecondsChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoProfiles extends StatelessWidget {
  const _NoProfiles();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 42, horizontal: 24),
        child: Column(
          children: [
            Text('No profiles yet', style: C.of(context).h2()),
            const SizedBox(height: 6),
            SizedBox(
              width: 380,
              child: Text(
                'A profile stores one server set. Add one for each network you '
                'reach machines on, then switch between them without retyping '
                'anything.',
                textAlign: TextAlign.center,
                style: C.of(context).small(color: C.of(context).textFaint),
              ),
            ),
          ],
        ),
      );
}

class _ProfileTile extends StatefulWidget {
  const _ProfileTile({
    required this.profile,
    required this.onActivate,
    required this.onEdit,
    required this.onDelete,
  });

  final ProfileRow profile;
  final ValueChanged<ProfileRow>? onActivate;
  final ValueChanged<ProfileRow>? onEdit;
  final ValueChanged<ProfileRow>? onDelete;

  @override
  State<_ProfileTile> createState() => _ProfileTileState();
}

class _ProfileTileState extends State<_ProfileTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: p.active ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: p.active ? null : () => widget.onActivate?.call(p),
        child: AnimatedContainer(
          duration: C.fast,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          color: p.active
              ? C.of(context).accent.withOpacity(0.08)
              : (_hover ? C.of(context).surfaceHi : Colors.transparent),
          child: Row(
            children: [
              // One profile is in force at a time, so the mark is the console's
              // radio mark and not a tick: a tick says "done", and what this
              // says is "this is the one".
              SizedBox(
                width: 24,
                child: LdRadioMark(selected: p.active),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(p.name, style: C.of(context).body()),
                        if (p.active) ...[
                          const SizedBox(width: 9),
                          Text('Active', style: C.of(context).micro(color: C.of(context).accent)),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      // The host is the operator's own infrastructure. It is
                      // shown because they need to recognise the profile, and
                      // never logged or sent anywhere.
                      p.host.isEmpty ? 'No custom server set' : p.host,
                      style: C.of(context).data(size: 11.5, color: C.of(context).textFaint),
                    ),
                  ],
                ),
              ),
              if (p.hasKey)
                Tooltip(
                  message: 'A server key is set for this profile',
                  child: LdIcon(LdIcons.key, size: 15, color: C.of(context).textFaint),
                ),
              const SizedBox(width: 14),
              AnimatedOpacity(
                duration: C.fast,
                opacity: _hover ? 1 : 0,
                child: Row(
                  children: [
                    LdButton(
                      label: 'Edit',
                      onPressed: _hover ? () => widget.onEdit?.call(p) : null,
                    ),
                    const SizedBox(width: 8),
                    // Deleting a profile takes a set of servers away with it,
                    // which is why this one is the page's only red control.
                    LdButton(
                      label: 'Delete',
                      kind: LdButtonKind.danger,
                      onPressed: _hover && !p.active ? () => widget.onDelete?.call(p) : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PollInterval extends StatelessWidget {
  const _PollInterval({required this.seconds, required this.onChanged});

  final int seconds;
  final ValueChanged<int>? onChanged;

  static const _options = [10, 30, 60, 300];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (final s in _options) ...[
              _Choice(
                label: s < 60 ? '${s}s' : '${s ~/ 60}m',
                selected: s == seconds,
                onTap: onChanged == null ? null : () => onChanged!(s),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Checking more often finds machines sooner and asks more of the ID '
          'server. Nothing is stored between runs, so a longer interval only '
          'means a coarser picture while LabDesk is open.',
          style: C.of(context).small(color: C.of(context).textFaint),
        ),
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: C.fast,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? C.of(context).accent.withOpacity(0.16) : Colors.transparent,
            borderRadius: C.roundedSm,
            border: Border.all(color: selected ? C.of(context).accent.withOpacity(0.45) : C.of(context).hairline),
          ),
          child: Text(
            label,
            style: C.of(context).small(
              color: selected ? C.of(context).text : C.of(context).textMuted,
              w: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
