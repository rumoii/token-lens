import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/sessions_page.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/widgets/filters.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats/widgets/session_usage.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';
import 'fix1_regressions_test.dart' as f1;
import 'sessions_page_test.dart' as s;

class IntegrationSessionsGateway extends s.SessionsGateway {
  bool grouped = false, mixed = false, legacy = false, unpriced = false;
  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) async {
    pages.add((filter: filter, limit: limit, cursor: cursor));
    final ids = grouped
        ? (filter.from?.isNotEmpty == true || filter.to?.isNotEmpty == true
              ? [1, 2, 3]
              : [2, 1, 3])
        : [1];
    return StatsSessions(
      items: [
        for (final id in ids)
          StatsSessionItem(
            source: 'codex',
            sessionId: 'i$id',
            projectKey: 'project-$id',
            startedAt: '2026-10-01T12:00:00Z',
            lastSeenAt: grouped
                ? '2026-11-0${id == 2 ? 8 : 7}T12:00:00Z'
                : '2026-11-09T12:00:00Z',
            grossTokens: mixed ? 900 : 400 - id * 100,
            recordCount: 1,
            unpricedRecords: 0,
            requestCount: mixed ? null : 1,
            hasCumulative: mixed,
            cumulative: const StatsTotals(
              grossTokens: 1000,
              recordCount: 2,
              requestCount: 1,
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
      sessionId: 'i1',
      startedAt: '2026-11-08T12:00:00Z',
      lastSeenAt: '2026-11-09T12:00:00Z',
      grossTokens: 1000,
      inputTokens: 100,
      cacheReadTokens: 400,
      costMicros: 5000000,
      recordCount: 2,
      requestCount: 1,
      unpricedRecords: 0,
    ),
    period: legacy
        ? null
        : StatsTotals(
            grossTokens: 900,
            inputTokens: 300,
            cacheReadTokens: 100,
            costMicros: unpriced ? null : 1250000,
            recordCount: 1,
            requestCount: mixed ? null : 1,
            unpricedRecords: unpriced ? 1 : 0,
          ),
    models: const [],
    timeline: [
      StatsBucket(
        bucket: '2026-11-09',
        grossTokens: 900,
        requestCount: mixed ? null : 1,
        eventGrossTokens: mixed ? null : 900,
        recordCount: 1,
        unpricedRecords: 0,
      ),
      if (mixed)
        const StatsBucket(
          bucket: '2026-11-08',
          grossTokens: 100,
          eventGrossTokens: 100,
          requestCount: 1,
          recordCount: 1,
          unpricedRecords: 0,
        ),
    ],
    kinds: StatsSessionKinds(event: 1, cumulative: mixed ? 1 : 0),
    granularity: granularity,
    snapshot: demoSnapshot,
  );
}

Finder detailText(String text) =>
    find.descendant(of: find.byType(SessionDetail), matching: find.text(text));

void main() {
  for (final period in ['all', 'week']) {
    for (final field in ['none', 'tool', 'project', 'model']) {
      test('INTEG-FIX2 usage label $period/$field', () {
        final filter = StatsFilter(
          source: field == 'tool' ? 'codex' : null,
          project: field == 'project' ? 'p' : null,
          model: field == 'model' ? 'm' : null,
        );
        final base = period == 'all' ? '全部' : '本周';
        final expected = field == 'none'
            ? base
            : period == 'all'
            ? '筛选后'
            : '$base筛选后';
        expect(sessionUsageLabel(StatsPeriod(period), filter), expected);
      });
    }
  }
  for (final width in [720.0, 1440.0]) {
    testWidgets('INTEG-FIX2 period list is flat at $width', (tester) async {
      await s.mountSessions(
        tester,
        IntegrationSessionsGateway()..grouped = true,
        query: 'period=today',
        width: width,
        reduced: true,
      );
      final page = find.byType(StatsSessionsPage);
      for (final date in ['2026-11-07T12:00:00Z', '2026-11-08T12:00:00Z']) {
        expect(
          find.descendant(
            of: page,
            matching: find.text(dayName(date, demoNow)),
          ),
          findsNothing,
        );
      }
      final ys = [
        for (final id in [1, 2, 3])
          tester.getTopLeft(find.byKey(Key('session-row-codex:i$id'))).dy,
      ];
      expect(ys[0], lessThan(ys[1]));
      expect(ys[1], lessThan(ys[2]));
    });
    testWidgets('INTEG-FIX2 all with model keeps date groups at $width', (
      tester,
    ) async {
      await s.mountSessions(
        tester,
        IntegrationSessionsGateway()..grouped = true,
        query: 'period=all&model=m',
        width: width,
        reduced: true,
      );
      for (final date in ['2026-11-07T12:00:00Z', '2026-11-08T12:00:00Z']) {
        expect(find.text(dayName(date, demoNow)), findsOneWidget);
      }
    });
    testWidgets('INTEG-FIX2 filtered week labels and detail at $width', (
      tester,
    ) async {
      await s.mountSessions(
        tester,
        IntegrationSessionsGateway(),
        query: 'period=week&model=m',
        width: width,
        reduced: true,
      );
      expect(find.textContaining('本周筛选后有用量的会话'), findsOneWidget);
      if (width < 768) {
        expect(find.text('本周筛选后 '), findsOneWidget);
        expect(find.text('本周筛选后 1 次请求'), findsOneWidget);
      } else {
        expect(find.text('本周筛选后请求'), findsOneWidget);
        expect(find.text('本周筛选后约值'), findsOneWidget);
      }
      await tester.tap(find.byKey(const Key('session-row-codex:i1')));
      await tester.pumpAndSettle();
      expect(detailText('本周筛选后'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    testWidgets('INTEG-FIX2 mixed period request is unknown at $width', (
      tester,
    ) async {
      await s.mountSessions(
        tester,
        IntegrationSessionsGateway()..mixed = true,
        query: 'period=today',
        width: width,
        reduced: true,
      );
      final row = find.byKey(const Key('session-row-codex:i1'));
      expect(
        find.descendant(of: row, matching: find.textContaining('不记录')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text(width < 768 ? '今天 —' : '—'),
        ),
        findsOneWidget,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(SessionDetail),
          matching: find.textContaining('不记录'),
        ),
        findsNothing,
      );
      final day = find.byKey(const Key('session-day-2026-11-09'));
      expect(
        find.descendant(of: day, matching: find.text('—')),
        findsNWidgets(2),
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('INTEG-FIX2 model filter tag can be removed', (tester) async {
    final fake = IntegrationSessionsGateway();
    await s.mountSessions(
      tester,
      fake,
      query: 'period=week&model=m',
      reduced: true,
    );
    final tag = find.byWidgetPredicate(
      (w) => w is FilterTag && w.label == '模型' && w.value == 'm',
    );
    expect(tag, findsOneWidget);
    await tester.tap(
      find.descendant(of: tag, matching: find.byTooltip('去掉模型筛选')),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(StatsPage));
    expect(Uri.splitQueryString(state.query).containsKey('model'), isFalse);
    expect(fake.pages.last.filter.model, isNull);
  });
  for (final scenario in ['period', 'legacy', 'unpriced']) {
    testWidgets('INTEG-FIX2 detail cost and cache scopes $scenario', (
      tester,
    ) async {
      await s.mountSessions(
        tester,
        IntegrationSessionsGateway()
          ..legacy = scenario == 'legacy'
          ..unpriced = scenario == 'unpriced',
        query: 'period=today',
        reduced: true,
      );
      await tester.tap(find.byKey(const Key('session-row-codex:i1')));
      await tester.pumpAndSettle();
      final labels = scenario == 'legacy' ? ['约值'] : ['今天约值', '累计约值'];
      for (final label in labels) {
        final cell = find.descendant(
          of: find.byType(SessionDetail),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Column &&
                w.children.any(
                  (child) => child is Text && child.data == label,
                ) &&
                w.children.any((child) => child is MoneyText),
          ),
        );
        expect(cell, findsOneWidget);
        final money = tester.widget<MoneyText>(
          find.descendant(of: cell, matching: find.byType(MoneyText)),
        );
        expect(
          money.value,
          label == '今天约值'
              ? (scenario == 'unpriced' ? null : '1.250000')
              : '5.000000',
        );
        if (label == '今天约值' && scenario == 'unpriced') {
          expect(
            find.descendant(of: cell, matching: find.text('未定价')),
            findsOneWidget,
          );
        }
      }
      final hit = find.byKey(const Key('session-hit'));
      expect(
        find.descendant(
          of: hit,
          matching: find.text(scenario == 'legacy' ? '缓存命中' : '今天缓存命中'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: hit,
          matching: find.text(scenario == 'legacy' ? '80%' : '25%'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('INTEG-FIX2 home mixed period uses lifetime request count', (
    tester,
  ) async {
    await f1.mountHome(
      tester,
      IntegrationSessionsGateway()..mixed = true,
      const StatsPeriod('today'),
    );
    expect(find.text('Codex · 本时段没有逐次请求'), findsOneWidget);
    expect(find.textContaining('只记录总数，算在开始那天'), findsNothing);
    expect(find.textContaining('不记录'), findsNothing);
  });
}
