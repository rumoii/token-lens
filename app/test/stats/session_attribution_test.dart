import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/sessions_page.dart';
import 'package:token_lens_app/stats/detail_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';
import 'detail_page_test.dart' as detail_test;

class AttributionGateway extends FakeStatsGateway {
  StatsFilter? recentFilter;
  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) async {
    recentFilter = filter;
    return StatsSessions(
      items: const [
        StatsSessionItem(
          source: 'codex',
          sessionId: 'long',
          projectKey: 'C:/demo',
          startedAt: '2026-10-16T12:00:00Z',
          lastSeenAt: '2026-11-09T05:00:00Z',
          grossTokens: 70890000,
          recordCount: 96,
          requestCount: 96,
          unpricedRecords: 0,
          hasCumulative: false,
          cumulative: StatsTotals(
            grossTokens: 380000000,
            recordCount: 100,
            requestCount: 100,
            unpricedRecords: 0,
          ),
        ),
      ],
      snapshot: demoSnapshot,
    );
  }

  @override
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity, {
    StatsFilter filter = const StatsFilter(),
  }) async => StatsSessionDetail(
    session: const StatsSessionSummary(
      source: 'codex',
      sessionId: 'long',
      startedAt: '2026-10-16T12:00:00Z',
      lastSeenAt: '2026-11-09T05:00:00Z',
      grossTokens: 380000000,
      recordCount: 100,
      requestCount: 100,
      unpricedRecords: 0,
    ),
    period: const StatsTotals(
      grossTokens: 70890000,
      recordCount: 96,
      requestCount: 96,
      unpricedRecords: 0,
    ),
    models: const [],
    kinds: const StatsSessionKinds(event: 100, cumulative: 0),
    timeline: const [
      StatsBucket(
        bucket: '2026-11-09',
        grossTokens: 70890000,
        eventGrossTokens: 70890000,
        recordCount: 96,
        requestCount: 96,
        unpricedRecords: 0,
      ),
      StatsBucket(
        bucket: '2026-10-16',
        grossTokens: 309110000,
        eventGrossTokens: 309110000,
        recordCount: 4,
        requestCount: 4,
        unpricedRecords: 0,
      ),
    ],
    granularity: granularity,
    snapshot: demoSnapshot,
  );
}

class SnapshotGateway extends AttributionGateway {
  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) async => const StatsSessions(
    items: [
      StatsSessionItem(
        source: 'dsh',
        sessionId: 'snapshot',
        startedAt: '2026-11-09T05:00:00Z',
        lastSeenAt: '2026-11-09T05:30:00Z',
        grossTokens: 1000,
        recordCount: 1,
        unpricedRecords: 1,
        hasCumulative: true,
        cumulative: StatsTotals(
          grossTokens: 1000,
          recordCount: 1,
          unpricedRecords: 1,
        ),
      ),
    ],
    snapshot: demoSnapshot,
  );
  @override
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity, {
    StatsFilter filter = const StatsFilter(),
  }) async => StatsSessionDetail(
    session: const StatsSessionSummary(
      source: 'dsh',
      sessionId: 'snapshot',
      startedAt: '2026-11-09T05:00:00Z',
      lastSeenAt: '2026-11-09T05:30:00Z',
      grossTokens: 1000,
      recordCount: 1,
      unpricedRecords: 1,
    ),
    period: const StatsTotals(
      grossTokens: 1000,
      recordCount: 1,
      unpricedRecords: 1,
    ),
    models: const [],
    timeline: const [],
    kinds: const StatsSessionKinds(event: 0, cumulative: 1),
    granularity: granularity,
    snapshot: demoSnapshot,
  );
}

void main() {
  Future<StatsController> mount(
    WidgetTester tester,
    FakeStatsGateway fake, {
    String unit = 'chinese',
    String period = 'today',
  }) async {
    tester.view.physicalSize = const Size(1600, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = StatsController(
      fake,
      clock: () => demoNow,
      preferences: UiPreferences(
        onboarded: true,
        unitSystem: unit,
        period: StatsPeriod(period),
      ),
    );
    addTearDown(c.dispose);
    await c.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: const LensPalette(false).theme,
        home: StatsPage(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  for (final unit in ['chinese', 'english']) {
    testWidgets('E3 首页换算 $unit 与零用量', (tester) async {
      final fake = FakeStatsGateway()..tokens = 350000000;
      final c = await mount(tester, fake, unit: unit);
      expect(find.text('= 350,000,000 token'), findsOneWidget);
      fake.empty = true;
      await c.load();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-conversion')), findsNothing);
    });
  }
  testWidgets('E3 最近会话按时段查询、两行数字和开始日期', (tester) async {
    final fake = AttributionGateway();
    await mount(tester, fake);
    expect(fake.recentFilter!.from, '2026-11-09');
    expect(find.text('今天的会话'), findsOneWidget);
    expect(find.text('今天 7089万'), findsOneWidget);
    expect(find.text('累计 3.8亿'), findsOneWidget);
    expect(find.text('开始于 10月16日'), findsOneWidget);
    expect(find.text('96 次请求'), findsOneWidget);
    await tester.ensureVisible(find.text('查看全部会话'));
    await tester.tap(find.text('查看全部会话'));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(StatsPage));
    expect(Uri.splitQueryString(state.query)['period'], 'today');
  });
  testWidgets('E3 会话页全部和今天的列', (tester) async {
    final c = await mount(tester, AttributionGateway(), period: 'all');
    final dynamic state = tester.state(find.byType(StatsPage));
    state.navigate('sessions', <String, String>{});
    await tester.pumpAndSettle();
    expect(find.text('请求'), findsOneWidget);
    expect(find.text('时长'), findsOneWidget);
    await c.setPeriod(const StatsPeriod('today'));
    await tester.pumpAndSettle();
    expect(find.text('今天请求'), findsOneWidget);
    expect(find.text('累计请求'), findsOneWidget);
    expect(find.text('今天约值'), findsOneWidget);
    expect(find.text('开始于 10月16日'), findsOneWidget);
  });
  testWidgets('E3 会话详情按天表、时段与累计', (tester) async {
    final c = StatsController(
      AttributionGateway(),
      clock: () => demoNow,
      preferences: const UiPreferences(period: StatsPeriod('today')),
    );
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: const LensPalette(false).theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SessionDetail(
              controller: c,
              source: 'codex',
              sessionId: 'long',
              onDetail: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('整个会话累计'), findsOneWidget);
    expect(find.text('按天'), findsOneWidget);
    expect(find.text('平均每次'), findsOneWidget);
    expect(find.text('96 次请求'), findsOneWidget);
    expect(find.text('100 次请求 · 跨 25 天'), findsOneWidget);
    expect(find.byKey(const Key('session-day-2026-11-09')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('session-day-2026-11-09'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('session-day-2026-10-16'))).dy,
      ),
    );
    final today = find.byKey(const Key('session-day-2026-11-09'));
    final palette = LensPalette.of(tester.element(today));
    final dayNumbers = tester
        .widgetList<TokenText>(
          find.descendant(of: today, matching: find.byType(TokenText)),
        )
        .toList();
    expect(dayNumbers.last.value, 738438);
    expect(
      (tester.widget<Container>(today).decoration! as BoxDecoration).color,
      palette['clay-wash'],
    );
  });
  testWidgets('E3 快照请求不当零，详情不展示按天表', (tester) async {
    await mount(tester, SnapshotGateway());
    expect(find.text('只记录总数，算在开始那天'), findsOneWidget);
    final dynamic state = tester.state(find.byType(StatsPage));
    state.navigate('sessions', <String, String>{'period': 'today'});
    await tester.pumpAndSettle();
    expect(find.text('不记录'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('session-row-dsh:snapshot')));
    await tester.pumpAndSettle();
    expect(find.text('按天'), findsNothing);
    expect(find.textContaining('无法按天拆分'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('E3 明细追加请求和平均每次，未知保持不记录', (tester) async {
    await detail_test.mountDetail(tester, detail_test.DetailGateway());
    expect(find.text('请求'), findsOneWidget);
    expect(find.text('平均每次'), findsOneWidget);
    expect(find.text('不记录'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  test('E3 明细同模型跨来源合并请求，纯快照保持 null', () {
    const data = StatsBreakdown(
      by: 'source_model',
      groups: [
        StatsGroup(
          key: 'm',
          model: 'm',
          source: 'codex',
          grossTokens: 100,
          eventGrossTokens: 100,
          requestCount: 2,
          recordCount: 2,
          unpricedRecords: 0,
        ),
        StatsGroup(
          key: 'm',
          model: 'm',
          source: 'claude',
          grossTokens: 200,
          eventGrossTokens: 200,
          requestCount: 3,
          recordCount: 3,
          unpricedRecords: 0,
        ),
        StatsGroup(
          key: 'snapshot',
          model: 'snapshot',
          source: 'dsh',
          grossTokens: 900,
          eventGrossTokens: 0,
          recordCount: 1,
          unpricedRecords: 1,
        ),
      ],
      totals: StatsTotals(
        grossTokens: 1200,
        recordCount: 6,
        unpricedRecords: 1,
      ),
      snapshot: demoSnapshot,
    );
    final rows = detailRows('model', data, {'model': ''});
    expect(rows.first.tokens, 300);
    expect(rows.first.requestCount, 5);
    expect(rows.first.eventGrossTokens, 300);
    expect(rows.last.requestCount, isNull);
    expect(rows.last.eventGrossTokens, 0);
  });
}
