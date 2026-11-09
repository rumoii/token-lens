import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/app_shell.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/smooth_wheel.dart';
import 'package:token_lens_app/stats/home_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';

import 'stats/fake_gateway.dart';
import 'support/fake_news_gateway.dart';

void main() {
  for (final width in [999.0, 1000.0]) {
    testWidgets('one sidebar and news layout threshold at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = FakeNewsGateway(cached: cachedNews);
      final newsController = NewsController(gateway);
      final statsController = StatsController(
        FakeStatsGateway(),
        clock: () => demoNow,
      );
      addTearDown(newsController.dispose);
      addTearDown(statsController.dispose);
      await statsController.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: const LensPalette(false).theme,
          home: AppShell(
            statsController: statsController,
            news: NewsPage(
              controller: newsController,
              openLink: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(StatsHome), findsOneWidget);
      await tester.tap(find.text('AI 热点'));
      await tester.pumpAndSettle();
      expect(find.text('Token Lens'), findsOneWidget);
      expect(find.text('工作台'), findsNothing);
      expect(find.text('AI 热点'), findsNWidgets(2));
      expect(find.byKey(const Key('stats-scroll')), findsNothing);
      expect(find.text('Cached article'), findsOneWidget);
      final sourcePanel = tester.getTopLeft(find.text('来源状态'));
      final feed = tester.getTopLeft(find.byKey(const Key('news-list')));
      if (width == 1000) {
        expect(
          sourcePanel.dx,
          greaterThan(tester.getRect(find.byKey(const Key('news-list'))).right),
        );
      } else {
        expect(sourcePanel.dy, greaterThan(feed.dy));
      }
      final scroll = find.descendant(
        of: find.byType(NewsPage),
        matching: find.byType(SingleChildScrollView),
      );
      expect(
        tester.widget<SingleChildScrollView>(scroll).controller,
        isA<SmoothWheelController>(),
      );
      expect(gateway.refreshCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('statistics failure keeps an error banner and usable news', (
    tester,
  ) async {
    final gateway = FakeNewsGateway(cached: cachedNews);
    final controller = NewsController(gateway);
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    const error = '无法打开统计账本，请检查预览目录是否可读写。';
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          statsInitializationError: error,
          news: NewsPage(
            controller: controller,
            openLink: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(error), findsOneWidget);
    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(find.text('AI 热点'), findsOneWidget);
    expect(find.text('Cached article'), findsOneWidget);
    expect(gateway.refreshCalls, 0);
    expect(
      tester.getBottomLeft(find.byType(MaterialBanner)).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(NewsPage)).dy),
    );
    await tester.ensureVisible(find.text('Cached article'));
    await tester.tap(find.text('Cached article'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse(cachedItem.url)]);
    await tester.ensureVisible(find.byKey(const Key('refresh-news')));
    await tester.tap(find.byKey(const Key('refresh-news')));
    await tester.pumpAndSettle();
    expect(gateway.refreshCalls, 1);
    expect(tester.takeException(), isNull);
  });
}
