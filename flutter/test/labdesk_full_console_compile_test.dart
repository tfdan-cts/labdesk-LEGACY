import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/console_page.dart';
import 'package:flutter_hbb/generated_bridge.dart';

void main() {
  test('complete console and native Dart bridge compile together', () {
    expect(const LabDeskConsolePage(), isA<StatefulWidget>());
    expect(LabDesk, isNotNull);
  });
}
