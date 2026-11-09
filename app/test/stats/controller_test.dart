import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats/logic/period.dart';

import 'fake_gateway.dart';

void main() {
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
