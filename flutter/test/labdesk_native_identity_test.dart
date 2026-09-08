import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.parent.path;
  String source(String path) =>
      File('$root/$path').readAsStringSync().replaceAll('\r\n', '\n');

  test('native executable and library have the installed LabDesk identity', () {
    final manifest = source('Cargo.toml');
    expect(manifest, contains('[package]\nname = "labdesk"'));
    expect(manifest, contains('default-run = "labdesk"'));
    expect(manifest, contains('[lib]\nname = "liblabdesk"'));
    expect(source('flutter/windows/CMakeLists.txt'),
        contains('set(BINARY_NAME "labdesk")'));
    expect(source('flutter/linux/CMakeLists.txt'),
        contains('set(BINARY_NAME "labdesk")'));
  });

  test('Windows loader requests existing LabDesk C exports', () {
    final loader = source('flutter/windows/runner/main.cpp');
    expect(loader, contains('LoadLibraryA("liblabdesk.dll")'));
    final exports = source('src/flutter.rs');
    final names = RegExp(r'GetProcAddress\(hInstance, "([^"]+)"\)')
        .allMatches(loader)
        .map((match) => match.group(1)!)
        .toList();
    expect(names, contains('labdesk_core_main_args'));
    for (final name in names) {
      expect(exports, contains('fn $name('), reason: 'Missing C export $name');
    }
  });

  test('Linux loader and native export agree on the owned library', () {
    final loader = source('flutter/linux/main.cc');
    expect(loader, contains('"liblabdesk.so"'));
    expect(loader, contains('"labdesk_core_main"'));
    expect(source('src/flutter.rs'), contains('fn labdesk_core_main('));
  });
}
