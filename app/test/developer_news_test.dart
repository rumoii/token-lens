import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';
import 'package:token_lens_app/news_page.dart';

import 'support/fake_news_gateway.dart';
import 'support/developer_news.dart';

void main() {
  test('D2.5 fixture covers nineteen sources and six explicit kinds', () {
    expect(developerNews.sources, hasLength(19));
    expect(
      developerNews.sources.map((s) => s.id).toSet(),
      developerNews.items.map((i) => i.sourceId).toSet(),
    );
    expect(developerNews.items.map((i) => i.kind).toSet(), {
      'release',
      'api',
      'deprecation',
      'pricing',
      'model',
      'general',
    });
    expect(cachedItem.kind, 'general');
  });

  test(
    'kind, category, source and search compose with shared counts',
    () async {
      final gateway = FakeNewsGateway(cached: developerNews);
      final controller = NewsController(gateway);
      addTearDown(controller.dispose);
      await controller.load();
      controller.setCategory(SourceCategory.community);
      controller.toggleSourceFilter('hn-ai');
      controller.toggleKindFilter('general');
      controller.setQuery('模型');
      expect(controller.visibleItems.map((i) => i.id), ['o']);
      expect(controller.categoryCount(SourceCategory.community), 1);
      expect(controller.categoryCount(SourceCategory.official), 0);
      expect(controller.categoryCount(null), 1);
      controller.toggleKindFilter('api');
      expect(controller.visibleItems.map((i) => i.id), ['o']);
      controller.toggleKindFilter('general');
      expect(controller.visibleItems, isEmpty);
      controller.clearFilters();
      expect(controller.kindIds, isEmpty);
      expect(controller.visibleItems.length, developerNews.items.length);
      expect(
        controller.categoryCount(SourceCategory.community),
        1 +
            developerNews.items
                .where(
                  (i) =>
                      developerSources
                          .singleWhere((s) => s.id == i.sourceId)
                          .category ==
                      SourceCategory.community,
                )
                .length,
      );
      expect(gateway.refreshCalls, 0);
    },
  );

  test('unknown or disabled also_in cannot match or inflate counts', () async {
    final gateway = FakeNewsGateway(
      cached: NewsSnapshot(
        sources: [openaiSource, hnSource.copyWith(enabled: false)],
        items: const [
          NewsItem(
            firstSeenMs: 1700000000000,
            id: 'x',
            sourceId: 'openai',
            title: 'X',
            url: 'https://example.com/x',
            alsoIn: ['hn-ai', 'hn-ai', 'missing'],
          ),
        ],
      ),
    );
    final controller = NewsController(gateway);
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.categoryCount(SourceCategory.community), 0);
    await controller.setSourceEnabled('hn-ai', true);
    expect(controller.categoryCount(SourceCategory.community), 1);
    controller.setCategory(SourceCategory.community);
    await controller.setSourceEnabled('openai', false);
    expect(controller.visibleItems.single.sourceId, 'openai');
    await controller.setSourceEnabled('hn-ai', false);
    expect(controller.visibleItems, isEmpty);
  });

  test('hot sort uses one unit, time ties and missing heat last', () async {
    final controller = NewsController(FakeNewsGateway(cached: developerNews));
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.hotSortAvailable, isFalse);
    controller.setSort(NewsSort.hot);
    expect(controller.sort, NewsSort.latest);
    controller.toggleSourceFilter('hn-ai');
    expect(controller.hotSortAvailable, isTrue);
    controller.setSort(NewsSort.hot);
    expect(controller.visibleItems.map((i) => i.id), [
      'hot-newer',
      'hot-older',
      'h',
      'o',
      'unranked',
    ]);
    controller.toggleSourceFilter('gh-release:openai/codex');
    expect(controller.sort, NewsSort.latest);
    expect(controller.visibleItems.first.id, 'o');
    controller.toggleSourceFilter('gh-release:openai/codex');
    controller.setSort(NewsSort.hot);
    controller.setQuery('模型');
    expect(controller.hotSortAvailable, isFalse);
    expect(controller.sort, NewsSort.latest);
  });

  test('multiple sources with the same heat unit remain comparable', () async {
    final controller = NewsController(
      FakeNewsGateway(
        cached: NewsSnapshot(
          sources: const [openaiSource, hnSource],
          items: const [
            NewsItem(
              firstSeenMs: 1700000000000,
              id: 'a',
              sourceId: 'openai',
              title: 'A',
              url: 'https://example.com/a',
              popularityKind: 'points',
              popularity: 0,
            ),
            NewsItem(
              firstSeenMs: 1700000000000,
              id: 'b',
              sourceId: 'hn-ai',
              title: 'B',
              url: 'https://example.com/b',
              popularityKind: 'points',
              popularity: 10,
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.hotSortAvailable, isTrue);
    controller.setSort(NewsSort.hot);
    expect(controller.visibleItems.map((i) => i.id), ['b', 'a']);
  });

  test(
    'refresh and source changes reconcile hot sort without another request',
    () async {
      final gateway = FakeNewsGateway(cached: developerNews);
      final controller = NewsController(gateway);
      addTearDown(controller.dispose);
      await controller.load();
      controller.toggleSourceFilter('hn-ai');
      controller.setSort(NewsSort.hot);
      await controller.setSourceEnabled('hn-ai', false);
      expect(controller.sort, NewsSort.latest);
      await controller.setSourceEnabled('hn-ai', true);
      controller.setSort(NewsSort.hot);
      gateway.refreshedItems['hn-ai'] = const [
        NewsItem(
          firstSeenMs: 1700000000000,
          id: 'changed',
          sourceId: 'hn-ai',
          title: 'Changed',
          url: 'https://example.com/changed',
          popularity: 1,
          popularityKind: 'stars',
        ),
        NewsItem(
          firstSeenMs: 1700000000000,
          id: 'points',
          sourceId: 'hn-ai',
          title: 'Points',
          url: 'https://example.com/points',
          popularity: 1,
          popularityKind: 'points',
        ),
      ];
      await controller.refresh(sourceIds: ['hn-ai']);
      expect(controller.hotSortAvailable, isFalse);
      expect(controller.sort, NewsSort.latest);
      final reopened = NewsController(FakeNewsGateway(cached: developerNews));
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.sort, NewsSort.latest);
      expect(gateway.refreshCalls, 1);
    },
  );

  test('latest handles unknown dates and stable registration ties', () async {
    final controller = NewsController(
      FakeNewsGateway(
        cached: const NewsSnapshot(
          sources: [openaiSource, hnSource],
          items: [
            NewsItem(
              firstSeenMs: 1700000000000,
              id: 'unknown',
              sourceId: 'hn-ai',
              title: 'Unknown',
              url: 'https://example.com/u',
              publishedAt: 'invalid',
            ),
            NewsItem(
              firstSeenMs: 1793890800000,
              id: 'h',
              sourceId: 'hn-ai',
              title: 'HN',
              url: 'https://example.com/h',
              publishedAt: '2026-11-05T15:00:00Z',
            ),
            NewsItem(
              firstSeenMs: 1793890800000,
              id: 'o',
              sourceId: 'openai',
              title: 'Official',
              url: 'https://example.com/o',
              publishedAt: '2026-11-05T15:00:00Z',
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.visibleItems.map((i) => i.id), ['o', 'h', 'unknown']);
  });

  test('also_in matches enabled category and source together', () async {
    final gateway = FakeNewsGateway(cached: multiNews);
    final controller = NewsController(gateway);
    addTearDown(controller.dispose);
    await controller.load();
    controller.setCategory(SourceCategory.community);
    controller.toggleSourceFilter('hn-ai');
    controller.setQuery('模型');
    expect(controller.visibleItems.map((item) => item.id), ['o']);
    expect(controller.visibleItems.single.sourceId, 'openai');
    await controller.setSourceEnabled('hn-ai', false);
    expect(controller.visibleItems, isEmpty);
    await controller.setSourceEnabled('hn-ai', true);
    expect(controller.visibleItems.map((item) => item.id), ['o']);
    controller.toggleSourceFilter('hn-ai');
    controller.toggleSourceFilter('openai');
    expect(controller.visibleItems, isEmpty);
    expect(gateway.refreshCalls, 0);
  });

  testWidgets('type and sort controls accompany the existing source filter', (
    tester,
  ) async {
    final controller = NewsController(FakeNewsGateway(cached: multiNews));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: NewsPage(controller: controller, openLink: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('全部类型'), findsOneWidget);
    expect(find.text('最新'), findsOneWidget);
    expect(find.text('热度'), findsOneWidget);
    await tester.tap(find.byKey(const Key('kind-filter-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('kind-filter-general')).first, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('type labels use neutral fills and general has no badge', (
    tester,
  ) async {
    final controller = NewsController(FakeNewsGateway(cached: developerNews));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: NewsPage(controller: controller, openLink: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    for (final pair in [
      ('release', '版本'),
      ('api', 'API'),
      ('deprecation', '弃用'),
      ('pricing', '价格'),
      ('model', '模型'),
    ]) {
      expect(find.byKey(Key('item-kind-${pair.$1}')), findsWidgets);
      final badge = tester.widget<Container>(
        find.byKey(Key('item-kind-${pair.$1}')).first,
      );
      expect(
        (badge.decoration! as BoxDecoration).color,
        const Color(0xffeeede9),
      );
      expect(
        find.descendant(
          of: find.byKey(Key('item-kind-${pair.$1}')).first,
          matching: find.text(pair.$2),
        ),
        findsOneWidget,
      );
    }
    expect(find.byKey(const Key('item-kind-general')), findsNothing);
    await tester.tap(find.byKey(const Key('kind-filter-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('kind-filter-api')).first);
    await tester.tap(find.byKey(const Key('kind-filter-deprecation')).first);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.kindIds, {'api', 'deprecation'});
    expect(controller.visibleItems.map((i) => i.id), ['deprecation', 'api']);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('kind-filter-menu')))
          .focusNode!
          .hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('AIbase date-only entries display the UTC day without a time', (
    tester,
  ) async {
    for (final date in [
      ('2026-11-05T00:00:00Z', '2026-11-05'),
      ('2026-11-05T23:00:00-02:00', '2026-11-06'),
    ]) {
      final controller = NewsController(
        FakeNewsGateway(
          cached: NewsSnapshot(
            sources: developerSources,
            items: [
              NewsItem(
                firstSeenMs: 1700000000000,
                id: 'aibase-date',
                sourceId: 'aibase',
                title: 'AIbase 日报日期',
                url: 'https://example.com/aibase/1',
                publishedAt: date.$1,
              ),
            ],
          ),
        ),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: NewsPage(
            key: ValueKey(date.$1),
            controller: controller,
            openLink: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('发布日期：${date.$2}'), findsOneWidget);
      expect(find.textContaining('（本地时间）'), findsNothing);
    }
  });

  testWidgets('API changelog dates retain the source day without a time', (
    tester,
  ) async {
    final controller = NewsController(FakeNewsGateway(cached: developerNews));
    addTearDown(controller.dispose);
    controller.toggleSourceFilter('openai-api');
    await tester.pumpWidget(
      MaterialApp(
        home: NewsPage(controller: controller, openLink: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('发布日期：2026-11-05'), findsOneWidget);
  });

  testWidgets(
    'sort controls reflect availability and category counts include also_in',
    (tester) async {
      final controller = NewsController(FakeNewsGateway(cached: developerNews));
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: NewsPage(controller: controller, openLink: (_) async => true),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextButton>(find.byKey(const Key('sort-hot'))).onPressed,
        isNull,
      );
      expect(find.textContaining('不同热度单位'), findsOneWidget);
      controller.toggleSourceFilter('hn-ai');
      controller.setCategory(SourceCategory.community);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('category-community')),
          matching: find.text('5'),
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(const Key('sort-hot')));
      await tester.tap(find.byKey(const Key('sort-hot')));
      await tester.pumpAndSettle();
      expect(controller.sort, NewsSort.hot);
      expect(
        tester.getTopLeft(find.text('A newer AI tooling discussion')).dy,
        lessThan(tester.getTopLeft(find.text('Community MODEL discussion')).dy),
      );
      expect(find.text('OpenAI'), findsWidgets);
      controller.toggleSourceFilter('gh-release:openai/codex');
      controller.setCategory(null);
      await tester.pumpAndSettle();
      expect(controller.sort, NewsSort.latest);
      expect(tester.takeException(), isNull);
    },
  );
}
