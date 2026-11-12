import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_gateway.dart';

import 'support/fake_news_gateway.dart';

void main() {
  test('D26B fake overlays read and stars and ignores unknown ids', () async {
    final gateway = FakeNewsGateway(cached: cachedNews);
    expect(cachedItem.read, isFalse);
    expect(cachedItem.starred, isFalse);
    expect((await gateway.setStarred('unknown', true)).starred, isEmpty);
    expect((await gateway.setRead([], true)).items.single.read, isFalse);
    expect(
      (await gateway.setRead(['unknown'], true)).items.single.read,
      isFalse,
    );
    expect((await gateway.setRead(['cached'], true)).items.single.read, isTrue);
    final starred = await gateway.setStarred('cached', true);
    expect(starred.items.single.starred, isTrue);
    expect(starred.starred.single.read, isTrue);
    expect(
      (await gateway.setRead(['cached'], false)).starred.single.read,
      isFalse,
    );
    expect((await gateway.setStarred('cached', false)).starred, isEmpty);
    await gateway.shutdown();
    expect((await gateway.setRead(['cached'], true)).error?.kind, 'closed');
    expect((await gateway.setStarred('cached', true)).error?.kind, 'closed');
  });

  test('D26B fake keeps ordered copies across refresh and disable', () async {
    final gateway = FakeNewsGateway(
      cached: const NewsSnapshot(
        sources: [openaiSource],
        items: [cachedItem, freshItem],
      ),
    );
    await gateway.setStarred('cached', true);
    gateway.nowMs++;
    await gateway.setStarred('fresh', true);
    gateway.nowMs++;
    expect(
      (await gateway.setStarred('cached', true)).starred.map((i) => i.id),
      ['fresh', 'cached'],
    );
    const updated = NewsItem(
      id: 'cached',
      sourceId: 'openai',
      title: 'Updated',
      url: 'https://example.com/new',
      firstSeenMs: 1,
    );
    gateway.refreshedItems['openai'] = [updated];
    final result = await gateway.refresh();
    expect(result.starred.map((i) => i.title), ['Fresh article', 'Updated']);
    final disabled = await gateway.setSourceEnabled('openai', false);
    expect(disabled.items, isEmpty);
    expect(disabled.starred, hasLength(2));
    expect((await gateway.setStarred('cached', true)).starred, hasLength(2));
    await gateway.setSourceEnabled('openai', true);
    gateway.refreshedItems['openai'] = [];
    final gone = await gateway.refresh();
    expect(gone.items, isEmpty);
    expect(gone.starred.map((i) => i.title), ['Fresh article', 'Updated']);
  });

  test('D26B fake supports state changes while a refresh is pending', () async {
    final gateway = FakeNewsGateway(cached: cachedNews);
    final pending = Completer<NewsSnapshot>();
    gateway.nextRefresh = pending.future;
    final refresh = gateway.refresh();
    expect((await gateway.setRead(['cached'], true)).refreshing, isTrue);
    expect((await gateway.setStarred('cached', true)).error, isNull);
    pending.complete(cachedNews);
    final result = await refresh;
    expect(result.items.single.read, isTrue);
    expect(result.starred.single.starred, isTrue);
  });

  test(
    'D26B fake preserves an unavailable state error across operations',
    () async {
      const error = NewsError(kind: 'cache', message: 'Unavailable state');
      final gateway = FakeNewsGateway(
        cached: const NewsSnapshot(
          sources: [openaiSource],
          items: [cachedItem],
          stateError: error,
        ),
      );
      expect(
        (await gateway.setRead(['cached'], true)).items.single.read,
        isFalse,
      );
      expect((await gateway.setStarred('cached', true)).starred, isEmpty);
      expect(
        (await gateway.setSourceEnabled('openai', false)).stateError,
        error,
      );
      expect((await gateway.refresh()).stateError, error);
    },
  );

  test('D26B fake rolls back failed state writes and can retry', () async {
    final gateway = FakeNewsGateway(cached: cachedNews);
    await gateway.setRead(['cached'], true);
    await gateway.setStarred('cached', true);
    gateway.stateWriteError = const NewsError(
      kind: 'cache',
      message: 'Write failed',
    );
    final unread = await gateway.setRead(['cached'], false);
    expect(unread.stateError?.kind, 'cache');
    expect(unread.items.single.read, isTrue);
    expect((await gateway.setStarred('cached', false)).starred, hasLength(1));
    gateway.stateWriteError = null;
    final retry = await gateway.setRead(['cached'], false);
    expect(retry.stateError, isNull);
    expect(retry.items.single.read, isFalse);
  });

  test(
    'D26B fake cleanup uses strict retention and keeps disabled cache ids',
    () async {
      for (final extra in [0, 1]) {
        final gateway = FakeNewsGateway(
          cached: NewsSnapshot(
            sources: [openaiSource],
            items: [cachedItem.copyWith(read: true)],
            starred: [freshItem.copyWith(read: true, starred: true)],
          ),
        );
        gateway.nowMs++;
        await gateway.setRead(['fresh'], true);
        gateway.nowMs += 30 * 24 * 60 * 60 * 1000 - 1 + extra;
        await gateway.setSourceEnabled('openai', false);
        final cleaned = await gateway.setRead(['cached'], true);
        expect(cleaned.starred.single.read, extra == 0);
        await gateway.setSourceEnabled('openai', true);
        expect((await gateway.snapshot()).items.single.read, isTrue);
      }
    },
  );
}
