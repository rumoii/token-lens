import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/main.dart';
import 'package:token_lens_app/app_shell.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/stats/stats_page.dart';

void main() {
  testWidgets('main 给新闻、AppShell、StatsPage 传入同一个外链函数', (tester) async {
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.resolveSymbolicLinks();
      for (final key in [
        'TOKEN_LENS_PREVIEW_DATA_DIR',
        'TOKEN_LENS_PREVIEW_HOME',
      ]) {
        final path = Platform.environment[key];
        expect(
          path,
          isNotNull,
          reason: '$key must name an isolated TEMP directory',
        );
        final resolved = await Directory(path!).resolveSymbolicLinks();
        expect(
          resolved.startsWith('$temp${Platform.pathSeparator}'),
          true,
          reason: '$key must stay inside TEMP',
        );
      }
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(const TokenLensApp());
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (find.byType(AppShell).evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      expect(find.byType(AppShell), findsOneWidget);
      final shell = tester.widget<AppShell>(find.byType(AppShell));
      final stats = tester.widget<StatsPage>(find.byType(StatsPage));
      expect(shell.openLink, isNotNull);
      expect(shell.openLink, same((shell.news as NewsPage).openLink));
      expect(stats.openLink, same(shell.openLink));
      // Unmount before draining the native work; no external link is opened.
      await tester.pumpWidget(const SizedBox());
      await Future.wait([
        shell.statsController!.shutdown(),
        (shell.news as NewsPage).controller.shutdown(),
      ]).timeout(const Duration(seconds: 10));
    });
  });
}
