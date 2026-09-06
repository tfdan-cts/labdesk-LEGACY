import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/formatter/id_formatter.dart';
import '../../common/labdesk_peer_status.dart';
import '../models/machine_row.dart';
import '../theme/console_theme.dart';
import '../theme/ld_icons.dart';
import 'console_menu.dart';

/// The section the console opens on: enter an id and connect, or find the
/// machine in the list and connect to that.
///
/// It replaces the peer page the application was derived from, whose tab strip,
/// peer cards and search row were that product's interface wholesale. What that
/// page did is kept - the same id formatting, the same four connect modes, the
/// same peer sets - but said in this console's language: one dense table,
/// grouped the way the operator grouped their machines, with the peer sets as
/// filters over one list rather than as five lists that each look different.
///
/// Like every other screen under `lib/labdesk`, this holds no FFI. The client
/// passes machines, groups and peer sets in and takes callbacks back, which is
/// what lets the whole screen be tested and screenshotted with no peer, no Rust
/// core and no generated bridge.

/// Every way the application can open a session, and the only ways the peer
/// page offered.
///
/// The first four are offered for any machine. The last three were gated on the
/// peer's platform and on this machine's, and still are - see
/// [_ConnectScreenState._modesFor].
enum ConnectMode {
  control,
  fileTransfer,
  viewCamera,
  terminal,
  terminalAdmin,
  rdp,
  tcpTunneling,
}

extension ConnectModeLabel on ConnectMode {
  String get label => switch (this) {
        ConnectMode.control => 'Connect',
        ConnectMode.fileTransfer => 'Transfer files',
        ConnectMode.viewCamera => 'View camera',
        // The application ships these as beta and says so. Dropping the word
        // here would promise more than the feature does.
        ConnectMode.terminal => 'Terminal (beta)',
        ConnectMode.terminalAdmin => 'Terminal as administrator (beta)',
        ConnectMode.rdp => 'RDP',
        ConnectMode.tcpTunneling => 'Port forwarding (TCP)',
      };

  String get glyph => switch (this) {
        ConnectMode.control => LdIcons.connect,
        ConnectMode.fileTransfer => LdIcons.fileTransfer,
        ConnectMode.viewCamera => LdIcons.camera,
        ConnectMode.terminal => LdIcons.terminal,
        ConnectMode.terminalAdmin => LdIcons.shield,
        ConnectMode.rdp => LdIcons.windows,
        ConnectMode.tcpTunneling => LdIcons.portForward,
      };
}

/// Everything else the peer cards offered per machine, gathered off the five
/// cards that each carried a slightly different subset of it.
///
/// These are reported to the client rather than performed here: the screen
/// holds no FFI, and every one of them ends in a bridge call, a dialog the
/// application already owns, or both.
enum RowAction {
  rename,
  alwaysRelay,
  rdpSettings,
  chooseIcon,
  assignGroups,
  wakeOnLan,
  desktopShortcut,
  copyId,
  addToFavourites,
  removeFromFavourites,
  addToAddressBook,
  editTags,
  editNote,
  sharedPassword,
  existIn,
  forgetPassword,
  removeFromAddressBook,
  forgetMachine,
}

extension RowActionLabel on RowAction {
  String get label => switch (this) {
        RowAction.rename => 'Rename',
        RowAction.alwaysRelay => 'Always connect via relay',
        // The port, username and password an RDP session uses. The peer card
        // put these behind a pencil inside its own RDP entry, where nothing
        // said what the pencil edited.
        RowAction.rdpSettings => 'RDP settings',
        RowAction.chooseIcon => 'Choose icon',
        RowAction.assignGroups => 'Groups',
        // Spelled out. "WOL" is an abbreviation the operator has to already
        // know, and this menu is the one place they would go to find out.
        RowAction.wakeOnLan => 'Wake on LAN',
        RowAction.desktopShortcut => 'Create desktop shortcut',
        RowAction.copyId => 'Copy id',
        RowAction.addToFavourites => 'Add to favourites',
        RowAction.removeFromFavourites => 'Remove from favourites',
        RowAction.addToAddressBook => 'Add to address book',
        RowAction.editTags => 'Edit tags',
        RowAction.editNote => 'Edit note',
        RowAction.sharedPassword => 'Shared password',
        RowAction.existIn => 'Also in',
        RowAction.forgetPassword => 'Forget saved password',
        RowAction.removeFromAddressBook => 'Remove from address book',
        RowAction.forgetMachine => 'Forget machine',
      };

  /// The same action said about several machines at once. Only the wording
  /// changes: "Forget machine" against nine of them is the wrong sentence.
  String get bulkLabel => switch (this) {
        RowAction.forgetMachine => 'Forget machines',
        _ => label,
      };

  /// Irreversible, or throws away something the operator typed in. Drawn apart
  /// from the rest of the menu.
  bool get isDestructive => switch (this) {
        RowAction.forgetPassword ||
        RowAction.removeFromAddressBook ||
        RowAction.forgetMachine =>
          true,
        _ => false,
      };

  /// The shape beside the line. Membership actions share the glyph of the set
  /// they add to or remove from, so the pair reads as one thing done and undone.
  String get glyph => switch (this) {
        RowAction.rename => LdIcons.rename,
        RowAction.alwaysRelay => LdIcons.switchSides,
        RowAction.rdpSettings => LdIcons.settings,
        RowAction.chooseIcon => LdIcons.machine,
        RowAction.assignGroups => LdIcons.group,
        RowAction.wakeOnLan => LdIcons.power,
        RowAction.desktopShortcut => LdIcons.display,
        RowAction.copyId => LdIcons.clipboard,
        RowAction.addToFavourites ||
        RowAction.removeFromFavourites =>
          LdIcons.favourite,
        RowAction.addToAddressBook ||
        RowAction.removeFromAddressBook =>
          LdIcons.addressBook,
        RowAction.editTags => LdIcons.pin,
        RowAction.editNote => LdIcons.file,
        RowAction.sharedPassword => LdIcons.key,
        RowAction.existIn => LdIcons.info,
        RowAction.forgetPassword => LdIcons.lock,
        RowAction.forgetMachine => LdIcons.trash,
      };
}

// The peer sets the old tab strip exposed, by id. Named rather than spelled
// out at each use because the menu's conditions are written in terms of them:
// what a peer card offered depended on which tab it was drawn on, and in one
// merged table the tab a machine would have been on is the set it is in.
const kSetRecent = 'recent';
const kSetFavourite = 'favourite';
const kSetAddressBook = 'addressBook';
const kSetDiscovered = 'discovered';

/// What the client can offer right now.
///
/// The peer cards read all of this off the bridge as they built each menu.
/// This screen cannot, so the client passes it in - and where a fact is
/// missing the action it gates is simply not offered, which is the same answer
/// the old menu gave.
class ConnectCapabilities {
  const ConnectCapabilities({
    this.hostIsWindows = false,
    this.canAddToAddressBook = false,
    this.addressBookWritable = false,
    this.addressBookIsPersonal = true,
    this.addressBookHasTags = false,
    this.savedPasswords = const {},
    this.alwaysRelay = const {},
  });

  /// This machine, not the far one: RDP and the desktop shortcut are both
  /// things only a Windows host can do.
  final bool hostIsWindows;

  /// There is an account, and an address book that can be written to.
  final bool canAddToAddressBook;

  final bool addressBookWritable;

  /// A shared address book keeps one password per machine for the whole team,
  /// which is a different action from forgetting the one saved here.
  final bool addressBookIsPersonal;

  final bool addressBookHasTags;

  /// Machines this client has a password saved for.
  final Set<String> savedPasswords;

  /// Machines pinned to the relay.
  final Set<String> alwaysRelay;
}

/// One of the operator's configured groups, flattened out of the client's group
/// model so this screen does not import it.
typedef ConnectGroup = ({String name, bool collapsed});

/// A named set of peers, as the old tab strip exposed them.
///
/// [ids] null with an [unavailable] reason means the client cannot source this
/// set in this build. The chip is then rendered disabled carrying that reason,
/// which is the honest form: a set that cannot be listed must not be offered as
/// a filter that quietly returns nothing.
class PeerSetChip {
  const PeerSetChip({
    required this.id,
    required this.label,
    this.icon,
    this.ids,
    this.unavailable,
  });

  final String id;
  final String label;
  final String? icon;
  final Set<String>? ids;
  final String? unavailable;

  bool get enabled => ids != null;
}

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({
    super.key,
    required this.machines,
    this.groups = const [],
    this.sets = const [],
    this.initialId = '',
    this.capabilities = const ConnectCapabilities(),
    this.onConnect,
    this.onAction,
    this.onGroupCollapsed,
    this.onPeerSetSelected,
    this.now,
    this.isLoading = false,
  });

  /// Built by `buildMachineRows`, the same list the Fleet screen reads. One
  /// source of truth for what a machine is and what is known about it.
  final List<MachineRow> machines;

  final List<ConnectGroup> groups;
  final List<PeerSetChip> sets;

  /// The last machine connected to, so the field opens where the operator left
  /// it, exactly as the page this replaces did.
  final String initialId;

  /// What the client can act on, so the row menu never lists an action that
  /// would fail.
  final ConnectCapabilities capabilities;

  final void Function(String id, ConnectMode mode)? onConnect;

  /// Everything in the row menu that is not opening a session.
  final void Function(String id, RowAction action)? onAction;

  /// Reported so the client can persist it; the screen collapses either way.
  final void Function(String group, bool collapsed)? onGroupCollapsed;

  /// Told when a peer set is selected, so the client can go and fetch it. LAN
  /// discovery in particular is a broadcast, and doing it unasked on every open
  /// is not this screen's call to make.
  final void Function(String? setId)? onPeerSetSelected;

  /// Injected so rendering is deterministic under test and in screenshots.
  final DateTime? now;

  /// Nothing has been read yet. An empty list while still reading is not an
  /// empty fleet, and saying "no machines yet" then would be a claim the screen
  /// cannot support.
  final bool isLoading;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final _id = IDTextEditingController(text: formatID(widget.initialId));
  final _search = TextEditingController();

  /// Only the groups the operator has toggled in this session. Everything else
  /// falls back to the stored state, so a group collapsed in settings opens
  /// collapsed.
  final _collapsed = <String, bool>{};

  String _query = '';
  String? _set;

  /// The machines the operator has ticked. The peer page kept this on its own
  /// model and dropped it when the table replaced the cards; a fleet of two
  /// hundred needs it back.
  final _selected = <String>{};

  /// The last row ticked on its own, which is the far end a shift-click ranges
  /// from. Null after a clear or after the row it named stops being visible.
  String? _anchor;

  /// Every visible row in the order it is drawn, so a range means the rows
  /// between two ticks on screen and not the rows between two ids.
  var _order = const <String>[];

  @override
  void dispose() {
    _id.dispose();
    _search.dispose();
    super.dispose();
  }

  void _connect(String id, ConnectMode mode) {
    if (id.isEmpty) return;
    // The field tracks the machine last connected to, which is the behaviour
    // the peer page had through the client's own connect().
    _id.id = id;
    widget.onConnect?.call(id, mode);
  }

  bool _isCollapsed(ConnectGroup g) => _collapsed[g.name] ?? g.collapsed;

  void _toggleGroup(ConnectGroup g) {
    final next = !_isCollapsed(g);
    setState(() => _collapsed[g.name] = next);
    widget.onGroupCollapsed?.call(g.name, next);
  }

  PeerSetChip? get _activeSet {
    for (final s in widget.sets) {
      if (s.id == _set && s.enabled) return s;
    }
    return null;
  }

  /// Whether the client listed this machine in a named set. A set it could not
  /// source at all answers false rather than throwing the machine out of every
  /// condition that mentions it.
  bool _inSet(String setId, String machineId) {
    for (final s in widget.sets) {
      if (s.id == setId) return s.ids?.contains(machineId) ?? false;
    }
    return false;
  }

  /// The session types this machine can be opened with.
  ///
  /// The last three carry the conditions the peer cards put on them: an
  /// administrator terminal and RDP only exist on Windows, RDP additionally
  /// needs a Windows host to run the client, and tunnelling was never offered
  /// against a handset.
  List<ConnectMode> _modesFor(MachineRow m) {
    final p = m.platform.toLowerCase();
    final windows = p.contains('win');
    return [
      ConnectMode.control,
      ConnectMode.fileTransfer,
      ConnectMode.viewCamera,
      ConnectMode.terminal,
      if (windows) ConnectMode.terminalAdmin,
      if (windows && widget.capabilities.hostIsWindows) ConnectMode.rdp,
      if (!p.contains('android')) ConnectMode.tcpTunneling,
    ];
  }

  /// The non-session actions this machine can be given.
  ///
  /// The old interface answered this question with the tab: a peer card on
  /// Recent had a rename and a delete, the same card on Discovered had a wake
  /// and no rename, and on the address book it had notes and tags instead. One
  /// table has no tabs, so the answer is the union over the sets the machine is
  /// actually in - which is the same answer, for a machine that was only ever
  /// on one tab, and the right one for a machine that was on three.
  Set<RowAction> _actionsFor(MachineRow m) {
    final caps = widget.capabilities;
    final inFav = _inSet(kSetFavourite, m.id);
    // Read off the session list rather than restated, so the settings can
    // never be offered for a machine the session itself is not offered for.
    final rdp = _modesFor(m).contains(ConnectMode.rdp);
    final inAb = _inSet(kSetAddressBook, m.id);
    final inLan = _inSet(kSetDiscovered, m.id);
    // Recent, or in none of the sets: the client hands this screen peers out
    // of its own stores, and one it cannot place is a locally known peer,
    // which is what Recent is.
    final local = _inSet(kSetRecent, m.id) || inFav || !(inAb || inLan);
    final abWrite = inAb && caps.addressBookWritable;

    return {
      // Renaming a machine found by a broadcast has nothing to write to: it
      // has no entry here until it is connected to. The old menu left it off
      // that tab for the same reason.
      if (local || abWrite) RowAction.rename,
      RowAction.alwaysRelay,
      if (rdp) RowAction.rdpSettings,
      RowAction.copyId,
      if (local || inLan) ...[
        RowAction.chooseIcon,
        RowAction.assignGroups,
      ],
      if (inLan) RowAction.wakeOnLan,
      if (caps.hostIsWindows) RowAction.desktopShortcut,
      if (inFav)
        RowAction.removeFromFavourites
      else if (local || inLan)
        RowAction.addToFavourites,
      if (caps.canAddToAddressBook) RowAction.addToAddressBook,
      if (abWrite && caps.addressBookHasTags) RowAction.editTags,
      if (abWrite) RowAction.editNote,
      if (abWrite && !caps.addressBookIsPersonal) RowAction.sharedPassword,
      if (inAb) RowAction.existIn,
      if (caps.savedPasswords.contains(m.id) &&
          (local || (abWrite && caps.addressBookIsPersonal)))
        RowAction.forgetPassword,
      if (abWrite) RowAction.removeFromAddressBook,
      if (local || inLan) RowAction.forgetMachine,
    };
  }

  /// One menu, in one order, grouped so the destructive end is somewhere the
  /// pointer does not arrive by accident.
  List<ConsoleMenuEntry<Object>> _menuFor(MachineRow m) {
    final offered = _actionsFor(m);
    final caps = widget.capabilities;

    List<ConsoleMenuEntry<Object>> run(String heading, List<RowAction> order) {
      final present = order.where(offered.contains).toList();
      if (present.isEmpty) return const [];
      return [
        const ConsoleMenuSplit<Object>(),
        ConsoleMenuHeading<Object>(heading),
        for (final a in present)
          ConsoleMenuAction<Object>(
            a,
            a.label,
            glyph: a.glyph,
            danger: a.isDestructive,
            checked: a == RowAction.alwaysRelay
                ? caps.alwaysRelay.contains(m.id)
                : null,
          ),
      ];
    }

    final destructive = [
      RowAction.forgetPassword,
      RowAction.removeFromAddressBook,
      RowAction.forgetMachine,
    ].where(offered.contains);

    return [
      for (final mode in _modesFor(m)) ...[
        ConsoleMenuAction<Object>(mode, mode.label, glyph: mode.glyph),
        // Directly under the session it configures. Anywhere else and the
        // operator has to know that "RDP settings" belongs to the RDP line.
        if (mode == ConnectMode.rdp && offered.contains(RowAction.rdpSettings))
          ConsoleMenuAction<Object>(
              RowAction.rdpSettings, RowAction.rdpSettings.label,
              glyph: RowAction.rdpSettings.glyph),
      ],
      ...run('This machine', const [
        RowAction.rename,
        RowAction.chooseIcon,
        RowAction.alwaysRelay,
        RowAction.wakeOnLan,
        RowAction.desktopShortcut,
        RowAction.copyId,
      ]),
      ...run('Membership', const [
        RowAction.assignGroups,
        RowAction.addToFavourites,
        RowAction.removeFromFavourites,
        RowAction.addToAddressBook,
        RowAction.editTags,
        RowAction.editNote,
        RowAction.sharedPassword,
        RowAction.existIn,
      ]),
      // No heading over the last run. The colour says what it is, and a word
      // like "Danger" over three lines that are already red is decoration.
      if (destructive.isNotEmpty) ...[
        const ConsoleMenuSplit<Object>(),
        for (final a in destructive)
          ConsoleMenuAction<Object>(a, a.label, glyph: a.glyph, danger: true),
      ],
    ];
  }

  bool _matches(MachineRow m) {
    final set = _activeSet;
    if (set != null && !set.ids!.contains(m.id)) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    // The id is matched with its spaces stripped, so "914 203" and "914203"
    // both find the same machine.
    final flat = q.replaceAll(' ', '');
    return m.displayName.toLowerCase().contains(q) ||
        m.hostname.toLowerCase().contains(q) ||
        (m.username ?? '').toLowerCase().contains(q) ||
        m.id.contains(flat);
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.machines.where(_matches).toList();
    final picked = _picked();
    // A search reads across the whole fleet, so the headings would fragment two
    // or three results into two or three sections. It flattens instead, and
    // each row carries its group so nothing is lost by flattening.
    final flat = _query.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _IdBar(
          controller: _id,
          onConnect: (mode) => _connect(_id.id, mode),
        ),
        Divider(height: 1, thickness: 1, color: C.of(context).hairline),
        // One bar, two jobs. A selection bar stacked under the filter row
        // would push the table down the moment a row is ticked and shorten
        // the list exactly when the operator is working through it.
        if (picked.isNotEmpty)
          _SelectionBar(
            count: picked.length,
            visible: visible.length,
            offered: _bulkOffered(picked),
            onAll: () => setState(() => _selected.addAll(_order)),
            onClear: _clearSelection,
            onAction: _bulk,
          )
        else
          _FilterBar(
            search: _search,
            onQuery: (q) => setState(() => _query = q),
            sets: widget.sets,
            selectedSet: _set,
            onSet: (id) {
              setState(() => _set = _set == id ? null : id);
              widget.onPeerSetSelected?.call(_set);
            },
            shown: visible.length,
            total: widget.machines.length,
          ),
        Expanded(child: _body(visible, flat)),
      ],
    );
  }

  Widget _body(List<MachineRow> visible, bool flat) {
    if (widget.machines.isEmpty) {
      return widget.isLoading ? const _Loading() : const _EmptyFleet();
    }
    if (visible.isEmpty) {
      return _EmptyResults(
        query: _query.trim(),
        set: _activeSet?.label,
        onClear: () {
          _search.clear();
          setState(() {
            _query = '';
            _set = null;
          });
        },
      );
    }

    // Distinct from an empty fleet and from an empty search: there are
    // machines, and nothing is wrong with them - nobody has asked yet.
    final unchecked =
        visible.every((m) => m.status == LabDeskPeerStatus.unknown);

    // Filled as the rows are built, so a shift-click ranges over the rows as
    // they are actually drawn - collapsed groups closed, sections in the
    // operator's order - rather than over the unsorted list behind them.
    final order = <String>[];
    final children = flat
        ? [for (final m in visible) _row(m, showGroup: true, order: order)]
        : _sections(visible, order);
    _order = order;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (unchecked) const _UncheckedNote(),
        _TableHeader(showGroup: flat),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _row(MachineRow m,
      {required bool showGroup, required List<String> order}) {
    order.add(m.id);
    return _MachineTile(
      key: ValueKey('row-${m.id}'),
      machine: m,
      showGroup: showGroup,
      now: widget.now,
      selected: _selected.contains(m.id),
      // The tick box is a hover affordance until there is a selection, and a
      // column once there is: a row that hides its checkbox while three of its
      // neighbours are ticked reads as a row that cannot be ticked.
      selecting: _selected.isNotEmpty,
      onSelect: () => _tick(m.id),
      onConnect: (mode) => _connect(m.id, mode),
      // Built when the menu opens rather than on every row of every frame,
      // and read from the sets as they are at that moment.
      menu: () => _menuFor(m),
      onAction: (a) => _act(m, a),
    );
  }

  /// The two actions the peer cards put behind a confirmation still are, and
  /// nothing else has gained one.
  ///
  /// Forgetting a saved password had no confirmation on the card and has none
  /// here: it is one word of typing to undo, and a prompt on every third menu
  /// item is how operators learn to dismiss prompts.
  Future<void> _act(MachineRow m, RowAction a) async {
    final name = m.displayName;
    final ask = switch (a) {
      RowAction.forgetMachine => (
          title: 'Forget "$name"?',
          body: 'LabDesk drops this machine from its list along with the '
              'alias, group and saved password held for it. The machine '
              'itself is not touched, and connecting to its id again brings '
              'it back as a stranger.',
          confirm: 'Forget machine',
        ),
      RowAction.removeFromAddressBook => (
          title: 'Remove "$name" from the address book?',
          body: 'The entry goes for everyone this address book is shared '
              'with, and the machine leaves any tags it was filed under.',
          confirm: 'Remove',
        ),
      _ => null,
    };

    if (ask != null) {
      final ok = await _confirm(context,
          title: ask.title, body: ask.body, confirmLabel: ask.confirm);
      if (!ok || !mounted) return;
    }
    widget.onAction?.call(m.id, a);
  }

  // ---- selection ---------------------------------------------------------

  /// Ticking a row. Shift ranges from the last row ticked on its own to this
  /// one, taking everything drawn between them, which is what a range means in
  /// every other table an operator uses.
  void _tick(String id) {
    final range = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      final from = _anchor == null ? -1 : _order.indexOf(_anchor!);
      final to = _order.indexOf(id);
      if (range && from >= 0 && to >= 0) {
        _selected
            .addAll(_order.sublist(math.min(from, to), math.max(from, to) + 1));
        return;
      }
      if (!_selected.remove(id)) _selected.add(id);
      // The anchor is where the next range starts, so it follows the tick even
      // when the tick cleared the row.
      _anchor = id;
    });
  }

  void _clearSelection() => setState(() {
        _selected.clear();
        _anchor = null;
      });

  /// The selection as the operator can actually see it.
  ///
  /// A tick is remembered by id, and a machine can leave the table under one -
  /// a refresh drops it, a filter hides it. The count and every bulk action
  /// read through this rather than off the raw set, so the bar can never claim
  /// machines that are not on screen and no action can reach one.
  List<String> _picked() => [
        for (final m in widget.machines)
          if (_matches(m) && _selected.contains(m.id)) m.id
      ];

  /// The bulk bar carries what the peer page's multi-select bar carried, and
  /// nothing else: delete, favourites, address book, tags.
  static const _bulkOrder = [
    RowAction.addToFavourites,
    RowAction.addToAddressBook,
    RowAction.editTags,
    RowAction.forgetMachine,
  ];

  /// What can be done to every machine in the selection.
  ///
  /// The intersection of the per-machine answer, so the gating is the row
  /// menu's gating rather than a second copy of it: an action offered here is
  /// one every ticked machine's own menu would have offered.
  Set<RowAction> _bulkOffered(List<String> picked) {
    Set<RowAction>? all;
    for (final m in widget.machines) {
      if (!picked.contains(m.id)) continue;
      final mine = _actionsFor(m).intersection(_bulkOrder.toSet());
      all = all == null ? mine : all.intersection(mine);
    }
    return all ?? const {};
  }

  /// Runs a bulk action, asking first when it cannot be undone and saying how
  /// many machines the answer covers.
  Future<void> _bulk(RowAction a) async {
    final ids = _picked();
    if (ids.isEmpty) return;
    final n = ids.length;
    final machines = '$n ${n == 1 ? 'machine' : 'machines'}';

    if (a.isDestructive) {
      final ok = await _confirm(
        context,
        title: 'Forget $machines?',
        body: 'LabDesk drops $machines from its list along with the aliases, '
            'groups and saved passwords held for them. The machines '
            'themselves are not touched, and connecting to an id again brings '
            'it back as a stranger.',
        confirmLabel: 'Forget $machines',
      );
      if (!ok || !mounted) return;
    }

    for (final id in ids) {
      widget.onAction?.call(id, a);
    }
    _clearSelection();
  }

  /// The configured groups in the operator's order, then whatever is in none of
  /// them under a plain heading.
  List<Widget> _sections(List<MachineRow> visible, List<String> order) {
    final named = {for (final g in widget.groups) g.name};
    final out = <Widget>[];

    for (final g in widget.groups) {
      final members = visible.where((m) => m.group == g.name).toList();
      final collapsed = _isCollapsed(g);
      out.add(_GroupHeader(
        key: ValueKey('group-${g.name}'),
        name: g.name,
        count: members.length,
        collapsed: collapsed,
        onTap: () => _toggleGroup(g),
      ));
      if (collapsed) continue;
      if (members.isEmpty) {
        out.add(const _GroupEmpty());
      } else {
        out.addAll(
            [for (final m in members) _row(m, showGroup: false, order: order)]);
      }
    }

    final loose = visible
        .where((m) => m.group == null || !named.contains(m.group))
        .toList();
    if (loose.isNotEmpty) {
      const ungrouped = 'Ungrouped';
      final collapsed = _collapsed[ungrouped] ?? false;
      out.add(_GroupHeader(
        key: const ValueKey('group-Ungrouped'),
        name: ungrouped,
        count: loose.length,
        collapsed: collapsed,
        plain: true,
        onTap: () => setState(() => _collapsed[ungrouped] = !collapsed),
      ));
      if (!collapsed) {
        out.addAll(
            [for (final m in loose) _row(m, showGroup: false, order: order)]);
      }
    }
    return out;
  }
}

// Column geometry, shared by the header and every row so the table is a table
// and not a set of rows that happen to look similar.
//
// Every data column is a flex rather than a fixed width. Fixed widths parked
// the whole surplus of a wide window in one place - a dead gutter between the
// last data column and the row's buttons, roughly 150 pixels of nothing on a
// 1440 window - which reads as a broken table the moment there are enough rows
// to see the pattern. Flexed, the surplus is spread across the columns that
// hold something, which is what the tables this is measured against do.
const _fName = 30;
const _fId = 15;
const _fPlatform = 15;
const _fGroup = 15;
const _fStatus = 14;
const _fSeen = 10;

const _padH = 24.0;

/// The tick box gutter. Reserved on the header too, so ticking a row does not
/// shift the columns sideways.
const _wSelect = 28.0;

/// Row height, and the two-line identity it has to hold.
///
/// 54 before, which fits thirteen machines on a 900 tall window. A fleet is
/// not thirteen machines. 44 holds the same two lines - the name at body size
/// over the user and host in mono - and fits sixteen, without dropping the row
/// under the size a pointer can hit: the two controls in it are 26 tall, and
/// the whole row is the hover target.
const _rowH = 44.0;

/// The accent bar that marks the current row, drawn down the leading edge. Two
/// pixels, the same as the fleet table, the file manager and the sidebar: this
/// product says "this is the current thing" one way.
///
/// A row reserves it whether or not it is selected — the border is transparent
/// rather than absent — so nothing in the column shifts as a selection lands,
/// and the row's own left padding is short by exactly the bar so the table
/// still lines up with its header.
const _leadBar = 2.0;

/// The trailing button cluster: Connect, a gap, and the row menu.
const _wActions = 74.0 + 4 + 26;

/// Enter an id and go. The primary action of the product, and the only place on
/// this screen that is not a list.
class _IdBar extends StatelessWidget {
  const _IdBar({required this.controller, required this.onConnect});

  final IDTextEditingController controller;
  final ValueChanged<ConnectMode> onConnect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_padH, 16, _padH, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('MACHINE ID', style: C.of(context).micro().copyWith(letterSpacing: 0.7)),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 268,
                height: 38,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: C.of(context).surface,
                  borderRadius: C.roundedSm,
                  border: Border.all(color: C.of(context).hairline),
                ),
                child: TextField(
                  key: const ValueKey('connect-id-field'),
                  controller: controller,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLines: 1,
                  cursorColor: C.of(context).accent,
                  cursorWidth: 1.5,
                  // An identifier is data, so it is set in the mono face and
                  // spaced in threes the way the client has always spaced it.
                  style: C.of(context).data(size: 16, w: FontWeight.w600),
                  inputFormatters: [IDTextInputFormatter()],
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText: '000 000 000',
                    hintStyle: C.of(context).data(size: 16, color: C.of(context).textFaint),
                  ),
                  onSubmitted: (_) => onConnect(ConnectMode.control),
                ),
              ),
              const SizedBox(width: 8),
              _PrimaryButton(
                key: const ValueKey('connect-id-go'),
                label: 'Connect',
                onPressed: () => onConnect(ConnectMode.control),
              ),
              const SizedBox(width: 6),
              _IdModeMenu(
                menuKey: const ValueKey('connect-id-modes'),
                onSelected: onConnect,
              ),
              const SizedBox(width: 14),
              Flexible(
                child: Text(
                  // Two clipped fragments before, and the first of them said
                  // nothing: "Enter connects" names neither what is connected
                  // nor to what. One sentence, and both halves have a verb.
                  'Press Enter to take control, or use the arrow for file transfer, camera and terminal.',
                  overflow: TextOverflow.ellipsis,
                  style: C.of(context).small(color: C.of(context).textFaint),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.search,
    required this.onQuery,
    required this.sets,
    required this.selectedSet,
    required this.onSet,
    required this.shown,
    required this.total,
  });

  final TextEditingController search;
  final ValueChanged<String> onQuery;
  final List<PeerSetChip> sets;
  final String? selectedSet;
  final ValueChanged<String> onSet;
  final int shown;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: _padH),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: C.of(context).hairline)),
      ),
      child: Row(
        children: [
          Container(
            width: 244,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: C.of(context).surface,
              borderRadius: C.roundedSm,
              border: Border.all(color: C.of(context).hairline),
            ),
            child: Row(
              children: [
                LdIcon(LdIcons.search, size: 14, color: C.of(context).textFaint),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const ValueKey('connect-search'),
                    controller: search,
                    onChanged: onQuery,
                    style: C.of(context).small(color: C.of(context).text),
                    cursorColor: C.of(context).accent,
                    cursorWidth: 1.5,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: 'Search name, host or id',
                      hintStyle: C.of(context).small(color: C.of(context).textFaint),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          for (final s in sets) ...[
            _SetChip(
              set: s,
              selected: s.id == selectedSet && s.enabled,
              onTap: () => onSet(s.id),
            ),
            const SizedBox(width: 6),
          ],
          const Spacer(),
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: C.of(context).surfaceHi,
              borderRadius: C.roundedSm,
            ),
            child: Text(
              shown == total
                  ? '$total ${total == 1 ? 'machine' : 'machines'}'
                  : '$shown of $total',
              style: C.of(context).small(color: C.of(context).textMuted, w: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetChip extends StatefulWidget {
  const _SetChip(
      {required this.set, required this.selected, required this.onTap});

  final PeerSetChip set;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SetChip> createState() => _SetChipState();
}

class _SetChipState extends State<_SetChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.set;
    final enabled = s.enabled;
    final fg = !enabled
        ? C.of(context).textFaint
        : widget.selected
            ? C.of(context).accent
            : (_hover ? C.of(context).text : C.of(context).textMuted);

    Widget chip = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: ValueKey('chip-${s.id}'),
        onTap: enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: C.fast,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: widget.selected
                ? C.of(context).accent.withOpacity(0.14)
                : (_hover && enabled ? C.of(context).surfaceHi : Colors.transparent),
            borderRadius: C.roundedSm,
            border: Border.all(
              color: widget.selected ? C.of(context).accentDim : C.of(context).hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s.icon != null) ...[
                LdIcon(s.icon!, size: 14, color: fg),
                const SizedBox(width: 7),
              ],
              Text(s.label, style: C.of(context).small(color: fg, w: FontWeight.w600)),
              if (!enabled) ...[
                const SizedBox(width: 6),
                LdIcon(LdIcons.lock, size: 12, color: C.of(context).textFaint),
              ],
            ],
          ),
        ),
      ),
    );

    // The reason travels with the disabled control, so the operator learns why
    // rather than assuming the set is empty.
    final why = s.unavailable;
    return why == null ? chip : Tooltip(message: why, child: chip);
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader({required this.showGroup});

  final bool showGroup;

  @override
  Widget build(BuildContext context) {
    Widget h(String s, int flex, {bool right = false}) => Expanded(
          flex: flex,
          child: Text(
            s,
            textAlign: right ? TextAlign.right : TextAlign.left,
            style: C.of(context).micro().copyWith(letterSpacing: 0.7),
          ),
        );

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: _padH),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: C.of(context).hairline)),
      ),
      child: Row(
        children: [
          const SizedBox(width: _wSelect),
          h('MACHINE', _fName),
          h('ID', _fId),
          h('PLATFORM', _fPlatform),
          if (showGroup) h('GROUP', _fGroup),
          h('STATUS', _fStatus),
          h('LAST SEEN', _fSeen, right: true),
          const SizedBox(width: 20 + _wActions),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatefulWidget {
  const _GroupHeader({
    super.key,
    required this.name,
    required this.count,
    required this.collapsed,
    required this.onTap,
    this.plain = false,
  });

  final String name;
  final int count;
  final bool collapsed;
  final VoidCallback onTap;

  /// The catch-all heading carries no group glyph: it is not a group.
  final bool plain;

  @override
  State<_GroupHeader> createState() => _GroupHeaderState();
}

class _GroupHeaderState extends State<_GroupHeader> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: C.fast,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: _padH),
          decoration: BoxDecoration(
            color: _hover ? C.of(context).surfaceHi : C.of(context).chrome,
            border: Border(bottom: BorderSide(color: C.of(context).hairline)),
          ),
          child: Row(
            children: [
              LdIcon(
                widget.collapsed ? LdIcons.chevronRight : LdIcons.chevronDown,
                size: 14,
                color: C.of(context).textMuted,
              ),
              const SizedBox(width: 8),
              if (!widget.plain) ...[
                LdIcon(LdIcons.group, size: 14, color: C.of(context).accent),
                const SizedBox(width: 8),
              ],
              Text(widget.name,
                  style: C.of(context).small(color: C.of(context).text, w: FontWeight.w700)),
              const SizedBox(width: 8),
              Text('${widget.count}',
                  style: C.of(context).data(size: 11, color: C.of(context).textFaint)),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupEmpty extends StatelessWidget {
  const _GroupEmpty();

  @override
  Widget build(BuildContext context) => Container(
        height: 34,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: _padH + 22),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: C.of(context).hairline)),
        ),
        child: Text('No machines in this group yet.',
            style: C.of(context).small(color: C.of(context).textFaint)),
      );
}

class _MachineTile extends StatefulWidget {
  const _MachineTile({
    super.key,
    required this.machine,
    required this.showGroup,
    required this.selected,
    required this.selecting,
    required this.onSelect,
    required this.onConnect,
    required this.menu,
    required this.onAction,
    this.now,
  });

  final MachineRow machine;
  final bool showGroup;
  final bool selected;

  /// Something on this table is ticked, so every row shows its box.
  final bool selecting;
  final VoidCallback onSelect;
  final ValueChanged<ConnectMode> onConnect;
  final List<ConsoleMenuEntry<Object>> Function() menu;
  final ValueChanged<RowAction> onAction;
  final DateTime? now;

  @override
  State<_MachineTile> createState() => _MachineTileState();
}

class _MachineTileState extends State<_MachineTile> {
  bool _hover = false;

  (Color, String) _status(LabDeskPeerStatus s) => switch (s) {
        LabDeskPeerStatus.online => (C.of(context).ok, 'Online'),
        LabDeskPeerStatus.offline => (C.of(context).bad, 'Offline'),
        LabDeskPeerStatus.unknown => (C.of(context).idle, 'Unknown'),
      };

  static (String?, String) _platform(String raw) {
    final p = raw.toLowerCase();
    if (p.contains('win')) return (LdIcons.windows, 'Windows');
    if (p.contains('mac') || p.contains('darwin') || p.contains('ios')) {
      return (LdIcons.macos, raw.isEmpty ? 'macOS' : raw);
    }
    if (p.contains('android')) return (LdIcons.android, 'Android');
    if (p.contains('linux') || p.contains('nix')) {
      return (LdIcons.linux, raw.isEmpty ? 'Linux' : raw);
    }
    // An unrecognised platform is reported as it came, not guessed at.
    return (null, raw.isEmpty ? 'Unknown' : raw);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.machine;
    final (statusColor, statusWord) = _status(m.status);
    final (glyph, platform) = _platform(m.platform);
    final second = [
      if ((m.username ?? '').isNotEmpty) m.username!,
      if (m.hostname.isNotEmpty) m.hostname,
    ].join('@');

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: C.fast,
        height: _rowH,
        padding: const EdgeInsets.fromLTRB(_padH - _leadBar, 0, _padH, 0),
        decoration: BoxDecoration(
          color: widget.selected
              ? C.of(context).accent.withOpacity(0.13)
              : (_hover ? C.of(context).surfaceHi : Colors.transparent),
          border: Border(
            left: BorderSide(
              color: widget.selected ? C.of(context).accent : Colors.transparent,
              width: _leadBar,
            ),
            bottom: BorderSide(color: C.of(context).hairline),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: _wSelect,
              child: _TickBox(
                boxKey: ValueKey('row-select-${m.id}'),
                on: widget.selected,
                shown: widget.selected || widget.selecting || _hover,
                onTap: widget.onSelect,
              ),
            ),
            Expanded(
              flex: _fName,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(m.displayName,
                      overflow: TextOverflow.ellipsis,
                      // The line box is pulled in from 1.45 so two lines fit
                      // the tighter row. The type sizes are untouched: this is
                      // leading, not the identity getting smaller.
                      style: C.of(context).body().copyWith(height: 1.2)),
                  Text(second,
                      overflow: TextOverflow.ellipsis,
                      style: C
                          .data(size: 11, color: C.of(context).textFaint)
                          .copyWith(height: 1.25)),
                ],
              ),
            ),
            Expanded(
              flex: _fId,
              child: Text(formatID(m.id),
                  overflow: TextOverflow.ellipsis,
                  style: C.of(context).data(size: 12, color: C.of(context).textMuted)),
            ),
            Expanded(
              flex: _fPlatform,
              child: Row(
                children: [
                  if (glyph != null) ...[
                    LdIcon(glyph, size: 15, color: C.of(context).textMuted),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(platform,
                        overflow: TextOverflow.ellipsis,
                        style: C.of(context).small(color: C.of(context).textMuted)),
                  ),
                ],
              ),
            ),
            if (widget.showGroup)
              Expanded(
                flex: _fGroup,
                child: Text(
                  m.group ?? 'Ungrouped',
                  overflow: TextOverflow.ellipsis,
                  style: C.of(context).small(
                      color: m.group == null ? C.of(context).textFaint : C.of(context).textMuted),
                ),
              ),
            Expanded(
              flex: _fStatus,
              child: Tooltip(
                message: switch (m.status) {
                  LabDeskPeerStatus.online =>
                    'Registered with the ID server. This is not a health check.',
                  LabDeskPeerStatus.offline =>
                    'Answered, and is not registered with the ID server.',
                  LabDeskPeerStatus.unknown =>
                    'Not asked about yet, or the last query failed. This is not '
                        'the same as being down.',
                },
                child: Row(
                  children: [
                    _Dot(
                      color: statusColor,
                      hollow: m.status == LabDeskPeerStatus.unknown,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(statusWord,
                          overflow: TextOverflow.ellipsis,
                          style: C.of(context).small(color: C.of(context).textMuted)),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              flex: _fSeen,
              child: Text(
                m.status == LabDeskPeerStatus.online
                    ? 'Now'
                    : m.sinceSeen(now: widget.now),
                textAlign: TextAlign.right,
                style: C.of(context).data(
                  size: 12,
                  color:
                      m.status == LabDeskPeerStatus.online ? C.of(context).ok : C.of(context).textMuted,
                ),
              ),
            ),
            const SizedBox(width: 20),
            _RowConnect(
              buttonKey: ValueKey('row-connect-${m.id}'),
              lit: _hover,
              onPressed: () => widget.onConnect(ConnectMode.control),
            ),
            const SizedBox(width: 4),
            ConsoleMenuButton<Object>(
              key: ValueKey('row-menu-${m.id}'),
              tooltip: 'Everything else for this machine',
              entries: widget.menu,
              onSelected: (v) => v is ConnectMode
                  ? widget.onConnect(v)
                  : widget.onAction(v as RowAction),
              builder: (focused, hovered) => AnimatedContainer(
                duration: C.fast,
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: hovered || focused
                      ? C.of(context).accent.withOpacity(0.12)
                      : Colors.transparent,
                  borderRadius: C.roundedSm,
                  border: Border.all(
                      color: focused ? C.of(context).accent : Colors.transparent),
                ),
                child: Center(
                  child: LdIcon(
                    LdIcons.more,
                    size: 16,
                    color: hovered || focused
                        ? C.of(context).accent
                        : (_hover ? C.of(context).textMuted : C.of(context).textFaint),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The status mark, matched to the fleet table.
///
/// Unknown is drawn hollow rather than as a grey fill. Three solid dots that
/// differ only in hue are three identical dots to an operator who cannot
/// separate the hues; a ring is a different shape, and shape survives.
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

/// A row's tick box.
///
/// Hidden until the pointer or the keyboard arrives, or until there is a
/// selection - a column of empty boxes down a table nobody is selecting in is
/// nine tenths of the table's ink spent on the thing least often done. It stays
/// reachable by tab either way, because a control that only exists under the
/// pointer is a control half the operators do not have.
class _TickBox extends StatefulWidget {
  const _TickBox({
    required this.boxKey,
    required this.on,
    required this.shown,
    required this.onTap,
  });

  final Key boxKey;
  final bool on;
  final bool shown;
  final VoidCallback onTap;

  @override
  State<_TickBox> createState() => _TickBoxState();
}

class _TickBoxState extends State<_TickBox> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final visible = widget.shown || _focused;
    return FocusableActionDetector(
      key: widget.boxKey,
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap();
          return null;
        }),
      },
      child: Tooltip(
        message: 'Select. Shift-click to take the range.',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            width: _wSelect,
            height: _rowH,
            child: Center(
              child: AnimatedOpacity(
                duration: C.fast,
                opacity: visible ? 1 : 0,
                // The console's checkbox. It is only ever drawn while the row
                // is under the pointer or the box has focus, so it is handed
                // the lit border either way rather than the resting hairline
                // it would otherwise disappear into.
                child: LdCheckbox(
                  on: widget.on,
                  hover: visible,
                  focused: _focused,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the peer page's multi-select bar did, in the place the filter row was.
///
/// It replaces that row rather than stacking under it: a bar that appears above
/// the table pushes the table down at the exact moment the operator is picking
/// rows out of it, and the filters are not what they are doing right now.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.visible,
    required this.offered,
    required this.onAll,
    required this.onClear,
    required this.onAction,
  });

  final int count;

  /// How many rows the table is showing, so select-all can say what it takes
  /// and can go quiet once it would take nothing.
  final int visible;

  /// The actions every selected machine can be given. Anything else is drawn
  /// disabled carrying the reason, rather than dropped: an action that vanishes
  /// as the selection grows looks like a bug.
  final Set<RowAction> offered;

  final VoidCallback onAll;
  final VoidCallback onClear;
  final ValueChanged<RowAction> onAction;

  @override
  Widget build(BuildContext context) {
    final machines = '$count ${count == 1 ? 'machine' : 'machines'}';

    Widget action(RowAction a) {
      final can = offered.contains(a);
      final fire = can ? () => onAction(a) : null;
      // The one that cannot be undone does not look like the three that can.
      final button = a.isDestructive
          ? _DangerButton(
              buttonKey: ValueKey('bulk-${a.name}'),
              label: a.bulkLabel,
              onPressed: fire,
            )
          : GhostButton(
              key: ValueKey('bulk-${a.name}'),
              label: a.bulkLabel,
              onPressed: fire,
            );
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: can
            ? button
            : Tooltip(
                message: 'Offered when every selected machine can be given it. '
                    'At least one of these $count cannot.',
                child: button,
              ),
      );
    }

    return Container(
      key: const ValueKey('selection-bar'),
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: _padH),
      decoration: BoxDecoration(
        // The one place the accent tints a whole surface. The table under it
        // is in a mode, and a mode that looks like the screen it replaced is a
        // mode the operator forgets they are in.
        color: C.of(context).accent.withOpacity(0.07),
        border: Border(bottom: BorderSide(color: C.of(context).hairline)),
      ),
      child: Row(
        children: [
          Text('$machines selected',
              style: C.of(context).small(color: C.of(context).text, w: FontWeight.w700)),
          const SizedBox(width: 14),
          if (count < visible)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GhostButton(
                key: const ValueKey('selection-all'),
                label: 'Select all $visible',
                onPressed: onAll,
              ),
            ),
          // No Spacer beside this: a Spacer and a Flexible are both flex 1, so
          // the free width was split between them and the buttons scrolled
          // inside a viewport half the size they needed. Reversed instead, so
          // the run sits against the right edge and a console too narrow to
          // hold it scrolls rather than hiding what the buttons do.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  for (final a in _ConnectScreenState._bulkOrder) action(a),
                  GhostButton(
                    key: const ValueKey('selection-clear'),
                    label: 'Clear',
                    glyph: LdIcons.close,
                    onPressed: onClear,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The row's primary action. Present at rest rather than revealed on hover: a
/// control that only exists under the pointer is a control a keyboard user does
/// not have.
class _RowConnect extends StatefulWidget {
  const _RowConnect({
    required this.buttonKey,
    required this.lit,
    required this.onPressed,
  });

  final Key buttonKey;
  final bool lit;
  final VoidCallback onPressed;

  @override
  State<_RowConnect> createState() => _RowConnectState();
}

class _RowConnectState extends State<_RowConnect> {
  bool _hover = false;
  bool _focused = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final active = _hover || _focused;
    final fg = active ? C.of(context).accent : (widget.lit ? C.of(context).text : C.of(context).textMuted);
    // A gesture detector is not a control: it cannot be tabbed to and it does
    // not answer the space bar. This one now can, and shows where focus is
    // while it holds it.
    return FocusableActionDetector(
      key: widget.buttonKey,
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onPressed();
          return null;
        }),
      },
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: C.fast,
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _down ? 1 : 0, 0),
          height: 26,
          width: 74,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? C.of(context).accent.withOpacity(0.12) : Colors.transparent,
            borderRadius: C.roundedSm,
            // The word is always there; the box only arrives with the pointer.
            // Nine outlined buttons down a table is noise, and a control that
            // appears from nothing is a control a keyboard user never finds.
            border: Border.all(
              color: _focused
                  ? C.of(context).accent
                  : _hover
                      ? C.of(context).accentDim
                      : widget.lit
                          ? C.of(context).hairline
                          : Colors.transparent,
            ),
          ),
          child: Text('Connect', style: C.of(context).small(color: fg, w: FontWeight.w600)),
        ),
      ),
    );
  }
}

/// The alternate session types for a typed-in id.
///
/// Only the three that need nothing known about the machine. An administrator
/// terminal, RDP and tunnelling all turn on the far platform, and nothing is
/// known about the platform of an id that has only been typed.
class _IdModeMenu extends StatelessWidget {
  const _IdModeMenu({required this.menuKey, required this.onSelected});

  final Key menuKey;
  final ValueChanged<ConnectMode> onSelected;

  @override
  Widget build(BuildContext context) => ConsoleMenuButton<ConnectMode>(
        key: menuKey,
        tooltip: 'Other session types',
        onSelected: onSelected,
        entries: () => const [
          ConsoleMenuAction(ConnectMode.fileTransfer, 'Transfer files'),
          ConsoleMenuAction(ConnectMode.viewCamera, 'View camera'),
          ConsoleMenuAction(ConnectMode.terminal, 'Terminal (beta)'),
        ],
        builder: (focused, hovered) => AnimatedContainer(
          duration: C.fast,
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hovered || focused
                ? C.of(context).accent.withOpacity(0.12)
                : Colors.transparent,
            borderRadius: C.roundedSm,
            border: Border.all(color: focused ? C.of(context).accent : C.of(context).hairline),
          ),
          child: LdIcon(LdIcons.chevronDown,
              size: 15, color: hovered || focused ? C.of(context).accent : C.of(context).textMuted),
        ),
      );
}

/// Asks before something irreversible, in the console's own surfaces rather
/// than in the framework's alert dialog.
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0xAA000000),
    builder: (ctx) => Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          key: const ValueKey('row-confirm'),
          width: 384,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          decoration: BoxDecoration(
            color: C.of(context).surface,
            borderRadius: C.rounded,
            border: Border.all(color: C.of(context).hairline),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 28,
                  offset: Offset(0, 12)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: C.of(context).h2()),
              const SizedBox(height: 8),
              Text(body, style: C.of(context).small(color: C.of(context).textFaint)),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  GhostButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.pop(ctx, false),
                  ),
                  _DangerButton(
                    label: confirmLabel,
                    onPressed: () => Navigator.pop(ctx, true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return ok ?? false;
}

/// The one button on this screen that is not the accent. A destructive
/// confirmation that looks like every other primary action is a confirmation
/// nobody reads.
class _DangerButton extends StatefulWidget {
  const _DangerButton({
    this.buttonKey = const ValueKey('row-confirm-go'),
    required this.label,
    required this.onPressed,
  });

  final Key buttonKey;
  final String label;

  /// Null draws the button as it is when the action is not on offer, which is
  /// how the bulk bar says an action does not apply to everything selected.
  final VoidCallback? onPressed;

  @override
  State<_DangerButton> createState() => _DangerButtonState();
}

class _DangerButtonState extends State<_DangerButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor:
          enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onPressed?.call();
          return null;
        }),
      },
      child: GestureDetector(
        key: widget.buttonKey,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: C.fast,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: !enabled
                ? Colors.transparent
                : C.of(context).bad.withOpacity(_hover ? 0.2 : 0.12),
            borderRadius: C.roundedSm,
            border: Border.all(color: C.of(context).bad.withOpacity(enabled ? 0.55 : 0.2)),
          ),
          child: Text(
            widget.label,
            style: C.of(context).small(
                color: enabled ? C.of(context).bad : C.of(context).bad.withOpacity(0.45),
                w: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatefulWidget {
  const _PrimaryButton(
      {super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

/// The shared filled primary: [C.of(context).primaryFill] under [C.of(context).primaryFg], the same
/// pair the installer's Accept and install uses. This button used to paint the
/// dim accent under a white label, so the product's two most important confirms
/// were two different colours.
class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: C.fast,
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _down ? 1 : 0, 0),
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _down
                ? C.of(context).primaryFillDown
                : (_hover ? C.of(context).primaryFillHover : C.of(context).primaryFill),
            borderRadius: C.roundedSm,
          ),
          child: Text(widget.label,
              style: C.of(context).small(color: C.of(context).primaryFg, w: FontWeight.w700)),
        ),
      ),
    );
  }
}

/// There are machines and none of them has been asked about. Not an empty
/// fleet, not a failed search, and not a fleet that is down.
class _UncheckedNote extends StatelessWidget {
  const _UncheckedNote();

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('note-unchecked'),
        padding: const EdgeInsets.fromLTRB(_padH, 11, _padH, 11),
        decoration: BoxDecoration(
          color: C.of(context).surface,
          border: Border(bottom: BorderSide(color: C.of(context).hairline)),
        ),
        child: Row(
          children: [
            _Dot(color: C.of(context).idle, hollow: true),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'Nothing has been checked yet. Reachability is polled, so these '
                'machines are neither up nor down until Refresh asks the ID server.',
                style: C.of(context).small(color: C.of(context).textMuted),
              ),
            ),
          ],
        ),
      );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const _Empty(
        stateKey: ValueKey('empty-loading'),
        icon: LdIcons.recent,
        title: 'Looking for machines',
        body: 'Reading the recent sessions, favourites and address book this '
            'server profile knows about.',
      );
}

class _EmptyFleet extends StatelessWidget {
  const _EmptyFleet();

  @override
  Widget build(BuildContext context) => const _Empty(
        stateKey: ValueKey('empty-no-machines'),
        icon: LdIcons.fleet,
        title: 'No machines yet',
        body: 'Connect to a machine by its id above and it appears here. '
            'Machines from a server profile with an address book arrive on '
            'their own.',
      );
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults(
      {required this.query, required this.set, required this.onClear});

  final String query;
  final String? set;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final where = set == null ? 'this fleet' : set!.toLowerCase();
    return _Empty(
      stateKey: const ValueKey('empty-no-results'),
      icon: LdIcons.search,
      title: query.isEmpty ? 'Nothing in $where yet' : 'No machine matches',
      body: query.isEmpty
          ? 'Every machine LabDesk knows about is outside this set.'
          : 'Nothing in $where is named, hosted or numbered "$query".',
      action: GhostButton(label: 'Clear filters', onPressed: onClear),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.stateKey,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final Key stateKey;
  final String icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        key: stateKey,
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LdIcon(icon, size: 24, color: C.of(context).textFaint),
              const SizedBox(height: 14),
              Text(title, style: C.of(context).h2()),
              const SizedBox(height: 6),
              SizedBox(
                width: 360,
                child: Text(body,
                    textAlign: TextAlign.center,
                    style: C.of(context).small(color: C.of(context).textFaint)),
              ),
              if (action != null) ...[
                const SizedBox(height: 16),
                action!,
              ],
            ],
          ),
        ),
      );
}
