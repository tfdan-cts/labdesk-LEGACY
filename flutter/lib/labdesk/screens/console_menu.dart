/// The console's own menu surface.
///
/// Only the *route* is borrowed from Material - the barrier, the escape key,
/// the focus scope and the off-screen clamping, all of which are worth reusing
/// and none of which are visible. Everything inside the panel is drawn to this
/// console's rules instead, because Material's own entry is unmistakable: a 48
/// pixel row, a 16 pixel gutter, an elevation tint over the fill and an ink
/// wash on hover. A console that draws its own table and its own glyphs and
/// then opens a Material menu on top of them has only moved the seam.
///
/// The entries are plain values rather than widgets so the screen that owns a
/// menu can decide what it offers - and be tested on that decision - without
/// building any of it.
library;

import 'package:flutter/material.dart';

import '../theme/console_theme.dart';
import '../theme/ld_icons.dart';

/// Panel width. Fixed rather than intrinsic: a menu that changes width as its
/// contents change between rows reads as a different menu each time.
const double _panelWidth = 258;

const double _itemHeight = 30;
const double _headingHeight = 24;
const double _splitHeight = 7;

sealed class ConsoleMenuEntry<T> {
  const ConsoleMenuEntry();
}

/// A line that does something.
class ConsoleMenuAction<T> extends ConsoleMenuEntry<T> {
  const ConsoleMenuAction(
    this.value,
    this.label, {
    this.checked,
    this.danger = false,
    this.glyph,
  });

  final T value;
  final String label;

  /// An [LdIcons] path drawn before the label, so a long menu can be scanned
  /// by shape as well as read. Lines without one still start their text at
  /// the same column as lines with one.
  final String? glyph;

  /// Non-null turns the line into a toggle carrying this state, which is what
  /// a setting that is on or off has to look like. Null is an ordinary action.
  final bool? checked;

  /// Irreversible, or destroys something the operator entered. Drawn apart
  /// from the rest so it cannot be picked by muscle memory.
  final bool danger;
}

/// A small caps label over a run of related entries. The same treatment the
/// table header uses, so the menu reads as part of the same object.
class ConsoleMenuHeading<T> extends ConsoleMenuEntry<T> {
  const ConsoleMenuHeading(this.label);

  final String label;
}

/// A hairline between two runs.
class ConsoleMenuSplit<T> extends ConsoleMenuEntry<T> {
  const ConsoleMenuSplit();
}

/// Opens [entries] under the widget that owns [context] and resolves to the
/// value picked, or null if the menu was dismissed.
Future<T?> showConsoleMenu<T>({
  required BuildContext context,
  required List<ConsoleMenuEntry<T>> entries,
}) {
  final box = context.findRenderObject() as RenderBox;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  // Anchored four pixels under the control. Material right-aligns the panel on
  // its own once the control sits nearer the right edge than the left, which
  // is where a table's row menu always is.
  final anchor = RelativeRect.fromRect(
    Rect.fromPoints(
      box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero) + const Offset(0, 4),
          ancestor: overlay),
    ),
    Offset.zero & overlay.size,
  );

  final glyphs =
      entries.any((e) => e is ConsoleMenuAction<T> && e.glyph != null);
  return showMenu<T>(
    context: context,
    position: anchor,
    color: C.of(context).surfaceHi,
    // Material tints an elevated surface toward the primary colour. The
    // console's surfaces are a fixed ladder, and a menu that sits a shade
    // purple over the panel behind it is not on that ladder.
    surfaceTintColor: Colors.transparent,
    // Depth, not a black outline. Material draws the shadow from the
    // elevation, so a tight one at full strength reads as a stroke around the
    // panel rather than as the panel sitting above the table.
    shadowColor: const Color(0x59000000),
    elevation: 18,
    constraints:
        const BoxConstraints(minWidth: _panelWidth, maxWidth: _panelWidth),
    shape: RoundedRectangleBorder(
      borderRadius: C.rounded,
      side: BorderSide(color: C.of(context).hairline),
    ),
    items: [
      for (final e in entries)
        switch (e) {
          ConsoleMenuAction<T>() =>
            _ConsoleMenuItem<T>(entry: e, glyphColumn: glyphs),
          ConsoleMenuHeading<T>() => _ConsoleMenuHeading<T>(label: e.label),
          ConsoleMenuSplit<T>() => _ConsoleMenuSplit<T>(),
        },
    ],
  );
}

class _ConsoleMenuItem<T> extends PopupMenuEntry<T> {
  const _ConsoleMenuItem({required this.entry, this.glyphColumn = false});

  final ConsoleMenuAction<T> entry;

  /// Whether any line in this menu carries a glyph, so the ones that do not
  /// reserve the same space and every label sits on one column.
  final bool glyphColumn;

  @override
  double get height => _itemHeight;

  @override
  bool represents(T? value) => value == entry.value;

  @override
  State<_ConsoleMenuItem<T>> createState() => _ConsoleMenuItemState<T>();
}

class _ConsoleMenuItemState<T> extends State<_ConsoleMenuItem<T>> {
  bool _hover = false;
  bool _focused = false;

  void _pick() => Navigator.pop(context, widget.entry.value);

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final lit = _hover || _focused;
    // A menu's lines are its content, so they are set at full strength and
    // the hover says where the pointer is with the fill, not by dimming the
    // rest of the list.
    final fg = e.danger ? C.of(context).bad : C.of(context).text;

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          _pick();
          return null;
        }),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _pick,
        child: Container(
          height: _itemHeight,
          margin: const EdgeInsets.symmetric(horizontal: 5),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: !lit
                ? Colors.transparent
                : (e.danger ? C.of(context).bad : C.of(context).accent).withOpacity(0.12),
            borderRadius: C.roundedSm,
            border: Border.all(
              color:
                  _focused ? (e.danger ? C.of(context).bad : C.of(context).accent) : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              if (widget.glyphColumn) ...[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: e.glyph == null
                      ? null
                      : LdIcon(e.glyph!,
                          size: 14, color: e.danger ? C.of(context).bad : C.of(context).textMuted),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  e.label,
                  overflow: TextOverflow.ellipsis,
                  style: C.of(context).small(color: fg, w: FontWeight.w500),
                ),
              ),
              if (e.checked != null) ...[
                const SizedBox(width: 10),
                // The console's toggle, not a smaller one drawn for menus. The
                // row is the hit area, so the pill takes no handler — but it is
                // live, and painting it as disabled would say the opposite.
                LdToggle(value: e.checked!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ConsoleMenuHeading<T> extends PopupMenuEntry<T> {
  const _ConsoleMenuHeading({required this.label});

  final String label;

  @override
  double get height => _headingHeight;

  @override
  bool represents(T? value) => false;

  @override
  State<_ConsoleMenuHeading<T>> createState() => _ConsoleMenuHeadingState<T>();
}

class _ConsoleMenuHeadingState<T> extends State<_ConsoleMenuHeading<T>> {
  @override
  Widget build(BuildContext context) => Container(
        height: _headingHeight,
        alignment: Alignment.bottomLeft,
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 5),
        child: Text(
          widget.label.toUpperCase(),
          style: C.of(context).micro().copyWith(letterSpacing: 0.7),
        ),
      );
}

class _ConsoleMenuSplit<T> extends PopupMenuEntry<T> {
  const _ConsoleMenuSplit();

  @override
  double get height => _splitHeight;

  @override
  bool represents(T? value) => false;

  @override
  State<_ConsoleMenuSplit<T>> createState() => _ConsoleMenuSplitState<T>();
}

class _ConsoleMenuSplitState<T> extends State<_ConsoleMenuSplit<T>> {
  @override
  Widget build(BuildContext context) => Container(
        height: _splitHeight,
        margin: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        child: Container(height: 1, color: C.of(context).hairline),
      );
}

/// A control that opens a console menu.
///
/// Focus-traversable and activated by Enter or Space, with a ring the same
/// weight as the accent border everything else on this surface uses. A menu
/// reachable only by pointer is a menu half the operators do not have.
class ConsoleMenuButton<T> extends StatefulWidget {
  const ConsoleMenuButton({
    super.key,
    required this.entries,
    required this.onSelected,
    required this.tooltip,
    required this.builder,
  });

  /// Built at open time, so a menu always describes the machine as it is now.
  final List<ConsoleMenuEntry<T>> Function() entries;

  final ValueChanged<T> onSelected;
  final String tooltip;
  final Widget Function(bool focused, bool hovered) builder;

  @override
  State<ConsoleMenuButton<T>> createState() => _ConsoleMenuButtonState<T>();
}

class _ConsoleMenuButtonState<T> extends State<ConsoleMenuButton<T>> {
  bool _hover = false;
  bool _focused = false;

  Future<void> _open() async {
    final picked =
        await showConsoleMenu<T>(context: context, entries: widget.entries());
    if (picked != null) widget.onSelected(picked);
  }

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            _open();
            return null;
          }),
        },
        child: Tooltip(
          message: widget.tooltip,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _open,
            child: widget.builder(_focused, _hover),
          ),
        ),
      );
}
