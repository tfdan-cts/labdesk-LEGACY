import 'dart:async';
import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/setting_widgets.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/peer_tab_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_hbb/labdesk/theme/console_theme.dart';
import 'package:flutter_hbb/labdesk/theme/dialog_skin.dart';
import 'package:flutter_hbb/labdesk/theme/ld_icons.dart';
import 'package:flutter_hbb/labdesk/theme/settings_skin.dart';
import 'package:flutter_hbb/utils/http_service.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'address_book.dart';

// ---------------------------------------------------------------------------
// The console's modals.
//
// Every dialog below used to be a Material `AlertDialog` with Material buttons,
// Material icons and LabDesk's accent, raised over three surfaces that have
// since been restyled — the console, the session windows, the connection
// manager. The presentation now comes from `labdesk/theme/dialog_skin.dart`, so
// they move together and so `tool/shots/dialogs_test.dart` can render them
// without a session behind them.
//
// Nothing here changes behaviour: the strings, the `translate` keys, the
// validation rules, the timeouts, the autofocus and the Escape/Enter contract
// are the ones that were here before.

/// [LdDialog] wearing the type the dialog manager insists on.
///
/// `OverlayDialogManager.show` is typed to return a `CustomAlertDialog`, and
/// that typedef lives in the app's shared `common.dart`. So the console's
/// dialog is handed over as one, with the Material `AlertDialog` its build
/// would have produced replaced outright. Nothing of the original survives
/// except the type name — the keyboard contract it carried is reimplemented in
/// [LdDialog] verbatim.
class _LdAlertDialog extends CustomAlertDialog {
  _LdAlertDialog({
    this.ldTitle,
    this.ldContent,
    this.ldActions,
    this.ldOnSubmit,
    this.ldOnCancel,
    this.ldWidth = DialogSkin.width,
  }) : super(content: const SizedBox.shrink());

  final Widget? ldTitle;
  final Widget? ldContent;
  final List<Widget>? ldActions;
  final VoidCallback? ldOnSubmit;
  final VoidCallback? ldOnCancel;
  final double ldWidth;

  @override
  Widget build(BuildContext context) => LdDialog(
        title: ldTitle,
        content: ldContent,
        actions: ldActions,
        onSubmit: ldOnSubmit,
        onCancel: ldOnCancel,
        width: ldWidth,
        // Mobile switches the platform soft keyboard off while a session is on
        // screen, so a dialog has to switch it back on to be answerable at all.
        onOpen: () {
          if (isAndroid) gFFI.invokeMethod("enable_soft_keyboard", true);
        },
      );
}

/// The console's modal, ready for `OverlayDialogManager.show`.
///
/// Public because `msgBox`, `msgBoxCommon` and `showFileConfirmDialog` raise
/// dialogs too and live in files this one does not own; they need one call, not
/// a copy of this.
CustomAlertDialog ldDialog({
  Widget? title,
  Widget? content,
  List<Widget>? actions,
  VoidCallback? onSubmit,
  VoidCallback? onCancel,
  double width = DialogSkin.width,
}) =>
    _LdAlertDialog(
      ldTitle: title,
      ldContent: content,
      ldActions: actions,
      ldOnSubmit: onSubmit,
      ldOnCancel: onCancel,
      ldWidth: width,
    );

/// One answer. Takes the untranslated key, exactly as `dialogButton` did.
Widget ldButton(
  String text, {
  required VoidCallback? onPressed,
  LdDialogTone tone = LdDialogTone.neutral,
  String? glyph,
  bool busy = false,
}) =>
    LdDialogButton(
      label: translate(text),
      onPressed: onPressed,
      tone: tone,
      glyph: glyph,
      busy: busy,
    );

/// The header of a dialog whose whole content is something the product has to
/// say — the same [LdDialogTitle] row every other dialog opens with, so a
/// message box is not the one modal in the product with no header.
///
/// The mark table and the translation rules live on [LdMsgboxContent] in
/// common.dart, because the raw `msgBox` path needs exactly the same two and a
/// second copy of them here is a second copy that drifts.
Widget? ldMessageTitle(String type, String title) =>
    LdMsgboxContent(type, title, '').header();

/// The body of a dialog whose whole content is something the product has to
/// say. Replaces `msgboxContent`. Pairs with [ldMessageTitle].
Widget ldMessage(String text, {String? detail}) => LdDialogMessage(
      text: ldMsgboxText(text),
      detail: detail,
      onLinkTap: (url) => launchUrl(Uri.parse(url)),
    );

void clientClose(SessionID sessionId, FFI ffi) async {
  if (allowAskForNoteAtEndOfConnection(ffi, true)) {
    if (await showConnEndAuditDialogCloseCanceled(ffi: ffi)) {
      return;
    }
    closeConnection();
  } else {
    msgBox(sessionId, 'info', 'Close', 'Are you sure to close the connection?',
        '', ffi.dialogManager);
  }
}

abstract class ValidationRule {
  String get name;
  bool validate(String value);
}

class LengthRangeValidationRule extends ValidationRule {
  final int _min;
  final int _max;

  LengthRangeValidationRule(this._min, this._max);

  @override
  String get name => translate('length %min% to %max%')
      .replaceAll('%min%', _min.toString())
      .replaceAll('%max%', _max.toString());

  @override
  bool validate(String value) {
    return value.length >= _min && value.length <= _max;
  }
}

class RegexValidationRule extends ValidationRule {
  final String _name;
  final RegExp _regex;

  RegexValidationRule(this._name, this._regex);

  @override
  String get name => translate(_name);

  @override
  bool validate(String value) {
    return value.isNotEmpty ? value.contains(_regex) : false;
  }
}

void changeIdDialog() {
  var newId = "";
  var msg = "";
  var isInProgress = false;
  TextEditingController controller = TextEditingController();
  final RxString rxId = controller.text.trim().obs;

  final rules = [
    RegexValidationRule('starts with a letter', RegExp(r'^[a-zA-Z]')),
    LengthRangeValidationRule(6, 16),
    RegexValidationRule('allowed characters', RegExp(r'^[\w-]*$'))
  ];

  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      debugPrint("onSubmit");
      newId = controller.text.trim();

      final Iterable violations = rules.where((r) => !r.validate(newId));
      if (violations.isNotEmpty) {
        setState(() {
          msg = (isDesktop || isWebDesktop)
              ? '${translate('Prompt')}:  ${violations.map((r) => r.name).join(', ')}'
              : violations.map((r) => r.name).join(', ');
        });
        return;
      }

      setState(() {
        msg = "";
        isInProgress = true;
        bind.mainChangeId(newId: newId);
      });

      var status = await bind.mainGetAsyncStatus();
      while (status == " ") {
        await Future.delayed(const Duration(milliseconds: 100));
        status = await bind.mainGetAsyncStatus();
      }
      if (status.isEmpty) {
        // ok
        close();
        return;
      }
      setState(() {
        isInProgress = false;
        msg = (isDesktop || isWebDesktop)
            ? '${translate('Prompt')}: ${translate(status)}'
            : translate(status);
      });
    }

    return ldDialog(
      title: LdDialogTitle(
          title: translate("Change ID"), glyph: LdIcons.machine),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(translate("id_change_tip"), style: C.body(color: C.textMuted)),
          const SizedBox(
            height: 16.0,
          ),
          LdDialogField(
            controller: controller,
            label: translate('Your new ID'),
            // An id is compared character by character against something
            // somebody else read out, so it is set in the data face.
            mono: true,
            errorText: msg.isEmpty ? null : translate(msg),
            suffixText: '${rxId.value.length}/16',
            inputFormatters: [
              LengthLimitingTextInputFormatter(16),
              // FilteringTextInputFormatter(RegExp(r"[a-zA-z][a-zA-z0-9\_]*"), allow: true)
            ],
            autofocus: true,
            onChanged: (value) {
              setState(() {
                rxId.value = value.trim();
                msg = '';
              });
            },
          ).workaroundFreezeLinuxMint(),
          // The rules, as a checklist rather than as a row of pink and green
          // lozenges. A rule that is not met yet is quiet: it is a thing still
          // to do, not an error the operator has already made.
          (isDesktop || isWebDesktop)
              ? Obx(() => Wrap(
                    runSpacing: 7,
                    spacing: 16,
                    children: rules.map((e) {
                      var checked = e.validate(rxId.value);
                      return Row(mainAxisSize: MainAxisSize.min, children: [
                        LdIcon(checked ? DialogGlyphs.check : LdIcons.minus,
                            size: 13, color: checked ? C.ok : C.textFaint),
                        const SizedBox(width: 6),
                        Text(e.name,
                            style: C.small(
                                color: checked ? C.ok : C.textMuted)),
                      ]);
                    }).toList(),
                  )).marginOnly(top: 14)
              : SizedBox.shrink(),
          // NOT use Offstage to wrap LinearProgressIndicator
          if (isInProgress) const LinearProgressIndicator().marginOnly(top: 16),
        ],
      ),
      actions: [
        ldButton("Cancel", onPressed: close, glyph: LdIcons.close),
        ldButton("OK",
            onPressed: submit,
            tone: LdDialogTone.primary,
            glyph: DialogGlyphs.check),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void changeWhiteList({Function()? callback}) async {
  final curWhiteList = await bind.mainGetOption(key: kOptionWhitelist);
  var newWhiteListField = curWhiteList == defaultOptionWhitelist
      ? ''
      : curWhiteList.split(',').join('\n');
  var controller = TextEditingController(text: newWhiteListField);
  var msg = "";
  var isInProgress = false;
  final isOptFixed = isOptionFixed(kOptionWhitelist);
  gFFI.dialogManager.show((setState, close, context) {
    return ldDialog(
      title: LdDialogTitle(
          title: translate("Allowed IPs"), glyph: LdIcons.shield),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(translate("whitelist_sep"), style: C.body(color: C.textMuted)),
          const SizedBox(
            height: 8.0,
          ),
          Text(translate("whitelist_cidr_tip"),
              style: C.body(color: C.textMuted)),
          const SizedBox(
            height: 16.0,
          ),
          LdDialogField(
            controller: controller,
            label: '',
            // A column of addresses. Monospaced so a stray digit in an octet
            // is visible, and tall enough to hold a real list.
            mono: true,
            maxLines: null,
            minLines: 4,
            errorText: msg.isEmpty ? null : translate(msg),
            enabled: !isOptFixed,
            autofocus: true,
          ).workaroundFreezeLinuxMint(),
          // NOT use Offstage to wrap LinearProgressIndicator
          if (isInProgress) const LinearProgressIndicator().marginOnly(top: 16),
        ],
      ),
      actions: [
        ldButton("Cancel", onPressed: close, glyph: LdIcons.close),
        if (!isOptFixed)
          ldButton("Clear", glyph: LdIcons.trash, onPressed: () async {
            await bind.mainSetOption(
                key: kOptionWhitelist, value: defaultOptionWhitelist);
            callback?.call();
            close();
          }),
        if (!isOptFixed)
          ldButton(
            "OK",
            tone: LdDialogTone.primary,
            glyph: DialogGlyphs.check,
            onPressed: () async {
              setState(() {
                msg = "";
                isInProgress = true;
              });
              newWhiteListField = controller.text.trim();
              var newWhiteList = "";
              if (newWhiteListField.isEmpty) {
                // pass
              } else {
                final ips =
                    newWhiteListField.trim().split(RegExp(r"[\s,;\n]+"));
                // test ip
                final ipMatch = RegExp(
                    r"^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)(\/([1-9]|[1-2][0-9]|3[0-2])){0,1}$");
                final ipv6Match = RegExp(
                    r"^(((?:[0-9A-Fa-f]{1,4}))*((?::[0-9A-Fa-f]{1,4}))*::((?:[0-9A-Fa-f]{1,4}))*((?::[0-9A-Fa-f]{1,4}))*|((?:[0-9A-Fa-f]{1,4}))((?::[0-9A-Fa-f]{1,4})){7})(\/([1-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])){0,1}$");
                for (final ip in ips) {
                  if (!ipMatch.hasMatch(ip) && !ipv6Match.hasMatch(ip)) {
                    msg = "${translate("Invalid IP")} $ip";
                    setState(() {
                      isInProgress = false;
                    });
                    return;
                  }
                }
                newWhiteList = ips.join(',');
              }
              if (newWhiteList.trim().isEmpty) {
                newWhiteList = defaultOptionWhitelist;
              }
              await bind.mainSetOption(
                  key: kOptionWhitelist, value: newWhiteList);
              callback?.call();
              close();
            },
          ),
      ],
      onCancel: close,
    );
  });
}

void changeIdWhiteList({Function()? callback}) async {
  final curIdWhiteList = await bind.mainGetOption(key: kOptionIdWhitelist);
  var newIdWhiteListField = curIdWhiteList == defaultOptionWhitelist
      ? ''
      : curIdWhiteList.split(',').join('\n');
  var controller = TextEditingController(text: newIdWhiteListField);
  var msg = "";
  var isInProgress = false;
  final isOptFixed = isOptionFixed(kOptionIdWhitelist);
  gFFI.dialogManager.show((setState, close, context) {
    return ldDialog(
      title: LdDialogTitle(
          title: translate("Allowed IDs"), glyph: LdIcons.shield),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(translate("whitelist_sep"), style: C.body(color: C.textMuted)),
          const SizedBox(
            height: 8.0,
          ),
          Text(translate("id_whitelist_wildcard_tip"),
              style: C.body(color: C.textMuted)),
          const SizedBox(
            height: 8.0,
          ),
          Text(translate("id_whitelist_caveat_tip"),
              style: C.body(color: C.textMuted)),
          const SizedBox(
            height: 16.0,
          ),
          LdDialogField(
            controller: controller,
            label: '',
            mono: true,
            maxLines: null,
            minLines: 4,
            errorText: msg.isEmpty ? null : translate(msg),
            enabled: !isOptFixed,
            autofocus: true,
          ).workaroundFreezeLinuxMint(),
          // NOT use Offstage to wrap LinearProgressIndicator
          if (isInProgress) const LinearProgressIndicator().marginOnly(top: 16),
        ],
      ),
      actions: [
        ldButton("Cancel", onPressed: close, glyph: LdIcons.close),
        if (!isOptFixed)
          ldButton("Clear", glyph: LdIcons.trash, onPressed: () async {
            await bind.mainSetOption(
                key: kOptionIdWhitelist, value: defaultOptionWhitelist);
            callback?.call();
            close();
          }),
        if (!isOptFixed)
          ldButton(
            "OK",
            tone: LdDialogTone.primary,
            glyph: DialogGlyphs.check,
            onPressed: () async {
              setState(() {
                msg = "";
                isInProgress = true;
              });
              newIdWhiteListField = controller.text.trim();
              var newIdWhiteList = "";
              if (newIdWhiteListField.isEmpty) {
                // pass
              } else {
                final ids = newIdWhiteListField
                    .trim()
                    .split(RegExp(r"[\s,;\n]+"))
                    .where((e) => e.isNotEmpty)
                    .toList();
                // Separators are handled above; allow all other Unicode characters.
                for (final id in ids) {
                  final hasControlCharacters = id.runes.any(
                      (char) => char <= 0x1f || (char >= 0x7f && char <= 0x9f));
                  if (hasControlCharacters) {
                    msg = "${translate("Invalid ID")} $id";
                    setState(() {
                      isInProgress = false;
                    });
                    return;
                  }
                }
                newIdWhiteList = ids.join(',');
              }
              if (newIdWhiteList.trim().isEmpty) {
                newIdWhiteList = defaultOptionWhitelist;
              }
              await bind.mainSetOption(
                  key: kOptionIdWhitelist, value: newIdWhiteList);
              callback?.call();
              close();
            },
          ),
      ],
      onCancel: close,
    );
  });
}

Future<String> changeDirectAccessPort(
    String currentIP, String currentPort) async {
  final controller = TextEditingController(text: currentPort);
  await gFFI.dialogManager.show((setState, close, context) {
    return ldDialog(
      width: DialogSkin.narrowWidth,
      title: LdDialogTitle(
          title: translate("Change Local Port"), glyph: LdIcons.portForward),
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // The address is not editable, so it is a statement beside the field
          // rather than a prefix inside it — a prefix the caret can never reach
          // reads as text somebody failed to select.
          Text('$currentIP :', style: C.data(size: 13, color: C.textMuted)),
          const SizedBox(width: 10),
          Expanded(
            child: LdDialogField(
              controller: controller,
              label: '',
              mono: true,
              maxLines: null,
              hintText: '21118',
              keyboardType: TextInputType.number,
              trailing: LdFieldButton(
                  glyph: LdIcons.close, onPressed: () => controller.clear()),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(
                    r'^([0-9]|[1-9]\d|[1-9]\d{2}|[1-9]\d{3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d{2}|655[0-2]\d|6553[0-5])$')),
              ],
              autofocus: true,
            ).workaroundFreezeLinuxMint(),
          ),
        ],
      ),
      actions: [
        ldButton("Cancel", onPressed: close, glyph: LdIcons.close),
        ldButton("OK",
            tone: LdDialogTone.primary,
            glyph: DialogGlyphs.check, onPressed: () async {
          await bind.mainSetOption(
              key: kOptionDirectAccessPort, value: controller.text);
          close();
        }),
      ],
      onCancel: close,
    );
  });
  return controller.text;
}

Future<String> changeAutoDisconnectTimeout(String old) async {
  final controller = TextEditingController(text: old);
  await gFFI.dialogManager.show((setState, close, context) {
    return ldDialog(
      width: DialogSkin.narrowWidth,
      title: LdDialogTitle(
          title: translate("Timeout in minutes"), glyph: LdIcons.recent),
      content: LdDialogField(
        controller: controller,
        label: '',
        mono: true,
        maxLines: null,
        hintText: '10',
        keyboardType: TextInputType.number,
        trailing: LdFieldButton(
            glyph: LdIcons.close, onPressed: () => controller.clear()),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(
              r'^([0-9]|[1-9]\d|[1-9]\d{2}|[1-9]\d{3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d{2}|655[0-2]\d|6553[0-5])$')),
        ],
        autofocus: true,
      ).workaroundFreezeLinuxMint(),
      actions: [
        ldButton("Cancel", onPressed: close, glyph: LdIcons.close),
        ldButton("OK",
            tone: LdDialogTone.primary,
            glyph: DialogGlyphs.check, onPressed: () async {
          await bind.mainSetOption(
              key: kOptionAutoDisconnectTimeout, value: controller.text);
          close();
        }),
      ],
      onCancel: close,
    );
  });
  return controller.text;
}

class DialogTextField extends StatelessWidget {
  final String title;
  final String? hintText;
  final bool obscureText;
  final String? errorText;
  final String? helperText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;

  static const kUsernameTitle = 'Username';
  static const kUsernameIcon =
      LdIcon(DialogGlyphs.user, size: 16, color: C.textFaint);
  static const kPasswordTitle = 'Password';
  static const kPasswordIcon =
      LdIcon(LdIcons.lock, size: 16, color: C.textFaint);

  DialogTextField(
      {Key? key,
      this.focusNode,
      this.obscureText = false,
      this.errorText,
      this.helperText,
      this.prefixIcon,
      this.suffixIcon,
      this.hintText,
      this.keyboardType,
      this.inputFormatters,
      this.maxLength,
      required this.title,
      required this.controller})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return LdDialogField(
      controller: controller,
      label: title,
      hintText: hintText,
      helperText: helperText,
      errorText: errorText,
      leading: prefixIcon,
      trailing: suffixIcon,
      focusNode: focusNode,
      autofocus: true,
      obscureText: obscureText,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      maxLength: maxLength,
    ).workaroundFreezeLinuxMint().paddingSymmetric(vertical: 6.0);
  }
}

abstract class ValidationField extends StatelessWidget {
  ValidationField({Key? key}) : super(key: key);

  String? validate();
  bool get isReady;
}

class Dialog2FaField extends ValidationField {
  Dialog2FaField({
    Key? key,
    required this.controller,
    this.autoFocus = true,
    this.reRequestFocus = false,
    this.title,
    this.hintText,
    this.errorText,
    this.readyCallback,
    this.onChanged,
  }) : super(key: key);

  final TextEditingController controller;
  final bool autoFocus;
  final bool reRequestFocus;
  final String? title;
  final String? hintText;
  final String? errorText;
  final VoidCallback? readyCallback;
  final VoidCallback? onChanged;
  final errMsg = translate('2FA code must be 6 digits.');

  @override
  Widget build(BuildContext context) {
    return DialogVerificationCodeField(
      title: title ?? translate('2FA code'),
      controller: controller,
      errorText: errorText,
      autoFocus: autoFocus,
      reRequestFocus: reRequestFocus,
      hintText: hintText,
      readyCallback: readyCallback,
      onChanged: _onChanged,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
      ],
    );
  }

  String get text => controller.text;
  bool get isAllDigits => text.codeUnits.every((e) => e >= 48 && e <= 57);

  @override
  bool get isReady => text.length == 6 && isAllDigits;

  @override
  String? validate() => isReady ? null : errMsg;

  _onChanged(StateSetter setState, SimpleWrapper<String?> errText) {
    onChanged?.call();

    if (text.length > 6) {
      setState(() => errText.value = errMsg);
      return;
    }

    if (!isAllDigits) {
      setState(() => errText.value = errMsg);
      return;
    }

    if (isReady) {
      readyCallback?.call();
      return;
    }

    if (errText.value != null) {
      setState(() => errText.value = null);
    }
  }
}

class DialogEmailCodeField extends ValidationField {
  DialogEmailCodeField({
    Key? key,
    required this.controller,
    this.autoFocus = true,
    this.reRequestFocus = false,
    this.hintText,
    this.errorText,
    this.readyCallback,
    this.onChanged,
  }) : super(key: key);

  final TextEditingController controller;
  final bool autoFocus;
  final bool reRequestFocus;
  final String? hintText;
  final String? errorText;
  final VoidCallback? readyCallback;
  final VoidCallback? onChanged;
  final errMsg = translate('Email verification code must be 6 characters.');

  @override
  Widget build(BuildContext context) {
    return DialogVerificationCodeField(
      title: translate('Verification code'),
      controller: controller,
      errorText: errorText,
      autoFocus: autoFocus,
      reRequestFocus: reRequestFocus,
      hintText: hintText,
      readyCallback: readyCallback,
      helperText: translate('verification_tip'),
      onChanged: _onChanged,
      keyboardType: TextInputType.visiblePassword,
    );
  }

  String get text => controller.text;

  @override
  bool get isReady => text.length == 6;

  @override
  String? validate() => isReady ? null : errMsg;

  _onChanged(StateSetter setState, SimpleWrapper<String?> errText) {
    onChanged?.call();

    if (text.length > 6) {
      setState(() => errText.value = errMsg);
      return;
    }

    if (isReady) {
      readyCallback?.call();
      return;
    }

    if (errText.value != null) {
      setState(() => errText.value = null);
    }
  }
}

class DialogVerificationCodeField extends StatefulWidget {
  DialogVerificationCodeField({
    Key? key,
    required this.controller,
    required this.title,
    this.autoFocus = true,
    this.reRequestFocus = false,
    this.helperText,
    this.hintText,
    this.errorText,
    this.textLength,
    this.readyCallback,
    this.onChanged,
    this.keyboardType,
    this.inputFormatters,
  }) : super(key: key);

  final TextEditingController controller;
  final bool autoFocus;
  final bool reRequestFocus;
  final String title;
  final String? helperText;
  final String? hintText;
  final String? errorText;
  final int? textLength;
  final VoidCallback? readyCallback;
  final Function(StateSetter setState, SimpleWrapper<String?> errText)?
      onChanged;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<DialogVerificationCodeField> createState() =>
      _DialogVerificationCodeField();
}

class _DialogVerificationCodeField extends State<DialogVerificationCodeField> {
  final _focusNode = FocusNode();
  Timer? _timer;
  Timer? _timerReRequestFocus;
  SimpleWrapper<String?> errorText = SimpleWrapper(null);
  String _preText = '';

  @override
  void initState() {
    super.initState();
    if (widget.autoFocus) {
      _timer =
          Timer(Duration(milliseconds: 50), () => _focusNode.requestFocus());

      if (widget.onChanged != null) {
        widget.controller.addListener(() {
          final text = widget.controller.text.trim();
          if (text == _preText) return;
          widget.onChanged!(setState, errorText);
          _preText = text;
        });
      }
    }

    // software secure keyboard will take the focus since flutter 3.13
    // request focus again when android account password obtain focus
    if (isAndroid && widget.reRequestFocus) {
      _focusNode.addListener(() {
        if (_focusNode.hasFocus) {
          _timerReRequestFocus?.cancel();
          _timerReRequestFocus = Timer(
              Duration(milliseconds: 100), () => _focusNode.requestFocus());
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timerReRequestFocus?.cancel();
    _focusNode.unfocus();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogTextField(
      title: widget.title,
      controller: widget.controller,
      errorText: widget.errorText ?? errorText.value,
      focusNode: _focusNode,
      helperText: widget.helperText,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
    );
  }
}

class PasswordWidget extends StatefulWidget {
  PasswordWidget({
    Key? key,
    required this.controller,
    this.autoFocus = true,
    this.reRequestFocus = false,
    this.hintText,
    this.errorText,
    this.title,
    this.maxLength,
  }) : super(key: key);

  final TextEditingController controller;
  final bool autoFocus;
  final bool reRequestFocus;
  final String? hintText;
  final String? errorText;
  final String? title;
  final int? maxLength;

  @override
  State<PasswordWidget> createState() => _PasswordWidgetState();
}

class _PasswordWidgetState extends State<PasswordWidget> {
  bool _passwordVisible = false;
  final _focusNode = FocusNode();
  Timer? _timer;
  Timer? _timerReRequestFocus;

  @override
  void initState() {
    super.initState();
    if (widget.autoFocus) {
      _timer =
          Timer(Duration(milliseconds: 50), () => _focusNode.requestFocus());
    }
    // software secure keyboard will take the focus since flutter 3.13
    // request focus again when android account password obtain focus
    if (isAndroid && widget.reRequestFocus) {
      _focusNode.addListener(() {
        if (_focusNode.hasFocus) {
          _timerReRequestFocus?.cancel();
          _timerReRequestFocus = Timer(
              Duration(milliseconds: 100), () => _focusNode.requestFocus());
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timerReRequestFocus?.cancel();
    _focusNode.unfocus();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogTextField(
      title: translate(widget.title ?? DialogTextField.kPasswordTitle),
      hintText: translate(widget.hintText ?? 'Enter your password'),
      controller: widget.controller,
      prefixIcon: DialogTextField.kPasswordIcon,
      suffixIcon: LdFieldButton(
        // Based on passwordVisible state choose the icon
        glyph: _passwordVisible ? DialogGlyphs.eye : LdIcons.privacy,
        active: _passwordVisible,
        onPressed: () {
          // Update the state i.e. toggle the state of passwordVisible variable
          setState(() {
            _passwordVisible = !_passwordVisible;
          });
        },
      ),
      obscureText: !_passwordVisible,
      errorText: widget.errorText,
      focusNode: _focusNode,
      maxLength: widget.maxLength,
    );
  }
}

void wrongPasswordDialog(SessionID sessionId,
    OverlayDialogManager dialogManager, type, title, text) {
  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    cancel() {
      close();
      closeConnection();
    }

    submit() {
      enterPasswordDialog(sessionId, dialogManager);
    }

    return ldDialog(
        title: ldMessageTitle(type, title),
        content: ldMessage(text),
        onSubmit: submit,
        onCancel: cancel,
        actions: [
          ldButton(
            'Cancel',
            glyph: LdIcons.close,
            onPressed: cancel,
          ),
          ldButton(
            'Retry',
            tone: LdDialogTone.primary,
            glyph: LdIcons.refresh,
            onPressed: submit,
          ),
        ]);
  });
}

void enterPasswordDialog(
    SessionID sessionId, OverlayDialogManager dialogManager) async {
  await _connectDialog(
    sessionId,
    dialogManager,
    passwordController: TextEditingController(),
  );
}

void enterUserLoginDialog(
    SessionID sessionId,
    OverlayDialogManager dialogManager,
    String osAccountDescTip,
    bool canRememberAccount) async {
  await _connectDialog(
    sessionId,
    dialogManager,
    osUsernameController: TextEditingController(),
    osPasswordController: TextEditingController(),
    osAccountDescTip: osAccountDescTip,
    canRememberAccount: canRememberAccount,
  );
}

void enterUserLoginAndPasswordDialog(
    SessionID sessionId,
    OverlayDialogManager dialogManager,
    String osAccountDescTip,
    bool canRememberAccount) async {
  await _connectDialog(
    sessionId,
    dialogManager,
    osUsernameController: TextEditingController(),
    osPasswordController: TextEditingController(),
    passwordController: TextEditingController(),
    osAccountDescTip: osAccountDescTip,
    canRememberAccount: canRememberAccount,
  );
}

_connectDialog(
  SessionID sessionId,
  OverlayDialogManager dialogManager, {
  TextEditingController? osUsernameController,
  TextEditingController? osPasswordController,
  TextEditingController? passwordController,
  String? osAccountDescTip,
  bool canRememberAccount = true,
}) async {
  final errUsername = ''.obs;
  var rememberPassword = false;
  if (passwordController != null) {
    rememberPassword =
        await bind.sessionGetRemember(sessionId: sessionId) ?? false;
  }
  var rememberAccount = false;
  if (canRememberAccount && osUsernameController != null) {
    rememberAccount =
        await bind.sessionGetRemember(sessionId: sessionId) ?? false;
  }
  if (osUsernameController != null) {
    osUsernameController.addListener(() {
      if (errUsername.value.isNotEmpty) {
        errUsername.value = '';
      }
    });
  }

  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    cancel() {
      close();
      closeConnection();
    }

    submit() {
      if (osUsernameController != null) {
        if (osUsernameController.text.trim().isEmpty) {
          errUsername.value = translate('Empty Username');
          setState(() {});
          return;
        }
      }
      final osUsername = osUsernameController?.text.trim() ?? '';
      final osPassword = osPasswordController?.text.trim() ?? '';
      final password = passwordController?.text.trim() ?? '';
      if (passwordController != null && password.isEmpty) return;
      if (rememberAccount) {
        bind.sessionPeerOption(
            sessionId: sessionId, name: 'os-username', value: osUsername);
        bind.sessionPeerOption(
            sessionId: sessionId, name: 'os-password', value: osPassword);
      }
      gFFI.login(
        osUsername,
        osPassword,
        sessionId,
        password,
        rememberPassword,
      );
      close();
      dialogManager.showLoading(translate('Logging in...'),
          onCancel: closeConnection);
    }

    // The sentence that says *which* password is being asked for. Under stress
    // this is the whole dialog: an operator who types the machine's password
    // into the account prompt has not misread a label, they were never given
    // one.
    descWidget(String text) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          maxLines: 3,
          softWrap: true,
          overflow: TextOverflow.ellipsis,
          style: C.body(color: C.textMuted),
        ),
      ).paddingOnly(bottom: 10);
    }

    rememberWidget(
      String desc,
      bool remember,
      ValueChanged<bool?>? onChanged,
    ) {
      return LdDialogCheck(
        label: desc,
        value: remember,
        onChanged: onChanged == null ? null : (v) => onChanged(v),
      ).paddingOnly(top: 4);
    }

    osAccountWidget() {
      if (osUsernameController == null || osPasswordController == null) {
        return Offstage();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (osAccountDescTip != null) descWidget(translate(osAccountDescTip)),
          DialogTextField(
            title: translate(DialogTextField.kUsernameTitle),
            controller: osUsernameController,
            prefixIcon: DialogTextField.kUsernameIcon,
            // The message belongs to the field it is about, not to the gap
            // underneath it.
            errorText: errUsername.value.isEmpty ? null : errUsername.value,
          ),
          PasswordWidget(
            controller: osPasswordController,
            autoFocus: false,
          ),
          if (canRememberAccount)
            rememberWidget(
              translate('remember_account_tip'),
              rememberAccount,
              (v) {
                if (v != null) {
                  setState(() => rememberAccount = v);
                }
              },
            ),
        ],
      );
    }

    passwdWidget() {
      if (passwordController == null) {
        return Offstage();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          descWidget(translate('verify_labdesk_password_tip')),
          PasswordWidget(
            controller: passwordController,
            autoFocus: osUsernameController == null,
          ),
          rememberWidget(
            translate('Remember password'),
            rememberPassword,
            (v) {
              if (v != null) {
                setState(() => rememberPassword = v);
              }
            },
          ),
        ],
      );
    }

    return ldDialog(
      title: LdDialogTitle(
        title: translate('Password Required'),
        glyph: LdIcons.lock,
      ),
      content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            osAccountWidget(),
            osUsernameController == null || passwordController == null
                ? Offstage()
                : Container(height: 18),
            passwdWidget(),
          ]),
      actions: [
        ldButton(
          'Cancel',
          glyph: LdIcons.close,
          onPressed: cancel,
        ),
        ldButton(
          'OK',
          tone: LdDialogTone.primary,
          glyph: DialogGlyphs.check,
          onPressed: submit,
        ),
      ],
      onSubmit: submit,
      onCancel: cancel,
    );
  });
}

void showWaitUacDialog(
    SessionID sessionId, OverlayDialogManager dialogManager, String type) {
  dialogManager.dismissAll();
  dialogManager.show(
      tag: '$sessionId-wait-uac',
      (setState, close, context) => ldDialog(
            title: ldMessageTitle(type, 'Wait'),
            content: ldMessage('wait_accept_uac_tip'),
            actions: [
              ldButton(
                'OK',
                tone: LdDialogTone.primary,
                glyph: DialogGlyphs.check,
                onPressed: close,
              ),
            ],
          ));
}

// Another username && password dialog?
void showRequestElevationDialog(
    SessionID sessionId, OverlayDialogManager dialogManager) {
  RxString groupValue = ''.obs;
  RxString errUser = ''.obs;
  RxString errPwd = ''.obs;
  TextEditingController userController = TextEditingController();
  TextEditingController pwdController = TextEditingController();

  void onRadioChanged(String? value) {
    if (value != null) {
      groupValue.value = value;
    }
  }

  // The two ways this can go, as a pair of choices rather than two Material
  // radios with their labels floating beside them. The explanation belongs to
  // the option it explains, so it sits inside the row.
  Widget OptionRequestPermissions = Obx(
    () => LdRadioRow(
      label: translate('Ask the remote user for authentication'),
      explain:
          translate('Choose this if the remote account is administrator'),
      selected: groupValue.value == '',
      onTap: () => onRadioChanged(''),
    ),
  );

  Widget OptionCredentials = Obx(
    () => LdRadioRow(
      label: translate('Transmit the username and password of administrator'),
      selected: groupValue.value == 'logon',
      onTap: () => onRadioChanged('logon'),
    ),
  );

  Widget UacNote = LdDialogNote(translate('still_click_uac_tip'));

  var content = Obx(
    () => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OptionRequestPermissions.marginOnly(bottom: 6),
        OptionCredentials,
        Offstage(
          offstage: 'logon' != groupValue.value,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              UacNote.marginOnly(bottom: 12),
              DialogTextField(
                controller: userController,
                title: translate('Username'),
                hintText: translate('elevation_username_tip'),
                prefixIcon: DialogTextField.kUsernameIcon,
                errorText: errUser.isEmpty ? null : errUser.value,
              ),
              PasswordWidget(
                controller: pwdController,
                autoFocus: false,
                errorText: errPwd.isEmpty ? null : errPwd.value,
              ),
            ],
          ).marginOnly(
              left: stateGlobal.isPortrait.isFalse ? SettingsSkin.indent : 0),
        ).marginOnly(top: 12),
      ],
    ),
  );

  dialogManager.dismissAll();
  dialogManager.show(tag: '$sessionId-request-elevation',
      (setState, close, context) {
    void submit() {
      if (groupValue.value == 'logon') {
        if (userController.text.isEmpty) {
          errUser.value = translate('Empty Username');
          return;
        }
        if (pwdController.text.isEmpty) {
          errPwd.value = translate('Empty Password');
          return;
        }
        bind.sessionElevateWithLogon(
            sessionId: sessionId,
            username: userController.text,
            password: pwdController.text);
      } else {
        bind.sessionElevateDirect(sessionId: sessionId);
      }
      close();
      showWaitUacDialog(sessionId, dialogManager, "wait-uac");
    }

    return ldDialog(
      title: LdDialogTitle(
          title: translate('Request Elevation'), glyph: LdIcons.shield),
      content: content,
      actions: [
        ldButton(
          'Cancel',
          glyph: LdIcons.close,
          onPressed: close,
        ),
        ldButton(
          'OK',
          tone: LdDialogTone.primary,
          glyph: DialogGlyphs.check,
          onPressed: submit,
        )
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void showOnBlockDialog(
  SessionID sessionId,
  String type,
  String title,
  String text,
  OverlayDialogManager dialogManager,
) {
  if (dialogManager.existing('$sessionId-wait-uac') ||
      dialogManager.existing('$sessionId-request-elevation')) {
    return;
  }
  dialogManager.show(tag: '$sessionId-$type', (setState, close, context) {
    void submit() {
      close();
      showRequestElevationDialog(sessionId, dialogManager);
    }

    return ldDialog(
      title: ldMessageTitle(type, title),
      content: ldMessage(
          "${translate(text)}${type.contains('uac') ? '\n' : '\n\n'}${translate('request_elevation_tip')}"),
      actions: [
        ldButton('Wait', glyph: DialogGlyphs.waiting, onPressed: close),
        ldButton('Request Elevation',
            tone: LdDialogTone.primary,
            glyph: LdIcons.shield,
            onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void showElevationError(SessionID sessionId, String type, String title,
    String text, OverlayDialogManager dialogManager) {
  dialogManager.show(tag: '$sessionId-$type', (setState, close, context) {
    void submit() {
      close();
      showRequestElevationDialog(sessionId, dialogManager);
    }

    return ldDialog(
      title: ldMessageTitle(type, title),
      content: ldMessage(text),
      actions: [
        ldButton('Cancel', glyph: LdIcons.close, onPressed: () {
          close();
        }),
        if (text != 'No permission')
          ldButton('Retry',
              tone: LdDialogTone.primary,
              glyph: LdIcons.refresh,
              onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void showWaitAcceptDialog(SessionID sessionId, String type, String title,
    String text, OverlayDialogManager dialogManager,
    {String peerId = ''}) {
  dialogManager.dismissAll();
  // The server sends this when it would not take a password at all: the
  // machine has no permanent password, or approves every session by hand. The
  // stock wording ("Prompt / please wait") over a black canvas read as a broken
  // window. Say what is being waited for and why, and name the machine.
  final alias = peerId.isEmpty
      ? ''
      : bind.mainGetPeerOptionSync(id: peerId, key: 'alias');
  final name = alias.isNotEmpty ? alias : (peerId.isEmpty ? 'the machine' : peerId);
  dialogManager.show((setState, close, context) {
    onCancel() {
      closeConnection();
    }

    return ldDialog(
      title: ldMessageTitle(type, 'Waiting for approval at $name'),
      content: ldMessage(
        'Someone at $name has to accept this session before anything shows here.',
        detail: '$name did not take a password: it has no permanent password '
            'set, or it approves every session by hand. To connect unattended, '
            'set a permanent password on that machine and save it here.',
      ),
      actions: [
        ldButton('Cancel', glyph: LdIcons.close, onPressed: onCancel),
      ],
      onCancel: onCancel,
    );
  });
}

void showRestartRemoteDevice(PeerInfo pi, String id, SessionID sessionId,
    OverlayDialogManager dialogManager) async {
  final res = await dialogManager
      .show<bool>((setState, close, context) => ldDialog(
            width: DialogSkin.narrowWidth,
            title: LdDialogTitle(
              title: translate("Restart remote device"),
              glyph: LdIcons.restart,
              tone: C.bad,
            ),
            // The machine is pulled out of the sentence and set in the data
            // face. It is the only thing in this dialog anybody checks, and the
            // question above it has never been the part that was misread.
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("${translate('Are you sure you want to restart')} ",
                    style: C.body(color: C.textMuted)),
                const SizedBox(height: 10),
                LdDialogIdentity("${pi.username}@${pi.hostname}($id) ?"),
              ],
            ),
            actions: [
              ldButton(
                "Cancel",
                glyph: LdIcons.close,
                onPressed: close,
              ),
              ldButton(
                "OK",
                tone: LdDialogTone.danger,
                glyph: LdIcons.restart,
                onPressed: () => close(true),
              ),
            ],
            onCancel: close,
            onSubmit: () => close(true),
          ));
  if (res == true) bind.sessionRestartRemoteDevice(sessionId: sessionId);
}

showSetOSPassword(
  SessionID sessionId,
  bool login,
  OverlayDialogManager dialogManager,
  String? osPassword,
  Function()? closeCallback,
) async {
  final controller = TextEditingController();
  osPassword ??=
      await bind.sessionGetOption(sessionId: sessionId, arg: 'os-password') ??
          '';
  var autoLogin =
      await bind.sessionGetOption(sessionId: sessionId, arg: 'auto-login') !=
          '';
  controller.text = osPassword;
  dialogManager.show((setState, close, context) {
    closeWithCallback([dynamic]) {
      close();
      if (closeCallback != null) closeCallback();
    }

    submit() {
      var text = controller.text.trim();
      bind.sessionPeerOption(
          sessionId: sessionId, name: 'os-password', value: text);
      bind.sessionPeerOption(
          sessionId: sessionId,
          name: 'auto-login',
          value: autoLogin ? 'Y' : '');
      if (text != '' && login) {
        bind.sessionInputOsPassword(sessionId: sessionId, value: text);
      }
      closeWithCallback();
    }

    return ldDialog(
      title: LdDialogTitle(
          title: translate('OS Password'), glyph: LdIcons.lock),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PasswordWidget(controller: controller),
          LdDialogCheck(
            label: translate('Auto Login'),
            value: autoLogin,
            onChanged: (v) {
              setState(() => autoLogin = v);
            },
          ).paddingOnly(top: 4),
        ],
      ),
      actions: [
        ldButton(
          "Cancel",
          glyph: LdIcons.close,
          onPressed: closeWithCallback,
        ),
        ldButton(
          "OK",
          tone: LdDialogTone.primary,
          glyph: DialogGlyphs.check,
          onPressed: submit,
        ),
      ],
      onSubmit: submit,
      onCancel: closeWithCallback,
    );
  });
}

showSetOSAccount(
  SessionID sessionId,
  OverlayDialogManager dialogManager,
) async {
  final usernameController = TextEditingController();
  final passwdController = TextEditingController();
  var username =
      await bind.sessionGetOption(sessionId: sessionId, arg: 'os-username') ??
          '';
  var password =
      await bind.sessionGetOption(sessionId: sessionId, arg: 'os-password') ??
          '';
  usernameController.text = username;
  passwdController.text = password;
  dialogManager.show((setState, close, context) {
    submit() {
      final username = usernameController.text.trim();
      final password = usernameController.text.trim();
      bind.sessionPeerOption(
          sessionId: sessionId, name: 'os-username', value: username);
      bind.sessionPeerOption(
          sessionId: sessionId, name: 'os-password', value: password);
      close();
    }

    descWidget(String text) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          maxLines: 3,
          softWrap: true,
          overflow: TextOverflow.ellipsis,
          style: C.body(color: C.textMuted),
        ),
      ).paddingOnly(bottom: 10);
    }

    return ldDialog(
      title: LdDialogTitle(
          title: translate('OS Account'), glyph: DialogGlyphs.user),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          descWidget(translate("os_account_desk_tip")),
          DialogTextField(
            title: translate(DialogTextField.kUsernameTitle),
            controller: usernameController,
            prefixIcon: DialogTextField.kUsernameIcon,
            errorText: null,
          ),
          PasswordWidget(controller: passwdController),
        ],
      ),
      actions: [
        ldButton(
          "Cancel",
          glyph: LdIcons.close,
          onPressed: close,
        ),
        ldButton(
          "OK",
          tone: LdDialogTone.primary,
          glyph: DialogGlyphs.check,
          onPressed: submit,
        ),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

Widget buildNoteTextField({
  required TextEditingController controller,
  required VoidCallback onEscape,
}) {
  final focusNode = FocusNode(
    onKey: (FocusNode node, RawKeyEvent evt) {
      if (evt.logicalKey.keyLabel == 'Enter') {
        if (evt is RawKeyDownEvent) {
          int pos = controller.selection.base.offset;
          controller.text =
              '${controller.text.substring(0, pos)}\n${controller.text.substring(pos)}';
          controller.selection =
              TextSelection.fromPosition(TextPosition(offset: pos + 1));
        }
        return KeyEventResult.handled;
      }
      if (evt.logicalKey.keyLabel == 'Esc') {
        if (evt is RawKeyDownEvent) {
          onEscape();
        }
        return KeyEventResult.handled;
      } else {
        return KeyEventResult.ignored;
      }
    },
  );

  return LdDialogField(
    controller: controller,
    label: '',
    autofocus: true,
    keyboardType: TextInputType.multiline,
    textInputAction: TextInputAction.newline,
    hintText: translate('input note here'),
    // Grows from five lines to eight and then scrolls inside itself. The
    // unbounded box this replaced only worked because a raw TextField was the
    // direct child of a fixed-height SizedBox; the field now carries its own
    // label and message, so it sizes itself instead.
    minLines: 5,
    maxLines: 8,
    maxLength: 256,
    showCounter: true,
    focusNode: focusNode,
  ).workaroundFreezeLinuxMint();
}

showAuditDialog(FFI ffi) async {
  final controller = TextEditingController(
      text: bind.sessionGetLastAuditNote(sessionId: ffi.sessionId));
  ffi.dialogManager.show((setState, close, context) {
    submit() {
      var text = controller.text;
      bind.sessionSendNote(sessionId: ffi.sessionId, note: text);
      close();
    }

    return ldDialog(
      title: LdDialogTitle(title: translate('Note'), glyph: LdIcons.rename),
      content: buildNoteTextField(
        controller: controller,
        onEscape: close,
      ),
      actions: [
        ldButton('Cancel', glyph: LdIcons.close, onPressed: close),
        ldButton('OK',
            tone: LdDialogTone.primary,
            glyph: DialogGlyphs.check,
            onPressed: submit)
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

bool allowAskForNoteAtEndOfConnection(FFI? ffi, bool closedByControlling) {
  if (ffi == null) {
    return false;
  }
  return mainGetLocalBoolOptionSync(kOptionAllowAskForNoteAtEndOfConnection) &&
      bind
          .sessionGetAuditServerSync(sessionId: ffi.sessionId, typ: "conn")
          .isNotEmpty &&
      bind.sessionGetAuditGuid(sessionId: ffi.sessionId).isNotEmpty &&
      bind.sessionGetLastAuditNote(sessionId: ffi.sessionId).isEmpty &&
      (!closedByControlling ||
          bind.willSessionCloseCloseSession(sessionId: ffi.sessionId));
}

// return value: close canceled
//  true: return
//  false: go on
Future<bool> desktopTryShowTabAuditDialogCloseCancelled(
    {required String id, required DesktopTabController tabController}) async {
  try {
    final page =
        tabController.state.value.tabs.firstWhere((tab) => tab.key == id).page;
    final ffi = (page as dynamic).ffi;
    final res = await showConnEndAuditDialogCloseCanceled(ffi: ffi);
    return res;
  } catch (e) {
    debugPrint('Failed to show audit dialog: $e');
    return false;
  }
}

// return value:
//  true: return
//  false: go on
Future<bool> showConnEndAuditDialogCloseCanceled(
    {required FFI ffi, String? type, String? title, String? text}) async {
  final res = await _showConnEndAuditDialogCloseCanceled(
      ffi: ffi, type: type, title: title, text: text);
  if (res == true) {
    return true;
  }
  return false;
}

// return value:
//  true: return
//  false / null: go on
Future<bool?> _showConnEndAuditDialogCloseCanceled({
  required FFI ffi,
  String? type,
  String? title,
  String? text,
}) async {
  final closedByControlling = type == null;
  final showDialog = allowAskForNoteAtEndOfConnection(ffi, closedByControlling);
  if (!showDialog) {
    return false;
  }
  ffi.dialogManager.dismissAll();

  Future<void> updateAuditNoteByGuid(String auditGuid, String note) async {
    debugPrint('Updating audit note for GUID: $auditGuid, note: $note');
    try {
      final apiServer = await bind.mainGetApiServer();
      if (apiServer.isEmpty) {
        debugPrint('API server is empty, cannot update audit note');
        return;
      }
      final url = '$apiServer/api/audit';
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode({
        'guid': auditGuid,
        'note': note,
      });

      final response = await http.put(
        Uri.parse(url),
        headers: headers,
        body: body,
      );

      if (response.statusCode == 200) {
        debugPrint('Successfully updated audit note for GUID: $auditGuid');
      } else {
        debugPrint(
            'Failed to update audit note. Status: ${response.statusCode}, Body: ${response.body}');
      }
    } catch (e) {
      debugPrint('Error updating audit note: $e');
    }
  }

  final controller = TextEditingController();
  bool askForNote =
      mainGetLocalBoolOptionSync(kOptionAllowAskForNoteAtEndOfConnection);
  final isOptFixed = isOptionFixed(kOptionAllowAskForNoteAtEndOfConnection);
  bool isInProgress = false;

  return await ffi.dialogManager.show<bool>((setState, close, context) {
    cancel() {
      close(true);
    }

    set() async {
      if (isInProgress) return;
      setState(() {
        isInProgress = true;
      });
      var text = controller.text;
      if (text.isNotEmpty) {
        await updateAuditNoteByGuid(
                bind.sessionGetAuditGuid(sessionId: ffi.sessionId), text)
            .timeout(const Duration(seconds: 6), onTimeout: () {
          debugPrint('updateAuditNoteByGuid timeout after 6s');
        });
      }
      // Save the "ask for note" preference
      if (!isOptFixed) {
        await mainSetLocalBoolOption(
            kOptionAllowAskForNoteAtEndOfConnection, askForNote);
      }
    }

    submit() async {
      await set();
      close(false);
    }

    // The answers are built in the order they were: the note is the point of
    // the dialog, so OK leads, and Cancel — which throws the note away — is
    // last and quiet.
    final buttons = [
      ldButton('OK',
          tone: LdDialogTone.primary,
          glyph: DialogGlyphs.check,
          busy: isInProgress,
          onPressed: isInProgress ? null : submit)
    ];
    if (type == 'relay-hint' || type == 'relay-hint2') {
      buttons.add(ldButton('Retry', glyph: LdIcons.refresh, onPressed: () async {
        await set();
        close(true);
        ffi.ffiModel.reconnect(ffi.dialogManager, ffi.sessionId, false);
      }));
      if (type == 'relay-hint2') {
        buttons.add(ldButton('Connect via relay', glyph: LdIcons.connect,
            onPressed: () async {
          await set();
          close(true);
          ffi.ffiModel.reconnect(ffi.dialogManager, ffi.sessionId, true);
        }));
      }
    }
    if (closedByControlling) {
      buttons.add(ldButton('Cancel',
          glyph: LdIcons.close, onPressed: isInProgress ? null : cancel));
    }

    final Widget? header;
    final Widget content;
    if (closedByControlling) {
      header = ldMessageTitle('info', 'Close');
      content = ldMessage('Are you sure to close the connection?');
    } else {
      header = ldMessageTitle(type, title ?? '');
      content = ldMessage(text ?? '');
    }

    return ldDialog(
      title: header,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          content,
          const SizedBox(height: 18),
          buildNoteTextField(
            controller: controller,
            onEscape: cancel,
          ),
          if (!isOptFixed) ...[
            const SizedBox(height: 10),
            LdDialogCheck(
              label: translate('note-at-conn-end-tip'),
              value: askForNote,
              onChanged: (value) {
                setState(() {
                  askForNote = value;
                });
              },
            ),
          ],
          if (isInProgress)
            const LinearProgressIndicator().marginOnly(top: 12),
        ],
      ),
      actions: buttons,
      onSubmit: submit,
      onCancel: cancel,
    );
  });
}

void showConfirmSwitchSidesDialog(
    SessionID sessionId, String id, OverlayDialogManager dialogManager) async {
  dialogManager.show((setState, close, context) {
    submit() async {
      await bind.sessionSwitchSides(sessionId: sessionId);
      closeConnection(id: id);
    }

    return ldDialog(
      title: ldMessageTitle('info', 'Switch Sides'),
      content: ldMessage('Please confirm if you want to share your desktop?'),
      actions: [
        ldButton('Cancel', glyph: LdIcons.close, onPressed: close),
        ldButton('OK',
            tone: LdDialogTone.primary,
            glyph: LdIcons.switchSides,
            onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

customImageQualityDialog(SessionID sessionId, String id, FFI ffi) async {
  double initQuality = kDefaultQuality;
  double initFps = kDefaultFps;
  bool qualitySet = false;
  bool fpsSet = false;

  bool? direct;
  try {
    direct =
        ConnectionTypeState.find(id).direct.value == ConnectionType.strDirect;
  } catch (_) {}
  bool hideFps = (await bind.mainIsUsingPublicServer() && direct != true) ||
      versionCmp(ffi.ffiModel.pi.version, '1.2.0') < 0;
  bool hideMoreQuality =
      (await bind.mainIsUsingPublicServer() && direct != true) ||
          versionCmp(ffi.ffiModel.pi.version, '1.2.2') < 0;

  setCustomValues({double? quality, double? fps}) async {
    debugPrint("setCustomValues quality:$quality, fps:$fps");
    if (quality != null) {
      qualitySet = true;
      await bind.sessionSetCustomImageQuality(
          sessionId: sessionId, value: quality.toInt());
    }
    if (fps != null) {
      fpsSet = true;
      await bind.sessionSetCustomFps(sessionId: sessionId, fps: fps.toInt());
    }
    if (!qualitySet) {
      qualitySet = true;
      await bind.sessionSetCustomImageQuality(
          sessionId: sessionId, value: initQuality.toInt());
    }
    if (!hideFps && !fpsSet) {
      fpsSet = true;
      await bind.sessionSetCustomFps(
          sessionId: sessionId, fps: initFps.toInt());
    }
  }

  final btnClose = dialogButton('Close', onPressed: () async {
    await setCustomValues();
    ffi.dialogManager.dismissAll();
  });

  // quality
  final quality = await bind.sessionGetCustomImageQuality(sessionId: sessionId);
  initQuality = quality != null && quality.isNotEmpty
      ? quality[0].toDouble()
      : kDefaultQuality;
  if (initQuality < kMinQuality ||
      initQuality > (!hideMoreQuality ? kMaxMoreQuality : kMaxQuality)) {
    initQuality = kDefaultQuality;
  }
  // fps
  final fpsOption =
      await bind.sessionGetOption(sessionId: sessionId, arg: 'custom-fps');
  initFps = fpsOption == null
      ? kDefaultFps
      : double.tryParse(fpsOption) ?? kDefaultFps;
  if (initFps < kMinFps || initFps > kMaxFps) {
    initFps = kDefaultFps;
  }

  final content = customImageQualityWidget(
      initQuality: initQuality,
      initFps: initFps,
      setQuality: (v) => setCustomValues(quality: v),
      setFps: (v) => setCustomValues(fps: v),
      showFps: !hideFps,
      showMoreQuality: !hideMoreQuality);
  msgBoxCommon(ffi.dialogManager, 'Custom Image Quality', content, [btnClose]);
}

trackpadSpeedDialog(SessionID sessionId, FFI ffi) async {
  int initSpeed = ffi.inputModel.trackpadSpeed;
  final curSpeed = SimpleWrapper(initSpeed);
  final btnClose = dialogButton('Close', onPressed: () async {
    if (curSpeed.value <= kMaxTrackpadSpeed &&
        curSpeed.value >= kMinTrackpadSpeed &&
        curSpeed.value != initSpeed) {
      await bind.sessionSetTrackpadSpeed(
          sessionId: sessionId, value: curSpeed.value);
      await ffi.inputModel.updateTrackpadSpeed();
    }
    ffi.dialogManager.dismissAll();
  });
  msgBoxCommon(
      ffi.dialogManager,
      'Trackpad speed',
      TrackpadSpeedWidget(
        value: curSpeed,
      ),
      [btnClose]);
}

void deleteConfirmDialog(Function onSubmit, String title) async {
  gFFI.dialogManager.show(
    (setState, close, context) {
      submit() async {
        await onSubmit();
        close();
      }

      return ldDialog(
        width: DialogSkin.narrowWidth,
        // The title is the whole dialog, so there is no body under it: an empty
        // content pane is twenty pixels of nothing between the question and the
        // answers.
        title: LdDialogTitle(
          title: title,
          glyph: LdIcons.trash,
          tone: C.bad,
        ),
        actions: [
          ldButton(
            "Cancel",
            glyph: LdIcons.close,
            onPressed: close,
          ),
          ldButton(
            "OK",
            tone: LdDialogTone.danger,
            glyph: LdIcons.trash,
            onPressed: submit,
          ),
        ],
        onSubmit: submit,
        onCancel: close,
      );
    },
  );
}

void editAbTagDialog(
    List<dynamic> currentTags, Function(List<dynamic>) onSubmit) {
  var isInProgress = false;

  final tags = List.of(gFFI.abModel.currentAbTags);
  var selectedTag = currentTags.obs;

  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      setState(() {
        isInProgress = true;
      });
      await onSubmit(selectedTag);
      close();
    }

    return ldDialog(
      title: LdDialogTitle(title: translate("Edit Tag"), glyph: LdIcons.group),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 2.0),
            child: Wrap(
              children: tags
                  .map((e) => AddressBookTag(
                      name: e,
                      tags: selectedTag,
                      onTap: () {
                        if (selectedTag.contains(e)) {
                          selectedTag.remove(e);
                        } else {
                          selectedTag.add(e);
                        }
                      },
                      showActionMenu: false))
                  .toList(growable: false),
            ),
          ),
          // NOT use Offstage to wrap LinearProgressIndicator
          if (isInProgress) const LinearProgressIndicator().marginOnly(top: 12),
        ],
      ),
      actions: [
        ldButton("Cancel", glyph: LdIcons.close, onPressed: close),
        ldButton("OK",
            tone: LdDialogTone.primary,
            glyph: DialogGlyphs.check,
            onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void editAbPeerNoteDialog(String id) {
  var isInProgress = false;
  final currentNote = gFFI.abModel.getPeerNote(id);
  var controller = TextEditingController(text: currentNote);

  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      setState(() {
        isInProgress = true;
      });
      await gFFI.abModel.changeNote(id: id, note: controller.text);
      close();
    }

    return ldDialog(
      title: LdDialogTitle(
          title: translate("Edit note"), glyph: LdIcons.rename),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          LdDialogField(
            controller: controller,
            label: translate('Note'),
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            maxLength: 300,
            showCounter: true,
          ).workaroundFreezeLinuxMint(),
          // NOT use Offstage to wrap LinearProgressIndicator
          if (isInProgress) const LinearProgressIndicator().marginOnly(top: 12),
        ],
      ),
      actions: [
        ldButton("Cancel", glyph: LdIcons.close, onPressed: close),
        ldButton("OK",
            tone: LdDialogTone.primary,
            glyph: DialogGlyphs.check,
            onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void renameDialog(
    {required String oldName,
    FormFieldValidator<String>? validator,
    required ValueChanged<String> onSubmit,
    Function? onCancel}) async {
  RxBool isInProgress = false.obs;
  var controller = TextEditingController(text: oldName);
  final formKey = GlobalKey<FormState>();
  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      String text = controller.text.trim();
      if (validator != null && formKey.currentState?.validate() == false) {
        return;
      }
      isInProgress.value = true;
      onSubmit(text);
      close();
      isInProgress.value = false;
    }

    cancel() {
      onCancel?.call();
      close();
    }

    return ldDialog(
      width: DialogSkin.narrowWidth,
      title: LdDialogTitle(
          title: translate('Rename'), glyph: LdIcons.rename),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Form(
            key: formKey,
            child: LdDialogField(
              controller: controller,
              label: translate('Name'),
              autofocus: true,
              validator: validator,
            ).workaroundFreezeLinuxMint(),
          ),
          // NOT use Offstage to wrap LinearProgressIndicator
          Obx(() => isInProgress.value
              ? const LinearProgressIndicator().marginOnly(top: 12)
              : Offstage())
        ],
      ),
      actions: [
        ldButton(
          "Cancel",
          glyph: LdIcons.close,
          onPressed: cancel,
        ),
        ldButton(
          "OK",
          tone: LdDialogTone.primary,
          glyph: DialogGlyphs.check,
          onPressed: submit,
        ),
      ],
      onSubmit: submit,
      onCancel: cancel,
    );
  });
}

void changeBot({Function()? callback}) async {
  if (bind.mainHasValidBotSync()) {
    await bind.mainSetOption(key: "bot", value: "");
    callback?.call();
    return;
  }
  String errorText = '';
  bool loading = false;
  final controller = TextEditingController();
  gFFI.dialogManager.show((setState, close, context) {
    onVerify() async {
      final token = controller.text.trim();
      if (token == "") return;
      loading = true;
      errorText = '';
      setState(() {});
      final error = await bind.mainVerifyBot(token: token);
      if (error == "") {
        callback?.call();
        close();
      } else {
        errorText = translate(error);
        loading = false;
        setState(() {});
      }
    }

    final codeField = LdDialogField(
      autofocus: true,
      controller: controller,
      label: '',
      // A bot token is a secret to be pasted and compared, not read.
      mono: true,
      hintText: translate('Token'),
      errorText: errorText == '' ? null : errorText,
    ).workaroundFreezeLinuxMint();

    return ldDialog(
      title: LdDialogTitle(
          title: translate("Telegram bot"), glyph: LdIcons.chat),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(translate("enable-bot-desc"),
                  style: C.small(color: C.textMuted))
              .marginOnly(bottom: 14),
          codeField,
        ],
      ),
      actions: [
        ldButton("Cancel", glyph: LdIcons.close, onPressed: close),
        ldButton("OK",
            tone: LdDialogTone.primary,
            glyph: DialogGlyphs.check,
            busy: loading,
            onPressed: loading ? null : onVerify),
      ],
      onCancel: close,
    );
  });
}

void change2fa({Function()? callback}) async {
  if (bind.mainHasValid2FaSync()) {
    await bind.mainSetOption(key: "2fa", value: "");
    await bind.mainClearTrustedDevices();
    callback?.call();
    return;
  }
  var new2fa = (await bind.mainGenerate2Fa());
  final secretRegex = RegExp(r'secret=([^&]+)');
  final secret = secretRegex.firstMatch(new2fa)?.group(1);
  String? errorText;
  final controller = TextEditingController();
  gFFI.dialogManager.show((setState, close, context) {
    onVerify() async {
      if (await bind.mainVerify2Fa(code: controller.text.trim())) {
        callback?.call();
        close();
      } else {
        errorText = translate('wrong-2fa-code');
      }
    }

    final codeField = Dialog2FaField(
      controller: controller,
      errorText: errorText,
      onChanged: () => setState(() => errorText = null),
      title: translate('Verification code'),
      readyCallback: () {
        onVerify();
        setState(() {});
      },
    );

    getOnSubmit() => codeField.isReady ? onVerify : null;

    return ldDialog(
      title: LdDialogTitle(
          title: translate("enable-2fa-title"), glyph: LdIcons.shield),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(translate("enable-2fa-desc"),
                  style: C.small(color: C.textMuted))
              .marginOnly(bottom: 16),
          // The code has to stay on white to be readable by a phone camera, so
          // it is matted rather than recoloured.
          Center(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: C.roundedSm,
              ),
              child: QrImageView(
                backgroundColor: Colors.white,
                data: new2fa,
                version: QrVersions.auto,
                size: 160,
                gapless: false,
              ),
            ),
          ).marginOnly(bottom: 12),
          // The same secret in text, for a machine with no camera pointed at
          // it. Set in the data face, because it is transcribed.
          if ((secret ?? '').isNotEmpty)
            LdDialogIdentity(secret!).marginOnly(bottom: 16),
          codeField,
        ],
      ),
      actions: [
        ldButton("Cancel", glyph: LdIcons.close, onPressed: close),
        ldButton("OK",
            tone: LdDialogTone.primary,
            glyph: DialogGlyphs.check,
            onPressed: getOnSubmit()),
      ],
      onCancel: close,
    );
  });
}

void enter2FaDialog(
    SessionID sessionId, OverlayDialogManager dialogManager) async {
  final controller = TextEditingController();
  final RxBool submitReady = false.obs;
  final RxBool trustThisDevice = false.obs;

  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    cancel() {
      close();
      closeConnection();
    }

    submit() {
      gFFI.send2FA(sessionId, controller.text.trim(), trustThisDevice.value);
      close();
      dialogManager.showLoading(translate('Logging in...'),
          onCancel: closeConnection);
    }

    late Dialog2FaField codeField;

    codeField = Dialog2FaField(
      controller: controller,
      title: translate('Verification code'),
      onChanged: () => submitReady.value = codeField.isReady,
    );

    final trustField = Obx(() => LdDialogCheck(
          label: translate("Trust this device"),
          value: trustThisDevice.value,
          onChanged: (value) {
            trustThisDevice.value = value;
          },
        ).paddingOnly(top: 6));

    return ldDialog(
        width: DialogSkin.narrowWidth,
        title: LdDialogTitle(
            title: translate('enter-2fa-title'), glyph: LdIcons.shield),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            codeField,
            if (bind.sessionGetEnableTrustedDevices(sessionId: sessionId))
              trustField,
          ],
        ),
        actions: [
          ldButton('Cancel', glyph: LdIcons.close, onPressed: cancel),
          Obx(() => ldButton(
                'OK',
                tone: LdDialogTone.primary,
                glyph: DialogGlyphs.check,
                onPressed: submitReady.isTrue ? submit : null,
              )),
        ],
        onSubmit: submit,
        onCancel: cancel);
  });
}

// This dialog should not be dismissed, otherwise it will be black screen, have not reproduced this.
void showWindowsSessionsDialog(
    String type,
    String title,
    String text,
    OverlayDialogManager dialogManager,
    SessionID sessionId,
    String peerId,
    String sessions) {
  List<dynamic> sessionsList = [];
  try {
    sessionsList = json.decode(sessions);
  } catch (e) {
    print(e);
  }
  List<String> sids = [];
  List<String> names = [];
  for (var session in sessionsList) {
    sids.add(session['sid']);
    names.add(session['name']);
  }
  String selectedUserValue = sids.first;
  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    submit() {
      bind.sessionSendSelectedSessionId(
          sessionId: sessionId, sid: selectedUserValue);
      close();
    }

    return ldDialog(
      title: ldMessageTitle(type, title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ldMessage(text).marginOnly(bottom: 18),
          // Which signed-in account on the far machine is about to be taken
          // over. The list is the decision, so it is drawn by the settings
          // select rather than by a Material combo.
          LdSelect(
            keys: sids,
            values: names,
            initialKey: selectedUserValue,
            width: double.infinity,
            onChanged: (value) {
              selectedUserValue = value;
            },
          ),
        ],
      ),
      actions: [
        ldButton('Connect',
            tone: LdDialogTone.primary,
            glyph: LdIcons.connect,
            onPressed: submit),
      ],
    );
  });
}

void addPeersToAbDialog(
  List<Peer> peers,
) async {
  Future<bool> addTo(String abname) async {
    final mapList = peers.map((e) {
      var json = e.toJson();
      // remove password when add to another address book to avoid re-share
      json.remove('password');
      json.remove('hash');
      return json;
    }).toList();
    final errMsg = await gFFI.abModel.addPeersTo(mapList, abname);
    if (errMsg == null) {
      showToast(translate('Successful'));
      return true;
    } else {
      BotToast.showText(text: errMsg, contentColor: Colors.red);
      return false;
    }
  }

  // if only one address book and it is personal, add to it directly
  if (gFFI.abModel.addressbooks.length == 1 &&
      gFFI.abModel.current.isPersonal()) {
    await addTo(gFFI.abModel.currentName.value);
    return;
  }

  RxBool isInProgress = false.obs;
  final names = gFFI.abModel.addressBooksCanWrite();
  RxString currentName = gFFI.abModel.currentName.value.obs;
  TextEditingController controller = TextEditingController();
  if (gFFI.peerTabModel.currentTab == PeerTabIndex.ab.index) {
    names.remove(currentName.value);
  }
  if (names.isEmpty) {
    debugPrint('no address book to add peers to, should not happen');
    return;
  }
  if (!names.contains(currentName.value)) {
    currentName.value = names[0];
  }
  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      if (controller.text != gFFI.abModel.translatedName(currentName.value)) {
        BotToast.showText(
            text: 'illegal address book name: ${controller.text}',
            contentColor: Colors.red);
        return;
      }
      isInProgress.value = true;
      if (await addTo(currentName.value)) {
        close();
      }
      isInProgress.value = false;
    }

    cancel() {
      close();
    }

    return ldDialog(
      width: DialogSkin.narrowWidth,
      title: LdDialogTitle(
        title: translate('Add to address book'),
        glyph: LdIcons.addressBook,
      ),
      content: Obx(() => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // https://github.com/flutter/flutter/issues/145081
              DropdownMenu(
                width: DialogSkin.narrowWidth - DialogSkin.pad * 2,
                initialSelection: currentName.value,
                onSelected: (value) {
                  if (value != null) {
                    currentName.value = value;
                  }
                },
                dropdownMenuEntries: names
                    .map((e) => DropdownMenuEntry(
                        value: e,
                        label: gFFI.abModel.translatedName(e),
                        style: MenuItemButton.styleFrom(
                            foregroundColor: C.text,
                            textStyle: C.body())))
                    .toList(),
                textStyle: C.body(),
                menuStyle: MenuStyle(
                  backgroundColor: const WidgetStatePropertyAll(C.surface),
                  surfaceTintColor:
                      const WidgetStatePropertyAll(Colors.transparent),
                  shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                    borderRadius: C.rounded,
                    side: const BorderSide(color: C.hairline),
                  )),
                ),
                inputDecorationTheme: InputDecorationTheme(
                  isDense: true,
                  filled: true,
                  fillColor: C.bg,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                      borderRadius: C.roundedSm,
                      borderSide: const BorderSide(color: C.hairline)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: C.roundedSm,
                      borderSide: const BorderSide(color: C.hairline)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: C.roundedSm,
                      borderSide: const BorderSide(color: C.accent)),
                ),
                enableFilter: true,
                controller: controller,
              ),
              // NOT use Offstage to wrap LinearProgressIndicator
              isInProgress.value
                  ? const LinearProgressIndicator().marginOnly(top: 12)
                  : Offstage()
            ],
          )),
      actions: [
        ldButton(
          "Cancel",
          glyph: LdIcons.close,
          onPressed: cancel,
        ),
        ldButton(
          "OK",
          tone: LdDialogTone.primary,
          glyph: DialogGlyphs.check,
          onPressed: submit,
        ),
      ],
      onSubmit: submit,
      onCancel: cancel,
    );
  });
}

void setSharedAbPasswordDialog(String abName, Peer peer) {
  TextEditingController controller = TextEditingController(text: '');
  RxBool isInProgress = false.obs;
  RxBool isInputEmpty = true.obs;
  bool passwordVisible = false;
  controller.addListener(() {
    isInputEmpty.value = controller.text.isEmpty;
  });
  gFFI.dialogManager.show((setState, close, context) {
    change(String password) async {
      isInProgress.value = true;
      bool res =
          await gFFI.abModel.changeSharedPassword(abName, peer.id, password);
      isInProgress.value = false;
      if (res) {
        showToast(translate('Successful'));
      }
      close();
    }

    cancel() {
      close();
    }

    return ldDialog(
      title: LdDialogTitle(
        title: translate(peer.password.isEmpty
            ? 'Set shared password'
            : 'Change Password'),
        glyph: LdIcons.key,
      ),
      content: Obx(() => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                LdDialogField(
                  controller: controller,
                  label: translate(DialogTextField.kPasswordTitle),
                  glyph: LdIcons.lock,
                  autofocus: true,
                  obscureText: !passwordVisible,
                  trailing: LdFieldButton(
                    glyph:
                        passwordVisible ? DialogGlyphs.eye : LdIcons.privacy,
                    active: passwordVisible,
                    onPressed: () {
                      setState(() {
                        passwordVisible = !passwordVisible;
                      });
                    },
                  ),
                ).workaroundFreezeLinuxMint(),
                // Everyone the book is shared with will be able to use this
                // password, which is a consequence that belongs on the screen
                // rather than in a footnote.
                if (!gFFI.abModel.current.isPersonal())
                  LdDialogNote(translate('share_warning_tip'), tone: C.bad)
                      .marginOnly(top: 12),
                // NOT use Offstage to wrap LinearProgressIndicator
                isInProgress.value
                    ? const LinearProgressIndicator().marginOnly(top: 12)
                    : Offstage()
              ])),
      actions: [
        ldButton(
          "Cancel",
          glyph: LdIcons.close,
          onPressed: cancel,
        ),
        if (peer.password.isNotEmpty)
          ldButton(
            "Remove",
            tone: LdDialogTone.danger,
            glyph: LdIcons.trash,
            onPressed: () => change(''),
          ),
        Obx(() => ldButton(
              "OK",
              tone: LdDialogTone.primary,
              glyph: DialogGlyphs.check,
              onPressed:
                  isInputEmpty.value ? null : () => change(controller.text),
            )),
      ],
      onSubmit: isInputEmpty.value ? null : () => change(controller.text),
      onCancel: cancel,
    );
  });
}

/// The bare confirmation.
///
/// Every caller of this is taking something away — turning two-factor off,
/// dropping the bot, deleting trusted devices — so the answer is drawn as
/// destructive rather than as an ordinary OK. It is checked at each call site
/// rather than assumed: `desktop_setting_page.dart`, `settings_page.dart` and
/// `confrimDeleteTrustedDevicesDialog` are the only ones.
void CommonConfirmDialog(OverlayDialogManager dialogManager, String content,
    VoidCallback onConfirm) {
  dialogManager.show((setState, close, context) {
    submit() {
      close();
      onConfirm.call();
    }

    return ldDialog(
      width: DialogSkin.narrowWidth,
      content: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 12, top: 1),
            child: LdIcon(LdIcons.alert, size: 19, color: C.bad),
          ),
          Expanded(
            child: Text(content, style: C.h2(), textAlign: TextAlign.start),
          ),
        ],
      ),
      actions: [
        ldButton(translate("Cancel"), glyph: LdIcons.close, onPressed: close),
        ldButton(translate("OK"),
            tone: LdDialogTone.danger,
            glyph: DialogGlyphs.check,
            onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void changeUnlockPinDialog(String oldPin, Function() callback) {
  final pinController = TextEditingController(text: oldPin);
  final confirmController = TextEditingController(text: oldPin);
  String? pinErrorText;
  String? confirmationErrorText;
  final maxLength = bind.mainMaxEncryptLen();
  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      pinErrorText = null;
      confirmationErrorText = null;
      final pin = pinController.text.trim();
      final confirm = confirmController.text.trim();
      if (pin != confirm) {
        setState(() {
          confirmationErrorText =
              translate('The confirmation is not identical.');
        });
        return;
      }
      final errorMsg = bind.mainSetUnlockPin(pin: pin);
      if (errorMsg != '') {
        setState(() {
          pinErrorText = translate(errorMsg);
        });
        return;
      }
      callback.call();
      close();
    }

    return ldDialog(
      width: DialogSkin.narrowWidth,
      title: LdDialogTitle(title: translate("Set PIN"), glyph: LdIcons.lock),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          DialogTextField(
            title: 'PIN',
            controller: pinController,
            obscureText: true,
            errorText: pinErrorText,
            maxLength: maxLength,
          ),
          DialogTextField(
            title: translate('Confirmation'),
            controller: confirmController,
            obscureText: true,
            errorText: confirmationErrorText,
            maxLength: maxLength,
          )
        ],
      ),
      actions: [
        ldButton(translate("Cancel"), glyph: LdIcons.close, onPressed: close),
        ldButton(translate("OK"),
            tone: LdDialogTone.primary,
            glyph: DialogGlyphs.check,
            onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void checkUnlockPinDialog(String correctPin, Function() passCallback) {
  final controller = TextEditingController();
  String? errorText;
  gFFI.dialogManager.show((setState, close, context) {
    submit() async {
      final pin = controller.text.trim();
      if (correctPin != pin) {
        setState(() {
          errorText = translate('Wrong PIN');
        });
        return;
      }
      passCallback.call();
      close();
    }

    return ldDialog(
      width: DialogSkin.narrowWidth,
      // The same literal the field beside it uses, and for the same reason: it
      // is not a `translate` key anywhere in the product, and this is a reskin.
      title: const LdDialogTitle(title: 'PIN', glyph: LdIcons.lock),
      content: PasswordWidget(
        title: 'PIN',
        controller: controller,
        errorText: errorText,
        hintText: '',
      ),
      actions: [
        ldButton(translate("Cancel"), glyph: LdIcons.close, onPressed: close),
        ldButton(translate("OK"),
            tone: LdDialogTone.primary,
            glyph: DialogGlyphs.check,
            onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

void confrimDeleteTrustedDevicesDialog(
    RxList<TrustedDevice> trustedDevices, RxList<Uint8List> selectedDevices) {
  CommonConfirmDialog(gFFI.dialogManager, '${translate('Confirm Delete')}?',
      () async {
    if (selectedDevices.isEmpty) return;
    if (selectedDevices.length == trustedDevices.length) {
      await bind.mainClearTrustedDevices();
      trustedDevices.clear();
      selectedDevices.clear();
    } else {
      final json = jsonEncode(selectedDevices.map((e) => e.toList()).toList());
      await bind.mainRemoveTrustedDevices(json: json);
      trustedDevices.removeWhere((element) {
        return selectedDevices.contains(element.hwid);
      });
      selectedDevices.clear();
    }
  });
}

void manageTrustedDeviceDialog() async {
  RxList<TrustedDevice> trustedDevices = (await TrustedDevice.get()).obs;
  RxList<Uint8List> selectedDevices = RxList.empty();
  gFFI.dialogManager.show((setState, close, context) {
    return ldDialog(
      width: 560,
      title: LdDialogTitle(
          title: translate("Manage trusted devices"), glyph: LdIcons.shield),
      content: trustedDevicesTable(trustedDevices, selectedDevices),
      actions: [
        Obx(() => ldButton(translate("Delete"),
            tone: LdDialogTone.danger,
            glyph: LdIcons.trash,
            onPressed: selectedDevices.isEmpty
                ? null
                : () {
                    confrimDeleteTrustedDevicesDialog(
                      trustedDevices,
                      selectedDevices,
                    );
                  })),
        ldButton(translate("Close"), glyph: LdIcons.close, onPressed: close),
      ],
      onCancel: close,
    );
  });
}

class TrustedDevice {
  late final Uint8List hwid;
  late final int time;
  late final String id;
  late final String name;
  late final String platform;

  TrustedDevice.fromJson(Map<String, dynamic> json) {
    final hwidList = json['hwid'] as List<dynamic>;
    hwid = Uint8List.fromList(hwidList.cast<int>());
    time = json['time'];
    id = json['id'];
    name = json['name'];
    platform = json['platform'];
  }

  String daysRemaining() {
    final expiry = time + 90 * 24 * 60 * 60 * 1000;
    final remaining = expiry - DateTime.now().millisecondsSinceEpoch;
    if (remaining < 0) {
      return '0';
    }
    return (remaining / (24 * 60 * 60 * 1000)).toStringAsFixed(0);
  }

  static Future<List<TrustedDevice>> get() async {
    final List<TrustedDevice> devices = List.empty(growable: true);
    try {
      final devicesJson = await bind.mainGetTrustedDevices();
      if (devicesJson.isNotEmpty) {
        final devicesList = json.decode(devicesJson);
        if (devicesList is List) {
          for (var device in devicesList) {
            devices.add(TrustedDevice.fromJson(device));
          }
        }
      }
    } catch (e) {
      print(e.toString());
    }
    devices.sort((a, b) => b.time.compareTo(a.time));
    return devices;
  }
}

Widget trustedDevicesTable(
    RxList<TrustedDevice> devices, RxList<Uint8List> selectedDevices) {
  RxBool selectAll = false.obs;
  setSelectAll() {
    if (selectedDevices.isNotEmpty &&
        selectedDevices.length == devices.length) {
      selectAll.value = true;
    } else {
      selectAll.value = false;
    }
  }

  devices.listen((_) {
    setSelectAll();
  });
  selectedDevices.listen((_) {
    setSelectAll();
  });
  // A column head is a label, and an id, a platform and a count of days are
  // measured values — so the heads are set as labels and the cells in the data
  // face, the same way the peer table and the file listing set theirs.
  Widget head(String label) => Text(translate(label).toUpperCase(),
      style: C.micro(color: C.textFaint).copyWith(letterSpacing: 0.8));
  Widget cell(String value) =>
      Text(value, style: C.data(size: 12, color: C.text));
  Widget tick(bool value, ValueChanged<bool> onChanged) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => onChanged(!value),
          behavior: HitTestBehavior.opaque,
          child: LdCheckMark(value: value),
        ),
      );

  // Scrolled rather than scaled: the FittedBox this replaced shrank the whole
  // table to fit, so a machine with a long hostname made every other row
  // unreadable too.
  return SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Obx(() => DataTable(
        headingRowHeight: 34,
        dataRowMinHeight: 38,
        dataRowMaxHeight: 38,
        horizontalMargin: 0,
        columnSpacing: 22,
        dividerThickness: 1,
        headingRowColor: const WidgetStatePropertyAll(C.chrome),
        dataRowColor: const WidgetStatePropertyAll(Colors.transparent),
        columns: [
          DataColumn(
              label: tick(selectAll.value, (value) {
            if (value) {
              selectedDevices.clear();
              selectedDevices.addAll(devices.map((e) => e.hwid));
            } else {
              selectedDevices.clear();
            }
          })),
          DataColumn(label: head('Platform')),
          DataColumn(label: head('ID')),
          DataColumn(label: head('Username')),
          DataColumn(label: head('Days remaining')),
        ],
        rows: devices.map((device) {
          return DataRow(cells: [
            DataCell(tick(selectedDevices.contains(device.hwid), (value) {
              if (value) {
                selectedDevices.remove(device.hwid);
                selectedDevices.add(device.hwid);
              } else {
                selectedDevices.remove(device.hwid);
              }
            })),
            DataCell(cell(device.platform)),
            DataCell(cell(device.id)),
            DataCell(Text(device.name, style: C.body())),
            DataCell(cell(device.daysRemaining())),
          ]);
        }).toList(),
      )),
  );
}
