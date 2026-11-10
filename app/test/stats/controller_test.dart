import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/stats/logic/period.dart';

import 'fake_gateway.dart';

class StatusGateway extends FakeStatsGateway {
  int statusReads = 0;
  bool statusFails = true;
  String status = 'completed_with_anomalies';
  Completer<StatsSources>? statusBarrier;
  @override
  Future<StatsSources> sources() async {
    statusReads++;
    if (statusBarrier != null) return statusBarrier!.future;
    if (statusFails) throw StateError('fixture status offline');
    return StatsSources(
      sources: const [],
      snapshot: demoSnapshot,
      lastRun: StatsSourceRun(
        status: status,
        attempted: 1,
        inserted: 1,
        updated: 0,
        unchanged: 0,
        rejected: 0,
        anomalyCount: 1,
        anomalies: const ['vanished: onboarding fixture'],
      ),
    );
  }
}

void main() {
  testWidgets('状态错误保留原始详情，重试仍失败时只查状态', (tester) async {
    final fake = StatusGateway()..syncFailure = 'SYNC_BUSY';
    final c = StatsController(fake, clock: () => demoNow);
    addTearDown(c.dispose);
    await c.sync();
    await tester.pump(const Duration(seconds: 2));
    expect(c.syncError, contains('fixture status offline'));
    expect(c.syncErrorKind, StatsSyncErrorKind.status);
    await c.retryStatus();
    expect(c.phase, StatsSyncPhase.error);
    expect(c.syncErrorKind, StatsSyncErrorKind.status);
    expect(c.syncError, contains('fixture status offline'));
    expect(fake.syncs, 1);
    await c.shutdown();
  });
  testWidgets('状态重试恢复成功且异常警告与冲突轮询一致', (tester) async {
    final fake = StatusGateway()..syncFailure = 'SYNC_BUSY';
    final c = StatsController(fake, clock: () => demoNow);
    addTearDown(c.dispose);
    await c.sync();
    await tester.pump(const Duration(seconds: 2));
    expect(c.syncError, contains('fixture status offline'));
    fake.statusFails = false;
    final version = c.ledgerVersion;
    await c.retryStatus();
    expect(c.phase, StatsSyncPhase.success);
    expect(c.syncErrorKind, isNull);
    expect(c.syncError, isNull);
    expect(c.warning, 'vanished: onboarding fixture');
    expect(c.ledgerVersion, version + 1);
    expect(fake.syncs, 1);
    await c.shutdown();
  });
  testWidgets('状态重试看到 running 后继续等待，重复重试去重', (tester) async {
    final fake = StatusGateway()..syncFailure = 'SYNC_BUSY';
    final c = StatsController(fake, clock: () => demoNow);
    addTearDown(c.dispose);
    await c.sync();
    await tester.pump(const Duration(seconds: 2));
    expect(c.syncError, contains('fixture status offline'));
    fake.statusFails = false;
    fake.status = 'running';
    final a = c.retryStatus();
    final b = c.retryStatus();
    expect(identical(a, b), true);
    await a;
    expect(c.phase, StatsSyncPhase.conflict);
    fake.status = 'ok';
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(c.phase, StatsSyncPhase.success);
    expect(fake.syncs, 1);
    await c.shutdown();
  });
  testWidgets('关闭后状态重试晚到不通知，也不能发起新请求', (tester) async {
    final fake = StatusGateway()..syncFailure = 'SYNC_BUSY';
    final c = StatsController(fake, clock: () => demoNow);
    addTearDown(c.dispose);
    await c.sync();
    await tester.pump(const Duration(seconds: 2));
    expect(c.syncError, contains('fixture status offline'));
    fake.statusBarrier = Completer<StatsSources>();
    var notifications = 0;
    c.addListener(() => notifications++);
    final pending = c.retryStatus();
    final before = notifications;
    final closing = c.shutdown();
    fake.statusBarrier!.completeError(StateError('late status failure'));
    await pending;
    await closing;
    final readsBefore = fake.statusReads;
    await c.retryStatus();
    await tester.pump(const Duration(minutes: 10));
    expect(notifications, before);
    expect(fake.statusReads, readsBefore);
    expect(fake.syncs, 1);
  });
  test('切周期保持旧完整快照，过期请求不能提交', () async {
    final fake = FakeStatsGateway();
    final controller = StatsController(fake, clock: () => demoNow);
    await controller.load();
    final old = controller.overview;
    final barrier = Completer<void>();
    fake.readBarrier = barrier;
    final month = controller.setPeriod(const StatsPeriod('month'));
    expect(controller.overview, same(old));
    expect(controller.loading, isTrue);
    fake.readBarrier = null;
    await controller.setPeriod(const StatsPeriod('all'));
    expect(controller.overview!.period.period, 'all');
    barrier.complete();
    await month;
    expect(controller.overview!.period.period, 'all');
    controller.dispose();
  });
  test('请求失败保留旧数据、重试成功', () async {
    final fake = FakeStatsGateway();
    final controller = StatsController(fake, clock: () => demoNow);
    await controller.load();
    final old = controller.overview;
    fake.failure = 'fixture failure';
    await controller.load();
    expect(controller.error, contains('fixture failure'));
    expect(controller.overview, same(old));
    fake.failure = null;
    await controller.load();
    expect(controller.error, isNull);
    controller.dispose();
  });
  testWidgets('打开一次、每五分钟、关闭幂等', (tester) async {
    final fake = FakeStatsGateway();
    final controller = StatsController(fake, clock: () => demoNow);
    unawaited(controller.start());
    await tester.pump();
    await tester.pump();
    expect(fake.syncs, 1);
    unawaited(controller.start());
    await tester.pump(const Duration(minutes: 5));
    await tester.pump();
    expect(fake.syncs, 2);
    await controller.shutdown();
    await controller.shutdown();
    await tester.pump(const Duration(minutes: 10));
    expect(fake.syncs, 2);
    expect(fake.closes, 1);
    controller.dispose();
  });
  test('同步去重和错误保留', () async {
    final fake = FakeStatsGateway()..syncBarrier = Completer<void>();
    final controller = StatsController(fake, clock: () => demoNow);
    await controller.load();
    final a = controller.sync(), b = controller.sync();
    expect(identical(a, b), isTrue);
    expect(fake.syncs, 1);
    fake.syncBarrier!.complete();
    await a;
    expect(controller.phase, StatsSyncPhase.success);
    fake.syncFailure = 'fixture';
    await controller.sync();
    expect(controller.phase, StatsSyncPhase.error);
    expect(controller.overview, isNotNull);
    controller.dispose();
  });
  testWidgets('锁冲突等待观察到成功，不重复采集', (tester) async {
    final fake = FakeStatsGateway()..syncFailure = 'SYNC_BUSY';
    final controller = StatsController(fake, clock: () => demoNow);
    await controller.sync();
    expect(controller.phase, StatsSyncPhase.conflict);
    await controller.sync();
    expect(fake.syncs, 1);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(controller.phase, StatsSyncPhase.success);
    await controller.shutdown();
    controller.dispose();
  });
  test('关闭后未完成读取不能再次通知', () async {
    final controller = StatsController(
      FakeStatsGateway()..readBarrier = Completer<void>(),
    );
    var notifications = 0;
    controller.addListener(() => notifications++);
    final read = controller.load();
    final before = notifications;
    await controller.shutdown();
    await read;
    expect(notifications, before);
    controller.dispose();
  });
}
