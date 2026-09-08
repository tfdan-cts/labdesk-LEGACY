import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:bot_toast/bot_toast.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide TabBarTheme;
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';
import 'package:flutter_hbb/labdesk/theme/ld_icons.dart';
import 'package:flutter_hbb/labdesk/theme/session_toolbar_skin.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/pages/view_camera_page.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:get/get_rx/src/rx_workers/utils/debouncer.dart';
import 'package:scroll_pos/scroll_pos.dart';
import 'package:window_manager/window_manager.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../utils/multi_window_manager.dart';

const double _kTabBarHeight = kDesktopRemoteTabBarHeight;
const double _kIconSize = TabSkin.glyphSize;
const double _kActionIconSize = 12;

/// The kind of session a window holds, as one of the console's own glyphs.
///
/// Every tab in a window is the same kind — the kind is fixed when the window
/// is opened — so this is what the tab bar knows about a session without
/// asking anything new.
String? _tabTypeGlyph(DesktopTabType tabType, String tabKey) {
  switch (tabType) {
    case DesktopTabType.remoteScreen:
      return LdIcons.display;
    case DesktopTabType.viewCamera:
      return LdIcons.camera;
    case DesktopTabType.fileTransfer:
      return LdIcons.fileTransfer;
    case DesktopTabType.portForward:
      return LdIcons.portForward;
    case DesktopTabType.terminal:
      return LdIcons.terminal;
    // The main window's own tabs are sections of the console, not sessions.
    case DesktopTabType.main:
      return tabKey == kTabLabelSettingPage ? LdIcons.settings : LdIcons.fleet;
    case DesktopTabType.cm:
    case DesktopTabType.install:
      return null;
  }
}

/// The platform of the machine behind a tab, as a glyph, or null when nothing
/// has been recorded about it yet.
///
/// This reads the same peer record the tab's own label already comes from —
/// [getDesktopTabLabel] calls `mainGetPeerSync` for the hostname on every
/// build — so the strip is not given a new source of truth, only the part of
/// the one it already reads that was being thrown away. A machine that has
/// never connected has no platform recorded, and then the tab leads with the
/// kind of session instead, exactly as it used to.
String? _peerPlatformGlyph(String tabKey) {
  String? read(String id) {
    try {
      final config = jsonDecode(bind.mainGetPeerSync(id: id));
      final raw = config['info']?['platform'];
      return raw is String && raw.isNotEmpty ? raw.toLowerCase() : null;
    } catch (e) {
      return null;
    }
  }

  // Terminal tabs are keyed '<peer>_<terminal>'; every other kind is keyed by
  // the peer alone.
  var platform = read(tabKey);
  final cut = tabKey.lastIndexOf('_');
  if (platform == null && cut > 0) {
    platform = read(tabKey.substring(0, cut));
  }
  if (platform == null) return null;
  if (platform.contains('win')) return LdIcons.windows;
  if (platform.contains('mac') ||
      platform.contains('darwin') ||
      platform.contains('ios')) {
    return LdIcons.macos;
  }
  if (platform.contains('android')) return LdIcons.android;
  if (platform.contains('linux') || platform.contains('nix')) {
    return LdIcons.linux;
  }
  // An unrecognised platform is not guessed at.
  return null;
}

/// The window's own buttons carry [IconData] in their public API, and four
/// pages outside this file still hand them Material and LabDesk icon-font
/// values. Mapping here means those callers draw the console's glyphs without
/// being touched, and anything unmapped still draws what it asked for.
final Map<IconData, String> _kLdGlyphs = {
  IconFont.min: LdIcons.minus,
  IconFont.max: LdIcons.maximize,
  IconFont.restore: LdIcons.restore,
  IconFont.close: LdIcons.close,
  IconFont.add: LdIcons.add,
  IconFont.menu: LdIcons.more,
  IconFont.more: LdIcons.more,
  IconFont.search: LdIcons.search,
  Icons.close: LdIcons.close,
  Icons.add: LdIcons.add,
  Icons.arrow_drop_down: LdIcons.chevronDown,
  Icons.keyboard_arrow_down_rounded: LdIcons.chevronDown,
  Icons.arrow_left: LdIcons.chevronLeft,
  Icons.arrow_right: LdIcons.chevronRight,
};

class TabInfo {
  final String key; // Notice: cm use client_id.toString() as key
  final String label;
  final IconData? selectedIcon;
  final IconData? unselectedIcon;
  final bool closable;
  final VoidCallback? onTabCloseButton;
  final VoidCallback? onTap;
  final Widget page;

  TabInfo(
      {required this.key,
      required this.label,
      this.selectedIcon,
      this.unselectedIcon,
      this.closable = true,
      this.onTabCloseButton,
      this.onTap,
      required this.page});
}

enum DesktopTabType {
  main,
  cm,
  remoteScreen,
  fileTransfer,
  viewCamera,
  portForward,
  terminal,
  install,
}

class DesktopTabState {
  final List<TabInfo> tabs = [];
  final ScrollPosController scrollController =
      ScrollPosController(itemCount: 0);
  final PageController pageController = PageController();
  int selected = 0;

  TabInfo get selectedTabInfo => tabs[selected];

  DesktopTabState() {
    scrollController.itemCount = tabs.length;
  }
}

CancelFunc showRightMenu(ToastBuilder builder,
    {BuildContext? context, Offset? target}) {
  return BotToast.showAttachedWidget(
    target: target,
    targetContext: context,
    verticalOffset: 0.0,
    horizontalOffset: 0.0,
    duration: Duration(seconds: 300),
    animationDuration: Duration(milliseconds: 0),
    animationReverseDuration: Duration(milliseconds: 0),
    preferDirection: PreferDirection.rightTop,
    ignoreContentClick: false,
    onlyOne: true,
    allowClick: true,
    enableSafeArea: true,
    backgroundColor: Color(0x00000000),
    attachedBuilder: builder,
  );
}

class DesktopTabController {
  final state = DesktopTabState().obs;
  final DesktopTabType tabType;

  /// index, key
  Function(int, String)? onRemoved;
  Function(String)? onSelected;
  Future<void> Function()? onCloseWindow;

  DesktopTabController(
      {required this.tabType, this.onRemoved, this.onSelected});

  int get length => state.value.tabs.length;

  void add(TabInfo tab) {
    if (!isDesktop) return;
    final index = state.value.tabs.indexWhere((e) => e.key == tab.key);
    int toIndex;
    if (index >= 0) {
      toIndex = index;
    } else {
      state.update((val) {
        val!.tabs.add(tab);
      });
      state.value.scrollController.itemCount = state.value.tabs.length;
      toIndex = state.value.tabs.length - 1;
      assert(toIndex >= 0);
    }
    try {
      // tabPage has not been initialized, call `onSelected` at the end of initState
      jumpTo(toIndex, callOnSelected: false);
    } catch (e) {
      // call before binding controller will throw
      debugPrint("Failed to jumpTo: $e");
    }
  }

  void remove(int index) {
    if (!isDesktop) return;
    final len = state.value.tabs.length;
    if (index < 0 || index > len - 1) return;
    final key = state.value.tabs[index].key;
    final currentSelected = state.value.selected;
    int toIndex = 0;
    if (index == len - 1) {
      toIndex = max(0, currentSelected - 1);
    } else if (index < len - 1 && index < currentSelected) {
      toIndex = max(0, currentSelected - 1);
    }
    state.value.tabs.removeAt(index);
    state.value.scrollController.itemCount = state.value.tabs.length;
    jumpTo(toIndex);
    onRemoved?.call(index, key);
  }

  /// For addTab, tabPage has not been initialized, set [callOnSelected] to false,
  /// and call [onSelected] at the end of initState
  bool jumpTo(int index, {bool callOnSelected = true}) {
    if (!isDesktop || index < 0) {
      return false;
    }
    state.update((val) {
      if (val != null) {
        val.selected = index;
        Future.delayed(Duration(milliseconds: 100), (() {
          if (val.pageController.hasClients) {
            val.pageController.jumpToPage(index);
          }
          val.scrollController.itemCount = val.tabs.length;
          if (val.scrollController.hasClients &&
              val.scrollController.itemCount > index) {
            val.scrollController
                .scrollToItem(index, center: false, animate: true);
          }
        }));
      }
    });
    if ((isDesktop && (bind.isIncomingOnly() || bind.isOutgoingOnly())) ||
        callOnSelected) {
      if (state.value.tabs.length > index) {
        final key = state.value.tabs[index].key;
        onSelected?.call(key);
      }
    }
    return true;
  }

  bool jumpToByKey(String key, {bool callOnSelected = true}) =>
      jumpTo(state.value.tabs.indexWhere((tab) => tab.key == key),
          callOnSelected: callOnSelected);

  bool jumpToByKeyAndDisplay(String key, int display, {bool isCamera = false}) {
    for (int i = 0; i < state.value.tabs.length; i++) {
      final tab = state.value.tabs[i];
      if (tab.key == key) {
        final ffi = isCamera
            ? (tab.page as ViewCameraPage).ffi
            : (tab.page as RemotePage).ffi;
        if (ffi.ffiModel.pi.currentDisplay == display) {
          return jumpTo(i, callOnSelected: true);
        }
      }
    }
    return false;
  }

  void closeBy(String? key) {
    if (!isDesktop) return;
    assert(onRemoved != null);
    if (key == null) {
      if (state.value.selected < state.value.tabs.length) {
        remove(state.value.selected);
      }
    } else {
      final index = state.value.tabs.indexWhere((tab) => tab.key == key);
      remove(index);
    }
  }

  void clear() {
    state.value.tabs.clear();
    state.refresh();
  }

  Widget? widget(String key) {
    return state.value.tabs.firstWhereOrNull((tab) => tab.key == key)?.page;
  }
}

class TabThemeConf {
  double iconSize;

  TabThemeConf({required this.iconSize});
}

typedef TabBuilder = Widget Function(
    String key, Widget icon, Widget label, TabThemeConf themeConf);
typedef TabMenuBuilder = Widget Function(String key);
typedef LabelGetter = Rx<String> Function(String key);

/// [_lastClickTime], help to handle double click
int _lastClickTime = 0;

class DesktopTab extends StatefulWidget {
  final bool showLogo;
  final bool showTitle;
  final bool showMinimize;
  final bool showMaximize;
  final bool showClose;
  final Widget Function(Widget pageView)? pageViewBuilder;
  // Right click tab menu
  final TabMenuBuilder? tabMenuBuilder;
  final Widget? tail;
  final Future<bool> Function()? onWindowCloseButton;
  final TabBuilder? tabBuilder;
  final LabelGetter? labelGetter;
  final double? maxLabelWidth;

  /// Whether this window marks its current tab with the accent rule. Kept as a
  /// colour for the pages that already pass one, but the strip has one accent
  /// and picks it itself.
  final Color? selectedBorderColor;

  final DesktopTabController controller;

  final _scrollDebounce = Debouncer(delay: Duration(milliseconds: 50));

  final RxList<String> invisibleTabKeys = RxList.empty();

  DesktopTab({
    Key? key,
    required this.controller,
    this.showLogo = true,
    this.showTitle = false,
    this.showMinimize = true,
    this.showMaximize = true,
    this.showClose = true,
    this.pageViewBuilder,
    this.tabMenuBuilder,
    this.tail,
    this.onWindowCloseButton,
    this.tabBuilder,
    this.labelGetter,
    this.maxLabelWidth,
    this.selectedBorderColor,
  }) : super(key: key);

  static RxString tablabelGetter(String peerId) {
    final alias = bind.mainGetPeerOptionSync(id: peerId, key: 'alias');
    return RxString(getDesktopTabLabel(peerId, alias));
  }

  @override
  State<DesktopTab> createState() {
    return _DesktopTabState();
  }
}

// ignore: must_be_immutable
class _DesktopTabState extends State<DesktopTab>
    with MultiWindowListener, WindowListener {
  Timer? _macOSCheckRestoreTimer;
  int _macOSCheckRestoreCounter = 0;

  bool get showLogo => widget.showLogo;
  bool get showTitle => widget.showTitle;
  bool get showMinimize => widget.showMinimize;
  bool get showMaximize => widget.showMaximize;
  bool get showClose => widget.showClose;
  Widget Function(Widget pageView)? get pageViewBuilder =>
      widget.pageViewBuilder;
  TabMenuBuilder? get tabMenuBuilder => widget.tabMenuBuilder;
  Widget? get tail => widget.tail;
  Future<bool> Function()? get onWindowCloseButton =>
      widget.onWindowCloseButton;
  TabBuilder? get tabBuilder => widget.tabBuilder;
  LabelGetter? get labelGetter => widget.labelGetter;
  double? get maxLabelWidth => widget.maxLabelWidth;
  Color? get selectedBorderColor => widget.selectedBorderColor;
  DesktopTabController get controller => widget.controller;
  RxList<String> get invisibleTabKeys => widget.invisibleTabKeys;
  Debouncer get _scrollDebounce => widget._scrollDebounce;

  Rx<DesktopTabState> get state => controller.state;

  DesktopTabType get tabType => controller.tabType;
  bool get isMainWindow =>
      tabType == DesktopTabType.main ||
      tabType == DesktopTabType.cm ||
      tabType == DesktopTabType.install;

  _DesktopTabState() : super();

  static RxString tablabelGetter(String peerId) {
    final alias = bind.mainGetPeerOptionSync(id: peerId, key: 'alias');
    return RxString(getDesktopTabLabel(peerId, alias));
  }

  @override
  void initState() {
    super.initState();
    DesktopMultiWindow.addListener(this);
    windowManager.addListener(this);

    Future.delayed(Duration(milliseconds: 500), () {
      if (isMainWindow) {
        windowManager.isMaximized().then((maximized) {
          if (stateGlobal.isMaximized.value != maximized) {
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => setState(() => stateGlobal.setMaximized(maximized)));
          }
        });
      } else {
        final wc = WindowController.fromWindowId(kWindowId!);
        wc.isMaximized().then((maximized) {
          debugPrint("isMaximized $maximized");
          if (stateGlobal.isMaximized.value != maximized) {
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => setState(() => stateGlobal.setMaximized(maximized)));
          }
        });
      }
    });
  }

  @override
  void dispose() {
    DesktopMultiWindow.removeListener(this);
    windowManager.removeListener(this);
    _macOSCheckRestoreTimer?.cancel();
    super.dispose();
  }

  void _setMaximized(bool maximize) {
    stateGlobal.setMaximized(maximize);
    _saveFrame();
    setState(() {});
  }

  @override
  void onWindowFocus() {
    stateGlobal.isFocused.value = true;
  }

  @override
  void onWindowBlur() {
    stateGlobal.isFocused.value = false;
  }

  @override
  void onWindowMinimize() {
    stateGlobal.setMinimized(true);
    stateGlobal.setMaximized(false);
    super.onWindowMinimize();
  }

  @override
  void onWindowMaximize() {
    stateGlobal.setMinimized(false);
    _setMaximized(true);
    super.onWindowMaximize();
  }

  @override
  void onWindowUnmaximize() {
    stateGlobal.setMinimized(false);
    _setMaximized(false);
    super.onWindowUnmaximize();
  }

  _saveFrame({bool? flush}) async {
    try {
      if (tabType == DesktopTabType.main) {
        await saveWindowPosition(WindowType.Main, flush: flush);
      } else if (kWindowType != null && kWindowId != null) {
        await saveWindowPosition(kWindowType!,
            windowId: kWindowId, flush: flush);
      }
    } catch (e) {
      debugPrint('Error saving window position: $e');
    }
  }

  @override
  void onWindowMoved() {
    _saveFrame();
    super.onWindowMoved();
  }

  @override
  void onWindowResized() {
    _saveFrame();
    super.onWindowResized();
  }

  @override
  void onWindowClose() async {
    mainWindowClose() async => await windowManager.hide();
    notMainWindowClose(WindowController windowController) async {
      if (controller.length != 0) {
        debugPrint("close not empty multiwindow from taskbar");
        if (isWindows) {
          await windowController.show();
          await windowController.focus();
          final res = await onWindowCloseButton?.call() ?? true;
          if (!res) return;
        }
        controller.clear();
      }
      await windowController.hide();
      await labDeskWinManager
          .call(WindowType.Main, kWindowEventHide, {"id": kWindowId!});
    }

    macOSWindowClose(
      Future<bool> Function() checkFullscreen,
      Future<void> Function() closeFunc,
    ) async {
      _macOSCheckRestoreCounter = 0;
      _macOSCheckRestoreTimer =
          Timer.periodic(Duration(milliseconds: 30), (timer) async {
        _macOSCheckRestoreCounter++;
        if (!await checkFullscreen() || _macOSCheckRestoreCounter >= 30) {
          _macOSCheckRestoreTimer?.cancel();
          _macOSCheckRestoreTimer = null;
          Timer(Duration(milliseconds: 700), () async => await closeFunc());
        }
      });
    }

    await _saveFrame(flush: true);

    // hide window on close
    if (isMainWindow) {
      if (labDeskWinManager.getActiveWindows().contains(kMainWindowId)) {
        await labDeskWinManager.unregisterActiveWindow(kMainWindowId);
      }
      // macOS specific workaround, the window is not hiding when in fullscreen.
      if (isMacOS && await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
        await macOSWindowClose(
          () async => await windowManager.isFullScreen(),
          mainWindowClose,
        );
      } else {
        await mainWindowClose();
      }
    } else {
      // it's safe to hide the subwindow
      final controller = WindowController.fromWindowId(kWindowId!);
      if (isMacOS) {
        // onWindowClose() maybe called multiple times because of loopCloseWindow() in remote_tab_page.dart.
        // use ??=  to make sure the value is set on first call.

        if (await onWindowCloseButton?.call() ?? true) {
          if (await controller.isFullScreen()) {
            await controller.setFullscreen(false);
            stateGlobal.setFullscreen(false, procWnd: false);
            await macOSWindowClose(
              () async => await controller.isFullScreen(),
              () async => await notMainWindowClose(controller),
            );
          } else {
            await notMainWindowClose(controller);
          }
        }
      } else {
        await notMainWindowClose(controller);
      }
    }
    super.onWindowClose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Obx(() {
        if (stateGlobal.showTabBar.isTrue &&
            !(kUseCompatibleUiMode && isHideSingleItem())) {
          final showBottomDivider = _showTabBarBottomDivider(tabType);
          return SizedBox(
            height: _kTabBarHeight,
            // The strip is the window's title bar and wears the chrome plane,
            // one step off the content plane below it. That step is what
            // separates the two when there is no divider to do it.
            child: ColoredBox(
              color: TabSkin.barColor,
              child: Column(
                children: [
                  SizedBox(
                    height:
                        showBottomDivider ? _kTabBarHeight - 1 : _kTabBarHeight,
                    child: _buildBar(),
                  ),
                  if (showBottomDivider)
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: C.hairline,
                    ),
                ],
              ),
            ),
          );
        } else {
          return Offstage();
        }
      }),
      Expanded(
          child: pageViewBuilder != null
              ? pageViewBuilder!(_buildPageView())
              : _buildPageView())
    ]);
  }

  List<Widget> _tabWidgets = [];
  Widget _buildPageView() {
    final child = Container(
        child: Obx(() => PageView(
            controller: state.value.pageController,
            physics: NeverScrollableScrollPhysics(),
            children: () {
              if (DesktopTabType.cm == tabType) {
                // Fix when adding a new tab still showing closed tabs with the same peer id, which would happen after the DesktopTab was stateful.
                return state.value.tabs.map((tab) {
                  return tab.page;
                }).toList();
              }

              /// to-do refactor, separate connection state and UI state for remote session.
              /// [workaround] PageView children need an immutable list, after it has been passed into PageView
              final tabLen = state.value.tabs.length;
              if (tabLen == _tabWidgets.length) {
                return _tabWidgets;
              } else if (_tabWidgets.isNotEmpty &&
                  tabLen == _tabWidgets.length + 1) {
                /// On add. Use the previous list(pointer) to prevent item's state init twice.
                /// *[_tabWidgets.isNotEmpty] means TabsWindow(remote_tab_page or file_manager_tab_page) opened before, but was hidden. In this case, we have to reload, otherwise the child can't be built.
                _tabWidgets.add(state.value.tabs.last.page);
                return _tabWidgets;
              } else {
                /// On remove or change. Use new list(pointer) to reload list children so that items loading order is normal.
                /// the Widgets in list must enable [AutomaticKeepAliveClientMixin]
                final newList = state.value.tabs.map((v) => v.page).toList();
                _tabWidgets = newList;
                return newList;
              }
            }())));
    if (tabType == DesktopTabType.remoteScreen) {
      return Container(color: kColorCanvas, child: child);
    } else {
      return child;
    }
  }

  /// Check whether to show ListView
  ///
  /// Conditions:
  /// - hide single item when only has one item (home) on [DesktopTabPage].
  bool isHideSingleItem() {
    return state.value.tabs.length == 1 &&
        (controller.tabType == DesktopTabType.main ||
            controller.tabType == DesktopTabType.install);
  }

  Widget _buildBar() {
    final isIncomingHomePage = bind.isIncomingOnly() && isInHomePage();
    // Every tooltip the strip raises — a truncated machine name, a window
    // button — is the console's panel, not Material's grey lozenge.
    return TooltipTheme(
      data: toolbarTooltipTheme,
      child: Row(
      children: [
        Expanded(
            child: GestureDetector(
                // custom double tap handler
                onTap: !isIncomingHomePage && showMaximize
                    ? () {
                        final current = DateTime.now().millisecondsSinceEpoch;
                        final elapsed = current - _lastClickTime;
                        _lastClickTime = current;
                        if (elapsed < bind.getDoubleClickTime()) {
                          // onDoubleTap
                          toggleMaximize(isMainWindow)
                              .then((value) => stateGlobal.setMaximized(value));
                        }
                      }
                    : (isIncomingHomePage ? () {} : null), // Keep tap recognizer for Windows touch.
                onPanStart: (_) => startDragging(isMainWindow),
                onPanCancel: () {
                  // We want to disable dragging of the tab area in the tab bar.
                  // Disable dragging is needed because macOS handles dragging by default.
                  if (isMacOS) {
                    setMovable(isMainWindow, false);
                  }
                },
                onPanEnd: (_) {
                  if (isMacOS) {
                    setMovable(isMainWindow, false);
                  }
                },
                child: Row(
                  children: [
                    Offstage(
                        offstage: !isMacOS,
                        child: const SizedBox(
                          width: 78,
                        )),
                    Offstage(
                      offstage: kUseCompatibleUiMode || isMacOS,
                      child: Row(children: [
                        Offstage(
                          offstage: !showLogo,
                          child: loadIcon(16),
                        ),
                        Offstage(
                            offstage: !showTitle,
                            child: Text(
                              bind.mainGetAppNameSync(),
                              style: C.small(
                                  color: C.textMuted, w: FontWeight.w600),
                            ).marginOnly(left: 6))
                      ]).marginOnly(
                        left: 8,
                        right: 10,
                      ),
                    ),
                    Expanded(
                        child: Listener(
                            // handle mouse wheel
                            onPointerSignal: (e) {
                              if (e is PointerScrollEvent) {
                                final sc =
                                    controller.state.value.scrollController;
                                if (!sc.canScroll) return;
                                _scrollDebounce.call(() {
                                  double adjust = 2.5;
                                  sc.animateTo(
                                      sc.offset + e.scrollDelta.dy * adjust,
                                      duration: Duration(milliseconds: 200),
                                      curve: Curves.ease);
                                });
                              }
                            },
                            child: _ListView(
                              controller: controller,
                              invisibleTabKeys: invisibleTabKeys,
                              tabBuilder: tabBuilder,
                              tabMenuBuilder: tabMenuBuilder,
                              labelGetter: labelGetter,
                              maxLabelWidth: maxLabelWidth,
                              markSelected: selectedBorderColor != null,
                            ))),
                  ],
                ))),
        // hide simulated action buttons when we in compatible ui mode, because of reusing system title bar.
        WindowActionPanel(
          isMainWindow: isMainWindow,
          state: state,
          tabController: controller,
          invisibleTabKeys: invisibleTabKeys,
          tail: tail,
          showMinimize: showMinimize,
          showMaximize: showMaximize,
          showClose: showClose,
          onClose: onWindowCloseButton,
          labelGetter: labelGetter,
        ).paddingOnly(left: 10)
      ],
    ));
  }
}

class WindowActionPanel extends StatefulWidget {
  final bool isMainWindow;
  final Rx<DesktopTabState> state;
  final DesktopTabController tabController;

  final bool showMinimize;
  final bool showMaximize;
  final bool showClose;
  final Widget? tail;
  final Future<bool> Function()? onClose;

  final RxList<String> invisibleTabKeys;
  final LabelGetter? labelGetter;

  const WindowActionPanel(
      {Key? key,
      required this.isMainWindow,
      required this.state,
      required this.tabController,
      required this.invisibleTabKeys,
      this.tail,
      this.showMinimize = true,
      this.showMaximize = true,
      this.showClose = true,
      this.onClose,
      this.labelGetter})
      : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return WindowActionPanelState();
  }
}

class WindowActionPanelState extends State<WindowActionPanel> {
  bool showTabDowndown() {
    return widget.tabController.state.value.tabs.length > 1 &&
        (widget.tabController.tabType == DesktopTabType.remoteScreen ||
            widget.tabController.tabType == DesktopTabType.fileTransfer ||
            widget.tabController.tabType == DesktopTabType.viewCamera ||
            widget.tabController.tabType == DesktopTabType.portForward ||
            widget.tabController.tabType == DesktopTabType.cm);
  }

  List<String> existingInvisibleTab() {
    return widget.invisibleTabKeys
        .where((key) =>
            widget.tabController.state.value.tabs.any((tab) => tab.key == key))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Obx(() {
          if (showTabDowndown() && existingInvisibleTab().isNotEmpty) {
            return _TabDropDownButton(
                controller: widget.tabController,
                labelGetter: widget.labelGetter,
                tabkeys: existingInvisibleTab());
          } else {
            return Offstage();
          }
        }),
        if (widget.tail != null) widget.tail!,
        if (!kUseCompatibleUiMode)
          Row(
            children: [
              if (widget.showMinimize && !isMacOS)
                ActionIcon(
                  message: 'Minimize',
                  icon: IconFont.min,
                  onTap: () {
                    if (widget.isMainWindow) {
                      windowManager.minimize();
                    } else {
                      WindowController.fromWindowId(kWindowId!).minimize();
                    }
                  },
                  isClose: false,
                ),
              if (widget.showMaximize && !isMacOS)
                Obx(() => ActionIcon(
                      message: stateGlobal.isMaximized.isTrue
                          ? 'Restore'
                          : 'Maximize',
                      icon: stateGlobal.isMaximized.isTrue
                          ? IconFont.restore
                          : IconFont.max,
                      onTap: bind.isIncomingOnly() && isInHomePage()
                          ? null
                          : _toggleMaximize,
                      isClose: false,
                    )),
              if (widget.showClose && !isMacOS)
                ActionIcon(
                  message: 'Close',
                  icon: IconFont.close,
                  onTap: () async {
                    final res = await widget.onClose?.call() ?? true;
                    if (res) {
                      // hide for all window
                      // note: the main window can be restored by tray icon
                      Future.delayed(Duration.zero, () async {
                        if (widget.isMainWindow) {
                          await windowManager.close();
                        } else {
                          await WindowController.fromWindowId(kWindowId!)
                              .close();
                        }
                      });
                    }
                  },
                  isClose: true,
                )
            ],
          ),
      ],
    );
  }

  void _toggleMaximize() {
    toggleMaximize(widget.isMainWindow).then((maximize) {
      // update state for sub window, wc.unmaximize/maximize() will not invoke onWindowMaximize/Unmaximize
      stateGlobal.setMaximized(maximize);
    });
  }
}

void startDragging(bool isMainWindow) {
  if (isMainWindow) {
    windowManager.startDragging();
  } else {
    WindowController.fromWindowId(kWindowId!).startDragging();
  }
}

void setMovable(bool isMainWindow, bool movable) {
  if (isMainWindow) {
    windowManager.setMovable(movable);
  } else {
    WindowController.fromWindowId(kWindowId!).setMovable(movable);
  }
}

/// return true -> window will be maximize
/// return false -> window will be unmaximize
Future<bool> toggleMaximize(bool isMainWindow) async {
  if (isMainWindow) {
    if (await windowManager.isMaximized()) {
      windowManager.unmaximize();
      return false;
    } else {
      windowManager.maximize();
      return true;
    }
  } else {
    final wc = WindowController.fromWindowId(kWindowId!);
    if (await wc.isMaximized()) {
      wc.unmaximize();
      return false;
    } else {
      wc.maximize();
      return true;
    }
  }
}

Future<bool> closeConfirmDialog() async {
  var confirm = true;
  final res = await gFFI.dialogManager.show<bool>((setState, close, context) {
    submit() {
      String value = bool2option(kOptionEnableConfirmClosingTabs, confirm);
      bind.mainSetLocalOption(
          key: kOptionEnableConfirmClosingTabs, value: value);
      close(true);
    }

    return CustomAlertDialog(
      title: Row(children: [
        const LdIcon(LdIcons.alert, color: C.bad, size: 22),
        const SizedBox(width: 10),
        Text(translate("Warning")),
      ]),
      content: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate("Disconnect all devices?")),
            CheckboxListTile(
              contentPadding: const EdgeInsets.all(0),
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                translate("Confirm before closing multiple tabs"),
              ),
              value: confirm,
              onChanged: (v) {
                if (v == null) return;
                setState(() => confirm = v);
              },
            )
          ]),
      // confirm checkbox
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        dialogButton("OK", onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
  return res == true;
}

class _ListView extends StatelessWidget {
  final DesktopTabController controller;
  final RxList<String> invisibleTabKeys;

  final TabBuilder? tabBuilder;
  final TabMenuBuilder? tabMenuBuilder;
  final LabelGetter? labelGetter;
  final double? maxLabelWidth;
  final bool markSelected;

  Rx<DesktopTabState> get state => controller.state;

  _ListView({
    required this.controller,
    required this.invisibleTabKeys,
    this.tabBuilder,
    this.tabMenuBuilder,
    this.labelGetter,
    this.maxLabelWidth,
    this.markSelected = false,
  });

  /// Check whether to show ListView
  ///
  /// Conditions:
  /// - hide single item when only has one item (home) on [DesktopTabPage].
  bool isHideSingleItem() {
    return state.value.tabs.length == 1 &&
            controller.tabType == DesktopTabType.main ||
        controller.tabType == DesktopTabType.install;
  }

  onVisibilityChanged(VisibilityInfo info) {
    final key = (info.key as ValueKey).value;
    if (info.visibleFraction < 0.75) {
      if (!invisibleTabKeys.contains(key)) {
        invisibleTabKeys.add(key);
      }
      invisibleTabKeys.removeWhere((key) =>
          controller.state.value.tabs.where((e) => e.key == key).isEmpty);
    } else {
      invisibleTabKeys.remove(key);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() => ListView(
        controller: state.value.scrollController,
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        children: isHideSingleItem()
            ? List.empty()
            : state.value.tabs.asMap().entries.map((e) {
                final index = e.key;
                final tab = e.value;
                final label = labelGetter == null
                    ? Rx<String>(tab.label)
                    : labelGetter!(tab.label);
                final child = VisibilityDetector(
                  key: ValueKey(tab.key),
                  onVisibilityChanged: onVisibilityChanged,
                  child: _Tab(
                    key: ValueKey(tab.key),
                    index: index,
                    tabInfoKey: tab.key,
                    label: label,
                    tabType: controller.tabType,
                    selectedIcon: tab.selectedIcon,
                    unselectedIcon: tab.unselectedIcon,
                    closable: tab.closable,
                    selected: state.value.selected,
                    onClose: () {
                      if (tab.onTabCloseButton != null) {
                        tab.onTabCloseButton!();
                      } else {
                        controller.remove(index);
                      }
                    },
                    onTap: () {
                      controller.jumpTo(index);
                      tab.onTap?.call();
                    },
                    tabBuilder: tabBuilder,
                    tabMenuBuilder: tabMenuBuilder,
                    maxLabelWidth: maxLabelWidth,
                    markSelected: markSelected,
                    isLast: index == state.value.tabs.length - 1,
                  ),
                );
                return GestureDetector(
                  onPanStart: (e) {},
                  child: child,
                );
              }).toList()));
  }
}

class _Tab extends StatefulWidget {
  final int index;
  final String tabInfoKey;
  final Rx<String> label;
  final DesktopTabType tabType;
  final IconData? selectedIcon;
  final IconData? unselectedIcon;
  final bool closable;
  final int selected;
  final Function() onClose;
  final Function() onTap;
  final TabBuilder? tabBuilder;
  final TabMenuBuilder? tabMenuBuilder;
  final double? maxLabelWidth;
  final bool markSelected;

  /// A separator after the last tab has nothing to separate it from.
  final bool isLast;

  const _Tab({
    Key? key,
    required this.index,
    required this.tabInfoKey,
    required this.label,
    required this.tabType,
    this.selectedIcon,
    this.unselectedIcon,
    this.tabBuilder,
    this.tabMenuBuilder,
    required this.closable,
    required this.selected,
    required this.onClose,
    required this.onTap,
    this.maxLabelWidth,
    this.markSelected = false,
    this.isLast = false,
  }) : super(key: key);

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> with RestorationMixin {
  final RestorableBool restoreHover = RestorableBool(false);

  /// The tab reads as the machine first: its platform, then its name. What
  /// kind of session it is follows the name in the faint size, because inside
  /// one window it is the same on every tab.
  ///
  /// When nothing is on record about the machine's platform the kind of
  /// session leads instead, so the tab is never left without a glyph.
  Widget _buildTabContent(bool isSelected, bool isHover) {
    bool showIcon =
        widget.selectedIcon != null && widget.unselectedIcon != null;

    // Nothing is read about the machine for a tab that was not given a glyph
    // to begin with — the connection manager's tabs are keyed by client, not
    // by peer, and asking about them would answer about somebody else.
    final typeGlyph =
        showIcon ? _tabTypeGlyph(widget.tabType, widget.tabInfoKey) : null;
    final platformGlyph =
        showIcon ? _peerPlatformGlyph(widget.tabInfoKey) : null;
    final leadGlyph = platformGlyph ?? typeGlyph;
    final glyphColor = TabSkin.glyphColor(isSelected, isHover);

    final icon = leadGlyph == null
        ? const SizedBox.shrink()
        : LdIcon(leadGlyph, size: _kIconSize, color: glyphColor)
            .paddingOnly(right: TabSkin.glyphGap);
    final typeMark = platformGlyph == null || typeGlyph == null
        ? const SizedBox.shrink()
        : LdIcon(typeGlyph, size: TabSkin.typeGlyphSize, color: C.textFaint)
            .paddingOnly(left: TabSkin.typeGlyphGap);

    final labelWidget = Obx(() {
      return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.maxLabelWidth ?? 200),
          child: Tooltip(
            message:
                widget.tabType == DesktopTabType.main
                    ? ''
                    : widget.label.value == widget.tabInfoKey
                        ? widget.label.value
                        : '${widget.label.value}\n${widget.tabInfoKey}',
            child: Text(
              widget.tabType == DesktopTabType.main
                  ? translate(widget.label.value)
                  : widget.label.value,
              textAlign: TextAlign.center,
              style: TabSkin.labelStyle(isSelected, isHover),
              overflow: TextOverflow.ellipsis,
            ),
          ));
    });

    Widget getWidgetWithBuilder() {
      if (widget.tabBuilder == null) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            labelWidget,
          ],
        );
      } else {
        return widget.tabBuilder!(
          widget.tabInfoKey,
          icon,
          labelWidget,
          TabThemeConf(iconSize: _kIconSize),
        );
      }
    }

    return Listener(
      onPointerDown: (e) {
        if (e.kind != ui.PointerDeviceKind.mouse) {
          return;
        }
        if (e.buttons == 2) {
          if (widget.tabMenuBuilder != null) {
            showRightMenu(
              (cacel) {
                return widget.tabMenuBuilder!(widget.tabInfoKey);
              },
              target: e.position,
            );
          }
        }
      },
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        getWidgetWithBuilder(),
        typeMark,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isSelected = widget.index == widget.selected;
    bool showDivider = widget.index != widget.selected - 1 &&
        widget.index != widget.selected &&
        !widget.isLast;
    RxBool hover = restoreHover.value.obs;
    return Ink(
      child: InkWell(
        // The tab paints its own hover plane, on the console's ramp and with
        // the console's timing. Material's overlay on top of it would be a
        // second, paler answer to the same question.
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        onHover: (value) {
          hover.value = value;
          restoreHover.value = value;
        },
        onTap: () => widget.onTap(),
        child: Obx(() => TabSurface(
              // _kTabBarHeight also displays normally
              height: _showTabBarBottomDivider(widget.tabType)
                  ? _kTabBarHeight - 1
                  : _kTabBarHeight,
              selected: isSelected,
              hover: hover.value,
              showIndicator: widget.markSelected,
              showDivider: showDivider,
              close: TabCloseButton(
                visible: hover.value && widget.closable,
                onClose: () => widget.onClose(),
              ),
              child: _buildTabContent(isSelected, hover.value),
            )),
      ),
    );
  }

  @override
  String? get restorationId => "_Tab${widget.label.value}";

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(restoreHover, 'restoreHover');
  }
}

class ActionIcon extends StatefulWidget {
  final String? message;
  final IconData icon;
  final GestureTapCallback? onTap;
  final GestureTapDownCallback? onTapDown;
  final bool isClose;
  final double iconSize;
  final double boxSize;

  const ActionIcon(
      {Key? key,
      this.message,
      required this.icon,
      this.onTap,
      this.onTapDown,
      this.isClose = false,
      this.iconSize = _kActionIconSize,
      this.boxSize = _kTabBarHeight - 1})
      : super(key: key);

  @override
  State<ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<ActionIcon> {
  final hover = false.obs;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onTapDown != null;
    final glyph = _kLdGlyphs[widget.icon];
    // Big enough that a stroked glyph reads at this size, never so big that it
    // touches the edge of the pad the hover raises under it.
    final glyphSize = min(widget.iconSize + 2, widget.boxSize - 8);
    return Tooltip(
      message: widget.message != null ? translate(widget.message!) : "",
      waitDuration: const Duration(seconds: 1),
      child: InkWell(
        // The pad below is the hover state; Material's own would sit on top of
        // it in a colour from another product.
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        onHover: (value) => hover.value = value,
        onTap: widget.onTap,
        onTapDown: widget.onTapDown,
        child: Obx(
          () => WindowButtonSurface(
            hover: enabled && hover.value,
            boxSize: widget.boxSize,
            // Closing a window is destructive, so it takes the one colour that
            // means that — but only under the cursor. A red cross sitting in
            // every title bar is a warning about nothing.
            color: enabled ? C.textMuted : C.textFaint,
            hoverColor: widget.isClose ? C.bad : C.text,
            iconBuilder: (fg) => glyph == null
                ? Icon(widget.icon, color: fg, size: widget.iconSize)
                : LdIcon(glyph, size: glyphSize, color: fg),
          ),
        ),
      ),
    );
  }
}

class AddButton extends StatelessWidget {
  const AddButton({
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ActionIcon(
        message: 'New Connection',
        icon: IconFont.add,
        onTap: () => labDeskWinManager.call(
            WindowType.Main, kWindowMainWindowOnTop, ""),
        isClose: false);
  }
}

class _TabDropDownButton extends StatefulWidget {
  final DesktopTabController controller;
  final List<String> tabkeys;
  final LabelGetter? labelGetter;

  const _TabDropDownButton(
      {required this.controller, required this.tabkeys, this.labelGetter});

  @override
  State<_TabDropDownButton> createState() => _TabDropDownButtonState();
}

class _TabDropDownButtonState extends State<_TabDropDownButton> {
  var position = RelativeRect.fromLTRB(0, 0, 0, 0);

  @override
  Widget build(BuildContext context) {
    List<String> sortedKeys = widget.controller.state.value.tabs
        .where((e) => widget.tabkeys.contains(e.key))
        .map((e) => e.key)
        .toList();
    return ActionIcon(
      onTapDown: (details) {
        final x = details.globalPosition.dx;
        final y = details.globalPosition.dy;
        position = RelativeRect.fromLTRB(x, y, x, y);
      },
      icon: Icons.arrow_drop_down,
      onTap: () {
        showMenu(
          context: context,
          position: position,
          // The console's panel: its surface, its hairline, its radius. Left
          // to Material this fell out of the title bar as a tinted sheet.
          color: C.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 10,
          shape: RoundedRectangleBorder(
            borderRadius: C.rounded,
            side: const BorderSide(color: C.hairline),
          ),
          items: sortedKeys.map((e) {
            var label = e;
            final tabInfo = widget.controller.state.value.tabs
                .firstWhereOrNull((element) => element.key == e);
            if (tabInfo != null) {
              label = tabInfo.label;
            }
            if (widget.labelGetter != null) {
              label = widget.labelGetter!(e).value;
            }
            var index = widget.controller.state.value.tabs
                .indexWhere((t) => t.key == e);
            label = '${index + 1}. $label';
            final menuHover = false.obs;
            final btnHover = false.obs;
            return PopupMenuItem<String>(
              value: e,
              height: 32,
              onTap: () {
                widget.controller.jumpToByKey(e);
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
              child: MouseRegion(
                onHover: (event) => setState(() => menuHover.value = true),
                onExit: (event) => setState(() => menuHover.value = false),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                          child: Text(label,
                              overflow: TextOverflow.ellipsis,
                              style: C.body())),
                    ),
                    Obx(
                      () {
                        if (tabInfo?.onTabCloseButton != null &&
                            menuHover.value) {
                          return InkWell(
                              onTap: () {
                                tabInfo?.onTabCloseButton?.call();
                                if (Navigator.of(context).canPop()) {
                                  Navigator.of(context).pop();
                                }
                              },
                              child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  onHover: (event) =>
                                      setState(() => btnHover.value = true),
                                  onExit: (event) =>
                                      setState(() => btnHover.value = false),
                                  child: LdIcon(LdIcons.close,
                                      size: 14,
                                      color: btnHover.value
                                          ? C.bad
                                          : C.textFaint)));
                        } else {
                          return Offstage();
                        }
                      },
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

bool _showTabBarBottomDivider(DesktopTabType tabType) {
  return tabType == DesktopTabType.main || tabType == DesktopTabType.install;
}

class TabbarTheme extends ThemeExtension<TabbarTheme> {
  final Color? selectedTabIconColor;
  final Color? unSelectedTabIconColor;
  final Color? selectedTextColor;
  final Color? unSelectedTextColor;
  final Color? selectedIconColor;
  final Color? unSelectedIconColor;
  final Color? dividerColor;
  final Color? hoverColor;
  final Color? closeHoverColor;
  final Color? selectedTabBackgroundColor;

  const TabbarTheme(
      {required this.selectedTabIconColor,
      required this.unSelectedTabIconColor,
      required this.selectedTextColor,
      required this.unSelectedTextColor,
      required this.selectedIconColor,
      required this.unSelectedIconColor,
      required this.dividerColor,
      required this.hoverColor,
      required this.closeHoverColor,
      required this.selectedTabBackgroundColor});

  static const light = TabbarTheme(
      selectedTabIconColor: MyTheme.accent,
      unSelectedTabIconColor: Color.fromARGB(255, 162, 203, 241),
      selectedTextColor: Colors.black,
      unSelectedTextColor: Color.fromARGB(255, 112, 112, 112),
      selectedIconColor: Color.fromARGB(255, 26, 26, 26),
      unSelectedIconColor: Color.fromARGB(255, 96, 96, 96),
      dividerColor: Color.fromARGB(255, 238, 238, 238),
      hoverColor: Colors.white54,
      closeHoverColor: Colors.white,
      selectedTabBackgroundColor: Colors.white54);

  static const dark = TabbarTheme(
      selectedTabIconColor: MyTheme.accent,
      unSelectedTabIconColor: Color.fromARGB(255, 30, 65, 98),
      selectedTextColor: Colors.white,
      unSelectedTextColor: Color.fromARGB(255, 192, 192, 192),
      selectedIconColor: Color.fromARGB(255, 192, 192, 192),
      unSelectedIconColor: Color.fromARGB(255, 255, 255, 255),
      dividerColor: Color.fromARGB(255, 64, 64, 64),
      hoverColor: Colors.black26,
      closeHoverColor: Colors.black,
      selectedTabBackgroundColor: Colors.black26);

  @override
  ThemeExtension<TabbarTheme> copyWith({
    Color? selectedTabIconColor,
    Color? unSelectedTabIconColor,
    Color? selectedTextColor,
    Color? unSelectedTextColor,
    Color? selectedIconColor,
    Color? unSelectedIconColor,
    Color? dividerColor,
    Color? hoverColor,
    Color? closeHoverColor,
    Color? selectedTabBackgroundColor,
  }) {
    return TabbarTheme(
      selectedTabIconColor: selectedTabIconColor ?? this.selectedTabIconColor,
      unSelectedTabIconColor:
          unSelectedTabIconColor ?? this.unSelectedTabIconColor,
      selectedTextColor: selectedTextColor ?? this.selectedTextColor,
      unSelectedTextColor: unSelectedTextColor ?? this.unSelectedTextColor,
      selectedIconColor: selectedIconColor ?? this.selectedIconColor,
      unSelectedIconColor: unSelectedIconColor ?? this.unSelectedIconColor,
      dividerColor: dividerColor ?? this.dividerColor,
      hoverColor: hoverColor ?? this.hoverColor,
      closeHoverColor: closeHoverColor ?? this.closeHoverColor,
      selectedTabBackgroundColor:
          selectedTabBackgroundColor ?? this.selectedTabBackgroundColor,
    );
  }

  @override
  ThemeExtension<TabbarTheme> lerp(
      ThemeExtension<TabbarTheme>? other, double t) {
    if (other is! TabbarTheme) {
      return this;
    }
    return TabbarTheme(
      selectedTabIconColor:
          Color.lerp(selectedTabIconColor, other.selectedTabIconColor, t),
      unSelectedTabIconColor:
          Color.lerp(unSelectedTabIconColor, other.unSelectedTabIconColor, t),
      selectedTextColor:
          Color.lerp(selectedTextColor, other.selectedTextColor, t),
      unSelectedTextColor:
          Color.lerp(unSelectedTextColor, other.unSelectedTextColor, t),
      selectedIconColor:
          Color.lerp(selectedIconColor, other.selectedIconColor, t),
      unSelectedIconColor:
          Color.lerp(unSelectedIconColor, other.unSelectedIconColor, t),
      dividerColor: Color.lerp(dividerColor, other.dividerColor, t),
      hoverColor: Color.lerp(hoverColor, other.hoverColor, t),
      closeHoverColor: Color.lerp(closeHoverColor, other.closeHoverColor, t),
      selectedTabBackgroundColor: Color.lerp(
          selectedTabBackgroundColor, other.selectedTabBackgroundColor, t),
    );
  }

  static color(BuildContext context) {
    return Theme.of(context).extension<ColorThemeExtension>()!;
  }
}
