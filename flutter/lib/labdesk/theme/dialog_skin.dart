import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'console_theme.dart';
import 'ld_icons.dart';

/// The look of every modal LabDesk raises.
///
/// A dialog is the one surface in this product that appears without being
/// asked for, on top of whatever the operator was doing, and usually because
/// something needs deciding: a password, a file that already exists, a machine
/// about to be restarted. So the rules here are stricter than anywhere else:
///
///   - One frame, for all of them: a title row, a hairline, the body, and the
///     answers in a footer. A message box is not a special shape and neither is
///     a two-word confirmation — the machine being deleted goes in the body
///     like every other thing a dialog is about.
///   - The question is the first thing on the surface and it is set at heading
///     weight. The consequence sits directly under it in full sentences, not
///     behind a tooltip or a "details" disclosure.
///   - A machine's identity — an id, a hostname, a path — is set in the
///     console's data face, because that is what somebody is about to compare
///     against the sticky note in their hand.
///   - The two answers weigh the same. A filled slab beside a grey outline
///     tells a hand that is already moving which one the product would prefer,
///     and on "restart this machine" or "overwrite this file" the product does
///     not get to have a preference. What the consequential answer carries
///     instead is a tinted frame, a tinted wash and a glyph.
///   - Destructive is the one thing allowed to look different in kind: it takes
///     the console's bad-news colour on its label as well as its frame, so it
///     cannot be mistaken for the ordinary answer at a glance.
///
/// Like the other skins in this directory these pieces take plain values and
/// know nothing about the FFI or about `common.dart` — translation happens at
/// the call site. That is what lets `tool/shots/dialogs_test.dart` render the
/// real dialogs without a session behind them, so what the shot shows is what
/// ships.
class DialogSkin {
  DialogSkin._();

  /// A dialog is read, so it is held to a measure rather than to whatever width
  /// its longest line wants. 460 is about 70 characters of [C.body].
  static const width = 460.0;

  /// The one a bare confirmation gets. Narrower, because a two-line question
  /// stretched to the full measure reads as an empty box.
  static const narrowWidth = 380.0;

  static const pad = 20.0;
  static const buttonHeight = 34.0;

  /// The pair at the foot never falls below this, so "OK" and "Cancel" are the
  /// same target however many letters each language spends on them.
  static const buttonMinWidth = 104.0;

  /// One shadow, with an offset. A zero-offset halo is decoration; this window
  /// is genuinely above the one behind it and should say so.
  static const List<BoxShadow> shadow = [
    BoxShadow(color: Color(0xB3000000), blurRadius: 34, offset: Offset(0, 14)),
  ];
}

/// Glyphs the dialogs need that the console's set does not carry yet.
///
/// Drawn to [LdIcons]' system — 24x24 box, 20x20 optical area, one 1.75 stroke,
/// round cap and join, never filled — so they can move into that file unchanged
/// the moment anything else needs them.
class DialogGlyphs {
  DialogGlyphs._();

  /// It worked, and it is the mark on a ticked checkbox. One stroke, no circle
  /// around it: the circle is what made Material's version read as a badge.
  static const check = 'M5 12.5l4.5 4.5L19 7.5';

  /// Something the operator should know before answering. A statement, not a
  /// warning — [LdIcons.alert] is the warning and the two must not blur.
  static const info = 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17z '
      'M12 11.25v5.25 M12 7.75h.01';

  /// Waiting on the far machine. An hourglass rather than a spinner, because
  /// nothing here is measuring progress.
  static const waiting = 'M7 4.5h10 M7 19.5h10 '
      'M8.5 4.5v3.2L12 12l-3.5 4.3v3.2 M15.5 4.5v3.2L12 12l3.5 4.3v3.2';

  /// Leave this one and go on to the next. The bar is what separates it from a
  /// plain arrow, which would only say "next".
  static const skip = 'M6.5 6.5L13 12l-6.5 5.5 M17.5 5.5v13';

  /// Whoever is being asked to sign in. The console's set has no person in it
  /// because the console is about machines; a credentials prompt is the one
  /// place the product means an account.
  static const user = 'M12 4.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z '
      'M4.5 20c0-3.6 3.4-5.75 7.5-5.75s7.5 2.15 7.5 5.75';

  /// The password is being shown. [LdIcons.privacy] is the same eye struck
  /// through, so the pair cannot drift.
  static const eye = 'M3 12c1.6-2.6 5-6 9-6s7.4 3.4 9 6c-1.6 2.6-5 6-9 6'
      's-7.4-3.4-9-6z M12 9.75a2.25 2.25 0 1 0 0 4.5 2.25 2.25 0 0 0 0-4.5z';
}

/// The theme a dialog runs its subtree under.
///
/// Dialogs are raised from the console, from a session window and from the
/// connection manager, and each of those roots a different [ThemeData]. A modal
/// that inherits whoever raised it is a modal that is one colour on the console
/// and another over a session — so it inherits nothing that matters and sets
/// the console's own values instead. This also catches the Material widgets the
/// dialog bodies host but this file does not own: the quality slider, the
/// trusted-device table, the address-book dropdown.
ThemeData dialogThemeData(BuildContext context) {
  final base = Theme.of(context);
  return base.copyWith(
    canvasColor: C.surface,
    dividerColor: C.hairline,
    hoverColor: C.surfaceHi,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    textTheme: base.textTheme.apply(
      fontFamily: 'Manrope',
      bodyColor: C.text,
      displayColor: C.text,
    ),
    iconTheme: const IconThemeData(color: C.textMuted, size: 18),
    colorScheme: base.colorScheme.copyWith(
      brightness: Brightness.dark,
      primary: C.accent,
      onPrimary: C.bg,
      surface: C.surface,
      onSurface: C.text,
      outline: C.hairline,
      error: C.bad,
    ),
    dividerTheme:
        const DividerThemeData(space: 1, thickness: 1, color: C.hairline),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? C.accent : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(C.bg),
      side: const BorderSide(color: C.textFaint, width: 1.4),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? C.accent : C.textFaint),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: C.accent,
      linearMinHeight: 3,
      linearTrackColor: C.bg,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: const WidgetStatePropertyAll(C.hairline),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
    ),
  );
}

/// A modal.
///
/// Replaces the Material `AlertDialog` the whole product used to raise. The
/// keyboard contract is carried over exactly: Escape cancels, Enter and the
/// numpad Enter submit until the moment the operator starts moving focus with
/// Tab, and Escape is always reported handled so a focused text field does not
/// throw on it.
class LdDialog extends StatelessWidget {
  const LdDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.onSubmit,
    this.onCancel,
    this.onOpen,
    this.width = DialogSkin.width,
  });

  /// An [LdDialogTitle]. Every dialog the product raises has one, including the
  /// ones whose whole body is a sentence: one frame — title row, hairline,
  /// body, footer — or the operator has to work out which kind of window this
  /// is before reading it.
  final Widget? title;

  /// What the title is about. A bare confirmation still puts the machine or the
  /// file here rather than folding it into the heading.
  final Widget? content;

  /// [LdDialogButton]s, in reading order. The last one is the answer.
  final List<Widget>? actions;

  final VoidCallback? onSubmit;
  final VoidCallback? onCancel;

  /// One side effect the Material dialog carried that is not presentation: on
  /// Android the platform soft keyboard is switched off while a session is on
  /// screen, and a dialog with a field in it has to switch it back on. The
  /// caller supplies it, because this file must not reach the FFI.
  final VoidCallback? onOpen;

  final double width;

  @override
  Widget build(BuildContext context) {
    final scopeNode = FocusScopeNode();
    Future.delayed(Duration.zero, () {
      if (!scopeNode.hasFocus) scopeNode.requestFocus();
    });
    bool tabTapped = false;
    onOpen?.call();

    final media = MediaQuery.of(context);

    return Theme(
      data: dialogThemeData(context),
      child: FocusScope(
        node: scopeNode,
        autofocus: true,
        onKeyEvent: (node, key) {
          if (key.logicalKey == LogicalKeyboardKey.escape) {
            if (key is KeyDownEvent) {
              onCancel?.call();
            }
            return KeyEventResult.handled; // avoid TextField exception on escape
          } else if (!tabTapped &&
              onSubmit != null &&
              (key.logicalKey == LogicalKeyboardKey.enter ||
                  key.logicalKey == LogicalKeyboardKey.numpadEnter)) {
            if (key is KeyDownEvent) onSubmit?.call();
            return KeyEventResult.handled;
          } else if (key.logicalKey == LogicalKeyboardKey.tab) {
            if (key is KeyDownEvent) {
              scopeNode.nextFocus();
              tabTapped = true;
            }
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Center(
          child: Container(
            width: width,
            constraints: BoxConstraints(maxHeight: media.size.height * 0.88),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: C.surface,
              borderRadius: C.rounded,
              border: Border.all(color: C.hairline),
              boxShadow: DialogSkin.shadow,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (title != null) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(DialogSkin.pad,
                          DialogSkin.pad - 2, DialogSkin.pad, DialogSkin.pad - 4),
                      child: title!,
                    ),
                    const Divider(height: 1, thickness: 1, color: C.hairline),
                  ],
                  if (content != null)
                    Flexible(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                            DialogSkin.pad,
                            title == null ? DialogSkin.pad : DialogSkin.pad - 4,
                            DialogSkin.pad,
                            DialogSkin.pad),
                        child: DefaultTextStyle(style: C.body(), child: content!),
                      ),
                    ),
                  if (actions != null && actions!.isNotEmpty) ...[
                    const Divider(height: 1, thickness: 1, color: C.hairline),
                    Container(
                      color: C.chrome,
                      padding: const EdgeInsets.fromLTRB(
                          DialogSkin.pad, 12, DialogSkin.pad, 12),
                      child: LdDialogActions(children: actions!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The row the answers sit in.
///
/// Right-aligned and wrapped, so the three-answer case — cancel, skip,
/// overwrite — folds instead of clipping in a language that spends more letters
/// on it.
class LdDialogActions extends StatelessWidget {
  const LdDialogActions({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: children,
      );
}

/// The heading of a dialog: what is about to happen, and the mark that says
/// what kind of thing it is. Every dialog gets one, message boxes included.
///
/// The mark is 19 pixels rather than the 50 Material spent on it: an icon three
/// lines tall is the loudest thing in the dialog and it is never the most
/// important one.
class LdDialogTitle extends StatelessWidget {
  const LdDialogTitle({
    super.key,
    required this.title,
    this.glyph,
    this.tone = C.accent,
    this.subtitle,
  });

  /// Already translated.
  final String title;

  /// A path from [LdIcons] or [DialogGlyphs].
  final String? glyph;

  /// [C.accent] unless the dialog is reporting something that already has a
  /// colour: [C.bad] when it is about to take something away or is telling the
  /// operator a thing failed, [C.ok] when it worked.
  final Color tone;

  /// Already translated.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (glyph != null)
          Padding(
            padding: const EdgeInsets.only(right: 11, top: 2),
            child: LdIcon(glyph!, size: 19, color: tone),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: C.h1()),
              if (subtitle != null) ...[
                const SizedBox(height: 5),
                Text(subtitle!, style: C.small(color: C.textMuted)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The body of a dialog whose whole content is something the product has to
/// say: a connection failed, the far end is busy, the machine wants elevating.
///
/// The sentences only. The heading and its mark are the dialog's own
/// [LdDialogTitle], drawn in the same header row above the same hairline as
/// every other dialog in the product — these used to carry their own heading
/// inside the body, which is why a message box was the one modal with no header
/// and a "Delete" confirmation was the one with no body.
///
/// Selectable, because half of these are error strings somebody is about to
/// paste into a ticket.
class LdDialogMessage extends StatelessWidget {
  const LdDialogMessage({
    super.key,
    required this.text,
    this.detail,
    this.onLinkTap,
  });

  /// Already translated.
  final String text;

  /// A machine, a path, an id: set in the data face and boxed, because it is
  /// the thing being checked rather than the thing being read.
  final String? detail;

  /// Called with a URL found in [text]. Null leaves links as plain text.
  final ValueChanged<String>? onLinkTap;

  static final _link = RegExp(r'(https?://[^\s]+)');

  Widget _body() {
    if (onLinkTap == null || !_link.hasMatch(text)) {
      return SelectableText(text, style: C.body(color: C.textMuted));
    }
    final spans = <TextSpan>[];
    var start = 0;
    for (final m in _link.allMatches(text)) {
      if (m.start > start) {
        spans.add(TextSpan(text: text.substring(start, m.start)));
      }
      final url = m.group(0) ?? '';
      spans.add(TextSpan(
        text: url,
        style: C.body(color: C.accent).copyWith(
            decoration: TextDecoration.underline,
            decorationColor: C.accent.withOpacity(0.6)),
        recognizer: TapGestureRecognizer()
          ..onTap = () =>
              onLinkTap!(url.replaceAll(RegExp(r'[.,;!?]+$'), '')),
      ));
      start = m.end;
    }
    if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
    return SelectableText.rich(
        TextSpan(style: C.body(color: C.textMuted), children: spans));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (text.isNotEmpty) _body(),
        if (detail != null && detail!.isNotEmpty) ...[
          if (text.isNotEmpty) const SizedBox(height: 12),
          LdDialogIdentity(detail!),
        ],
      ],
    );
  }
}

/// The machine, the path or the id a dialog is about to act on.
///
/// Set in the data face on the background plane: it is the one line in the
/// dialog somebody will read character by character, and a proportional face
/// with an ambiguous l/1 is exactly the wrong thing to hand them when the next
/// click restarts a server.
class LdDialogIdentity extends StatelessWidget {
  const LdDialogIdentity(this.value, {super.key, this.glyph});

  /// Not translated: it is a name.
  final String value;
  final String? glyph;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
        decoration: BoxDecoration(
          color: C.bg,
          borderRadius: C.roundedSm,
          border: Border.all(color: C.hairline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (glyph != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: LdIcon(glyph!, size: 14, color: C.textFaint),
              ),
              const SizedBox(width: 9),
            ],
            Expanded(
              child: SelectableText(value,
                  style: C.data(size: 12.5, color: C.text)),
            ),
          ],
        ),
      );
}

/// Something the operator should read before answering, that is not the
/// question itself: the UAC caveat, the shared-password warning.
class LdDialogNote extends StatelessWidget {
  const LdDialogNote(this.text, {super.key, this.tone = C.textMuted, this.glyph});

  /// Already translated.
  final String text;
  final Color tone;
  final String? glyph;

  @override
  Widget build(BuildContext context) {
    final bad = tone == C.bad;
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
      decoration: BoxDecoration(
        color: bad ? C.bad.withOpacity(0.10) : C.bg,
        borderRadius: C.roundedSm,
        border: Border.all(color: bad ? C.bad.withOpacity(0.45) : C.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 9),
            child: LdIcon(glyph ?? DialogGlyphs.info, size: 15, color: tone),
          ),
          Expanded(child: Text(text, style: C.small(color: tone))),
        ],
      ),
    );
  }
}

/// A typed value in a dialog.
///
/// The label sits above the box rather than floating into its border. A
/// Material floating label is a label that is either covering the value or
/// shrunk to nine pixels, and in a password prompt under stress it is the one
/// word that says which of the two passwords is being asked for.
class LdDialogField extends StatelessWidget {
  const LdDialogField({
    super.key,
    required this.controller,
    required this.label,
    this.hintText,
    this.helperText,
    this.errorText,
    this.glyph,
    this.leading,
    this.trailing,
    this.focusNode,
    this.autofocus = true,
    this.obscureText = false,
    this.mono = false,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.maxLength,
    this.maxLines = 1,
    this.minLines,
    this.suffixText,
    this.showCounter = false,
    this.enabled = true,
    this.validator,
    this.onChanged,
  });

  final TextEditingController controller;

  /// Already translated.
  final String label;
  final String? hintText;
  final String? helperText;
  final String? errorText;

  /// A path from [LdIcons], drawn inside the box on the leading edge.
  final String? glyph;

  /// A mark on the leading edge that is already a widget, for the callers that
  /// hand one down.
  final Widget? leading;

  /// The one control a field may carry: the reveal on a password.
  final Widget? trailing;

  final FocusNode? focusNode;
  final bool autofocus;
  final bool obscureText;

  /// An id, a port, a token: things that are compared character by character.
  final bool mono;

  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;
  final int? maxLines;
  final int? minLines;
  final String? suffixText;

  /// Only where the limit is part of the writing — a note capped at 256
  /// characters. Everywhere else the counter is a number nobody asked for,
  /// sitting exactly where the error message goes.
  final bool showCounter;

  final bool enabled;

  /// For the one field that is validated by a [Form] rather than by its
  /// caller. When it is set the message is drawn by the decoration, because
  /// that is the only place a [FormField] can put it.
  final FormFieldValidator<String>? validator;

  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null && errorText!.isNotEmpty;
    final fg = enabled ? C.text : C.textFaint;
    final style =
        mono ? C.data(size: 13, color: fg) : C.body(color: fg);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty) ...[
          Text(label.toUpperCase(),
              style: C.micro(color: C.textFaint).copyWith(letterSpacing: 0.8)),
          const SizedBox(height: 7),
        ],
        TextFormField(
          controller: controller,
          focusNode: focusNode,
          validator: validator,
          autofocus: autofocus,
          enabled: enabled,
          obscureText: obscureText,
          autocorrect: false,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          inputFormatters: inputFormatters,
          maxLength: maxLength,
          maxLines: obscureText ? 1 : maxLines,
          minLines: minLines,
          onChanged: onChanged,
          cursorColor: C.accent,
          cursorWidth: 1.5,
          style: style,
          buildCounter: (_,
              {required currentLength, required isFocused, required maxLength}) {
            if (!showCounter || maxLength == null) return null;
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('$currentLength/$maxLength',
                  style: C.data(size: 11, color: C.textFaint)),
            );
          },
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: mono
                ? C.data(size: 13, color: C.textFaint)
                : C.body(color: C.textFaint),
            suffixText: suffixText,
            suffixStyle: C.data(size: 11.5, color: C.textFaint),
            isDense: true,
            filled: true,
            fillColor: enabled ? C.bg : C.bg.withOpacity(0.5),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            prefixIcon: glyph == null && leading == null
                ? null
                : Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                    child: glyph != null
                        ? LdIcon(glyph!, size: 16, color: C.textFaint)
                        : leading,
                  ),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 0, minHeight: 0),
            suffixIcon: trailing,
            suffixIconConstraints:
                const BoxConstraints(minWidth: 0, minHeight: 0),
            border: _border(C.hairline),
            enabledBorder: _border(hasError ? C.bad : C.hairline),
            disabledBorder: _border(C.hairline.withOpacity(0.6)),
            focusedBorder: _border(hasError ? C.bad : C.accent),
            errorBorder: _border(C.bad),
            focusedErrorBorder: _border(C.bad),
            // The message is drawn below rather than by the decoration, so it
            // can be selected and so it does not reserve a line of height on
            // every field that has never been wrong. A validated field is the
            // exception: a [FormField] has nowhere else to put it.
            errorStyle: validator == null
                ? const TextStyle(height: 0, fontSize: 0)
                : C.small(color: C.bad, w: FontWeight.w600),
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 7),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1, right: 7),
                child: LdIcon(LdIcons.alert, size: 13, color: C.bad),
              ),
              Expanded(
                child: SelectableText(errorText!,
                    style: C.small(color: C.bad, w: FontWeight.w600)),
              ),
            ],
          ),
        ],
        if (helperText != null && helperText!.isNotEmpty) ...[
          const SizedBox(height: 7),
          Text(helperText!, style: C.small(color: C.textFaint)),
        ],
      ],
    );
  }

  OutlineInputBorder _border(Color c) => OutlineInputBorder(
      borderRadius: C.roundedSm, borderSide: BorderSide(color: c));
}

/// A control inside a field's box: the reveal on a password, the clear on a
/// port.
///
/// Drawn rather than an `IconButton`, which brought a 48-pixel touch target and
/// a ripple into a 44-pixel-tall field.
class LdFieldButton extends StatefulWidget {
  const LdFieldButton({
    super.key,
    required this.glyph,
    required this.onPressed,
    this.active = false,
  });

  /// A path from [LdIcons] or [DialogGlyphs].
  final String glyph;
  final VoidCallback onPressed;

  /// The state it puts the field in is currently on — a password being shown.
  final bool active;

  @override
  State<LdFieldButton> createState() => _LdFieldButtonState();
}

class _LdFieldButtonState extends State<LdFieldButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
            child: LdIcon(widget.glyph,
                size: 17,
                color: _hover || widget.active ? C.text : C.textFaint),
          ),
        ),
      );
}

/// The box itself, so a tick drawn outside a row still matches one.
///
/// The console's [LdCheckbox] under this file's name. It used to be a second
/// drawing of the same idea — 17 pixels at a 4 radius against the console's 16
/// at a 5 — which is how a product ends up with two checkboxes again after
/// consolidating three.
class LdCheckMark extends StatelessWidget {
  const LdCheckMark(
      {super.key,
      required this.value,
      this.enabled = true,
      this.hover = false});

  final bool value;
  final bool enabled;
  final bool hover;

  @override
  Widget build(BuildContext context) =>
      LdCheckbox(on: value, enabled: enabled, hover: hover);
}

/// One thing the operator is agreeing to alongside the answer: remember this
/// password, do this for every conflict, trust this device.
///
/// The whole row is the target, and the box is drawn rather than Material's —
/// a filled blue square is the single most recognisable Material tell and it
/// sat in the middle of the password prompt.
class LdDialogCheck extends StatefulWidget {
  const LdDialogCheck({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  /// Already translated.
  final String label;
  final bool value;

  /// Null disables the row, which is what a policy-fixed option looks like.
  final ValueChanged<bool>? onChanged;

  @override
  State<LdDialogCheck> createState() => _LdDialogCheckState();
}

class _LdDialogCheckState extends State<LdDialogCheck> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final on = widget.value;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? () => widget.onChanged!(!on) : null,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: LdCheckMark(
                    value: on, enabled: enabled, hover: _hover),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  style: C.small(
                      color: !enabled
                          ? C.textFaint
                          : (_hover || on ? C.text : C.textMuted)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What an answer is for.
enum LdDialogTone {
  /// The thing the dialog was raised to do: connect, save, retry.
  primary,

  /// The other answer, and everything that is neither.
  neutral,

  /// An action that cannot be taken back: delete, restart, overwrite,
  /// disconnect. The only place red appears on a dialog.
  danger,
}

/// One answer.
///
/// Sized so the pair at the foot is one pair of buttons rather than a button
/// and its shadow: same height, same minimum width, same type at the same
/// weight, and both labels in the console's full-strength text colour. What the
/// consequential one carries is a tinted frame, a tinted wash and a glyph.
class LdDialogButton extends StatefulWidget {
  const LdDialogButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.tone = LdDialogTone.neutral,
    this.glyph,
    this.busy = false,
  });

  /// Already translated.
  final String label;

  /// Null disables it — an OK that cannot yet be given keeps its shape and
  /// stops claiming it can act.
  final VoidCallback? onPressed;

  final LdDialogTone tone;

  /// A path from [LdIcons] or [DialogGlyphs].
  final String? glyph;

  /// Work is in flight; the answer has been given and cannot be given twice.
  final bool busy;

  @override
  State<LdDialogButton> createState() => _LdDialogButtonState();
}

class _LdDialogButtonState extends State<LdDialogButton> {
  bool _hover = false;
  bool _down = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.busy;
    final tint = switch (widget.tone) {
      LdDialogTone.primary => C.accent,
      LdDialogTone.danger => C.bad,
      LdDialogTone.neutral => C.hairline,
    };
    final neutral = widget.tone == LdDialogTone.neutral;
    final fg = !enabled
        ? C.textFaint
        : (widget.tone == LdDialogTone.danger ? C.bad : C.text);
    // Hover raises the fill; focus does not. They used to do the same thing,
    // which left a keyboard-focused answer and a pointed-at answer painted
    // identically apart from the ring — and next to a resting answer of the
    // same tone the brighter fill read as "this one is the default" rather
    // than "this one is under something". The ring is now the only thing that
    // says where the keyboard is, and the fill the only thing that says where
    // the pointer is.
    final lit = _hover && enabled;

    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor:
          enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onPressed?.call();
          return null;
        }),
      },
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedContainer(
          duration: C.fast,
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _down ? 1 : 0, 0),
          height: DialogSkin.buttonHeight,
          constraints:
              const BoxConstraints(minWidth: DialogSkin.buttonMinWidth),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: !enabled
                ? Colors.transparent
                : neutral
                    ? (lit ? C.surfaceHi : Colors.transparent)
                    : tint.withOpacity(lit ? 0.22 : 0.12),
            borderRadius: C.roundedSm,
            border: Border.all(
              // [C.focusRing]: the one ring the console draws round whatever
              // the keyboard is on, the same on this button as on the checkbox
              // above it. Tone is carried by the fill and the glyph, so the
              // ring is free to mean only "this is where the keyboard is".
              color: _focus && enabled
                  ? C.focusRing
                  : !enabled
                      ? C.disabledBorder
                      : neutral
                          ? C.hairline
                          : tint.withOpacity(_hover ? 0.9 : 0.65),
              // A disabled answer drops to the hairline weight as well as the
              // hairline colour: a 1.4 frame on a dead OK made it the heaviest
              // outline at the foot of the dialog.
              width: _focus && enabled
                  ? C.focusRingWidth
                  : (enabled && !neutral ? 1.4 : 1),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.busy)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.6, color: C.accent),
                )
              else if (widget.glyph != null)
                LdIcon(widget.glyph!, size: 15, color: fg),
              if (widget.busy || widget.glyph != null) const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(widget.label,
                      maxLines: 1,
                      style: C.small(color: fg, w: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
