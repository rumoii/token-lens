import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/app_shell.dart';
import 'package:token_lens_app/smooth_wheel.dart';
import 'package:token_lens_app/stats/home_page.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';

import 'fake_gateway.dart';

void main() {
  Future<StatsController> mount(
    WidgetTester tester, {
    double width = 1440,
    double height = 1000,
    Widget? news = const Text('新闻内容'),
    FakeStatsGateway? gateway,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = StatsController(
      gateway ?? FakeStatsGateway(),
      clock: () => demoNow,
    );
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: const LensPalette(false).theme,
        home: news == null
            ? StatsPage(controller: controller)
            : AppShell(statsController: controller, news: news),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('默认用量总览，分组菜单按原型顺序排列', (tester) async {
    await mount(tester);
    expect(find.byType(StatsHome), findsOneWidget);
    expect(find.text('新闻内容'), findsNothing);
    expect(find.byType(SegmentedButton<bool>), findsNothing);
    expect(find.bySemanticsLabel('页面导航'), findsOneWidget);
    const labels = [
      '用量',
      '用量总览',
      '用量明细',
      '会话记录',
      '工具',
      '资讯',
      'AI 热点',
      '设置',
      '价格与设置',
    ];
    for (var i = 0; i < labels.length; i++) {
      expect(find.text(labels[i]), findsOneWidget);
      if (i > 0) {
        expect(
          tester.getTopLeft(find.text(labels[i])).dy,
          greaterThan(tester.getTopLeft(find.text(labels[i - 1])).dy),
        );
      }
    }
    expect(find.byIcon(Icons.rss_feed_rounded), findsOneWidget);
    expect(
      tester.widget<ListView>(find.byType(ListView)).controller,
      isA<SmoothWheelController>(),
    );
    expect(
      tester
          .widget<SingleChildScrollView>(find.byKey(const Key('stats-scroll')))
          .controller,
      isA<SmoothWheelController>(),
    );
  });

  testWidgets('AI 热点切换内容、隐藏本期工具且底部位置不变', (tester) async {
    final controller = await mount(tester);
    expect(find.text('本期工具'), findsOneWidget);
    final sync = tester.getTopLeft(find.text(controller.syncLabel));
    final appearance = tester.getTopLeft(
      find.byIcon(Icons.light_mode_outlined),
    );
    await tester.tap(find.text('AI 热点'));
    await tester.pumpAndSettle();
    expect(find.text('新闻内容'), findsOneWidget);
    expect(find.byType(StatsHome), findsNothing);
    expect(find.byKey(const Key('stats-scroll')), findsNothing);
    expect(find.text('本期工具'), findsNothing);
    expect(find.text('正在读取本期用量…'), findsNothing);
    expect(find.text('重试读取'), findsNothing);
    expect(find.text(controller.syncLabel), findsOneWidget);
    expect(tester.getTopLeft(find.text(controller.syncLabel)), sync);
    expect(
      tester.getTopLeft(find.byIcon(Icons.light_mode_outlined)),
      appearance,
    );
    expect(find.byIcon(Icons.dark_mode_outlined), findsOneWidget);
    await tester.tap(find.text('用量总览'));
    await tester.pumpAndSettle();
    expect(find.byType(StatsHome), findsOneWidget);
    expect(find.text('本期工具'), findsOneWidget);
  });

  testWidgets('AI 热点不显示统计重试与加载状态', (tester) async {
    final gateway = FakeStatsGateway();
    final controller = await mount(tester, gateway: gateway);
    gateway.failure = 'synthetic read failure';
    await controller.load();
    await tester.pumpAndSettle();
    final sidebar = find.byType(ListView);
    expect(
      find.descendant(of: sidebar, matching: find.text('重试读取')),
      findsOneWidget,
    );
    await tester.tap(find.text('AI 热点'));
    await tester.pumpAndSettle();
    expect(find.text('重试读取'), findsNothing);
    gateway.failure = null;
    gateway.readBarrier = Completer<void>();
    final read = controller.load();
    await tester.pump();
    expect(controller.loading, isTrue);
    expect(find.text('正在读取本期用量…'), findsNothing);
    expect(find.text('本期工具'), findsNothing);
    expect(find.text(controller.syncLabel), findsOneWidget);
    gateway.readBarrier!.complete();
    await read;
    await tester.pumpAndSettle();
  });

  testWidgets('未提供新闻时没有资讯分组', (tester) async {
    await mount(tester, news: null);
    expect(find.text('资讯'), findsNothing);
    expect(find.text('AI 热点'), findsNothing);
    expect(find.text('用量'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('720 宽抽屉显示分组，点击 AI 热点后关闭', (tester) async {
    await mount(tester, width: 720);
    await tester.tap(find.byTooltip('打开导航菜单'));
    await tester.pumpAndSettle();
    expect(find.text('用量'), findsOneWidget);
    expect(find.text('资讯'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    await tester.tap(find.text('AI 热点'));
    await tester.pumpAndSettle();
    expect(find.text('新闻内容'), findsOneWidget);
    expect(find.byTooltip('关闭导航菜单'), findsNothing);
    expect(
      tester.state<ScaffoldState>(find.byType(Scaffold)).isDrawerOpen,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('矮窗口菜单和本期工具共同滚动', (tester) async {
    await mount(tester, height: 420);
    final sidebar = find.byType(ListView);
    expect(
      find.descendant(of: sidebar, matching: find.text('用量总览')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('本期工具'),
      90,
      scrollable: find.descendant(
        of: sidebar,
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('本期工具').hitTestable(), findsOneWidget);
    expect(find.text('同步用量').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [1440.0, 720.0]) {
    testWidgets('侧栏及抽屉 $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = StatsController(
        FakeStatsGateway(),
        clock: () => demoNow,
      );
      addTearDown(controller.dispose);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: const LensPalette(false).theme,
          home: StatsPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      if (width < 768) {
        await tester.tap(find.byTooltip('打开导航菜单'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('用量明细'));
      await tester.pumpAndSettle();
      expect(find.text('这一页还在迁移'), findsNothing);
      expect(find.text('拆开看'), findsOneWidget);
      expect(
        (tester.state(find.byType(StatsPage)) as dynamic).query,
        'period=week&view=detail',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
