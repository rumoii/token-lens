import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';
import 'package:token_lens_app/news_page.dart';

import 'support/fake_news_gateway.dart';

void main() {
  testWidgets('wide list aligns short and long article titles', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = NewsController(
      FakeNewsGateway(
        cached: const NewsSnapshot(
          sources: [openaiSource],
          items: [
            NewsItem(
              firstSeenMs: 1700000000000,
              id: 'short',
              sourceId: 'openai',
              title: 'Short article',
              url: 'https://openai.com/index/short/',
              description: 'A short excerpt.',
            ),
            NewsItem(
              firstSeenMs: 1700000000000,
              id: 'long',
              sourceId: 'openai',
              title: 'Long article',
              url: 'https://openai.com/index/long/',
              description:
                  'This longer source excerpt fills the available list width '
                  'and wraps onto another line, while the short source excerpt '
                  'fits on one line. Both article titles should start at the '
                  'same left edge regardless of the length of their excerpts.',
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: NewsPage(controller: controller, openLink: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('news-list')), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Short article')).dx,
      closeTo(tester.getTopLeft(find.text('Long article')).dx, .01),
    );
  });

  testWidgets('startup shows cached news without fetching or opening links', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final gateway = FakeNewsGateway(cached: cachedNews);
    final controller = NewsController(gateway);
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: NewsPage(
          controller: controller,
          openLink: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(hours: 1));
    expect(find.text('AI 热点'), findsOneWidget);
    expect(find.text('Token Lens'), findsNothing);
    expect(find.text('工作台'), findsNothing);
    expect(find.text('预览'), findsOneWidget);
    expect(find.text('Cached article'), findsOneWidget);
    expect(find.textContaining('本地缓存'), findsWidgets);
    expect(gateway.refreshCalls, 0);
    expect(opened, isEmpty);
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('在默认浏览器中打开原文：Cached article'))
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    await tester.tap(find.text('Cached article'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse(cachedItem.url)]);
    semantics.dispose();
    controller.dispose();
  });

  testWidgets(
    'manual refresh keeps existing content and exposes cancellation',
    (tester) async {
      final gateway = FakeNewsGateway(cached: cachedNews);
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
      expect(gateway.refreshCalls, 1);
      expect(find.text('Cached article'), findsOneWidget);
      expect(find.text('取消刷新'), findsOneWidget);
      pending.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text('Cached article'), findsOneWidget);
      expect(find.textContaining('刷新失败'), findsWidgets);
      expect(find.textContaining('离线缓存'), findsWidgets);
      controller.dispose();
    },
  );

  testWidgets('700x500 supports keyboard layout switch without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = NewsController(FakeNewsGateway(cached: cachedNews));
    await tester.pumpWidget(
      MaterialApp(
        home: NewsPage(controller: controller, openLink: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('news-list')), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('卡片布局'));
    Focus.of(tester.element(find.byIcon(Icons.grid_view_rounded)))
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('news-cards')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets(
    '700x500 with text scale 2 supports scrolling and keyboard article links',
    (tester) async {
      tester.view.physicalSize = const Size(700, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = NewsController(FakeNewsGateway(cached: cachedNews));
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: NewsPage(
            controller: controller,
            openLink: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Cached article'));
      Focus.of(tester.element(find.text('Cached article'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse(cachedItem.url)]);
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );

  testWidgets('empty cache explains manual refresh and no statistics values', (
    tester,
  ) async {
    final gateway = FakeNewsGateway();
    final controller = NewsController(gateway);
    await tester.pumpWidget(
      MaterialApp(
        home: NewsPage(controller: controller, openLink: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有动态'), findsOneWidget);
    expect(find.text('点击顶部“统计”查看用量统计。'), findsNothing);
    expect(find.text('无自动刷新。外部页面仅在点击原文后打开。'), findsOneWidget);
    expect(gateway.refreshCalls, 0);
    controller.dispose();
  });

  testWidgets('unmounted page ignores external opener completion', (
    tester,
  ) async {
    final controller = NewsController(FakeNewsGateway(cached: cachedNews));
    final opened = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        home: NewsPage(controller: controller, openLink: (_) => opened.future),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cached article'));
    await tester.pumpWidget(const SizedBox());
    opened.complete(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('invalid last-success timestamp remains readable', (
    tester,
  ) async {
    final controller = NewsController(
      FakeNewsGateway(
        cached: NewsSnapshot(
          sources: [openaiSource.copyWith(lastSuccessMs: 9223372036854775807)],
          items: [cachedItem],
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NewsPage(controller: controller, openLink: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('时间不可用'), findsOneWidget);
    expect(find.text('Cached article'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });
}
