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
    await _mount(
      tester,
      _PricingGateway(0, null, 0)..empty = true,
      detail: true,
    );
    expect(find.text('按公开价估算'), findsOneWidget);
    expect(find.text('还没有价格'), findsNothing);
  });
}
