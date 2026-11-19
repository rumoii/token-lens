import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats_controller.dart';

import '../news_controller_schedule_test.dart' show ManualTimer, period;
import '../support/fake_news_gateway.dart';
import 'fake_gateway.dart';
import 'onboarding_flow_test.dart' as onboarding;

class NewsFixture {
  final gateway = FakeNewsGateway(cached: cachedNews);
  final timers = <ManualTimer>[];
  DateTime now = demoNow;
  late final controller = NewsController(
    gateway,
    now: () => now,
    periodicTimer: (duration, callback) {
      final timer = ManualTimer(callback);
      if (duration == period) timers.add(timer);
      return timer;
    },
  );
}

class OnboardingController extends StatsController {
  OnboardingController(
    super.gateway, {
    super.news,
    super.store,
    super.preferences,
  });
  late Future<void> syncFromChoice;

  @override
  Future<void> startOnboardingSync({bool? localOnly}) =>
      syncFromChoice = super.startOnboardingSync(localOnly: localOnly);
}

void main() {
  test(
    'S4 startup and re-enable control news fetches without deleting cache',
    () async {
      final fixture = NewsFixture();
      final news = fixture.controller;
      final c = StatsController(
        FakeStatsGateway(),
        preferences: const UiPreferences(
          onboarded: true,
          newsEnabled: false,
          autoCheckUpdates: false,
        ),
        news: news,
      );
      addTearDown(news.dispose);
      addTearDown(c.dispose);
      await c.start();
      expect(fixture.gateway.refreshCalls, 0);
      expect(fixture.gateway.snapshotCalls, 0);
      expect(fixture.timers, isEmpty);
      await news.refresh();
      expect(fixture.gateway.refreshCalls, 0);

      await c.setPreferences(c.preferences.copyWith(newsEnabled: true));
      await Future<void>.delayed(Duration.zero);
      expect(fixture.gateway.refreshCalls, 1);
      expect(fixture.timers.single.isActive, isTrue);
      await news.setRead([cachedItem.id], true);
      await news.toggleStar(cachedItem.id);
      final oldTimer = fixture.timers.single;

      await c.setPreferences(c.preferences.copyWith(newsEnabled: false));
      expect(oldTimer.isActive, isFalse);
      fixture.now = fixture.now.add(period);
      oldTimer.fire();
      expect(fixture.gateway.refreshCalls, 1);

      await c.setPreferences(c.preferences.copyWith(newsEnabled: true));
      await Future<void>.delayed(Duration.zero);
      expect(fixture.timers, hasLength(2));
      expect(fixture.timers.last.isActive, isTrue);
      expect(news.snapshot.items.single.read, isTrue);
      expect(news.snapshot.starred.single.id, cachedItem.id);
      expect(fixture.gateway.shutdownCalls, 0);
      expect(c.preferences.autoCheckUpdates, isFalse);
    },
  );

  test(
    'S4 rapid re-enable waits for cancellation and never revives the old timer',
    () async {
      final fixture = NewsFixture();
      final news = fixture.controller;
      addTearDown(news.dispose);
      final request = Completer<NewsSnapshot>();
      fixture.gateway.nextRefresh = request.future;
      final starting = news.start();
      await Future<void>.delayed(Duration.zero);
      expect(fixture.gateway.refreshCalls, 1);
      final stopping = news.setEnabled(false);
      final restarting = news.setEnabled(true);
      expect(fixture.gateway.cancelCalls, 1);
      expect(fixture.gateway.refreshCalls, 1);
      expect(fixture.timers, isEmpty);
      fixture.gateway.nextRefresh = null;
      request.complete(cachedNews);
      await Future.wait([starting, stopping, restarting]);
      expect(fixture.gateway.refreshCalls, 2);
      expect(fixture.timers.single.isActive, isTrue);
    },
  );

  testWidgets('S4 retry can change the news choice after a failed sync', (
    tester,
  ) async {
    final fixture = NewsFixture();
    final gateway = onboarding.OnboardingGateway()..syncFailure = 'synthetic';
    final c = StatsController(gateway, news: fixture.controller);
    addTearDown(fixture.controller.dispose);
    addTearDown(c.dispose);
    await onboarding.mount(tester, c);
    await onboarding.click(tester, '开始统计');
    expect(c.phase, StatsSyncPhase.error);
    expect(fixture.timers.single.isActive, isTrue);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    gateway.syncFailure = null;
    await onboarding.click(tester, '重试');
    expect(find.text('统计好了'), findsOneWidget);
    expect(c.preferences.newsEnabled, isFalse);
    expect(fixture.timers.single.isActive, isFalse);
    expect(fixture.gateway.refreshCalls, 1);
  });

  for (final localOnly in [false, true]) {
    testWidgets(
      'S4 onboarding saves news choice $localOnly independently of updates',
      (tester) async {
        final dir = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('s4-onboard-'),
        ))!;
        addTearDown(() => dir.delete(recursive: true));
        final fixture = NewsFixture();
        final news = fixture.controller;
        final store = PreferencesStore(dir);
        final c = OnboardingController(
          onboarding.OnboardingGateway(),
          news: news,
          store: store,
          preferences: const UiPreferences(autoCheckUpdates: false),
        );
        addTearDown(news.dispose);
        await c.start();
        await onboarding.mount(tester, c);
        expect(fixture.gateway.refreshCalls, 0);
        expect(fixture.timers, isEmpty);
        if (localOnly) {
          await tester.tap(find.byType(Checkbox));
          await tester.pumpAndSettle();
        }
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(TextButton, '开始统计'));
          await c.syncFromChoice;
        });
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(TextButton, '去看看'));
          await c.store!.flush();
        });
        await tester.pumpAndSettle();
        expect(c.preferences.onboarded, isTrue);
        expect(c.preferences.newsEnabled, !localOnly);
        expect(fixture.gateway.refreshCalls, localOnly ? 0 : 1);
        expect(fixture.timers, hasLength(localOnly ? 0 : 1));
        final saved = (await tester.runAsync(store.read))!;
        expect(saved.newsEnabled, !localOnly);
        expect(saved.autoCheckUpdates, isFalse);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
}
