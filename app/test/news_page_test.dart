import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';

import 'support/fake_news_gateway.dart';

Widget _app(NewsController controller, {Future<bool> Function(Uri)? open}) =>
    MaterialApp(
      theme: const LensPalette(false).theme,
      home: NewsPage(
        controller: controller,
        openLink: open ?? (_) async => true,
        now: () => DateTime(2026, 11, 12, 9),
      ),
    );

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
    await tester.pumpWidget(_app(controller));
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
      _app(
        controller,
        open: (uri) async {
          opened.add(uri);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(hours: 1));
    expect(find.text('AI 热点'), findsOneWidget);
    expect(find.text('Token Lens'), findsNothing);
    expect(find.text('预览'), findsNothing);
    expect(find.text('Cached article'), findsOneWidget);
    expect(find.textContaining('每 30 分钟自动刷新'), findsOneWidget);
    expect(gateway.refreshCalls, 0);
    expect(opened, isEmpty);
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('在默认浏览器中打开原文：Cached article'))
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    expect(find.byKey(const Key('unread-dot')), findsOneWidget);
    await tester.tap(find.text('Cached article'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse(cachedItem.url)]);
    expect(controller.snapshot.items.single.read, isTrue);
    expect(find.byKey(const Key('unread-dot')), findsNothing);
    semantics.dispose();
    controller.dispose();
  });

  testWidgets('a failed open still marks the article read and explains', (
    tester,
  ) async {
    final controller = NewsController(FakeNewsGateway(cached: cachedNews));
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller, open: (_) async => false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cached article'));
    await tester.pumpAndSettle();
    expect(find.text('无法打开原文，请检查默认浏览器设置。'), findsOneWidget);
    expect(controller.snapshot.items.single.read, isTrue);
  });

  testWidgets(
    'manual refresh keeps existing content and exposes cancellation',
    (tester) async {
      final gateway = FakeNewsGateway(cached: cachedNews);
      final pending = Completer<NewsSnapshot>();
      gateway.nextRefresh = pending.future;
      final controller = NewsController(gateway);
      await tester.pumpWidget(_app(controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('refresh-news')));
      await tester.pump();
      expect(gateway.refreshCalls, 1);
      expect(find.text('Cached article'), findsOneWidget);
      expect(find.text('取消刷新'), findsOneWidget);
      expect(find.textContaining('正在刷新'), findsOneWidget);
      pending.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text('Cached article'), findsOneWidget);
      expect(find.textContaining('刷新失败'), findsWidgets);
      expect(find.textContaining('离线缓存'), findsWidgets);
      controller.dispose();
    },
  );

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
      await tester.scrollUntilVisible(
        find.text('Cached article'),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('news-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      Focus.of(tester.element(find.text('Cached article'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse(cachedItem.url)]);
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );

  testWidgets('empty cache explains automatic refresh without fetching', (
    tester,
  ) async {
    final gateway = FakeNewsGateway();
    final controller = NewsController(gateway);
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();
    expect(find.text('还没有动态'), findsOneWidget);
    expect(find.textContaining('无自动刷新'), findsNothing);
    expect(gateway.refreshCalls, 0);
    controller.dispose();
  });

  testWidgets('unmounted page ignores external opener completion', (
    tester,
  ) async {
    final controller = NewsController(FakeNewsGateway(cached: cachedNews));
    final opened = Completer<bool>();
    await tester.pumpWidget(_app(controller, open: (_) => opened.future));
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
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();
    expect(find.textContaining('时间不可用'), findsOneWidget);
    expect(find.text('Cached article'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('items group by local first-seen day with read actions', (
    tester,
  ) async {
    final now = DateTime(2026, 11, 12, 9);
    final controller = NewsController(
      FakeNewsGateway(
        cached: NewsSnapshot(
          sources: const [openaiSource],
          items: [
            NewsItem(
              id: 'today',
              sourceId: 'openai',
              title: 'Today article',
              url: 'https://openai.com/index/today/',
              firstSeenMs: DateTime(2026, 11, 12, 8, 5).millisecondsSinceEpoch,
            ),
            NewsItem(
              id: 'yesterday',
              sourceId: 'openai',
              title: 'Yesterday article',
              url: 'https://openai.com/index/yesterday/',
              firstSeenMs: DateTime(2026, 11, 11, 20).millisecondsSinceEpoch,
            ),
          ],
        ),
      ),
      now: () => now,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();
    expect(find.text('今天 · 11月12日 周四'), findsOneWidget);
    expect(find.text('昨天 · 11月11日 周三'), findsOneWidget);
    expect(find.text('08:05'), findsOneWidget);
    expect(find.text('1 条，全部未读'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('read-day-2026-11-12')));
    await tester.pumpAndSettle();
    expect(
      controller.snapshot.items.where((item) => item.read).map((i) => i.id),
      ['today'],
    );
    expect(find.byKey(const Key('read-day-2026-11-12')), findsNothing);
    await tester.tap(find.byKey(const Key('read-yesterday')));
    await tester.pumpAndSettle();
    expect(controller.totalUnread, 0);
    expect(find.byTooltip('标为未读'), findsNWidgets(2));
  });

  testWidgets('unread and starred views have their own empty states', (
    tester,
  ) async {
    final controller = NewsController(FakeNewsGateway(cached: cachedNews));
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('star-cached')));
    await tester.pumpAndSettle();
    expect(controller.snapshot.starred.single.id, 'cached');
    expect(find.text('收藏 1'), findsOneWidget);
    await tester.tap(find.text('收藏 1'));
    await tester.pumpAndSettle();
    expect(controller.view, NewsView.starred);
    expect(find.text('Cached article'), findsOneWidget);
    await tester.tap(find.byKey(const Key('star-cached')));
    await tester.pumpAndSettle();
    expect(find.text('还没有收藏'), findsOneWidget);
    await tester.tap(find.text('未读 1'));
    await tester.pumpAndSettle();
    expect(find.text('Cached article'), findsOneWidget);
    await tester.tap(find.byKey(const Key('read-cached')));
    await tester.pumpAndSettle();
    expect(find.text('都读完了'), findsOneWidget);
  });

  testWidgets('slash focuses search unless a text field has focus', (
    tester,
  ) async {
    final controller = NewsController(FakeNewsGateway(cached: cachedNews));
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byKey(const Key('news-search')),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
    await tester.enterText(find.byKey(const Key('news-search')), 'a/b');
    await tester.pump();
    expect(controller.query, 'a/b');
  });

  testWidgets('hot card ranks each source by its own popularity', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = NewsController(FakeNewsGateway(cached: multiNews));
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('hot-card'));
    expect(controller.hotTabs, ['hn-ai']);
    expect(
      find.descendant(
        of: card,
        matching: find.text('Community MODEL discussion'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('票')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('Codex 新版本')),
      findsNothing,
    );
    controller.setCategory(SourceCategory.official);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: card,
        matching: find.text('Community MODEL discussion'),
      ),
      findsOneWidget,
    );
  });
}
