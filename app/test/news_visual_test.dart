import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

import 'stats/demo_visual_support.dart';
import 'support/fake_news_gateway.dart';

void main() {
  for (final (width, dark) in [
    (1440.0, false),
    (700.0, false),
    (1440.0, true),
  ]) {
    final name = '${width.toInt()}${dark ? '-dark' : ''}';
    testWidgets('multi-source layout at $name', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final output = Platform.environment['D2E_SCREENSHOT_DIR'];
      if (output != null) await loadSystemFonts(tester);
      final gateway = FakeNewsGateway(cached: multiNews);
      final controller = NewsController(gateway);
      addTearDown(controller.dispose);
      await controller.load();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: LensPalette(dark).theme,
            home: NewsPage(controller: controller, openLink: (_) async => true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('OpenAI 模型更新'), findsOneWidget);
      expect(find.text('另有 1 个来源'), findsOneWidget);
      expect(find.byTooltip('也见于 Hacker News'), findsOneWidget);
      expect(find.byKey(const Key('hot-card')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(controller.snapshot.sources.length, 16);
      if (output != null) {
        await capture(tester, boundary, '$output/D26D-$name.png');
      }
      if (width == 1440) {
        await tester.tap(find.byKey(const Key('news-filter')));
        await tester.pumpAndSettle();
        // Six item kinds plus the fourteen enabled sources.
        expect(
          find.byWidgetPredicate(
            (w) => w is LensMenuRow && w.entry.checked != null,
          ),
          findsNWidgets(20),
        );
        if (output != null) {
          await capture(tester, boundary, '$output/D26D-$name-filter.png');
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('manage-sources')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source-status-panel')), findsOneWidget);
      if (output != null) {
        await capture(tester, boundary, '$output/D26D-$name-sources.png');
      }
      await tester.ensureVisible(find.byKey(const Key('source-row-hn-ai')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('source-row-hn-ai')));
      await tester.pumpAndSettle();
      expect(find.textContaining('来源暂时限制请求'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
