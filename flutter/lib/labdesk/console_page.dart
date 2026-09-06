import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart' show trimID;
import 'package:flutter_hbb/common/labdesk_peer_status.dart';
import 'package:flutter_hbb/common/labdesk_profiles.dart';
import 'package:flutter_hbb/common/labdesk_status_binding.dart';
import 'package:flutter_hbb/common/widgets/labdesk_groups.dart';
import 'package:flutter_hbb/common/widgets/login.dart' show loginDialog;
import 'package:flutter_hbb/common/widgets/peer_card.dart' show showRdpDialog;
import 'package:flutter_hbb/desktop/pages/connection_page.dart' show OnlineStatusWidget;
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/desktop/pages/labdesk_machine_link.dart';
import 'package:flutter_hbb/desktop/pages/labdesk_terminal_rpc.dart';
import 'package:flutter_hbb/desktop/widgets/server_profile_switcher.dart';
import 'package:flutter_hbb/desktop/widgets/update_progress.dart' show handleUpdate;
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:provider/provider.dart';

import 'console_data.dart';
import 'models/automation_models.dart';
import 'models/chat_transcript.dart';
import 'models/console_rpc.dart';
import 'models/machine_metrics.dart';
import 'models/machine_row.dart';
import 'models/machine_state.dart';
import 'models/net_view.dart';
import 'models/tool_models.dart';
import 'screens/actions_screen.dart';
import 'screens/automation_screen.dart';
import 'screens/connect_screen.dart';
import 'screens/console_shell.dart';
import 'screens/sessions_screen.dart';
import 'screens/settings_screen.dart';
import 'models/labnet.dart';
import 'screens/enrol_card.dart';
import 'screens/labnet_card.dart';
import 'screens/network_screen.dart';
import 'screens/selfheal_card.dart';
import 'services/overlay_broker.dart';
import 'services/overlay_daemon.dart';
import 'services/overlay_enrolment.dart';
import 'services/overlay_session.dart';
import 'theme/console_theme.dart';
import 'screens/terminal_screen.dart';
import 'screens/tools_screen.dart';
import 'services/automation_engine.dart';
import 'services/tool_catalog.dart';
import 'services/tool_parsers.dart';
import 'screens/this_machine_screen.dart';
import 'theme/ld_icons.dart';

/// The console, driven by the real client.
///
/// This is the only file in `lib/labdesk` that touches the FFI. Everything
/// behind it takes plain values and hands back callbacks, which is what lets
/// the whole surface be rendered and judged from `lib/labdesk_preview.dart`
/// without a peer, a Rust core or a generated bridge.
///
/// What is wired, and what is honestly not: connecting, opening a terminal and
/// transferring files all go through the client's own `connect`, so they work.
/// Capturing a screen and restarting a machine need a session that is already
/// open, and the main window holds no registry of open sessions, because on
/// desktop each one runs in its own window. Rather than invent that registry
/// here, the console reports no connected machines, so those two actions render
/// disabled with their explanation intact. The Health screen says the same
/// thing about its own panels. That is the design the screens were built to:
/// an absent capability is shown as absent, never as a control that does
/// nothing.
class LabDeskConsolePage extends StatefulWidget {
  const LabDeskConsolePage({super.key});

  @override
  State<LabDeskConsolePage> createState() => _LabDeskConsolePageState();
}

class _LabDeskConsolePageState extends State<LabDeskConsolePage> {
  Timer? _tick;
  bool _refreshing = false;
  DateTime? _lastRefreshed;

  /// Lets controls that mean "go to settings" move the console rather than
  /// open a second settings surface in its own tab.
  final _sectionRequest = ConsoleSectionRequest(ConsoleSection.connect);
  var _settingsTab = SettingsTabKey.general;
  var _section = ConsoleSection.connect;

  /// The machine last connected to, so the id field opens where the operator
  /// left it. Read once, exactly as the page this replaces did.
  var _lastRemoteId = '';

  /// Machines this client has a password saved for. The bridge answers one id
  /// at a time and only asynchronously, so the answer is read with the rest of
  /// the fleet rather than during a build, and the row menu offers "Forget
  /// saved password" against this.
  final _savedPasswords = <String>{};

  // labnet: the encrypted direct path. The daemon, the broker and the two
  // sequences are built once; the This machine card and the Network section
  // render their state. Nothing reaches the daemon until the operator says so.
  late final OverlayDaemon _daemon;
  late final OverlayBroker _broker;
  late final OverlayEnrolment _enrolment;
  late final OverlaySession _overlay;
  var _labnet = LabnetCardState.off;
  var _inbox = LabnetInbox.empty;

  /// The organization's machines as lab-desk.net holds them, read with the
  /// inbox. The Network section is the one place the console names a machine
  /// the way the server does rather than by its peer id, because that is what
  /// every labnet route resolves against.
  var _orgMachines = const <OrgMachine>[];

  /// The same list keyed by peer id. Rebuilt when the list changes rather than
  /// scanned: the fleet table and the rule tick both resolve every row through
  /// it, once a second, and a linear scan per row is quadratic.
  var _orgByPeer = const <String, OrgMachine>{};

  /// The per-machine reads, keyed by `machine.id`: the fleet answer carries no
  /// uptime and no signed-in user, so one machine a cycle is asked for its own
  /// hot row rather than every machine every cycle (contract section 5, "not
  /// the N+1").
  final _detail = <String, MachineState>{};

  /// Which machine the round-robin read is up to, and which have had their
  /// stored history pulled once.
  var _detailCursor = -1;
  final _backfilled = <String>{};

  /// What each machine reports about its own network, keyed by `machine.id`.
  /// Read only for the machine a section is actually showing.
  final _netViews = <String, MachineNetView>{};

  /// The machine the Network section's adapter view is pointed at.
  var _netMachineId = '';

  /// The fleets this account may name, and whether it is narrowed to more than
  /// one of them, which is the only case where creating a labnet has to say
  /// which fleet it belongs to.
  var _fleets = const <OrgFleet>[];
  var _mustNameFleet = false;
  var _fleetsRead = false;

  /// The self-healing switch as it stands on this machine, and whether the
  /// service has reported since it was last flipped.
  var _selfHealOn = false;
  var _selfHealWaiting = false;

  var _labnetBusy = false;
  var _labnetError = '';
  Timer? _inboxTick;
  static const _kConsentKey = 'labdesk-overlay-consent';


  void _goToSettings(SettingsTabKey tab) {
    // A page this build does not offer must not become reachable through the
    // console: tabKeys hides pages by policy and by platform.
    final offered = settingsPages().any((p) => p.key == tab);
    setState(() => _settingsTab = offered ? tab : SettingsTabKey.general);
    _sectionRequest.request(ConsoleSection.settings);
  }

  @override
  void initState() {
    super.initState();
    LabDeskGroupsModel.ensureLoaded();
    ServerProfilesModel.ensureLoaded();
    // ponytail: a one second repaint rather than plumbing change notification
    // through a store that is deliberately plain Dart. This is a monitoring
    // surface whose figures are seconds old by nature, and the alternative is
    // reactive wiring in a layer kept free of it on purpose.
    //
    // Only while Fleet is showing, though. Everything else here is either the
    // application's own widget or a screen with nothing that changes second to
    // second, and rebuilding the hosted connect page or a settings page once a
    // second is work nobody asked for.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _pollReachability();
      _runAutomation();
      _ticks++;
      if (_ticks.isEven) _pollSessions();
      if (_section == ConsoleSection.fleet ||
          _section == ConsoleSection.connect) {
        setState(() {});
      }
    });
    bind.mainIsUsingPublicServer().then((public) {
      // The intervals the peer page it replaced used: a public server is
      // shared and is asked less often.
      _pollEvery = Duration(seconds: public ? 10 : 4);
    });
    // The peer stores fill from events, not from a getter, so the load has to
    // be asked for. Recent and favourites are local reads. LAN discovery is a
    // broadcast and is not run until the operator asks for that set.
    bind.mainLoadRecentPeers();
    bind.mainLoadFavPeers();
    bind.mainLoadLanPeers();
    _automation.rules = decodeRules(bind.mainGetLocalOption(key: _kRulesKey));
    _selfHealOn = bind.mainGetOptionSync(key: kSelfHealOption) == 'Y';
    _library = ScriptLibrary.decode(bind.mainGetLocalOption(key: _kScriptsKey));
    _initLabnet();
    // Ask once on open so the fleet is not blank while waiting for the client's
    // own poll to come round.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final id = await bind.mainGetLastRemoteId();
      if (mounted && id.isNotEmpty) setState(() => _lastRemoteId = id);
      await _refresh();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _inboxTick?.cancel();
    _enrolment.dispose();
    _sectionRequest.dispose();
    LabDeskMachineLink.closeAll();
    super.dispose();
  }

  /// The reachability poll the peer page used to run. That page is no longer
  /// mounted, and without this the dots were only ever asked for once, on
  /// open, and again on Refresh: a machine coming up stayed red until the
  /// operator happened to press the button.
  var _pollEvery = const Duration(seconds: 4);

  void _pollReachability() {
    final now = DateTime.now();
    labdeskStatus.expireStale(now);
    if (!labdeskStatus.isDue(now, _pollEvery)) return;
    final ids = {for (final p in _peers) p.id}.toList(growable: false);
    if (ids.isEmpty) return;
    labdeskStatus.beginQuery(ids, at: now);
    bind.queryOnlines(ids: ids);
  }

  /// Which window holds a live session to a machine, by kind.
  ///
  /// Sessions run in their own windows, and the main window kept no record of
  /// them, which is why Health, Terminal and two of the Actions shipped in a
  /// permanent "no session" state. The windows already answer "what do you
  /// hold" for the tab bar, so the console asks each of them every two seconds
  /// rather than inventing an event system for the same fact.
  final _remoteWindowOf = <String, int>{};
  final _terminalWindowOf = <String, int>{};
  var _ticks = 0;
  var _askingWindows = false;

  /// What Health has learned, per machine: the session window's quality
  /// figures, and the readings the machine's own collector sent to
  /// lab-desk.net. Nothing here is measured over a session any more; the agent
  /// takes its own figures on its own flush (WP18).
  final _sessionStats = <String, Map<String, dynamic>>{};

  /// Keyed by peer id, like everything else the console renders.
  final _history = <String, MetricHistory>{};

  /// The last uplink each machine's history has a sample for, so a fleet poll
  /// that lands between two flushes does not record the same reading twice.
  final _historyAt = <String, int>{};

  /// Rules that act on machines. Evaluated by this tick, so they run only
  /// while the console is open; the screen says so.
  static const _kRulesKey = 'labdesk-automation';
  final _automation = AutomationEngine();

  /// The toolbox: which machines are picked, which tool is open, what each
  /// machine answered, and the operator's saved scripts.
  static const _kScriptsKey = 'labdesk-scripts';
  final _toolSelected = <String>{};
  ToolId? _tool;
  final _toolResults = <String, ToolRunResult>{};
  final _toolBusy = <String>{};
  var _library = ScriptLibrary.empty;

  final _terminalLines = <String, List<TerminalLine>>{};

  /// Chat for every outgoing session, read from the window that holds it.
  /// Incoming connections are handled by the connection manager, which is a
  /// separate process this window cannot ask; the Sessions screen says so.
  final _chats = <String, SessionChat>{};
  final _readLines = <String, int>{};
  String? _openChatId;

  /// A window channel call that treats a closed or busy window as no answer.
  Future<dynamic> _ask(int windowId, String method, [dynamic args]) async {
    try {
      return await DesktopMultiWindow.invokeMethod(windowId, method, args);
    } catch (e) {
      debugPrint('labdesk: window $windowId did not answer $method: $e');
      return null;
    }
  }

  Future<void> _pollSessions() async {
    if (_askingWindows) return;
    _askingWindows = true;
    try {
      final remote = <String, int>{};
      final terminal = <String, int>{};
      for (final w in rustDeskWinManager.windowsOfType(WindowType.RemoteDesktop)) {
        final list = await _ask(w, kWindowEventGetRemoteList);
        if (list is String) {
          for (final id in list.split(',')) {
            if (id.isNotEmpty) remote[id] = w;
          }
        }
      }
      for (final w in rustDeskWinManager.windowsOfType(WindowType.Terminal)) {
        final list = await _ask(w, kWindowEventLabDeskTerminalList);
        if (list is String) {
          for (final id in list.split(',')) {
            if (id.isNotEmpty) terminal[id] = w;
          }
        }
      }
      if (!mounted) return;
      final changed = !mapEquals(remote, _remoteWindowOf) ||
          !mapEquals(terminal, _terminalWindowOf);
      _remoteWindowOf
        ..clear()
        ..addAll(remote);
      _terminalWindowOf
        ..clear()
        ..addAll(terminal);
      // A granted direct path is released once its session has come and gone.
      await _overlay.noteOpenSessions({...remote.keys, ...terminal.keys});

      // Chat transcripts of the desktop sessions that are open.
      final chats = <String, SessionChat>{};
      for (final e in remote.entries) {
        final s = decodeSessionChat(await _ask(e.value, kLabDeskRpcChatGet, e.key));
        if (s != null) {
          final read =
              _openChatId == s.id ? s.lines.length : (_readLines[s.id] ?? 0);
          _readLines[s.id] = read;
          chats[s.id] = s.copyWith(unread: (s.lines.length - read).clamp(0, 999));
        }
      }
      _readLines.removeWhere((id, _) => !chats.containsKey(id));
      final chatsChanged = !mapEquals(
          {for (final c in chats.values) c.id: c.lines.length},
          {for (final c in _chats.values) c.id: c.lines.length});
      _chats
        ..clear()
        ..addAll(chats);

      // Quality figures for the machines a desktop session is open to. The
      // machine's own CPU, memory and disk no longer come from here.
      for (final e in remote.entries) {
        final s = await _ask(e.value, kLabDeskRpcSessionStats, e.key);
        if (s is String) {
          _sessionStats[e.key] = jsonDecode(s) as Map<String, dynamic>;
        }
      }
      if (mounted &&
          (changed ||
              chatsChanged ||
              _section == ConsoleSection.fleet ||
              _section == ConsoleSection.sessions)) {
        setState(() {});
      }
    } finally {
      _askingWindows = false;
    }
  }

  void _runAutomation() {
    if (_automation.rules.isEmpty) return;
    final machines = _machines;
    final fired = _automation.tick(
      now: DateTime.now(),
      status: {
        for (final m in machines) m.id: labdeskStatus.store.stateOf(m.id).status
      },
      metrics: {
        for (final m in machines)
          if (_stateOfPeer(m.id) case final s?) m.id: s.metrics()
      },
      machines: {for (final m in machines) m.id},
    );
    for (final f in fired) {
      _execute(f);
    }
    if (fired.isNotEmpty && mounted && _section == ConsoleSection.automation) {
      setState(() {});
    }
  }

  Future<void> _execute(Firing f) async {
    final id = f.machineId;
    switch (f.action) {
      case RunCommand(:final command, :final platformHint):
        final platform = _rowOf(id)?.platform ?? '';
        if (platformHint != null &&
            !platform.toLowerCase().startsWith(platformHint.toLowerCase())) {
          _automation.recordOutcome(
              f.id, false, 'skipped: $platform is not $platformHint');
          break;
        }
        final ffi = await LabDeskMachineLink.open(id);
        if (ffi == null) {
          _automation.recordOutcome(
              f.id, false, LabDeskMachineLink.reason(id));
          break;
        }
        final out = await LabDeskTerminalRpc.runOn(ffi, id, command);
        final code = out['exitCode'];
        _automation.recordOutcome(
            f.id, code == 0, (out['reason'] as String?) ?? 'exit $code');
      case Notify(:final message):
        showToast(message.isEmpty ? '${f.rule.name} fired' : message);
        _automation.recordOutcome(f.id, true);
      case WakeOnLan():
        await bind.mainWol(id: id);
        _automation.recordOutcome(f.id, true, 'magic packet sent');
      case OpenSession():
        if (mounted) _connectVia(id);
        _automation.recordOutcome(f.id, true);
    }
    if (mounted) setState(() {});
  }

  void _saveRules(List<Rule> rules) {
    _automation.rules = rules;
    bind.mainSetLocalOption(key: _kRulesKey, value: encodeRules(rules));
    setState(() {});
  }

  Widget _automationScreen(BuildContext context) => AutomationScreen(
        rules: _automation.rules,
        log: _automation.log.entries,
        machines: _machines,
        now: DateTime.now(),
        onSave: _saveRules,
        onApplyPreset: (preset) => _saveRules([
          ..._automation.rules,
          preset.toRule(
              'rule-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'),
        ]),
        onToggle: (id, on) => _saveRules([
          for (final r in _automation.rules)
            r.id == id ? r.copyWith(enabled: on) : r,
        ]),
        onRunNow: (id) {
          for (final f in _automation.runNow(
            ruleId: id,
            now: DateTime.now(),
            machines: {for (final m in _machines) m.id},
          )) {
            _execute(f);
          }
        },
      );

  /// Run one command on one machine over whatever shell is available and hand
  /// back the raw answer, or a map naming why there was none.
  Future<Map<String, dynamic>> _shell(String id, String command) async {
    final tw = _terminalWindowOf[id];
    if (tw != null) {
      final r = await _ask(tw, kWindowEventLabDeskTermRun,
          jsonEncode({'id': id, 'command': command}));
      if (r is String) return jsonDecode(r) as Map<String, dynamic>;
      return {'lines': <String>[], 'reason': 'The terminal window did not answer.'};
    }
    final ffi = await LabDeskMachineLink.open(id);
    if (ffi == null) {
      return {'lines': <String>[], 'reason': LabDeskMachineLink.reason(id)};
    }
    return LabDeskTerminalRpc.runOn(ffi, id, command);
  }

  Future<void> _runTool(ToolId tool, Set<String> ids) async {
    setState(() {
      _tool = tool;
      _toolResults.clear();
      _toolBusy.addAll(ids);
    });
    await Future.wait(ids.map((id) async {
      final platform = _rowOf(id)?.platform ?? '';
      final cmd = ToolCatalog.commandFor(tool, platform);
      final result = cmd == null
          ? ToolRunResult(
              machineId: id,
              error: 'No ${tool.label.toLowerCase()} command for $platform.',
            )
          : ToolParsers.result(id, tool, await _shell(id, cmd.command));
      if (!mounted) return;
      setState(() {
        _toolResults[id] = result;
        _toolBusy.remove(id);
      });
    }));
  }

  Future<void> _toolAction(
      ToolId tool, ToolAction action, String id, String? target) async {
    final platform = _rowOf(id)?.platform ?? '';
    final cmd = ToolCatalog.actionFor(tool, action, platform, target: target);
    if (cmd == null) {
      showToast('No ${action.label.toLowerCase()} command for $platform.');
      return;
    }
    setState(() => _toolBusy.add(id));
    final out = await _shell(id, cmd.command);
    if (!mounted) return;
    setState(() => _toolBusy.remove(id));
    final reason = out['reason'];
    final code = out['exitCode'];
    if (reason is String && reason.isNotEmpty) {
      showToast(reason);
    } else if (code is int && code != 0) {
      showToast('${action.label}: exit $code'
          '${ToolParsers.firstMessage(List<String>.from(out['lines'] ?? const [])) ?? ''}');
    } else {
      showToast('${action.label}: done on ${_rowOf(id)?.displayName ?? id}');
      // Power actions end the shell on the far side; re-list for the rest.
      if (tool.listsSomething && !action.isDestructive) _runTool(tool, {id});
    }
  }

  Future<void> _runScript(SavedScript script, Set<String> ids) async {
    setState(() {
      _tool = ToolId.scripts;
      _toolResults.clear();
      _toolBusy.addAll(ids);
    });
    await Future.wait(ids.map((id) async {
      final platform = _rowOf(id)?.platform ?? '';
      final result = script.platform.matches(platform)
          ? ToolParsers.result(
              id, ToolId.scripts, await _shell(id, script.oneLine))
          : ToolRunResult(
              machineId: id,
              error: 'This script is for ${script.platform.label}; '
                  '${_rowOf(id)?.displayName ?? id} runs $platform.',
            );
      if (!mounted) return;
      setState(() {
        _toolResults[id] = result;
        _toolBusy.remove(id);
      });
    }));
  }

  void _saveLibrary(ScriptLibrary next) {
    _library = next;
    bind.mainSetLocalOption(key: _kScriptsKey, value: next.encode());
    setState(() {});
  }

  Widget _toolsScreen(BuildContext context) => ToolsScreen(
        machines: _machines,
        selectedIds: _toolSelected,
        onSelectionChanged: (ids) => setState(() => _toolSelected
          ..clear()
          ..addAll(ids)),
        tool: _tool,
        onToolChanged: (t) => setState(() {
          _tool = t;
          _toolResults.clear();
        }),
        results: _toolResults,
        busyIds: _toolBusy,
        onRun: _runTool,
        onAction: _toolAction,
        library: _library,
        onSaveScript: (s) => _saveLibrary(_library.upsert(s)),
        onDeleteScript: (id) => _saveLibrary(_library.remove(id)),
        onRunScript: _runScript,
      );

  MachineRow? _rowOf(String id) {
    for (final m in _fleetRows) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Every machine the fleet's health must account for: the technician's own
  /// peer rows, plus each machine the organization holds that is not among
  /// them.
  ///
  /// The peer list alone is not the fleet. On a console that has never
  /// connected to anything that list is empty, and until 2026-09-05 the health
  /// board rendered it: signed in on homebox-devserver the board read "No
  /// machines yet." while lab-desk.net was answering the same console with four
  /// machines, one of them that machine, online and carrying figures.
  List<MachineRow> get _fleetRows {
    final rows = _machines;
    final known = {for (final r in rows) r.id};
    return [
      ...rows,
      for (final m in _orgMachines)
        if (!known.contains(m.peerId))
          MachineRow(
            id: m.peerId,
            hostname: m.name,
            platform: m.platform,
            status: _serverStatusOf(m.peerId) ?? LabDeskPeerStatus.unknown,
          ),
    ];
  }

  MachineHealth _healthFor(String id) {
    final row = _rowOf(id);
    if (row == null) return MachineHealth.empty;
    return buildMachineHealth(
      machine: row,
      connected: _remoteWindowOf.containsKey(id) ||
          _terminalWindowOf.containsKey(id) ||
          LabDeskMachineLink.isOpen(id),
      sessionStats: _sessionStats[id],
      state: _stateOfPeer(id),
      history: _history[id],
    );
  }

  /// The organization's machine for a peer id, or null when lab-desk.net has
  /// never been told about that peer.
  OrgMachine? _orgOfPeer(String peerId) => _orgByPeer[peerId];

  /// The hot row for a peer: the fleet answer, with what only the per-machine
  /// read carries (uptime, the signed-in user) filled in from the last one.
  MachineState? _stateOfPeer(String peerId) {
    final m = _orgOfPeer(peerId);
    if (m == null) return null;
    final detail = _detail[m.id];
    return detail == null ? m.state : detail.mergeDetail(m.state);
  }

  /// One command, run in the terminal window's hidden shell for this machine,
  /// with its output brought back as plain lines.
  Future<void> _terminalSubmit(String id, String command) async {
    final lines = _terminalLines.putIfAbsent(id, () => []);
    setState(() => lines.add(TerminalLine(command, kind: TerminalLineKind.input)));
    final w = _terminalWindowOf[id];
    Map<String, dynamic>? out;
    if (w != null) {
      final r = await _ask(w, kWindowEventLabDeskTermRun,
          jsonEncode({'id': id, 'command': command}));
      if (r is String) out = jsonDecode(r) as Map<String, dynamic>;
    } else {
      // No terminal window: the console's own link carries the shell.
      final ffi = await LabDeskMachineLink.open(id);
      if (ffi == null) {
        if (!mounted) return;
        setState(() => lines.add(TerminalLine(LabDeskMachineLink.reason(id),
            kind: TerminalLineKind.notice)));
        return;
      }
      out = await LabDeskTerminalRpc.runOn(ffi, id, command);
    }
    if (!mounted) return;
    setState(() {
      if (out == null) {
        lines.add(const TerminalLine('The terminal window did not answer.',
            kind: TerminalLineKind.error));
        return;
      }
      for (final l in out['lines'] as List? ?? const []) {
        lines.add(TerminalLine(l.toString()));
      }
      final code = out['exitCode'];
      final reason = out['reason'];
      if (reason is String && reason.isNotEmpty) {
        lines.add(TerminalLine(reason, kind: TerminalLineKind.notice));
      } else if (out['timedOut'] == true) {
        lines.add(const TerminalLine(
            'No end of output after 30 s. The command may still be running.',
            kind: TerminalLineKind.notice));
      } else if (code is int && code != 0) {
        lines.add(TerminalLine('exit $code', kind: TerminalLineKind.error));
      }
    });
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await labdeskRefreshStatus();
      await _readSavedPasswords();
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _lastRefreshed = DateTime.now();
        });
      }
    }
  }

  Future<void> _readSavedPasswords() async {
    final found = <String>{};
    for (final id in {for (final p in _peers) p.id}) {
      if (await bind.mainPeerHasPassword(id: id)) found.add(id);
    }
    if (!mounted) return;
    setState(() => _savedPasswords
      ..clear()
      ..addAll(found));
  }

  /// Every store the client keeps peers in: recent sessions, favourites, the
  /// address book, whatever LAN discovery has found, and whichever peer tab is
  /// open. They overlap; the adapter folds them by id.
  ///
  /// All five are read rather than only the first three, because Connect offers
  /// each of them as a filter, and a filter over a list that never contained
  /// the set would return nothing and look like an answer.
  Iterable<ConsolePeer> get _peers sync* {
    for (final list in [
      gFFI.recentPeersModel.peers,
      gFFI.favoritePeersModel.peers,
      gFFI.abModel.peersModel.peers,
      gFFI.lanPeersModel.peers,
      gFFI.peerTabModel.currentTabCachedPeers,
    ]) {
      for (final p in list) {
        yield (
          id: p.id,
          hostname: p.hostname,
          platform: p.platform,
          alias: p.alias,
          username: p.username,
        );
      }
    }
  }

  String? _groupOf(String id) {
    for (final g in LabDeskGroupsModel.groups) {
      if (g.peers.contains(id)) return g.name;
    }
    return null;
  }

  List<MachineRow> get _machines => buildMachineRows(
        peers: _peers,
        store: labdeskStatus.store,
        historyOf: labdeskStatus.historyOf,
        groupOf: _groupOf,
        serverStatusOf: _serverStatusOf,
      );

  /// Reachability as lab-desk.net computed it, for a peer it holds a machine
  /// for. Null for anything else, which leaves the client's own poll answering.
  LabDeskPeerStatus? _serverStatusOf(String peerId) {
    final m = _orgOfPeer(peerId);
    if (m == null) return null;
    return switch (m.state.status) {
      'online' => LabDeskPeerStatus.online,
      'offline' => LabDeskPeerStatus.offline,
      _ => LabDeskPeerStatus.unknown,
    };
  }

  List<ProfileRow> get _profiles => [
        for (final p in ServerProfilesModel.profiles)
          ProfileRow(
            name: p.name,
            host: p.host,
            relay: p.relay,
            api: p.api,
            hasKey: p.key.isNotEmpty,
            active: p.name == ServerProfilesModel.active.value,
          )
      ];

  void _runAction(String machineId, MachineAction action) {
    switch (action.id) {
      case 'connect':
        _connectVia(machineId);
        break;
      case 'terminal':
        _connectVia(machineId, isTerminal: true);
        break;
      case 'transfer':
        _connectVia(machineId, isFileTransfer: true);
        break;
      case 'screenshot':
      case 'reboot':
        // Both act on a remote desktop session, which lives in its own window.
        // The screen only enables them while some session is open; a terminal
        // alone is not enough, and this is where that is said.
        final w = _remoteWindowOf[machineId];
        if (w == null) {
          showToast('Open a remote desktop session to this machine first.');
          break;
        }
        _ask(w, kLabDeskRpcAction,
                jsonEncode({'id': machineId, 'action': action.id}))
            .then((ok) {
          if (ok != true) showToast('The session window could not do that.');
        });
        break;
      default:
        debugPrint('labdesk: no handler for action ${action.id}');
    }
  }

  /// The peer sets the old tab strip exposed, sourced from the stores the
  /// client already keeps.
  ///
  /// A set this build cannot source carries its reason instead of an id list,
  /// and the chip renders disabled with that reason on it. Faking the list
  /// would be worse than not offering it.
  List<PeerSetChip> get _peerSets {
    final abOff = bind.isDisableAb();
    final accountOff = bind.isDisableAccount();
    final discoveryOff =
        bind.mainGetLocalOption(key: 'disable-discovery-panel') == 'Y';
    Set<String> ids(Iterable peers) => {for (final p in peers) p.id as String};

    return [
      PeerSetChip(
        id: kSetRecent,
        label: 'Recent',
        icon: LdIcons.recent,
        ids: ids(gFFI.recentPeersModel.peers),
      ),
      PeerSetChip(
        id: kSetFavourite,
        label: 'Favourites',
        icon: LdIcons.favourite,
        ids: ids(gFFI.favoritePeersModel.peers),
      ),
      PeerSetChip(
        id: kSetAddressBook,
        label: 'Address book',
        icon: LdIcons.addressBook,
        ids: abOff || accountOff ? null : ids(gFFI.abModel.peersModel.peers),
        unavailable: abOff
            ? 'The address book is turned off in this build.'
            : accountOff
                ? 'The address book needs an account, and accounts are turned '
                    'off in this build.'
                : null,
      ),
      PeerSetChip(
        id: kSetDiscovered,
        label: 'Discovered',
        icon: LdIcons.discovered,
        ids: discoveryOff ? null : ids(gFFI.lanPeersModel.peers),
        unavailable:
            discoveryOff ? 'LAN discovery is turned off in Settings.' : null,
      ),
    ];
  }

  /// LabDesk's own connect surface.
  ///
  /// This used to mount the peer page the application was derived from, which
  /// meant the section the product opens on was that product's interface: its
  /// tab strip, its peer cards, its search row. The screen behind this keeps
  /// what that page did - the same id formatting, the same four session types,
  /// the same peer sets - and says it in this console's language.
  Widget _connect(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _connectScreen(context)),
          // The client's own service line, kept where it was: it is the only
          // place that says whether this machine can be reached at all, and
          // whether the service needs starting. Losing it in the move would
          // have left the console unable to explain a fleet that is entirely
          // unreachable because nothing is running here.
          if (!bind.isOutgoingOnly()) ...[
            Divider(height: 1, thickness: 1, color: C.hairline),
            const OnlineStatusWidget(),
          ],
        ],
      );

  /// The peer the client holds for an id, wherever it is kept.
  ///
  /// Two of the address book dialogs take the whole peer rather than its id,
  /// so the console has to hand them one.
  Peer? _peerOf(String id) {
    for (final list in [
      gFFI.abModel.peersModel.peers,
      gFFI.recentPeersModel.peers,
      gFFI.favoritePeersModel.peers,
      gFFI.lanPeersModel.peers,
    ]) {
      for (final p in list) {
        if (p.id == id) return p;
      }
    }
    return null;
  }

  /// What the client can act on right now, which is what decides the shape of
  /// a row's menu. Every one of these was read off the bridge by the peer card
  /// as it built its own menu.
  ConnectCapabilities _capabilities(List<MachineRow> machines) =>
      ConnectCapabilities(
        hostIsWindows: isWindows,
        canAddToAddressBook: gFFI.userModel.userName.value.isNotEmpty &&
            gFFI.abModel.addressBooksCanWrite().isNotEmpty,
        addressBookWritable: gFFI.abModel.current.canWrite(),
        addressBookIsPersonal: gFFI.abModel.current.isPersonal(),
        addressBookHasTags: gFFI.abModel.currentAbTags.isNotEmpty,
        savedPasswords: _savedPasswords,
        alwaysRelay: {
          for (final m in machines)
            if (mainGetPeerBoolOptionSync(m.id, kOptionForceAlwaysRelay)) m.id
        },
      );

  /// Everything the peer cards could do to a machine that is not opening a
  /// session, wired to the same calls they made.
  ///
  /// The screen has already asked before anything destructive, so by the time
  /// one of those arrives here the operator has said yes.
  Future<void> _rowAction(String id, RowAction action) async {
    void done() {
      if (mounted) setState(() {});
    }

    switch (action) {
      case RowAction.rename:
        final inAb = gFFI.abModel.find(id);
        final oldName = inAb != null && inAb.alias.isNotEmpty
            ? inAb.alias
            : await bind.mainGetPeerOption(id: id, key: 'alias');
        renameDialog(
          oldName: oldName,
          onSubmit: (newName) async {
            if (newName == oldName) return;
            if (inAb != null) {
              await gFFI.abModel.changeAlias(id: id, alias: newName);
            }
            await bind.mainSetPeerAlias(id: id, alias: newName);
            // The stores are filled from events, so the rename only reaches
            // the table once they are re-read. Without this the row keeps the
            // old name until something else happens to reload them.
            await bind.mainLoadRecentPeers();
            await bind.mainLoadFavPeers();
            done();
          },
        );

      case RowAction.alwaysRelay:
        final on = mainGetPeerBoolOptionSync(id, kOptionForceAlwaysRelay);
        await bind.mainSetPeerOption(
          id: id,
          key: kOptionForceAlwaysRelay,
          value: bool2option(kOptionForceAlwaysRelay, !on),
        );
        done();

      case RowAction.rdpSettings:
        // The peer card's own dialog, unchanged. It was library-private, so
        // the port, username and password it edits were reachable from the
        // card's RDP entry and nowhere else.
        showRdpDialog(id);

      case RowAction.chooseIcon:
        await showLabDeskIconPicker(context, id);
        done();

      case RowAction.assignGroups:
        await showLabDeskAssignDialog(context, id);
        done();

      case RowAction.wakeOnLan:
        await bind.mainWol(id: id);

      case RowAction.desktopShortcut:
        await bind.mainCreateShortcut(id: id);
        showToast(translate('Successful'));

      case RowAction.copyId:
        await Clipboard.setData(ClipboardData(text: id));
        showToast(translate('Successful'));

      case RowAction.addToFavourites:
        final favs = (await bind.mainGetFav()).toList();
        if (!favs.contains(id)) {
          favs.add(id);
          await bind.mainStoreFav(favs: favs);
          await bind.mainLoadFavPeers();
        }
        done();

      case RowAction.removeFromFavourites:
        final favs = (await bind.mainGetFav()).toList();
        if (favs.remove(id)) {
          await bind.mainStoreFav(favs: favs);
          await bind.mainLoadFavPeers();
        }
        done();

      case RowAction.addToAddressBook:
        final peer = _peerOf(id);
        if (peer != null) addPeersToAbDialog([Peer.copy(peer)]);

      case RowAction.editTags:
        editAbTagDialog(gFFI.abModel.getPeerTags(id), (tags) async {
          await gFFI.abModel.changeTagForPeers([id], tags);
          done();
        });

      case RowAction.editNote:
        editAbPeerNoteDialog(id);

      case RowAction.sharedPassword:
        final peer = _peerOf(id);
        if (peer != null) {
          setSharedAbPasswordDialog(gFFI.abModel.currentName.value, peer);
        }

      case RowAction.existIn:
        _showExistIn(id);

      case RowAction.forgetPassword:
        await gFFI.abModel.changePersonalHashPassword(id, '');
        await bind.mainForgetPassword(id: id);
        await _readSavedPasswords();
        done();

      case RowAction.removeFromAddressBook:
        await gFFI.abModel.deletePeers([id]);
        done();

      case RowAction.forgetMachine:
        // The old menu did one of these depending on which tab the card was
        // drawn on. One table has no tabs, and the confirmation the operator
        // agreed to says the machine leaves the list, so all of them run.
        await bind.mainRemovePeer(id: id);
        await bind.mainRemoveDiscovered(id: id);
        final favs = (await bind.mainGetFav()).toList();
        if (favs.remove(id)) await bind.mainStoreFav(favs: favs);
        for (final g in LabDeskGroupsModel.groups) {
          g.peers.remove(id);
        }
        LabDeskGroupsModel.peerIcons.remove(id);
        await LabDeskGroupsModel.saveGroups();
        await LabDeskGroupsModel.savePeerIcons();
        await bind.mainLoadRecentPeers();
        await bind.mainLoadFavPeers();
        await bind.mainLoadLanPeers();
        _savedPasswords.remove(id);
        done();
    }
  }

  /// Which address books already hold this machine. The peer card put this
  /// behind an "Exist in" entry, and the answer is only ever a list of names.
  void _showExistIn(String id) {
    final names = gFFI.abModel.idExistIn(id);
    gFFI.dialogManager.show((setState, close, context) => CustomAlertDialog(
          title: Text(translate('Also in')),
          content: Text(names.isEmpty ? translate('Empty') : names.join(', ')),
          actions: [dialogButton('OK', onPressed: close)],
          onSubmit: close,
          onCancel: close,
        ));
  }

  Widget _connectScreen(BuildContext context) {
    final machines = _machines;
    return ConnectScreen(
        machines: machines,
        capabilities: _capabilities(machines),
        onAction: _rowAction,
        // Same signal Fleet uses: genuinely loading only before anything has
        // been asked for.
        isLoading: machines.isEmpty && _lastRefreshed == null,
        groups: [
          for (final g in LabDeskGroupsModel.groups)
            (name: g.name, collapsed: g.collapsed)
        ],
        sets: _peerSets,
        initialId: _lastRemoteId,
        // The same call the peer page made, with the same three alternates.
        onConnect: (id, mode) {
          // An administrator terminal is an ordinary terminal session opened
          // with one environment variable set, which is how the peer card
          // asked for it too.
          if (mode == ConnectMode.terminalAdmin) setEnvTerminalAdmin();
          _connectVia(
            id,
            isFileTransfer: mode == ConnectMode.fileTransfer,
            isViewCamera: mode == ConnectMode.viewCamera,
            isTerminal: mode == ConnectMode.terminal ||
                mode == ConnectMode.terminalAdmin,
            isTcpTunneling: mode == ConnectMode.tcpTunneling,
            isRDP: mode == ConnectMode.rdp,
          );
        },
        onGroupCollapsed: (name, collapsed) {
          for (final g in LabDeskGroupsModel.groups) {
            if (g.name == name) {
              g.collapsed = collapsed;
              LabDeskGroupsModel.saveGroups();
              break;
            }
          }
        },
        // Discovery is a broadcast on the local network, so it goes out when
        // the operator asks for that set and not on every open.
        onPeerSetSelected: (id) {
          if (id == kSetDiscovered) bind.mainDiscover();
        },
    );
  }

  /// One settings page, with no navigation of its own.
  ///
  /// Mounting DesktopSettingPage whole put a second navigation rail beside the
  /// console's, which is two sidebars for one interface. Its pages are nested
  /// in the console's own sidebar instead, and only the body renders here.
  Widget _settings(BuildContext context) => Container(
        color: C.bg,
        child: settingsPageBody(_settingsTab),
      );

  /// Chat with every machine this client has a desktop session open to. The
  /// messages go through the session's own chat model, so the floating chat in
  /// the session window and this screen show one conversation.
  Widget _sessions(BuildContext context) => SessionsScreen(
        sessions: mergeSessionChats(_chats.values),
        selectedId: _openChatId,
        onSelect: (id) => setState(() {
          _openChatId = id;
          _readLines[id] = _chats[id]?.lines.length ?? 0;
        }),
        onSend: (id, text) async {
          final w = _remoteWindowOf[id];
          if (w == null) {
            showToast('That session has closed.');
            return;
          }
          final ok = await _ask(
              w, kLabDeskRpcChatSend, jsonEncode({'id': id, 'text': text}));
          if (ok != true) showToast('The session window could not send that.');
          _pollSessions();
        },
      );

  /// The name the far side is shown when this client connects. It lives in the
  /// account payload the client keeps under `user_info`, so it is merged into
  /// that rather than replacing it. Rust reads `display_name` first and falls
  /// back to the OS user name, which is what this exists to replace.
  String get _displayName {
    try {
      final j = jsonDecode(bind.mainGetLocalOption(key: 'user_info'));
      if (j is Map) {
        final d = (j['display_name'] as String?)?.trim();
        if (d != null && d.isNotEmpty) return d;
        final n = (j['name'] as String?)?.trim();
        if (n != null && n.isNotEmpty) return n;
      }
    } catch (_) {}
    return '';
  }

  void _editDisplayName() {
    renameDialog(
      oldName: _displayName,
      onSubmit: (name) async {
        Map<String, dynamic> info = {};
        try {
          final j = jsonDecode(bind.mainGetLocalOption(key: 'user_info'));
          if (j is Map) info = Map<String, dynamic>.from(j);
        } catch (_) {}
        info['display_name'] = name.trim();
        await bind.mainSetLocalOption(key: 'user_info', value: jsonEncode(info));
        if (mounted) setState(() {});
      },
    );
  }

  Widget _thisMachine(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Consumer<ServerModel>(
        builder: (context, model, _) => ThisMachineScreen(
          machineId: model.serverId.text,
          password: model.serverPasswd.text,
          passwordIsTemporary:
              model.verificationMethod != kUsePermanentPassword,
          serviceRunning: model.isStart,
          profileSwitcher: const ServerProfileSwitcher(),
          // Enrolment is the machine's own consent to be owned, so the token
          // is pasted here, at the machine, and the privileged process spends
          // it (src/labdesk/labnet.rs).
          enrol: MachineEnrolCard(
            enrol: (token) => bind.mainAgentEnrol(token: token),
          ),
          labnet: LabnetCard(
            state: _labnet,
            onEnable: _enableLabnet,
            onDisable: _disableLabnet,
          ),
          selfHeal: SelfHealCard(
            on: _selfHealOn,
            reachability:
                _netViews[_machineIdOfPeer(_thisPeerId)]?.reachability ??
                    NetReachability.unknown,
            // Only a machine that reports at all can be waited on. One that
            // has never sent a network view is not "waiting for the service";
            // it is a machine nobody is hearing from, and the card says that.
            waiting: _selfHealWaiting &&
                _netViews.containsKey(_machineIdOfPeer(_thisPeerId)),
            onChanged: _setSelfHeal,
          ),
          // Both of these existed on the old left rail and would have been lost
          // in the move. The catalogue of the old interface is what caught it.
          onRefreshPassword: () => bind.mainUpdateTemporaryPassword(),
          onEditPassword: () => _goToSettings(SettingsTabKey.safety),
          displayName: _displayName,
          onEditDisplayName: _editDisplayName,
          onStartService: model.isStart ? null : () => start_service(true),
        ),
      ),
    );
  }

  /// The switch is one option. The daemon re-reads its own config file every
  /// tick, so nothing else has to be told (`selfheal.rs::enabled`); what the
  /// card shows beside the switch is the step the daemon reported, which is why
  /// it says it is waiting until the machine's next uplink carries one.
  Future<void> _setSelfHeal(bool on) async {
    setState(() {
      _selfHealOn = on;
      _selfHealWaiting = true;
    });
    await bind.mainSetOption(key: kSelfHealOption, value: on ? 'Y' : '');
    await _pollNetViews();
  }

  void _initLabnet() {
    // The bundled netbird is driven by the privileged process, which knows
    // where it is and owns its service, so nothing here needs a path or a
    // prompt.
    _daemon = OverlayDaemon(
      call: (action, setupKey, managementUrl) => bind.mainOverlayDaemon(
          action: action, setupKey: setupKey, managementUrl: managementUrl),
    );
    _broker = OverlayBroker(
      baseUrl: 'https://lab-desk.net',
      token: () => bind.mainGetLocalOption(key: 'access_token'),
      // The machine plane's credential. The console cannot make it: the agent
      // key is kept where an interactive user cannot read it
      // (src/labdesk/identity.rs), so the privileged process signs over IPC
      // and only the three headers come back.
      sign: (method, path, body) async => MachineSignature.decode(
          await bind.mainAgentSign(method: method, path: path, body: body)),
      peerId: () => _thisPeerId,
      machineIdOf: _machineIdOfPeer,
    );
    _enrolment = OverlayEnrolment(
      daemon: _daemon,
      broker: _broker,
      setOption: (k, v) => bind.mainSetOption(key: k, value: v),
      identity: () async =>
          (await bind.mainGetIdPk(), await bind.mainGetDirectAccessPort()),
    );
    _enrolment.states.listen((s) {
      if (mounted) setState(() => _labnet = s);
    });
    _overlay = OverlaySession(
      broker: _broker,
      daemon: _daemon,
      setOption: (k, v) => bind.mainSetOption(key: k, value: v),
    );
    // What the daemon says now, so a machine enrolled last week opens as On.
    _daemon.status().then((s) {
      if (!mounted || !s.isUp) return;
      setState(
          () => _labnet = LabnetCardState(LabnetPhase.on, ip: bareIp(s.ip)));
    });
    _inboxTick =
        Timer.periodic(const Duration(seconds: 15), (_) => _pollInbox());
    WidgetsBinding.instance.addPostFrameCallback((_) => _pollInbox());
  }

  bool get _signedIn =>
      bind.mainGetLocalOption(key: 'access_token').isNotEmpty;

  /// This machine's own peer id, as the server holds it.
  ///
  /// `serverModel.serverId` is an `IDTextEditingController`, so its `text` is
  /// what the box on screen shows: "1 180 573 903", spaces and all. Comparing
  /// that with a `machine.peerId` matched nothing, so the console never
  /// recognised itself -- the self-healing card could not report, the Network
  /// section opened on somebody else's machine, and the labnet broker named
  /// this machine to the server with the spaces in it (homebox-devserver,
  /// 2026-09-05). `trimID` is the same function the connect box uses.
  String get _thisPeerId => trimID(gFFI.serverModel.serverId.text);

  /// The `machine.id` lab-desk.net names [peerId] by, or empty when the
  /// organization's machine list holds no such peer. Empty rather than the peer
  /// id itself: a machine the server cannot name is one it must refuse.
  String _machineIdOfPeer(String peerId) {
    for (final m in _orgMachines) {
      if (m.peerId == peerId) return m.id;
    }
    return '';
  }

  /// The organization's machines, the invitations waiting on this machine and
  /// the labnets the account manages, read every 15 s while signed in, like the
  /// client's own heartbeat. The account is what both halves of the read are
  /// scoped by, so a console with nobody signed in polls nothing.
  Future<void> _pollInbox() async {
    if (!mounted) return;
    if (!_signedIn) {
      _forgetAccountData();
      return;
    }
    // THE TWO READS ARE SEPARATE, and that is the whole point of this shape.
    // The machines are the organization's; the inbox is labnet's, and labnet is
    // a subsystem a server need not have at all -- lab-desk.net answers
    // `/agent/overlay/inbox` 503 "labnet is not set up on this server yet" when
    // no NetBird is configured for it. Reading both inside one `try` meant that
    // 503 threw past the assignment below, so the console lost the whole
    // organization over a feature nobody had asked for: an empty health board,
    // no adapters, no self-healing report and no machine picker, with one red
    // line on the Network page as the only sign (homebox-devserver,
    // 2026-09-05).
    final List<OrgMachine> machines;
    try {
      // First, because it is the map every labnet call names a machine
      // through and the inbox is rendered against it. `?state=1` rides the same
      // answer, so the fleet's figures cost no extra request.
      machines = await _broker.machines();
    } on OverlayBrokerException catch (e) {
      _reportBrokerFailure(e);
      return;
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _orgMachines = machines;
      _orgByPeer = {
        for (final m in machines)
          if (m.peerId.isNotEmpty) m.peerId: m
      };
      _recordHistory(machines, DateTime.now());
      if (_netMachineId.isEmpty ||
          !machines.any((m) => m.id == _netMachineId)) {
        _netMachineId = _machineIdOfPeer(_thisPeerId);
        if (_netMachineId.isEmpty && machines.isNotEmpty) {
          _netMachineId = machines.first.id;
        }
      }
    });
    try {
      final inbox = await _broker.inbox();
      if (!mounted) return;
      setState(() {
        _inbox = inbox;
        _labnetError = '';
      });
      await _maybeAskConsent(inbox);
    } on OverlayBrokerException catch (e) {
      _reportBrokerFailure(e);
    } catch (_) {}
    await _pollDetail();
    await _pollNetViews();
    if (!_fleetsRead) await _readFleets();
  }

  /// A sign-in that no longer holds is the account surface's to report, and the
  /// previous account's machines must not stay on screen. Anything else is a
  /// message for the labnet surface.
  void _reportBrokerFailure(OverlayBrokerException e) {
    if (e.signInAgain) {
      _forgetAccountData();
    } else if (mounted) {
      setState(() => _labnetError = e.message);
    }
  }

  /// One machine a cycle: its own hot row, and the first time round its stored
  /// history. Bounded on purpose, so a fleet of two hundred machines costs one
  /// extra request every fifteen seconds rather than two hundred.
  Future<void> _pollDetail() async {
    if (_orgMachines.isEmpty) return;
    _detailCursor = (_detailCursor + 1) % _orgMachines.length;
    final m = _orgMachines[_detailCursor];
    try {
      final state = await _broker.machineState(m.id);
      if (!mounted) return;
      setState(() => _detail[m.id] = state);
    } catch (_) {}
    if (_backfilled.contains(m.id) || m.peerId.isEmpty) return;
    _backfilled.add(m.id);
    try {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final samples = await _broker.metrics(m.id,
          from: now - const Duration(hours: 12).inSeconds, to: now);
      if (!mounted || samples.isEmpty) return;
      setState(() {
        final history = MetricHistory();
        for (final s in samples) {
          history.add(s);
        }
        // Anything the live poll already recorded is newer than what the
        // server stored, so it goes back on the end rather than being lost.
        for (final s in _history[m.peerId]?.samples ?? const <MetricSample>[]) {
          if (samples.isEmpty || s.at.isAfter(samples.last.at)) history.add(s);
        }
        _history[m.peerId] = history;
      });
    } catch (_) {}
  }

  /// The network view for the machine whichever section is open is showing,
  /// and nothing else: the adapter list is read where it is rendered.
  Future<void> _pollNetViews() async {
    final wanted = <String>{
      if (_section == ConsoleSection.network && _netMachineId.isNotEmpty)
        _netMachineId,
      if (_section == ConsoleSection.thisMachine) _machineIdOfPeer(_thisPeerId),
    }..remove('');
    for (final id in wanted) {
      try {
        final view = await _broker.netView(id);
        if (!mounted) return;
        setState(() {
          _netViews[id] = view;
          if (id == _machineIdOfPeer(_thisPeerId) &&
              view.reachability.selfHealRunning == _selfHealOn) {
            _selfHealWaiting = false;
          }
        });
      } catch (_) {}
    }
  }

  /// The fleets, read once per sign-in. Only a technician narrowed to more than
  /// one fleet is ever asked which one a new labnet belongs to.
  Future<void> _readFleets() async {
    try {
      final ids = await _broker.fleetIds();
      final fleets = await _broker.fleets();
      if (!mounted) return;
      setState(() {
        _fleets = fleets;
        _mustNameFleet = ids != null && ids.length > 1;
        // Read once per sign-in, not once per poll: an organization with no
        // fleets would otherwise be asked twice every fifteen seconds for ever.
        _fleetsRead = true;
      });
    } catch (_) {}
  }

  /// One reading per machine per uplink. The fleet poll runs every fifteen
  /// seconds and a machine flushes every five minutes by default, so without
  /// the stamp the same reading would be recorded twenty times over.
  void _recordHistory(List<OrgMachine> machines, DateTime now) {
    for (final m in machines) {
      final seen = m.state.seenAt;
      if (m.peerId.isEmpty || seen == null) continue;
      if (_historyAt[m.id] == seen) continue;
      final sample = m.state.sampleAt(
          DateTime.fromMillisecondsSinceEpoch(seen * 1000, isUtc: true)
              .toLocal());
      if (sample == null) continue;
      _historyAt[m.id] = seen;
      _history.putIfAbsent(m.peerId, MetricHistory.new).add(sample);
    }
  }

  /// Drops everything read under an account that no longer holds, so a
  /// revoked session or a sign-out never leaves another account's labnets,
  /// member addresses or machine names on screen or in the peer map.
  void _forgetAccountData() {
    if (!mounted) return;
    if (_orgMachines.isEmpty && _inbox == LabnetInbox.empty) return;
    setState(() {
      _orgMachines = const <OrgMachine>[];
      _orgByPeer = const <String, OrgMachine>{};
      _inbox = LabnetInbox.empty;
      _labnetError = '';
      _detail.clear();
      _netViews.clear();
      _backfilled.clear();
      _historyAt.clear();
      _history.clear();
      _fleets = const <OrgFleet>[];
      _mustNameFleet = false;
      _fleetsRead = false;
    });
  }

  /// The one prompt: asked once per machine, only while signed in, never
  /// again once answered or enrolled.
  Future<void> _maybeAskConsent(LabnetInbox inbox) async {
    final asked = bind.mainGetLocalOption(key: _kConsentKey) == 'asked';
    if (!shouldAskLabnetConsent(
        signedIn: _signedIn,
        consentAsked: asked,
        enrolled: inbox.enrolled || _labnet.phase == LabnetPhase.on)) {
      return;
    }
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.surface,
        title: Text('Encrypted direct connections', style: C.h2()),
        content: SizedBox(
          width: 440,
          child: Text(
            'Machines on your account can open a direct encrypted path to '
            'this one instead of going through an ID server. Nothing else can '
            'reach it that way. You can turn this off under This machine at '
            'any time.',
            style: C.body(),
          ),
        ),
        actions: [
          _dialogAction('Not now', () => Navigator.of(ctx).pop(false)),
          const SizedBox(width: 16),
          _dialogAction('Turn on', () => Navigator.of(ctx).pop(true)),
        ],
      ),
    );
    // Recorded once the person has actually answered, so a console closed
    // while the first poll was in flight does not spend the only prompt.
    if (yes == null) return;
    await bind.mainSetLocalOption(key: _kConsentKey, value: 'asked');
    if (yes) _enableLabnet();
  }

  Widget _dialogAction(String label, VoidCallback onTap) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              label,
              style: C.small(color: C.textMuted).copyWith(
                decoration: TextDecoration.underline,
                decorationColor: C.textFaint,
              ),
            ),
          ),
        ),
      );

  Future<void> _enableLabnet() async {
    if (_labnet.phase == LabnetPhase.working) return;
    await _enrolment.enable();
    await _pollInbox();
  }

  Future<void> _disableLabnet() async {
    if (_labnet.phase == LabnetPhase.working) return;
    await _enrolment.disable();
    // Every per-peer hint the session service wrote goes with the labnet, or
    // the next connect to each of those peers dials a dead address first.
    final opts = jsonDecode(bind.mainGetOptionsSync()) as Map<String, dynamic>;
    for (final k in opts.keys) {
      if (k.startsWith(kOverlayAddrOption) || k.startsWith(kOverlayPkOption)) {
        await bind.mainSetOption(key: k, value: '');
      }
    }
    await _pollInbox();
  }

  /// Every way the console opens a session goes through here. With the direct
  /// path on, lab-desk.net is asked for the grant and the target is waited for
  /// before the client dials; without it, or if anything short of that
  /// happens, the session goes the way it always has.
  Future<void> _connectVia(
    String id, {
    bool isTerminal = false,
    bool isFileTransfer = false,
    bool isViewCamera = false,
    bool isTcpTunneling = false,
    bool isRDP = false,
  }) async {
    if (_labnet.phase == LabnetPhase.on) await _overlay.prepare(id);
    if (!mounted) return;
    connect(
      context,
      id,
      isTerminal: isTerminal,
      isFileTransfer: isFileTransfer,
      isViewCamera: isViewCamera,
      isTcpTunneling: isTcpTunneling,
      isRDP: isRDP,
    );
  }

  Future<void> _labnetDo(Future<void> Function() action) async {
    setState(() {
      _labnetBusy = true;
      _labnetError = '';
    });
    try {
      await action();
    } on OverlayBrokerException catch (e) {
      // Turning full access on, deleting a labnet and minting an enrolment
      // token are refused on a console token older than five minutes, and the
      // console's token is usually hours old. Signing in again mints a fresh
      // one; the request is then the same request, so it is simply retried.
      if (e.needsFreshSignIn && mounted && await loginDialog() == true) {
        try {
          await action();
        } on OverlayBrokerException catch (e2) {
          _labnetError = e2.message;
        } catch (e2) {
          _labnetError = '$e2';
        }
      } else {
        _labnetError = e.message;
      }
    } catch (e) {
      _labnetError = '$e';
    }
    if (mounted) setState(() => _labnetBusy = false);
    await _pollInbox();
  }

  /// The Network section speaks `machine.id`: it is what the members of a
  /// labnet come back as and what every route that names a machine resolves,
  /// so the machines offered and this machine itself are named the same way
  /// rather than by the peer id the rest of the console uses.
  Widget _network(BuildContext context) => NetworkScreen(
        inbox: _inbox,
        thisMachineId: _machineIdOfPeer(_thisPeerId),
        machines: [
          for (final m in _orgMachines)
            NetworkMachine(id: m.id, name: m.name),
        ],
        fleets: [
          for (final f in _fleets) NetworkFleet(id: f.id, name: f.name),
        ],
        mustNameFleet: _mustNameFleet,
        netView: _netViews[_netMachineId] ?? MachineNetView.empty,
        netMachineId: _netMachineId,
        netBusy: !_netViews.containsKey(_netMachineId),
        onSelectNetMachine: (id) {
          setState(() => _netMachineId = id);
          _pollNetViews();
        },
        busy: _labnetBusy,
        error: _labnetError,
        onCreate: (name, fleetId) =>
            _labnetDo(() => _broker.createLabnet(name, fleetId: fleetId)),
        onRename: (id, name) => _labnetDo(() => _broker.renameLabnet(id, name)),
        onApprove: (id) => _labnetDo(() => _broker.decide(id, approve: true)),
        onDecline: (id) => _labnetDo(() => _broker.decide(id, approve: false)),
        onInvite: (l, d) => _labnetDo(() => _broker.invite(l, d)),
        onFullAccess: (l, on) => _labnetDo(() => _broker.setFullAccess(l, on)),
        onLeave: (l) => _labnetDo(() => _broker.leave(l)),
        onRemove: (l, d) => _labnetDo(() => _broker.removeMember(l, d)),
        onDelete: (l) => _labnetDo(() => _broker.deleteLabnet(l)),
      );

  @override
  Widget build(BuildContext context) {
    final machines = _machines;
    return Container(
      color: C.bg,
      child: Stack(
        children: [
          // The old home page, mounted and never painted.
          //
          // Its widget tree is replaced by the console, but its State owned
          // work nothing else does: it registers the main window's
          // multi-window method handler (show, hide, move a tab to a new
          // window, open a monitor session, report remote window coords), the
          // stop-service flag that ConnectionPage and Settings resolve with
          // Get.find, the uni-links subscription, the macOS permission
          // watches, and the once-a-second fetch of this machine's own id.
          //
          // Reimplementing that was the alternative, and reimplementing a
          // lifecycle by reading it is how the three defects a critique found
          // in this rebuild got there in the first place. Mounting it offstage
          // keeps every one of those responsibilities exactly as it was while
          // the console owns the whole visible interface.
          //
          // What this deliberately does NOT restore is the page's own visible
          // parts: the install prompt, the macOS permission cards, the update
          // banner and the system error banner. Those are real interface and
          // belong in the console; they are named in docs/CONSOLE.md as
          // outstanding rather than quietly dropped.
          const Offstage(offstage: true, child: DesktopHomePage()),
          Column(children: [
            _installBanner(),
            _updateBanner(),
            Expanded(child: ConsoleShell(
        machines: machines,
        healthMachines: _fleetRows,
        samples: labdeskStatus.samples,
        profiles: _profiles,
        profileName: ServerProfilesModel.active.value,
        // activate() rewrites the live server keys, saves, and asks the ID
        // server again, which is exactly what the old home-screen dropdown did.
        onProfileSelected: (name) async {
          await ServerProfilesModel.activate(name);
          if (mounted) setState(() {});
        },
        isRefreshing: _refreshing || labdeskStatus.isQuerying,
        // The fleet is only genuinely loading before anything has been asked.
        isLoading: machines.isEmpty && _lastRefreshed == null,
        // Stamped when the server answered, not when the button was pressed:
        // a query that never came back must not read as a fresh check.
        lastRefreshed: labdeskStatus.lastResponseAt,
        onRefresh: _refresh,
        // Actions that need a session need a desktop session; the terminal
        // screen needs a terminal. Health counts either as "connected".
        connectedIds: _remoteWindowOf.keys.toSet(),
        // A shell is available through a terminal window or the console's link;
        // the link opens on demand, so every machine with a saved password
        // counts.
        terminalIds: {
          ..._terminalWindowOf.keys,
          ...LabDeskMachineLink.openIds,
          ..._savedPasswords,
        },
        healthFor: _healthFor,
        terminalLinesFor: (id) => _terminalLines[id] ?? const [],
        onTerminalSubmit: _terminalSubmit,
        onRunAction: _runAction,
        sectionRequest: _sectionRequest,
        onSectionChanged: (s) {
          // The adapter list is read for whichever section is showing it, so
          // the section that has just opened asks now rather than waiting out
          // the fifteen second poll behind a card that says "Reading...".
          setState(() => _section = s);
          _pollNetViews();
        },
        subItems: {
          ConsoleSection.settings: [
            for (final p in settingsPages())
              ConsoleSubItem(id: p.key.name, label: p.label, icon: p.icon),
          ],
        },
        selectedSubItem: _settingsTab.name,
        onSubItemSelected: (section, id) {
          if (section != ConsoleSection.settings) return;
          for (final p in settingsPages()) {
            if (p.key.name == id) {
              setState(() => _settingsTab = p.key);
              break;
            }
          }
        },
            hosted: {
              ConsoleSection.connect: _connect,
              ConsoleSection.thisMachine: _thisMachine,
              ConsoleSection.settings: _settings,
              ConsoleSection.sessions: _sessions,
              ConsoleSection.automation: _automationScreen,
              ConsoleSection.tools: _toolsScreen,
              ConsoleSection.network: _network,
            },
          )),
          ]),
        ],
      ),
    );
  }

  /// Running without being installed means no always-on service, no unattended
  /// access to this machine, and no in-place updates. The stock home page
  /// carried this card; the console owns it now.
  Widget _installBanner() {
    final needsInstall = isWindows && !bind.isDisableInstallation() && !bind.mainIsInstalled();
    final needsDaemon = isMacOS && bind.mainIsInstalled() && !bind.mainIsInstalledDaemon(prompt: false);
    if (!needsInstall && !needsDaemon) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.error.withOpacity(0.10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(children: [
          Icon(Icons.shield_outlined, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              needsInstall
                  ? translate('LabDesk is running without being installed. Install it to run as an always-on service, accept connections while nobody is signed in, and update itself.')
                  : translate('The background service is not installed. Install it so this machine stays reachable.'),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          TextButton(
            onPressed: () => needsInstall ? bind.mainGotoInstall() : bind.mainIsInstalledDaemon(prompt: true),
            child: Text(translate('Install')),
          ),
        ]),
      ),
    );
  }

  /// A new version is available from lab-desk.net. The core sets
  /// [stateGlobal.updateUrl] after its check on start and once a day; the
  /// banner offers the in-app update the stock client already implements
  /// (download, then a one-time elevation to install and relaunch).
  Widget _updateBanner() => Obx(() {
        final url = stateGlobal.updateUrl.value;
        if (url.isEmpty || _updateDismissed) return const SizedBox.shrink();
        final version = url.substring(url.lastIndexOf('/') + 1);
        final theme = Theme.of(context);
        return Material(
          color: theme.colorScheme.primary.withOpacity(0.12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(children: [
              Icon(Icons.system_update_alt, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${translate('LabDesk')} $version ${translate('is available. Update installs in place and relaunches.')}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: () => handleUpdate(url),
                child: Text(translate('Update now')),
              ),
              TextButton(
                onPressed: () => setState(() => _updateDismissed = true),
                child: Text(translate('Later')),
              ),
            ]),
          ),
        );
      });
  bool _updateDismissed = false;
}
