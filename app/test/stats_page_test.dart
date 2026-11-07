import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/stats_page.dart';

StatsTotals totals({
  int? tokens = 100,
  String? cost = '0.000123',
  int records = 1,
  int unpriced = 0,
}) => StatsTotals(
  grossTokens: tokens ?? 0,
  inputTokens: tokens,
  outputTokens: tokens == null ? null : 0,
  cacheReadTokens: tokens == null ? null : 0,
  cacheWriteTokens: tokens == null ? null : 0,
  costUsd: cost,
  costMicros: cost == null ? null : 123,
  unpricedRecords: unpriced,
  recordCount: records,
);
StatsGroup group() => const StatsGroup(
  key: 'unlisted',
  grossTokens: 10,
  inputTokens: 10,
  unpricedRecords: 1,
  recordCount: 1,
  priceState: 'unknown',
);

class FakeStatsGateway implements StatsGateway {
  FakeStatsGateway(this.value);
  StatsOverview value;
  Completer<void>? pending;
  String? failure;
  int syncs = 0;
  int closes = 0;
  @override
  Future<StatsOverview> load() async => value;
  @override
  Future<void> sync() async {
    syncs++;
    if (failure != null) throw StateError(failure!);
    await pending?.future;
  }

  @override
  Future<void> shutdown() async {
    closes++;
    pending?.complete();
    pending = null;
  }
}

void main() {
  Future<StatsController> show(
    WidgetTester tester,
    FakeStatsGateway gateway,
  ) async {
    final controller = StatsController(gateway);
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(home: StatsPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('data shows totals and both tables', (tester) async {
    await show(tester, FakeStatsGateway(StatsOverview(totals: totals())));
    expect(find.text('100'), findsOneWidget);
    expect(find.text(r'$0.000123'), findsOneWidget);
    expect(find.text('按来源'), findsOneWidget);
    expect(find.text('按模型'), findsOneWidget);
  });
  testWidgets('empty ledger shows zero and guidance', (tester) async {
    await show(
      tester,
      FakeStatsGateway(
        StatsOverview(totals: totals(tokens: 0, records: 0, cost: '0.000000')),
      ),
    );
    expect(find.text('尚无统计记录，点击同步读取本机日志。'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
  });
  testWidgets('unknown is not displayed as zero', (tester) async {
    await show(
      tester,
      FakeStatsGateway(StatsOverview(totals: totals(tokens: null, cost: null))),
    );
    expect(find.text('未知'), findsNWidgets(2));
    expect(find.text('0'), findsNothing);
  });
  testWidgets('unpriced records stay explicit', (tester) async {
    await show(
      tester,
      FakeStatsGateway(
        StatsOverview(totals: totals(unpriced: 1), models: [group()]),
      ),
    );
    expect(find.textContaining('未定价'), findsWidgets);
    expect(find.text('unlisted'), findsOneWidget);
    expect(find.text('未知'), findsOneWidget);
  });
  testWidgets('sync disables duplicate start and keeps previous data', (
    tester,
  ) async {
    final gateway = FakeStatsGateway(StatsOverview(totals: totals()))
      ..pending = Completer<void>();
    await show(tester, gateway);
    await tester.tap(find.text('同步'));
    await tester.pump();
    expect(find.text('同步中…'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(gateway.syncs, 1);
    gateway.pending!.complete();
    gateway.pending = null;
    await tester.pumpAndSettle();
    expect(find.text('同步'), findsOneWidget);
  });
  testWidgets('lock collision is a skipped sync', (tester) async {
    final gateway = FakeStatsGateway(StatsOverview(totals: totals()))
      ..failure = 'SYNC_BUSY';
    await show(tester, gateway);
    await tester.tap(find.text('同步'));
    await tester.pumpAndSettle();
    expect(find.text('已有同步或采集任务在执行中，本次已跳过。'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
  });
  testWidgets('startup and five minute timer stop on shutdown', (tester) async {
    final gateway = FakeStatsGateway(StatsOverview(totals: totals()));
    final controller = StatsController(gateway);
    addTearDown(controller.dispose);
    unawaited(controller.start());
    await tester.pump();
    expect(gateway.syncs, 1);
    await tester.pump(const Duration(minutes: 5));
    await tester.pump();
    expect(gateway.syncs, 2);
    await controller.shutdown();
    await controller.shutdown();
    await tester.pump(const Duration(minutes: 10));
    expect(gateway.syncs, 2);
    expect(gateway.closes, 1);
  });
}
