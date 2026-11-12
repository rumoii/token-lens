import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/app_shell.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/smooth_wheel.dart';
import 'package:token_lens_app/stats/home_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';

import 'stats/fake_gateway.dart';
import 'support/fake_news_gateway.dart';

void main() {
  for (final width in [767.0, 1000.0]) {
    testWidgets('one sidebar hosts news with an unread badge at $width', (
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
      await newsController.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: const LensPalette(false).theme,
          home: AppShell(
            statsController: statsController,
            news: NewsPage(
              controller: newsController,
              openLink: (_) async => true,
            ),
            newsListenable: newsController,
            newsUnread: () => newsController.totalUnread,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(StatsHome), findsOneWidget);
      if (width < 768) {
        await tester.tap(find.byTooltip('打开导航菜单'));
        await tester.pumpAndSettle();
      }
      final badge = find.byKey(const Key('news-unread-badge'));
      expect(badge, findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text('1')),
        findsOneWidget,
      );
      await tester.tap(find.text('AI 热点'));
      await tester.pumpAndSettle();
      expect(find.text('Token Lens'), findsOneWidget);
      expect(find.byKey(const Key('stats-scroll')), findsNothing);
      expect(find.text('Cached article'), findsOneWidget);
      final scroll = find.descendant(
        of: find.byType(NewsPage),
        matching: find.byType(CustomScrollView),
      );
      expect(
        tester.widget<CustomScrollView>(scroll).controller,
        isA<SmoothWheelController>(),
      );
      await tester.tap(find.text('Cached article'));
      await tester.pumpAndSettle();
      expect(newsController.totalUnread, 0);
      if (width < 768) {
        await tester.tap(find.byTooltip('打开导航菜单'));
        await tester.pumpAndSettle();
      }
      expect(badge, findsNothing);
      expect(gateway.refreshCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the unread badge caps at 99+', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final newsController = NewsController(
      FakeNewsGateway(
        cached: NewsSnapshot(
          sources: const [openaiSource],
          items: [
            for (var i = 0; i < 120; i++)
              NewsItem(
                id: 'item-$i',
                sourceId: 'openai',
                title: 'Article $i',
                url: 'https://openai.com/index/$i/',
                firstSeenMs: 1700000000000,
              ),
          ],
        ),
      ),
    );
    final statsController = StatsController(
      FakeStatsGateway(),
      clock: () => demoNow,
    );
    addTearDown(newsController.dispose);
    addTearDown(statsController.dispose);
    await statsController.load();
    await newsController.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: const LensPalette(false).theme,
        home: AppShell(
          statsController: statsController,
          news: NewsPage(
            controller: newsController,
            openLink: (_) async => true,
          ),
          newsListenable: newsController,
          newsUnread: () => newsController.totalUnread,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('news-unread-badge')),
        matching: find.text('99+'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('statistics failure keeps an error banner and usable news', (
    tester,
  ) async {
    final gateway = FakeNewsGateway(cached: cachedNews);
    final controller = NewsController(gateway);
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    const error = '无法打开统计账本，请检查数据目录是否可读写。';
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
    await tester.tap(find.text('Cached article'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse(cachedItem.url)]);
    await tester.tap(find.byKey(const Key('refresh-news')));
    await tester.pumpAndSettle();
    expect(gateway.refreshCalls, 1);
    expect(tester.takeException(), isNull);
  });
}
