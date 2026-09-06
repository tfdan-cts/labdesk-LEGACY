import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'console_theme.dart';
import 'ld_icons.dart';

/// The look of a settings page.
///
/// A settings page is a reading surface, not a dashboard: the operator is
/// scanning a column of decisions, one per line, and every one of them has the
/// same shape — a name on the left, the thing that changes it on the right, and
/// the explanation underneath in a quieter voice. Nothing here is a card. Boxes
/// inside boxes were the old page's whole structure and they turned a list of
/// twelve permissions into twelve framed panels.
///
/// These pieces take plain values and know nothing about the FFI, which is what
/// lets `tool/shots/settings_test.dart` render the real controls without a
/// session behind them.
class SettingsSkin {
  SettingsSkin._();

  /// A column of prose is unreadable at monitor width. Everything on a settings
  /// page is held to one measure, left-aligned against the sidebar.
  static const contentWidth = 720.0;

  static const pagePadding = EdgeInsets.fromLTRB(28, 20, 28, 40);

  /// The step used for a control that belongs to the row above it.
  static const indent = 26.0;

  static Color label(bool enabled, [BuildContext? context]) {
    final p = context == null ? ConsolePalette.dark : C.of(context);
    return enabled ? p.text : p.textFaint;
  }
}

/// The theme the settings pages run under.
///
/// Both embedded and standalone settings inherit their surrounding appearance.
/// The shared console theme also covers hosted Material controls and the
/// dropdown routes they open; settings adds only its control-specific details.
ThemeData settingsThemeData(BuildContext context) {
  final p = C.of(context);
  final base = C.theme(brightness: p.brightness);
  return base.copyWith(
    iconTheme: IconThemeData(color: p.textMuted, size: 18),
    dividerTheme: DividerThemeData(space: 1, thickness: 1, color: p.hairline),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? Colors.transparent
              : states.contains(WidgetState.selected)
                  ? p.accent
                  : Colors.transparent),
      checkColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled) ? p.textFaint : p.primaryFg),
      side: BorderSide(color: p.textFaint),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? p.textFaint
              : states.contains(WidgetState.selected)
                  ? p.accent
                  : p.textFaint),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? p.textFaint
              : states.contains(WidgetState.selected)
                  ? p.primaryFg
                  : p.textMuted),
      trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? Colors.transparent
              : states.contains(WidgetState.selected)
                  ? p.accent
                  : p.surfaceHi),
      trackOutlineColor: WidgetStatePropertyAll(p.textFaint),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: p.accent,
      inactiveTrackColor: p.hairline,
      thumbColor: p.accent,
      overlayColor: p.accent.withOpacity(.12),
      valueIndicatorColor: p.surfaceHi,
      valueIndicatorTextStyle: p.small(color: p.text),
      trackHeight: 3,
    ),
    listTileTheme: ListTileThemeData(
        textColor: p.text, iconColor: p.textMuted, selectedColor: p.accent),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent),
  );
}

/// The scrolling body of one settings page.
///
/// Owns the theme, the plane and the measure, so a page is a list of groups and
/// nothing else. Used by the console, by the standalone settings window and by
/// the shot, which is why the three cannot drift apart.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.children, this.controller});

  final List<Widget> children;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    return Theme(
      data: settingsThemeData(context),
      child: ColoredBox(
        color: p.bg,
        child: Scrollbar(
          controller: controller,
          child: ListView(
            controller: controller,
            padding: SettingsSkin.pagePadding,
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: SettingsSkin.contentWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
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

/// A named set of settings.
///
/// A title, its rows, and a hairline closing the group off from the next one.
/// The rule follows the group rather than leading it so the page opens on its
/// first title instead of on a stray line under the title bar, and so the last
/// group is closed rather than left hanging. No frame: the old page drew each
/// of these as a Material card and a page of twelve permissions became twelve
/// floating panels.
///
/// [trailing] carries the occasional control that belongs to the group as a
/// whole rather than to any one row.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.title,
    required this.children,
    this.explain,
    this.trailing,
  });

  final String title;
  final String? explain;
  final List<Widget> children;
  final List<Widget>? trailing;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: p.h2()),
                    if (explain != null) ...[
                      const SizedBox(height: 4),
                      Text(explain!, style: p.small(color: p.textFaint)),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...trailing!,
            ],
          ),
        ),
        ...children,
        const SizedBox(height: 16),
        Divider(height: 1, thickness: 1, color: p.hairline),
        const SizedBox(height: 20),
      ],
    );
  }
}

/// One decision: what it is on the left, what changes it on the right.
///
/// [explain] is the row's quiet second line. [control] may be null for a row
/// that is only a statement, and [onTap] makes the whole row the control's hit
/// area, which is what a label is for.
class SettingsRow extends StatefulWidget {
  const SettingsRow({
    super.key,
    required this.label,
    this.explain,
    this.control,
    this.onTap,
    this.enabled = true,
    this.indent = 0,
    this.leading,
    this.labelStyle,
    this.controlAbove = false,
  });

  final String label;
  final String? explain;
  final Widget? control;
  final VoidCallback? onTap;
  final bool enabled;
  final double indent;

  /// A mark that qualifies the label — the warning on a whitelist that is
  /// actually holding something back.
  final Widget? leading;
  final TextStyle? labelStyle;

  /// Put the control on its own line under the label. For controls too wide to
  /// sit beside one — a select, a directory path.
  final bool controlAbove;

  @override
  State<SettingsRow> createState() => _SettingsRowState();
}

class _SettingsRowState extends State<SettingsRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    // [enabled] colours the label; whether the row is a hit area is the
    // caller's decision, because a handful of rows in the pages this serves
    // stay tappable while their control is disabled.
    final tappable = widget.onTap != null;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          if (widget.leading != null) ...[
            widget.leading!,
            const SizedBox(width: 7)
          ],
          Flexible(
            child: Text(
              widget.label,
              style: widget.labelStyle ??
                  p.body(color: SettingsSkin.label(widget.enabled, context)),
            ),
          ),
        ]),
        if (widget.explain != null) ...[
          const SizedBox(height: 3),
          Text(widget.explain!, style: p.small(color: p.textFaint)),
        ],
      ],
    );

    final body = widget.controlAbove
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              text,
              if (widget.control != null) ...[
                const SizedBox(height: 9),
                widget.control!,
              ],
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: text),
              if (widget.control != null) ...[
                const SizedBox(width: 18),
                widget.control!,
              ],
            ],
          );

    return MouseRegion(
      cursor: tappable ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: tappable ? widget.onTap : null,
        child: AnimatedContainer(
          duration: C.fast,
          constraints: const BoxConstraints(minHeight: 44),
          padding: EdgeInsets.fromLTRB(widget.indent + 8, 9, 8, 9),
          decoration: BoxDecoration(
            color: _hover && tappable ? p.surface : Colors.transparent,
            borderRadius: C.roundedSm,
          ),
          child: Align(alignment: Alignment.centerLeft, child: body),
        ),
      ),
    );
  }
}

/// A settings page's toggle.
///
/// The drawing is [LdToggle], which is the console's one toggle and is shared
/// with the menus and the connection dialogs. This is only the settings page's
/// name for it: a disabled toggle on this surface is a toggle with no handler,
/// which is not true everywhere else.
class LdSwitch extends StatelessWidget {
  const LdSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => LdToggle(
        value: value,
        onChanged: onChanged,
        enabled: onChanged != null,
      );
}

/// One option in a radio group.
///
/// The ring and the label are one hit area; the group that owns them decides
/// what a selection means.
class LdRadioRow extends StatefulWidget {
  const LdRadioRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.explain,
    this.indent = 0,
    this.softWrap = true,
  });

  final String label;
  final String? explain;
  final bool selected;
  final VoidCallback? onTap;
  final double indent;
  final bool softWrap;

  @override
  State<LdRadioRow> createState() => _LdRadioRowState();
}

class _LdRadioRowState extends State<LdRadioRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: C.fast,
          constraints: const BoxConstraints(minHeight: 36),
          padding: EdgeInsets.fromLTRB(widget.indent + 8, 7, 8, 7),
          decoration: BoxDecoration(
            color: _hover && enabled ? p.surface : Colors.transparent,
            borderRadius: C.roundedSm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: LdRadioMark(selected: widget.selected, enabled: enabled),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.label,
                      overflow: widget.softWrap ? null : TextOverflow.ellipsis,
                      style:
                          p.body(color: SettingsSkin.label(enabled, context)),
                    ),
                    if (widget.explain != null) ...[
                      const SizedBox(height: 3),
                      Text(widget.explain!, style: p.small(color: p.textFaint)),
                    ],
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

/// The ring itself, so a radio drawn outside a row still matches one.
///
/// One size everywhere, and it is [LdCheckbox.size] with the same 1.4 ring: a
/// radio and a checkbox sit in the same column of a settings page and in the
/// same dialog body, so a radio a couple of pixels off the tick beside it reads
/// as a mistake rather than as a different kind of choice.
class LdRadioMark extends StatelessWidget {
  const LdRadioMark({super.key, required this.selected, this.enabled = true});

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    return AnimatedContainer(
      duration: C.fast,
      width: LdCheckbox.size,
      height: LdCheckbox.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          // [p.disabledBorder]'s rule: a locked radio keeps no accent at all.
          color:
              !enabled ? p.disabledBorder : (selected ? p.accent : p.textFaint),
          width: 1.4,
        ),
      ),
      child: Center(
        child: AnimatedContainer(
          duration: C.fast,
          width: selected ? 8 : 0,
          height: selected ? 8 : 0,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: !selected
                ? Colors.transparent
                : (enabled ? p.accent : p.textFaint),
          ),
        ),
      ),
    );
  }
}

/// A choice from a closed list.
///
/// [keys] are what gets stored, [values] what gets read; the pairing is the one
/// the pages already used, so a call site only changes shape, never meaning.
class LdSelect extends StatelessWidget {
  const LdSelect({
    super.key,
    required this.keys,
    required this.values,
    required this.initialKey,
    required this.onChanged,
    this.enabled = true,
    this.width = 260,
  });

  final List<String> keys;
  final List<String> values;
  final String initialKey;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final double width;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    var index = keys.indexOf(initialKey);
    if (index < 0) index = 0;
    if (values.isEmpty) return const SizedBox.shrink();
    final fg = enabled ? p.text : p.textFaint;

    // Aligned rather than sized alone: a settings page stretches its children
    // to the measure, and a select stretched to 720 pixels to hold the word
    // "Dark" is the tell of a control that was never given a width.
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: width,
        height: 34,
        padding: const EdgeInsets.only(left: 11, right: 8),
        decoration: BoxDecoration(
          color: enabled ? p.bg : Colors.transparent,
          borderRadius: C.roundedSm,
          border: Border.all(color: enabled ? p.textFaint : p.disabledBorder),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: index,
            isExpanded: true,
            isDense: true,
            borderRadius: C.rounded,
            dropdownColor: p.surface,
            focusColor: p.accent.withOpacity(.16),
            style: p.body(color: fg),
            icon: LdIcon(LdIcons.chevronDown,
                size: 15, color: enabled ? p.textMuted : p.textFaint),
            onChanged: enabled
                ? (i) {
                    if (i != null && i != index) onChanged(keys[i]);
                  }
                : null,
            selectedItemBuilder: (_) => [
              for (final v in values)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(v,
                      overflow: TextOverflow.ellipsis,
                      style: p.body(color: fg)),
                ),
            ],
            items: [
              for (var i = 0; i < values.length; i++)
                DropdownMenuItem<int>(
                  value: i,
                  child: Text(
                    values[i],
                    overflow: TextOverflow.ellipsis,
                    style: p.body(color: i == index ? p.accent : p.text),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A short typed value — a port, a timeout.
///
/// Set in the data face, because that is what a port number is.
class LdTextField extends StatelessWidget {
  const LdTextField({
    super.key,
    required this.controller,
    this.enabled = true,
    this.width = 110,
    this.hint,
    this.obscure = false,
    this.errorText,
    this.inputFormatters,
    this.onChanged,
    this.mono = true,
  });

  final TextEditingController controller;
  final bool enabled;
  final double width;
  final String? hint;
  final bool obscure;
  final String? errorText;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    final color = enabled ? p.text : p.textFaint;
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        enabled: enabled,
        obscureText: obscure,
        autocorrect: false,
        onChanged: onChanged,
        inputFormatters: inputFormatters,
        cursorColor: p.accent,
        cursorWidth: 1.5,
        style: mono ? p.data(size: 13, color: color) : p.body(color: color),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: mono
              ? p.data(size: 13, color: p.textFaint)
              : p.body(color: p.textFaint),
          errorText: (errorText?.isEmpty ?? true) ? null : errorText,
          errorStyle: p.small(color: p.bad),
          isDense: true,
          filled: true,
          fillColor: enabled ? p.bg : Colors.transparent,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          border: OutlineInputBorder(
              borderRadius: C.roundedSm,
              borderSide: BorderSide(color: p.hairline)),
          enabledBorder: OutlineInputBorder(
              borderRadius: C.roundedSm,
              borderSide: BorderSide(color: p.hairline)),
          disabledBorder: OutlineInputBorder(
              borderRadius: C.roundedSm,
              borderSide: BorderSide(color: p.hairline.withOpacity(0.6))),
          focusedBorder: OutlineInputBorder(
              borderRadius: C.roundedSm,
              borderSide: BorderSide(color: p.accent)),
          errorBorder: OutlineInputBorder(
              borderRadius: C.roundedSm, borderSide: BorderSide(color: p.bad)),
          focusedErrorBorder: OutlineInputBorder(
              borderRadius: C.roundedSm, borderSide: BorderSide(color: p.bad)),
        ),
      ),
    );
  }
}

/// What a button is for.
///
/// [danger] is not a colour choice: it is reserved for an action the operator
/// cannot take back, and it is the only place red appears on a settings page.
enum LdButtonKind { primary, quiet, danger }

/// A button, with the full state set.
class LdButton extends StatefulWidget {
  const LdButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = LdButtonKind.quiet,
    this.glyph,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onPressed;
  final LdButtonKind kind;

  /// A path from [LdIcons].
  final String? glyph;
  final String? tooltip;

  @override
  State<LdButton> createState() => _LdButtonState();
}

class _LdButtonState extends State<LdButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    final enabled = widget.onPressed != null;
    // [p.disabledBorder]'s rule, ahead of the kind: a disabled button of any
    // rank is an empty frame at the hairline under [p.textFaint]. A disabled
    // primary that kept a filled slab was still the loudest thing on the row.
    final (Color bg, Color fg, Color border) = !enabled
        ? (Colors.transparent, p.textFaint, p.disabledBorder)
        : switch (widget.kind) {
            // The shared filled primary. One tint, one foreground, same as the
            // installer's confirm and Connect's go.
            LdButtonKind.primary => (
                _down
                    ? p.primaryFillDown
                    : (_hover ? p.primaryFillHover : p.primaryFill),
                p.primaryFg,
                Colors.transparent,
              ),
            LdButtonKind.danger => (
                _hover ? p.bad.withOpacity(0.16) : Colors.transparent,
                p.bad,
                p.bad.withOpacity(0.5),
              ),
            LdButtonKind.quiet => (
                _hover ? p.surfaceHi : Colors.transparent,
                _hover ? p.text : p.textMuted,
                _hover ? p.hairline : p.hairline.withOpacity(0.6),
              ),
          };

    Widget button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: C.fast,
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _down ? 1 : 0, 0),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: C.roundedSm,
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.glyph != null) ...[
                LdIcon(widget.glyph!, size: 15, color: fg),
                const SizedBox(width: 7),
              ],
              Text(widget.label, style: p.small(color: fg, w: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}

/// A statement the page makes rather than a control: a path that is ready, a
/// requirement the machine does not meet, a licence.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text,
      {super.key, this.tone, this.indent = 0, this.selectable = false});

  final String text;
  final Color? tone;
  final double indent;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    final t = Text(text, style: p.body(color: tone ?? p.textMuted));
    return Padding(
      padding: EdgeInsets.fromLTRB(indent + 8, 7, 8, 7),
      child: selectable ? SelectionArea(child: t) : t,
    );
  }
}

/// A row that reads a value back: the label, then the value in the data face.
class SettingsFact extends StatelessWidget {
  const SettingsFact({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 160,
              child: Text(label, style: p.body(color: p.textMuted))),
          Expanded(
            child: SelectionArea(
              child: Text(value, style: p.data(size: 12.5, color: p.text)),
            ),
          ),
        ],
      ),
    );
  }
}

/// A link out of the application.
class SettingsLink extends StatefulWidget {
  const SettingsLink({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<SettingsLink> createState() => _SettingsLinkState();
}

class _SettingsLinkState extends State<SettingsLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: p.body(color: _hover ? p.text : p.accent),
              ),
              const SizedBox(width: 6),
              LdIcon(LdIcons.chevronRight,
                  size: 14, color: _hover ? p.text : p.accent),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bar that stands between the operator and a page of settings that can
/// weaken the machine.
///
/// The whole bar is the control, because the whole bar is the one thing it
/// offers. Its [label] is the page's own unlock string, unchanged.
class SettingsLockBar extends StatefulWidget {
  const SettingsLockBar(
      {super.key, required this.label, required this.onUnlock});

  final String label;
  final VoidCallback onUnlock;

  @override
  State<SettingsLockBar> createState() => _SettingsLockBarState();
}

class _SettingsLockBarState extends State<SettingsLockBar> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onUnlock,
        child: AnimatedContainer(
          duration: C.fast,
          margin: const EdgeInsets.only(bottom: 24),
          padding: const EdgeInsets.fromLTRB(14, 13, 13, 13),
          decoration: BoxDecoration(
            color: _hover ? p.surfaceHi : p.surface,
            borderRadius: C.rounded,
            border: Border.all(color: p.hairline),
          ),
          child: Row(
            children: [
              LdIcon(LdIcons.lock,
                  size: 17, color: _hover ? p.text : p.textMuted),
              const SizedBox(width: 11),
              Expanded(
                child: Text(widget.label,
                    style: p.body(color: _hover ? p.text : p.textMuted)),
              ),
              const SizedBox(width: 12),
              LdIcon(LdIcons.chevronRight,
                  size: 15, color: _hover ? p.text : p.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}
