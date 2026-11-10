import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'demo_visual_support.dart';

void main() {
  testWidgets('空账本支持从没有 ledger.db 的 TEMP 目录开始并生成六种截图', (tester) async {
    final empty = await createDemoVisualData(tester);
    expect(
      await tester.runAsync(
        () => File('${empty.data.path}/ledger.db').exists(),
      ),
      false,
    );
    expect(await tester.runAsync(() => empty.logs.list().isEmpty), true);
    final output = '${empty.data.path}/shots';
    var frames = 0;
    await captureDemoVisuals(
      tester,
      routes: [(name: 'empty', page: 'home', query: '')],
      output: output,
      onReady: (tester, route, dark, width) {
        frames++;
        expect(find.text('欢迎使用 Token Lens'), findsOneWidget);
        expect(find.text('在这台电脑上找到 0 个工具'), findsOneWidget);
      },
    );
    expect(frames, 6);
    final names = await tester.runAsync(
      () async =>
          Directory(output).list().map((f) => f.uri.pathSegments.last).toList(),
    );
    expect(
      names,
      unorderedEquals([
        for (final scheme in ['light', 'dark'])
          for (final width in [1440, 1024, 720]) 'empty-$scheme-$width.png',
      ]),
    );
  });
}
