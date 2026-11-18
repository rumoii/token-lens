import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Flutter package and Rust health report the same release version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final cargo = File('rust/Cargo.toml').readAsStringSync();
    final ui = RegExp(
      r'^version:\s*([^\s#]+)',
      multiLine: true,
    ).firstMatch(pubspec)![1]!.split('+').first;
    final package = RegExp(
      r'^\[package\]\s*\n([\s\S]*?)(?=^\[|$(?![\s\S]))',
      multiLine: true,
    ).firstMatch(cargo)![1]!;
    final core = RegExp(
      r'^version\s*=\s*"([^"]+)"',
      multiLine: true,
    ).firstMatch(package)![1];
    expect(
      core,
      ui,
      reason:
          'pubspec.yaml version $ui must match rust/Cargo.toml package version $core',
    );
  });
}
