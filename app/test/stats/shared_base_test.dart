import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/app_shell.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/logic/format.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/onboarding_page.dart';
import 'package:token_lens_app/stats/settings_page.dart';
import 'package:token_lens_app/stats/sources_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';
import 'gateway_test.dart' show ClientSpy;

Map<String, dynamic> roundTrip(Map<String, dynamic> fields) =>
    jsonDecode(UiPreferences.decode(jsonEncode(fields)).encode());

class DiscoveryClientSpy extends ClientSpy {
  final discoveryResult = const StatsDiscovery(sources: [], supported: 27);
  final healthResult = const StatsHealth(
    ok: true,
    version: 'fixture',
    dataDir: '/demo',
    ledgerPath: '/demo/ledger.db',
    schemaVersion: 5,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #discovery) {
      calls.add(invocation);
      return Future.value(discoveryResult);
    }
    if (invocation.memberName == #health) {
      calls.add(invocation);
      return Future.value(healthResult);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  const added = {
    'onboarded': true,
    'rates': {'USD': 1, 'CNY': 8.25},
    'rateSource': 'fetched',
    'ratesFetchedAt': 1794182400000,
  };
  test('新偏好往返且旧文件读出默认值', () {
    final actual = roundTrip({'appearance': 'dark', ...added});
    for (final key in added.keys) {
      expect(actual[key], added[key], reason: key);
    }
    final old = roundTrip({'appearance': 'dark', 'currency': 'CNY'});
    expect(old['onboarded'], false);
    expect(old['rates'], defaultRates);
    expect(old['rateSource'], 'default');
    expect(old['ratesFetchedAt'], isNull);
    expect(old['appearance'], 'dark');
  });
  test('每个新字段坏值只回退该项，其他偏好保留', () {
    final defaults = {
      'onboarded': false,
      'rates': defaultRates,
      'rateSource': 'default',
      'ratesFetchedAt': null,
    };
    for (final field in <String, List<Object?>>{
      'onboarded': [null, 1, 'true'],
      'rates': [
        null,
        [],
        {},
        {'CNY': 0},
        {'CNY': -1},
        {'CNY': 'bad'},
      ],
      'rateSource': [null, 1, 'other'],
      'ratesFetchedAt': [null, 0, -1, 1.5, 'bad', true],
    }.entries) {
      for (final bad in field.value) {
        final actual = roundTrip({
          'appearance': 'dark',
          'tokenMode': 'full',
          'currency': 'CNY',
          'period': {'period': 'month'},
          ...added,
          field.key: bad,
        });
        expect(
          actual[field.key],
          defaults[field.key],
          reason: '${field.key}: $bad',
        );
        expect(actual['appearance'], 'dark');
        expect(actual['tokenMode'], 'full');
        expect(actual['currency'], 'CNY');
        expect(actual['period']['period'], 'month');
        for (final other in added.keys.where((k) => k != field.key)) {
          expect(actual[other], added[other], reason: other);
        }
      }
    }
  });
  test('rates 的 USD 固定 1，兼容旧版的 CNY 数字字符串', () {
    expect(
      roundTrip({
        'rates': {'USD': 99, 'CNY': '8.25'},
      })['rates'],
      {'USD': 1, 'CNY': 8.25},
    );
  });
  test('编码也校验汇率、来源、时间戳；copyWith 可清空时间戳', () {
    for (final invalid in [double.nan, double.infinity, 0, -1]) {
      final value = UiPreferences(
        appearance: 'dark',
        onboarded: true,
        rates: {'USD': 99, 'CNY': invalid},
        rateSource: 'invalid',
        ratesFetchedAt: -1,
      );
      final encoded = jsonDecode(value.encode());
      expect(encoded['rates'], defaultRates);
      expect(encoded['rateSource'], 'default');
      expect(encoded['ratesFetchedAt'], isNull);
      expect(encoded['appearance'], 'dark');
      expect(encoded['onboarded'], true);
    }
    final value = UiPreferences.decode(jsonEncode(added));
    expect(
      jsonDecode(
        value.copyWith(appearance: 'light').encode(),
      )['ratesFetchedAt'],
      added['ratesFetchedAt'],
    );
    expect(
      jsonDecode(
        value.copyWith(ratesFetchedAt: null).encode(),
      )['ratesFetchedAt'],
      isNull,
    );
    expect(
      jsonDecode(
        value
            .copyWith(
              onboarded: false,
              rates: {'USD': 2, 'CNY': 9},
              rateSource: 'default',
            )
            .encode(),
      )['rates'],
      {'USD': 1, 'CNY': 9},
    );
  });
  test('gateway discovery 默认 false、显式 true/false 和 health 原样透传', () async {
    final spy = DiscoveryClientSpy();
    final gateway = RustStatsGateway(spy);
    expect(await gateway.discovery(), same(spy.discoveryResult));
    expect(await gateway.discovery(fresh: true), same(spy.discoveryResult));
    expect(await gateway.discovery(fresh: false), same(spy.discoveryResult));
    expect(await gateway.health(), same(spy.healthResult));
    expect(spy.calls.map((c) => c.namedArguments).toList(), [
      {#fresh: false},
      {#fresh: true},
      {#fresh: false},
      {},
    ]);
  });
  testWidgets('lastSync 仅同步成功更新，失败和冲突保持原值', (tester) async {
    final fake = FakeStatsGateway();
    final controller = StatsController(fake, clock: () => demoNow);
    addTearDown(controller.dispose);
    final c = controller;
    expect(c.lastSync, isNull);
    await controller.sync();
    final result = c.lastSync!;
    expect(result.fileCount, 10);
    expect(result.durationMs, 1);
    fake.syncFailure = 'fixture';
    await controller.sync();
    expect(c.lastSync, same(result));
    fake.syncFailure = 'SYNC_BUSY';
    await controller.sync();
    expect(c.lastSync, same(result));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(c.lastSync, same(result));
    await controller.shutdown();
  });
  test('fake discovery 与 health 默认可用', () async {
    final fake = FakeStatsGateway();
    expect((await fake.discovery()).sources, isEmpty);
    expect((await fake.discovery(fresh: true)).supported, 27);
    expect((await fake.health()).ok, true);
    expect(await fake.health(), await fake.health());
  });
  testWidgets('已完成引导时 gate 显示 child，不读取也不同步', (tester) async {
    final fake = FakeStatsGateway();
    final c = StatsController(
      fake,
      preferences: const UiPreferences(onboarded: true),
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StatsOnboardingGate(
          controller: c,
          child: const Text('gate child'),
        ),
      ),
    );
    expect(find.text('gate child'), findsOneWidget);
    expect(fake.requests, isEmpty);
    expect(fake.syncs, 0);
  });
  for (final page in ['home', 'detail', 'sessions']) {
    testWidgets('$page 金额使用偏好中的非默认 CNY 汇率并响应更新', (tester) async {
      tester.view.physicalSize = const Size(1440, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = StatsController(
        FakeStatsGateway(),
        clock: () => demoNow,
        preferences: UiPreferences.decode(
          '{"currency":"CNY","rates":{"USD":1,"CNY":10}}',
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
      if (page != 'home') {
        (tester.state(find.byType(StatsPage)) as dynamic).navigate(page);
      }
      await tester.pumpAndSettle();
      expect(find.text('¥10.40'), findsWidgets);
      await c.setPreferences(
        UiPreferences.decode('{"currency":"CNY","rates":{"USD":1,"CNY":20}}'),
      );
      await tester.pumpAndSettle();
      expect(find.text('¥20.80'), findsWidgets);
      expect(find.text('¥10.40'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('来源、设置接到各自页面，gate 包住外壳，openLink 传到设置', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = StatsController(FakeStatsGateway(), clock: () => demoNow);
    addTearDown(c.dispose);
    await c.load();
    final opened = <Uri>[];
    Future<bool> open(Uri uri) async {
      opened.add(uri);
      return true;
    }

    final shell = AppShell(
      statsController: c,
      news: const Text('news'),
      openLink: open,
    );
    await tester.pumpWidget(
      MaterialApp(theme: const LensPalette(false).theme, home: shell),
    );
    await tester.pumpAndSettle();
    final stats = tester.widget<StatsPage>(find.byType(StatsPage));
    expect(stats.openLink, same(open));
    expect(find.byType(StatsOnboardingGate), findsOneWidget);
    for (final entry in [
      ('工具', 'StatsSourcesPage'),
      ('价格与设置', 'StatsSettingsPage'),
    ]) {
      await tester.tap(find.text(entry.$1).first);
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w.runtimeType.toString() == entry.$2),
        findsOneWidget,
      );
    }
    final settings = tester.widget<StatsSettingsPage>(
      find.byType(StatsSettingsPage),
    );
    final uri = Uri.parse('https://example.invalid/pricing');
    expect(await settings.openLink!(uri), true);
    expect(opened, [uri]);
    await tester.tap(find.text('工具').first);
    await tester.pumpAndSettle();
    tester.widget<StatsSourcesPage>(find.byType(StatsSourcesPage)).onDetail({
      'tool': 'codex',
      'dim': 'model',
    });
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(StatsPage));
    expect(state.page, 'detail');
    expect(Uri.splitQueryString(state.query)['tool'], 'codex');
    expect(Uri.splitQueryString(state.query)['dim'], 'model');
  });
}
