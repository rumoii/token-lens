import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_gateway.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

import 'news_controller_first_refresh_test.dart';
import 'support/fake_news_gateway.dart';

Widget app(FirstRefreshHarness h) => MaterialApp(
  theme: const LensPalette(false).theme,
  home: NewsPage(
    controller: h.controller,
    openLink: (_) async => true,
    now: () => h.now,
  ),
);

void main() {
  testWidgets(
    'empty refresh shows progress, skeleton, cancel, then partial article',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = FirstRefreshHarness();
      addTearDown(h.controller.dispose);
      await h.controller.load();
      final pending = Completer<NewsSnapshot>();
      h.gateway.nextRefresh = pending.future;
      final work = h.controller.refresh();
      await tester.pumpWidget(app(h));
      expect(find.text('正在获取动态 · 已完成 0/2 个来源'), findsOneWidget);
      expect(find.text('正在刷新 · 已完成 0/2 个来源'), findsOneWidget);
      expect(find.byType(SkeletonLines), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('还没有动态'), findsNothing);
      h.gateway.cached = NewsSnapshot(
        sources: [openaiSource, hnSource.copyWith(refreshing: true)],
        items: const [freshItem],
        refreshing: true,
      );
      h.polls.last.fire();
      await tester.pump();
      expect(find.text('Fresh article'), findsOneWidget);
      expect(find.text('正在刷新 · 已完成 1/2 个来源'), findsOneWidget);
      expect(find.byType(SkeletonLines), findsNothing);
      pending.complete(cachedNews);
      await work;
      await tester.pumpAndSettle();
      expect(find.text('Cached article'), findsOneWidget);
    },
  );

  testWidgets('empty refresh cancel button invokes cancellation', (
    tester,
  ) async {
    final h = FirstRefreshHarness();
    addTearDown(h.controller.dispose);
    await h.controller.load();
    final pending = Completer<NewsSnapshot>();
    h.gateway.nextRefresh = pending.future;
    final work = h.controller.refresh();
    await tester.pumpWidget(app(h));
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(h.gateway.cancelCalls, 1);
    expect(h.polls.last.isActive, isFalse);
    pending.complete(failedNews);
    await work;
    await tester.pumpAndSettle();
    expect(h.controller.nextRetryAt, isNull);
  });

  testWidgets('waiting retry shows local HH:mm and immediate refresh', (
    tester,
  ) async {
    final h = FirstRefreshHarness(cached: failedNews);
    addTearDown(h.controller.dispose);
    await h.fail();
    await tester.pumpWidget(app(h));
    await tester.pumpAndSettle();
    expect(find.text('将在 09:02 自动重试'), findsOneWidget);
    expect(find.text('立即刷新'), findsOneWidget);
    h.gateway.nextRefresh = Future.value(cachedNews);
    await tester.tap(find.text('立即刷新'));
    await tester.pumpAndSettle();
    expect(h.gateway.refreshCalls, 2);
    expect(find.text('将在 09:02 自动重试'), findsNothing);
    expect(find.text('Cached article'), findsOneWidget);
  });
}
