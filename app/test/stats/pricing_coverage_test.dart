import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/settings_page.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';

class _PricingGateway extends FakeStatsGateway {
  _PricingGateway(this.unpriced, this.costMicros, this.records);

  final int unpriced, records;
  final int? costMicros;

  @override
  StatsTotals totals(StatsFilter filter) {
    final usage = super.totals(filter);
    return StatsTotals(
      grossTokens: usage.grossTokens,
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens,
      cacheReadTokens: usage.cacheReadTokens,
      cacheWriteTokens: usage.cacheWriteTokens,
      costUsd: costMicros == null ? null : (costMicros! / 1e6).toString(),
      costMicros: costMicros,
      unpricedRecords: unpriced,
      recordCount: records,
    );
  }
}

class _EmptyPeriodPricingGateway extends _PricingGateway {
  _EmptyPeriodPricingGateway() : super(0, null, 0) {
    empty = true;
  }

  @override
  Future<StatsSources> sources() => FakeStatsGateway().sources();
}

class _ModelPricingGateway extends _PricingGateway {
  _ModelPricingGateway() : super(2, 12000, 4);
  static const modelGroups = [
    StatsGroup(
      model: 'unknown-demo',
      source: 'claude',
      grossTokens: 40,
      inputTokens: 25,
      outputTokens: 15,
      unpricedRecords: 2,
      recordCount: 2,
      priceState: 'unknown',
    ),
    StatsGroup(
      model: 'manual-demo',
      source: 'codex',
      grossTokens: 60,
      inputTokens: 40,
      outputTokens: 20,
      unpricedRecords: 0,
      recordCount: 2,
      priceState: 'manual',
      costMicros: 12000,
    ),
  ];
  @override
  List<StatsGroup> groups(StatsFilter filter, {String by = 'source_model'}) =>
      by == 'source_model' ? modelGroups : super.groups(filter, by: by);

  @override
  Future<StatsPricing> pricing() async => const StatsPricing(
    priceVersion: 'fixture',
    currency: 'USD',
    provisional: false,
    models: [
      StatsModelPrice(
        model: 'unknown-demo',
        records: 2,
        state: 'unknown',
        billing: 'metered',
        localRecords: 0,
        localProviders: {},
        priceMarks: {},
      ),
      StatsModelPrice(
        model: 'manual-demo',
        records: 2,
        state: 'manual',
        billing: 'metered',
        localRecords: 0,
        localProviders: {},
        priceMarks: {},
        prices: StatsPrices(input: 1, output: 1),
      ),
    ],
    counts: StatsPriceCounts(
      verified: 0,
      aggregate: 0,
      unknown: 1,
      local: 0,
      manual: 1,
    ),
    snapshot: demoSnapshot,
  );
}

const _estimate = '按公开标准价估算，不是账单';
const _pricingHint = '没有价格的记录不计入金额。到「价格与设置」里查看是哪些模型。';

Future<void> _mount(
  WidgetTester tester,
  _PricingGateway gateway, {
  bool detail = false,
  String period = 'month',
}) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = StatsController(
    gateway,
    clock: () => demoNow,
    preferences: UiPreferences(
      period: StatsPeriod(period),
      onboarded: true,
      unitSystem: detail ? 'english' : 'chinese',
      autoCheckUpdates: false,
    ),
  );
  addTearDown(controller.dispose);
  await controller.load();
  await tester.pumpWidget(
    MaterialApp(
      theme: const LensPalette(false).theme,
      home: StatsPage(controller: controller),
    ),
  );
  if (detail) {
    await tester.tap(find.text('用量明细').first);
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('按模型明细显示两种价格入口并跳到第一个缺价模型', (tester) async {
    await _mount(tester, _ModelPricingGateway(), detail: true);
    expect(find.text('去补价格 ›'), findsNothing);
    final byModel = find.text('按模型');
    await tester.ensureVisible(byModel);
    await tester.tap(byModel);
    await tester.pumpAndSettle();
    expect(find.byTooltip('按你手填的价算'), findsOneWidget);
    final add = find.text('填写价格');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('照已有模型的价格填'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    final missing = find.text('去补价格 ›');
    await tester.ensureVisible(missing);
    await tester.tap(missing);
    await tester.pumpAndSettle();
    expect(find.byType(StatsSettingsPage), findsOneWidget);
    expect(find.text('知道它的价格的话，自己填上，这 2 条记录就有金额了。'), findsOneWidget);
  });

  const cases = [
    (
      name: '全有价格（零价也计价）',
      unpriced: 0,
      costMicros: 0,
      home: _estimate,
      detail: '按公开价估算',
    ),
    (
      name: '部分没有价格',
      unpriced: 1234,
      costMicros: 1040000,
      home: '按公开标准价估算，另有 1,234 条记录没有价格',
      detail: '按公开价估算 · 1,234 条未计价',
    ),
    (
      name: '全部没有价格',
      unpriced: 2000,
      costMicros: null,
      home: '这段时间用到的模型都还没有价格',
      detail: '还没有价格',
    ),
  ];

  for (final scenario in cases) {
    testWidgets('总览：${scenario.name}', (tester) async {
      await _mount(
        tester,
        _PricingGateway(scenario.unpriced, scenario.costMicros, 2000),
        period: 'all',
      );
      final note = find.text(scenario.home);
      expect(note, findsOneWidget);
      if (scenario.unpriced > 0) {
        expect(find.byTooltip(_pricingHint), findsOneWidget);
        await tester.tap(note);
        await tester.pumpAndSettle();
        expect(find.byType(StatsSettingsPage), findsOneWidget);
      } else {
        expect(find.byTooltip(_pricingHint), findsNothing);
      }
    });

    testWidgets('明细：${scenario.name}', (tester) async {
      await _mount(
        tester,
        _PricingGateway(scenario.unpriced, scenario.costMicros, 2000),
        detail: true,
      );
      expect(find.text(scenario.detail), findsOneWidget);
    });
  }

  testWidgets('总览有对比时，徽标和比较语在换算与约值之间', (tester) async {
    await _mount(tester, _PricingGateway(0, 1040000, 2000));
    final hero = find.byKey(const Key('home-hero'));
    final comparison = find.descendant(of: hero, matching: find.text('比上个月'));
    expect(comparison, findsOneWidget);
    final conversion = find.byKey(const Key('home-conversion'));
    final amount = find.descendant(of: hero, matching: find.text('约值 '));
    final badge = find.descendant(
      of: hero,
      matching: find.byIcon(Icons.arrow_upward),
    );
    expect(badge, findsOneWidget);
    for (final item in [comparison, badge]) {
      expect(
        tester.getTopLeft(item).dy,
        greaterThan(tester.getBottomLeft(conversion).dy),
      );
      expect(
        tester.getBottomLeft(item).dy,
        lessThan(tester.getTopLeft(amount).dy),
      );
    }
    expect(find.text(_estimate), findsOneWidget);
  });

  testWidgets('明细空期仍显示普通金额说明', (tester) async {
    await _mount(tester, _EmptyPeriodPricingGateway(), detail: true);
    expect(find.text('按公开价估算'), findsOneWidget);
    expect(find.text('还没有价格'), findsNothing);
  });
}
