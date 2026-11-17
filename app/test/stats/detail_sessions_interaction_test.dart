import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/smooth_wheel.dart';
import 'package:token_lens_app/stats/detail_page.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/widgets/charts.dart';
import 'package:token_lens_app/stats/widgets/filters.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'detail_page_test.dart' as d;
import 'sessions_page_test.dart' as s;
import 'fake_gateway.dart';

class DelayedDetail extends d.DetailGateway {
  Completer<StatsSummary>? delayed;
  @override
  Future<StatsSummary> summary(StatsFilter filter) async {
    if (filter.source == 'dsh' && delayed != null) return delayed!.future;
    final result = await super.summary(filter);
    return filter.source == 'codex'
        ? StatsSummary(
            totals: const StatsTotals(
              grossTokens: 777777,
              unpricedRecords: 0,
              recordCount: 1,
            ),
            activity: result.activity,
            rolling: result.rolling,
            snapshot: result.snapshot,
          )
        : result;
  }
}

void main() {
  testWidgets('会话：加载更多在同一帧重复点击只请求一次游标', (tester) async {
    final fake = s.SessionsGateway()..paged = true;
    await s.mountSessions(tester, fake);
    final before = fake.pages.length;
    fake.delayed = Completer<StatsSessions>();
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '加载更多'),
    );
    button.onPressed!();
    button.onPressed!();
    fake.delayed!.complete(
      const StatsSessions(items: [], snapshot: demoSnapshot),
    );
    await tester.pumpAndSettle();
    expect(fake.pages.length, before + 1);
    expect(fake.pages.last.cursor, 'opaque-next');
  });
  for (final drill in [
    ('date', '2026-11-09', 'bucket', '2026-11-09', 'tool'),
    ('model', 'claude-sonnet-5-5', 'model', 'claude-sonnet-5-5', 'date'),
    (
      'project',
      'claude|claude-sonnet-5-5',
      'project',
      'claude|claude-sonnet-5-5',
      'date',
    ),
  ]) {
    testWidgets('明细：${drill.$1} 点行增加筛选', (tester) async {
      await d.mountDetail(
        tester,
        d.DetailGateway(),
        query: 'period=month&view=detail&dim=${drill.$1}',
      );
      final row = find.byKey(Key('detail-row-${drill.$2}'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(d.pageQuery(tester)[drill.$3], drill.$4);
      expect(d.pageQuery(tester)['dim'] ?? 'date', drill.$5);
    });
  }
  testWidgets('明细：菜单键盘选择、标签、四拆法、清除筛选和排序', (tester) async {
    await d.mountDetail(tester, d.DetailGateway());
    final menu = find.widgetWithText(FilterPick, '工具');
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(d.pageQuery(tester)['tool'], isNotEmpty);
    expect(find.byTooltip('去掉工具筛选'), findsOneWidget);
    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(d.pageQuery(tester)['tool'], isNull);
    for (final dim in ['按时间', '按工具', '按模型', '按项目']) {
      await tester.tap(find.text(dim));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('用量').last);
    await tester.pumpAndSettle();
    expect(find.text('用量 ↓'), findsOneWidget);
    await tester.tap(find.text('用量 ↓'));
    await tester.pumpAndSettle();
    expect(find.text('用量 ↑'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterPick, '项目'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(StatsDetail), findsOneWidget);
  });
  testWidgets('明细：小时桶保留标签但不缩小日期；趋势选中桶', (tester) async {
    final fake = d.DetailGateway();
    await d.mountDetail(
      tester,
      fake,
      query: 'period=month&view=detail&bucket=2026-11-05T08:00:00',
    );
    expect(find.byTooltip('去掉时间筛选'), findsOneWidget);
    expect(
      fake.reads
          .where((r) => r.method == 'summary')
          .every(
            (r) => r.filter.from == '2026-11-01' && r.filter.to == '2026-11-09',
          ),
      isTrue,
    );
    expect(
      tester.widget<TrendChart>(find.byType(TrendChart)).selected,
      '2026-11-05T08:00:00',
    );
    await tester.tap(find.byTooltip('去掉时间筛选'));
    await tester.pumpAndSettle();
    expect(d.pageQuery(tester)['bucket'], isNull);
  });
  testWidgets('明细：独立块失败、重试、空态', (tester) async {
    final fake = d.DetailGateway()..failingResource = 'timeseries:day';
    await d.mountDetail(tester, fake);
    expect(
      find.descendant(
        of: find.byType(StatsDetail),
        matching: find.text('加载失败（request_failed）'),
      ),
      findsOneWidget,
    );
    expect(find.byType(TrendChart), findsOneWidget);
    fake.failingResource = null;
    await tester.tap(
      find.descendant(of: find.byType(StatsDetail), matching: find.text('重试')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(StatsDetail),
        matching: find.text('加载失败（request_failed）'),
      ),
      findsNothing,
    );
    fake.empty = true;
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('detail', {
      'dim': 'project',
    });
    await tester.pumpAndSettle();
    expect(find.text('这段时间没有符合筛选的用量。'), findsOneWidget);
  });
  testWidgets('明细：过期结果丢弃，刷新保留旧指标，销毁后不通知', (tester) async {
    final fake = DelayedDetail();
    await d.mountDetail(tester, fake);
    final old = await fake.summary(const StatsFilter());
    fake.delayed = Completer<StatsSummary>();
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('detail', {
      'tool': 'dsh',
    });
    await tester.pump();
    expect(find.byType(TokenText), findsWidgets);
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('detail', {
      'tool': 'codex',
    });
    await tester.pumpAndSettle();
    fake.delayed!.complete(old);
    await tester.pumpAndSettle();
    expect(d.pageQuery(tester)['tool'], 'codex');
    expect(
      tester
          .widgetList<TokenText>(find.byType(TokenText))
          .where((w) => w.style?.fontSize == 22)
          .single
          .value,
      777777,
    );
    fake.delayed = Completer<StatsSummary>();
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('detail', {
      'tool': 'dsh',
    });
    await tester.pump();
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('home');
    await tester.pumpAndSettle();
    fake.delayed!.completeError(StateError('disposed late failure'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  for (final dark in [false, true]) {
    testWidgets('明细/会话：720 主题 dark=$dark 和减少动态', (tester) async {
      await d.mountDetail(
        tester,
        d.DetailGateway()..unknown = true,
        width: 720,
        dark: dark,
        reduced: true,
      );
      expect(find.text('未定价'), findsWidgets);
      expect(find.text('—'), findsWidgets);
      expect(tester.takeException(), isNull);
      (tester.state(find.byType(StatsPage)) as dynamic).navigate('sessions');
      await tester.pumpAndSettle();
      expect(find.text('会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('明细：自定义日期应用保留工具筛选', (tester) async {
    await d.mountDetail(
      tester,
      d.DetailGateway(),
      query: 'period=month&view=detail&tool=claude',
    );
    await tester.tap(find.byTooltip('自定义'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('range-起始')), '2026-10-01');
    await tester.enterText(find.byKey(const Key('range-结束')), '2026-10-03');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(d.pageQuery(tester)['from'], '2026-10-01');
    expect(d.pageQuery(tester)['tool'], 'claude');
  });
  for (final width in [1440.0, 720.0]) {
    testWidgets('面板：$width 按行打开、宽度、SmoothWheel、关闭和焦点', (tester) async {
      final fake = s.SessionsGateway();
      await s.mountSessions(tester, fake, width: width, reduced: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      final before = FocusManager.instance.primaryFocus;
      await tester.tap(find.byKey(const Key('session-row-codex:s1')));
      await tester.pumpAndSettle();
      final scroll = find.byKey(const Key('session-panel-scroll'));
      expect(
        tester.widget<SingleChildScrollView>(scroll).controller,
        isA<SmoothWheelController>(),
      );
      expect(tester.getSize(scroll).width, width < 768 ? width : 460);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('会话详情'), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(before));
      await tester.tap(find.byKey(const Key('session-row-codex:s1')));
      await tester.pumpAndSettle();
      if (width >= 768) {
        await tester.tapAt(const Offset(260, 200));
      } else {
        await tester.tapAt(const Offset(5, 5));
      }
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('会话详情'), findsNothing);
    });
  }
  testWidgets('会话：不存在、详情失败独立重试', (tester) async {
    final fake = s.SessionsGateway()..missing = true;
    await s.mountSessions(tester, fake, query: 'source=codex&session=missing');
    expect(find.text('会话不存在'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    fake.missing = false;
    fake.failure = 'detail synthetic error';
    await tester.tap(find.byKey(const Key('session-row-codex:s1')));
    await tester.pumpAndSettle();
    expect(find.text('加载失败（request_failed）'), findsOneWidget);
    fake.failure = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('用了哪些模型'), findsOneWidget);
  });
  testWidgets('会话：项目工具筛选进入请求；同步重置分页重读', (tester) async {
    final fake = s.SessionsGateway()..paged = true;
    final c = await s.mountSessions(
      tester,
      fake,
      query: 'tool=codex&project=C%3A%2Fdemo',
    );
    expect(fake.pages.last.filter.source, 'codex');
    expect(fake.pages.last.filter.project, 'C:/demo');
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    final count = fake.pages.length;
    await c.sync();
    await tester.pumpAndSettle();
    expect(fake.pages.length, greaterThan(count));
    expect(fake.pages.where((r) => r.limit == 50).last.cursor, isNull);
    expect(find.text('已显示 1 个会话'), findsOneWidget);
    await tester.tap(find.byTooltip('去掉工具筛选'));
    await tester.pumpAndSettle();
    expect(fake.pages.last.filter.source, isNull);
  });
  testWidgets('会话：筛选过期列表不发布；离页晚到不通知', (tester) async {
    final fake = s.SessionsGateway();
    await s.mountSessions(tester, fake);
    fake.delayed = Completer<StatsSessions>();
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('sessions', {
      'tool': 'claude',
    });
    await tester.pump();
    final late = fake.delayed!;
    fake.delayed = null;
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('sessions', {
      'tool': 'codex',
    });
    await tester.pumpAndSettle();
    late.complete(const StatsSessions(items: [], snapshot: demoSnapshot));
    await tester.pumpAndSettle();
    expect(find.text('已显示 1 个会话'), findsOneWidget);
    fake.delayed = Completer<StatsSessions>();
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('sessions', {
      'tool': 'dsh',
    });
    await tester.pump();
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('home');
    await tester.pump();
    fake.delayed!.completeError(StateError('late sessions'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('会话：技术细节和去明细链接使用全部周期', (tester) async {
    final fake = s.SessionsGateway();
    await s.mountSessions(tester, fake, query: 'source=codex&session=s1');
    await tester.tap(find.text('技术细节'));
    await tester.pumpAndSettle();
    expect(find.text('s1'), findsOneWidget);
    await tester.tap(find.text('在明细里看 Codex'));
    await tester.pumpAndSettle();
    expect(find.byType(StatsDetail), findsOneWidget);
    expect(d.pageQuery(tester)['period'], 'all');
    expect(d.pageQuery(tester)['tool'], 'codex');
    await tester.tap(find.text('概览'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-hero')), findsOneWidget);
    expect(
      (tester.state(
        find.byType(StatsPage),
      ) as dynamic).widget.controller.preferences.period.period,
      'all',
    );
  });
  testWidgets('会话：列表失败重试、工具下拉和详情同步重读', (tester) async {
    final fake = s.SessionsGateway();
    final c = await s.mountSessions(tester, fake);
    fake.failure = 'sessions fixture failure';
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('sessions', {
      'tool': 'dsh',
    });
    await tester.pumpAndSettle();
    expect(find.text('加载失败（request_failed）'), findsOneWidget);
    fake.failure = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('已显示 1 个会话'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterPick, '工具'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fake.pages.last.filter.source, 'claude');
    await tester.tap(find.byKey(const Key('session-row-codex:s1')));
    await tester.pumpAndSettle();
    final count = fake.details.length;
    await c.sync();
    await tester.pumpAndSettle();
    expect(fake.details.length, greaterThan(count));
  });
  testWidgets('总览：模型全部、工具、最近会话和全部会话进入真页面', (tester) async {
    final fake = s.SessionsGateway();
    await s.mountSessions(tester, fake);
    final state = tester.state(find.byType(StatsPage)) as dynamic;
    state.navigate('home');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('全部').last);
    await tester.tap(find.text('全部').last);
    await tester.pumpAndSettle();
    expect(find.byType(StatsDetail), findsOneWidget);
    expect(d.pageQuery(tester)['dim'], 'model');
    state.navigate('home');
    await tester.pumpAndSettle();
    final tool = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.data == 'Claude Code' &&
          w.style?.fontSize == 14 &&
          w.style?.fontWeight == FontWeight.w500,
    );
    await tester.ensureVisible(tool);
    await tester.tap(tool);
    await tester.pumpAndSettle();
    expect(d.pageQuery(tester)['tool'], 'claude');
    expect(d.pageQuery(tester)['dim'], 'model');
    state.navigate('home');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('lumen'));
    await tester.tap(find.text('lumen'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('会话详情'), findsOneWidget);
    expect(fake.details.last, ('claude', 'session-0', 'day'));
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    state.navigate('home');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('查看全部会话'));
    await tester.tap(find.text('查看全部会话'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && w.data == '会话' && w.style?.fontSize == 28,
      ),
      findsOneWidget,
    );
    expect(find.text('已显示 1 个会话'), findsOneWidget);
  });
}
