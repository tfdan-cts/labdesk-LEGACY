import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// LabDesk's own glyph set.
///
/// Every icon in the product used to come from Material, which is why the
/// application still read as the one it was derived from: a toolbar of
/// Material glyphs is a Material product no matter what the type and colour
/// do. These are drawn to one system instead.
///
/// The system, and it is not negotiable per-glyph:
///   - a 24x24 box, with the drawing inside a 20x20 optical area
///   - one stroke weight, 1.75, round cap and round join, never filled
///   - square corners are radius 2; nothing is a perfect circle unless the
///     thing itself is round (a dot, a lens)
///   - horizontals and verticals sit on the half-pixel grid so they stay crisp
///     at 16 and 24
///   - one idea per glyph. Where Material draws the object, these draw the
///     action being taken on it.
class LdIcons {
  LdIcons._();

  // ---- console navigation ------------------------------------------------


  /// Connect: a plug going in. It used to be a screen with a signal leaving
  /// it, which made it the fourth rounded-rectangle monitor in a set that only
  /// needs one — and at 16 the arcs that carried the whole meaning were the
  /// first thing to disappear. A plug has a silhouette no other glyph here has.
  static const connect = 'M9 3.5v4.5 M15 3.5v4.5 '
      'M6 8h12v3.5a6 6 0 0 1-12 0z M12 17.5v3';

  /// Fleet: the machines stacked as one deck. Four squares in a grid was the
  /// same drawing as [viewCards] — two different ideas arriving as one mark —
  /// so the set is drawn as a set of *machines* rather than as a layout.
  static const fleet =
      'M4.5 10.5h10a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1h-10a1 1 0 0 1-1-1v-7'
      'a1 1 0 0 1 1-1z M7 8h9.5a1 1 0 0 1 1 1v8.5 M9.5 5.5h9a1 1 0 0 1 1 1v9 '
      'M6.75 16.25h.01';

  /// Health: a reading taken over time, not a heart.
  static const health = 'M3 12h3.5l2-5 3 10 2.5-5H21';

  /// Terminal: the prompt itself, with the window taken off it. Framed, it was
  /// [machine] with a two-pixel `>_` inside, and at 16 the two were the same
  /// glyph. Unframed, the caret owns the whole box and nothing else in the set
  /// looks like it.
  static const terminal = 'M5 6.5l5.5 5.5L5 17.5 M13 17.5h6';

  /// Actions: a single deliberate act, not a storm.
  static const actions = 'M13.5 3l-8 10h5l-1.5 8 8-10h-5z';

  /// This machine: the box itself, stood on its end, with its vents and its
  /// lamp. Drawn as a screen it was indistinguishable from [display] at row
  /// size; the machine is the thing under the desk, not the thing on it.
  static const machine =
      'M6.5 4h11a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1V5'
      'a1 1 0 0 1 1-1z M9 8h6 M9 11h6 M12 16.5h.01';

  /// Settings: the levers, not a gear.
  static const settings = 'M4 7h6 M14 7h6 M4 17h10 M18 17h2 '
      'M12 4.5v5 M16 14.5v5';

  // ---- peer list ---------------------------------------------------------

  /// Recent: elapsed time.
  static const recent = 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17z '
      'M12 7.5V12l3 2';

  /// Favourite: a marked machine.
  static const favourite = 'M12 3.75l2.6 5.3 5.9.85-4.25 4.15 1 5.85L12 17.15 '
      '6.75 19.9l1-5.85L3.5 9.9l5.9-.85z';

  /// Discovered: something found on the local network.
  static const discovered = 'M12 12.5a1 1 0 1 0 0-1 1 1 0 0 0 0 1z '
      'M8.5 15.5a5 5 0 0 1 0-7 M15.5 8.5a5 5 0 0 1 0 7 '
      'M5.5 18.5a9 9 0 0 1 0-13 M18.5 5.5a9 9 0 0 1 0 13';

  /// Address book: the shared list. The head and shoulders that used to sit on
  /// the cover were four curves inside a 12-unit box, which is more detail than
  /// a 16px glyph can hold; the rings on the spine are what say "book", so the
  /// cover carries entries instead of a portrait.
  static const addressBook =
      'M7 3.5h12a1 1 0 0 1 1 1v15a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1v-15a1 1 0 0 1 1-1z '
      'M4 8h3 M4 12h3 M4 16h3 M10 9.5h6 M10 14h3.5';

  /// Group: machines gathered under one name.
  static const group = 'M4 6.5h7v5H4z M13 12.5h7v5h-7z M7.5 11.5v6h5.5';

  /// Search.
  static const search = 'M10.75 4.5a6.25 6.25 0 1 0 0 12.5 6.25 6.25 0 0 0 0-12.5z '
      'M15.5 15.5l4 4';

  /// Refresh: ask again.
  static const refresh = 'M19.5 12a7.5 7.5 0 1 1-2.2-5.3 M19.5 4.5V9h-4.5';

  /// Add.
  static const add = 'M12 5v14 M5 12h14';

  /// More: the row's own menu.
  static const more = 'M12 6.75a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5z '
      'M12 12.75a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5z '
      'M12 18.75a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5z';

  /// List and card views.
  static const viewList = 'M4 6.5h16 M4 12h16 M4 17.5h16';

  /// Card view. The gutters are 2.6 wide because at 16 the stroke itself is
  /// 2.25 of those units: a 2-unit gutter closes and four cards become one
  /// filled square.
  static const viewCards = 'M2.9 6.2h7.8v5h-7.8z M13.3 6.2h7.8v5h-7.8z '
      'M2.9 13.8h7.8v5h-7.8z M13.3 13.8h7.8v5h-7.8z';

  // ---- platforms ---------------------------------------------------------

  // The one deliberate exception to "abstract stroke marks". These sit in the
  // Platform column, where the operator is scanning for an operating system
  // and nothing else; an invented abstraction for Windows is not decodable, and
  // the trademark is the reason the column can be read at a glance. They are
  // still held to the system — 1.75 stroke, round joins, never filled — and
  // each has been cut back to the fewest shapes that stay open at 16, which is
  // the size the column actually ships at.

  /// Four panes sheared into the flag, on 2.5-unit gutters. The old mark's
  /// gutters were half a unit — at 16 the four panes fused into a slab — and
  /// the lean is now carried by every edge rather than only the top two, so it
  /// cannot be mistaken for the square grid of [viewCards].
  static const windows = 'M3.5 7.36l7-.98v5.5l-7 .98z M13 6.03l7-.98v5.5l-7 .98z '
      'M3.5 15.46l7-.98v5.5l-7 .98z M13 14.13l7-.98v5.5l-7 .98z';

  /// The penguin as one body. The old drawing pinched a small head onto a wide
  /// body, and at 16 the pinch closed and left a keyhole.
  static const linux =
      'M12 3.5c-3.4 0-5.6 2.9-5.6 6.9 0 1.8-1.4 3.6-1.4 5.6 0 2.3 3.1 4 7 4'
      's7-1.7 7-4c0-2-1.4-3.8-1.4-5.6 0-4-2.2-6.9-5.6-6.9z '
      'M9.4 8.7h.01 M14.6 8.7h.01 M10.3 11.4L12 12.7l1.7-1.3';

  /// The apple with the leaf and the bite taken off it. Both were sub-2-unit
  /// features that inked solid at row size and read as dirt on the glyph; the
  /// silhouette and the stem carry the mark on their own.
  static const macos =
      'M12 8.6c-1.3-1.1-3.2-1.3-4.6-.3-1.7 1.2-2.2 3.9-1.2 6.5.9 2.4 2.7 4.4 '
      '4.1 4.4.7 0 1.1-.3 1.7-.3s1 .3 1.7.3c1.4 0 3.2-2 4.1-4.4 1-2.6.5-5.3-1.2-6.5'
      '-1.4-1-3.3-.8-4.6.3z M12 8.6V6.2c0-1.4 1.2-2.6 2.9-2.7';

  /// The robot's head, which is the half of the mark that is recognisable. The
  /// body, the legs and the arms took the head down to eight units across.
  static const android = 'M4 16.5a8 8 0 0 1 16 0z M7.5 10L5.5 6.5 M16.5 10l2-3.5 '
      'M9 14h.01 M15 14h.01';

  // ---- session toolbar ---------------------------------------------------

  /// Display: which screen is being watched.
  static const display =
      'M4 5.5h16a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1z '
      'M9 20h6 M12 16.5V20';

  /// Keyboard: input is being sent.
  static const keyboard =
      'M3.5 7.5h17a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1h-17a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1z '
      'M6.5 10.5h.01 M10 10.5h.01 M13.5 10.5h.01 M17 10.5h.01 M8 13.5h8';

  /// Pointer.
  static const pointer = 'M6.5 3.75l11 6.75-4.9 1.1-1.6 5z';

  /// Clipboard shared between the two machines.
  static const clipboard =
      'M8.5 4.5h7 M9.5 3h5a1 1 0 0 1 1 1v1.5h-7V4a1 1 0 0 1 1-1z '
      'M15.5 5.5H18a1 1 0 0 1 1 1V19a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V6.5a1 1 0 0 1 1-1h2.5 '
      'M9 12h6 M9 15.5h4';

  /// File transfer: the direction is the point.
  static const fileTransfer = 'M5 8.5h6.5l2 2.5H19a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H5'
      'a1 1 0 0 1-1-1v-8.5a1 1 0 0 1 1-1z M12 12.5v5 M9.75 15.25L12 17.5l2.25-2.25';

  /// Chat with whoever is at the far end.
  static const chat = 'M4.5 5.5h15a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H10l-4.5 3.5V15.5H4.5'
      'a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1z';

  /// Recording: the frame being captured, with the lens open in it. A ring
  /// with a dot in it was the selected radio button, mark for mark — the same
  /// drawing appears in settings and in this toolbar's own menus — so the
  /// glyph said "this option is chosen", not "the session is being written".
  static const record =
      'M5.5 4.5h13a1.5 1.5 0 0 1 1.5 1.5v12a1.5 1.5 0 0 1-1.5 1.5h-13'
      'A1.5 1.5 0 0 1 4 18V6a1.5 1.5 0 0 1 1.5-1.5z '
      'M12 8.75a3.25 3.25 0 1 0 0 6.5 3.25 3.25 0 0 0 0-6.5z';

  /// Fullscreen, and its way out.
  static const fullscreen = 'M4 9V5.5a1 1 0 0 1 1-1h3.5 M15.5 4.5H19a1 1 0 0 1 1 1V9 '
      'M20 15v3.5a1 1 0 0 1-1 1h-3.5 M8.5 19.5H5a1 1 0 0 1-1-1V15';
  static const fullscreenExit = 'M8.5 4.5V8a1 1 0 0 1-1 1H4 M15.5 4.5V8a1 1 0 0 0 1 1H20 '
      'M20 15h-3.5a1 1 0 0 0-1 1v3.5 M4 15h3.5a1 1 0 0 1 1 1v3.5';

  /// Picture quality, drawn as the level it is set to. An open arc with a
  /// needle in it is a loading spinner to everyone who has ever waited for one,
  /// and it carried no notion of more or less. Three rising bars do, and the
  /// menu behind the control offers exactly three settings.
  static const quality = 'M6 18.5v-4 M12 18.5v-8 M18 18.5v-12';

  /// Sound coming back, and the microphone going out.
  static const audio = 'M5 9.5h3l4-3.5v12l-4-3.5H5a1 1 0 0 1-1-1v-3a1 1 0 0 1 1-1z '
      'M16 9a4 4 0 0 1 0 6 M18.75 6.5a8 8 0 0 1 0 11';
  static const audioOff = 'M5 9.5h3l4-3.5v12l-4-3.5H5a1 1 0 0 1-1-1v-3a1 1 0 0 1 1-1z '
      'M16.5 9.75l4 4.5 M20.5 9.75l-4 4.5';
  static const mic = 'M12 4.5a2.5 2.5 0 0 1 2.5 2.5v5a2.5 2.5 0 0 1-5 0V7A2.5 2.5 0 0 1 12 4.5z '
      'M6.5 11.5a5.5 5.5 0 0 0 11 0 M12 17v3 M9.5 20h5';

  /// Privacy: the far end is not being shown.
  static const privacy = 'M4 4.5l16 15 '
      'M9.6 6.2A9.6 9.6 0 0 1 12 6c5 0 8.5 4.2 9 6-.2.8-1 2.2-2.4 3.5 '
      'M6.4 8.1C4.6 9.4 3.2 11.2 3 12c.5 1.8 4 6 9 6 1 0 1.9-.2 2.7-.5 '
      'M10.2 10.4a2.25 2.25 0 0 0 3.1 3.2';

  /// Ending the session, and acting on the machine.
  static const disconnect = 'M14 5.5h4.5a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H14 '
      'M11 12H4 M7 8.5L3.5 12 7 15.5';
  static const power = 'M12 4v7 M7.4 7.4a6.5 6.5 0 1 0 9.2 0';
  static const restart = 'M4.5 12a7.5 7.5 0 1 0 2.2-5.3 M4.5 4.5V9H9';

  /// Pinned toolbar.
  static const pin = 'M9.5 3.5h5l-.75 5.25L17 12.5H7l3.25-3.75z M12 12.5V20';

  /// Mobile actions: the far machine is a handset, and its own on-screen
  /// controls are being driven from here.
  static const mobileActions =
      'M8 3.5h8a1 1 0 0 1 1 1v15a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1v-15a1 1 0 0 1 1-1z '
      'M9.5 17.5h.01 M12 17.5h.01 M14.5 17.5h.01';

  /// The toolbar's own grab handle. A grip, not an arrow: it says "hold me",
  /// which is the only thing the handle does. Drawn as six short bars rather
  /// than six dots — a zero-length round cap is exactly one stroke wide, and at
  /// the 16px this ships at, in the faintest text colour, the drag affordance
  /// for the
  /// whole toolbar was six specks nobody could see.
  static const grip = 'M8.5 7h2 M13.5 7h2 M8.5 12h2 M13.5 12h2 '
      'M8.5 17h2 M13.5 17h2';

  /// Take one away. Serves both the window minimise and the "decrease"
  /// half of a stepper, because they are the same instruction.
  static const minus = 'M6 12h12';

  /// Dismiss.
  static const close = 'M6.75 6.75l10.5 10.5 M17.25 6.75l-10.5 10.5';

  // ---- session window chrome ---------------------------------------------

  /// Maximise: the window taking the whole screen. One frame, because that is
  /// what the window becomes.
  static const maximize = 'M6.5 5.5h11a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1h-11'
      'a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1z';

  /// Restore: the window stepping back off the screen, so a second one shows
  /// behind it.
  static const restore =
      'M5.5 8.5h9a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1z '
      'M8.5 6.5v-1a1 1 0 0 1 1-1h9a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-1';

  /// Port forward: traffic crossing from this side to the far side. The two
  /// rails are the point — a bare arrow would only say "next".
  static const portForward = 'M4.5 5.5v13 M19.5 5.5v13 '
      'M7.5 12h7 M11.5 8.5L15 12l-3.5 3.5';

  /// Watching a camera on the far machine, as opposed to its screen.
  static const camera =
      'M4.5 7.5h3.2l1.4-2h6.8l1.4 2h1.2a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1h-14'
      'a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1z '
      'M12 15.75a3.25 3.25 0 1 0 0-6.5 3.25 3.25 0 0 0 0 6.5z';

  /// A warning the operator has to answer, used where an action cannot be
  /// undone. Never decorative: it is only ever drawn in the console's one
  /// bad-news colour.
  static const alert = 'M12 4.75L20.5 19.75h-17z M12 10v4.25 M12 17.25h.01';

  /// Restriction: this is shut, or it wants a password. It is never the
  /// affirmative answer to anything — a padlock on an Accept button says the
  /// opposite of what the button does. Use [check] there and [key] where a
  /// credential is being handed over.
  static const lock = 'M6.5 10.5h11a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1z '
      'M8.5 10.5V7.5a3.5 3.5 0 0 1 7 0v3';
  static const key = 'M15 4.5a4.5 4.5 0 1 0 0 9 4.5 4.5 0 0 0 0-9z '
      'M11.6 12.4L4 20v.5h3.5V18h2.5v-2.5h2z';
  static const shield = 'M12 3.5l7 2.5v5.5c0 4-3 7.2-7 8.5-4-1.3-7-4.5-7-8.5V6z';

  // ---- connection manager ------------------------------------------------

  /// A voice call being taken, and the same call being put down. The slash is
  /// the only mark that survives at 14px; a handset rotated 135 degrees, which
  /// is the other convention, reads as a handset that has fallen over.
  static const call = 'M5 4.5h3.3l1.7 4.2-2.1 1.5a12.5 12.5 0 0 0 5.9 5.9'
      'l1.5-2.1 4.2 1.7V19a1 1 0 0 1-1 1h-.7A14.8 14.8 0 0 1 4 6.2V5.5'
      'a1 1 0 0 1 1-1z';
  static const callEnd = '$call M4.5 19.5L19.5 4.5';

  /// Switching sides: the two machines trading places, not a reply arrow.
  static const switchSides = 'M4.5 9.5h13 M14 6l3.5 3.5-3.5 3.5 '
      'M19.5 15.5h-13 M10 12l-3.5 3.5 3.5 3.5';

  /// The far end's keyboard and pointer stopped at this machine. Drawn as the
  /// input being blocked rather than as a prohibition sign, which says nothing
  /// about what is being prohibited.
  static const blockInput =
      'M3.5 7.5h17a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1h-17a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1z '
      'M4 18.5L20 5.5';

  /// Plain arrows, for the places a chevron would understate the direction:
  /// a port crossing to the far side, a file going one way or the other.
  static const arrowRight = 'M4.5 12h14 M13 6.5l5.5 5.5-5.5 5.5';
  static const arrowUp = 'M12 19.5v-14 M6.5 11l5.5-5.5 5.5 5.5';
  static const arrowDown = 'M12 4.5v14 M6.5 13l5.5 5.5 5.5-5.5';

  /// What the far end did to a file: removed it, made a folder, renamed it.
  static const trash = 'M4.5 7h15 M9.5 7V5.5a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1V7 '
      'M6.5 7l.85 12.07a1 1 0 0 0 1 .93h7.3a1 1 0 0 0 1-.93L17.5 7 '
      'M10 10.5v6 M14 10.5v6';
  static const folderAdd = 'M5 8.5h6.5l2 2.5H19a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H5'
      'a1 1 0 0 1-1-1v-8.5a1 1 0 0 1 1-1z M12 13v4 M10 15h4';
  static const rename = 'M5.5 18.5v-3l9.5-9.5 3 3-9.5 9.5z M13.5 7.5l3 3';

  /// A chevron, the only glyph allowed to be decorative. All four exist so a
  /// control that points at an edge can point at the edge it actually means.
  static const chevronDown = 'M7.5 10l4.5 4.5 4.5-4.5';
  static const chevronUp = 'M7.5 14l4.5-4.5 4.5 4.5';
  static const chevronRight = 'M10 7.5l4.5 4.5-4.5 4.5';
  static const chevronLeft = 'M14 7.5L9.5 12l4.5 4.5';
  // ---- promoted from the surfaces that had to draw them locally -----------
  // Each of these was authored inside one screen because this file was being
  // edited at the time. A glyph set with copies living in three files is not a
  // set, so they live here now and the screens reference them.

  /// A tick. Used by checkboxes and by anything reporting "this one".
  static const check = 'M5.5 12.5L10 17l8.5-10';

  /// A folder, and a file with its corner turned. The two marks that separate
  /// a directory from a document without relying on colour.
  static const folder = 'M5 8.5h6.5l2 2.5H19a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H5'
      'a1 1 0 0 1-1-1v-8.5a1 1 0 0 1 1-1z';
  static const file = 'M6.5 3.5h6.5l5 5v11a1 1 0 0 1-1 1h-10.5a1 1 0 0 1-1-1'
      'v-15a1 1 0 0 1 1-1z M13 3.5V8.5h5';

  /// A volume: a bay with its lamp lit, not a floppy disk nobody has seen.
  static const drive =
      'M4.5 8.5h15a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1h-15a1 1 0 0 1-1-1v-5'
      'a1 1 0 0 1 1-1z M6.5 12h6 M17 12h.01';

  /// Home, and starting a paused job again.
  static const home = 'M3.5 11.25L12 4l8.5 7.25 M5.75 9.5V19a1 1 0 0 0 1 1h10.5'
      'a1 1 0 0 0 1-1V9.5 M9.75 20v-5.5h4.5V20';
  static const resume = 'M8.5 5.75l10 6.25-10 6.25z';

  /// An explanation the operator has not asked for. The ring is [recent]'s
  /// ring, to the unit, so the two round glyphs in the set are the same circle
  /// rather than two circles drawn a fortnight apart.
  static const info = 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17z '
      'M12 11v5.5 M12 7.75h.01';

  /// A still taken off the remote display: the picture, not the camera.
  /// [camera] is the far machine's webcam being watched and [record] is the
  /// session being written, so neither can stand for a screenshot without
  /// saying something the action does not do.
  static const screenshot =
      'M4.5 5.5h15a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1h-15a1 1 0 0 1-1-1v-11'
      'a1 1 0 0 1 1-1z M7.75 9h.01 M3.5 15.5l4.5-4.5 4 4 2.5-2.5 6 6';

  /// Waiting. A bare three-quarter arc on [recent]'s circle, spun by
  /// [LdSpinner]. No arrowhead: an arrow makes it [refresh], which is a thing
  /// the operator can ask for rather than a thing that is happening.
  static const spinner = 'M12 3.5a8.5 8.5 0 1 0 8.5 8.5';
}

/// Renders one glyph from [LdIcons].
///
/// Stroke, cap and join are fixed here rather than per icon so the set cannot
/// drift: a glyph added later inherits the system whether or not its author
/// was thinking about it.
class LdIcon extends StatelessWidget {
  const LdIcon(this.path, {super.key, this.size = 20, this.color});

  final String path;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? DefaultTextStyle.of(context).style.color ?? const Color(0xFFEDEDF2);
    final hex = '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    // The weight the glyph is actually drawn at, in logical pixels, before it
    // is converted back into the viewBox's own units — SVG measures stroke in
    // user space, so a constant stroke-width shrinks with the box.
    //
    // Held almost flat as the glyph gets smaller. The previous line multiplied
    // the compensation straight back out again ((1.75 * 24 / size) * size / 24
    // is 1.75, whatever size is), so a 16px glyph was drawn at 1.17px and the
    // whole small end of the set read as hairlines.
    final weight = 1.75 - (24 - size).clamp(0.0, 10.0) * 0.031;
    final stroke = weight * 24 / size;
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
        'fill="none" stroke="$hex" stroke-width="$stroke" '
        'stroke-linecap="round" stroke-linejoin="round">'
        '<path d="$path"/></svg>',
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(c.withOpacity(c.opacity), BlendMode.srcIn),
      ),
    );
  }
}

/// The console's busy mark.
///
/// A Material `CircularProgressIndicator` is one of the most recognisable
/// objects the framework draws — a butt-capped arc that stretches and shrinks
/// as it turns — and it was appearing on buttons and rows that had otherwise
/// been redrawn glyph by glyph. This is the set's own arc, at the set's stroke
/// and cap, turning at a constant rate.
class LdSpinner extends StatefulWidget {
  const LdSpinner({super.key, this.size = 14, this.color});

  final double size;
  final Color? color;

  @override
  State<LdSpinner> createState() => _LdSpinnerState();
}

class _LdSpinnerState extends State<LdSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
        turns: _turn,
        child: LdIcon(LdIcons.spinner, size: widget.size, color: widget.color),
      );
}
