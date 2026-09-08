// Renders the file-transfer window so a change to it can be looked at rather
// than guessed at. Not part of the CI gate: it lives outside test/ and is run
// by hand with `flutter test tool/shots/filemanager_test.dart`.
//
// The real FileManagerPage cannot be built here — it needs a live FFI session
// for the directory listings, the platform of each end and the job table, and
// the app's shared common.dart does not compile under the test SDK — so the
// window's presentation was extracted to
// lib/labdesk/theme/file_manager_skin.dart. Every piece below (the panel
// frame, the pane header, the toolbar buttons, the column heads, the file rows,
// the job tiles, the empty state) is the same widget the shipping page builds
// from, handed plain values instead of the model's.
//
// Shot lands in tool/shots/out/filemanager.png.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/labdesk/theme/console_theme.dart';
import 'package:flutter_hbb/labdesk/theme/file_manager_skin.dart';
import 'package:flutter_hbb/labdesk/theme/ld_icons.dart';
import 'package:flutter_hbb/labdesk/theme/session_toolbar_skin.dart';

const _out = 'tool/shots/out';
const _size = Size(1500, 950);

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

/// One listing entry, as the page hands it to [FmFileRow].
class _Entry {
  const _Entry(this.name, this.kind, this.modified, this.size);
  final String name;
  final FmEntryKind kind;
  final String modified;
  final String size;
}

const _local = <_Entry>[
  _Entry('.ssh', FmEntryKind.folder, '2026-08-19 07:41:12', ''),
  _Entry('captures', FmEntryKind.folder, '2026-08-28 22:03:55', ''),
  _Entry('firmware', FmEntryKind.folder, '2026-07-02 14:26:08', ''),
  _Entry('bench-log-0829.csv', FmEntryKind.file, '2026-08-29 18:55:41', '412 KB'),
  _Entry('build-image.tar.zst', FmEntryKind.file, '2026-08-26 03:12:09', '2.7 GB'),
  _Entry('probe-readings.parquet', FmEntryKind.file, '2026-08-30 09:14:37', '88.4 MB'),
  _Entry('rack-diagram.pdf', FmEntryKind.file, '2026-05-11 11:02:20', '1.9 MB'),
  _Entry('serial-dump.txt', FmEntryKind.file, '2026-08-30 09:47:02', '61 KB'),
  _Entry('watchdog.service', FmEntryKind.file, '2026-03-08 20:31:44', '724 B'),
];

const _remote = <_Entry>[
  _Entry('C:', FmEntryKind.drive, '', '931 GB'),
  _Entry('D:', FmEntryKind.drive, '', '3.6 TB'),
  _Entry('incoming', FmEntryKind.folder, '2026-08-30 09:12:51', ''),
  _Entry('quarantine', FmEntryKind.folder, '2026-08-14 06:20:33', ''),
  _Entry('agent-2026.08.msi', FmEntryKind.file, '2026-08-21 13:44:19', '54.2 MB'),
  _Entry('crash-0827-0341.dmp', FmEntryKind.file, '2026-08-27 03:41:58', '1.2 GB'),
  _Entry('inventory.xlsx', FmEntryKind.file, '2026-08-18 16:09:27', '336 KB'),
  _Entry('site-survey.docx', FmEntryKind.file, '2026-06-30 10:55:14', '2.1 MB'),
];

/// The pane's own toolbar, in the shipping order.
Widget _tools({
  required bool isLocal,
  required Widget location,
  required Key sendKey,
  required bool canSend,
}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
    child: Column(
      children: [
        Row(
          children: [
            FmToolButton(
                glyph: LdIcons.chevronLeft, tooltip: 'Back', onPressed: () {}),
            FmToolButton(
                glyph: LdIcons.arrowUp,
                tooltip: 'Parent directory',
                onPressed: () {}),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6.0),
                child: Container(
                  height: FmSkin.toolButtonSize,
                  decoration: FmSkin.field,
                  child: location,
                ),
              ),
            ),
            FmToolButton(
                glyph: LdIcons.search, tooltip: 'Search', onPressed: () {}),
            FmToolButton(
                glyph: LdIcons.refresh,
                tooltip: 'Refresh File',
                onPressed: () {}),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  FmToolButton(
                      glyph: FmGlyphs.home, tooltip: 'Home', onPressed: () {}),
                  FmToolButton(
                      glyph: LdIcons.folderAdd,
                      tooltip: 'Create Folder',
                      onPressed: () {}),
                  FmToolButton(
                    glyph: LdIcons.trash,
                    tooltip: 'Delete',
                    danger: true,
                    // Disabled on the remote side: nothing is selected there,
                    // and a control that looks live and does nothing is worse
                    // than one that admits it.
                    onPressed: canSend ? () {} : null,
                  ),
                  FmToolButton(
                      glyph: LdIcons.more, tooltip: 'More', onPressed: () {}),
                ],
              ),
            ),
            KeyedSubtree(
              key: sendKey,
              child: FmSendButton(
                label: isLocal ? 'Send' : 'Receive',
                glyph: LdIcons.fileTransfer,
                onPressed: canSend ? () {} : null,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// The breadcrumb bar as the page builds it: crumbs, chevrons, and the control
/// that drops the volume list.
Widget _bread(List<String> parts) {
  final row = <Widget>[];
  for (var i = 0; i < parts.length; i++) {
    if (i > 0) {
      row.add(const LdIcon(LdIcons.chevronRight, size: 12, color: C.textFaint));
    }
    row.add(FmCrumb(
        label: parts[i], current: i == parts.length - 1, onTap: () {}));
  }
  return Row(
    children: [
      Expanded(
        child: Row(children: row),
      ),
      FmToolButton(
          glyph: LdIcons.chevronDown,
          tooltip: '',
          glyphSize: 15,
          onPressed: () {}),
    ],
  );
}

Widget _columns({
  required double nameWidth,
  required double modifiedWidth,
  required String sorted,
  required bool ascending,
}) {
  Widget head(String label, {double? width, double leading = 0, bool end = false}) =>
      SizedBox(
        width: width,
        child: Padding(
          padding: EdgeInsets.only(left: leading),
          child: FmColumnHead(
            label: label,
            ascending: sorted == label ? ascending : null,
            alignEnd: end,
            onTap: () {},
          ),
        ),
      );
  const divider = SizedBox(
      width: 2, child: ColoredBox(color: C.hairline, child: SizedBox.expand()));
  return Container(
    height: FmSkin.headerHeight,
    decoration: const BoxDecoration(
      color: C.chrome,
      border: Border(
        top: BorderSide(color: C.hairline),
        bottom: BorderSide(color: C.hairline),
      ),
    ),
    child: Row(children: [
      const SizedBox(width: 2),
      head('Name', width: nameWidth, leading: 10),
      divider,
      head('Modified', width: modifiedWidth),
      divider,
      Expanded(child: head('Size', end: true)),
      const SizedBox(width: 10),
    ]),
  );
}

Widget _pane({
  required bool isLocal,
  required String title,
  required String platformGlyph,
  required Widget location,
  required List<_Entry> entries,
  required Set<String> selected,
  required String sorted,
  required bool ascending,
  required Key sendKey,
  String? contextTarget,
}) {
  // The page's own defaults at a 1500-pixel window: 0.115 of the width as the
  // unit, spent 1.5 on the name and 1.05 on the timestamp.
  const nameWidth = 258.0;
  const modifiedWidth = 181.0;
  return FmPane(
    children: [
      FmPaneHeader(
        title: title,
        subtitle: isLocal ? 'Local Computer' : 'Remote Computer',
        badge: LdIcon(platformGlyph, size: 18, color: C.textMuted),
      ),
      _tools(
          isLocal: isLocal,
          location: location,
          sendKey: sendKey,
          canSend: selected.isNotEmpty),
      _columns(
          nameWidth: nameWidth,
          modifiedWidth: modifiedWidth,
          sorted: sorted,
          ascending: ascending),
      Expanded(
        child: ListView(
          children: [
            for (final e in entries)
              FmFileRow(
                name: e.name,
                kind: e.kind,
                modified: e.modified,
                size: e.size,
                selected: selected.contains(e.name),
                contextTarget: contextTarget == e.name,
                nameWidth: nameWidth,
                modifiedWidth: modifiedWidth,
                onTap: () {},
              ),
          ],
        ),
      ),
    ],
  );
}

/// The queue, with one job in each state the model can reach.
Widget _queue() {
  Widget name(String text) => Text(text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: C.body(color: C.text).copyWith(fontWeight: FontWeight.w600));

  return FmPane(
    rail: true,
    children: [
      FmPaneHeader(
        title: 'Transfer file',
        trailing: Text('6', style: C.data(size: 12, color: C.textFaint)),
      ),
      Expanded(
        child: ListView(children: [
          FmJobTile(
            name: name('build-image.tar.zst'),
            state: FmJobState.running,
            stateLabel: 'Transfer file',
            detail: '1/1 files, 1.13 GB / 2.70 GB',
            directionGlyph: LdIcons.arrowRight,
            directionTurns: 0,
            percent: 0.42,
            percentText: '42%',
            speed: '18.4 MB/s',
            actions: [
              FmToolButton(
                  glyph: LdIcons.close,
                  tooltip: 'Delete',
                  danger: true,
                  onPressed: () {}),
            ],
          ),
          FmJobTile(
            name: name('crash-0827-0341.dmp'),
            state: FmJobState.failed,
            stateLabel: 'Error',
            detail: '0/1 files, 1.20 GB',
            directionGlyph: LdIcons.arrowRight,
            directionTurns: 2,
            error: 'No space left on device (/var/lab/incoming)',
            actions: [
              FmToolButton(
                  glyph: LdIcons.close,
                  tooltip: 'Delete',
                  danger: true,
                  onPressed: () {}),
            ],
          ),
          FmJobTile(
            name: name('probe-readings.parquet'),
            state: FmJobState.paused,
            stateLabel: 'Paused',
            detail: '0/1 files, 88.4 MB',
            directionGlyph: LdIcons.arrowRight,
            directionTurns: 0,
            actions: [
              FmToolButton(
                  glyph: FmGlyphs.resume, tooltip: 'Resume', onPressed: () {}),
              FmToolButton(
                  glyph: LdIcons.close,
                  tooltip: 'Delete',
                  danger: true,
                  onPressed: () {}),
            ],
          ),
          FmJobTile(
            name: name('firmware/rev-c/bootloader.bin'),
            state: FmJobState.queued,
            stateLabel: 'Waiting',
            detail: '0/3 files, 14.8 MB',
            directionGlyph: LdIcons.arrowRight,
            directionTurns: 0,
            actions: [
              FmToolButton(
                  glyph: LdIcons.close,
                  tooltip: 'Delete',
                  danger: true,
                  onPressed: () {}),
            ],
          ),
          FmJobTile(
            name: name('bench-log-0829.csv'),
            state: FmJobState.done,
            stateLabel: 'Finished',
            detail: '1/1 files, 412 KB',
            directionGlyph: LdIcons.arrowRight,
            directionTurns: 0,
            actions: [
              FmToolButton(
                  glyph: LdIcons.close,
                  tooltip: 'Delete',
                  danger: true,
                  onPressed: () {}),
            ],
          ),
          FmJobTile(
            name: name('quarantine/old-agent'),
            state: FmJobState.done,
            stateLabel: 'Finished',
            detail: 'Finished 6/6 files, 240 MB',
            directionGlyph: LdIcons.trash,
            directionTurns: 0,
            actions: [
              FmToolButton(
                  glyph: LdIcons.close,
                  tooltip: 'Delete',
                  danger: true,
                  onPressed: () {}),
            ],
          ),
        ]),
      ),
    ],
  );
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('file manager', (tester) async {
    await tester.binding.setSurfaceSize(_size);
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const hoveredKey = ValueKey('hovered-send');

    await tester.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: C.theme(),
        home: Builder(builder: (context) {
          return Theme(
            data: cmThemeData(context),
            child: Scaffold(
              backgroundColor: C.bg,
              body: Padding(
                padding: const EdgeInsets.all(FmSkin.gap),
                child: Row(
                  children: [
                    Flexible(
                      flex: 3,
                      child: _pane(
                        isLocal: true,
                        title: 'Local workstation',
                        platformGlyph: LdIcons.linux,
                        location: _bread(['home', 'ops', 'lab']),
                        entries: _local,
                        selected: const {
                          'build-image.tar.zst',
                          'probe-readings.parquet'
                        },
                        contextTarget: 'serial-dump.txt',
                        sorted: 'Name',
                        ascending: true,
                        sendKey: hoveredKey,
                      ),
                    ),
                    Flexible(
                      flex: 3,
                      child: _pane(
                        isLocal: false,
                        title: 'Remote workstation',
                        platformGlyph: LdIcons.windows,
                        location: _bread(['C:', 'lab', 'incoming']),
                        entries: _remote,
                        selected: const {},
                        sorted: 'Size',
                        ascending: false,
                        sendKey: const ValueKey('remote-send'),
                      ),
                    ),
                    Flexible(flex: 2, child: _queue()),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();

    // Park the cursor on the one consequential control, so hover is in the shot.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(hoveredKey)));
    await tester.pumpAndSettle();

    final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('shot')),
    );
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(_out).createSync(recursive: true);
      File('$_out/filemanager.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  });
}
