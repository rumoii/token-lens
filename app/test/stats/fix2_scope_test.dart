import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/stats/sessions_page.dart';

import 'fake_gateway.dart';
import 'sessions_page_test.dart' as s;

class FilterScopeGateway extends s.SessionsGateway {
  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) async {
    pages.add((filter: filter, limit: limit, cursor: cursor));
    return const StatsSessions(
      items: [
        StatsSessionItem(
          source: 'codex',
          sessionId: 'cross-project',
          projectKey: null,
          startedAt: '2026-11-01T05:00:00Z',
          lastSeenAt: '2026-11-09T06:00:00Z',
          grossTokens: 10,
          eventGrossTokens: 10,
          recordCount: 1,
          requestCount: 1,
          unpricedRecords: 0,
          hasCumulative: false,
          cumulative: StatsTotals(
            grossTokens: 110,
            eventGrossTokens: 110,
            recordCount: 2,
            requestCount: 2,
            unpricedRecords: 0,
          ),
        ),
      ],
      snapshot: demoSnapshot,
    );
  }
}

void main() {
  for (final width in [720.0, 1440.0]) {
    for (final filter in ['project', 'tool', 'model']) {
      testWidgets('FIX2 all + $filter shows 累计 110 at $width', (tester) async {
        final fake = FilterScopeGateway();
        final value = filter == 'tool'
            ? 'codex'
            : filter == 'project'
            ? 'C:/demo'
            : 'model-a';
        final query = Uri(queryParameters: {'period': 'all', filter: value})
            .query;
        await s.mountSessions(
          tester,
          fake,
          width: width,
          query: query,
          reduced: true,
        );
        final row = find.byKey(const Key('session-row-codex:cross-project'));
        if (width < 768) {
          expect(
            find.descendant(of: row, matching: find.textContaining('累计 110')),
            findsOneWidget,
          );
          expect(find.text('筛选后约值 '), findsOneWidget);
        } else {
          // Header and its numeric cell together display 累计 110.
          expect(find.text('累计'), findsOneWidget);
          expect(
            find.descendant(of: row, matching: find.text('110')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byKey(const Key('sessions-header-tokens')),
              matching: find.text('筛选后用量'),
            ),
            findsOneWidget,
          );
          expect(find.text('筛选后请求'), findsOneWidget);
          expect(find.text('累计请求'), findsOneWidget);
          expect(find.text('筛选后约值'), findsOneWidget);
        }
        final sent = fake.pages.last.filter;
        expect(switch (filter) {
          'project' => sent.project,
          'tool' => sent.source,
          _ => sent.model,
        }, value);
        expect(sent.from, isNull);
        expect(sent.to, isNull);
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('FIX2 all without filters keeps original columns at $width', (
      tester,
    ) async {
      await s.mountSessions(
        tester,
        FilterScopeGateway(),
        width: width,
        query: 'period=all&tool=&project=&model=',
        reduced: true,
      );
      expect(find.textContaining('累计 110'), findsNothing);
      expect(find.text('累计请求'), findsNothing);
      expect(find.text('筛选后用量'), findsNothing);
      if (width >= 768) {
        expect(
          find.descendant(
            of: find.byKey(const Key('sessions-header-tokens')),
            matching: find.text('全部用量'),
          ),
          findsOneWidget,
        );
        for (final label in ['时长', '约值', '请求']) {
          expect(
            find.descendant(
              of: find.byType(StatsSessionsPage),
              matching: find.text(label),
            ),
            findsOneWidget,
          );
        }
        expect(find.text('累计'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
