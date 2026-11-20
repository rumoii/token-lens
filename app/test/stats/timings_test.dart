import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/stats/detail_page.dart' show detailRows;

import 'detail_page_test.dart' show DetailGateway, mountDetail;
import 'sessions_page_test.dart' show SessionsGateway, mountSessions;

Future<void> withTimingTooltip(
  WidgetTester tester,
  Finder target,
  VoidCallback verify,
) async {
  await tester.ensureVisible(target);
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: tester.getCenter(target));
  try {
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    verify();
  } finally {
    await mouse.removePointer();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
  }
}

StatsTiming exampleTiming(String method) => StatsTiming(
  requestCount: 4,
  ttft: [
    StatsTtft(method: method, sampleCount: 2, medianMs: 1000, p90Ms: 4000),
  ],
  speed: [
    StatsSpeed(
      method: method,
      sampleCount: 2,
      outputTokens: 100,
      generationMs: 2000,
      tokensPerSecond: 50,
    ),
  ],
);

class TimingSessions extends SessionsGateway {
  StatsTiming? timing;
  @override
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity, {
    StatsFilter filter = const StatsFilter(),
  }) async {
    final value = (await super.sessionDetail(
      source,
      sessionId,
      granularity,
      filter: filter,
    ))!;
    return StatsSessionDetail(
      session: value.session,
      models: value.models,
      timeline: value.timeline,
      kinds: value.kinds,
      granularity: value.granularity,
      snapshot: value.snapshot,
      period: value.period,
      timing: timing,
    );
  }
}

class TimingDetail extends DetailGateway {
  StatsTiming? timing;
  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) async {
    final value = await super.breakdown(by, filter);
    return StatsBreakdown(
      by: by,
      groups: [
        StatsGroup(
          key: by == 'source' ? 'kimi' : 'm',
          source: 'kimi',
          model: 'm',
          grossTokens: 100,
          unpricedRecords: 0,
          recordCount: 4,
          requestCount: 4,
          timing: timing,
          modelTiming: timing,
        ),
      ],
      totals: value.totals,
      snapshot: value.snapshot,
    );
  }
}

void main() {
  test('E4 模型行使用完整模型分布，不合并工具分位数', () {
    final combined = StatsTiming(
      requestCount: 8,
      ttft: [
        const StatsTtft(
          method: 'client_reported',
          sampleCount: 4,
          medianMs: 2500,
          p90Ms: 8000,
        ),
      ],
    );
    final data = StatsBreakdown(
      by: 'source_model',
      groups: [
        for (final source in ['kimi', 'zcode'])
          StatsGroup(
            key: 'm',
            model: 'm',
            source: source,
            grossTokens: 100,
            recordCount: 4,
            unpricedRecords: 0,
            timing: exampleTiming('client_reported'),
            modelTiming: combined,
          ),
      ],
      totals: const StatsTotals(
        grossTokens: 200,
        recordCount: 8,
        unpricedRecords: 0,
      ),
      snapshot: const StatsSnapshot(
        generatedAt: '2026-01-15T00:00:00Z',
        priceVersion: 'test',
        tz: 'UTC',
        filters: StatsAppliedFilter(from: '', to: '', offsetMinutes: 0),
      ),
    );
    expect(
      detailRows('model', data, {'model': ''}).single.timing,
      same(combined),
    );
  });
  for (final width in [720.0, 1440.0]) {
    testWidgets('E4 会话 $width 混合 method 分开显示', (tester) async {
      final a = exampleTiming('client_reported'),
          b = exampleTiming('log_timestamps');
      final timing = StatsTiming(
        requestCount: 8,
        ttft: [...a.ttft!, ...b.ttft!],
        speed: [...a.speed!, ...b.speed!],
      );
      await mountSessions(
        tester,
        TimingSessions()..timing = timing,
        query: 'source=kimi&session=s',
        width: width,
      );
      for (final value in ['一般 1.00 秒，慢时 4.00 秒', '约 50.0 token/s']) {
        await withTimingTooltip(tester, find.text(value), () {
          expect(find.text('$value · 客户端记录的计时'), findsOneWidget);
          expect(find.text('$value · 按日志时间戳估算'), findsOneWidget);
          expect(find.text('8 次请求里 2 次有记录'), findsNWidgets(2));
        });
      }
      expect(tester.takeException(), isNull);
    });
    for (final method in ['client_reported', 'log_timestamps']) {
      testWidgets('E4 会话 $width $method 指标、覆盖率和来源提示', (tester) async {
        await mountSessions(
          tester,
          TimingSessions()..timing = exampleTiming(method),
          query: 'source=kimi&session=s',
          width: width,
        );
        expect(find.text('首字（开始回复前要等）'), findsOneWidget);
        expect(find.text('速度（回复时每秒出多少）'), findsOneWidget);
        expect(find.text('一般 1.00 秒，慢时 4.00 秒'), findsOneWidget);
        expect(find.text('约 50.0 token/s'), findsOneWidget);
        final source = method == 'client_reported' ? '客户端记录的计时' : '按日志时间戳估算';
        for (final value in ['一般 1.00 秒，慢时 4.00 秒', '约 50.0 token/s']) {
          await withTimingTooltip(tester, find.text(value), () {
            expect(find.text('4 次请求里 2 次有记录 · $source'), findsOneWidget);
          });
        }
        expect(tester.takeException(), isNull);
      });
      for (final dim in ['tool', 'model']) {
        testWidgets('E4 明细 $dim $width $method 指标和覆盖率', (tester) async {
          await mountDetail(
            tester,
            TimingDetail()..timing = exampleTiming(method),
            query: 'period=all&view=detail&dim=$dim',
            width: width,
          );
          expect(find.text('首字（开始回复前要等）'), findsOneWidget);
          expect(find.text('速度（回复时每秒出多少）'), findsOneWidget);
          expect(find.text('一般 1.00 秒，慢时 4.00 秒'), findsOneWidget);
          expect(find.text('约 50.0 token/s'), findsOneWidget);
          final source = method == 'client_reported' ? '客户端记录的计时' : '按日志时间戳估算';
          for (final value in ['一般 1.00 秒，慢时 4.00 秒', '约 50.0 token/s']) {
            await withTimingTooltip(tester, find.text(value), () {
              expect(find.text('4 次请求里 2 次有记录 · $source'), findsOneWidget);
            });
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
    testWidgets('E4 会话 $width 无计时显示缺失提示', (tester) async {
      await mountSessions(
        tester,
        TimingSessions(),
        query: 'source=kimi&session=s',
        width: width,
      );
      expect(find.byKey(const Key('session-ttft')), findsNothing);
      expect(find.byKey(const Key('session-speed')), findsNothing);
      expect(find.text('每次请求'), findsOneWidget);
      await withTimingTooltip(tester, find.text('每次请求'), () {
        expect(find.text('日志里没记：首字、速度、平均速度'), findsOneWidget);
      });
      expect(find.textContaining('覆盖'), findsNothing);
      expect(tester.takeException(), isNull);
    });
    testWidgets('E4 明细 $width 无计时不加计时行', (tester) async {
      await mountDetail(
        tester,
        TimingDetail(),
        query: 'period=all&view=detail&dim=tool',
        width: width,
      );
      expect(find.byKey(const Key('detail-ttft-kimi')), findsNothing);
      expect(find.text('每次请求'), findsNothing);
      expect(find.textContaining('覆盖'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
