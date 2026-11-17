import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

import 'stats/fake_gateway.dart';

void main() {
  Future<StatsController> show(
    WidgetTester tester,
    FakeStatsGateway gateway, {
    bool load = true,
    StatsPeriod period = const StatsPeriod(),
  }) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = StatsController(
      gateway,
      clock: () => demoNow,
      preferences: UiPreferences(period: period, onboarded: true),
    );
    addTearDown(controller.dispose);
    if (load) await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: const LensPalette(false).theme,
        home: StatsPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('数据显示总览区块', (tester) async {
    await show(tester, FakeStatsGateway());
    for (final label in ['趋势', '常用模型', '本周的会话', '这一年']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byKey(const Key('home-hero')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('空账本给切换范围入口', (tester) async {
    await show(tester, FakeStatsGateway()..empty = true);
    expect(find.text('这周还没有用量'), findsOneWidget);
    expect(find.text('看本月'), findsOneWidget);
    expect(find.text('趋势'), findsNothing);
  });
  testWidgets('NULL token 和未定价不当零', (tester) async {
    await show(tester, FakeStatsGateway()..unknown = true);
    expect(find.text('未定价'), findsWidgets);
    expect(find.text('—'), findsWidgets);
    expect(find.text('\$0.00'), findsNothing);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: const TokenText(null))),
    );
    await tester.pumpAndSettle();
    expect(find.text('—'), findsOneWidget);
    expect(find.byTooltip('客户端没有上报该字段'), findsOneWidget);
  });
  testWidgets('未定价工具保持明确', (tester) async {
    await show(tester, FakeStatsGateway(), period: const StatsPeriod('month'));
    expect(find.text('未定价'), findsWidgets);
    expect(find.text('synthetic-unpriced-model'), findsOneWidget);
  });
  testWidgets('同步去重、保留画面、禁用重复按钮', (tester) async {
    final fake = FakeStatsGateway()..syncBarrier = Completer<void>();
    final controller = await show(tester, fake);
    await tester.tap(find.text('同步用量'));
    await tester.pump();
    expect(find.text('正在同步'), findsOneWidget);
    expect(find.byKey(const Key('home-hero')), findsOneWidget);
    expect(fake.syncs, 1);
    final duplicate = controller.sync();
    expect(fake.syncs, 1);
    fake.syncBarrier!.complete();
    fake.syncBarrier = null;
    await duplicate;
    await tester.pumpAndSettle();
  });
  testWidgets('同步完成和失败可以重试', (tester) async {
    final fake = FakeStatsGateway()..syncBarrier = Completer<void>();
    await show(tester, fake);
    await tester.tap(find.text('同步用量'));
    await tester.pump();
    expect(find.text('正在同步'), findsOneWidget);
    expect(fake.syncs, 1);
    await tester.tap(find.text('同步用量'));
    expect(fake.syncs, 1);
    fake.syncBarrier!.complete();
    fake.syncBarrier = null;
    await tester.pumpAndSettle();
    fake.syncFailure = 'fixture';
    await tester.tap(find.text('同步用量'));
    await tester.pumpAndSettle();
    expect(find.text('同步失败，已保留先前采集的数据。'), findsWidgets);
    expect(find.byKey(const Key('home-hero')), findsOneWidget);
  });
  testWidgets('锁冲突等待后完成', (tester) async {
    final fake = FakeStatsGateway()..syncFailure = 'SYNC_BUSY';
    await show(tester, fake);
    await tester.tap(find.text('同步用量'));
    await tester.pump();
    expect(find.text('已有同步在执行，正在等待完成'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('刚刚完成同步'), findsOneWidget);
  });
}
