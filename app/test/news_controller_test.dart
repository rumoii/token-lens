import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';

import 'support/fake_news_gateway.dart';

void main() {
  test('startup reads cached snapshot once and never refreshes', () async {
    final gateway = FakeNewsGateway(cached: cachedNews);
    final controller = NewsController(gateway);
    await Future.wait([controller.load(), controller.load()]);
    expect(gateway.snapshotCalls, 1);
    expect(gateway.refreshCalls, 0);
    expect(controller.snapshot.items.single.title, 'Cached article');
    controller.dispose();
  });

  test(
    'explicit refresh suppresses duplicate calls and recovers from failure',
    () async {
      final gateway = FakeNewsGateway(cached: cachedNews);
      final controller = NewsController(gateway);
      await controller.load();
      final failed = Completer<NewsSnapshot>();
      gateway.nextRefresh = failed.future;
      final first = controller.refresh();
      await controller.refresh();
      expect(gateway.refreshCalls, 1);
      expect(controller.snapshot.refreshing, isTrue);
      failed.completeError(StateError('transport failed'));
      await first;
      expect(controller.snapshot.items.single.title, 'Cached article');
      expect(controller.snapshot.sources.first.lastSuccessMs, 1700000000000);
      expect(controller.snapshot.error, isNotNull);
      expect(controller.snapshot.refreshing, isFalse);
      gateway.nextRefresh = Future.value(
        NewsSnapshot(
          items: [freshItem],
          sources: [openaiSource.copyWith(lastSuccessMs: 1800000000000)],
        ),
      );
      await controller.refresh();
      expect(controller.snapshot.items.single.title, 'Fresh article');
      expect(controller.snapshot.error, isNull);
      controller.dispose();
    },
  );

  test('error snapshots preserve cached content', () async {
    final gateway = FakeNewsGateway(cached: cachedNews);
    final controller = NewsController(gateway);
    await controller.load();
    gateway.nextRefresh = Future.value(
      const NewsSnapshot(
        error: NewsError(kind: 'network', message: '暂时无法连接来源'),
      ),
    );
    await controller.refresh();
    expect(controller.snapshot.items.single.id, 'cached');
    expect(
      controller.snapshot.sources.first.lastSuccessMs,
      cachedNews.sources.first.lastSuccessMs,
    );
    controller.dispose();
  });

  test('cancel waits for terminal work and rejects its late success', () async {
    final gateway = FakeNewsGateway(cached: cachedNews);
    gateway.cancelSnapshot = NewsSnapshot(
      items: cachedNews.items,
      sources: cachedNews.sources,
      error: const NewsError(kind: 'cancelled', message: 'Refresh cancelled.'),
    );
    final controller = NewsController(gateway);
    await controller.load();
    final pending = Completer<NewsSnapshot>();
    gateway.nextRefresh = pending.future;
    final refresh = controller.refresh();
    final cancel = controller.cancelRefresh();
    await Future<void>.delayed(Duration.zero);
    expect(gateway.cancelCalls, 1);
    expect(controller.snapshot.refreshing, isTrue);
    pending.complete(const NewsSnapshot(items: [freshItem]));
    await refresh;
    await cancel;
    expect(controller.snapshot.refreshing, isFalse);
    expect(controller.snapshot.items.single.id, 'cached');
    expect(controller.snapshot.error?.kind, 'cancelled');
    controller.dispose();
  });

  test('completed empty feed wins a late cancellation request', () async {
    final gateway = FakeNewsGateway(cached: cachedNews);
    final controller = NewsController(gateway);
    await controller.load();
    final pending = Completer<NewsSnapshot>();
    gateway.nextRefresh = pending.future;
    final refresh = controller.refresh();
    final committed = NewsSnapshot(
      sources: [openaiSource.copyWith(lastSuccessMs: 1800000000000)],
    );
    gateway.cached = committed;
    final cancel = controller.cancelRefresh();
    pending.complete(committed);
    await refresh;
    await cancel;
    expect(controller.snapshot.items, isEmpty);
    expect(
      controller.snapshot.sources.first.lastSuccessMs,
      committed.sources.first.lastSuccessMs,
    );
    expect(controller.snapshot.error, isNull);
    expect(controller.snapshot.refreshing, isFalse);
    controller.dispose();
  });

  test(
    'dispose ignores late completions and shuts gateway down once',
    () async {
      final gateway = FakeNewsGateway(cached: cachedNews);
      final controller = NewsController(gateway);
      await controller.load();
      final pending = Completer<NewsSnapshot>();
      gateway.nextRefresh = pending.future;
      final refresh = controller.refresh();
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.dispose();
      pending.complete(const NewsSnapshot(items: [freshItem]));
      await refresh;
      await controller.shutdown();
      expect(notifications, 0);
      expect(gateway.shutdownCalls, 1);
      expect(controller.snapshot.items.single.id, 'cached');
    },
  );
}
