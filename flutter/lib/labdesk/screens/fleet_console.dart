import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../common/formatter/id_formatter.dart';
import '../../common/labdesk_peer_status.dart';
import '../models/machine_row.dart';
import '../charts/reachability_chart.dart';
import '../theme/console_theme.dart';
import '../theme/ld_icons.dart';

/// The fleet console.
///
/// An Operate surface: sidebar plus content plane, a summary the operator reads
/// in one glance, and a dense list they scan. Familiar on purpose. The
/// character is in the details, not in the structure.
class FleetConsole extends StatelessWidget {
  const FleetConsole({
    super.key,
    required this.machines,
    this.profileName = 'Default',
    this.isRefreshing = false,
    this.isLoading = false,
    this.lastRefreshed,
    this.onRefresh,
    this.selectedId,
    this.onSelect,
    this.now,
    this.samples = const [],
    this.embedded = false,
  });

  /// When embedded the shell already draws the sidebar and the title bar, so
  /// this renders only the content plane.

  final bool embedded;
  final List<MachineRow> machines;
  final List<ReachSample> samples;
  final String profileName;
  final bool isRefreshing;

  /// First load, before anything is known. Shows skeletons rather than a
  /// spinner floating in an empty plane.
  final bool isLoading;

  final DateTime? lastRefreshed;
  final VoidCallback? onRefresh;
  final String? selectedId;
  final ValueChanged<String>? onSelect;

  /// Injected so rendering is deterministic under test and in screenshots.
  final DateTime? now;

  int _count(LabDeskPeerStatus s) => machines.where((m) => m.status == s).length;

  @override
  Widget build(BuildContext context) {
    final content = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Summary(
            online: _count(LabDeskPeerStatus.online),
            offline: _count(LabDeskPeerStatus.offline),
            unknown: _count(LabDeskPeerStatus.unknown),
            isLoading: isLoading,
            samples: samples,
          ),
          const SizedBox(height: 20),
          _MachineList(
            machines: machines,
            isLoading: isLoading,
            selectedId: selectedId,
            onSelect: onSelect,
            now: now,
          ),
        ],
      ),
    );

    if (embedded) return content;

    return ColoredBox(
      color: C.of(context).bg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Sidebar(profileName: profileName),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(
                  isRefreshing: isRefreshing,
                  lastRefreshed: lastRefreshed,
                  onRefresh: onRefresh,
                  now: now,
                ),
                Expanded(child: content),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.profileName});

  final String profileName;

  static const _nav = <(String, String, bool)>[
    (LdIcons.fleet, 'Fleet', true),
    (LdIcons.health, 'Health', false),
    (LdIcons.terminal, 'Terminal', false),
    (LdIcons.actions, 'Actions', false),
    (LdIcons.settings, 'Settings', false),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 216,
      color: C.of(context).chrome,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [C.of(context).accent, C.of(context).accentDim],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: C.roundedSm,
                  ),
                ),
                const SizedBox(width: 10),
                Text('LabDesk', style: C.of(context).h1()),
              ],
            ),
          ),
          for (final (icon, label, active) in _nav)
            _NavItem(icon: icon, label: label, active: active),
          const Spacer(),
          Divider(height: 1, thickness: 1, color: C.of(context).hairline),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Server profile', style: C.of(context).micro()),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        profileName,
                        overflow: TextOverflow.ellipsis,
                        style: C.of(context).body(),
                      ),
                    ),
                    LdIcon(LdIcons.chevronDown, size: 14, color: C.of(context).textFaint),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({required this.icon, required this.label, required this.active});

  final String icon;
  final String label;
  final bool active;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.active ? C.of(context).text : (_hover ? C.of(context).text : C.of(context).textMuted);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: C.fast,
          height: 34,
          padding: const EdgeInsets.only(right: 10),
          decoration: BoxDecoration(
            color: widget.active
                ? C.of(context).accent.withOpacity(0.14)
                : (_hover ? C.of(context).surfaceHi : Colors.transparent),
            borderRadius: C.roundedSm,
          ),
          child: Row(
            children: [
              // Fill plus a leading accent bar: the one way this product says
              // "this is the current thing", shared with the selected row.
              Container(
                width: _leadBar,
                height: 18,
                decoration: BoxDecoration(
                  color: widget.active ? C.of(context).accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              const SizedBox(width: 8),
              LdIcon(widget.icon, size: 16, color: widget.active ? C.of(context).accent : fg),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: C.of(context).small(
                  color: fg,
                  w: widget.active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.isRefreshing,
    required this.lastRefreshed,
    required this.onRefresh,
    this.now,
  });

  final bool isRefreshing;
  final DateTime? lastRefreshed;
  final VoidCallback? onRefresh;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: C.of(context).bg,
        border: Border(bottom: BorderSide(color: C.of(context).hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Text('Fleet', style: C.of(context).h1()),
          const Spacer(),
          Text(_stamp(lastRefreshed, now), style: C.of(context).small(color: C.of(context).textFaint)),
          const SizedBox(width: 12),
          GhostButton(
            label: 'Refresh',
            glyph: LdIcons.refresh,
            busy: isRefreshing,
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }

  static String _stamp(DateTime? at, DateTime? now) {
    if (at == null) return 'Not checked yet';
    final s = (now ?? DateTime.now()).difference(at).inSeconds;
    if (s < 10) return 'Checked just now';
    if (s < 60) return 'Checked ${s}s ago';
    if (s < 3600) return 'Checked ${s ~/ 60}m ago';
    return 'Checked ${s ~/ 3600}h ago';
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.online,
    required this.offline,
    required this.unknown,
    required this.isLoading,
    required this.samples,
  });

  final int online;
  final int offline;
  final int unknown;
  final bool isLoading;
  final List<ReachSample> samples;

  @override
  Widget build(BuildContext context) {
    // Nothing has answered a check yet. Online and offline are not zero, they
    // are unmeasured, and printing "0" beside Online would claim a reading
    // that was never taken.
    final measured = online + offline > 0;
    final note = !measured
        ? 'No machine has answered a check yet, so online and offline are not '
            'known. They are not zero.'
        : unknown > 0
            ? 'Unknown means LabDesk has had no answer for that machine yet. It '
                'is not a report that the machine is down.'
            : null;

    return Panel(
      title: 'Reachability',
      subtitle: 'Whether each machine is registered with the ID server. This is not a health check.',
      child: isLoading
          ? const _SummarySkeleton()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // One band: three counts sharing a rule, over a single bar of
                // the same three quantities in the same left-to-right order,
                // so the counts are the bar's labels rather than a separate
                // widget parked beside it.
                Row(
                  children: [
                    _Metric(
                      label: 'Online',
                      value: measured ? '$online' : '--',
                      color: C.of(context).ok,
                    ),
                    const _BandRule(),
                    _Metric(
                      label: 'Offline',
                      value: measured ? '$offline' : '--',
                      color: C.of(context).bad,
                    ),
                    const _BandRule(),
                    _Metric(
                      label: 'Unknown',
                      value: '$unknown',
                      color: C.of(context).idle,
                      hollow: true,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FleetMixBar(online: online, offline: offline, unknown: unknown),
                if (note != null) ...[
                  const SizedBox(height: 12),
                  Text(note, style: C.of(context).small(color: C.of(context).textFaint)),
                ],
                const SizedBox(height: 18),
                Divider(height: 1, thickness: 1, color: C.of(context).hairline),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text('Online this session', style: C.of(context).micro()),
                    const Spacer(),
                    if (samples.length >= 2)
                      Text(
                        '0 to ${samples.map((s) => s.total).reduce(math.max)} machines',
                        style: C.of(context).micro(),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                ReachabilityChart(samples: samples),
              ],
            ),
    );
  }
}

/// One count in the status band.
///
/// Flexed rather than sized to its content: three cells of equal width read as
/// a band, where three content-sized cells read as a column with the rest of
/// the card left over.
class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.color,
    this.hollow = false,
  });

  final String label;

  /// Already formatted, because an unmeasured count is a dash and not a number.
  final String value;
  final Color color;

  /// Unknown carries a ring rather than a filled dot, so it stays separable
  /// from offline for an operator who cannot tell the two hues apart.
  final bool hollow;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _Dot(color: color, hollow: hollow),
              const SizedBox(width: 8),
              Text(label, style: C.of(context).small()),
            ],
          ),
          const SizedBox(height: 8),
          Text(value, style: C.of(context).metric()),
        ],
      ),
    );
  }
}

/// The rule between two cells of the band.
class _BandRule extends StatelessWidget {
  const _BandRule();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 44,
        margin: const EdgeInsets.only(right: 22, left: 2),
        color: C.of(context).hairline,
      );
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, this.hollow = false});

  final Color color;
  final bool hollow;

  @override
  Widget build(BuildContext context) => Container(
        width: hollow ? 8 : 7,
        height: hollow ? 8 : 7,
        decoration: BoxDecoration(
          color: hollow ? null : color,
          border: hollow ? Border.all(color: color, width: 1.5) : null,
          shape: BoxShape.circle,
        ),
      );
}

class _MachineList extends StatelessWidget {
  const _MachineList({
    required this.machines,
    required this.isLoading,
    required this.selectedId,
    required this.onSelect,
    this.now,
  });

  final List<MachineRow> machines;
  final bool isLoading;
  final String? selectedId;
  final ValueChanged<String>? onSelect;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'Machines',
      subtitle: isLoading ? null : '${machines.length} tracked',
      padding: EdgeInsets.zero,
      actions: isLoading || machines.isEmpty ? null : const [AvailabilityLegend()],
      child: isLoading
          ? const _ListSkeleton()
          : machines.isEmpty
              ? const _EmptyState()
              : ClipRRect(
                  // A selected last row is filled to its corners, and the panel
                  // draws its radius without clipping its child.
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(C.radius - 1),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _ListHeader(),
                      for (var i = 0; i < machines.length; i++)
                        _MachineTile(
                          machine: machines[i],
                          selected: machines[i].id == selectedId,
                          last: i == machines.length - 1,
                          onTap: onSelect == null
                              ? null
                              : () => onSelect!(machines[i].id),
                          now: now,
                        ),
                    ],
                  ),
                ),
    );
  }
}

const _wStatus = 30.0;
const _wPlatform = 92.0;
const _wGroup = 118.0;
const _wSeen = 84.0;

/// The accent bar that marks the current row and the current nav item. Two
/// pixels, drawn down the leading edge, the same everywhere.
const _leadBar = 2.0;

/// Row height, matched to the table on Connect and to the file manager.
///
/// 52 plus a rule before, which is 53 and reads as a different table beside
/// them. 44 holds the same two lines - the name at body size over the id in
/// mono - by tightening the leading, not the type, and carries its own rule
/// inside the height the way the other tables do.
const _rowH = 44.0;

/// Content inset. The bar is drawn as the row's left border, so the padding is
/// short by its width and the text still lands 18 from the panel edge.
const _padH = 18.0;

/// Wide enough to hold the strip and the word above it on the same left edge,
/// with a gutter before the right-aligned last column.
const _wTrend = 100.0;
const _wStrip = 88.0;

class _ListHeader extends StatelessWidget {
  const _ListHeader();

  @override
  Widget build(BuildContext context) {
    // Uppercase and letterspaced, the way Connect, the file manager and the
    // connection manager all label their columns. A column head is a label,
    // not a sentence, and this product had already decided how a label looks.
    Widget h(String s, {double? w, bool right = false}) {
      final t = Text(s,
          textAlign: right ? TextAlign.right : TextAlign.left,
          style: C.of(context).micro().copyWith(letterSpacing: 0.7));
      return w == null ? Expanded(child: t) : SizedBox(width: w, child: t);
    }

    return Container(
      height: 28,
      padding: const EdgeInsets.fromLTRB(_padH + _leadBar, 0, _padH, 0),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: C.of(context).hairline)),
      ),
      child: Row(
        children: [
          const SizedBox(width: _wStatus),
          h('MACHINE'),
          h('PLATFORM', w: _wPlatform),
          h('GROUP', w: _wGroup),
          h('RECENT', w: _wTrend),
          h('LAST SEEN', w: _wSeen, right: true),
        ],
      ),
    );
  }
}

class _MachineTile extends StatefulWidget {
  const _MachineTile({
    required this.machine,
    required this.selected,
    required this.last,
    required this.onTap,
    this.now,
  });

  final MachineRow machine;
  final bool selected;

  /// The last row drops its rule, so the panel's rounded bottom edge is not
  /// cut by a hairline running to both corners.
  final bool last;
  final VoidCallback? onTap;
  final DateTime? now;

  @override
  State<_MachineTile> createState() => _MachineTileState();
}

class _MachineTileState extends State<_MachineTile> {
  bool _hover = false;

  Color get _statusColor => switch (widget.machine.status) {
        LabDeskPeerStatus.online => C.of(context).ok,
        LabDeskPeerStatus.offline => C.of(context).bad,
        LabDeskPeerStatus.unknown => C.of(context).idle,
      };

  /// One triplet for these three states, everywhere on this screen and in the
  /// rest of the product: Online, Offline, Unknown.
  String get _statusWord => switch (widget.machine.status) {
        LabDeskPeerStatus.online => 'Online',
        LabDeskPeerStatus.offline => 'Offline',
        LabDeskPeerStatus.unknown => 'Unknown',
      };

  @override
  Widget build(BuildContext context) {
    final m = widget.machine;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: C.fast,
          height: _rowH,
          padding: const EdgeInsets.fromLTRB(_padH, 0, _padH, 0),
          decoration: BoxDecoration(
            color: widget.selected
                ? C.of(context).accent.withOpacity(0.13)
                : (_hover ? C.of(context).surfaceHi : Colors.transparent),
            border: Border(
              // Down the leading edge, not under the row: a rule beneath a
              // selected row reads as belonging to the row above it.
              left: BorderSide(
                color: widget.selected ? C.of(context).accent : Colors.transparent,
                width: _leadBar,
              ),
              bottom: BorderSide(
                color: widget.last ? Colors.transparent : C.of(context).hairline,
              ),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: _wStatus,
                child: Tooltip(
                  message: _statusWord,
                  child: _Dot(
                    color: _statusColor,
                    hollow: m.status == LabDeskPeerStatus.unknown,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Leading tightened to hold two lines in the shorter row.
                    // The type sizes are untouched: this is leading, not the
                    // identity getting smaller.
                    Text(
                      m.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: C.of(context).body().copyWith(height: 1.2),
                    ),
                    // One id formatter for the product. Connect and the consent
                    // prompt both print grouped triplets; a raw ten-digit run
                    // here made the same number look like a different field.
                    Text(formatID(m.id),
                        style: C.of(context).data(size: 11, color: C.of(context).textFaint)
                            .copyWith(height: 1.25)),
                  ],
                ),
              ),
              SizedBox(
                width: _wPlatform,
                child: Text(m.platform, style: C.of(context).small(color: C.of(context).textMuted)),
              ),
              SizedBox(
                width: _wGroup,
                child: Text(
                  m.group ?? 'Ungrouped',
                  overflow: TextOverflow.ellipsis,
                  style: C.of(context).small(
                    color: m.group == null ? C.of(context).textFaint : C.of(context).textMuted,
                  ),
                ),
              ),
              SizedBox(
                width: _wTrend,
                child: m.history.isEmpty
                    ? Text('--', style: C.of(context).small(color: C.of(context).textFaint))
                    : Tooltip(
                        message: 'Last ${m.history.length} checks, oldest first',
                        child: AvailabilityStrip(
                          history: m.history,
                          width: _wStrip,
                        ),
                      ),
              ),
              SizedBox(
                width: _wSeen,
                child: Text(
                  m.status == LabDeskPeerStatus.online
                      ? 'Now'
                      : m.sinceSeen(now: widget.now),
                  textAlign: TextAlign.right,
                  style: C.of(context).data(
                    size: 12,
                    color: m.status == LabDeskPeerStatus.online ? C.of(context).ok : C.of(context).textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Teaches the interface rather than announcing emptiness.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 54, horizontal: 24),
      child: Column(
        children: [
          LdIcon(LdIcons.fleet, size: 26, color: C.of(context).textFaint),
          const SizedBox(height: 14),
          Text('No machines yet', style: C.of(context).h2()),
          const SizedBox(height: 6),
          SizedBox(
            width: 340,
            child: Text(
              'Machines appear here once you connect to them, or when a server '
              'profile with an address book is selected.',
              textAlign: TextAlign.center,
              style: C.of(context).small(color: C.of(context).textFaint),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummarySkeleton extends StatelessWidget {
  const _SummarySkeleton();

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const _BandRule(),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Shimmer(width: 58, height: 10),
                      SizedBox(height: 10),
                      _Shimmer(width: 38, height: 24),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          const _Shimmer(width: double.infinity, height: 8),
        ],
      );
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (var i = 0; i < 5; i++)
            Container(
              height: _rowH,
              padding: const EdgeInsets.symmetric(horizontal: _padH),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: C.of(context).hairline)),
              ),
              child: const Row(
                children: [
                  _Shimmer(width: 7, height: 7, circle: true),
                  SizedBox(width: 23),
                  _Shimmer(width: 150, height: 11),
                  Spacer(),
                  _Shimmer(width: 60, height: 10),
                ],
              ),
            ),
        ],
      );
}

/// Loading placeholders shaped like the content they replace, rather than a
/// spinner in the middle of an empty panel.
class _Shimmer extends StatefulWidget {
  const _Shimmer({
    required this.width,
    required this.height,
    this.circle = false,
  });

  final double width;
  final double height;
  final bool circle;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Color.lerp(C.of(context).surfaceHi, C.of(context).hairline, _c.value),
          borderRadius: widget.circle ? null : BorderRadius.circular(3),
          shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
        ),
      ),
    );
  }
}
