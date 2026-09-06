import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ld_icons.dart';

/// LabDesk console design language.
///
/// This is an Operate surface: the operator is in a task, so the interface
/// should disappear into it. Familiarity is a feature here, and the character
/// lives in precise details rather than in expression.
///
/// The rules it holds itself to:
///   - One sans family carries headings, labels, buttons and body. Monospace is
///     reserved for things that are actually data: identifiers, timestamps,
///     measured values. Mono as a costume for "technical" is the tell.
///   - Restrained colour. One accent, used for primary action and current
///     selection only. Status colour is semantic and never decorative.
///   - One radius scale, applied everywhere.
///   - Real states on everything interactive: hover, focus, selected, disabled,
///     loading, empty.
class C {
  C._();

  // Surfaces. A cool near-black, never pure black, with a separate slightly
  // cooler layer for the chrome so the content plane reads as the subject.
  static const bg = Color(0xFF11171B);
  static const chrome = Color(0xFF0C1115);
  static const surface = Color(0xFF172127);
  static const surfaceHi = Color(0xFF1C282E);
  static const hairline = Color(0xFF2B363E);

  static const text = Color(0xFFEAF2F4);
  static const textMuted = Color(0xFF9FACB5);
  static const textFaint = Color(0xFF85959F);

  /// Pale cyan ties active navigation, controls and telemetry together.
  static const accent = Color(0xFFA5DCE7);
  static const accentDim = Color(0xFF729CAE);

  /// The filled primary button. One tint, one foreground, everywhere.
  ///
  /// The console had two: the installer painted its confirm in the light accent
  /// under a near-black label while Connect and Send painted theirs in the dark
  /// accent under a white one, so the same rank arrived in two colours with
  /// opposite foregrounds and neither read as the more important. The fill is
  /// the accent, the label is the page background, and the dim accent is the
  /// pressed state rather than a second rank.
  ///
  /// Any surface still drawing its own filled primary — the session toolbar,
  /// the connection manager, the file manager's Send — should switch to these
  /// four values rather than pick its own.
  static const primaryFill = accent;
  static const primaryFillHover = Color(0xFFBEE9F1);
  static const primaryFillDown = accentDim;
  static const primaryFg = bg;

  /// Semantic status. Never used as decoration.
  static const ok = Color(0xFF88D4B0);
  static const bad = Color(0xFFE79B9B);
  static const warning = Color(0xFFECC181);
  static const idle = Color(0xFF85959F);

  /// One focus ring for the whole console, on buttons and on marks alike.
  ///
  /// There were two: a button rang in [text] while a checkbox rang in [accent],
  /// so the keyboard spoke one language on the answers at the foot of a dialog
  /// and another on the option above them. The accent is the one that survives —
  /// it is already the console's "this is the current thing" colour.
  static const focusRing = accent;
  static const focusRingWidth = 1.8;

  /// One disabled rule for the whole console: no fill, the frame at 60% of the
  /// [hairline], and everything on it — label, glyph, knob, tick — in
  /// [textFaint]. It holds for the toggle, the checkbox, the radio and every
  /// button.
  ///
  /// Nothing disabled keeps the accent. A dimmed accent is still the accent: a
  /// locked toggle painted in [accentDim] sat one shade off the live one and
  /// read as available at the glance an operator actually gives it.
  static final disabledBorder = hairline.withOpacity(0.6);

  static const radius = 8.0;
  static const radiusSm = 6.0;
  static final rounded = BorderRadius.circular(radius);
  static final roundedSm = BorderRadius.circular(radiusSm);

  static const fast = Duration(milliseconds: 140);
  static const medium = Duration(milliseconds: 220);

  /// The two families are bundled with the application rather than fetched at
  /// runtime. A font CDN is not reachable from an isolated network, and a
  /// machine worth administering remotely is frequently on one; a console that
  /// silently loses its typeface there is a console that looks broken exactly
  /// where it has to be trusted. It also keeps the tool from calling out to a
  /// third party to draw itself.
  static const _sans = 'Manrope';
  static const _mono = 'JetBrainsMono';

  /// Manrope is bundled as its variable cut, so a weight has to be requested on
  /// the wght axis as well as declared. Setting only [FontWeight] would render
  /// every weight at the axis default.
  static List<FontVariation> _wght(FontWeight w) =>
      [FontVariation('wght', w.value.toDouble())];

  static TextStyle _sansStyle({
    required double fontSize,
    required FontWeight fontWeight,
    required Color color,
    double? letterSpacing,
    double? height,
    List<FontFeature>? fontFeatures,
  }) =>
      TextStyle(
        fontFamily: _sans,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontVariations: _wght(fontWeight),
        color: color,
        letterSpacing: letterSpacing,
        height: height,
        fontFeatures: fontFeatures,
      );

  // A fixed scale with a tight ratio. Product UI is viewed at a consistent
  // size, so fluid type would only add noise.
  static TextStyle h1() => _sansStyle(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      color: text,
      letterSpacing: -0.4,
      height: 1.2);
  static TextStyle h2() => _sansStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: text,
      letterSpacing: -0.2,
      height: 1.3);
  static TextStyle body({Color color = text}) => _sansStyle(
      fontSize: 13.5, fontWeight: FontWeight.w500, color: color, height: 1.45);
  static TextStyle small(
          {Color color = textMuted, FontWeight w = FontWeight.w500}) =>
      _sansStyle(fontSize: 12, fontWeight: w, color: color, height: 1.4);
  static TextStyle micro({Color color = textFaint}) => _sansStyle(
      fontSize: 11, fontWeight: FontWeight.w600, color: color, height: 1.3);

  /// Identifiers, timestamps, measured values. Tabular so a column of figures
  /// does not jitter as it updates.
  static TextStyle data(
          {double size = 12.5,
          Color color = text,
          FontWeight w = FontWeight.w500}) =>
      TextStyle(
        fontFamily: _mono,
        fontSize: size,
        fontWeight: w,
        color: color,
        height: 1.35,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// A large measured number.
  static TextStyle metric({Color color = text}) => _sansStyle(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: -0.8,
        height: 1.0,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static ConsolePalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? ConsolePalette.dark
          : ConsolePalette.light;

  static ThemeData theme({Brightness brightness = Brightness.dark}) {
    final p = brightness == Brightness.dark
        ? ConsolePalette.dark
        : ConsolePalette.light;
    final base = ThemeData(
        brightness: brightness, useMaterial3: true, fontFamily: _sans);
    final input = InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      labelStyle: p.small(),
      hintStyle: p.body(color: p.textFaint),
      helperStyle: p.small(),
      errorStyle: p.small(color: p.bad),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(borderRadius: roundedSm),
      enabledBorder: OutlineInputBorder(
          borderRadius: roundedSm, borderSide: BorderSide(color: p.textFaint)),
      disabledBorder: OutlineInputBorder(
          borderRadius: roundedSm,
          borderSide: BorderSide(color: p.disabledBorder)),
      focusedBorder: OutlineInputBorder(
          borderRadius: roundedSm,
          borderSide: BorderSide(color: p.focusRing, width: focusRingWidth)),
      errorBorder: OutlineInputBorder(
          borderRadius: roundedSm, borderSide: BorderSide(color: p.bad)),
      focusedErrorBorder: OutlineInputBorder(
          borderRadius: roundedSm,
          borderSide: BorderSide(color: p.bad, width: focusRingWidth)),
    );
    final menu = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(p.surfaceHi),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      side: WidgetStatePropertyAll(BorderSide(color: p.hairline)),
      shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: roundedSm)),
    );
    ButtonStyle button({bool filled = false, bool outlined = false}) =>
        ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
          shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: roundedSm)),
          textStyle: WidgetStatePropertyAll(p.small(w: FontWeight.w600)),
          animationDuration: fast,
          foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? p.textFaint
                  : filled
                      ? p.primaryFg
                      : p.accent),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (!filled || states.contains(WidgetState.disabled)) {
              return Colors.transparent;
            }
            if (states.contains(WidgetState.pressed)) return p.primaryFillDown;
            return states.contains(WidgetState.hovered)
                ? p.primaryFillHover
                : p.primaryFill;
          }),
          overlayColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.focused) ||
                      states.contains(WidgetState.pressed)
                  ? p.accent.withOpacity(.16)
                  : states.contains(WidgetState.hovered)
                      ? p.accent.withOpacity(.08)
                      : Colors.transparent),
          side: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.disabled)
                  ? BorderSide(
                      color: outlined ? p.disabledBorder : Colors.transparent)
                  : states.contains(WidgetState.focused)
                      ? BorderSide(
                          color: filled ? p.text : p.focusRing,
                          width: focusRingWidth)
                      : BorderSide(
                          color: outlined ? p.textFaint : Colors.transparent)),
        );
    return base.copyWith(
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.surface,
      dividerColor: p.hairline,
      disabledColor: p.textFaint,
      focusColor: p.accent.withOpacity(.16),
      hoverColor: p.accent.withOpacity(.08),
      iconTheme: IconThemeData(color: p.textMuted),
      textTheme: base.textTheme
          .apply(bodyColor: p.text, displayColor: p.text)
          .copyWith(
            titleLarge: p.h1(),
            titleMedium: p.h2(),
            bodyLarge: p.body().copyWith(fontSize: 15),
            bodyMedium: p.body(),
            bodySmall: p.small(),
            labelLarge: p.small(w: FontWeight.w600),
            labelMedium: p.small(),
            labelSmall: p.micro(),
          ),
      colorScheme:
          ColorScheme.fromSeed(seedColor: p.accent, brightness: brightness)
              .copyWith(
        surface: p.surface,
        onSurface: p.text,
        onSurfaceVariant: p.textMuted,
        surfaceContainerHighest: p.surfaceHi,
        primary: p.accent,
        onPrimary: p.primaryFg,
        primaryContainer: p.surfaceHi,
        onPrimaryContainer: p.text,
        secondary: p.accentDim,
        onSecondary: p.primaryFg,
        secondaryContainer: p.surfaceHi,
        onSecondaryContainer: p.text,
        error: p.bad,
        onError: p.primaryFg,
        outline: p.textFaint,
        outlineVariant: p.hairline,
      ),
      inputDecorationTheme: input,
      textSelectionTheme: TextSelectionThemeData(
          cursorColor: p.accent,
          selectionColor: p.accent.withOpacity(.28),
          selectionHandleColor: p.accent),
      filledButtonTheme: FilledButtonThemeData(style: button(filled: true)),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: button(filled: true)
              .copyWith(elevation: const WidgetStatePropertyAll(0))),
      outlinedButtonTheme:
          OutlinedButtonThemeData(style: button(outlined: true)),
      textButtonTheme: TextButtonThemeData(style: button()),
      menuTheme: MenuThemeData(style: menu),
      menuButtonTheme: MenuButtonThemeData(
          style: button().copyWith(
              foregroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.disabled)
                      ? p.textFaint
                      : p.text))),
      dropdownMenuTheme: DropdownMenuThemeData(
          textStyle: p.body(), inputDecorationTheme: input, menuStyle: menu),
      popupMenuTheme: PopupMenuThemeData(
          color: p.surfaceHi,
          surfaceTintColor: Colors.transparent,
          textStyle: p.body(),
          shape: RoundedRectangleBorder(
              borderRadius: roundedSm, side: BorderSide(color: p.hairline))),
      tabBarTheme: TabBarTheme(
          labelColor: p.accent,
          unselectedLabelColor: p.textMuted,
          labelStyle: p.body().copyWith(
              fontWeight: FontWeight.w600,
              fontVariations: _wght(FontWeight.w600)),
          unselectedLabelStyle: p.body(),
          dividerColor: p.hairline,
          indicator: UnderlineTabIndicator(
              borderSide: BorderSide(color: p.accent, width: 2))),
      dialogTheme: DialogTheme(
          backgroundColor: p.surface,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: p.h1(),
          contentTextStyle: p.body()),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: p.surfaceHi,
          borderRadius: roundedSm,
          border: Border.all(color: p.hairline),
          // Depth carries an offset and a soft blur; a zero-offset halo is
          // decoration, not elevation.
          boxShadow: const [
            BoxShadow(
                color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 6)),
          ],
        ),
        textStyle: p.small(color: p.text),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(p.textFaint),
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(4),
      ),
    );
  }
}

/// Immutable per-subtree colors. Legacy C constants always remain dark.
class ConsolePalette {
  const ConsolePalette._(this.brightness);
  static const dark = ConsolePalette._(Brightness.dark);
  static const light = ConsolePalette._(Brightness.light);
  final Brightness brightness;
  bool get isDark => brightness == Brightness.dark;

  Color get bg => isDark ? C.bg : const Color(0xfff4f7f7);
  Color get chrome => isDark ? C.chrome : const Color(0xffe9eeee);
  Color get surface => isDark ? C.surface : const Color(0xfffafdfe);
  Color get surfaceHi => isDark ? C.surfaceHi : const Color(0xffe3ebed);
  Color get hairline => isDark ? C.hairline : const Color(0xffcbd6da);
  Color get text => isDark ? C.text : const Color(0xff18272c);
  Color get textMuted => isDark ? C.textMuted : const Color(0xff52636d);
  Color get textFaint => isDark ? C.textFaint : const Color(0xff5b6c75);
  Color get accent => isDark ? C.accent : const Color(0xff256578);
  Color get accentDim => isDark ? C.accentDim : const Color(0xff427285);
  Color get primaryFill => accent;
  Color get primaryFillHover =>
      isDark ? C.primaryFillHover : const Color(0xff1e5668);
  Color get primaryFillDown =>
      isDark ? C.primaryFillDown : const Color(0xff194a59);
  Color get primaryFg => isDark ? C.primaryFg : Colors.white;
  Color get ok => isDark ? C.ok : const Color(0xff27704e);
  Color get bad => isDark ? C.bad : const Color(0xff9b4141);
  Color get warning => isDark ? C.warning : const Color(0xff8b5d17);
  Color get idle => textFaint;
  Color get focusRing => accent;
  Color get disabledBorder => hairline.withOpacity(.6);
  double get focusRingWidth => C.focusRingWidth;
  double get radius => C.radius;
  double get radiusSm => C.radiusSm;
  BorderRadius get rounded => C.rounded;
  BorderRadius get roundedSm => C.roundedSm;
  Duration get fast => C.fast;
  Duration get medium => C.medium;

  TextStyle h1() => C.h1().copyWith(color: text);
  TextStyle h2() => C.h2().copyWith(color: text);
  TextStyle body({Color? color}) => C.body(color: color ?? text);
  TextStyle small({Color? color, FontWeight w = FontWeight.w500}) =>
      C.small(color: color ?? textMuted, w: w);
  TextStyle micro({Color? color}) => C.micro(color: color ?? textFaint);
  TextStyle data(
          {double size = 12.5, Color? color, FontWeight w = FontWeight.w500}) =>
      C.data(size: size, color: color ?? text, w: w);
  TextStyle metric({Color? color}) => C.metric(color: color ?? text);
}

/// A titled panel. The structural unit of the console.
///
/// No eyebrow above the title: the title carries its own weight.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions,
    this.padding = const EdgeInsets.fromLTRB(18, 16, 18, 18),
    this.fill = false,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget>? actions;
  final EdgeInsets padding;

  /// Consume the height offered. Required when the body scrolls, otherwise the
  /// column sizes to its children and hands the body an unbounded height.
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: C.rounded,
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 15, 12, 14),
            child: Row(
              children: [
                // Expanded, and no Spacer beside it. A Flexible and a Spacer
                // are both flex 1, so the free space was split evenly: the
                // title block was capped at half the header however wide the
                // panel got, wrapping subtitles into a narrow column while the
                // other half sat empty, and the actions never reached the
                // right edge.
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: p.h2()),
                      if (subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(subtitle!, style: p.small(color: p.textFaint)),
                      ],
                    ],
                  ),
                ),
                if (actions != null) ...actions!,
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: p.hairline),
          if (fill)
            Expanded(child: Padding(padding: padding, child: child))
          else
            Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// A quiet secondary button with the full state set.
class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    this.icon,
    this.glyph,
    this.onPressed,
    this.busy = false,
  });

  final String label;
  final IconData? icon;

  /// A path from [LdIcons]. Preferred over [icon]: the console draws its own
  /// glyphs, and a Material icon on a button is the one place the borrowed set
  /// is most visible.
  final String? glyph;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    final enabled = onPressed != null && !busy;
    final fg = enabled ? p.textMuted : p.textFaint;
    return OutlinedButton(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(
            foregroundColor: p.textMuted,
            disabledForegroundColor: p.textFaint,
            textStyle: p.small(w: FontWeight.w600),
            minimumSize: const Size(40, 40),
            shape: RoundedRectangleBorder(borderRadius: C.roundedSm)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (busy)
            SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.6, color: p.textFaint))
          else if (glyph != null)
            LdIcon(glyph!, size: 15, color: fg)
          else if (icon != null)
            Icon(icon, size: 14, color: fg),
          if (busy || glyph != null || icon != null) const SizedBox(width: 7),
          Text(label),
        ]));
  }
}

/// The console's toggle. One size, one palette, drawn once.
///
/// There used to be three. The settings page drew a 34x20 pill in the light
/// accent with a near-black knob, a menu row drew a smaller one in the dim
/// accent with a white knob, and the connection manager drew a third. A control
/// that means "this is on" cannot be three different objects, because then none
/// of them is the one the operator has learned.
///
/// Drawn rather than themed: a Material Switch carries a 48-pixel tap target, a
/// ripple and an M3 outline that no amount of theming brings onto the console's
/// ramp.
///
/// [enabled] paints the control; [onChanged] decides whether the pill itself is
/// the hit area. They are separate because a toggle sitting in a menu row is
/// live but driven by the row around it, and painting that one as disabled
/// would be a lie.
///
/// [stateLabel] puts the state in a word beside the pill. Off by default: a
/// column of them is noise. It exists because the connection manager states
/// every permission twice on purpose — a caption that survives when the two
/// track colours do not separate for the operator reading them — and that
/// surface should be able to take this widget without giving that up.
class LdToggle extends StatefulWidget {
  const LdToggle({
    super.key,
    required this.value,
    this.onChanged,
    this.enabled = true,
    this.stateLabel = false,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;
  final bool stateLabel;

  @override
  State<LdToggle> createState() => _LdToggleState();
}

class _LdToggleState extends State<LdToggle> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    final enabled = widget.enabled;
    final tappable = widget.onChanged != null && enabled;
    final on = widget.value;
    // [p.disabledBorder]'s rule: a locked toggle drops the fill entirely rather
    // than dimming it. The knob's position is what still says which way it is.
    final track = !enabled ? Colors.transparent : (on ? p.accent : p.surfaceHi);
    final knob = !enabled ? p.textFaint : (on ? p.primaryFg : p.textMuted);

    Widget pill = AnimatedContainer(
      duration:
          MediaQuery.of(context).disableAnimations ? Duration.zero : C.fast,
      curve: Curves.easeOut,
      width: 34,
      height: 20,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: track,
        borderRadius: BorderRadius.circular(10),
        boxShadow: _focused && tappable
            ? [BoxShadow(color: p.focusRing, spreadRadius: 3)]
            : null,
        border: Border.all(
          color: !enabled
              ? p.disabledBorder
              : on
                  ? Colors.transparent
                  : (_hover && tappable ? p.textFaint : p.hairline),
        ),
      ),
      child: AnimatedAlign(
        duration:
            MediaQuery.of(context).disableAnimations ? Duration.zero : C.fast,
        curve: Curves.easeOut,
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: knob, shape: BoxShape.circle),
        ),
      ),
    );

    if (widget.stateLabel) {
      pill = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A fixed box, right-aligned: ON is narrower than OFF, and a pill
          // that shifts sideways as the state changes reads as two controls.
          SizedBox(
            width: 24,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                on ? 'ON' : 'OFF',
                style: p
                    .data(
                      size: 10,
                      w: FontWeight.w700,
                      color:
                          !enabled ? p.textFaint : (on ? p.text : p.textMuted),
                    )
                    .copyWith(letterSpacing: 0.6),
              ),
            ),
          ),
          const SizedBox(width: 8),
          pill,
        ],
      );
    }

    final control = MouseRegion(
      cursor: tappable ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: tappable ? () => widget.onChanged!(!on) : null,
        child: pill,
      ),
    );
    if (!tappable) return control;
    return Semantics(
      toggled: on,
      enabled: true,
      child: FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onChanged!(!on);
            return null;
          }),
        },
        child: control,
      ),
    );
  }
}

/// The console's checkbox. One size, one palette, drawn once.
///
/// There used to be three, at three sizes and two radii, and the two that
/// carried a tick disagreed about which way round it went: the table drew a dim
/// fill under a white tick, the installer a light fill under a dark one. This
/// is the installer's reading — the accent is the fill and the tick is cut out
/// of it — at one size for both.
///
/// A mark rather than a control. Every place a checkbox appears in this
/// console, the row around it is the hit area and already knows whether it is
/// hovered, focused and enabled; a box that took the tap as well would fight
/// its own row for it.
class LdCheckbox extends StatelessWidget {
  const LdCheckbox({
    super.key,
    required this.on,
    this.enabled = true,
    this.hover = false,
    this.focused = false,
  });

  final bool on;
  final bool enabled;
  final bool hover;
  final bool focused;

  static const size = 16.0;

  @override
  Widget build(BuildContext context) {
    final p = C.of(context);
    // [p.disabledBorder]'s rule, and the same 1.4 ring the radio carries so the
    // two marks are one family at one size.
    final fill = on && enabled ? p.accent : Colors.transparent;
    final border = !enabled
        ? p.disabledBorder
        : on
            ? p.accent
            : focused
                ? p.focusRing
                : (hover ? p.textFaint : p.hairline);

    return AnimatedContainer(
      duration:
          MediaQuery.of(context).disableAnimations ? Duration.zero : C.fast,
      curve: Curves.easeOut,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
            color: border, width: focused && enabled ? C.focusRingWidth : 1.4),
      ),
      // A locked option still has to say which way it is, so the tick survives
      // being disabled — in [p.textFaint] on no fill, because the disabled rule
      // takes the accent away rather than dimming it.
      child: on
          ? Center(
              child: LdIcon(LdIcons.check,
                  size: 12, color: enabled ? p.primaryFg : p.textFaint))
          : null,
    );
  }
}
