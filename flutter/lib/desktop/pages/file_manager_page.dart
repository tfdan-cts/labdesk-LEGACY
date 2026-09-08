import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:extended_text/extended_text.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/desktop/widgets/dragable_divider.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:flutter_hbb/desktop/widgets/list_search_action_listener.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';
import 'package:flutter_hbb/labdesk/theme/file_manager_skin.dart';
import 'package:flutter_hbb/labdesk/theme/ld_icons.dart';
import 'package:flutter_hbb/labdesk/theme/session_toolbar_skin.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/web/dummy.dart'
    if (dart.library.html) 'package:flutter_hbb/web/web_unique.dart';

import '../../consts.dart';
import '../../desktop/widgets/material_mod_popup_menu.dart' as mod_menu;
import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../widgets/popup_menu.dart';

/// status of location bar
enum LocationStatus {
  /// normal bread crumb bar
  bread,

  /// show path text field
  pathLocation,

  /// show file search bar text field
  fileSearchBar
}

/// The status of currently focused scope of the mouse
enum MouseFocusScope {
  /// Mouse is in local field.
  local,

  /// Mouse is in remote field.
  remote,

  /// Mouse is not in local field, remote neither.
  none
}

class FileManagerPage extends StatefulWidget {
  FileManagerPage(
      {Key? key,
      required this.id,
      required this.password,
      required this.isSharedPassword,
      this.tabController,
      this.connToken,
      this.forceRelay})
      : super(key: key);
  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final String? connToken;
  final DesktopTabController? tabController;
  final SimpleWrapper<State<FileManagerPage>?> _lastState = SimpleWrapper(null);

  FFI get ffi => (_lastState.value! as _FileManagerPageState)._ffi;

  @override
  State<StatefulWidget> createState() {
    final state = _FileManagerPageState();
    _lastState.value = state;
    return state;
  }
}

class _FileManagerPageState extends State<FileManagerPage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final _mouseFocusScope = Rx<MouseFocusScope>(MouseFocusScope.none);

  final _dropMaskVisible = false.obs; // TODO impl drop mask
  final _overlayKeyState = OverlayKeyState();
  final _uniqueKey = UniqueKey();

  late FFI _ffi;

  FileModel get model => _ffi.fileModel;
  JobController get jobController => model.jobController;

  @override
  void initState() {
    super.initState();
    _ffi = FFI(null);
    _ffi.start(widget.id,
        isFileTransfer: true,
        password: widget.password,
        isSharedPassword: widget.isSharedPassword,
        connToken: widget.connToken,
        forceRelay: widget.forceRelay);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ffi.dialogManager
          .showLoading(translate('Connecting...'), onCancel: closeConnection);
    });
    Get.put<FFI>(_ffi, tag: 'ft_${widget.id}');
    WakelockManager.enable(_uniqueKey);
    if (isWeb) {
      _ffi.ffiModel.updateEventListener(_ffi.sessionId, widget.id);
    }
    debugPrint("File manager page init success with id ${widget.id}");
    _ffi.dialogManager.setOverlayState(_overlayKeyState);
    // Call onSelected in post frame callback, since we cannot guarantee that the callback will not call setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.tabController?.onSelected?.call(widget.id);
    });
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    model.close().whenComplete(() {
      _ffi.close();
      _ffi.dialogManager.dismissAll();
      WakelockManager.disable(_uniqueKey);
      Get.delete<FFI>(tag: 'ft_${widget.id}');
    });
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      jobController.jobTable.refresh();
    }
  }

  Widget willPopScope(Widget child) {
    if (isWeb) {
      return WillPopScope(
        onWillPop: () async {
          clientClose(_ffi.sessionId, _ffi);
          return false;
        },
        child: child,
      );
    } else {
      return child;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Overlay(key: _overlayKeyState.key, initialEntries: [
      OverlayEntry(builder: (_) {
        // The window runs on the console's own theme rather than the app's, so
        // the two panes, the queue and everything Material would otherwise draw
        // inside them sit on one dark surface ramp. It is applied under the
        // overlay, not over it: the dialogs this page raises — the overwrite
        // prompt above all — are unchanged.
        return willPopScope(Theme(
          data: cmThemeData(context),
          child: Scaffold(
            backgroundColor: C.bg,
            body: Padding(
              padding: const EdgeInsets.all(FmSkin.gap),
              child: Row(
                children: [
                  if (!isWeb)
                    Flexible(
                        flex: 3,
                        child: dropArea(FileManagerView(
                            model.localController, _ffi, _mouseFocusScope))),
                  Flexible(
                      flex: 3,
                      child: dropArea(FileManagerView(
                          model.remoteController, _ffi, _mouseFocusScope))),
                  Flexible(flex: 2, child: statusList())
                ],
              ),
            ),
          ),
        ));
      })
    ]);
  }

  Widget dropArea(FileManagerView fileView) {
    return DropTarget(
        onDragDone: (detail) =>
            handleDragDone(detail, fileView.controller.isLocal),
        onDragEntered: (enter) {
          _dropMaskVisible.value = true;
        },
        onDragExited: (exit) {
          _dropMaskVisible.value = false;
        },
        child: fileView);
  }

  /// transfer status list
  /// watch transfer status
  ///
  /// The queue is the part of this window people actually watch, so every state
  /// the model can be in is drawn as itself: waiting, running with a bar and a
  /// rate, paused, finished, failed. The reason a job failed is on the tile
  /// rather than behind a tooltip — a transfer that broke overnight is the
  /// whole reason anybody opens this panel in the morning.
  Widget statusList() {
    FmJobState stateOf(JobProgress job) {
      switch (job.state) {
        case JobState.inProgress:
          return FmJobState.running;
        case JobState.paused:
          return FmJobState.paused;
        case JobState.error:
          return FmJobState.failed;
        case JobState.done:
          return FmJobState.done;
        case JobState.none:
          return FmJobState.queued;
      }
    }

    // The arrow points the way the two panes are laid out: left and right on
    // the desktop, up and down on the web, exactly as before.
    int directionTurns(JobProgress job) => isWeb
        ? (job.isRemoteToLocal ? 1 : 3)
        : (job.isRemoteToLocal ? 2 : 0);

    Widget jobTile(JobProgress item, int index) {
      final running =
          item.type == JobType.transfer && item.state == JobState.inProgress;
      final deleting =
          item.type == JobType.deleteDir || item.type == JobType.deleteFile;
      // `display()` already resolves cancelled and skipped jobs; only the
      // paused state has no word of its own in the model.
      final label = item.display().isNotEmpty
          ? item.display()
          : translate(item.state == JobState.paused ? 'Paused' : 'Waiting');
      final err = item.err;
      return FmJobTile(
        name: Tooltip(
          waitDuration: Duration(milliseconds: 500),
          message: item.jobName,
          // Elided from the front: the tail of a path is the part that says
          // which file this is.
          child: ExtendedText(
            item.jobName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: C.body(color: C.text).copyWith(fontWeight: FontWeight.w600),
            overflowWidget: TextOverflowWidget(
                child: Text("...", style: C.body(color: C.textFaint)),
                position: TextOverflowPosition.start),
          ),
        ),
        state: stateOf(item),
        stateLabel: label,
        detail: item.getStatus(),
        directionGlyph: deleting ? LdIcons.trash : LdIcons.arrowRight,
        directionTurns: deleting ? 0 : directionTurns(item),
        percent: running ? item.percent : null,
        percentText: running ? item.percentText : null,
        speed: running && item.speed > 0
            ? '${readableFileSize(item.speed)}/s'
            : null,
        error: item.state == JobState.error &&
                err.isNotEmpty &&
                err != 'cancel' &&
                err != 'skipped'
            ? err
            : null,
        actions: [
          Offstage(
            offstage: item.state != JobState.paused,
            child: FmToolButton(
              glyph: FmGlyphs.resume,
              tooltip: translate("Resume"),
              onPressed: () {
                jobController.resumeJob(item.id);
              },
            ),
          ),
          FmToolButton(
            glyph: LdIcons.close,
            tooltip: translate("Delete"),
            danger: true,
            onPressed: () {
              jobController.jobTable.removeAt(index);
              jobController.cancelJob(item.id);
            },
          ),
        ],
      );
    }

    statusListView(List<JobProgress> jobs) => ListView.builder(
          controller: ScrollController(),
          itemBuilder: (BuildContext context, int index) =>
              jobTile(jobs[index], index),
          itemCount: jobController.jobTable.length,
        );

    return FmPane(
      rail: true,
      children: [
        FmPaneHeader(
          title: translate('Transfer file'),
          trailing: Obx(() => Text('${jobController.jobTable.length}',
              style: C.data(size: 12, color: C.textFaint))),
        ),
        Expanded(
          child: Obx(
            () => jobController.jobTable.isEmpty
                ? FmEmpty(
                    glyph: LdIcons.fileTransfer,
                    line: translate("No transfers in progress"),
                  )
                : statusListView(jobController.jobTable),
          ),
        ),
      ],
    );
  }

  void handleDragDone(DropDoneDetails details, bool isLocal) {
    if (isLocal) {
      // ignore local
      return;
    }
    final items = SelectedItems(isLocal: false);
    for (var file in details.files) {
      final f = File(file.path);
      items.add(Entry()
        ..path = file.path
        ..name = file.name
        ..size = FileSystemEntity.isDirectorySync(f.path) ? 0 : f.lengthSync());
    }
    final otherSideData = model.localController.directoryData();
    model.remoteController.sendFiles(items, otherSideData);
  }
}

class FileManagerView extends StatefulWidget {
  final FileController controller;
  final FFI _ffi;
  final Rx<MouseFocusScope> _mouseFocusScope;

  FileManagerView(this.controller, this._ffi, this._mouseFocusScope);

  @override
  State<StatefulWidget> createState() => _FileManagerViewState();
}

class _FileManagerViewState extends State<FileManagerView> {
  final _locationStatus = LocationStatus.bread.obs;
  final _locationNode = FocusNode();
  final _locationBarKey = GlobalKey();
  final _searchText = "".obs;
  final _breadCrumbScroller = ScrollController();
  final _keyboardNode = FocusNode();
  final _listSearchBuffer = TimeoutStringBuffer();
  final _nameColWidth = 0.0.obs;
  final _modifiedColWidth = 0.0.obs;
  final _sizeColWidth = 0.0.obs;
  final _fileListScrollController = ScrollController();
  final _globalHeaderKey = GlobalKey();
  final _menuButtonKey = GlobalKey();

  /// [_lastClickTime], [_lastClickEntry] help to handle double click
  var _lastClickTime =
      DateTime.now().millisecondsSinceEpoch - bind.getDoubleClickTime() - 1000;
  Entry? _lastClickEntry;

  String _localHostname = '';

  double? _windowWidthPrev;
  double _fileTransferMinimumWidth = 0.0;

  FileController get controller => widget.controller;
  bool get isLocal => widget.controller.isLocal;
  FFI get _ffi => widget._ffi;
  SelectedItems get selectedItems => controller.selectedItems;

  @override
  void initState() {
    super.initState();
    if (isLocal && !isWeb) {
      try {
        _localHostname = Platform.localHostname.trim();
      } on OSError {
        // A missing OS name keeps the honest local-machine label.
      }
    }
    // register location listener
    _locationNode.addListener(onLocationFocusChanged);
    controller.directory.listen((e) => breadCrumbScrollToEnd());
  }

  @override
  void dispose() {
    _locationNode.removeListener(onLocationFocusChanged);
    _locationNode.dispose();
    _keyboardNode.dispose();
    _breadCrumbScroller.dispose();
    _fileListScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _handleColumnPorportions();
    return FmPane(
      children: [
        headTools(),
        Expanded(
          child: MouseRegion(
            onEnter: (evt) {
              widget._mouseFocusScope.value =
                  isLocal ? MouseFocusScope.local : MouseFocusScope.remote;
              _keyboardNode.requestFocus();
            },
            onExit: (evt) =>
                widget._mouseFocusScope.value = MouseFocusScope.none,
            child: _buildFileList(context, _fileListScrollController),
          ),
        ),
      ],
    );
  }

  void _handleColumnPorportions() {
    final windowWidthNow = MediaQuery.of(context).size.width;
    if (_windowWidthPrev == null) {
      _windowWidthPrev = windowWidthNow;
      final defaultColumnWidth = windowWidthNow * 0.115;
      _fileTransferMinimumWidth = defaultColumnWidth / 3;
      // The same three columns of space as before, apportioned by what each one
      // holds: the name is what the eye scans and was the column that ran out
      // of room first, while the size never needs more than eight characters.
      _nameColWidth.value = defaultColumnWidth * 1.5;
      _modifiedColWidth.value = defaultColumnWidth * 0.9;
      _sizeColWidth.value = defaultColumnWidth * 0.6;
    }

    if (_windowWidthPrev != windowWidthNow) {
      final difference = windowWidthNow / _windowWidthPrev!;
      _windowWidthPrev = windowWidthNow;
      _fileTransferMinimumWidth *= difference;
      _nameColWidth.value *= difference;
      _modifiedColWidth.value *= difference;
      _sizeColWidth.value *= difference;
    }
  }

  void onLocationFocusChanged() {
    debugPrint("focus changed on local");
    if (_locationNode.hasFocus) {
      // ignore
    } else {
      // lost focus, change to bread
      if (_locationStatus.value != LocationStatus.fileSearchBar) {
        _locationStatus.value = LocationStatus.bread;
      }
    }
  }

  Widget headTools() {
    var uploadButtonTapPosition = RelativeRect.fill;
    RxBool isUploadFolder =
        (bind.mainGetLocalOption(key: 'upload-folder-button') == 'Y').obs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Which machine this pane is showing. The platform mark is the
        // console's own glyph rather than the borrowed logo, and it sits on the
        // surface ramp instead of inside a filled accent square — the accent in
        // this window means "this is the action".
        AnimatedBuilder(
          animation: _ffi.ffiModel,
          builder: (context, _) {
            final role = translate(isLocal ? 'Local Computer' : 'Remote Computer');
            // The peer-info event supplies the connected machine's own hostname.
            // An address/ID remains a connection key, never a fabricated name.
            final hostname = isLocal
                ? _localHostname
                : _ffi.ffiModel.pi.hostname.trim();
            final platform = isLocal
                ? (isWindows ? 'Windows' : (isMacOS ? 'Mac OS' : 'Linux'))
                : _ffi.ffiModel.pi.platform;
            return FmPaneHeader(
              title: hostname.isEmpty ? role : hostname,
              subtitle: hostname.isEmpty ? null : role,
              badge: LdIcon(_platformGlyph(platform),
                  size: 18, color: C.textMuted),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Column(
            children: [
              // Where the pane is, and how to get somewhere else.
              Row(
                children: [
                  FmToolButton(
                    glyph: LdIcons.chevronLeft,
                    tooltip: translate('Back'),
                    onPressed: () {
                      selectedItems.clear();
                      controller.goBack();
                    },
                  ),
                  FmToolButton(
                    glyph: LdIcons.arrowUp,
                    tooltip: translate('Parent directory'),
                    onPressed: () {
                      selectedItems.clear();
                      controller.goToParentDirectory();
                    },
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6.0),
                      child: Container(
                        height: FmSkin.toolButtonSize,
                        decoration: FmSkin.field,
                        child: GestureDetector(
                          onTap: () {
                            _locationStatus.value =
                                _locationStatus.value == LocationStatus.bread
                                    ? LocationStatus.pathLocation
                                    : LocationStatus.bread;
                            Future.delayed(Duration.zero, () {
                              if (_locationStatus.value ==
                                  LocationStatus.pathLocation) {
                                _locationNode.requestFocus();
                              }
                            });
                          },
                          child: Obx(
                            () => Row(
                              children: [
                                Expanded(
                                    child: _locationStatus.value ==
                                            LocationStatus.bread
                                        ? buildBread()
                                        : buildPathLocation()),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Obx(() {
                    switch (_locationStatus.value) {
                      case LocationStatus.bread:
                        return FmToolButton(
                          glyph: LdIcons.search,
                          tooltip: translate('Search'),
                          onPressed: () {
                            _locationStatus.value =
                                LocationStatus.fileSearchBar;
                            Future.delayed(Duration.zero,
                                () => _locationNode.requestFocus());
                          },
                        );
                      case LocationStatus.pathLocation:
                        return FmToolButton(
                          glyph: LdIcons.close,
                          tooltip: '',
                          onPressed: null,
                        );
                      case LocationStatus.fileSearchBar:
                        return FmToolButton(
                          glyph: LdIcons.close,
                          tooltip: translate('Clear'),
                          onPressed: () {
                            onSearchText("", isLocal);
                            _locationStatus.value = LocationStatus.bread;
                          },
                        );
                    }
                  }),
                  FmToolButton(
                    glyph: LdIcons.refresh,
                    tooltip: translate('Refresh File'),
                    onPressed: () {
                      controller.refresh();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // What can be done to what is in it. The two panes are built the
              // same way round: mirroring them put Send and Receive nose to
              // nose across the gap, which is a gutter of arrows, not a layout.
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        FmToolButton(
                          glyph: FmGlyphs.home,
                          tooltip: translate('Home'),
                          onPressed: () {
                            controller.goToHomeDirectory();
                          },
                        ),
                        FmToolButton(
                          glyph: LdIcons.folderAdd,
                          tooltip: translate('Create Folder'),
                          onPressed: () {
                        final name = TextEditingController();
                        String? errorText;
                        _ffi.dialogManager.show((setState, close, context) {
                          name.addListener(() {
                            if (errorText != null) {
                              setState(() {
                                errorText = null;
                              });
                            }
                          });
                          submit() {
                            if (name.value.text.isNotEmpty) {
                              if (!PathUtil.validName(name.value.text,
                                  controller.options.value.isWindows)) {
                                setState(() {
                                  errorText = translate("Invalid folder name");
                                });
                                return;
                              }
                              controller.createDir(PathUtil.join(
                                controller.directory.value.path,
                                name.value.text,
                                controller.options.value.isWindows,
                              ));
                              close();
                            }
                          }

                          cancel() => close(false);
                          return CustomAlertDialog(
                            title: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SvgPicture.asset("assets/folder_new.svg",
                                    colorFilter: svgColor(MyTheme.accent)),
                                Text(
                                  translate("Create Folder"),
                                ).paddingOnly(
                                  left: 10,
                                ),
                              ],
                            ),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextFormField(
                                  decoration: InputDecoration(
                                    labelText: translate(
                                      "Please enter the folder name",
                                    ),
                                    errorText: errorText,
                                  ),
                                  controller: name,
                                  autofocus: true,
                                ).workaroundFreezeLinuxMint(),
                              ],
                            ),
                            actions: [
                              dialogButton(
                                "Cancel",
                                icon: Icon(Icons.close_rounded),
                                onPressed: cancel,
                                isOutline: true,
                              ),
                              dialogButton(
                                "Ok",
                                icon: Icon(Icons.done_rounded),
                                onPressed: submit,
                              ),
                            ],
                            onSubmit: submit,
                            onCancel: cancel,
                          );
                        });
                      },
                        ),
                        Obx(() => FmToolButton(
                              glyph: LdIcons.trash,
                              tooltip: translate('Delete'),
                              danger: true,
                              onPressed:
                                  SelectedItems.valid(selectedItems.items)
                                      ? () async {
                                          await (controller
                                              .removeAction(selectedItems));
                                          selectedItems.clear();
                                        }
                                      : null,
                            )),
                        menu(isLocal: isLocal),
                      ],
                    ),
                  ),
                  if (isWeb)
                    Obx(() => Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            FmSendButton(
                              label: translate(isUploadFolder.isTrue
                                  ? 'Upload folder'
                                  : 'Upload files'),
                              glyph: LdIcons.arrowUp,
                              onPressed: () =>
                                  {webselectFiles(is_folder: isUploadFolder.value)},
                            ),
                            InkWell(
                              hoverColor: Colors.transparent,
                              splashColor: Colors.transparent,
                              highlightColor: Colors.transparent,
                              focusColor: Colors.transparent,
                              onTapDown: (e) {
                                final x = e.globalPosition.dx;
                                final y = e.globalPosition.dy;
                                uploadButtonTapPosition =
                                    RelativeRect.fromLTRB(x, y, x, y);
                              },
                              onTap: () async {
                                final value = await showMenu<bool>(
                                    context: context,
                                    position: uploadButtonTapPosition,
                                    items: [
                                      PopupMenuItem<bool>(
                                        value: false,
                                        child: Text(translate('Upload files')),
                                      ),
                                      PopupMenuItem<bool>(
                                        value: true,
                                        child: Text(translate('Upload folder')),
                                      ),
                                    ]);
                                if (value != null) {
                                  isUploadFolder.value = value;
                                  bind.mainSetLocalOption(
                                      key: 'upload-folder-button',
                                      value: value ? 'Y' : '');
                                  webselectFiles(is_folder: value);
                                }
                              },
                              child: const LdIcon(LdIcons.chevronDown,
                                  size: 16, color: C.textMuted),
                            ),
                          ]),
                        )),
                  Obx(() => FmSendButton(
                        label: isLocal
                            ? translate('Send')
                            : translate(isWeb ? 'Download' : 'Receive'),
                        // The same mark on both, because it is the same act:
                        // the word is what says which way it goes.
                        glyph: LdIcons.fileTransfer,
                        onPressed: SelectedItems.valid(selectedItems.items)
                            ? () {
                                final otherSideData =
                                    controller.getOtherSideDirectoryData();
                                controller.sendFiles(
                                    selectedItems, otherSideData);
                                selectedItems.clear();
                              }
                            : null,
                      )),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The console draws its own platform marks, so the pane header uses those
  /// rather than the borrowed logos. Unknown peers keep a generic machine
  /// mark until peer-info supplies their platform.
  String _platformGlyph(String platform) {
    if (platform == kPeerPlatformMacOS) return LdIcons.macos;
    if (platform == kPeerPlatformLinux) return LdIcons.linux;
    if (platform == kPeerPlatformAndroid) return LdIcons.android;
    if (platform == kPeerPlatformWindows) return LdIcons.windows;
    return LdIcons.machine;
  }

  Widget menu({bool isLocal = false}) {
    final List<MenuEntryBase<String>> items = [
      MenuEntrySwitch<String>(
        switchType: SwitchType.scheckbox,
        text: translate("Show Hidden Files"),
        getter: () async {
          return controller.options.value.showHidden;
        },
        setter: (bool v) async {
          controller.toggleShowHidden();
        },
        padding: kDesktopMenuPadding,
        dismissOnClicked: true,
      ),
      MenuEntryButton(
          childBuilder: (style) => Text(translate("Select All"), style: style),
          proc: () => setState(() =>
              selectedItems.selectAll(controller.directory.value.entries)),
          padding: kDesktopMenuPadding,
          dismissOnClicked: true),
      MenuEntryButton(
          childBuilder: (style) =>
              Text(translate("Unselect All"), style: style),
          proc: () => selectedItems.clear(),
          padding: kDesktopMenuPadding,
          dismissOnClicked: true)
    ];

    return FmToolButton(
      key: _menuButtonKey,
      glyph: LdIcons.more,
      tooltip: translate('More'),
      onPressed: () {
        final button =
            _menuButtonKey.currentContext!.findRenderObject() as RenderBox;
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox;
        final position = RelativeRect.fromRect(
          button.localToGlobal(Offset(0, button.size.height), ancestor: overlay) &
              Size.zero,
          Offset.zero & overlay.size,
        );
        mod_menu.showMenu(
          context: context,
          position: position,
          items: items
              .map(
                (e) => e.build(
                  context,
                  MenuConfig(
                      commonColor: CustomPopupMenuTheme.commonColor,
                      height: CustomPopupMenuTheme.height,
                      dividerHeight: CustomPopupMenuTheme.dividerHeight),
                ),
              )
              .expand((i) => i)
              .toList(),
          elevation: 8,
        );
      },
    );
  }

  Widget _buildFileList(
      BuildContext context, ScrollController scrollController) {
    final fd = controller.directory.value;
    final entries = fd.entries;
    Rx<Entry?> rightClickEntry = Rx(null);

    return ListSearchActionListener(
      node: _keyboardNode,
      buffer: _listSearchBuffer,
      onNext: (buffer) {
        debugPrint("searching next for $buffer");
        assert(buffer.length == 1);
        assert(selectedItems.items.length <= 1);
        var skipCount = 0;
        if (selectedItems.items.isNotEmpty) {
          final index = entries.indexOf(selectedItems.items.first);
          if (index < 0) {
            return;
          }
          skipCount = index + 1;
        }
        var searchResult = entries
            .skip(skipCount)
            .where((element) => element.name.toLowerCase().startsWith(buffer));
        if (searchResult.isEmpty) {
          // cannot find next, lets restart search from head
          debugPrint("restart search from head");
          searchResult = entries.where(
              (element) => element.name.toLowerCase().startsWith(buffer));
        }
        if (searchResult.isEmpty) {
          selectedItems.clear();
          return;
        }
        _jumpToEntry(isLocal, searchResult.first, scrollController,
            FmSkin.rowHeight);
      },
      onSearch: (buffer) {
        debugPrint("searching for $buffer");
        final selectedEntries = selectedItems;
        final searchResult = entries
            .where((element) => element.name.toLowerCase().startsWith(buffer));
        selectedEntries.clear();
        if (searchResult.isEmpty) {
          selectedItems.clear();
          return;
        }
        _jumpToEntry(isLocal, searchResult.first, scrollController,
            FmSkin.rowHeight);
      },
      child: Obx(() {
        final entries = controller.directory.value.entries;
        final filteredEntries = _searchText.isNotEmpty
            ? entries.where((element) {
                return element.name.contains(_searchText.value);
              }).toList(growable: false)
            : entries;
        final rows = filteredEntries.map((entry) {
          final sizeStr =
              entry.isFile ? readableFileSize(entry.size.toDouble()) : "";
          final lastModifiedStr = entry.isDrive
              ? " "
              : "${entry.lastModified().toString().replaceAll(".000", "")}   ";
          var secondaryPosition = RelativeRect.fromLTRB(0, 0, 0, 0);
          onTap() {
            final items = selectedItems;
            // handle double click
            if (_checkDoubleClick(entry)) {
              controller.openDirectory(entry.path);
              items.clear();
              return;
            }
            _onSelectedChanged(items, filteredEntries, entry, isLocal);
          }

          onSecondaryTap() {
            final items = [
              if (!entry.isDrive &&
                  versionCmp(_ffi.ffiModel.pi.version, "1.3.0") >= 0)
                mod_menu.PopupMenuItem(
                  child: Text(translate("Rename")),
                  height: CustomPopupMenuTheme.height,
                  onTap: () {
                    controller.renameAction(entry, isLocal);
                  },
                )
            ];
            if (items.isNotEmpty) {
              rightClickEntry.value = entry;
              final future = mod_menu.showMenu(
                context: context,
                position: secondaryPosition,
                items: items,
              );
              future.then((value) {
                rightClickEntry.value = null;
              });
              future.onError((error, stackTrace) {
                rightClickEntry.value = null;
              });
            }
          }

          onSecondaryTapDown(details) {
            secondaryPosition = RelativeRect.fromLTRB(
                details.globalPosition.dx,
                details.globalPosition.dy,
                details.globalPosition.dx,
                details.globalPosition.dy);
          }

          return Obx(() => FmFileRow(
                key: ValueKey(entry.name),
                name: entry.name.nonBreaking,
                kind: entry.isDrive
                    ? FmEntryKind.drive
                    : (entry.isFile ? FmEntryKind.file : FmEntryKind.folder),
                modified: lastModifiedStr,
                size: sizeStr,
                selected: selectedItems.items.contains(entry),
                contextTarget: rightClickEntry.value == entry,
                nameWidth: _nameColWidth.value,
                modifiedWidth: _modifiedColWidth.value,
                onTap: onTap,
                onSecondaryTap: onSecondaryTap,
                onSecondaryTapDown: onSecondaryTapDown,
              ));
        }).toList(growable: false);

        return Column(
          children: [
            _buildFileBrowserHeader(context),
            // Body
            Expanded(
              child: rows.isEmpty
                  ? FmEmpty(
                      glyph: FmGlyphs.folder,
                      line: translate('Empty'),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemExtent: FmSkin.rowHeight,
                      itemBuilder: (context, index) {
                        return rows[index];
                      },
                      itemCount: rows.length,
                    ),
            ),
          ],
        );
      }),
    );
  }

  onSearchText(String searchText, bool isLocal) {
    selectedItems.clear();
    _searchText.value = searchText;
  }

  void _jumpToEntry(bool isLocal, Entry entry,
      ScrollController scrollController, double rowHeight) {
    final entries = controller.directory.value.entries;
    final index = entries.indexOf(entry);
    if (index == -1) {
      debugPrint("entry is not valid: ${entry.path}");
    }
    final selectedEntries = selectedItems;
    final searchResult = entries.where((element) => element == entry);
    selectedEntries.clear();
    if (searchResult.isEmpty) {
      return;
    }
    final offset = min(
        max(scrollController.position.minScrollExtent,
            entries.indexOf(searchResult.first) * rowHeight),
        scrollController.position.maxScrollExtent);
    scrollController.jumpTo(offset);
    selectedEntries.add(searchResult.first);
    debugPrint("focused on ${searchResult.first.name}");
  }

  void _onSelectedChanged(SelectedItems selectedItems, List<Entry> entries,
      Entry entry, bool isLocal) {
    final isCtrlDown = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlLeft) ||
        RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlRight);
    final isShiftDown = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.shiftLeft) ||
        RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.shiftRight);
    if (isCtrlDown) {
      if (selectedItems.items.contains(entry)) {
        selectedItems.remove(entry);
      } else {
        selectedItems.add(entry);
      }
    } else if (isShiftDown) {
      final List<int> indexGroup = [];
      for (var selected in selectedItems.items) {
        indexGroup.add(entries.indexOf(selected));
      }
      indexGroup.add(entries.indexOf(entry));
      indexGroup.removeWhere((e) => e == -1);
      final maxIndex = indexGroup.reduce(max);
      final minIndex = indexGroup.reduce(min);
      selectedItems.clear();
      entries
          .getRange(minIndex, maxIndex + 1)
          .forEach((e) => selectedItems.add(e));
    } else {
      selectedItems.clear();
      selectedItems.add(entry);
    }
    setState(() {});
  }

  bool _checkDoubleClick(Entry entry) {
    final current = DateTime.now().millisecondsSinceEpoch;
    final elapsed = current - _lastClickTime;
    _lastClickTime = current;
    if (_lastClickEntry == entry) {
      if (elapsed < bind.getDoubleClickTime()) {
        return true;
      }
    } else {
      _lastClickEntry = entry;
    }
    return false;
  }

  void _onDrag(double dx, RxDouble column1, RxDouble column2) {
    if (column1.value + dx <= _fileTransferMinimumWidth ||
        column2.value - dx <= _fileTransferMinimumWidth) {
      return;
    }
    column1.value += dx;
    column2.value -= dx;
    column1.value = max(_fileTransferMinimumWidth, column1.value);
    column2.value = max(_fileTransferMinimumWidth, column2.value);
  }

  /// The column heads, on the chrome plane so the band reads as a rule over the
  /// listing rather than as its first row.
  ///
  /// The leading 2 and the trailing 10 are the row's own selection rule and its
  /// right margin: the heads sit exactly over the columns they name, which the
  /// old header did not.
  Widget _buildFileBrowserHeader(BuildContext context) {
    const padding = EdgeInsets.symmetric(horizontal: 0.5);
    return Container(
      key: _globalHeaderKey,
      height: FmSkin.headerHeight,
      decoration: const BoxDecoration(
        color: C.chrome,
        border: Border(
          top: BorderSide(color: C.hairline),
          bottom: BorderSide(color: C.hairline),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 2),
          Obx(
            () => headerItemFunc(
                _nameColWidth.value, SortBy.name, translate("Name"),
                leading: 10),
          ),
          DraggableDivider(
            axis: Axis.vertical,
            color: C.hairline,
            onPointerMove: (dx) =>
                _onDrag(dx, _nameColWidth, _modifiedColWidth),
            padding: padding,
          ),
          Obx(
            () => headerItemFunc(_modifiedColWidth.value, SortBy.modified,
                translate("Modified")),
          ),
          DraggableDivider(
              axis: Axis.vertical,
              color: C.hairline,
              onPointerMove: (dx) =>
                  _onDrag(dx, _modifiedColWidth, _sizeColWidth),
              padding: padding),
          Expanded(
              child: headerItemFunc(null, SortBy.size, translate("Size"),
                  alignEnd: true)),
          const SizedBox(width: 10),
        ],
      ),
    );
  }

  Widget headerItemFunc(double? width, SortBy sortBy, String name,
      {double leading = 0, bool alignEnd = false}) {
    return ObxValue<Rx<bool?>>(
        (ascending) => SizedBox(
              width: width,
              child: Padding(
                padding: EdgeInsets.only(left: leading),
                child: FmColumnHead(
                  label: name,
                  ascending: ascending.value,
                  alignEnd: alignEnd,
                  onTap: () {
                    if (ascending.value == null) {
                      ascending.value = true;
                    } else {
                      ascending.value = !ascending.value!;
                    }
                    controller.changeSortStyle(sortBy,
                        isLocal: isLocal, ascending: ascending.value!);
                  },
                ),
              ),
            ), () {
      if (controller.sortBy.value == sortBy) {
        return controller.sortAscending.obs;
      } else {
        return Rx<bool?>(null);
      }
    }());
  }

  Widget buildBread() {
    final items = getPathBreadCrumbItems(isLocal, (list) {
      var path = "";
      for (var item in list) {
        path = PathUtil.join(path, item, controller.options.value.isWindows);
      }
      controller.openDirectory(path);
    });

    return items.isEmpty
        ? Offstage()
        : Row(
            key: _locationBarKey,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
                Expanded(
                  child: Listener(
                    // handle mouse wheel
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent) {
                        final sc = _breadCrumbScroller;
                        final scale = isWindows ? 2 : 4;
                        sc.jumpTo(sc.offset + e.scrollDelta.dy / scale);
                      }
                    },
                    child: BreadCrumb(
                      items: items,
                      divider: const LdIcon(LdIcons.chevronRight,
                          size: 12, color: C.textFaint),
                      overflow: ScrollableOverflow(
                        controller: _breadCrumbScroller,
                      ),
                    ),
                  ),
                ),
                FmToolButton(
                  glyph: LdIcons.chevronDown,
                  tooltip: translate('Path'),
                  glyphSize: 15,
                  onPressed: () async {
                    final renderBox = _locationBarKey.currentContext
                        ?.findRenderObject() as RenderBox;
                    _locationBarKey.currentContext?.size;

                    final size = renderBox.size;
                    final offset = renderBox.localToGlobal(Offset.zero);

                    final x = offset.dx;
                    final y = offset.dy + size.height + 1;

                    final isPeerWindows = controller.options.value.isWindows;
                    final List<MenuEntryBase> menuItems = [
                      MenuEntryButton(
                          childBuilder: (TextStyle? style) => isPeerWindows
                              ? buildWindowsThisPC(context, style)
                              : Text(
                                  '/',
                                  style: style,
                                ),
                          proc: () {
                            controller.openDirectory('/');
                          },
                          dismissOnClicked: true),
                      MenuEntryDivider()
                    ];
                    if (isPeerWindows) {
                      var loadingTag = "";
                      if (!isLocal) {
                        loadingTag = _ffi.dialogManager.showLoading("Waiting");
                      }
                      try {
                        final showHidden = controller.options.value.showHidden;
                        final fd = await controller.fileFetcher
                            .fetchDirectory("/", isLocal, showHidden);
                        for (var entry in fd.entries) {
                          menuItems.add(MenuEntryButton(
                              childBuilder: (TextStyle? style) =>
                                  Row(children: [
                                    const LdIcon(FmGlyphs.drive,
                                        size: 16, color: C.textMuted),
                                    SizedBox(width: 10),
                                    Text(
                                      entry.name,
                                      style: style,
                                    )
                                  ]),
                              proc: () {
                                controller.openDirectory('${entry.name}\\');
                              },
                              dismissOnClicked: true));
                        }
                        menuItems.add(MenuEntryDivider());
                      } catch (e) {
                        debugPrint("buildBread fetchDirectory err=$e");
                      } finally {
                        if (!isLocal) {
                          _ffi.dialogManager.dismissByTag(loadingTag);
                        }
                      }
                    }
                    mod_menu.showMenu(
                        context: context,
                        position: RelativeRect.fromLTRB(x, y, x, y),
                        elevation: 4,
                        items: menuItems
                            .map((e) => e.build(
                                context,
                                MenuConfig(
                                    commonColor:
                                        CustomPopupMenuTheme.commonColor,
                                    height: CustomPopupMenuTheme.height,
                                    dividerHeight:
                                        CustomPopupMenuTheme.dividerHeight,
                                    boxWidth: size.width)))
                            .expand((i) => i)
                            .toList());
                  },
                )
              ]);
  }

  List<BreadCrumbItem> getPathBreadCrumbItems(
      bool isLocal, void Function(List<String>) onPressed) {
    final path = controller.directory.value.path;
    final breadCrumbList = List<BreadCrumbItem>.empty(growable: true);
    final isWindows = controller.options.value.isWindows;
    if (isWindows && path == '/') {
      breadCrumbList.add(BreadCrumbItem(
          content: GestureDetector(
        onTap: () => onPressed(['/']),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: buildWindowsThisPC(context),
          ),
        ),
      )));
    } else {
      final list = PathUtil.split(path, isWindows);
      breadCrumbList.addAll(
        // The last crumb is where the pane actually is, so it is the only one
        // at full strength; the ones behind it are a way back, which is a
        // quieter job.
        list.asMap().entries.map(
              (e) => BreadCrumbItem(
                content: FmCrumb(
                  label: e.value,
                  current: e.key == list.length - 1,
                  onTap: () => onPressed(
                    list.sublist(0, e.key + 1),
                  ),
                ),
              ),
            ),
      );
    }
    return breadCrumbList;
  }

  breadCrumbScrollToEnd() {
    Future.delayed(Duration(milliseconds: 200), () {
      if (_breadCrumbScroller.hasClients) {
        _breadCrumbScroller.animateTo(
            _breadCrumbScroller.position.maxScrollExtent,
            duration: Duration(milliseconds: 200),
            curve: Curves.fastLinearToSlowEaseIn);
      }
    });
  }

  Widget buildPathLocation() {
    final text = _locationStatus.value == LocationStatus.pathLocation
        ? controller.directory.value.path
        : _searchText.value;
    final textController = TextEditingController(text: text)
      ..selection = TextSelection.collapsed(offset: text.length);
    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: LdIcon(
            _locationStatus.value == LocationStatus.pathLocation
                ? FmGlyphs.folder
                : LdIcons.search,
            size: 15,
            color: C.textFaint,
          ),
        ),
        Expanded(
          child: TextField(
            focusNode: _locationNode,
            // A path is an identifier, so it is typed and read in the console's
            // data face.
            style: C.data(size: 12.5, color: C.text),
            cursorColor: C.accent,
            cursorWidth: 1.6,
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
            ),
            controller: textController,
            onSubmitted: (path) {
              controller.openDirectory(path);
            },
            onChanged: _locationStatus.value == LocationStatus.fileSearchBar
                ? (searchText) => onSearchText(searchText, isLocal)
                : null,
          ).workaroundFreezeLinuxMint(),
        )
      ],
    );
  }

  // openDirectory(String path, {bool isLocal = false}) {
  //   model.openDirectory(path, isLocal: isLocal);
  // }
}

Widget buildWindowsThisPC(BuildContext context, [TextStyle? textStyle]) {
  return Row(mainAxisSize: MainAxisSize.min, children: [
    const LdIcon(LdIcons.machine, size: 16, color: C.textMuted),
    SizedBox(width: 10),
    Text(translate('This PC'),
        style: textStyle ?? C.small(color: C.text, w: FontWeight.w700))
  ]);
}
