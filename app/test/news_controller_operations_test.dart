import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';

import 'support/fake_news_gateway.dart';

class OperationGateway extends FakeNewsGateway {
  OperationGateway() : super(cached: cachedNews);
  bool throwRead = false, throwStar = false;
  Future<NewsSnapshot>? snapshotResult;
  Future<NewsSnapshot>? enableResult;
  Future<NewsSnapshot>? readResult;
  @override
  Future<NewsSnapshot> snapshot() => snapshotResult ?? super.snapshot();
  @override
  Future<NewsSnapshot> setSourceEnabled(String id, bool enabled) =>
      enableResult ?? super.setSourceEnabled(id, enabled);
  @override
  Future<NewsSnapshot> setRead(List<String> ids, bool read) async {
    if (throwRead) throw StateError('read failed');
    return readResult == null
        ? await super.setRead(ids, read)
        : await readResult!;
  }

  @override
  Future<NewsSnapshot> setStarred(String id, bool starred) async {
    if (throwStar) throw StateError('star failed');
    return super.setStarred(id, starred);
  }
}

void main() {
  test('state operations run during refresh and preserve native state after completion', () async {
    final gateway = FakeNewsGateway(cached: cachedNews);
    final c = NewsController(gateway);
    addTearDown(c.dispose);
    await c.load();
    final pending = Completer<NewsSnapshot>();
    gateway.nextRefresh = pending.future;
    final refresh = c.refresh();
    await c.setRead(['cached'], true);
    await c.toggleStar('cached');
    expect(gateway.readRequests, hasLength(1));
    expect(gateway.readRequests.single.$1, ['cached']);
    expect(gateway.readRequests.single.$2, isTrue);
    expect(gateway.starRequests, [('cached', true)]);
    expect(c.snapshot.items.single.read, isTrue);
    expect(c.snapshot.starred.single.id, 'cached');
    pending.complete(cachedNews);
    await refresh;
    expect(c.snapshot.items.single.read, isTrue);
    expect(c.snapshot.items.single.starred, isTrue);
    expect(c.snapshot.starred.single.id, 'cached');
    await c.toggleStar('cached');
    expect(gateway.starRequests.last, ('cached', false));
    expect(c.snapshot.starred, isEmpty);
    await c.setRead(['cached'], false);
    await c.openedItem('cached');
    expect(gateway.readRequests.last.$1, ['cached']);
    expect(gateway.readRequests.last.$2, isTrue);
    expect(c.snapshot.items.single.read, isTrue);
  });

  test(
    'refresh result wins instead of overlaying locally cached flags',
    () async {
      final gateway = FakeNewsGateway(cached: cachedNews);
      final c = NewsController(gateway);
      addTearDown(c.dispose);
      await c.load();
      final pending = Completer<NewsSnapshot>();
      gateway.nextRefresh = pending.future;
      final refresh = c.refresh();
      await c.setRead(['cached'], true);
      await c.toggleStar('cached');
      // Simulate another native state update before the refresh commits.
      await gateway.setRead(['cached'], false);
      await gateway.setStarred('cached', false);
      pending.complete(cachedNews);
      await refresh;
      expect(c.snapshot.items.single.read, isFalse);
      expect(c.snapshot.items.single.starred, isFalse);
      expect(c.snapshot.starred, isEmpty);
    },
  );

  test(
    'markDayRead sends only unread ids from that group in one request',
    () async {
      final midnight = DateTime(2026, 11, 11);
      final gateway = FakeNewsGateway(
        cached: NewsSnapshot(
          sources: const [openaiSource],
          items: [
            NewsItem(
              id: 'today',
              sourceId: 'openai',
              title: 'Today',
              url: 'https://example.com',
              firstSeenMs: midnight.millisecondsSinceEpoch,
            ),
            NewsItem(
              id: 'read',
              sourceId: 'openai',
              title: 'Read',
              url: 'https://example.com',
              firstSeenMs: midnight.millisecondsSinceEpoch,
              read: true,
            ),
            NewsItem(
              id: 'yesterday',
              sourceId: 'openai',
              title: 'Yesterday',
              url: 'https://example.com',
              firstSeenMs: midnight
                  .subtract(const Duration(minutes: 1))
                  .millisecondsSinceEpoch,
            ),
          ],
        ),
      );
      final c = NewsController(gateway, now: () => midnight);
      addTearDown(c.dispose);
      await c.load();
      await c.markDayRead(c.dayGroups.first);
      expect(gateway.readRequests, hasLength(1));
      expect(gateway.readRequests.single.$1, ['today']);
      expect(gateway.readRequests.single.$2, isTrue);
      expect(c.totalUnread, 1);
    },
  );

  for (final read in [true, false]) {
    test(
      'thrown state operation preserves content and records Chinese stateError ($read)',
      () async {
        final gateway = OperationGateway();
        final c = NewsController(gateway);
        addTearDown(c.dispose);
        await c.load();
        await c.toggleStar('cached');
        gateway.throwRead = read;
        gateway.throwStar = !read;
        final before = c.snapshot;
        if (read) {
          await c.setRead(['cached'], true);
        } else {
          await c.toggleStar('cached');
        }
        expect(c.snapshot.items, before.items);
        expect(c.snapshot.starred, before.starred);
        expect(c.snapshot.error, before.error);
        expect(c.snapshot.stateError?.kind, 'cache');
        expect(
          c.snapshot.stateError!.message,
          matches(RegExp('[\u4e00-\u9fff]')),
        );
        gateway.throwRead = gateway.throwStar = false;
        await c.setRead(['cached'], true);
        expect(c.snapshot.stateError, isNull);
      },
    );
  }

  test(
    'load failure keeps state written while snapshot load was pending',
    () async {
      final gateway = OperationGateway();
      final pending = Completer<NewsSnapshot>();
      gateway.snapshotResult = pending.future;
      await gateway.setStarred('cached', true);
      gateway.stateWriteError = const NewsError(
        kind: 'cache',
        message: '状态写入失败',
      );
      final c = NewsController(gateway);
      addTearDown(c.dispose);
      final load = c.load();
      await c.setRead(['cached'], true);
      final before = c.snapshot;
      expect(before.starred, hasLength(1));
      expect(before.stateError, isNotNull);
      pending.completeError(StateError('cache failed'));
      await load;
      expect(c.snapshot.starred, before.starred);
      expect(c.snapshot.stateError, same(before.stateError));
      expect(c.snapshot.items, before.items);
      expect(c.snapshot.error?.kind, 'cache');
    },
  );

  test(
    'source switching blocks automatic tick but not state operations',
    () async {
      final gateway = OperationGateway();
      late void Function(Timer) tick;
      var now = DateTime(2026, 11, 11);
      final c = NewsController(
        gateway,
        now: () => now,
        periodicTimer: (duration, callback) {
          tick = callback;
          return Timer(const Duration(days: 1), () {});
        },
      );
      addTearDown(c.dispose);
      await c.start();
      final count = gateway.refreshCalls;
      final pending = Completer<NewsSnapshot>();
      gateway.enableResult = pending.future;
      final enable = c.setSourceEnabled('openai', false);
      now = now.add(const Duration(minutes: 30));
      tick(Timer(Duration.zero, () {}));
      await c.setRead(['cached'], true);
      expect(gateway.refreshCalls, count);
      expect(gateway.readRequests, isNotEmpty);
      pending.complete(cachedNews);
      await enable;
    },
  );

  test(
    'closed operations do not call gateway and late state result is ignored',
    () async {
      final gateway = OperationGateway();
      final c = NewsController(gateway);
      addTearDown(c.dispose);
      await c.load();
      final before = c.snapshot;
      final pending = Completer<NewsSnapshot>();
      gateway.readResult = pending.future;
      final work = c.setRead(['cached'], true);
      await c.shutdown();
      pending.complete(const NewsSnapshot());
      await work;
      await c.setRead(['cached'], true);
      await c.toggleStar('cached');
      await c.openedItem('cached');
      c.setView(NewsView.starred);
      c.setHotTab('hn-ai');
      expect(c.snapshot, same(before));
      expect(c.view, NewsView.all);
      expect(gateway.readRequests, isEmpty);
      expect(gateway.starRequests, isEmpty);
    },
  );
}
