import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

import 'support/fake_news_gateway.dart';

void main() {
  test('category, source and case-insensitive title/description search intersect locally', () async {
    final gateway = FakeNewsGateway(cached: multiNews);
    final controller = NewsController(gateway);
    addTearDown(controller.dispose);
    await controller.load();
    controller.setCategory(SourceCategory.community);
    controller.toggleSourceFilter('hn-ai');
    controller.toggleSourceFilter('openai');
    controller.setQuery('INFERENCE');
    expect(controller.visibleItems.map((item) => item.id), ['h']);
    controller.setQuery('model');
    expect(controller.visibleItems.map((item) => item.id), ['h']);
    controller.toggleSourceFilter('hn-ai');
    expect(controller.visibleItems, isEmpty);
    controller.clearFilters();
    expect(controller.visibleItems.length, 14);
    expect(gateway.snapshotCalls, 1);
    expect(gateway.refreshCalls, 0);
  });

  test(
    'all and single refresh forward exact ids and mark only enabled targets',
    () async {
      final gateway = FakeNewsGateway(cached: multiNews);
      final controller = NewsController(gateway);
      addTearDown(controller.dispose);
      await controller.load();
      await controller.refresh();
      expect(gateway.refreshRequests.single, isNull);
      final pending = Completer<NewsSnapshot>();
      gateway.nextRefresh = pending.future;
      final ids = ['hn-ai'];
      final task = controller.refresh(sourceIds: ids);
      ids.add('openai');
      expect(gateway.refreshRequests.last, ['hn-ai']);
      expect(
        controller.snapshot.sources
            .where((source) => source.refreshing)
            .map((source) => source.id),
        ['hn-ai'],
      );
      pending.complete(multiNews);
      await task;
    },
  );

  test(
    'source disable retains fake cache, hides entries, and excludes refresh',
    () async {
      final gateway = FakeNewsGateway(cached: multiNews);
      final controller = NewsController(gateway);
      addTearDown(controller.dispose);
      await controller.load();
      await controller.setSourceEnabled('hn-ai', false);
      expect(gateway.enableRequests, [('hn-ai', false)]);
      expect(
        controller.visibleItems.map((item) => item.id),
        isNot(contains('h')),
      );
      gateway.refreshedItems['hn-ai'] = [freshItem];
      await controller.refresh(sourceIds: ['hn-ai', 'unknown']);
      expect(gateway.cached.items.map((item) => item.id), contains('h'));
      await controller.setSourceEnabled('hn-ai', true);
      expect(controller.visibleItems.map((item) => item.id), contains('h'));
    },
  );

  test(
    'one failed source preserves its cache while a successful source commits',
    () async {
      final gateway = FakeNewsGateway(cached: multiNews);
      gateway.failures['hn-ai'] = const NewsError(
        kind: 'rate_limited',
        message: 'private diagnostic',
      );
      gateway.refreshedItems['openai'] = [freshItem];
      final controller = NewsController(gateway);
      addTearDown(controller.dispose);
      await controller.load();
      await controller.refresh();
      expect(controller.snapshot.error, isNull);
      expect(
        controller.snapshot.sources
            .singleWhere((source) => source.id == 'hn-ai')
            .error
            ?.kind,
        'rate_limited',
      );
      expect(
        controller.visibleItems.map((item) => item.id),
        containsAll(['fresh', 'h', 'c', 'q']),
      );
    },
  );

  test('late initial snapshot and source enable result cannot revive disposed controller', () async {
    final lateLoad = _DelayedGateway();
    final loading = NewsController(lateLoad);
    final load = loading.load();
    loading.dispose();
    lateLoad.loaded.complete(multiNews);
    await load;
    expect(loading.snapshot.items, isEmpty);

    final gateway = _DelayedGateway()..loaded.complete(multiNews);
    final controller = NewsController(gateway);
    await controller.load();
    final change = controller.setSourceEnabled('hn-ai', false);
    controller.dispose();
    gateway.changed.complete(const NewsSnapshot());
    await change;
    expect(controller.snapshot.items.length, multiNews.items.length);
    expect(gateway.shutdownCalls, 1);
  });

  testWidgets('news exposes local category filters and source management', (
    tester,
  ) async {
    final controller = NewsController(FakeNewsGateway(cached: cachedNews));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: NewsPage(controller: controller, openLink: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('category-all')), findsOneWidget);
    expect(find.text('工具更新'), findsOneWidget);
    expect(find.byKey(const Key('manage-sources')), findsOneWidget);
  });

  testWidgets('filters combine in the page and clear without a request', (
    tester,
  ) async {
    final gateway = FakeNewsGateway(cached: multiNews);
    final controller = NewsController(gateway);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: NewsPage(controller: controller, openLink: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('category-community')));
    await tester.tap(find.byKey(const Key('news-filter')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('filter-hn-ai')).first);
    await tester.tap(find.byKey(const Key('filter-hn-ai')).first);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('news-search')), 'INFERENCE');
    await tester.pumpAndSettle();
    expect(find.text('Community MODEL discussion'), findsWidgets);
    expect(find.text('OpenAI 模型更新'), findsNothing);
    await tester.enterText(find.byKey(const Key('news-search')), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的动态'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('clear-filters')));
    await tester.tap(find.byKey(const Key('clear-filters')));
    await tester.pumpAndSettle();
    expect(find.text('OpenAI 模型更新'), findsOneWidget);
    expect(find.text('Community MODEL discussion'), findsWidgets);
    expect(gateway.refreshCalls, 0);
  });

  testWidgets(
    'source controls refresh only their source and enable/disable its articles',
    (tester) async {
      final gateway = FakeNewsGateway(cached: multiNews);
      final controller = NewsController(gateway);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: NewsPage(controller: controller, openLink: (_) async => true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('manage-sources')));
      await tester.pumpAndSettle();
      await _openSourceActions(tester, 'hn-ai');
      await tester.tap(find.byKey(const Key('refresh-hn-ai')));
      await tester.pumpAndSettle();
      expect(gateway.refreshRequests.single, ['hn-ai']);
      await tester.tap(find.byKey(const Key('enabled-hn-ai')));
      await tester.pumpAndSettle();
      expect(gateway.enableRequests.last, ('hn-ai', false));
      expect(
        controller.visibleItems.map((item) => item.title),
        isNot(contains('Community MODEL discussion')),
      );
      await _openSourceActions(tester, 'hn-ai');
      expect(
        tester
            .widget<LensMenuRow>(find.byKey(const Key('refresh-hn-ai')))
            .entry
            .onPressed,
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('enabled-hn-ai')));
      await tester.pumpAndSettle();
      expect(
        controller.visibleItems.map((item) => item.title),
        contains('Community MODEL discussion'),
      );
    },
  );

  testWidgets(
    'partial failure renders safe Chinese copy and cross-source metadata',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = FakeNewsGateway(cached: multiNews);
      gateway.failures['hn-ai'] = const NewsError(
        kind: 'rate_limited',
        message: 'SECRET transport detail',
      );
      final controller = NewsController(gateway);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: NewsPage(controller: controller, openLink: (_) async => true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('refresh-news')));
      await tester.pumpAndSettle();
      expect(gateway.refreshRequests.single, isNull);
      expect(find.text('OpenAI 模型更新'), findsOneWidget);
      expect(find.text('Community MODEL discussion'), findsWidgets);
      expect(
        find.descendant(
          of: find.byKey(const Key('news-list')),
          matching: find.text('312 票'),
        ),
        findsOneWidget,
      );
      expect(find.text('1.2k 星'), findsOneWidget);
      expect(find.byTooltip('也见于 Hacker News'), findsOneWidget);
      await tester.tap(find.byKey(const Key('manage-sources')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('source-status-hn-ai'))).data,
        startsWith('限流'),
      );
      await _openSourceActions(tester, 'hn-ai');
      expect(find.textContaining('来源暂时限制请求'), findsOneWidget);
      expect(find.textContaining('SECRET'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final failure in [
    ('too_large', '响应过大', '来源响应超过大小上限，本次未更新缓存。'),
    ('content_type', '类型不符', '来源返回了不支持的内容类型，本次未更新缓存。'),
  ]) {
    testWidgets('source ${failure.$1} has a distinct safe Chinese message', (
      tester,
    ) async {
      final gateway = FakeNewsGateway(cached: multiNews);
      gateway.failures['hn-ai'] = NewsError(
        kind: failure.$1,
        message: 'INTERNAL response detail',
      );
      final controller = NewsController(gateway);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: NewsPage(controller: controller, openLink: (_) async => true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('refresh-news')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('manage-sources')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('source-status-hn-ai'))).data,
        startsWith(failure.$2),
      );
      await _openSourceActions(tester, 'hn-ai');
      expect(find.text(failure.$3), findsOneWidget);
      expect(find.textContaining('INTERNAL'), findsNothing);
    });
  }

  testWidgets('cancel button rejects late results and page disposal is quiet', (
    tester,
  ) async {
    final gateway = FakeNewsGateway(cached: multiNews);
    final pending = Completer<NewsSnapshot>();
    gateway.nextRefresh = pending.future;
    final controller = NewsController(gateway);
    await tester.pumpWidget(
      MaterialApp(
        home: NewsPage(controller: controller, openLink: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('refresh-news')));
    await tester.pump();
    await tester.tap(find.text('取消刷新'));
    await tester.pump();
    expect(gateway.cancelCalls, 1);
    pending.complete(
      const NewsSnapshot(items: [freshItem], sources: [openaiSource]),
    );
    await tester.pumpAndSettle();
    expect(find.text('OpenAI 模型更新'), findsOneWidget);
    expect(find.text('Fresh article'), findsNothing);
    final late = Completer<NewsSnapshot>();
    gateway.nextRefresh = late.future;
    await tester.tap(find.byKey(const Key('refresh-news')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    late.complete(
      const NewsSnapshot(items: [freshItem], sources: [openaiSource]),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(gateway.shutdownCalls, 1);
  });
}

class _DelayedGateway extends FakeNewsGateway {
  final loaded = Completer<NewsSnapshot>();
  final changed = Completer<NewsSnapshot>();

  @override
  Future<NewsSnapshot> snapshot() => loaded.future;

  @override
  Future<NewsSnapshot> setSourceEnabled(String id, bool enabled) =>
      changed.future;
}

Future<void> _openSourceActions(WidgetTester tester, String id) async {
  final row = find.byKey(Key('source-row-$id'));
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}
