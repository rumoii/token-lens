import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats/widgets/filters.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'f1_polish_test.dart' show mountPolish, singleLine, insideCard;
import 'fake_gateway.dart';

class SortGateway extends FakeStatsGateway {
  @override
  List<StatsGroup> groups(StatsFilter filter, {String by = 'source_model'}) =>
      by == 'project'
      ? [
          for (var i = 0; i < 3; i++)
            StatsGroup(
              key: '/synthetic/${['alpha', 'beta', 'gamma'][i]}',
              grossTokens: [300000, 200000, 100000][i],
              costMicros: [1000000, 3000000, 2000000][i],
              requestCount: [30, 10, 20][i],
              eventGrossTokens: [300000, 200000, 100000][i],
              inputTokens: [3000, 1000, 2000][i],
              outputTokens: [100, 300, 200][i],
              cacheReadTokens: [2000, 1000, 3000][i],
              cacheWriteTokens: [400, 300, 200][i],
              recordCount: 30,
              unpricedRecords: 0,
            ),
        ]
      : super.groups(filter, by: by);
  @override
  Future<StatsTimeseries> timeseries(
    String granularity,
    StatsFilter filter,
  ) async => StatsTimeseries(
    granularity: granularity,
    snapshot: demoSnapshot,
    points: [
      for (var i = 0; i < 3; i++)
        StatsBucket(
          bucket: '2026-11-0${7 + i}',
          grossTokens: [300000, 200000, 100000][i],
          costMicros: [1000000, 3000000, 2000000][i],
          recordCount: 30,
          unpricedRecords: 0,
        ),
    ],
  );
}

class ShareGateway extends FakeStatsGateway {
  @override
  List<StatsGroup> groups(StatsFilter filter, {String by = 'source_model'}) =>
      by == 'source'
      ? const [
          StatsGroup(
            key: 'claude',
            grossTokens: 996,
            recordCount: 1,
            unpricedRecords: 0,
          ),
          StatsGroup(
            key: 'codex',
            grossTokens: 4,
            recordCount: 1,
            unpricedRecords: 0,
          ),
        ]
      : super.groups(filter, by: by);
  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) async {
    if (by != 'source') return super.breakdown(by, filter);
    return StatsBreakdown(
      by: by,
      groups: groups(filter, by: by),
      totals: const StatsTotals(
        grossTokens: 1000,
        recordCount: 2,
        unpricedRecords: 0,
      ),
      snapshot: demoSnapshot,
    );
  }
}

class MetricsGateway extends FakeStatsGateway {
  @override
  List<StatsGroup> groups(StatsFilter filter, {String by = 'source_model'}) =>
      by == 'project'
      ? const [
          StatsGroup(
            key: '/synthetic/metrics',
            grossTokens: 123456,
            requestCount: 1234567,
            eventGrossTokens: 123456,
            costMicros: 123456789000,
            inputTokens: 1234,
            outputTokens: 12345,
            cacheReadTokens: 123456,
            cacheWriteTokens: 1234567,
            recordCount: 12,
            unpricedRecords: 0,
          ),
        ]
      : super.groups(filter, by: by);
}

List<String> projectOrder(WidgetTester tester) =>
    (['alpha', 'beta', 'gamma']..sort(
      (a, b) => tester
          .getTopLeft(find.byKey(Key('detail-row-/synthetic/$a')))
          .dy
          .compareTo(
            tester.getTopLeft(find.byKey(Key('detail-row-/synthetic/$b'))).dy,
          ),
    ));

Future<void> pickSort(WidgetTester tester, String label) async {
  final picker = find.byKey(const Key('detail-sort'));
  await tester.ensureVisible(picker);
  await tester.tap(picker, kind: PointerDeviceKind.mouse);
  await tester.pumpAndSettle();
  final popup = find.byType(LensMenu);
  final option = find.descendant(of: popup, matching: find.text(label));
  await tester.scrollUntilVisible(
    option,
    60,
    scrollable: find.descendant(of: popup, matching: find.byType(Scrollable)),
  );
  await tester.pumpAndSettle();
  await tester.tap(option, kind: PointerDeviceKind.mouse);
  await tester.pumpAndSettle();
}

class RetryingSourcesGateway extends FakeStatsGateway {
  RetryingSourcesGateway() {
    empty = true;
  }
  bool failSources = true;
  Completer<StatsSources>? pendingSources;
  @override
  Future<StatsSources> sources() async {
    if (failSources) throw StateError('Synthetic sources failure');
    return pendingSources?.future ?? super.sources();
  }
}

Finder get focusRings => find.byWidgetPredicate(
  (w) => w is CustomPaint && w.foregroundPainter is LensFocusRing,
);

void currentPeriodEmpty() {
  expect(find.text('今天还没有用量'), findsOneWidget);
  expect(find.text('看本月'), findsOneWidget);
  expect(find.text('看全部'), findsOneWidget);
  expect(find.text('还没有任何用量'), findsNothing);
}

void main() {
  for (final completelyEmpty in [false, true]) {
    testWidgets(
      'F1-R3-01 sources failure retry succeeds empty=$completelyEmpty',
      (tester) async {
        final gateway = RetryingSourcesGateway();
        final c = await mountPolish(tester, gateway: gateway);
        expect(c.resourceErrors, contains('sources'));
        currentPeriodEmpty();
        gateway.failSources = false;
        gateway.pendingSources = Completer<StatsSources>();
        final retry = c.load();
        await tester.pumpAndSettle();
        expect(c.loading, isTrue);
        expect(c.resourceErrors, contains('sources'));
        currentPeriodEmpty();
        gateway.pendingSources!.complete(
          await (FakeStatsGateway()..empty = completelyEmpty).sources(),
        );
        await retry;
        await tester.pumpAndSettle();
        if (completelyEmpty) {
          expect(find.text('还没有任何用量'), findsOneWidget);
          expect(find.text('看本月'), findsNothing);
          expect(find.text('看全部'), findsNothing);
        } else {
          currentPeriodEmpty();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final width in [1440.0, 1024.0, 720.0]) {
    testWidgets('F1-R3-03 project sorting works at $width', (tester) async {
      await mountPolish(
        tester,
        width: width,
        page: 'detail',
        query: 'period=month&dim=project',
        gateway: SortGateway(),
      );
      expect(projectOrder(tester), ['alpha', 'beta', 'gamma']);
      if (width == 1440) {
        await tester.tap(find.text('约值').last);
      } else {
        expect(find.byKey(const Key('detail-sort')), findsOneWidget);
        singleLine(tester, find.text('排序：用量'));
        insideCard(tester, find.byKey(const Key('detail-sort')));
        await pickSort(tester, '约值');
      }
      await tester.pumpAndSettle();
      expect(projectOrder(tester), ['beta', 'gamma', 'alpha']);
      if (width == 1440) {
        await tester.tap(find.text('约值 ↓'));
      } else {
        await tester.tap(find.byTooltip('从大到小'));
      }
      await tester.pumpAndSettle();
      expect(projectOrder(tester), ['alpha', 'gamma', 'beta']);
      if (width < 1440) {
        expect(find.byTooltip('从小到大'), findsOneWidget);
        await pickSort(tester, '请求');
        expect(projectOrder(tester), ['alpha', 'gamma', 'beta']);
        await pickSort(tester, '平均每次');
        expect(projectOrder(tester), ['beta', 'alpha', 'gamma']);
        expect(
          tester
              .widget<FilterPick>(find.byKey(const Key('detail-sort')))
              .options
              .map((o) => o.label),
          ['项目', '用量', '约值', '占比', '新输入', '输出', '读缓存', '写缓存', '请求', '平均每次'],
        );
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets('F1-R3-04 sidebar retains boundary percentages at $width', (
      tester,
    ) async {
      await mountPolish(tester, width: width, gateway: ShareGateway());
      if (width < 768) {
        await tester.tap(
          find.byTooltip('打开导航菜单'),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
      }
      for (final label in ['99.6%', '0.4%']) {
        final side = find.byWidgetPredicate(
          (w) => w is Text && w.data == label && (w.style?.fontSize == 12),
        );
        expect(side, findsOneWidget);
        singleLine(tester, side);
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'F1-R3-05 status separators attach to preceding item at $width',
      (tester) async {
        await mountPolish(tester, width: width, page: 'sources');
        for (final element in find.text('状态').evaluate()) {
          final row = find
              .ancestor(
                of: find.byWidget(element.widget),
                matching: find.byType(Row),
              )
              .first;
          expect(
            find.descendant(
              of: row,
              matching: find.textContaining(RegExp(r'^\s*·\s+\S')),
            ),
            findsNothing,
          );
          final wrap = tester.widget<Wrap>(
            find.descendant(of: row, matching: find.byType(Wrap)).first,
          );
          final origin = find.byWidget(wrap.children.first);
          final separator = find.descendant(
            of: origin,
            matching: find.text(' · '),
          );
          final badge = find.descendant(
            of: origin,
            matching: find.text('只用样例日志核对过'),
          );
          expect(
            tester.getTopLeft(separator).dx,
            greaterThanOrEqualTo(tester.getTopRight(badge).dx),
          );
          expect(
            tester.getCenter(separator).dy,
            closeTo(tester.getCenter(badge).dy, 1),
          );
          for (final label in ['每次请求都有记录 · ', '记录完整 · ', '自检正常']) {
            final unit = find.descendant(of: row, matching: find.text(label));
            expect(unit, findsOneWidget);
            singleLine(tester, unit);
            insideCard(tester, unit);
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'F1-R3-06 compact metrics end with at least two items at $width',
      (tester) async {
        await mountPolish(
          tester,
          width: width,
          page: 'detail',
          query: 'period=month&dim=project',
          gateway: MetricsGateway(),
        );
        final row = find.byKey(const Key('detail-row-/synthetic/metrics'));
        final metrics = [
          for (final label in [
            '约值 ',
            '1,234,567 次请求',
            '平均每次 ',
            '占 100%',
            '新输入 ',
            '输出 ',
            '读缓存 ',
            '写缓存 ',
          ])
            find.descendant(of: row, matching: find.text(label)),
        ];
        if (width < 1440) {
          final positions = [
            for (final metric in metrics) tester.getTopLeft(metric).dy,
          ];
          debugPrint('F1-R3-06 $width metric positions: $positions');
          final last = positions.reduce((a, b) => a > b ? a : b);
          expect(
            positions.where((y) => (y - last).abs() < 1).length,
            greaterThanOrEqualTo(2),
            reason: '$positions',
          );
          for (final metric in metrics) {
            singleLine(tester, metric);
            insideCard(tester, metric);
          }
        }
        insideCard(tester, row);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'F1-R3-02 mouse opens session without autofocus outline at $width',
      (tester) async {
        await mountPolish(tester, width: width, page: 'sessions');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(focusRings, findsWidgets);
        final row = find.byKey(const Key('session-row-claude:polish'));
        await tester.ensureVisible(row);
        await tester.tap(row, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus!.hasFocus, isTrue);
        expect(find.byTooltip('关闭'), findsOneWidget);
        expect(focusRings, findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(focusRings, findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('F1-R3-03 sorting survives wide compact wide resize', (
    tester,
  ) async {
    await mountPolish(
      tester,
      page: 'detail',
      query: 'period=month&dim=project',
      gateway: SortGateway(),
    );
    await tester.tap(find.text('约值').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('约值 ↓'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1024, 3000);
    await tester.pumpAndSettle();
    expect(find.text('排序：约值'), findsOneWidget);
    expect(find.byTooltip('从小到大'), findsOneWidget);
    expect(projectOrder(tester), ['alpha', 'gamma', 'beta']);
    tester.view.physicalSize = const Size(1440, 3000);
    await tester.pumpAndSettle();
    expect(find.text('约值 ↑'), findsOneWidget);
    expect(projectOrder(tester), ['alpha', 'gamma', 'beta']);
    expect(tester.takeException(), isNull);
  });
  testWidgets('F1-R3-03 compact dates sort by cost and direction', (
    tester,
  ) async {
    await mountPolish(
      tester,
      width: 1024,
      page: 'detail',
      query: 'period=month&dim=date',
      gateway: SortGateway(),
    );
    List<int> order() => [7, 8, 9]
      ..sort(
        (a, b) => tester
            .getTopLeft(find.byKey(Key('detail-row-2026-11-0$a')))
            .dy
            .compareTo(
              tester.getTopLeft(find.byKey(Key('detail-row-2026-11-0$b'))).dy,
            ),
      );
    expect(order(), [9, 8, 7]);
    await pickSort(tester, '约值');
    expect(order(), [8, 9, 7]);
    await tester.tap(find.byTooltip('从大到小'));
    await tester.pumpAndSettle();
    expect(order(), [7, 9, 8]);
    expect(tester.takeException(), isNull);
  });
  testWidgets('F1-R3-02 pointer outside button clears ring while focus stays', (
    tester,
  ) async {
    final routes = GestureBinding.instance.pointerRouter.debugGlobalRouteCount;
    final strategy = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy = strategy);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              LensFocusOutline(
                child: TextButton(
                  onPressed: () {},
                  child: const Text('Focus target'),
                ),
              ),
              LensFocusOutline(
                child: TextButton(
                  onPressed: () {},
                  child: const Text('Second target'),
                ),
              ),
              GestureDetector(
                onTap: () {},
                child: const SizedBox(
                  width: 300,
                  height: 100,
                  child: Text('Outside target'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      GestureBinding.instance.pointerRouter.debugGlobalRouteCount,
      routes + 1,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus;
    expect(focusRings, findsWidgets);
    await tester.tap(
      find.text('Outside target'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, focused);
    expect(focusRings, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focusRings, findsWidgets);
    tester.binding.handlePointerEvent(
      const PointerPanZoomStartEvent(
        pointer: 5,
        device: 5,
        position: Offset(200, 100),
      ),
    );
    await tester.pumpAndSettle();
    expect(focusRings, findsNothing);
    tester.binding.handlePointerEvent(
      const PointerPanZoomEndEvent(
        pointer: 5,
        device: 5,
        position: Offset(200, 100),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(focusRings, findsWidgets);
    await tester.tap(
      find.text('Outside target'),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();
    expect(focusRings, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(GestureBinding.instance.pointerRouter.debugGlobalRouteCount, routes);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(tester.takeException(), isNull);
  });
}
