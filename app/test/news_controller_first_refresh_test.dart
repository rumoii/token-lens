import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';

import 'news_controller_schedule_test.dart' show ManualTimer;
import 'support/fake_news_gateway.dart';

const neverSource = NewsSource(
  id: 'openai',
  name: 'OpenAI',
  category: SourceCategory.official,
  homeUrl: 'https://openai.com/',
);
const emptyNews = NewsSnapshot(sources: [neverSource, hnSource]);
const failedNews = NewsSnapshot(
  sources: [
    NewsSource(
      id: 'openai',
      name: 'OpenAI',
      category: SourceCategory.official,
      homeUrl: 'https://openai.com/',
      error: NewsError(kind: 'timeout', message: 'Timed out'),
    ),
  ],
);

class PollGateway extends FakeNewsGateway {
  PollGateway({super.cached = emptyNews});
  Completer<NewsSnapshot>? pendingSnapshot;

  @override
  Future<NewsSnapshot> snapshot() {
    if (pendingSnapshot case final pending?) {
      snapshotCalls++;
      return pending.future;
    }
    return super.snapshot();
  }
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

class FirstRefreshHarness {
  FirstRefreshHarness({NewsSnapshot cached = emptyNews})
    : gateway = PollGateway(cached: cached) {
    controller = NewsController(
      gateway,
      now: () => now,
      periodicTimer: (duration, callback) {
        final timer = ManualTimer(callback);
        (duration == const Duration(seconds: 1) ? polls : cycles).add(timer);
        return timer;
      },
      timer: (duration, callback) {
        delays.add(duration);
        final timer = ManualTimer((_) => callback());
        retries.add(timer);
        return timer;
      },
    );
  }

  final PollGateway gateway;
  late final NewsController controller;
  DateTime now = DateTime(2026, 11, 12, 9);
  final polls = <ManualTimer>[];
  final cycles = <ManualTimer>[];
  final retries = <ManualTimer>[];
  final delays = <Duration>[];

  Future<void> fail() async {
    gateway.nextRefresh = Future.value(failedNews);
    await controller.refresh();
  }

  Future<void> retry() async {
    now = now.add(delays.last);
    retries.last.fire();
    await flush();
  }
}

void main() {
  test('poll publishes a completed source before refresh returns', () async {
    final gateway = PollGateway();
    final timers = <ManualTimer>[];
    final controller = NewsController(
      gateway,
      now: () => DateTime(2026, 11, 12, 9),
      periodicTimer: (duration, callback) {
        expect(duration, const Duration(seconds: 1));
        final timer = ManualTimer(callback);
        timers.add(timer);
        return timer;
      },
    );
    addTearDown(controller.dispose);
    await controller.load();
    final pending = Completer<NewsSnapshot>();
    gateway.nextRefresh = pending.future;
    final work = controller.refresh();
    expect(controller.refreshTotal, 2);
    expect(controller.refreshDone, 0);
    gateway.cached = NewsSnapshot(
      sources: [openaiSource, hnSource.copyWith(refreshing: true)],
      items: const [freshItem],
      refreshing: true,
    );
    for (final timer in timers) {
      timer.fire();
    }
    await flush();
    final partial = controller.visibleItems.map((item) => item.id).toList();
    expect(controller.refreshDone, 1);
    expect(controller.refreshTotal, 2);
    pending.complete(cachedNews);
    await work;
    // Capture the intermediate result separately from the final response.
    expect(partial, ['fresh']);
    expect(gateway.snapshotCalls, 2);
    expect(controller.visibleItems.single.id, 'cached');
    expect(controller.refreshDone, 0);
    expect(controller.refreshTotal, 0);
    expect(timers.single.isActive, isFalse);
  });

  testWidgets('first failure retries after two minutes', (tester) async {
    final gateway = FakeNewsGateway(cached: failedNews);
    gateway.failures['openai'] = failedNews.sources.single.error!;
    final controller = NewsController(
      gateway,
      now: () => DateTime(2026, 11, 12, 9),
    );
    addTearDown(controller.dispose);
    await controller.start();
    expect(gateway.refreshCalls, 1);
    await tester.pump(const Duration(minutes: 1, seconds: 59));
    expect(gateway.refreshCalls, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(gateway.refreshCalls, 2);
    controller.dispose();
  });

  test(
    'poll reads never overlap and late reads lose to final snapshot',
    () async {
      final h = FirstRefreshHarness();
      addTearDown(h.controller.dispose);
      await h.controller.load();
      final pending = Completer<NewsSnapshot>();
      h.gateway.nextRefresh = pending.future;
      final work = h.controller.refresh();
      final read = Completer<NewsSnapshot>();
      h.gateway.pendingSnapshot = read;
      h.polls.last.fire();
      h.polls.last.fire();
      expect(h.gateway.snapshotCalls, 2);
      pending.complete(cachedNews);
      await work;
      h.polls.last.fire();
      expect(h.gateway.snapshotCalls, 2);
      read.complete(const NewsSnapshot(items: [freshItem]));
      await flush();
      expect(h.controller.visibleItems.single.id, 'cached');
    },
  );

  test(
    'late poll from a previous refresh cannot replace the next one',
    () async {
      final h = FirstRefreshHarness();
      addTearDown(h.controller.dispose);
      await h.controller.load();
      final first = Completer<NewsSnapshot>();
      h.gateway.nextRefresh = first.future;
      final work = h.controller.refresh();
      final read = Completer<NewsSnapshot>();
      h.gateway.pendingSnapshot = read;
      h.polls.last.fire();
      first.complete(cachedNews);
      await work;
      final next = Completer<NewsSnapshot>();
      h.gateway.nextRefresh = next.future;
      final nextWork = h.controller.refresh();
      h.polls.first.fire();
      h.polls.last.fire();
      expect(h.gateway.snapshotCalls, 2);
      read.complete(
        const NewsSnapshot(sources: [openaiSource], items: [freshItem]),
      );
      await flush();
      expect(h.controller.visibleItems.single.id, 'cached');
      h.gateway.pendingSnapshot = null;
      h.polls.last.fire();
      await flush();
      expect(h.gateway.snapshotCalls, 3);
      next.complete(cachedNews);
      await nextWork;
    },
  );

  for (final action in ['cancel', 'shutdown', 'dispose']) {
    test(
      '$action from refresh notification creates no poll or request',
      () async {
        final h = FirstRefreshHarness();
        addTearDown(h.controller.dispose);
        await h.controller.load();
        Future<void>? stop;
        var stopped = false;
        h.controller.addListener(() {
          if (stopped || !h.controller.snapshot.refreshing) return;
          stopped = true;
          if (action == 'cancel') {
            stop = h.controller.cancelRefresh();
          } else if (action == 'shutdown') {
            stop = h.controller.shutdown();
          } else {
            h.controller.dispose();
          }
        });
        await h.controller.refresh();
        await stop;
        expect(h.polls, isEmpty);
        expect(h.gateway.refreshCalls, 0);
        expect(h.controller.nextRetryAt, isNull);
      },
    );
  }

  for (final withError in [false, true]) {
    test('empty poll preserves existing articles ($withError)', () async {
      final h = FirstRefreshHarness(cached: cachedNews);
      addTearDown(h.controller.dispose);
      await h.controller.load();
      final pending = Completer<NewsSnapshot>();
      h.gateway.nextRefresh = pending.future;
      final work = h.controller.refresh();
      h.gateway.cached = NewsSnapshot(
        sources: [openaiSource.copyWith(refreshing: true)],
        refreshing: true,
        error: withError
            ? const NewsError(kind: 'cache', message: 'Unavailable')
            : null,
      );
      h.polls.last.fire();
      await flush();
      expect(h.controller.visibleItems.single.id, 'cached');
      expect(h.controller.refreshDone, 0);
      pending.complete(cachedNews);
      await work;
    });
  }

  test('failed poll leaves data and allows the next read', () async {
    final h = FirstRefreshHarness(cached: cachedNews);
    addTearDown(h.controller.dispose);
    await h.controller.load();
    final pending = Completer<NewsSnapshot>();
    h.gateway.nextRefresh = pending.future;
    final work = h.controller.refresh();
    h.gateway.pendingSnapshot = Completer<NewsSnapshot>();
    h.polls.last.fire();
    h.gateway.pendingSnapshot!.completeError(StateError('read failed'));
    await flush();
    expect(h.controller.visibleItems.single.id, 'cached');
    h.gateway.pendingSnapshot = null;
    h.polls.last.fire();
    await flush();
    expect(h.gateway.snapshotCalls, 3);
    pending.complete(cachedNews);
    await work;
  });

  for (final action in ['cancel', 'shutdown', 'dispose']) {
    test('$action stops polling and discards a pending read', () async {
      final h = FirstRefreshHarness();
      addTearDown(h.controller.dispose);
      await h.controller.load();
      final pending = Completer<NewsSnapshot>();
      h.gateway.nextRefresh = pending.future;
      final work = h.controller.refresh();
      final read = Completer<NewsSnapshot>();
      h.gateway.pendingSnapshot = read;
      h.polls.last.fire();
      Future<void>? cancellation;
      if (action == 'cancel') {
        cancellation = h.controller.cancelRefresh();
      } else if (action == 'shutdown') {
        await h.controller.shutdown();
      } else {
        h.controller.dispose();
      }
      expect(h.polls.last.isActive, isFalse);
      h.polls.last.fire();
      expect(h.gateway.snapshotCalls, 2);
      h.gateway.pendingSnapshot = null;
      read.complete(cachedNews);
      pending.complete(failedNews);
      await work;
      await cancellation;
      await flush();
      expect(h.controller.snapshot.items, isEmpty);
      expect(h.controller.nextRetryAt, isNull);
      expect(h.retries, isEmpty);
    });
  }

  test(
    'progress counts only selected enabled sources, including failures',
    () async {
      final h = FirstRefreshHarness(
        cached: NewsSnapshot(
          sources: [
            neverSource,
            hnSource,
            codexSource.copyWith(enabled: false),
          ],
        ),
      );
      addTearDown(h.controller.dispose);
      await h.controller.load();
      final pending = Completer<NewsSnapshot>();
      h.gateway.nextRefresh = pending.future;
      final work = h.controller.refresh(
        sourceIds: ['hn-ai', 'missing', 'hn-ai', codexSource.id],
      );
      expect(h.controller.refreshTotal, 1);
      expect(h.controller.refreshDone, 0);
      h.gateway.cached = NewsSnapshot(
        sources: [
          neverSource,
          hnSource.copyWith(error: failedNews.sources.single.error),
          codexSource.copyWith(enabled: false),
        ],
        refreshing: true,
      );
      h.polls.last.fire();
      await flush();
      expect(h.controller.refreshDone, 1);
      pending.complete(emptyNews);
      await work;
    },
  );

  test(
    'first failures retry at 2, then 10 minutes, then ordinary cycle',
    () async {
      final h = FirstRefreshHarness(cached: failedNews);
      addTearDown(h.controller.dispose);
      h.gateway.nextRefresh = Future.value(failedNews);
      await h.controller.start();
      expect(h.controller.nextRetryAt, h.now.add(const Duration(minutes: 2)));
      expect(h.delays, [const Duration(minutes: 2)]);
      await h.retry();
      expect(h.gateway.refreshCalls, 2);
      expect(h.controller.nextRetryAt, h.now.add(const Duration(minutes: 10)));
      await h.retry();
      expect(h.gateway.refreshCalls, 3);
      expect(h.delays, [
        const Duration(minutes: 2),
        const Duration(minutes: 10),
      ]);
      expect(h.controller.nextRetryAt, isNull);
      h.now = h.now.add(const Duration(minutes: 30));
      h.cycles.single.fire();
      await flush();
      expect(h.gateway.refreshCalls, 4);
      expect(h.delays, hasLength(2));
    },
  );

  for (final cached in [
    cachedNews,
    const NewsSnapshot(sources: [neverSource], items: [cachedItem]),
    const NewsSnapshot(sources: [openaiSource]),
  ]) {
    test(
      'cache or any prior success prevents first-failure retry (${cached.items.length}, ${cached.sources.first.lastSuccessMs})',
      () async {
        final h = FirstRefreshHarness(cached: cached);
        addTearDown(h.controller.dispose);
        h.gateway.failures['openai'] = failedNews.sources.single.error!;
        await h.controller.refresh();
        expect(h.controller.nextRetryAt, isNull);
        expect(h.delays, isEmpty);
      },
    );
  }

  test('partial success prevents retry even with no articles', () async {
    final h = FirstRefreshHarness();
    addTearDown(h.controller.dispose);
    h.gateway.failures['openai'] = failedNews.sources.single.error!;
    await h.controller.refresh();
    expect(h.controller.snapshot.items, isEmpty);
    expect(h.controller.nextRetryAt, isNull);
    expect(h.delays, isEmpty);
  });

  test('manual success cancels retry and clears failure count', () async {
    final h = FirstRefreshHarness(cached: failedNews);
    addTearDown(h.controller.dispose);
    await h.fail();
    final retry = h.retries.single;
    h.gateway.nextRefresh = Future.value(
      const NewsSnapshot(sources: [openaiSource]),
    );
    await h.controller.refresh();
    expect(retry.isActive, isFalse);
    expect(h.controller.nextRetryAt, isNull);
    retry.fire();
    await flush();
    expect(h.gateway.refreshCalls, 2);
    // A newly enabled, never-successful source gets the first delay again.
    h.gateway.cached = failedNews;
    await h.controller.setSourceEnabled('openai', true);
    await h.fail();
    expect(h.delays.last, const Duration(minutes: 2));
  });

  test('busy retry is skipped without postponement', () async {
    final h = FirstRefreshHarness(cached: failedNews);
    addTearDown(h.controller.dispose);
    await h.fail();
    final pending = Completer<NewsSnapshot>();
    h.gateway.nextRefresh = pending.future;
    final work = h.controller.refresh();
    await h.retry();
    expect(h.gateway.refreshCalls, 2);
    expect(h.controller.nextRetryAt, isNull);
    expect(h.delays, hasLength(1));
    pending.complete(cachedNews);
    await work;
  });

  for (final dispose in [false, true]) {
    test(
      'shutdown/dispose cancels retry and rejects late callback ($dispose)',
      () async {
        final h = FirstRefreshHarness(cached: failedNews);
        addTearDown(h.controller.dispose);
        await h.fail();
        if (dispose) {
          h.controller.dispose();
        } else {
          await h.controller.shutdown();
        }
        expect(h.retries.single.isActive, isFalse);
        expect(h.controller.nextRetryAt, isNull);
        await h.retry();
        expect(h.gateway.refreshCalls, 1);
      },
    );
  }
}
