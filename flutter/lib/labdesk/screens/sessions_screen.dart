import 'package:flutter/material.dart';

import '../models/chat_transcript.dart';
import '../theme/console_theme.dart';
import '../theme/ld_icons.dart';

/// Every session this machine is in, and what has been said in each.
///
/// Chat used to exist only inside a session: a floating panel in the window
/// holding an outgoing session, and a side page in the connection manager for
/// an incoming one. Both are still there and still work. This is the console's
/// view of the same conversations, so an operator with four sessions open does
/// not have to find four windows to read them.
///
/// Free of the FFI like every other console screen: the client hands the
/// transcripts in and takes submitted messages back out through [onSend],
/// which is what lets the whole surface render in the design harness with no
/// peer and no bridge.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({
    super.key,
    required this.sessions,
    this.onSend,
    this.selectedId,
    this.onSelect,
  });

  /// Ordered by the client — outgoing first, see [mergeSessionChats]. The
  /// screen does not sort, because a list that reorders itself under the
  /// pointer between polls cannot be clicked.
  final List<SessionChat> sessions;

  /// Null leaves the input disabled rather than absent: an operator reading a
  /// transcript should still see where a reply would go.
  final void Function(String sessionId, String text)? onSend;

  /// Which session is open. Null lets the screen keep its own selection, which
  /// is what the design harness does.
  final String? selectedId;
  final ValueChanged<String>? onSelect;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  String? _ownSelection;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The session on show: whatever the client says, else the last one picked
  /// here, else the first in the list. Falls back rather than going blank when
  /// the selected session ends, which happens the moment a window closes.
  SessionChat? get _selected {
    if (widget.sessions.isEmpty) return null;
    final wanted = widget.selectedId ?? _ownSelection;
    for (final s in widget.sessions) {
      if (s.id == wanted) return s;
    }
    return widget.sessions.first;
  }

  void _select(SessionChat s) {
    setState(() => _ownSelection = s.id);
    widget.onSelect?.call(s.id);
  }

  /// Lines in the open transcript at the last build, so a message arriving
  /// while it is being read scrolls into view instead of landing below the fold.
  int _lineCount = 0;

  @override
  void didUpdateWidget(covariant SessionsScreen old) {
    super.didUpdateWidget(old);
    final now = _selected?.lines.length ?? 0;
    if (now != _lineCount) {
      _lineCount = now;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _submit() {
    final session = _selected;
    final text = _input.text.trim();
    if (session == null || text.isEmpty || widget.onSend == null) return;
    widget.onSend!(session.id, text);
    _input.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sessions.isEmpty) return const _Empty();

    final selected = _selected!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 264,
            child: Panel(
              title: 'Sessions',
              subtitle: widget.sessions.length == 1
                  ? '1 active'
                  : '${widget.sessions.length} active',
              padding: EdgeInsets.zero,
              fill: true,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: widget.sessions.length,
                itemBuilder: (context, i) {
                  final s = widget.sessions[i];
                  return _SessionRow(
                    session: s,
                    selected: s.id == selected.id,
                    onTap: () => _select(s),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Panel(
              title: selected.peerLabel,
              subtitle: selected.isOutgoing
                  ? 'You connected to this machine'
                  : 'This machine was connected to',
              padding: EdgeInsets.zero,
              fill: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: selected.lines.isEmpty
                        ? Center(
                            child: Text(
                              'Nothing said yet. Anything typed here reaches '
                              'the session\'s own chat window as well.',
                              textAlign: TextAlign.center,
                              style: C.of(context).small(color: C.of(context).textFaint),
                            ),
                          )
                        : Scrollbar(
                            controller: _scroll,
                            child: ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                              itemCount: selected.lines.length,
                              itemBuilder: (context, i) =>
                                  _Line(line: selected.lines[i]),
                            ),
                          ),
                  ),
                  Divider(height: 1, thickness: 1, color: C.of(context).hairline),
                  _Compose(
                    controller: _input,
                    focus: _focus,
                    enabled: widget.onSend != null,
                    onSubmit: _submit,
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

/// One session in the left list.
class _SessionRow extends StatefulWidget {
  const _SessionRow({
    required this.session,
    required this.selected,
    required this.onTap,
  });

  final SessionChat session;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SessionRow> createState() => _SessionRowState();
}

class _SessionRowState extends State<_SessionRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final lit = widget.selected || _hover;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: 46,
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? C.of(context).accent.withOpacity(0.13)
                : (_hover ? C.of(context).surfaceHi : Colors.transparent),
            borderRadius: C.roundedSm,
          ),
          child: Row(
            children: [
              // Which way the session was opened, as a direction rather than a
              // second screen glyph: both kinds are sessions, and the only
              // thing worth telling apart at row size is who called whom.
              LdIcon(
                s.isOutgoing ? LdIcons.arrowRight : LdIcons.arrowDown,
                size: 16,
                color: lit ? C.of(context).accent : C.of(context).textFaint,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      s.peerLabel,
                      overflow: TextOverflow.ellipsis,
                      style: C.of(context).small(
                          color: lit ? C.of(context).text : C.of(context).textMuted,
                          w: FontWeight.w600),
                    ),
                    Text(
                      s.isOutgoing ? 'Outgoing' : 'Incoming',
                      style: C.of(context).micro(),
                    ),
                  ],
                ),
              ),
              if (s.unread > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: C.of(context).accent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text('${s.unread}',
                      style: C.of(context).micro(color: C.of(context).primaryFg)
                          .copyWith(fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.line});

  final ChatLine line;

  @override
  Widget build(BuildContext context) {
    // No bubbles and no avatars. This is a console, and a transcript reads
    // faster as a column of who-said-what than as a chat application dropped
    // into a panel.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 46,
            child: Text(
              line.isMine ? 'You' : 'Them',
              style: C.of(context).micro(color: line.isMine ? C.of(context).accent : C.of(context).textFaint),
            ),
          ),
          Expanded(
            child: SelectableText(
              line.text,
              style: C.of(context).body(color: line.isMine ? C.of(context).text : C.of(context).textMuted),
            ),
          ),
          const SizedBox(width: 10),
          Text(_clock(line.at), style: C.of(context).micro()),
        ],
      ),
    );
  }

  static String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
}

class _Compose extends StatelessWidget {
  const _Compose({
    required this.controller,
    required this.focus,
    required this.enabled,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool enabled;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      padding: const EdgeInsets.only(left: 18, right: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focus,
              enabled: enabled,
              onSubmitted: (_) => onSubmit(),
              style: C.of(context).body(),
              cursorColor: C.of(context).accent,
              cursorWidth: 1.6,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: enabled
                    ? 'Write a message'
                    : 'This session cannot be written to',
                hintStyle: C.of(context).small(color: C.of(context).textFaint),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GhostButton(
            label: 'Send',
            glyph: LdIcons.arrowRight,
            onPressed: enabled ? onSubmit : null,
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LdIcon(LdIcons.chat, size: 26, color: C.of(context).textFaint),
            const SizedBox(height: 14),
            Text('No session is active', style: C.of(context).h2()),
            const SizedBox(height: 6),
            SizedBox(
              width: 340,
              height: 34,
              child: Text(
                'Connect to a machine from Connect, or wait for somebody to '
                'connect to this one. Chat appears here while a session is open.',
                textAlign: TextAlign.center,
                style: C.of(context).small(color: C.of(context).textFaint),
              ),
            ),
          ],
        ),
      );
}
