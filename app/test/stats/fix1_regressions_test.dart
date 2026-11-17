import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/sessions_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats/widgets/session_usage.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'detail_page_test.dart' as d;
import 'sessions_page_test.dart' as s;
import 'fake_gateway.dart';

class FilteredSessionGateway extends s.SessionsGateway {
  StatsFilter? detailFilter;
  @override
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity, {
    StatsFilter filter = const StatsFilter(),
  }) {
    detailFilter = filter;
    return Future.value(
      StatsSessionDetail(
        session: StatsSessionSummary(
          source: source,
          sessionId: sessionId,
          startedAt: '2026-11-09T05:00:00Z',
          lastSeenAt: '2026-11-09T06:00:00Z',
          grossTokens: 200,
          requestCount: 2,
          recordCount: 2,
          unpricedRecords: 0,
        ),
        period: StatsTotals(
          grossTokens: filter.project == 'C:/demo' ? 42 : 200,
          requestCount: 1,
          recordCount: 1,
          unpricedRecords: 0,
        ),
        models: const [],
        timeline: const [],
        kinds: const StatsSessionKinds(event: 2, cumulative: 0),
        granularity: granularity,
        snapshot: demoSnapshot,
      ),
    );
  }
}

class HistoricalGateway extends FakeStatsGateway {
  HistoricalGateway({this.start = '2026-11-09T12:00:00Z', this.offset = -300});
  final String start;
  final int offset;
  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) async => StatsSessions(
    items: [
      StatsSessionItem(
        source: 'codex',
        sessionId: 'history',
        startedAt: start,
        lastSeenAt: '2026-11-12T14:00:00Z',
        grossTokens: 100,
        recordCount: 1,
        unpricedRecords: 0,
        hasCumulative: false,
        requestCount: 1,
        cumulative: const StatsTotals(
          grossTokens: 200,
          recordCount: 2,
          requestCount: 2,
          unpricedRecords: 0,
        ),
      ),
    ],
    snapshot: StatsSnapshot(
      generatedAt: '',
      priceVersion: '',
      tz: 'test',
      filters: StatsAppliedFilter(
        from: filter.from ?? '',
        to: filter.to ?? '',
        offsetMinutes: offset,
      ),
    ),
  );
}

Future<void> mountHome(
  WidgetTester tester,
  FakeStatsGateway fake,
  StatsPeriod period,
) async {
  tester.view.physicalSize = const Size(1600, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = StatsController(
    fake,
    clock: () => demoNow,
    preferences: UiPreferences(onboarded: true, period: period),
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
}

void main() {
  testWidgets('FIX1-1 mixed event/snapshot average excludes snapshot gross', (
    tester,
  ) async {
    final fake = d.DetailGateway()
      ..modelGroups = const [
        StatsGroup(
          key: 'mixed',
          model: 'mixed',
          source: 'codex',
          grossTokens: 1100,
          eventGrossTokens: 100,
          requestCount: 1,
          recordCount: 2,
          unpricedRecords: 0,
        ),
      ];
    await d.mountDetail(
      tester,
      fake,
      query: 'period=month&view=detail&dim=model',
    );
    final row = find.byKey(const Key('detail-row-mixed'));
    final cells = tester
        .widgetList<TokenText>(
          find.descendant(of: row, matching: find.byType(TokenText)),
        )
        .toList();
    expect(cells.last.value, 100);
  });
  testWidgets(
    'FIX1-1 merged sources and snapshots retain event-only numerator',
    (tester) async {
      final fake = d.DetailGateway()
        ..modelGroups = const [
          StatsGroup(
            key: 'mixed',
            model: 'mixed',
            source: 'codex',
            grossTokens: 1100,
            eventGrossTokens: 100,
            requestCount: 1,
            recordCount: 2,
            unpricedRecords: 0,
          ),
          StatsGroup(
            key: 'mixed',
            model: 'mixed',
            source: 'claude',
            grossTokens: 50,
            eventGrossTokens: 50,
            requestCount: 2,
            recordCount: 2,
            unpricedRecords: 0,
          ),
          StatsGroup(
            key: 'mixed',
            model: 'mixed',
            source: 'dsh',
            grossTokens: 900,
            eventGrossTokens: 0,
            recordCount: 1,
            unpricedRecords: 0,
          ),
        ];
      await d.mountDetail(
        tester,
        fake,
        query: 'period=month&view=detail&dim=model',
      );
      final row = find.byKey(const Key('detail-row-mixed'));
      final cells = tester
          .widgetList<TokenText>(
            find.descendant(of: row, matching: find.byType(TokenText)),
          )
          .toList();
      expect(cells.first.value, 2050);
      expect(cells.last.value, 50);
    },
  );
  testWidgets('FIX1-2 detail retains list tool/project/time filter', (
    tester,
  ) async {
    final fake = FilteredSessionGateway();
    await s.mountSessions(
      tester,
      fake,
      query: 'period=today&tool=codex&project=C%3A%2Fdemo',
    );
    final list = fake.pages.last.filter;
    await tester.tap(find.byKey(const Key('session-row-codex:s1')));
    await tester.pumpAndSettle();
    expect(fake.detailFilter!.project, list.project);
    expect(fake.detailFilter!.source, list.source);
    expect(fake.detailFilter!.from, list.from);
    expect(fake.detailFilter!.to, list.to);
    expect(find.textContaining('不受筛选影响'), findsOneWidget);
    final totals = tester
        .widgetList<TokenText>(
          find.descendant(
            of: find.byType(SessionDetail),
            matching: find.byType(TokenText),
          ),
        )
        .take(2)
        .map((w) => w.value)
        .toList();
    expect(totals, [42, 200]);
  });
  testWidgets(
    'FIX1-3 history period shows differing lifetime even if start is inside',
    (tester) async {
      await mountHome(
        tester,
        HistoricalGateway(),
        const StatsPeriod('custom', '2026-11-09', '2026-11-09'),
      );
      expect(find.text('累计 200'), findsOneWidget);
      expect(find.textContaining('开始于 '), findsNothing);
    },
  );
  testWidgets('FIX1-5 start chip uses query fixed offset', (tester) async {
    // At +14:00 this is November 9; a -05:00 host still sees November 8.
    await mountHome(
      tester,
      HistoricalGateway(start: '2026-11-08T12:30:00Z', offset: 840),
      const StatsPeriod('today'),
    );
    expect(find.textContaining('开始于 '), findsNothing);
  });
  testWidgets('FIX1-6 start chip includes previous year', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: const LensPalette(false).theme,
        home: Scaffold(
          body: SessionStartChip(
            startedAt: '2025-12-15T12:00:00Z',
            now: DateTime.utc(2026, 11, 9),
            offsetMinutes: 0,
          ),
        ),
      ),
    );
    expect(find.text('开始于 2025年12月15日'), findsOneWidget);
  });
  test('FIX1-5 fixed offset keeps summer start in the query day', () {
    expect(
      sessionStartedBefore(
        '2026-07-01T04:30:00Z',
        const StatsPeriod('custom', '2026-07-01', '2026-07-01'),
        DateTime.utc(2026, 11, 9),
        offsetMinutes: -300,
      ),
      isTrue,
    );
    expect(
      sessionStartedBefore(
        '2026-07-01T04:30:00Z',
        const StatsPeriod('custom', '2026-07-01', '2026-07-01'),
        DateTime.utc(2026, 11, 9),
        offsetMinutes: -240,
      ),
      isFalse,
    );
  });
}
