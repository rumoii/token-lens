import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats/widgets/motion.dart';
import 'package:token_lens_app/stats/widgets/charts.dart';

import 'fake_gateway.dart';

void main() {
  Future<StatsController> mount(
    WidgetTester tester,
    FakeStatsGateway fake, {
    bool reduced = false,
    bool loaded = true,
    double width = 1440,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = StatsController(
      fake,
      clock: () => demoNow,
      preferences: const UiPreferences(onboarded: true),
    );
    addTearDown(controller.dispose);
    if (loaded) await controller.load();
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: controller,
        builder: (context, _) => MaterialApp(
          theme: const LensPalette(false).theme,
          darkTheme: const LensPalette(true).theme,
          themeMode: controller.preferences.appearance == 'dark'
              ? ThemeMode.dark
              : controller.preferences.appearance == 'light'
              ? ThemeMode.light
              : ThemeMode.system,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: child!,
          ),
          home: StatsPage(controller: controller),
        ),
      ),
    );
    if (loaded) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return controller;
  }

  testWidgets('首次加载、请求失败、重试恢复', (tester) async {
    final fake = FakeStatsGateway()..readBarrier = Completer<void>();
    final c = await mount(tester, fake, loaded: false);
    final pending = c.load();
    await tester.pump();
    expect(find.byType(SkeletonLines), findsOneWidget);
    fake.failure = 'read fixture';
    fake.readBarrier!.complete();
    fake.readBarrier = null;
    await pending;
    await tester.pumpAndSettle();
    expect(find.text('加载失败（request_failed）'), findsOneWidget);
    fake.failure = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-hero')), findsOneWidget);
  });
  testWidgets('切周期旧画面保留，数据到齐后整体替换', (tester) async {
    final fake = FakeStatsGateway();
    final c = await mount(tester, fake);
    final old = c.overview;
    fake.readBarrier = Completer<void>();
    await tester.tap(find.text('本月'));
    await tester.pump();
    expect(c.overview, same(old));
    expect(find.byKey(const Key('home-hero')), findsOneWidget);
    expect(find.byType(SkeletonLines), findsNothing);
    fake.readBarrier!.complete();
    fake.readBarrier = null;
    await tester.pumpAndSettle();
    expect(c.overview!.period.period, 'month');
  });
  testWidgets('自定义日期和清空', (tester) async {
    final c = await mount(tester, FakeStatsGateway());
    await tester.tap(find.byTooltip('自定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.enterText(find.byKey(const Key('range-起始')), '2026-10-01');
    await tester.enterText(find.byKey(const Key('range-结束')), '2026-10-05');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(
      c.preferences.period.query,
      'period=custom&from=2026-10-01&to=2026-10-05',
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('720 深浅和跟随系统，减少动态直接目标值', (tester) async {
    final c = await mount(
      tester,
      FakeStatsGateway(),
      reduced: true,
      width: 720,
    );
    await c.setPreferences(c.preferences.copyWith(appearance: 'dark'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(StatsPage));
    expect(Theme.of(context).brightness, Brightness.dark);
    await c.setPreferences(c.preferences.copyWith(appearance: 'light'));
    await tester.pumpAndSettle();
    expect(Theme.of(context).brightness, Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await c.setPreferences(c.preferences.copyWith(appearance: 'system'));
    await tester.pumpAndSettle();
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(find.byType(LensEnter), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('明细按钮、模型、趋势桶和会话携带筛选', (tester) async {
    final c = await mount(tester, FakeStatsGateway());
    await tester.tap(find.text('看明细'));
    await tester.pumpAndSettle();
    expect(
      (tester.state(find.byType(StatsPage)) as dynamic).query,
      'period=week&view=detail',
    );
    expect(find.text('拆开看'), findsOneWidget);
    await tester.tap(find.text('用量总览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('claude-sonnet-5-5'));
    await tester.pumpAndSettle();
    expect(
      (tester.state(find.byType(StatsPage)) as dynamic).query,
      'period=week&view=detail&model=claude-sonnet-5-5',
    );
    await tester.tap(find.text('用量总览'));
    await tester.pumpAndSettle();
    final chart = find.byType(TrendChart);
    final at = tester.getTopLeft(chart);
    await tester.tapAt(at + const Offset(75, 100));
    await tester.pumpAndSettle();
    expect(
      (tester.state(find.byType(StatsPage)) as dynamic).query,
      'period=week&view=detail&bucket=2026-11-09&dim=tool',
    );
    expect(c.preferences.period.period, 'week');
  });
  testWidgets('数字入场、改值与 reduced motion', (tester) async {
    num shown = -1;
    Widget view(num target, bool reduce) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: TweenValue(
          value: target,
          builder: (v) {
            shown = v;
            return Text('$v');
          },
        ),
      ),
    );
    await tester.pumpWidget(view(100, false));
    expect(shown, 0);
    await tester.pump(const Duration(milliseconds: 660));
    expect(shown, closeTo(87.5, .00001));
    await tester.pumpAndSettle();
    expect(shown, 100);
    await tester.pumpWidget(view(200, false));
    await tester.pumpAndSettle();
    expect(shown, 200);
    await tester.pumpWidget(view(300, true));
    await tester.pump();
    expect(shown, 300);
  });
  testWidgets('价格请求单独失败不遮掉总览、重试恢复', (tester) async {
    final fake = FakeStatsGateway()..failingResource = 'pricing';
    final c = await mount(tester, fake);
    expect(find.byKey(const Key('home-hero')), findsOneWidget);
    expect(find.text('加载失败（request_failed）'), findsOneWidget);
    expect(c.error, isNull);
    expect(c.resourceErrors, contains('pricing'));
    fake.failingResource = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(c.resourceErrors, isEmpty);
    expect(find.text('加载失败（request_failed）'), findsNothing);
  });
  testWidgets('热力小结两分支的活跃数字使用粗体 ink，其余文字保持 muted', (tester) async {
    for (final newcomer in [false, true]) {
      for (final dark in [false, true]) {
        final c = await mount(
          tester,
          newcomer ? _FewActiveDaysGateway() : FakeStatsGateway(),
        );
        await c.setPreferences(
          c.preferences.copyWith(appearance: dark ? 'dark' : 'light'),
        );
        await tester.pumpAndSettle();
        final active = c.overview!.year.points
            .where((day) => day.grossTokens > 0)
            .length;
        final recap = find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.data ?? widget.textSpan?.toPlainText() ?? '').startsWith(
                newcomer ? '从 ' : '过去一年活跃 ',
              ),
        );
        expect(recap, findsOneWidget);
        final text = tester.widget<Text>(recap);
        expect(text.textSpan, isNotNull);
        final numbers = <TextSpan>[];
        text.textSpan!.visitChildren((span) {
          if (span is TextSpan &&
              span.text?.replaceAll('\u2060', '') == '$active') {
            numbers.add(span);
          }
          return true;
        });
        expect(numbers, hasLength(1));
        final palette = LensPalette(dark);
        expect(numbers.single.style?.fontWeight, FontWeight.w700);
        expect(numbers.single.style?.color, palette.ink);
        expect(
          numbers.single.style?.fontFeatures,
          contains(FontFeature.tabularFigures()),
        );
        expect(text.style?.color, palette.muted);
        expect(text.style?.fontWeight, FontWeight.w400);
        expect(
          text.textSpan!.toPlainText().replaceAll('\u2060', ''),
          contains('活跃 $active 天'),
        );
      }
    }
  });
  testWidgets('总览总结行内工具名使用 w700 ink', (tester) async {
    await mount(tester, FakeStatsGateway());
    final tool = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data == 'Claude Code' &&
          widget.style?.fontSize == 15,
    );
    expect(tool, findsOneWidget);
    final text = tester.widget<Text>(tool);
    expect(text.style?.fontWeight, FontWeight.w700);
    expect(text.style?.color, const LensPalette(false).ink);
  });
  testWidgets('1024 宽指标徽标不缩，说明在同一行剩余宽度换行', (tester) async {
    await mount(tester, FakeStatsGateway(), width: 1024);
    final description = find.textContaining('平均每个 ');
    expect(description, findsOneWidget);
    final card = find
        .ancestor(of: description, matching: find.byType(LensCard))
        .first;
    final badge = find.descendant(
      of: card,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Text && RegExp(r'^\d+%$').hasMatch(widget.data ?? ''),
      ),
    );
    expect(badge, findsOneWidget);
    final badgeBox = tester.getRect(
      find.ancestor(of: badge, matching: find.byType(Container)).first,
    );
    final descriptionBox = tester.getRect(description);
    expect(descriptionBox.left - badgeBox.right, closeTo(6, .01));
    expect(descriptionBox.center.dy, closeTo(badgeBox.center.dy, .01));
    expect(
      descriptionBox.right,
      lessThanOrEqualTo(tester.getRect(card).right - 18),
    );
    expect(tester.takeException(), isNull);
  });
}

class _FewActiveDaysGateway extends FakeStatsGateway {
  @override
  Future<StatsTimeseries> timeseries(
    String granularity,
    StatsFilter filter,
  ) async {
    final data = await super.timeseries(granularity, filter);
    return StatsTimeseries(
      granularity: data.granularity,
      points: data.points.take(7).toList(),
      snapshot: data.snapshot,
      unallocated: data.unallocated,
    );
  }
}
