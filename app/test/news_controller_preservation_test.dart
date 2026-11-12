import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';

import 'support/fake_news_gateway.dart';

const stateError = NewsError(kind: 'cache', message: '状态不可用');
const saved = NewsSnapshot(
  sources: [openaiSource],
  items: [cachedItem],
  starred: [freshItem],
  stateError: stateError,
);

class FaultGateway extends FakeNewsGateway {
  FaultGateway() : super(cached: saved);

  bool failSnapshot = false;
  bool failEnable = false;
  bool failCancel = false;
  Future<NewsSnapshot>? snapshotResult;
  NewsSnapshot? refreshSnapshot;

  @override
  Future<NewsSnapshot> refresh({List<String>? sourceIds}) async =>
      refreshSnapshot ?? await super.refresh(sourceIds: sourceIds);

  @override
  Future<NewsSnapshot> snapshot() async {
    if (failSnapshot) throw StateError('snapshot failed');
    return snapshotResult == null ? saved : await snapshotResult!;
  }

  @override
  Future<NewsSnapshot> setSourceEnabled(String id, bool enabled) async {
    if (failEnable) throw StateError('enable failed');
    return saved;
  }

  @override
  Future<void> cancelRefresh() async {
    if (failCancel) throw StateError('cancel failed');
    await super.cancelRefresh();
  }
}

void expectSaved(NewsController controller) {
  expect(controller.snapshot.starred, saved.starred);
  expect(controller.snapshot.stateError, same(stateError));
}

void main() {
  test('freeze retains starred and stateError from gateway', () async {
    final controller = NewsController(FaultGateway());
    addTearDown(controller.dispose);
    await controller.load();
    expectSaved(controller);
    expect(
      () => controller.snapshot.starred.add(cachedItem),
      throwsUnsupportedError,
    );
  });

  test('error snapshot freeze keeps returned state fields while preserving cached items', () async {
    final gateway = FaultGateway();
    final controller = NewsController(gateway);
    addTearDown(controller.dispose);
    await controller.load();
    gateway.refreshSnapshot = const NewsSnapshot(
      starred: [freshItem],
      stateError: stateError,
      error: NewsError(kind: 'network', message: '刷新不可用'),
    );
    await controller.refresh();
    expect(controller.snapshot.items, saved.items);
    expectSaved(controller);
  });

  test('refresh pending and thrown fallback retain state fields', () async {
    final gateway = FaultGateway();
    final controller = NewsController(gateway);
    addTearDown(controller.dispose);
    await controller.load();
    final pending = Completer<NewsSnapshot>();
    gateway.nextRefresh = pending.future;
    final refresh = controller.refresh();
    expectSaved(controller);
    pending.completeError(StateError('refresh failed'));
    await refresh;
    expectSaved(controller);
    expect(controller.snapshot.error?.kind, 'network');
  });

  test('source setting fallback retains state fields', () async {
    final gateway = FaultGateway()..failEnable = true;
    final controller = NewsController(gateway);
    addTearDown(controller.dispose);
    await controller.load();
    await controller.setSourceEnabled('openai', false);
    expectSaved(controller);
    expect(controller.snapshot.error?.kind, 'cache');
  });

  for (final failSnapshot in [false, true]) {
    for (final failCancel in [false, true]) {
      test(
        'cancel preserves state (snapshot=$failSnapshot, cancel=$failCancel)',
        () async {
          final gateway = FaultGateway()..failCancel = failCancel;
          final controller = NewsController(gateway);
          addTearDown(controller.dispose);
          await controller.load();
          gateway.failSnapshot = failSnapshot;
          final pending = Completer<NewsSnapshot>();
          gateway.nextRefresh = pending.future;
          final refresh = controller.refresh();
          final cancel = controller.cancelRefresh();
          pending.complete(saved);
          await refresh;
          await cancel;
          expectSaved(controller);
          if (failCancel || failSnapshot) {
            expect(controller.snapshot.error, isNotNull);
          }
        },
      );
    }
  }
}
