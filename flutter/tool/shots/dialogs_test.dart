// Fixture strings say LabDesk on purpose. The product does not carry the brand in
// its string table: lang.rs swaps LabDesk for the app name at runtime whenever
// APP_NAME is not LabDesk, and core_main.rs:34 sets it to LabDesk. A fixture that
// bypasses 	ranslate must not imply the shipping copy is wrong.
// Renders the modals the product raises, so a change to them can be looked at
// rather than guessed at. Not part of the CI gate: it lives outside test/ and
// is run by hand with `flutter test tool/shots/dialogs_test.dart`.
//
// The real dialogs cannot be built here. `lib/common/widgets/dialog.dart` needs
// a live FFI session for nearly every value it draws and it imports the app's
// shared common.dart, which does not compile under the test SDK — which made
// the password prompt, the file-conflict prompt and the restart confirmation
// the surfaces nobody could look at. So their presentation was extracted to
// lib/labdesk/theme/dialog_skin.dart, where it takes plain values, and both
// these shots and the shipping dialogs build from those same pieces.
//
// Every string below is copied verbatim from the call site, in English, as
// `translate` would return it with the default language.
//
// Shots land in tool/shots/out/dialog-*.png.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/labdesk/theme/console_theme.dart';
import 'package:flutter_hbb/labdesk/theme/dialog_skin.dart';
import 'package:flutter_hbb/labdesk/theme/ld_icons.dart';
import 'package:flutter_hbb/labdesk/theme/settings_skin.dart';

const _out = 'tool/shots/out';

Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final loader = FontLoader(family);
    final bytes = File(path).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    await loader.load();
  }

  await load('Manrope', 'assets/fonts/Manrope-Variable.ttf');
  await load('JetBrainsMono', 'assets/fonts/JetBrainsMono-Medium.ttf');
}

/// The desk a modal is raised over.
///
/// Deliberately not the console's own flat background: these dialogs appear
/// over a session window, over a file transfer, over whatever the person was
/// doing, so the ground is uneven.
///
/// It used to carry a flat cream rectangle pinned to the bottom-left corner as
/// a stand-in for "a document is open". Nothing in the product draws that, and
/// what it actually produced was a hard-edged grey slab wherever the dialog's
/// shadow crossed the corner of it — a harness artefact being read as the
/// shadow's fault. The shadow over a genuinely light remote desktop is not
/// something this sheet can show, and it is better to not show it than to show
/// it wrong.
Widget _desk(List<Widget> dialogs) => Stack(fit: StackFit.expand, children: [
      Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF23262D), Color(0xFF15171C), Color(0xFF2E2937)],
            stops: [0, 0.55, 1],
          ),
        ),
      ),
      Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final d in dialogs) ...[
              d,
              if (d != dialogs.last) const SizedBox(width: 34),
            ],
          ],
        ),
      ),
    ]);

/// A caption above each window, so a sheet of them can be read.
Widget _captioned(String caption, Widget dialog) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(caption, style: C.micro(color: C.textFaint)),
        const SizedBox(height: 10),
        dialog,
      ],
    );

/// `_connectDialog(passwordController: ...)` — the prompt that stands between
/// the operator and a machine they are already trying to reach.
Widget _passwordDialog({Key? okKey, bool remember = true}) {
  return LdDialog(
    title: const LdDialogTitle(
      title: 'Password Required',
      glyph: LdIcons.lock,
    ),
    onSubmit: () {},
    onCancel: () {},
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Verify LabDesk password', style: C.body(color: C.textMuted)),
        const SizedBox(height: 14),
        LdDialogField(
          controller: TextEditingController(text: 'hunter2hunter2'),
          label: 'Password',
          hintText: 'Enter your password',
          glyph: LdIcons.lock,
          obscureText: true,
          trailing: LdFieldButton(glyph: LdIcons.privacy, onPressed: () {}),
        ),
        const SizedBox(height: 12),
        LdDialogCheck(
          label: 'Remember password',
          value: remember,
          onChanged: (_) {},
        ),
      ],
    ),
    actions: [
      LdDialogButton(
          label: 'Cancel', glyph: LdIcons.close, onPressed: () {}),
      KeyedSubtree(
        key: okKey,
        child: LdDialogButton(
          label: 'OK',
          tone: LdDialogTone.primary,
          glyph: DialogGlyphs.check,
          onPressed: () {},
        ),
      ),
    ],
  );
}

/// The same prompt after a rejected password, which is the state it is most
/// often read in.
Widget _wrongPasswordDialog() {
  return LdDialog(
    title: const LdDialogTitle(
      title: 'Password Required',
      glyph: LdIcons.lock,
    ),
    onSubmit: () {},
    onCancel: () {},
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Verify LabDesk password', style: C.body(color: C.textMuted)),
        const SizedBox(height: 14),
        LdDialogField(
          controller: TextEditingController(text: 'hunter2'),
          label: 'Password',
          glyph: LdIcons.lock,
          obscureText: true,
          errorText: 'Wrong password',
          trailing: LdFieldButton(glyph: LdIcons.privacy, onPressed: () {}),
        ),
        const SizedBox(height: 12),
        LdDialogCheck(
          label: 'Remember password',
          value: false,
          onChanged: (_) {},
        ),
      ],
    ),
    actions: [
      LdDialogButton(label: 'Cancel', glyph: LdIcons.close, onPressed: () {}),
      LdDialogButton(
        label: 'Retry',
        tone: LdDialogTone.primary,
        glyph: LdIcons.refresh,
        onPressed: () {},
      ),
    ],
  );
}

/// `FileModel.showFileConfirmDialog` — three answers, one of which destroys a
/// file that is already on the far machine.
Widget _conflictDialog({required bool identical, Key? hoverKey}) {
  return LdDialog(
    width: DialogSkin.width,
    title: const LdDialogTitle(
      title: 'Overwrite',
      glyph: LdIcons.alert,
      tone: C.bad,
    ),
    onSubmit: () {},
    onCancel: () {},
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('This file exists, skip or overwrite this file?', style: C.h2()),
        const SizedBox(height: 10),
        const LdDialogIdentity(
          r'C:\Users\wenger\Documents\site-survey\rec-centre-2026-08.xlsx',
        ),
        if (identical) ...[
          const SizedBox(height: 12),
          const LdDialogNote(
            "This file is identical with the peer's one.",
          ),
        ],
        const SizedBox(height: 10),
        LdDialogCheck(
          label: 'Do this for all conflicts',
          value: false,
          onChanged: (_) {},
        ),
      ],
    ),
    actions: [
      LdDialogButton(label: 'Cancel', glyph: LdIcons.close, onPressed: () {}),
      LdDialogButton(
          label: 'Skip', glyph: DialogGlyphs.skip, onPressed: () {}),
      KeyedSubtree(
        key: hoverKey,
        // Labelled with the verb it performs. "OK" on the one answer that
        // destroys a file the operator cannot get back is the label of a
        // dialog that has not been read.
        child: LdDialogButton(
          label: 'Overwrite',
          tone: LdDialogTone.danger,
          glyph: LdIcons.fileTransfer,
          onPressed: () {},
        ),
      ),
    ],
  );
}

/// `showRestartRemoteDevice` — the confirmation with the largest blast radius
/// in the product, and the reason the answers are not a filled slab and an
/// outline.
Widget _restartDialog() {
  return LdDialog(
    width: DialogSkin.narrowWidth,
    title: const LdDialogTitle(
      title: 'Restart remote device',
      glyph: LdIcons.restart,
      tone: C.bad,
    ),
    onSubmit: () {},
    onCancel: () {},
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Are you sure you want to restart', style: C.body()),
        const SizedBox(height: 10),
        const LdDialogIdentity('frontdesk@city-of-jennings-rec-center'
            '\n412 007 336'),
      ],
    ),
    actions: [
      LdDialogButton(label: 'Cancel', glyph: LdIcons.close, onPressed: () {}),
      LdDialogButton(
        label: 'OK',
        tone: LdDialogTone.danger,
        glyph: LdIcons.restart,
        onPressed: () {},
      ),
    ],
  );
}

/// `deleteConfirmDialog` — the shortest dialog in the product.
Widget _deleteDialog() {
  return LdDialog(
    width: DialogSkin.narrowWidth,
    title: const LdDialogTitle(
      title: 'Delete',
      glyph: LdIcons.trash,
      tone: C.bad,
    ),
    onSubmit: () {},
    onCancel: () {},
    // The machine goes in the body, in the data face, exactly as the restart
    // confirmation beside it puts its machine there. It used to ride in the
    // title as a subtitle, which made this the one dialog in the product with
    // no body and its own framing.
    content: const LdDialogIdentity('Chemline Natural Bridge'),
    actions: [
      LdDialogButton(label: 'Cancel', glyph: LdIcons.close, onPressed: () {}),
      LdDialogButton(
        label: 'OK',
        tone: LdDialogTone.danger,
        glyph: LdIcons.trash,
        onPressed: () {},
      ),
    ],
  );
}

/// `msgBox` — what the product says when a connection will not come up.
Widget _errorDialog() {
  return LdDialog(
    width: DialogSkin.width,
    title: const LdDialogTitle(
      title: 'Connection Error',
      glyph: LdIcons.alert,
      tone: C.bad,
    ),
    onSubmit: () {},
    onCancel: () {},
    content: const LdDialogMessage(
      text: 'Failed to connect to the remote machine: the connection was reset '
          'by the relay.',
    ),
    actions: [
      LdDialogButton(label: 'Cancel', glyph: LdIcons.close, onPressed: () {}),
      LdDialogButton(
        label: 'Reconnect',
        tone: LdDialogTone.primary,
        glyph: LdIcons.refresh,
        onPressed: () {},
      ),
    ],
  );
}

/// `showOnBlockDialog` — the far machine is showing a UAC prompt, and nothing
/// this side sends will reach it until somebody answers.
Widget _elevationDialog() {
  return LdDialog(
    width: DialogSkin.width,
    title: const LdDialogTitle(title: 'Privacy mode', glyph: LdIcons.shield),
    onSubmit: () {},
    onCancel: () {},
    content: const LdDialogMessage(
      text: 'The remote window is elevated and cannot be controlled until this '
          'session is elevated too.\n\nRequest elevation from the remote user?',
    ),
    actions: [
      LdDialogButton(label: 'Wait', glyph: DialogGlyphs.waiting, onPressed: () {}),
      LdDialogButton(
        label: 'Request Elevation',
        tone: LdDialogTone.primary,
        glyph: LdIcons.shield,
        onPressed: () {},
      ),
    ],
  );
}

/// `change2fa` / `enter2FaDialog` — an OK that cannot yet be given.
Widget _twoFactorDialog() {
  return LdDialog(
    width: DialogSkin.narrowWidth,
    title: const LdDialogTitle(
      title: 'Enter your 2FA code',
      glyph: LdIcons.shield,
    ),
    onSubmit: () {},
    onCancel: () {},
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        LdDialogField(
          controller: TextEditingController(text: '4021'),
          label: 'Verification code',
          autofocus: false,
          mono: true,
          glyph: LdIcons.key,
        ),
        const SizedBox(height: 12),
        LdDialogCheck(
          label: 'Trust this device',
          value: false,
          onChanged: (_) {},
        ),
      ],
    ),
    actions: [
      LdDialogButton(label: 'Cancel', glyph: LdIcons.close, onPressed: () {}),
      const LdDialogButton(
        label: 'OK',
        tone: LdDialogTone.primary,
        glyph: DialogGlyphs.check,
        onPressed: null,
      ),
    ],
  );
}

/// `changeIdDialog` — a field with a checklist of rules under it, half met.
Widget _changeIdDialog() {
  Widget rule(String name, bool ok) => Row(mainAxisSize: MainAxisSize.min, children: [
        LdIcon(ok ? DialogGlyphs.check : LdIcons.minus,
            size: 13, color: ok ? C.ok : C.textFaint),
        const SizedBox(width: 6),
        Text(name, style: C.small(color: ok ? C.ok : C.textMuted)),
      ]);

  return LdDialog(
    title: const LdDialogTitle(title: 'Change ID', glyph: LdIcons.machine),
    onSubmit: () {},
    onCancel: () {},
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
            'ID can only contain letters, numbers, underscores and hyphens. '
            'It has to start with a letter.',
            style: C.body(color: C.textMuted)),
        const SizedBox(height: 16),
        LdDialogField(
          controller: TextEditingController(text: '7lab-forge'),
          label: 'Your new ID',
          mono: true,
          autofocus: false,
          suffixText: '10/16',
        ),
        const SizedBox(height: 14),
        Wrap(runSpacing: 7, spacing: 16, children: [
          rule('starts with a letter', false),
          rule('length 6 to 16', true),
          rule('allowed characters', true),
        ]),
      ],
    ),
    actions: [
      LdDialogButton(label: 'Cancel', glyph: LdIcons.close, onPressed: () {}),
      LdDialogButton(
        label: 'OK',
        tone: LdDialogTone.primary,
        glyph: DialogGlyphs.check,
        onPressed: () {},
      ),
    ],
  );
}

/// `showRequestElevationDialog` — two ways to go, the second of which asks for
/// an administrator's credentials.
Widget _elevationFormDialog() {
  return LdDialog(
    title: const LdDialogTitle(
        title: 'Request Elevation', glyph: LdIcons.shield),
    onSubmit: () {},
    onCancel: () {},
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        LdRadioRow(
          label: 'Ask the remote user for authentication',
          explain: 'Choose this if the remote account is administrator',
          selected: false,
          onTap: () {},
        ),
        const SizedBox(height: 6),
        LdRadioRow(
          label: 'Transmit the username and password of administrator',
          selected: true,
          onTap: () {},
        ),
        Padding(
          padding: const EdgeInsets.only(left: SettingsSkin.indent, top: 12),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const LdDialogNote(
              'Still requires the remote user to click OK on the UAC window '
              'of running LabDesk.',
            ),
            const SizedBox(height: 12),
            LdDialogField(
              controller: TextEditingController(),
              label: 'Username',
              hintText: 'eg: .\\administrator',
              leading: const LdIcon(DialogGlyphs.user,
                  size: 16, color: C.textFaint),
              autofocus: false,
            ),
            const SizedBox(height: 12),
            LdDialogField(
              controller: TextEditingController(text: 'correcthorse'),
              label: 'Password',
              glyph: LdIcons.lock,
              obscureText: true,
              autofocus: false,
              errorText: 'Empty Password',
              trailing:
                  LdFieldButton(glyph: LdIcons.privacy, onPressed: () {}),
            ),
          ],
        )),
      ],
    ),
    actions: [
      LdDialogButton(label: 'Cancel', glyph: LdIcons.close, onPressed: () {}),
      LdDialogButton(
        label: 'OK',
        tone: LdDialogTone.primary,
        glyph: DialogGlyphs.check,
        onPressed: () {},
      ),
    ],
  );
}

/// `FfiModel._handleScreenshot` — the session window's screenshot prompt, and
/// the dialog that made the case for reskinning `CustomAlertDialog` and
/// `dialogButton` themselves rather than one call site at a time. A live
/// capture of it showed three identical filled violet Material slabs under no
/// header at all.
///
/// Built here exactly as those two now build it. The call site passes
/// `title: null` and puts its heading inside `msgboxContent`, which
/// `CustomAlertDialog` lifts into the frame's own title row; the type
/// `custom-nook-nocancel-hasclose` matches no named entry in the mark table, so
/// it takes the table's fallback — the info ring in the accent, which is what
/// `ldMsgboxMark` now returns for every `custom-*` and unknown type rather than
/// leaving one dialog in the product with a bare title.
/// The width is `contentBoxConstraints`' default 500.
/// The tones are what `dialogButton` reads off the labels: "Save as" is the
/// primary, the clipboard is the second way to take the same shot, and Cancel
/// is dismissive whatever the caller passed.
///
/// Strings are what `translate` returns with the default language;
/// `screenshot-action-tip` is src/lang/en.rs:254.
Widget _screenshotDialog() {
  return LdDialog(
    width: 500,
    title: const LdDialogTitle(
        title: 'Take screenshot', glyph: DialogGlyphs.info),
    content: const LdDialogMessage(
      text: 'Please select how to continue with the screenshot.',
    ),
    actions: [
      LdDialogButton(label: 'Cancel', glyph: LdIcons.close, onPressed: () {}),
      LdDialogButton(
          label: 'Copy to clipboard',
          glyph: LdIcons.clipboard,
          onPressed: () {}),
      LdDialogButton(
        label: 'Save as...',
        tone: LdDialogTone.primary,
        glyph: LdIcons.fileTransfer,
        onPressed: () {},
      ),
    ],
  );
}

/// `showAuditDialog` — the note left against a session.
Widget _noteDialog() {
  return LdDialog(
    title: const LdDialogTitle(title: 'Note', glyph: LdIcons.rename),
    onSubmit: () {},
    onCancel: () {},
    content: LdDialogField(
      controller: TextEditingController(
          text: 'Replaced the failing NIC and re-seated the riser. '
              'Reboot scheduled for Saturday 03:00.'),
      label: '',
      autofocus: false,
      hintText: 'input note here',
      minLines: 5,
      maxLines: 8,
      maxLength: 256,
      showCounter: true,
    ),
    actions: [
      LdDialogButton(label: 'Cancel', glyph: LdIcons.close, onPressed: () {}),
      LdDialogButton(
        label: 'OK',
        tone: LdDialogTone.primary,
        glyph: DialogGlyphs.check,
        onPressed: () {},
      ),
    ],
  );
}

Future<void> _shoot(WidgetTester tester, String name) async {
  final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('shot')),
  );
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(_out).createSync(recursive: true);
    File('$_out/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<void> _pump(WidgetTester tester, Widget child, Size size) async {
  await tester.binding.setSurfaceSize(size);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(RepaintBoundary(
    key: const ValueKey('shot'),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: C.theme(),
      home: Scaffold(backgroundColor: C.bg, body: child),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Parks the cursor on one control, because hover is half the design and a
/// button nobody is pointing at does not show it.
Future<void> _hover(WidgetTester tester, Key key) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(find.byKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('dialogs: the password prompt', (tester) async {
    const okKey = ValueKey('ok');
    await _pump(
      tester,
      _desk([
        _captioned('the prompt as it arrives', _passwordDialog(okKey: okKey)),
        _captioned('after a rejected password', _wrongPasswordDialog()),
      ]),
      const Size(1080, 620),
    );
    await _hover(tester, okKey);
    await _shoot(tester, 'dialog-password');
  });

  testWidgets('dialogs: a file conflict', (tester) async {
    const okKey = ValueKey('ok');
    await _pump(
      tester,
      _desk([
        _captioned('a name that already exists — cursor on Overwrite',
            _conflictDialog(identical: false, hoverKey: okKey)),
        _captioned('the same file byte for byte, nothing under the cursor',
            _conflictDialog(identical: true)),
      ]),
      const Size(1080, 620),
    );
    await _hover(tester, okKey);
    await _shoot(tester, 'dialog-conflict');
  });

  testWidgets('dialogs: the answers that cannot be taken back', (tester) async {
    await _pump(
      tester,
      _desk([
        _captioned('restart the machine at the far end', _restartDialog()),
        _captioned('remove a machine from the list', _deleteDialog()),
      ]),
      const Size(940, 480),
    );
    // Tab moves focus onto the first answer. The ring has to be the one thing
    // on the pair that is not a tone.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await _shoot(tester, 'dialog-destructive');
  });

  testWidgets('dialogs: what the product says for itself', (tester) async {
    await _pump(
      tester,
      _desk([
        _captioned('a connection that will not come up', _errorDialog()),
        _captioned('the far end is waiting on UAC', _elevationDialog()),
      ]),
      const Size(1080, 480),
    );
    await _shoot(tester, 'dialog-message');
  });

  // Not a shot. The Material dialog these replaced answered Escape, Enter and
  // the numpad Enter, and stopped answering Enter the moment focus was moved
  // with Tab — which is the difference between "submit" and "press whatever the
  // operator has just tabbed onto". Asserted here because it is the one part of
  // the reskin that is not visible in a picture.
  testWidgets('dialogs: the keyboard contract survived the reskin',
      (tester) async {
    var submitted = 0;
    var cancelled = 0;
    await _pump(
      tester,
      LdDialog(
        onSubmit: () => submitted++,
        onCancel: () => cancelled++,
        content: const Text('x'),
        actions: const [LdDialogButton(label: 'OK', onPressed: null)],
      ),
      const Size(600, 300),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(cancelled, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(submitted, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pumpAndSettle();
    expect(submitted, 2);

    // Once Tab has moved focus, Enter belongs to whatever holds it.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(submitted, 2);
  });

  testWidgets('dialogs: the ones with a form in them', (tester) async {
    await _pump(
      tester,
      _desk([
        _captioned('a new id, and the rules it has to meet', _changeIdDialog()),
        _captioned('credentials for the far machine', _elevationFormDialog()),
        _captioned('a note against the session', _noteDialog()),
      ]),
      const Size(1560, 660),
    );
    await _shoot(tester, 'dialog-forms');
  });

  testWidgets('dialogs: the raw path, reskinned at the source', (tester) async {
    await _pump(
      tester,
      _desk([
        _captioned('a screenshot, and what to do with it', _screenshotDialog()),
      ]),
      const Size(700, 420),
    );
    await _shoot(tester, 'dialog-screenshot');
  });

  testWidgets('dialogs: an answer that cannot be given yet', (tester) async {
    await _pump(
      tester,
      _desk([_captioned('the code is not six digits yet', _twoFactorDialog())]),
      const Size(560, 460),
    );
    await _shoot(tester, 'dialog-2fa');
  });
}
