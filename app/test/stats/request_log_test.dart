import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'detail_page_test.dart' as d;
import 'sessions_page_test.dart' as s;
import 'fake_gateway.dart';

class RequestGateway extends d.DetailGateway {
  final requestCalls = <({StatsFilter filter, StatsRequestQuery query})>[];
  bool requestFailure = false;
  Future<StatsRequests>? pending;
  int count = 65;
  bool idsBySort = false;
  @override
  Future<StatsRequests> requestList(
    StatsFilter filter,
    StatsRequestQuery query,
  ) async {
    requestCalls.add((filter: filter, query: query));
    if (pending != null) {
      final next = pending!;
      pending = null;
      return next;
    }
    if (requestFailure) throw StateError('synthetic request failure');
    return StatsRequests(
      items: List.generate(
        count,
        (i) => StatsRequest(
          id: idsBySort ? '${query.sort}-r$i' : 'r$i',
          observedAt: '2026-11-09T04:12:00Z',
          source:
              query.source ??
              (i == 1
                  ? 'claude'
                  : i == 2
                  ? 'grok'
                  : 'codex'),
          sessionId: 's1',
          projectKey: 'synthetic-project',
          model: 'synthetic-model-with-a-long-name-$i',
          inputTokens: i == 0 ? null : 12345,
          outputTokens: 300,
          cacheReadTokens: 100,
          cacheWriteTokens: 0,
          costMicros: i == 0
              ? null
              : i == 1
              ? 1
              : 3000,
          unpricedRecords: i == 0 ? 1 : 0,
          priceState: 'unknown',
          scope: i == 2 ? 'turn' : 'request',
          status: i == 3 ? 'failed' : 'completed',
          ttftMs: i == 0 ? null : 2400,
          speedTps: i == 1 || i == 3 ? null : 20.0,
          throughputTps: i == 1 ? 10.0 : null,
        ),
      ).skip(query.offset).take(query.limit).toList(),
      total: query.includeSummary ? count : null,
      slow: query.includeSummary
          ? const StatsRequestSlow(ttftMs: 2000, speedTps: 25)
          : null,
      snapshot: demoSnapshot,
    );
  }
}

class RequestSessionGateway extends s.SessionsGateway {
  final data = RequestGateway();
  bool onlyTotals = false;
  @override
  Future<StatsRequests> requestList(
    StatsFilter filter,
    StatsRequestQuery query,
  ) => data.requestList(filter, query);
  @override
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity, {
    StatsFilter filter = const StatsFilter(),
  }) async {
    final result = await super.sessionDetail(
      source,
      sessionId,
      granularity,
      filter: filter,
    );
    if (!onlyTotals || result == null) return result;
    return StatsSessionDetail(
      session: result.session,
      models: result.models,
      timeline: result.timeline,
      kinds: const StatsSessionKinds(event: 0, cumulative: 1),
      granularity: result.granularity,
      snapshot: result.snapshot,
      period: result.period,
      timing: result.timing,
    );
  }
}

void main() {
  for (final width in [1440.0, 1024.0, 720.0]) {
    testWidgets('请求列表 $width 无 overflow，内容在卡片内，无横向滚动', (tester) async {
      final fake = RequestGateway();
      await d.mountDetail(
        tester,
        fake,
        width: width,
        reduced: true,
        query: 'period=month&view=detail&dim=request&tool=codex&model=test&project=test&bucket=2026-11-09T08:00:00',
      );
      final row = find.byKey(const Key('request-row-r0'));
      expect(row, findsOneWidget);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final card = find
          .ancestor(of: row, matching: find.byType(LensCard))
          .first;
      final bounds = tester.getRect(card);
      for (final target in [
        row,
        find.byKey(const Key('request-model-r0')),
        find.byKey(const Key('request-money-r0')),
        find.byKey(const Key('request-meta-r0')),
      ]) {
        if (target.evaluate().isEmpty) continue;
        final rect = tester.getRect(target);
        expect(rect.left, greaterThanOrEqualTo(bounds.left));
        expect(rect.right, lessThanOrEqualTo(bounds.right));
        expect(rect.top, greaterThanOrEqualTo(bounds.top));
        expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
      }
      expect(
        tester
            .widgetList<Scrollable>(find.byType(Scrollable))
            .where(
              (s) =>
                  s.axisDirection == AxisDirection.left ||
                  s.axisDirection == AxisDirection.right,
            ),
        isEmpty,
      );
      expect(fake.requestCalls.single.query.bucket, isNull);
      expect(fake.requestCalls.single.filter.source, 'codex');
      expect(fake.requestCalls.single.filter.model, 'test');
      expect(fake.requestCalls.single.filter.project, 'test');
    });
  }
  testWidgets('请求分页沿用首屏摘要，换排序和计时筛选回到30条', (tester) async {
    final fake = RequestGateway();
    await d.mountDetail(
      tester,
      fake,
      query: 'period=month&view=detail&dim=request',
      reduced: true,
    );
    expect(find.text('时间 ↓'), findsOneWidget);
    var more = find.text('再显示 30 条（还有 35 条）');
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(fake.requestCalls.last.query.offset, 30);
    expect(fake.requestCalls.last.query.includeSummary, isFalse);
    more = find.text('再显示 5 条');
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('request-row-r64')), findsOneWidget);
    final sort = find.byKey(const Key('request-sort-speed'));
    await tester.ensureVisible(sort);
    await tester.tap(sort);
    await tester.pumpAndSettle();
    expect(fake.requestCalls.last.query.sort, 'speed');
    expect(fake.requestCalls.last.query.descending, isFalse);
    expect(find.text('速度 token/s ↑'), findsOneWidget);
    expect(fake.requestCalls.last.query.offset, 0);
    expect(fake.requestCalls.last.query.includeSummary, isTrue);
    expect(find.byKey(const Key('request-row-r30')), findsNothing);
    await tester.tap(sort);
    await tester.pumpAndSettle();
    expect(fake.requestCalls.last.query.descending, isTrue);
    final timed = find.text('只看有计时的');
    await tester.ensureVisible(timed);
    await tester.tap(timed);
    await tester.pumpAndSettle();
    expect(fake.requestCalls.last.query.timedOnly, isTrue);
    expect(fake.requestCalls.last.query.offset, 0);
  });
  testWidgets('请求行回车打开对应会话', (tester) async {
    await d.mountDetail(
      tester,
      RequestGateway(),
      query: 'period=month&view=detail&dim=request',
      reduced: true,
    );
    final row = find.byKey(const Key('request-row-r0'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    final element = tester.element(find.byKey(const Key('request-model-r0')));
    Focus.of(element).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final rings = tester
        .widgetList<CustomPaint>(
          find.descendant(of: row, matching: find.byType(CustomPaint)),
        )
        .map((w) => w.foregroundPainter)
        .whereType<LensFocusRing>();
    expect(rings.single.color, LensPalette.of(element)['clay']);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('会话详情'), findsOneWidget);
  });
  testWidgets('请求空态、错误和重试', (tester) async {
    final fake = RequestGateway()..count = 0;
    final c = await d.mountDetail(
      tester,
      fake,
      query: 'period=month&view=detail&dim=request',
      reduced: true,
    );
    expect(find.text('这段时间没有逐次请求。只记录会话总数的工具不出现在这里。'), findsOneWidget);
    await tester.ensureVisible(find.text('只看有计时的'));
    await tester.tap(find.text('只看有计时的'));
    await tester.pumpAndSettle();
    expect(find.text('这段时间的请求都没有计时记录。'), findsOneWidget);
    fake.requestFailure = true;
    c.ledgerVersion++;
    await tester.tap(find.text('只看有计时的'));
    await tester.pumpAndSettle();
    expect(find.text('加载失败（request_failed）'), findsOneWidget);
    fake.requestFailure = false;
    c.ledgerVersion++;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('加载失败（request_failed）'), findsNothing);
  });
  testWidgets('会话请求页签不受周期筛选，默认概况', (tester) async {
    final fake = s.SessionsGateway();
    await s.mountSessions(tester, fake, width: 720, reduced: true);
    await tester.tap(find.byKey(const Key('session-row-codex:s1')));
    await tester.pumpAndSettle();
    final tabs = find.byKey(const Key('session-tabs'));
    expect(tabs, findsOneWidget);
    await tester.tap(find.descendant(of: tabs, matching: find.text('请求')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-request-log')), findsOneWidget);
    expect(find.text('不受筛选影响'), findsNothing);
  });
  testWidgets('请求宽窄切换保留排序，滤器变化重新计算摘要', (tester) async {
    final fake = RequestGateway();
    await d.mountDetail(
      tester,
      fake,
      query: 'period=month&view=detail&dim=request',
      reduced: true,
    );
    final sort = find.byKey(const Key('request-sort-speed'));
    await tester.ensureVisible(sort);
    await tester.tap(sort);
    await tester.pumpAndSettle();
    final calls = fake.requestCalls.length;
    tester.view.physicalSize = const Size(720, 1800);
    await tester.pumpAndSettle();
    expect(find.text('排序：速度'), findsOneWidget);
    expect(fake.requestCalls.length, calls);
    final menu = find.byKey(const Key('request-sort-menu'));
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('首字').last);
    await tester.pumpAndSettle();
    expect(fake.requestCalls.last.query.sort, 'ttft');
    expect(fake.requestCalls.last.query.descending, isTrue);
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('detail', {
      'period': 'week',
      'dim': 'request',
      'tool': 'claude',
    });
    await tester.pumpAndSettle();
    expect(fake.requestCalls.last.filter.source, 'claude');
    expect(fake.requestCalls.last.query.offset, 0);
    expect(fake.requestCalls.last.query.includeSummary, isTrue);
  });
  testWidgets('迟到翻页不能覆盖换排序后的首屏，卸载后不更新状态', (tester) async {
    final fake = RequestGateway()..idsBySort = true;
    final c = await d.mountDetail(
      tester,
      fake,
      query: 'period=month&view=detail&dim=request',
      reduced: true,
    );
    expect(find.byKey(const Key('request-row-time-r0')), findsOneWidget);
    final stale = Completer<StatsRequests>();
    fake.pending = stale.future;
    final more = find.text('再显示 30 条（还有 35 条）');
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    final sort = find.byKey(const Key('request-sort-speed'));
    await tester.ensureVisible(sort);
    await tester.tap(sort);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('request-row-speed-r0')), findsOneWidget);
    expect(find.byKey(const Key('request-row-time-r0')), findsNothing);
    stale.complete(
      const StatsRequests(
        items: [
          StatsRequest(
            id: 'old-page-only',
            observedAt: '2026-11-09T04:12:00Z',
            source: 'codex',
            sessionId: 's1',
            model: 'old-page-only-model',
            unpricedRecords: 0,
            priceState: 'unknown',
          ),
        ],
        total: 999,
        slow: StatsRequestSlow(),
        snapshot: demoSnapshot,
      ),
    );
    await tester.pumpAndSettle();
    await c.setPreferences(c.preferences.copyWith(currency: 'CNY'));
    await tester.pumpAndSettle();
    expect(find.text('65 次请求'), findsOneWidget);
    expect(find.text('999 次请求'), findsNothing);
    expect(find.byKey(const Key('request-row-old-page-only')), findsNothing);
    expect(find.byKey(const Key('request-row-time-r0')), findsNothing);
    expect(find.byKey(const Key('request-row-speed-r0')), findsOneWidget);
    final late = Completer<StatsRequests>();
    fake.pending = late.future;
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('home');
    await tester.pumpAndSettle();
    late.complete(
      const StatsRequests(
        items: [],
        total: null,
        slow: null,
        snapshot: demoSnapshot,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('请求缺失说明、平均速度、turn和慢值标色', (tester) async {
    await d.mountDetail(
      tester,
      RequestGateway(),
      query: 'period=month&view=detail&dim=request',
      reduced: true,
    );
    expect(find.byTooltip('日志里没记这一项。'), findsWidgets);
    expect(
      find.byTooltip('Codex 这次请求直接从工具调用开始，日志里看不到第一段输出的时间。'),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Claude Code 只记了整次请求的时长，这是算上等待的平均速度。'),
      findsOneWidget,
    );
    expect(find.byTooltip('这次请求没有正常结束，不算速度。'), findsOneWidget);
    expect(find.byTooltip('这个工具按一整轮对话记录时间，一轮里可能有多次请求。'), findsNWidgets(2));
    expect(find.textContaining('10.0≈', findRichText: true), findsWidgets);
    expect(find.text('<\$0.001'), findsOneWidget);
    expect(find.text('\$0.003'), findsWidgets);
    final turnRow = find.byKey(const Key('request-row-r2'));
    for (final text in tester.widgetList<Text>(
      find.descendant(of: turnRow, matching: find.byType(Text)),
    )) {
      if (text.textSpan?.toPlainText() == '2.4 秒' ||
          text.textSpan?.toPlainText() == '20.0') {
        final span = text.textSpan! as TextSpan;
        expect(
          (span.children!.first as TextSpan).style!.color,
          LensPalette.of(tester.element(turnRow)).ink,
        );
      }
    }
  });
  for (final width in [1440.0, 1024.0, 720.0]) {
    testWidgets('会话请求 $width 两行布局完整落在卡片内', (tester) async {
      final fake = RequestSessionGateway();
      await s.mountSessions(
        tester,
        fake,
        width: width,
        reduced: true,
        dark: width == 1024,
        query: 'period=week',
      );
      await tester.tap(find.byKey(const Key('session-row-codex:s1')));
      await tester.pumpAndSettle();
      final tabs = find.byKey(const Key('session-tabs'));
      await tester.tap(find.descendant(of: tabs, matching: find.text('请求')));
      await tester.pumpAndSettle();
      expect(fake.data.requestCalls.single.query.source, 'codex');
      expect(fake.data.requestCalls.single.query.sessionId, 's1');
      expect(fake.data.requestCalls.single.filter.from, isNull);
      final row = find.byKey(const Key('request-row-r0'));
      final card = find
          .ancestor(of: row, matching: find.byType(LensCard))
          .first;
      final bounds = tester.getRect(card);
      for (final target in [
        row,
        find.byKey(const Key('request-model-r0')),
        find.byKey(const Key('request-money-r0')),
        find.byKey(const Key('request-meta-r0')),
      ]) {
        final rect = tester.getRect(target);
        expect(rect.left, greaterThanOrEqualTo(bounds.left));
        expect(rect.right, lessThanOrEqualTo(bounds.right));
        expect(rect.top, greaterThanOrEqualTo(bounds.top));
        expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
      }
      expect(
        find.descendant(of: row, matching: find.byType(InkWell)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widgetList<Scrollable>(
              find.descendant(of: card, matching: find.byType(Scrollable)),
            )
            .where(
              (s) =>
                  s.axisDirection == AxisDirection.left ||
                  s.axisDirection == AxisDirection.right,
            ),
        isEmpty,
      );
      expect(
        tester
            .widgetList<Scrollable>(
              find.ancestor(of: row, matching: find.byType(Scrollable)),
            )
            .every(
              (s) =>
                  s.axisDirection == AxisDirection.down ||
                  s.axisDirection == AxisDirection.up,
            ),
        isTrue,
      );
      final pills = find.byKey(const Key('request-sort-pills'));
      await tester.tap(find.descendant(of: pills, matching: find.text('速度')));
      await tester.pumpAndSettle();
      expect(fake.data.requestCalls.last.query.descending, isFalse);
      expect(find.text('速度 ▲'), findsOneWidget);
    });
  }
  testWidgets('只记录总数的会话不显示页签', (tester) async {
    final fake = RequestSessionGateway()..onlyTotals = true;
    await s.mountSessions(tester, fake, width: 720, reduced: true);
    await tester.tap(find.byKey(const Key('session-row-codex:s1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-tabs')), findsNothing);
    expect(find.text('只记录总数'), findsOneWidget);
    expect(fake.data.requestCalls, isEmpty);
  });
}
