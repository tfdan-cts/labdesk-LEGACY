import 'package:flutter/material.dart';

import 'console_theme.dart';
import 'ld_icons.dart';
import 'settings_skin.dart' show LdRadioMark;

/// The look of the session toolbar, with the session taken out of it.
///
/// The toolbar itself (`desktop/widgets/remote_toolbar.dart`) cannot be built
/// without a live FFI session, and the app's shared `common.dart` does not
/// compile under the test SDK at all — which made the one part of the product
/// that most needs looking at the one part that could not be looked at. So the
/// presentation lives here, takes plain values, and is rendered by
/// `tool/shots/toolbar_test.dart`. The toolbar imports these pieces rather
/// than restating them, so what the shot shows is what ships.
///
/// The design decision worth naming: `color` and `hoverColor` on the buttons
/// are *foreground* colours. The
/// toolbar this replaced painted a filled blue chip behind every white glyph,
/// which is what made a floating row of controls read as somebody else's
/// product. Here a resting button is a glyph on the toolbar surface and
/// nothing else; hover raises a quiet [C.surfaceHi] pad under it. Accent is
/// spent only on state that is genuinely on — pinned, current monitor —
/// and red only on destructive or recording state.
class ToolbarSkin {
  ToolbarSkin._();

  /// A control at rest, and the same control under the cursor.
  static const Color restColor = C.textMuted;
  static const Color hoverRestColor = C.text;
  static const Color inactiveColor = C.textFaint;
  static const Color hoverInactiveColor = C.textMuted;

  /// A control that is currently on.
  static const Color activeColor = C.accent;
  static const Color hoverActiveColor = C.primaryFillHover;

  static const Color redColor = C.bad;
  static const Color hoverRedColor = Color(0xFFFF8E8E);

  static const Color surfaceColor = C.chrome;
  static const Color hoverSurfaceColor = C.surfaceHi;

  // kMinInteractiveDimension
  static const double height = 20.0;
  static const double dividerHeight = 12.0;

  static const double buttonSize = 30;
  static const double glyphSize = 18;
  static const double buttonHMargin = 1;
  static const double buttonVMargin = 5;
  static const double iconRadius = C.radiusSm;

  // Depth is a cast shadow on the container, not a Material elevation: M3
  // elevation also tints the surface it lifts, which would drift the toolbar
  // off the console's one surface ramp.
  static const double elevation = 0;
  static const List<BoxShadow> shadow = [
    BoxShadow(color: Color(0x99000000), blurRadius: 18, offset: Offset(0, 6)),
  ];

  static const double dividerSpaceToAction = menuSplitHeight;

  // ---- menus -------------------------------------------------------------
  //
  // Every number below is taken from `labdesk/screens/console_menu.dart`, the
  // console's own menu, rather than chosen here. The two used to be different
  // objects: this one sat a shade darker, threw a hard 0xB3 shadow that read as
  // a grey rim once the menu opened over a light document, and set its lines a
  // size and a half up in the body face. Opened side by side with a machine
  // row's menu they were plainly from two different products.
  //
  //   surface   C.surfaceHi        (was C.surface, one rung down)
  //   radius    C.radius           (unchanged)
  //   shadow    none. The console's row menu carries elevation 18 at 0x59,
  //             which over its near-black table is invisible and over the
  //             white document this toolbar floats on is a grey slab. What
  //             separates that panel is its hairline against a darker plane,
  //             and that works over any wallpaper; the drop shadow was the
  //             single loudest thing about this menu.
  //   row       30 high, 5 in from the panel edge, 9 of padding inside that
  //   type      C.small at w500     (was C.body, 13.5)
  //   split     7 of space, hairline inset to the row margin
  static const double menuBorderRadius = C.radius;

  /// The panel's own inset. The horizontal 5 is what lets a lit row sit inside
  /// the panel instead of running out to its border.
  static const EdgeInsets menuPadding =
      EdgeInsets.symmetric(vertical: 6, horizontal: 5);
  static const double menuButtonBorderRadius = C.radiusSm;

  /// A row, and the space a divider takes between two runs of them.
  static const double menuItemHeight = 30;
  static const double menuSplitHeight = 7;

  static const Color borderColor = C.hairline;

  static const MenuStyle menuStyle = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(C.surfaceHi),
    surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
    shadowColor: WidgetStatePropertyAll(Colors.transparent),
    elevation: WidgetStatePropertyAll(0),
    side: WidgetStatePropertyAll(BorderSide(width: 1, color: C.hairline)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(menuBorderRadius)))),
    padding: WidgetStatePropertyAll(menuPadding),
  );

  static MenuStyle defaultMenuStyle(BuildContext context) => menuStyle;

  /// A control *on* the toolbar row, as opposed to a row inside a menu. It
  /// draws its own pad, so the shape is restated here to keep the menu theme's
  /// focus ring off the toolbar — accent on the row means the control is on.
  static const ButtonStyle defaultMenuButtonStyle = ButtonStyle(
    backgroundColor: WidgetStatePropertyAll(Colors.transparent),
    padding: WidgetStatePropertyAll(EdgeInsets.zero),
    overlayColor: WidgetStatePropertyAll(Colors.transparent),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(menuButtonBorderRadius)),
        side: BorderSide(color: Colors.transparent))),
  );

  /// The toolbar's own container: one hairline, one radius, one cast shadow.
  static BoxDecoration containerDecoration(BorderRadius radius) =>
      BoxDecoration(
        color: surfaceColor,
        border: Border.all(color: borderColor, width: 1),
        borderRadius: radius,
        boxShadow: shadow,
      );

  /// A hairline, not a Material border: 1px of [C.hairline] is the console's
  /// only separator.
  static Widget borderWrapper(Widget child, BorderRadius borderRadius) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: borderColor, width: 1),
        borderRadius: borderRadius,
      ),
      child: child,
    );
  }
}

/// Theme applied to the toolbar row and, because every menu is opened from
/// inside it, to every menu it opens.
///
/// Everything Material would otherwise supply is replaced here: the row's own
/// `MenuBar` chrome, item text and hit surface, the checkbox and radio marks,
/// the dividers, the tooltip and the scale slider. Left as Material, the menus
/// were the loudest remaining tell — a tinted sheet with a blue ripple,
/// hanging under a console.
ThemeData toolbarThemeData(BuildContext context) {
  final base = Theme.of(context);
  return base.copyWith(
    // Menu bodies inherit the plane they sit on, not the video behind them.
    canvasColor: C.surface,
    shadowColor: const Color(0xB3000000),
    textTheme: base.textTheme.apply(
      fontFamily: 'Manrope',
      bodyColor: C.text,
      displayColor: C.text,
    ),
    iconTheme: const IconThemeData(color: C.textMuted, size: 18),
    colorScheme: base.colorScheme.copyWith(
      primary: C.accent,
      onPrimary: C.bg,
      surface: C.surface,
      onSurface: C.text,
      outline: C.hairline,
      error: C.bad,
    ),
    tooltipTheme: toolbarTooltipTheme,
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        minimumSize:
            const WidgetStatePropertyAll(Size(64, ToolbarSkin.menuItemHeight)),
        maximumSize: const WidgetStatePropertyAll(
            Size.fromHeight(ToolbarSkin.menuItemHeight)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding:
            const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 9)),
        textStyle: WidgetStatePropertyAll(C.small(color: C.text)),
        foregroundColor: const WidgetStatePropertyAll(C.text),
        iconColor: const WidgetStatePropertyAll(C.textMuted),
        // No ripple. A menu row lights its own surface and stops there.
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        // A tint of the accent, the way a machine row's menu lights a line —
        // a solid surfaceHi pad was invisible now that the panel is surfaceHi.
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)
                ? C.accent.withOpacity(0.12)
                : Colors.transparent),
        // Focus is a ring, not a brighter fill: keyboard and pointer have to
        // stay tellable apart.
        shape: WidgetStateProperty.resolveWith((states) => RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(ToolbarSkin.menuButtonBorderRadius),
              side: BorderSide(
                  color: states.contains(WidgetState.focused)
                      ? C.accent
                      : Colors.transparent),
            )),
      ),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: C.accent,
      inactiveTrackColor: C.hairline,
      thumbColor: C.accent,
      overlayColor: C.accent.withOpacity(0.12),
      trackHeight: 3,
    ),
    // A run break inside a menu: seven of space with the hairline held to the
    // same 5 the rows are inset by, so the line stops where the rows stop.
    dividerTheme: const DividerThemeData(
      space: ToolbarSkin.dividerSpaceToAction,
      thickness: 1,
      indent: 5,
      endIndent: 5,
      color: C.hairline,
    ),
    // The row is a plain surface; the container behind it already carries the
    // fill, the hairline and the shadow.
    menuBarTheme: const MenuBarThemeData(
      style: MenuStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        elevation: WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder()),
      ),
    ),
    menuTheme: const MenuThemeData(style: ToolbarSkin.menuStyle),
  );
}

/// Tooltips are the console's, not Material's: a hairlined surface panel with
/// an offset shadow, never the dark grey lozenge.
final TooltipThemeData toolbarTooltipTheme = TooltipThemeData(
  waitDuration: const Duration(milliseconds: 400),
  verticalOffset: 20,
  decoration: BoxDecoration(
    color: C.surfaceHi,
    borderRadius: C.roundedSm,
    border: Border.all(color: C.hairline),
    boxShadow: const [
      BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 6)),
    ],
  ),
  textStyle: C.small(color: C.text),
  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
);

// The marks a menu row wears when its setting is on are the console's own
// [LdCheckbox] and [LdRadioMark], not Material's.
//
// Material's `Checkbox` is a fixed 18 across and its `Radio` a fixed 20 —
// neither takes a size — so on a 30-high row set in 12px type they sat a size
// and a half above everything else in the console, and the selected radio was
// mark for mark the glyph the toolbar uses for "recording". This file drew its
// own pair for a while, which meant the toolbar's box was a 15 while the
// settings pages' was a 16 and the two drifted every time either moved. They
// are now literally the objects a settings page builds, at [LdCheckbox.size],
// so a menu opened off the toolbar and a menu opened off a machine row cannot
// disagree about what a mark is.

/// A menu row carrying a setting that is on or off.
///
/// A thin wrapper on [MenuItemButton] rather than `CheckboxMenuButton`, which
/// builds a Material `Checkbox` this skin cannot resize. The contract is the
/// one `CheckboxMenuButton` has: a null [onChanged] disables the row, and
/// activating it reports the opposite of [value].
///
/// The mark is trailing, which is the reason these exist as functions at all.
/// Material hangs it off the leading edge, so a menu holding both settings and
/// plain actions — which is every menu this toolbar opens — starts its labels
/// on two different columns and reads as two lists stacked. A machine row's
/// menu puts the state at the right-hand edge and keeps one left margin, and
/// that is the shape being matched.
Widget toolbarCheckMenuItem({
  Key? key,
  required bool? value,
  required ValueChanged<bool?>? onChanged,
  required Widget? child,
}) {
  final on = value ?? false;
  return Semantics(
    checked: on,
    child: MenuItemButton(
      key: key,
      onPressed: onChanged == null ? null : () => onChanged(!on),
      trailingIcon: LdCheckbox(on: on, enabled: onChanged != null),
      child: child,
    ),
  );
}

/// A menu row that is one choice out of a set.
///
/// Same contract as `RadioMenuButton`: activating it reports [value], and
/// [closeOnActivate] decides whether the menu stays open behind the change.
Widget toolbarRadioMenuItem<T>({
  Key? key,
  required T value,
  required T? groupValue,
  required ValueChanged<T?>? onChanged,
  required Widget? child,
  bool closeOnActivate = true,
}) {
  final selected = value == groupValue;
  return Semantics(
    checked: selected,
    inMutuallyExclusiveGroup: true,
    child: MenuItemButton(
      key: key,
      closeOnActivate: closeOnActivate,
      onPressed: onChanged == null ? null : () => onChanged(value),
      trailingIcon: LdRadioMark(selected: selected, enabled: onChanged != null),
      child: child,
    ),
  );
}

/// A display with its number written inside the screen.
///
/// The toolbar has to say "monitor 2" in the width of one icon in three
/// different places, so it says it once, here. The digit is set in the
/// console's data face, because that is what it is.
Widget displayIndexGlyph(String label, Color color,
    {double size = ToolbarSkin.glyphSize}) {
  return SizedBox(
    width: size,
    height: size,
    // The screen's optical centre sits above the glyph's box centre; the lower
    // band of the glyph belongs to the stand.
    child: Stack(
      alignment: const Alignment(0, -0.09),
      children: [
        LdIcon(LdIcons.display, size: size, color: color),
        Text(
          label,
          textAlign: TextAlign.center,
          style: C
              .data(size: size * 0.52, color: color, w: FontWeight.w700)
              .copyWith(height: 1),
        ),
      ],
    ),
  );
}

/// The pad and the glyph, shared by the plain and the submenu button so the
/// two can never drift apart.
class ToolbarButtonSurface extends StatelessWidget {
  const ToolbarButtonSurface({
    super.key,
    required this.hover,
    this.focused = false,
    required this.color,
    required this.hoverColor,
    this.glyph,
    this.iconBuilder,
  });

  final bool hover;
  final bool focused;
  final Color color;
  final Color hoverColor;

  /// A path from [LdIcons].
  final String? glyph;

  /// For the controls whose icon is not a single glyph — a numbered display,
  /// the scale map of the desk. Handed the resolved foreground colour so those
  /// controls light up on hover like everything else.
  final Widget Function(Color fg)? iconBuilder;

  @override
  Widget build(BuildContext context) {
    final fg = hover ? hoverColor : color;
    final icon = iconBuilder?.call(fg) ??
        LdIcon(glyph!, size: ToolbarSkin.glyphSize, color: fg);
    return AnimatedContainer(
      duration: C.fast,
      curve: Curves.easeOut,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: hover ? ToolbarSkin.hoverSurfaceColor : Colors.transparent,
        // The fill alone is an 11-value step off the toolbar surface, which is
        // not enough to read over live video; the hairline gives the pad an
        // edge without inventing a colour outside the ramp.
        border: Border.all(
            color: focused
                ? C.focusRing
                : (hover ? C.hairline : Colors.transparent),
            width: focused ? C.focusRingWidth : 1),
        borderRadius: BorderRadius.circular(ToolbarSkin.iconRadius),
      ),
      child: icon,
    );
  }
}

/// One toolbar control that does something when pressed.
///
/// [tooltip] arrives already translated: the presentation layer is kept clear
/// of the app's FFI-backed i18n so it can be rendered without a session.
class ToolbarIconButton extends StatefulWidget {
  const ToolbarIconButton({
    super.key,
    this.glyph,
    this.iconBuilder,
    required this.tooltip,
    required this.color,
    required this.hoverColor,
    required this.onPressed,
    this.hMargin,
    this.vMargin,
    this.topLevel = true,
    this.width,
  });

  /// A path from [LdIcons].
  final String? glyph;
  final Widget Function(Color fg)? iconBuilder;
  final String tooltip;
  final Color color;
  final Color hoverColor;
  final VoidCallback? onPressed;
  final double? hMargin;
  final double? vMargin;
  final bool topLevel;
  final double? width;

  @override
  State<ToolbarIconButton> createState() => _ToolbarIconButtonState();
}

class _ToolbarIconButtonState extends State<ToolbarIconButton> {
  bool hover = false;
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    assert(widget.glyph != null || widget.iconBuilder != null);
    final surface = ToolbarButtonSurface(
      hover: hover,
      focused: focused,
      color: widget.color,
      hoverColor: widget.hoverColor,
      glyph: widget.glyph,
      iconBuilder: widget.iconBuilder,
    );
    final button = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: widget.hMargin ?? ToolbarSkin.buttonHMargin,
        vertical: widget.vMargin ?? ToolbarSkin.buttonVMargin,
      ),
      child: SizedBox(
        width: widget.width ?? ToolbarSkin.buttonSize,
        height: ToolbarSkin.buttonSize,
        child: widget.topLevel
            ? TextButton(
                style: ToolbarSkin.defaultMenuButtonStyle.copyWith(
                  minimumSize: const WidgetStatePropertyAll(Size.zero),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onHover: (value) => setState(() => hover = value),
                onFocusChange: (value) => setState(() => focused = value),
                onPressed: widget.onPressed,
                child: surface,
              )
            : MenuItemButton(
                style: ToolbarSkin.defaultMenuButtonStyle,
                onHover: (value) => setState(() => hover = value),
                onFocusChange: (value) => setState(() => focused = value),
                onPressed: widget.onPressed,
                child: surface,
              ),
      ),
    );
    return Semantics(
      label: widget.tooltip,
      child: Tooltip(
          message: widget.tooltip, excludeFromSemantics: true, child: button),
    );
  }
}

/// The look of the tab strip that hosts the sessions.
///
/// The strip and the floating toolbar are two faces of the same window, so
/// they live in one file and share [ToolbarButtonSurface] outright: a window
/// whose title bar and whose toolbar disagree about what a hovered control
/// looks like is a window assembled from two products.
///
/// It is also here for the same reason the toolbar's look is:
/// `desktop/widgets/tabbar_widget.dart` cannot be built in a test — it needs
/// FFI, a window handle and `common.dart` — so the parts that can be judged by
/// eye take plain values and are rendered by `tool/shots/tabbar_test.dart`.
class TabSkin {
  TabSkin._();

  /// The strip is the window's title bar, so it wears the chrome plane, and
  /// the tabs climb the same surface ramp the rest of the console selects on:
  /// resting on the strip, one step up under the cursor, two steps up when
  /// current. The current tab is the brightest thing in the strip, which is
  /// the whole job.
  ///
  /// The obvious alternative — the current tab painted in the *content* colour
  /// so it reads as a hole through to the page — inverts here, because the
  /// console's chrome is lighter than its content plane, not darker. It made
  /// the current tab the dimmest tab in the strip and the hovered one the
  /// brightest.
  static const barColor = C.chrome;
  static const selectedColor = C.surfaceHi;
  static const hoverColor = C.surface;

  /// The machine's platform, or the kind of session when the platform is not
  /// known yet.
  static const glyphSize = 14.0;

  /// The kind of session, when the platform is already leading the tab. Smaller
  /// and fainter, because inside one window it is the same on every tab and
  /// only earns its place across windows.
  static const typeGlyphSize = 12.0;

  /// Gap after the leading glyph, and before the trailing one.
  static const glyphGap = 7.0;
  static const typeGlyphGap = 8.0;

  static const closeSize = 18.0;
  static const closeGlyphSize = 12.0;

  /// The only accent in the strip, and only ever under the current tab.
  static const indicatorColor = C.accent;
  static const indicatorHeight = 2.0;

  static Color labelColor(bool selected, bool hover) =>
      selected || hover ? C.text : C.textMuted;

  static TextStyle labelStyle(bool selected, bool hover) => C.small(
        color: labelColor(selected, hover),
        w: selected ? FontWeight.w600 : FontWeight.w500,
      );

  /// A tab's leading glyph never takes the accent: the underline already says
  /// which tab is current, and a second signal for one state is noise.
  static Color glyphColor(bool selected, bool hover) =>
      selected ? C.text : (hover ? C.textMuted : C.textFaint);
}

/// One tab's plane, its current-tab rule and the separator that follows it.
///
/// The rule is painted as a foreground decoration rather than a border so it
/// costs no height: the strip is 28 logical pixels tall and has none to give.
class TabSurface extends StatelessWidget {
  const TabSurface({
    super.key,
    required this.height,
    required this.selected,
    required this.hover,
    required this.showIndicator,
    required this.showDivider,
    required this.child,
    this.close,
  });

  final double height;
  final bool selected;
  final bool hover;

  /// Whether this window marks its current tab at all. The main window's own
  /// tabs do not.
  final bool showIndicator;
  final bool showDivider;

  /// The tab's content: glyph, label, and whatever the owning page adds.
  final Widget child;

  /// The close affordance, which keeps its slot whether or not it is showing so
  /// the label does not shift under the cursor.
  final Widget? close;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected && showIndicator
                  ? TabSkin.indicatorColor
                  : Colors.transparent,
              width: TabSkin.indicatorHeight,
            ),
          ),
        ),
        child: AnimatedContainer(
          duration: C.fast,
          curve: Curves.easeOut,
          height: height,
          padding: const EdgeInsets.only(left: 10, right: 6),
          color: selected
              ? TabSkin.selectedColor
              : (hover ? TabSkin.hoverColor : Colors.transparent),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [child, if (close != null) close!],
          ),
        ),
      ),
      Opacity(
        opacity: showDivider ? 1 : 0,
        child: VerticalDivider(
          width: 1,
          indent: 9,
          endIndent: 9,
          color: C.hairline,
        ),
      ),
    ]);
  }
}

/// The tab's close affordance: hidden until the tab is under the cursor, and
/// red only once the cursor is on the affordance itself. A red mark on every
/// tab the pointer crosses would be shouting about a session it has not been
/// asked to end.
class TabCloseButton extends StatefulWidget {
  const TabCloseButton({super.key, required this.visible, this.onClose});

  final bool visible;
  final VoidCallback? onClose;

  @override
  State<TabCloseButton> createState() => _TabCloseButtonState();
}

class _TabCloseButtonState extends State<TabCloseButton> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: SizedBox(
        width: TabSkin.closeSize,
        height: TabSkin.closeSize,
        child: !widget.visible
            ? null
            : MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => hover = true),
                onExit: (_) => setState(() => hover = false),
                child: GestureDetector(
                  onTap: widget.onClose,
                  child: ToolbarButtonSurface(
                    hover: hover,
                    color: C.textMuted,
                    hoverColor: C.bad,
                    iconBuilder: (fg) => LdIcon(LdIcons.close,
                        size: TabSkin.closeGlyphSize, color: fg),
                  ),
                ),
              ),
      ),
    );
  }
}

/// One of the window's own buttons: minimise, maximise, close, add a tab.
///
/// The same pad as every other control in the window, inset from the edge of
/// the strip so a 28-pixel-tall title bar does not end up with a hover plane
/// running from its top edge to its bottom one.
class WindowButtonSurface extends StatelessWidget {
  const WindowButtonSurface({
    super.key,
    required this.hover,
    required this.boxSize,
    required this.color,
    required this.hoverColor,
    required this.iconBuilder,
  });

  final bool hover;
  final double boxSize;
  final Color color;
  final Color hoverColor;
  final Widget Function(Color fg) iconBuilder;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: boxSize,
      width: boxSize,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: ToolbarButtonSurface(
          hover: hover,
          color: color,
          hoverColor: hoverColor,
          iconBuilder: iconBuilder,
        ),
      ),
    );
  }
}

/// One toolbar control that opens a menu.
class ToolbarSubmenuButton extends StatefulWidget {
  ToolbarSubmenuButton({
    super.key,
    this.glyph,
    this.iconBuilder,
    required this.tooltip,
    required this.color,
    required this.hoverColor,
    required this.menuChildrenGetter,
    this.menuChildWrapper,
    this.menuStyle,
    this.width,
  });

  final String tooltip;

  /// A path from [LdIcons].
  final String? glyph;
  final Widget Function(Color fg)? iconBuilder;
  final Color color;
  final Color hoverColor;
  final List<Widget> Function(ToolbarSubmenuButtonState state)
      menuChildrenGetter;

  /// The toolbar wraps every menu child so it can keep track of the pointer
  /// for the far machine. Nothing in the look depends on it, so it is handed
  /// in rather than known about here.
  final Widget Function(Widget child)? menuChildWrapper;
  final MenuStyle? menuStyle;
  final double? width;

  @override
  State<ToolbarSubmenuButton> createState() => ToolbarSubmenuButtonState();
}

class ToolbarSubmenuButtonState extends State<ToolbarSubmenuButton> {
  bool hover = false;

  @override // discard @protected
  void setState(VoidCallback fn) {
    super.setState(fn);
  }

  @override
  Widget build(BuildContext context) {
    assert(widget.glyph != null || widget.iconBuilder != null);
    final button = SizedBox(
        width: widget.width ??
            ToolbarSkin.buttonSize,
        height: ToolbarSkin.buttonSize,
        child: SubmenuButton(
            menuStyle: widget.menuStyle ?? ToolbarSkin.menuStyle,
            style: ToolbarSkin.defaultMenuButtonStyle,
            onHover: (value) => setState(() {
                  hover = value;
                }),
            child: Tooltip(
                message: widget.tooltip,
                child: ToolbarButtonSurface(
                  hover: hover,
                  color: widget.color,
                  hoverColor: widget.hoverColor,
                  glyph: widget.glyph,
                  iconBuilder: widget.iconBuilder,
                )),
            menuChildren: widget
                .menuChildrenGetter(this)
                .map((e) => widget.menuChildWrapper?.call(e) ?? e)
                .toList()));
    return MenuBar(children: [
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ToolbarSkin.buttonHMargin,
          vertical: ToolbarSkin.buttonVMargin,
        ),
        child: button,
      )
    ]);
  }
}

// ---------------------------------------------------------------------------
// The connection manager.
//
// The window the *controlled* machine shows when somebody asks to connect to
// it: who is asking, what they are asking for, the permission set they would
// be granted, and the two answers. It is the same window family as the toolbar
// above, so it is built from the same surface ramp, the same hairline, the same
// glyph set and the same one accent — a machine that is being asked for should
// not look like it belongs to a different product than the machine doing the
// asking.
//
// The pieces are here rather than in `desktop/pages/server_page.dart` for the
// same reason the toolbar's are: that page cannot be built without FFI and the
// app's shared `common.dart`, so it could not be looked at. These take plain
// values, the page hands them translated strings and its own callbacks, and
// `tool/shots/cm_test.dart` renders them — so what the shot shows is what
// ships.

/// The connection manager's own measurements.
class CmSkin {
  CmSkin._();

  /// The window is 300 logical pixels wide. Every measurement below is spent
  /// against that, which is why the permission set is a list of labelled rows
  /// and not a grid of unlabelled tiles: at this width a grid can afford the
  /// icons or the words, and the words are the ones that carry the meaning.
  static const pad = 10.0;

  /// Sized so that all eight permissions a Windows session can carry are on
  /// screen at the moment the request is being answered. A permission that has
  /// to be scrolled to is a permission that was not read.
  static const rowHeight = 26.0;
  static const buttonHeight = 34.0;

  static BoxDecoration get panel => BoxDecoration(
        color: C.surface,
        borderRadius: C.rounded,
        border: Border.all(color: C.hairline),
      );
}

/// The theme the connection-manager window runs under.
///
/// Narrower than [toolbarThemeData] on purpose: this window also hosts the chat
/// page and the file-transfer log, neither of which belongs to this file, so it
/// sets the things that would otherwise betray the console — the tooltip
/// lozenge, the Material blue, the scrollbar, the type — and leaves the rest of
/// Material alone.
ThemeData cmThemeData(BuildContext context) {
  final base = Theme.of(context);
  return base.copyWith(
    scaffoldBackgroundColor: C.bg,
    canvasColor: C.bg,
    dividerColor: C.hairline,
    textTheme: base.textTheme.apply(
      fontFamily: 'Manrope',
      bodyColor: C.text,
      displayColor: C.text,
    ),
    iconTheme: const IconThemeData(color: C.textMuted, size: 18),
    colorScheme: base.colorScheme.copyWith(
      primary: C.accent,
      onPrimary: C.bg,
      surface: C.surface,
      onSurface: C.text,
      outline: C.hairline,
      error: C.bad,
    ),
    tooltipTheme: toolbarTooltipTheme,
    dividerTheme:
        const DividerThemeData(space: 1, thickness: 1, color: C.hairline),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: const WidgetStatePropertyAll(C.hairline),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
    ),
  );
}

/// A status mark that is readable before it is coloured: the dot says *there is
/// a state here*, the word beside it says which one.
class CmStatusDot extends StatelessWidget {
  const CmStatusDot({super.key, required this.color, this.size = 7});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// Who is asking, and what for.
///
/// The order is deliberate, and it is the order a person answers the question
/// in. While the request is unanswered the consent line comes first, at heading
/// weight, because it *is* the question; under it the name the caller claims,
/// and — set in the console's data face, because it is an identifier and it is
/// the part that can actually be checked against whoever phoned — the id; under
/// that, in words, the kind of access being asked for.
///
/// Once the session is running the panel inverts: identity first, and the state
/// drops to a quiet line at the foot with the elapsed time beside it.
class CmIdentity extends StatelessWidget {
  const CmIdentity({
    super.key,
    required this.name,
    required this.peerId,
    required this.kindGlyph,
    required this.kindLabel,
    required this.statusLabel,
    required this.statusColor,
    required this.pending,
    this.avatar,
    this.elapsed,
    this.action,
  });

  /// The name the far end sends. It is not proof of anything, so it is set as a
  /// name and the id is set as data.
  final String name;
  final String peerId;

  /// The kind of access: a screen, a terminal, files, a camera, a port.
  final String kindGlyph;
  final String kindLabel;

  /// Already translated by the caller.
  final String statusLabel;
  final Color statusColor;

  /// The request has not been answered yet.
  final bool pending;

  /// The peer's picture when it has one; the initial block otherwise.
  final Widget? avatar;

  /// Time since the session was accepted, in the data face.
  final String? elapsed;

  /// Chat, or the file-transfer log.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final identity = Row(
      children: [
        SizedBox(
            width: 40, height: 40, child: avatar ?? CmInitialAvatar(name: name)),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (name.isNotEmpty) ...[
                Text(name,
                    style: C.h2(), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
              ],
              Text(
                peerId,
                style: C.data(
                  size: 14,
                  color: name.isEmpty ? C.text : C.textMuted,
                  w: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (action != null) action!,
      ],
    );

    final kind = Row(
      children: [
        LdIcon(kindGlyph, size: 15, color: C.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(kindLabel,
              style: C.small(color: C.text, w: FontWeight.w600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );

    return Container(
      decoration: CmSkin.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The question is a header band with a rule under it, which is what a
          // console dialog is: the accent glyph, the title, then the hairline
          // that runs the full width of the panel. Set inside the panel's own
          // padding — as an indented divider under an indented line — it was a
          // heading that happened to have a rule, and the one window in the
          // product that asks a person a question looked like nothing else that
          // asks a person a question.
          if (pending) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: LdIcon(LdIcons.shield, size: 17, color: C.accent),
                  ),
                  const SizedBox(width: 9),
                  Expanded(child: Text(statusLabel, style: C.h2())),
                ],
              ),
            ),
            const Divider(height: 1, thickness: 1, color: C.hairline),
          ],
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                identity,
                const SizedBox(height: 12),
                kind,
                if (!pending) ...[
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      CmStatusDot(color: statusColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(statusLabel,
                            style: C.small(color: C.textMuted),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (elapsed != null)
                        Text(elapsed!,
                            style: C.data(size: 12, color: C.textMuted)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The peer with no picture. A rounded square on the console's radius, not a
/// circle: a circle here would be the only one in the product.
class CmInitialAvatar extends StatelessWidget {
  const CmInitialAvatar({super.key, required this.name, this.color});

  final String name;

  /// The colour the app derives from the peer's name, so two callers are not
  /// the same block. Left null where there is no app to derive it.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: C.surfaceHi,
        borderRadius: C.rounded,
        border: Border.all(
            color: color ?? C.hairline, width: color != null ? 1.5 : 1),
      ),
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: C.data(size: 18, color: color ?? C.textMuted, w: FontWeight.w700),
      ),
    );
  }
}

/// The heading over the permission set, and the one place the window says the
/// set cannot be touched.
class CmPermissionHeader extends StatelessWidget {
  const CmPermissionHeader(
      {super.key, required this.label, required this.locked});

  /// Already translated.
  final String label;

  /// The deployment has taken permission changes away from this window. Said
  /// once, here, rather than eight times down the list.
  final bool locked;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(label.toUpperCase(),
                  style:
                      C.micro(color: C.textFaint).copyWith(letterSpacing: 0.8),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            if (locked) const LdIcon(LdIcons.lock, size: 13, color: C.textFaint),
          ],
        ),
      );
}

/// The permission set, and the promise that none of it is hidden by accident.
///
/// Two rules, both of them about a consent surface rather than about looks:
///
/// The list shows whole rows only. When the panel is shorter than the set — the
/// window offering "Accept and Elevate" is the case that does it — the viewport
/// is cut to a whole multiple of [CmSkin.rowHeight] instead of wherever the
/// panel's edge happened to land. A permission sliced through the middle reads
/// as a rendering fault, and worse, the half of it that survives is the label:
/// the reader cannot tell whether the thing they can half-see is on or off.
///
/// And when rows are out of view the rail says so. It is drawn in [C.textFaint]
/// rather than the hairline the rest of the console scrolls with, because here
/// it is not furniture — it is the only thing on the panel claiming that the
/// eight permissions the person is about to grant are not the six they can see.
/// It paints nothing at all when the whole set fits, which is the common case.
class CmPermissionPanel extends StatefulWidget {
  const CmPermissionPanel({
    super.key,
    required this.label,
    required this.locked,
    required this.rows,
  });

  /// Already translated.
  final String label;
  final bool locked;
  final List<Widget> rows;

  @override
  State<CmPermissionPanel> createState() => _CmPermissionPanelState();
}

class _CmPermissionPanelState extends State<CmPermissionPanel> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
      decoration: CmSkin.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CmPermissionHeader(label: widget.label, locked: widget.locked),
          Expanded(
            child: LayoutBuilder(builder: (context, constraints) {
              final whole = constraints.maxHeight.isFinite
                  ? (constraints.maxHeight / CmSkin.rowHeight)
                      .floor()
                      .clamp(1, widget.rows.length)
                  : widget.rows.length;
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  height: whole * CmSkin.rowHeight,
                  child: RawScrollbar(
                    controller: _controller,
                    thumbVisibility: true,
                    thumbColor: C.textFaint,
                    thickness: 4,
                    radius: const Radius.circular(2),
                    child: ListView(
                      controller: _controller,
                      padding: EdgeInsets.zero,
                      children: widget.rows,
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

/// One permission, as state rather than as decoration.
///
/// The tile this replaced was a coloured square with a white glyph in it and
/// nothing else: to read whether the far end had your clipboard you had to know
/// the icon, know that blue meant on, and hover to find out which permission the
/// tile even was. Here the row says what it is in words, says ON or OFF in
/// words, and puts the knob on the side that matches — so the state survives
/// colour blindness, a bad panel, and a glance.
///
/// When the deployment forbids changing permissions the row keeps saying what it
/// says and stops offering: no hover, no pointer, everything one step back. A
/// control that looks live and does nothing is worse than one that admits it.
///
/// Two things it deliberately does not do. It does not carry a tooltip: the
/// window is 250 wide at its narrowest and a tooltip opened on one permission
/// covered the *label* of the two under it, so pointing at one line of a consent
/// list hid two others. The string is still handed to [Semantics], where a
/// screen reader can have it without anything being painted over. And below 240
/// the label drops a point and the ON/OFF word moves under it rather than
/// beside it — the row is 26 tall either way, and the state stays a word at
/// every width the window can be handed. It used to be dropped at that width on
/// the grounds that the knob still says the same thing by its position, which
/// is exactly the reasoning the tile this row replaced was built on.
class CmPermissionRow extends StatefulWidget {
  const CmPermissionRow({
    super.key,
    required this.glyph,
    required this.label,
    required this.tooltip,
    required this.on,
    required this.canModify,
    required this.onChanged,
  });

  final String glyph;

  /// Already translated.
  final String label;

  /// Already translated and already carrying the state, exactly as it was.
  /// Spoken, not painted: it is the row's [Semantics] label.
  final String tooltip;
  final bool on;
  final bool canModify;
  final ValueChanged<bool> onChanged;

  @override
  State<CmPermissionRow> createState() => _CmPermissionRowState();
}

/// The ON/OFF word's colour, so the wide row and the narrow one cannot drift.
Color _stateColor(bool live, bool on) => live
    ? (on ? C.text : C.textFaint)
    : (on ? C.textMuted : C.textFaint);

class _CmPermissionRowState extends State<CmPermissionRow> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final live = widget.canModify;
    // A locked row steps back a whole level, but it does not stop saying which
    // of the two things it is: a permission that is on and cannot be revoked is
    // the most important thing on the panel, not the least.
    final labelColor = live
        ? (widget.on ? C.text : C.textMuted)
        : (widget.on ? C.textMuted : C.textFaint);
    final glyphColor = live
        ? (widget.on ? C.accent : C.textFaint)
        : (widget.on ? C.textMuted : C.textFaint);

    return Semantics(
      label: widget.tooltip,
      // The row this replaced was an InkWell, so it took keyboard focus and
      // answered Enter. That is kept: the page it sits on is wrapped in an
      // ExcludeFocus in the shipping configuration, and the right way to have
      // no focus here is that wrapper deciding it, not the control quietly
      // losing the ability.
      child: FocusableActionDetector(
        enabled: live,
        mouseCursor: live ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onChanged(!widget.on);
            return null;
          }),
        },
        child: GestureDetector(
          onTap: live ? () => widget.onChanged(!widget.on) : null,
          child: LayoutBuilder(builder: (context, constraints) {
            final tight = constraints.maxWidth < 240;
            return AnimatedContainer(
              duration: C.fast,
              curve: Curves.easeOut,
              height: CmSkin.rowHeight,
              padding: EdgeInsets.symmetric(horizontal: tight ? 6 : 8),
              decoration: BoxDecoration(
                color:
                    (_hover || _focus) && live ? C.surfaceHi : Colors.transparent,
                borderRadius: C.roundedSm,
                border: Border.all(
                    color: _focus && live ? C.text : Colors.transparent),
              ),
              child: Row(
                children: [
                  LdIcon(widget.glyph, size: 15, color: glyphColor),
                  SizedBox(width: tight ? 7 : 9),
                  Expanded(
                    child: tight
                        // No room for the word beside the label, so it goes
                        // under it. It does not go away: the knob's position
                        // is the one part of this row a person cannot name,
                        // and a consent list that stops saying ON at the width
                        // it is most often opened at is a consent list that
                        // stops being read.
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(widget.label,
                                  style: C
                                      .small(
                                          color: labelColor,
                                          w: FontWeight.w600)
                                      .copyWith(fontSize: 11, height: 1.15),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              Text(
                                widget.on ? 'ON' : 'OFF',
                                style: C
                                    .data(
                                      size: 9,
                                      color: _stateColor(live, widget.on),
                                      w: FontWeight.w700,
                                    )
                                    .copyWith(height: 1.1),
                              ),
                            ],
                          )
                        : Text(widget.label,
                            style: C.small(
                                color: labelColor, w: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                  ),
                  if (!tight) ...[
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 25,
                      child: Text(
                        widget.on ? 'ON' : 'OFF',
                        textAlign: TextAlign.right,
                        style: C.data(
                          size: 10,
                          color: _stateColor(live, widget.on),
                          w: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                  SizedBox(width: tight ? 6 : 8),
                  CmToggleTrack(on: widget.on, live: live),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }
}

/// The knob and its track. The position is the signal; the colour agrees with
/// it and is never asked to carry it alone.
class CmToggleTrack extends StatelessWidget {
  const CmToggleTrack({super.key, required this.on, required this.live});

  final bool on;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final knob =
        live ? (on ? C.accent : C.textMuted) : (on ? C.textMuted : C.textFaint);
    return AnimatedContainer(
      duration: C.fast,
      curve: Curves.easeOut,
      width: 24,
      height: 14,
      padding: const EdgeInsets.all(2),
      alignment: on ? Alignment.centerRight : Alignment.centerLeft,
      decoration: BoxDecoration(
        color: on && live ? C.accent.withOpacity(0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
            color: !on
                ? C.hairline
                : (live ? C.accent.withOpacity(0.55) : C.textFaint)),
      ),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: knob, shape: BoxShape.circle),
      ),
    );
  }
}

/// What an action means, which is the only thing that decides how it is drawn.
enum CmTone {
  /// The deliberate act: accepting, elevating, taking the call.
  accent,

  /// Ending something: disconnecting, hanging up.
  danger,

  /// The other answer, and everything that is neither.
  neutral,
}

/// One of the window's answers.
///
/// Nothing here is a filled slab, and that is a safety decision rather than a
/// stylistic one. The pair at the foot of an unanswered request is *Accept* and
/// *Cancel*; a solid accent rectangle beside a grey outline tells the eye — and
/// the hand that is already moving — which one the product would prefer. So the
/// two are the same height, the same width, the same type at the same weight,
/// and both labels are set in the console's full-strength text colour. What
/// Accept carries instead is the accent frame, the accent wash and a glyph:
/// enough that it is unmistakably the consequential one, not so much that it is
/// the easy one.
class CmActionButton extends StatefulWidget {
  const CmActionButton({
    super.key,
    required this.label,
    required this.tone,
    this.glyph,
    this.onPressed,
    this.onTapDown,
    this.tooltip,
  });

  /// Already translated.
  final String label;
  final CmTone tone;
  final String? glyph;
  final VoidCallback? onPressed;

  /// For the one control that opens a menu where it was pressed.
  final GestureTapDownCallback? onTapDown;

  /// Already translated.
  final String? tooltip;

  @override
  State<CmActionButton> createState() => _CmActionButtonState();
}

class _CmActionButtonState extends State<CmActionButton> {
  bool _hover = false;
  bool _down = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final neutral = widget.tone == CmTone.neutral;
    final live = widget.onPressed != null || widget.onTapDown != null;
    final tint = switch (widget.tone) {
      CmTone.accent => C.accent,
      CmTone.danger => C.bad,
      CmTone.neutral => C.hairline,
    };
    // A dead answer says so the way every other dead control in the console
    // does: the fill goes, the frame drops to [C.disabledBorder] and the label
    // and its glyph step back to [C.textFaint]. A greyed-down tone would still
    // have read as the consequential button.
    final fg = !live
        ? C.textFaint
        : (widget.tone == CmTone.danger ? C.bad : C.text);

    // Kept focusable, and given a ring: the buttons this replaced were InkWells
    // and answered the keyboard, and an answer to a consent question that can
    // only be given with a mouse is an answer some people cannot give. Whether
    // this page takes focus at all stays the decision of the ExcludeFocus the
    // page is wrapped in.
    final button = FocusableActionDetector(
      enabled: live,
      mouseCursor: live ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onPressed?.call();
          return null;
        }),
      },
      child: GestureDetector(
        onTapDown: !live
            ? null
            : (details) {
                setState(() => _down = true);
                widget.onTapDown?.call(details);
              },
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: C.fast,
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _down ? 1 : 0, 0),
          height: CmSkin.buttonHeight,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // Hover raises the fill, focus does not. Both used to, which left
            // the keyboard's button and the pointer's button painted the same
            // and put a second, brighter version of a tone next to the resting
            // one — read as "this is the default answer" rather than "this is
            // the one being pointed at". The ring says where the keyboard is
            // and nothing else does.
            color: !live
                ? Colors.transparent
                : neutral
                    ? (_hover ? C.surfaceHi : Colors.transparent)
                    : tint.withOpacity(_hover ? 0.22 : 0.12),
            borderRadius: C.roundedSm,
            border: Border.all(
              // The ring is [C.focusRing] at [C.focusRingWidth], the one the
              // whole console answers the keyboard with. This pair used to draw
              // its own white ring on the argument that an accent ring around
              // Cancel misnames it; what it actually did was make the only
              // window in the product that asks a question the only window
              // whose focus looks like something else. The tones say which
              // button is which; the ring says where the keyboard is.
              color: !live
                  ? C.disabledBorder
                  : _focus
                      ? C.focusRing
                      : (neutral
                          ? C.hairline
                          : tint.withOpacity(_hover ? 0.9 : 0.65)),
              width: _focus && live
                  ? C.focusRingWidth
                  : (neutral || !live ? 1 : 1.4),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.glyph != null) ...[
                LdIcon(widget.glyph!, size: 15, color: fg),
                const SizedBox(width: 8),
              ],
              // Scaled down rather than elided. Half the labels here are verbs
              // the person is about to act on — "Stop voice call" clipped to
              // "Stop voice c…" is a button that has stopped saying what it
              // does, and the German for it is longer still.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    widget.label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: C.small(color: fg, w: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return widget.tooltip == null
        ? button
        : Tooltip(message: widget.tooltip!, child: button);
  }
}
