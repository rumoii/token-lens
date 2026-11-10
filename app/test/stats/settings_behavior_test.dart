import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/exchange_rate.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/settings_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats/widgets/settings_display.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'settings_pricing_test.dart' show SettingsGateway, model, showSettings;
import 'fake_gateway.dart' show demoSnapshot;

class SettingsStore extends PreferencesStore {
  SettingsStore() : super(Directory.systemTemp);
  final saved = <UiPreferences>[];
  @override
  Future<bool> write(UiPreferences preferences) async {
    saved.add(preferences);
    return true;
  }
}

class DelayedSettingsGateway extends SettingsGateway {
  DelayedSettingsGateway() : super([model('initial')]);
  final pending = <Completer<StatsPricing>>[];
  @override
  Future<StatsPricing> pricing() =>
      pending.isEmpty ? super.pricing() : pending.removeAt(0).future;
}

StatsPricing priceFixture(String name) => StatsPricing(
  priceVersion: name,
  currency: 'USD',
  provisional: false,
  models: [model(name)],
  counts: const StatsPriceCounts(
    verified: 1,
    aggregate: 0,
    unknown: 0,
    local: 0,
  ),
  snapshot: demoSnapshot,
);

Future<StatsController> showRateSettings(
  WidgetTester t,
  ExchangeRateRequest request, {
  PreferencesStore? store,
  bool reduced = false,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(1100, 2000);
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final c = StatsController(
    SettingsGateway([model('fixture')]),
    store: store,
    preferences: const UiPreferences(
      rates: {'USD': 1, 'CNY': 7.2},
      rateSource: 'fetched',
      ratesFetchedAt: 1000,
    ),
    clock: () => DateTime.fromMillisecondsSinceEpoch(1794182400000),
  );
  addTearDown(c.dispose);
  await t.pumpWidget(
    MaterialApp(
      theme: const LensPalette(false).theme,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            size: const Size(1100, 2000),
            disableAnimations: reduced,
          ),
          child: SettingsExchangeScope(
            request: request,
            child: SingleChildScrollView(
              child: StatsSettingsPage(controller: c),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('刷新保留旧数据，忽略过期结果；health 不随账本刷新；销毁后不通知', (t) async {
    final g = DelayedSettingsGateway();
    final c = await showSettings(t, g);
    final old = Completer<StatsPricing>(), newest = Completer<StatsPricing>();
    g.pending.add(old);
    c.reloadLedger();
    await t.pump();
    expect(find.text('initial'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsWidgets);
    g.pending.add(newest);
    c.reloadLedger();
    await t.pump();
    newest.complete(priceFixture('latest'));
    await t.pumpAndSettle();
    expect(find.text('latest'), findsOneWidget);
    expect(find.text('initial'), findsNothing);
    old.complete(priceFixture('stale'));
    await t.pumpAndSettle();
    expect(find.text('latest'), findsOneWidget);
    expect(find.text('stale'), findsNothing);
    expect(g.healthReads, 1);
    final late = Completer<StatsPricing>();
    g.pending.add(late);
    c.reloadLedger();
    await t.pump();
    await t.pumpWidget(const SizedBox());
    late.complete(priceFixture('disposed'));
    await t.pump();
    expect(t.takeException(), isNull);
  });
  testWidgets('数字单位立即更新累计用量，币种不转换 USD 单价，不重复查询', (t) async {
    final g = SettingsGateway([
      model('precise', prices: const StatsPrices(input: .125, output: 2)),
    ]);
    g.usage = [
      const StatsGroup(
        model: 'precise',
        grossTokens: 1200000,
        unpricedRecords: 0,
        recordCount: 1,
      ),
    ];
    await showSettings(t, g);
    expect(find.text('1.2M'), findsOneWidget);
    await t.tap(find.text('万 / 亿'));
    await t.pumpAndSettle();
    expect(find.text('120万'), findsOneWidget);
    await t.tap(find.text('人民币 ¥'));
    await t.pumpAndSettle();
    expect(find.text(r'输入 $0.125 · 输出 $2'), findsOneWidget);
    expect(g.priceReads, 1);
    expect(g.usageReads, 1);
    expect(g.healthReads, 1);
  });
  testWidgets('减少动态效果时请求中无循环动效', (t) async {
    final pending = Completer<ExchangeRateResponse>();
    await showRateSettings(t, (_, _) => pending.future, reduced: true);
    await t.tap(find.text('更新汇率'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('更新中…'), findsOneWidget);
    expect(t.binding.hasScheduledFrame, false);
    pending.complete(const ExchangeRateResponse(200, '{"rates":{"CNY":8}}'));
    await t.pumpAndSettle();
    expect(t.binding.hasScheduledFrame, false);
  });
  testWidgets('只点击更新才请求，重复点击合并，成功持久化且保留同期偏好', (t) async {
    final store = SettingsStore();
    final response = Completer<ExchangeRateResponse>();
    var calls = 0;
    final c = await showRateSettings(t, (_, _) {
      calls++;
      return response.future;
    }, store: store);
    expect(calls, 0);
    expect(find.textContaining('1 美元 ≈ 7.20 元'), findsOneWidget);
    Future<void> select(String label, {bool settle = true}) async {
      await t.tap(find.text(label));
      if (settle) {
        await t.pumpAndSettle();
      } else {
        await t.pump();
      }
    }

    await select('人民币 ¥');
    expect(calls, 0);
    expect(c.preferences.currency, 'CNY');
    await select('深色');
    await select('K / M / B');
    expect(c.preferences.appearance, 'dark');
    expect(c.preferences.unitSystem, 'english');
    final savedBefore = store.saved.last;
    expect(savedBefore.appearance, 'dark');
    expect(savedBefore.unitSystem, 'english');
    expect(savedBefore.currency, 'CNY');
    await t.tap(find.text('更新汇率'));
    await t.pump();
    expect(calls, 1);
    expect(find.text('更新中…'), findsOneWidget);
    final busy = t.widget<LensButton>(find.widgetWithText(LensButton, '更新中…'));
    expect(busy.onPressed, isNull);
    await t.tap(find.text('更新中…'));
    await t.pump();
    expect(calls, 1);
    await select('万 / 亿', settle: false);
    response.complete(
      const ExchangeRateResponse(200, '{"rates":{"CNY":8.25,"EUR":3}}'),
    );
    await t.pumpAndSettle();
    expect(c.preferences.rates, {'USD': 1, 'CNY': 8.25});
    expect(c.preferences.rateSource, 'fetched');
    expect(c.preferences.ratesFetchedAt, 1794182400000);
    expect(c.preferences.unitSystem, 'chinese');
    expect(c.preferences.currency, 'CNY');
    expect(find.textContaining('1 美元 ≈ 8.25 元'), findsOneWidget);
    final saved = store.saved.last;
    expect(saved.rates['CNY'], 8.25);
    expect(saved.rateSource, 'fetched');
    expect(saved.ratesFetchedAt, 1794182400000);
    expect(saved.unitSystem, 'chinese');
    expect(find.textContaining('汇率更新失败：'), findsNothing);
  });
  testWidgets('失败保留汇率与时间，显示原因，点击重试后成功', (t) async {
    var calls = 0;
    final c = await showRateSettings(t, (_, _) async {
      calls++;
      return calls == 1
          ? const ExchangeRateResponse(503, '{}')
          : const ExchangeRateResponse(200, '{"rates":{"CNY":7.8}}');
    });
    await t.tap(find.text('更新汇率'));
    await t.pumpAndSettle();
    expect(c.preferences.rates['CNY'], 7.2);
    expect(c.preferences.ratesFetchedAt, 1000);
    expect(
      find.textContaining('汇率更新失败：Exchange service returned HTTP 503.'),
      findsOneWidget,
    );
    await t.tap(find.text('更新汇率'));
    await t.pumpAndSettle();
    expect(calls, 2);
    expect(c.preferences.rates['CNY'], 7.8);
    expect(find.textContaining('汇率更新失败：'), findsNothing);
  });
  testWidgets('超时取消，销毁取消，晚到结果不落盘', (t) async {
    final pending = <Completer<ExchangeRateResponse>>[];
    final tokens = <ExchangeRateCancellation>[];
    final c = await showRateSettings(t, (_, token) {
      tokens.add(token);
      final next = Completer<ExchangeRateResponse>();
      pending.add(next);
      return next.future;
    });
    await t.tap(find.text('更新汇率'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 4999));
    expect(tokens.first.cancelled, false);
    await t.pump(const Duration(milliseconds: 1));
    expect(tokens.first.cancelled, true);
    expect(find.textContaining('汇率更新失败：'), findsOneWidget);
    pending.first.complete(
      const ExchangeRateResponse(200, '{"rates":{"CNY":9}}'),
    );
    await t.pump();
    expect(c.preferences.rates['CNY'], 7.2);
    await t.tap(find.text('更新汇率'));
    await t.pump();
    await t.pumpWidget(const SizedBox());
    expect(tokens.last.cancelled, true);
    pending.last.complete(
      const ExchangeRateResponse(200, '{"rates":{"CNY":10}}'),
    );
    await t.pump();
    expect(c.preferences.rates['CNY'], 7.2);
    expect(t.takeException(), isNull);
  });
  testWidgets('health 失败可重试，内容默认折叠', (t) async {
    final g = SettingsGateway([model('fixture')])..healthFails = true;
    await showSettings(t, g);
    expect(g.healthReads, 1);
    expect(find.text('/synthetic-preview'), findsNothing);
    await t.tap(find.text('关于这台电脑上的 Token Lens'));
    await t.pumpAndSettle();
    expect(find.text('加载失败（request_failed）'), findsOneWidget);
    g.healthFails = false;
    await t.tap(find.text('重试'));
    await t.pumpAndSettle();
    expect(g.healthReads, 2);
    expect(find.text('/synthetic-preview'), findsOneWidget);
  });
  for (final failure in ['pricing', 'usage']) {
    testWidgets('$failure 独立失败可重试', (t) async {
      final g = SettingsGateway([model('fixture')])..failingResource = failure;
      await showSettings(t, g);
      expect(find.text('加载失败（request_failed）'), findsOneWidget);
      final before = failure == 'pricing' ? g.priceReads : g.usageReads;
      g.failingResource = null;
      await t.tap(find.text('重试'));
      await t.pumpAndSettle();
      expect(failure == 'pricing' ? g.priceReads : g.usageReads, before + 1);
      expect(find.text('fixture'), findsOneWidget);
    });
  }
  testWidgets('空态、内置汇率、浅深主题、720 宽、减少动态效果', (t) async {
    for (final dark in [false, true]) {
      await showSettings(t, SettingsGateway([]), width: 720, dark: dark);
      expect(find.text('还没有用到的模型'), findsOneWidget);
      expect(find.text('1 美元 ≈ 6.70 元 · 内置汇率'), findsOneWidget);
      expect(t.takeException(), isNull);
    }
  });
}
