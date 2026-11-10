import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/smooth_wheel.dart';
import 'package:token_lens_app/stats/sources_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';

const healthy = StatsSourceChecks(
  timeOutOfRange: 0,
  hugeRequests: 0,
  nullModel: 0,
  mixedKindSessions: 0,
);
StatsSource source(
  String id, {
  String evidence = 'A',
  String mode = 'event',
  int records = 3,
  StatsRetention retention = const StatsRetention(reviewable: 3, logsGone: 0),
  StatsSourceChecks checks = healthy,
  List<StatsSourceNote> notes = const [],
}) => StatsSource(
  source: id,
  evidence: evidence,
  status: 'ok',
  records: records,
  recordMode: mode,
  retention: retention,
  checks: checks,
  notes: notes,
  limits: const ['累计型：一个会话只有一条快照'],
  lastObservedAt: '2026-11-08T00:00:00Z',
);

class SourcesGateway extends FakeStatsGateway {
  List<StatsSource> items = [source('codex')];
  StatsSourceRun? run;
  String? sourcesError, monthError;
  int sourceReads = 0, monthReads = 0;
  final monthFilters = <StatsFilter>[];
  List<String> anomalies = [];
  Completer<StatsSources>? pendingSources;
  @override
  Future<StatsSources> sources() async {
    sourceReads++;
    if (pendingSources != null) return pendingSources!.future;
    if (sourcesError != null) throw StateError(sourcesError!);
    return StatsSources(sources: items, lastRun: run, snapshot: demoSnapshot);
  }

  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) async {
    if (by == 'source' && filter.from == '2026-11-01') {
      monthReads++;
      monthFilters.add(filter);
      if (monthError != null) throw StateError(monthError!);
    }
    return super.breakdown(by, filter);
  }

  @override
  Future<StatsSync> sync() async {
    syncs++;
    if (syncFailure != null) throw StateError(syncFailure!);
    await syncBarrier?.future;
    return StatsSync(
      attempted: 3,
      inserted: 2,
      updated: 1,
      unchanged: 0,
      rejected: 0,
      repriced: 0,
      counts: zeroCounts,
      anomalies: anomalies,
      fileCount: 5,
      durationMs: 1200,
    );
  }
}

Future<StatsController> mount(
  WidgetTester tester,
  SourcesGateway fake, {
  double width = 1440,
  bool dark = false,
  bool reduced = false,
  bool settle = true,
  ValueChanged<Map<String, String>>? onDetail,
}) async {
  tester.view.physicalSize = Size(width, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = StatsController(fake, clock: () => demoNow);
  final scroll = SmoothWheelController();
  addTearDown(controller.dispose);
  addTearDown(scroll.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: LensPalette(dark).theme,
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 1800),
          disableAnimations: reduced,
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: StatsSourcesPage(
                controller: controller,
                onDetail: onDetail ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return controller;
}

Finder syncButton(String label) => find.widgetWithText(TextButton, label);

void main() {
  testWidgets('旧例：同步成功后显示计数和友好工具名', (tester) async {
    final fake = SourcesGateway();
    await mount(tester, fake);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('用真实日志核对过'), findsOneWidget);
    await tester.tap(syncButton('立即同步'));
    await tester.pumpAndSettle();
    expect(
      find.text('同步完成：扫描 5 个文件，新增 2 条，有变化的 1 条，用时 1.2 秒。'),
      findsOneWidget,
    );
    expect(fake.syncs, 1);
  });
  testWidgets('旧例：口径说明标出影响，未找到工具折叠', (tester) async {
    final fake = SourcesGateway()
      ..items = [
        source(
          'dsh',
          evidence: 'B',
          mode: 'cumulative',
          notes: const [
            StatsSourceNote(text: '只记录每个会话的总数。', impact: 'affects'),
            StatsSourceNote(text: '已修正计数。', impact: 'handled'),
          ],
        ),
      ];
    await mount(tester, fake);
    expect(find.text('只记录每个会话的总数。'), findsOneWidget);
    expect(find.text('只记录每个会话的总数'), findsOneWidget);
    expect(find.text('有影响'), findsOneWidget);
    expect(find.text('已处理'), findsOneWidget);
    expect(find.text('Claude Code'), findsNothing);
    await tester.tap(find.text('还有 24 个支持的工具没在这台电脑上找到'));
    await tester.pumpAndSettle();
    expect(find.text('Claude Code'), findsOneWidget);
    await tester.tap(find.text('还有 24 个支持的工具没在这台电脑上找到'));
    await tester.pumpAndSettle();
    expect(find.text('Claude Code'), findsNothing);
  });
  testWidgets('旧例：日志留存与自检只列非零异常', (tester) async {
    final fake = SourcesGateway()
      ..items = [
        source(
          'claude',
          records: 10,
          retention: const StatsRetention(reviewable: 4, logsGone: 6),
          checks: const StatsSourceChecks(
            timeOutOfRange: 0,
            hugeRequests: 0,
            nullModel: 3,
            mixedKindSessions: 0,
          ),
        ),
        source('codex'),
      ];
    await mount(tester, fake);
    expect(find.text('4 条还能对照原始日志复核'), findsOneWidget);
    expect(find.text('另有 6 条的日志已经不在了，照常计入总数，但没法再复核。'), findsOneWidget);
    expect(find.text('没有模型名、不计价：3 条'), findsOneWidget);
    expect(find.textContaining('时间不在合理范围'), findsNothing);
    expect(find.text('全部记录都还能对照原始日志复核'), findsOneWidget);
    expect(find.text('没发现异常'), findsOneWidget);
  });
  testWidgets('旧例：冲突等待且按钮禁用，复用控制器轮询', (tester) async {
    final fake = SourcesGateway()..syncFailure = 'SYNC_BUSY';
    final c = await mount(tester, fake);
    await tester.tap(syncButton('立即同步'));
    await tester.pump();
    expect(find.text('已有同步在执行，正在等待完成'), findsOneWidget);
    expect(tester.widget<TextButton>(syncButton('同步中…')).onPressed, isNull);
    expect(c.phase, StatsSyncPhase.conflict);
    await tester.pumpWidget(const SizedBox());
    await c.shutdown();
  });
  testWidgets('冲突观察完成不把上次同步计数当成本次结果', (tester) async {
    final fake = SourcesGateway();
    final c = await mount(tester, fake);
    await tester.tap(syncButton('立即同步'));
    await tester.pumpAndSettle();
    final receipt = c.lastSync;
    expect(find.textContaining('同步完成：扫描 5 个文件'), findsOneWidget);
    fake.syncFailure = 'SYNC_BUSY';
    await tester.tap(syncButton('立即同步'));
    await tester.pump();
    fake.run = const StatsSourceRun(
      status: 'ok',
      attempted: 8,
      inserted: 4,
      updated: 0,
      unchanged: 4,
      rejected: 0,
      anomalyCount: 0,
      anomalies: [],
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(c.phase, StatsSyncPhase.success);
    expect(c.lastSync, same(receipt));
    expect(find.textContaining('同步完成：扫描'), findsNothing);
    await tester.tap(find.text('上次同步的技术细节'));
    await tester.pumpAndSettle();
    expect(
      find.text('读了 8 条记录：新增 4 条，有变化的 0 条，没变的 4 条，跳过 0 条。'),
      findsOneWidget,
    );
    await c.shutdown();
  });
  for (final failing in ['sources', 'month']) {
    testWidgets('旧例：$failing 接口独立失败和重试', (tester) async {
      final fake = SourcesGateway();
      if (failing == 'sources') {
        fake.sourcesError = 'source failed';
      } else {
        fake.monthError = 'month failed';
      }
      await mount(tester, fake);
      expect(find.text('加载失败（request_failed）'), findsOneWidget);
      final beforeSources = fake.sourceReads, beforeMonth = fake.monthReads;
      fake.sourcesError = null;
      fake.monthError = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('加载失败（request_failed）'), findsNothing);
      expect(find.text('Codex'), findsOneWidget);
      expect(fake.sourceReads, beforeSources + (failing == 'sources' ? 1 : 0));
      expect(fake.monthReads, beforeMonth + (failing == 'month' ? 1 : 0));
    });
  }
  testWidgets('同步中按钮禁用，不重复同步；完成后重读来源和本月', (tester) async {
    final fake = SourcesGateway()..syncBarrier = Completer<void>();
    await mount(tester, fake);
    final sourcesBefore = fake.sourceReads, monthBefore = fake.monthReads;
    await tester.tap(syncButton('立即同步'));
    await tester.pump();
    expect(tester.widget<TextButton>(syncButton('同步中…')).onPressed, isNull);
    await tester.tap(syncButton('同步中…'));
    expect(fake.syncs, 1);
    fake.syncBarrier!.complete();
    await tester.pumpAndSettle();
    expect(fake.sourceReads, greaterThan(sourcesBefore));
    expect(fake.monthReads, greaterThan(monthBefore));
    expect(
      fake.monthFilters.every(
        (f) => f.from == '2026-11-01' && f.to == '2026-11-09',
      ),
      true,
    );
  });
  testWidgets('同步异常警告和失败可见，失败后可再试', (tester) async {
    final fake = SourcesGateway()..anomalies = ['synthetic warning'];
    await mount(tester, fake);
    await tester.tap(syncButton('立即同步'));
    await tester.pumpAndSettle();
    expect(find.text('同步完成，有异常警告：synthetic warning'), findsOneWidget);
    fake.syncFailure = 'synthetic failure';
    await tester.tap(syncButton('立即同步'));
    await tester.pumpAndSettle();
    expect(find.textContaining('同步失败：'), findsOneWidget);
    expect(tester.widget<TextButton>(syncButton('立即同步')).onPressed, isNotNull);
  });
  testWidgets('明细回调带 tool 和 dim=model；技术细节可展开', (tester) async {
    Map<String, String>? params;
    await mount(tester, SourcesGateway(), onDetail: (v) => params = v);
    await tester.tap(find.text('看用量'));
    expect(params, {'tool': 'codex', 'dim': 'model'});
    expect(find.text('来源 ID'), findsNothing);
    await tester.tap(find.text('技术细节'));
    await tester.pumpAndSettle();
    expect(find.text('来源 ID'), findsOneWidget);
    expect(find.text('A（真实样本）'), findsOneWidget);
    expect(find.text('累计型：一个会话只有一条快照'), findsOneWidget);
  });
  testWidgets('空来源和零记录不作为找到工具', (tester) async {
    await mount(
      tester,
      SourcesGateway()..items = [source('codex', records: 0)],
    );
    expect(find.text('还没找到工具的日志'), findsOneWidget);
    expect(find.text('用过支持的 AI 编程工具以后，点「立即同步」。'), findsOneWidget);
    expect(find.text('还有 25 个支持的工具没在这台电脑上找到'), findsOneWidget);
    expect(find.text('Codex'), findsNothing);
  });
  for (final dark in [false, true]) {
    for (final reduced in [false, true]) {
      testWidgets('720 宽 dark=$dark reduced=$reduced 无溢出', (tester) async {
        final fake = SourcesGateway()
          ..items = [source('claude'), source('codex')];
        await mount(tester, fake, width: 720, dark: dark, reduced: reduced);
        expect(find.byType(ToolTile), findsNWidgets(2));
        expect(find.text('看用量'), findsNWidgets(2));
        final a = tester.getTopLeft(find.byKey(const ValueKey('tool-claude')));
        final b = tester.getTopLeft(find.byKey(const ValueKey('tool-codex')));
        expect(a.dx, b.dx);
        expect(a.dy, isNot(b.dy));
        expect(tester.takeException(), isNull);
        if (reduced) {
          fake.syncBarrier = Completer<void>();
          await tester.tap(syncButton('立即同步'));
          await tester.pump();
          // Let the button's finite press/hover feedback finish before checking
          // that the reduced-motion sync icon does not schedule a loop.
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          expect(tester.binding.hasScheduledFrame, isFalse);
          fake.syncBarrier!.complete();
          await tester.pumpAndSettle();
        }
      });
    }
  }
  testWidgets('销毁后丢弃未完成请求', (tester) async {
    final fake = SourcesGateway()..pendingSources = Completer<StatsSources>();
    await mount(tester, fake, settle: false);
    expect(fake.sourceReads, 1);
    expect(fake.pendingSources!.isCompleted, isFalse);
    await tester.pumpWidget(const SizedBox());
    fake.pendingSources!.complete(
      const StatsSources(sources: [], snapshot: demoSnapshot),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
