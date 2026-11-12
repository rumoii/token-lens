import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';

import 'support/fake_news_gateway.dart';

const period = Duration(minutes: 30);

class ManualTimer implements Timer {
  ManualTimer(this.callback);
  final void Function(Timer) callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    tick++;
    // Deliberately deliver late callbacks too, to test the closed guard.
    callback(this);
  }
}

class ScheduleHarness {
  ScheduleHarness(NewsSnapshot cached)
    : gateway = FakeNewsGateway(cached: cached) {
    controller = NewsController(
      gateway,
      now: () => time,
      periodicTimer: (duration, callback) {
        if (duration == const Duration(seconds: 1)) {
          return ManualTimer(callback);
        }
        expect(duration, period);
        timerCreations++;
        return timer = ManualTimer(callback);
      },
    );
  }
  DateTime time = DateTime(2026, 11, 11, 12);
  final FakeNewsGateway gateway;
  late final NewsController controller;
  ManualTimer? timer;
  int timerCreations = 0;
  Future<void> tick({Duration advance = period}) async {
    time = time.add(advance);
    expect(timer, isNotNull);
    timer!.fire();
    await Future<void>.delayed(Duration.zero);
  }
}

NewsSnapshot cacheAt(int? time) => NewsSnapshot(
  sources: [
    NewsSource(
      id: 'openai',
      name: 'OpenAI',
      category: SourceCategory.official,
      homeUrl: 'https://example.com',
      lastSuccessMs: time,
    ),
  ],
  items: const [cachedItem],
);

void main() {
  final now = DateTime(2026, 11, 11, 12).millisecondsSinceEpoch;
  for (final (label, timestamp, expected) in [
    ('fresh', now - 1, 0),
    ('exact boundary', now - period.inMilliseconds, 0),
    ('old', now - period.inMilliseconds - 1, 1),
    ('never', null, 1),
  ]) {
    test('start $label cache and duplicate starts', () async {
      final h = ScheduleHarness(cacheAt(timestamp));
      addTearDown(h.controller.dispose);
      await Future.wait([h.controller.start(), h.controller.start()]);
      await h.controller.start();
      expect(h.gateway.snapshotCalls, 1);
      expect(h.gateway.refreshCalls, expected);
      expect(h.timerCreations, 1);
    });
  }

  test(
    'disabled source freshness does not prevent immediate refresh',
    () async {
      final h = ScheduleHarness(
        NewsSnapshot(
          sources: [
            cacheAt(null).sources.single,
            NewsSource(
              id: 'disabled',
              name: 'Disabled',
              category: SourceCategory.tools,
              homeUrl: 'https://example.com',
              lastSuccessMs: now,
              enabled: false,
            ),
          ],
        ),
      );
      addTearDown(h.controller.dispose);
      await h.controller.start();
      expect(h.gateway.refreshCalls, 1);
    },
  );

  test('mixed null and fresh enabled cache waits for timer', () async {
    final h = ScheduleHarness(
      NewsSnapshot(
        sources: [
          cacheAt(null).sources.single,
          NewsSource(
            id: 'other',
            name: 'Other',
            category: SourceCategory.tools,
            homeUrl: 'https://example.com',
            lastSuccessMs: now,
          ),
        ],
      ),
    );
    addTearDown(h.controller.dispose);
    await h.controller.start();
    expect(h.gateway.refreshCalls, 0);
    await h.tick();
    expect(h.gateway.refreshRequests, [null]);
  });

  test(
    'timer skips busy and recent manual refresh, including source refresh',
    () async {
      final h = ScheduleHarness(cacheAt(now));
      addTearDown(h.controller.dispose);
      await h.controller.start();
      h.time = h.time.add(const Duration(minutes: 20));
      final pending = Completer<NewsSnapshot>();
      h.gateway.nextRefresh = pending.future;
      final work = h.controller.refresh(sourceIds: ['openai']);
      await h.tick(advance: const Duration(minutes: 10));
      expect(h.gateway.refreshCalls, 1);
      pending.complete(cacheAt(h.time.millisecondsSinceEpoch));
      await work;
      await h.tick(advance: const Duration(minutes: 1));
      expect(h.gateway.refreshCalls, 1);
      h.gateway.nextRefresh = null;
      await h.tick(advance: const Duration(minutes: 19));
      expect(h.gateway.refreshCalls, 2);
    },
  );

  test(
    'rate limit skips one round; manual refresh remains available',
    () async {
      final h = ScheduleHarness(cacheAt(now));
      addTearDown(h.controller.dispose);
      await h.controller.start();
      h.gateway.failures['openai'] = const NewsError(
        kind: 'rate_limited',
        message: 'Limited',
      );
      await h.tick();
      expect(h.gateway.refreshCalls, 1);
      await h.tick();
      expect(h.gateway.refreshCalls, 1);
      h.gateway.failures.clear();
      await h.tick();
      expect(h.gateway.refreshCalls, 2);
      await h.controller.refresh();
      expect(h.gateway.refreshCalls, 3);
    },
  );

  test('manual refresh bypasses an unconsumed rate-limit skip', () async {
    final h = ScheduleHarness(cacheAt(now));
    addTearDown(h.controller.dispose);
    await h.controller.start();
    h.gateway.failures['openai'] = const NewsError(
      kind: 'rate_limited',
      message: 'Limited',
    );
    await h.controller.refresh();
    h.gateway.failures.clear();
    await h.controller.refresh();
    expect(h.gateway.refreshCalls, 2);
    await h.tick();
    expect(h.gateway.refreshCalls, 3);
  });

  test('automatic failure does not retry before next tick', () async {
    final h = ScheduleHarness(cacheAt(now));
    addTearDown(h.controller.dispose);
    await h.controller.start();
    final failed = Completer<NewsSnapshot>();
    h.gateway.nextRefresh = failed.future;
    final tick = h.tick();
    failed.completeError(StateError('offline'));
    await tick;
    expect(h.gateway.refreshCalls, 1);
    expect(h.controller.snapshot.error?.kind, 'network');
    h.gateway.nextRefresh = null;
    await h.tick();
    expect(h.gateway.refreshCalls, 2);
  });

  for (final dispose in [false, true]) {
    test(
      'shutdown/dispose cancels timer and rejects late tick ($dispose)',
      () async {
        final h = ScheduleHarness(cacheAt(now));
        addTearDown(h.controller.dispose);
        await h.controller.start();
        if (dispose) {
          h.controller.dispose();
        } else {
          await h.controller.shutdown();
        }
        expect(h.timer?.isActive, isFalse);
        await h.tick();
        await h.controller.start();
        expect(h.gateway.refreshCalls, 0);
        expect(h.timerCreations, 1);
        expect(h.gateway.shutdownCalls, 1);
      },
    );
  }

  test('shutdown during startup refresh never installs timer', () async {
    final h = ScheduleHarness(cacheAt(null));
    addTearDown(h.controller.dispose);
    final pending = Completer<NewsSnapshot>();
    h.gateway.nextRefresh = pending.future;
    final start = h.controller.start();
    await Future<void>.delayed(Duration.zero);
    expect(h.gateway.refreshCalls, 1);
    await h.controller.shutdown();
    pending.complete(cacheAt(now));
    await start;
    expect(h.timerCreations, 0);
  });
}
