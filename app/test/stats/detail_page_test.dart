import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';

class DetailGateway extends FakeStatsGateway {
  final reads = <({String method, StatsFilter filter})>[];
  List<StatsGroup>? modelGroups;
  @override
  Future<StatsSummary> summary(StatsFilter filter) {
    reads.add((method: 'summary', filter: filter));
    return super.summary(filter);
  }

  @override
  Future<StatsMatrix> matrix(
    String granularity,
    String by,
    StatsFilter filter,
  ) {
    reads.add((method: 'matrix', filter: filter));
    return super.matrix(granularity, by, filter);
  }

  @override
  Future<StatsTimeseries> timeseries(String granularity, StatsFilter filter) {
    reads.add((method: 'timeseries:$granularity', filter: filter));
    return super.timeseries(granularity, filter);
  }

  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) async {
    reads.add((method: 'breakdown:$by', filter: filter));
    final result = await super.breakdown(by, filter);
    return by == 'source_model' && modelGroups != null
        ? StatsBreakdown(
            by: by,
            groups: modelGroups!,
            totals: result.totals,
            snapshot: result.snapshot,
          )
        : result;
  }
}

Future<StatsController> mountDetail(
  WidgetTester tester,
  DetailGateway fake, {
  String query = 'period=month&view=detail',
  double width = 1440,
  bool dark = false,
  bool reduced = false,
}) async {
  tester.view.physicalSize = Size(width, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = StatsController(
    fake,
    clock: () => demoNow,
    preferences: UiPreferences(period: StatsPeriod.parse(query)),
  );
  addTearDown(c.dispose);
  await c.load();
  fake.reads.clear();
  await tester.pumpWidget(
    MaterialApp(
      theme: LensPalette(dark).theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: StatsPage(controller: c),
    ),
  );
  (tester.state(find.byType(StatsPage)) as dynamic).navigate(
    'detail',
    Uri.splitQueryString(query),
  );
  await tester.pumpAndSettle();
  return c;
}

Map<String, String> pageQuery(WidgetTester tester) => Uri.splitQueryString(
  (tester.state(find.byType(StatsPage)) as dynamic).query as String,
);
void main() {
  testWidgets('DetailView 地址筛选进入请求，可去掉标签', (tester) async {
    final fake = DetailGateway();
    await mountDetail(
      tester,
      fake,
      query: 'period=month&view=detail&tool=dsh&dim=tool',
    );
    expect(find.text('明细').first, findsOneWidget);
    expect(find.byTooltip('去掉工具筛选'), findsOneWidget);
    expect(
      fake.reads
          .where((r) => r.method == 'summary')
          .every((r) => r.filter.source == 'dsh'),
      isTrue,
    );
    expect(
      fake.reads
          .where((r) => r.method == 'matrix')
          .every((r) => r.filter.source == 'dsh'),
      isTrue,
    );
    await tester.tap(find.byTooltip('去掉工具筛选'));
    await tester.pumpAndSettle();
    expect(pageQuery(tester)['tool'], isNull);
    expect(pageQuery(tester)['view'], 'detail');
  });
  testWidgets('DetailView 未定价；点行增加筛选并换拆法', (tester) async {
    await mountDetail(
      tester,
      DetailGateway(),
      query: 'period=month&view=detail&dim=tool',
    );
    expect(find.text('未定价'), findsWidgets);
    await tester.tap(find.byKey(const Key('detail-row-codex')));
    await tester.pumpAndSettle();
    expect(pageQuery(tester)['tool'], 'codex');
    expect(pageQuery(tester)['dim'], 'model');
  });
  testWidgets('DetailView 时间拆分的跨桶快照独立说明', (tester) async {
    await mountDetail(tester, DetailGateway());
    expect(find.textContaining('不在这张表里'), findsOneWidget);
  });
  for (final partial in [false, true]) {
    testWidgets('DetailView 模型聚合 NULL 分项 partial=$partial', (tester) async {
      final fake = DetailGateway()
        ..modelGroups = [
          StatsGroup(
            source: 'dsh',
            model: 'same-model',
            grossTokens: 100,
            inputTokens: 100,
            cacheWriteTokens: partial ? 0 : null,
            unpricedRecords: 1,
            recordCount: 1,
          ),
          StatsGroup(
            source: 'codex',
            model: 'same-model',
            grossTokens: 100,
            outputTokens: partial ? 50 : null,
            cacheWriteTokens: partial ? 0 : null,
            unpricedRecords: 1,
            recordCount: 1,
          ),
        ];
      await mountDetail(
        tester,
        fake,
        query: 'period=month&view=detail&dim=model',
      );
      final row = find.byKey(const Key('detail-row-same-model'));
      expect(
        find.descendant(of: row, matching: find.text('100')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('—')),
        findsNWidgets(partial ? 1 : 3),
      );
      if (partial) {
        expect(
          find.descendant(of: row, matching: find.text('50')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.text('0')),
          findsOneWidget,
        );
      }
    });
  }
  testWidgets('DetailView 周期切换保留工具，清掉旧时段', (tester) async {
    await mountDetail(
      tester,
      DetailGateway(),
      query: 'period=week&view=detail&tool=dsh&bucket=2026-11-09&dim=tool',
    );
    await tester.tap(find.text('本月'));
    await tester.pumpAndSettle();
    expect(pageQuery(tester)['period'], 'month');
    expect(pageQuery(tester)['tool'], 'dsh');
    expect(pageQuery(tester)['bucket'], isNull);
  });
  for (final entry in [
    ('2026-08', '2026-08-15', '2026-08-31'),
    ('2026-11', '2026-11-01', '2026-11-04'),
  ]) {
    testWidgets('DetailView 自定义周期 ${entry.$1} 取交集', (tester) async {
      final fake = DetailGateway();
      await mountDetail(
        tester,
        fake,
        query:
            'period=custom&from=2026-08-15&to=2026-11-04&view=detail&bucket=${entry.$1}&dim=tool',
      );
      final scoped = fake.reads.where(
        (r) => ['summary', 'breakdown:source'].contains(r.method),
      );
      expect(scoped, isNotEmpty);
      expect(
        scoped.every(
          (r) => r.filter.from == entry.$2 && r.filter.to == entry.$3,
        ),
        isTrue,
      );
      expect(
        fake.reads
            .where((r) => r.method == 'matrix')
            .every(
              (r) =>
                  r.filter.from == '2026-08-15' && r.filter.to == '2026-11-04',
            ),
        isTrue,
      );
    });
  }
  testWidgets('DetailView 非法桶不加标签；概览切回总览', (tester) async {
    final fake = DetailGateway();
    await mountDetail(
      tester,
      fake,
      query: 'period=custom&from=2026-08-15&to=2026-11-04&view=detail&bucket=garbage',
    );
    expect(find.byTooltip('去掉时间筛选'), findsNothing);
    expect(find.textContaining('不在这张表里'), findsOneWidget);
    for (final method in ['summary', 'timeseries:month']) {
      final reads = fake.reads.where((r) => r.method == method);
      expect(reads, isNotEmpty);
      expect(
        reads.every(
          (r) => r.filter.from == '2026-08-15' && r.filter.to == '2026-11-04',
        ),
        isTrue,
      );
    }
    await tester.tap(find.text('概览'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-hero')), findsOneWidget);
  });
}
