import 'dart:async';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'settings_pricing_test.dart';

class DiagnosticsSettingsGateway extends SettingsGateway {
  DiagnosticsSettingsGateway() : super([]);
  final directories = <String>[];
  final logged = <String>[];
  String? exportError;
  Completer<String>? pending;
  @override
  Future<String> exportDiagnostics(String directory) async {
    directories.add(directory);
    if (exportError != null) throw StateError(exportError!);
    return pending?.future ??
        '$directory/token-lens-diagnostics-20261116-120000.txt';
  }

  @override
  Future<void> logError(String type, String message, String stack) async {
    logged.add('$type $message $stack');
  }
}

void main() {
  testWidgets('诊断说明、点击导出、保存位置与打开文件夹', (t) async {
    final g = DiagnosticsSettingsGateway();
    final opened = <Uri>[];
    final downloads = Directory(
      Platform.isWindows ? r'C:\Synthetic\Downloads' : '/synthetic/Downloads',
    );
    await showSettings(
      t,
      g,
      downloadsDirectory: () async => downloads,
      openLink: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    expect(find.text('诊断与关于'), findsOneWidget);
    expect(find.textContaining('不包含：账本、任何对话内容。用户目录会显示成 ~。'), findsOneWidget);
    expect(g.directories, isEmpty);
    await t.ensureVisible(find.text('导出诊断日志'));
    await t.tap(find.text('导出诊断日志'));
    await t.pumpAndSettle();
    expect(g.directories, [downloads.path]);
    expect(
      find.textContaining('token-lens-diagnostics-20261116-120000.txt'),
      findsOneWidget,
    );
    await t.ensureVisible(find.text('打开所在文件夹'));
    await t.tap(find.text('打开所在文件夹'));
    await t.pumpAndSettle();
    expect(opened.single.scheme, 'file');
    expect(opened.single, Uri.directory(downloads.path));
    expect(t.takeException(), isNull);
  });

  testWidgets('下载目录不可用则退回 exports，导出失败显示并写日志', (t) async {
    final g = DiagnosticsSettingsGateway()
      ..exportError = 'synthetic write denied';
    await showSettings(t, g, width: 720, downloadsDirectory: () async => null);
    await t.ensureVisible(find.text('导出诊断日志'));
    await t.tap(find.text('导出诊断日志'));
    await t.pumpAndSettle();
    expect(g.directories.single, endsWith('exports'));
    expect(find.textContaining('synthetic write denied'), findsOneWidget);
    expect(g.logged.single, contains('synthetic write denied'));
    expect(t.takeException(), isNull);
  });
}
