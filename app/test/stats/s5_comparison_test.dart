import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/widgets/charts.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

import 'f1_polish_test.dart' show PolishGateway, mountPolish;

class ComparisonGateway extends PolishGateway
    implements StatsComparisonGateway {
  final calls = <String>[];
  bool similar = false, missingProject = false, decrease = false;

  @override
  Future<StatsComparison> comparison(
    String by,
    StatsFilter current,
    StatsFilter previous,
  ) async {
    calls.add(by);
    final keys = by == 'source'
        ? ['claude', 'codex', 'pi', 'grok', 'gemini', 'kimi']
        : [
            for (var i = 0; i < 6; i++)
              by == 'project' ? '/synthetic/project-$i' : 'model-$i',
          ];
    StatsComparisonSide side(List<int> counts, {required bool priced}) {
      final groups = [
        for (final (index, count) in counts.indexed)
          if (count > 0)
            StatsGroup(
              key: missingProject ? null : keys[index],
              grossTokens: count,
              recordCount: 1,
              costMicros: priced ? count * 1000 : null,
              unpricedRecords: priced ? 0 : 1,
            ),
      ];
      return StatsComparisonSide(
        totals: StatsTotals(
          grossTokens: counts.reduce((a, b) => a + b),
          recordCount: groups.length,
          costMicros: priced ? counts.reduce((a, b) => a + b) * 1000 : null,
          unpricedRecords: priced ? 0 : groups.length,
        ),
        groups: groups,
      );
    }

    final now = side([100, 90, 80, 70, 60, 0], priced: true);
    final then = side([10, 0, 10, 10, 10, similar ? 340 : 10], priced: false);
    return StatsComparison(
      by: by,
      current: decrease ? then : now,
      previous: decrease ? now : then,
    );
  }
}

void main() {
  testWidgets(
    'S5 attribution opens, switches dimensions and cost, expands and drills down',
    (tester) async {
      final gateway = ComparisonGateway();
      await mountPolish(
        tester,
        gateway: gateway,
        period: const StatsPeriod('last7'),
      );
      final link = find.text('看变化 →');
      expect(link, findsOneWidget);
      expect(find.textContaining('增加最多的是', findRichText: true), findsOneWidget);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.text('比上期变化在哪'), findsOneWidget);
      final expand = find.text('展开其余 1 项');
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(find.text('本期未用'), findsOneWidget);
      await tester.tap(find.text('按模型').last);
      await tester.pumpAndSettle();
      expect(gateway.calls.last, 'model');
      await tester.tap(find.text('按工具').last);
      await tester.pumpAndSettle();
      expect(gateway.calls.last, 'source');
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('comparison-metric')),
          matching: find.text('金额'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('含未定价'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('比上期变化在哪'), findsNothing);
      await tester.tap(link);
      await tester.pumpAndSettle();
      await tester.tap(find.text('project-0'));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(StatsPage)) as dynamic;
      final query = Uri.splitQueryString(state.query as String);
      expect(query, containsPair('project', '/synthetic/project-0'));
      expect(query, containsPair('period', 'last7'));
      expect(tester.takeException(), isNull);
    },
  );

  for (final (name, period, similar, missingProject, decrease, direction) in [
    ('less than 10%', 'last7', true, false, false, ''),
    ('missing project', 'last7', false, true, false, ''),
    ('without previous period', 'all', false, false, false, ''),
    ('decrease', 'last7', false, false, true, '减少最多的是'),
  ]) {
    testWidgets('S5 attribution sentence: $name', (tester) async {
      final gateway = ComparisonGateway()
        ..similar = similar
        ..missingProject = missingProject
        ..decrease = decrease;
      await mountPolish(tester, gateway: gateway, period: StatsPeriod(period));
      expect(find.textContaining('增加最多的是', findRichText: true), findsNothing);
      expect(
        find.textContaining('减少最多的是', findRichText: true),
        direction.isEmpty ? findsNothing : findsOneWidget,
      );
      if (period == 'all') expect(find.text('看变化 →'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('S5 detail compare is URL backed and disabled for all time', (
    tester,
  ) async {
    final gateway = ComparisonGateway();
    await mountPolish(
      tester,
      gateway: gateway,
      page: 'detail',
      query: 'period=all&dim=project',
    );
    final toggle = find.byKey(const Key('detail-compare'));
    expect(tester.widget<LensSwitch>(toggle).onChanged, isNull);
    final state = tester.state(find.byType(StatsPage)) as dynamic;
    state.navigate('detail', {'period': 'lastMonth', 'dim': 'project'});
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      Uri.splitQueryString(state.query as String),
      containsPair('compare', '1'),
    );
    expect(find.text('上期'), findsWidgets);
    expect(find.text('差额'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  for (final page in ['home', 'detail']) {
    testWidgets('S5 $page trend can switch its metric', (tester) async {
      await mountPolish(tester, gateway: ComparisonGateway(), page: page);
      final metric = find.byKey(const Key('trend-metric'));
      List<int> totals() => tester
          .widget<TrendChart>(find.byType(TrendChart))
          .buckets
          .map((bucket) => bucket.total)
          .toList();
      final usage = totals();
      final cost = find.descendant(of: metric, matching: find.text('金额'));
      final tokens = find.descendant(of: metric, matching: find.text('token'));
      expect(cost, findsOneWidget);
      await tester.ensureVisible(cost);
      await tester.tap(cost);
      await tester.pumpAndSettle();
      expect(totals(), isNot(usage));
      await tester.tap(tokens);
      await tester.pumpAndSettle();
      expect(totals(), usage);
      expect(tester.takeException(), isNull);
    });
  }
}
