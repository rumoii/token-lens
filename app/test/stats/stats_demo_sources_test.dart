import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/tools.dart';
import 'package:token_lens_app/stats/sources_page.dart';

import 'demo_visual_support.dart';

void main() {
  final ledger = Platform.environment['D34_DEMO_LEDGER'];
  final output = Platform.environment['D34_SCREENSHOT_DIR'];
  if (ledger == null || ledger.isEmpty || output == null || output.isEmpty) {
    return;
  }
  testWidgets('D34C-A 合成账本来源页六张截图（只 load）', (tester) async {
    await captureDemoVisuals(
      tester,
      routes: [(name: 'sources', page: 'sources', query: '')],
      output: output,
      ledger: ledger,
      onReady: (tester, route, dark, width) async {
        final context = tester.element(find.byType(StatsSourcesPage));
        await tester.runAsync(() async {
          for (final tool in tools.values) {
            if (tool.logo != null) {
              await precacheImage(
                AssetImage('assets/tool-logos/${tool.logo}'),
                context,
              );
            }
          }
        });
        await tester.pumpAndSettle();
        expect(find.text('工具'), findsOneWidget);
        expect(find.text('立即同步'), findsOneWidget);
        expect(find.textContaining('这台电脑上找到 10 个'), findsOneWidget);
      },
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
