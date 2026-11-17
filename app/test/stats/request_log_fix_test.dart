import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/widgets/filters.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'detail_page_test.dart' as d;
import 'sessions_page_test.dart' as s;
import 'request_log_test.dart';

class FixGateway extends RequestGateway {
  bool missingSession = false, missingValues = false;
  List<String>? toolSources;
  int? reportedTotal;
  @override
  Future<StatsRequests> requestList(
    StatsFilter filter,
    StatsRequestQuery query,
  ) async {
    final value = await super.requestList(filter, query);
    return StatsRequests(
      items: [
        for (var i = 0; i < value.items.length; i++)
          StatsRequest(
            id: value.items[i].id,
            observedAt: value.items[i].observedAt,
            source:
                toolSources?[i % toolSources!.length] ?? value.items[i].source,
            sessionId: missingSession ? null : value.items[i].sessionId,
            model: missingValues ? null : value.items[i].model,
            inputTokens: missingValues ? null : value.items[i].inputTokens,
            outputTokens: missingValues ? null : value.items[i].outputTokens,
            cacheReadTokens: missingValues
                ? null
                : value.items[i].cacheReadTokens,
            cacheWriteTokens: missingValues
                ? null
                : value.items[i].cacheWriteTokens,
            costMicros: value.items[i].costMicros,
            unpricedRecords: value.items[i].unpricedRecords,
            priceState: value.items[i].priceState,
            scope: value.items[i].scope,
            status: missingValues ? null : value.items[i].status,
            ttftMs: missingValues ? null : value.items[i].ttftMs,
            speedTps: missingValues ? null : value.items[i].speedTps,
            throughputTps: missingValues ? null : value.items[i].throughputTps,
          ),
      ],
      total: query.includeSummary ? (reportedTotal ?? value.total) : null,
      slow: value.slow,
      snapshot: value.snapshot,
    );
  }
}

class FixSessionGateway extends s.SessionsGateway {
  final data = FixGateway();
  @override
  Future<StatsRequests> requestList(
    StatsFilter filter,
    StatsRequestQuery query,
  ) => data.requestList(filter, query);
}

void main() {
  for (final dimension in [
    ('工具', 'tool'),
    ('模型', 'model'),
    ('项目', 'project'),
  ]) {
    testWidgets('FIX1 筛选${dimension.$1}保留请求维度、排序、计时勾选并重取30条', (tester) async {
      final fake = FixGateway();
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
      final timed = find.text('只看有计时的');
      await tester.ensureVisible(timed);
      await tester.tap(timed);
      await tester.pumpAndSettle();
      final more = find.text('再显示 30 条（还有 35 条）');
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('request-row-r59')), findsOneWidget);
      final pick = find.byWidgetPredicate(
        (w) => w is FilterPick && w.label == dimension.$1,
      );
      final option = tester.widget<FilterPick>(pick).options.first;
      await tester.ensureVisible(pick);
      await tester.tap(pick);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, option.label).last);
      await tester.pumpAndSettle();
      expect(d.pageQuery(tester)['dim'], 'request');
      expect(d.pageQuery(tester)[dimension.$2], option.value);
      expect(fake.requestCalls.last.query.sort, 'speed');
      expect(fake.requestCalls.last.query.descending, isFalse);
      expect(fake.requestCalls.last.query.timedOnly, isTrue);
      expect(fake.requestCalls.last.query.offset, 0);
      expect(fake.requestCalls.last.query.includeSummary, isTrue);
      expect(find.byKey(const Key('request-row-r30')), findsNothing);
    });
  }
  for (final width in [1440.0, 1024.0, 720.0]) {
    testWidgets('FIX1 无会话编号 $width 请求照常列出但不能点击聚焦', (tester) async {
      final fake = FixGateway()
        ..count = 1
        ..missingSession = true;
      await d.mountDetail(
        tester,
        fake,
        width: width,
        query: 'period=month&view=detail&dim=request',
        reduced: true,
      );
      final row = find.byKey(const Key('request-row-r0'));
      expect(row, findsOneWidget);
      expect(find.text('1 次请求'), findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.byType(InkWell)),
        findsNothing,
      );
      expect(
        tester
            .widgetList<Focus>(
              find.descendant(of: row, matching: find.byType(Focus)),
            )
            .where((f) => f.canRequestFocus && !f.skipTraversal),
        isEmpty,
      );
      expect(find.byTooltip('这次请求的日志里没有会话编号，打不开所在的会话。'), findsOneWidget);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('会话详情'), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('这次请求的日志里没有会话编号，打不开所在的会话。'), findsOneWidget);
      await mouse.removePointer();
    });
  }
  for (final width in [1024.0, 720.0]) {
    testWidgets('FIX1 工具名 $width 完整显示，排序复用 FilterPick', (tester) async {
      final fake = FixGateway()
        ..count = 3
        ..toolSources = ['claude', 'qwen', 'opencode'];
      await d.mountDetail(
        tester,
        fake,
        width: width,
        query: 'period=month&view=detail&dim=request',
        reduced: true,
      );
      for (final (i, name) in [
        (0, 'Claude Code'),
        (1, 'Qwen Code'),
        (2, 'OpenCode'),
      ]) {
        final text = find.descendant(
          of: find.byKey(Key('request-row-r$i')),
          matching: find.text(name),
        );
        expect(
          tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
          isFalse,
          reason: name,
        );
      }
      expect(
        tester
            .renderObject<RenderParagraph>(
              find.byKey(const Key('request-model-r0')),
            )
            .didExceedMaxLines,
        isTrue,
      );
      expect(
        find.byTooltip('synthetic-model-with-a-long-name-0'),
        findsOneWidget,
      );
      final sort = find.byKey(const Key('request-sort-menu'));
      expect(tester.widget(sort), isA<FilterPick>());
      expect(
        find.descendant(of: sort, matching: find.byIcon(Icons.expand_more)),
        findsOneWidget,
      );
      await tester.ensureVisible(sort);
      await tester.tap(sort);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '速度').last);
      await tester.pumpAndSettle();
      expect(fake.requestCalls.last.query.sort, 'speed');
      expect(fake.requestCalls.last.query.descending, isFalse);
    });
  }
  testWidgets('FIX1 剩余条数使用与总数一致的千位分隔', (tester) async {
    final fake = FixGateway()..reportedTotal = 65233;
    await d.mountDetail(
      tester,
      fake,
      query: 'period=month&view=detail&dim=request',
      reduced: true,
    );
    expect(find.text('65,233 次请求'), findsOneWidget);
    expect(find.text('再显示 30 条（还有 65,203 条）'), findsOneWidget);
  });
  for (final session in [false, true]) {
    for (final width in [1440.0, 1024.0, 720.0]) {
      testWidgets('FIX1 空值样式 ${session ? '会话' : '明细'} $width 统一浅色常规字重', (
        tester,
      ) async {
        if (session) {
          final fake = FixSessionGateway();
          fake.data
            ..count = 1
            ..missingValues = true;
          await s.mountSessions(tester, fake, width: width, reduced: true);
          await tester.tap(find.byKey(const Key('session-row-codex:s1')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byKey(const Key('session-tabs')),
              matching: find.text('请求'),
            ),
          );
          await tester.pumpAndSettle();
        } else {
          final fake = FixGateway()
            ..count = 1
            ..missingValues = true;
          await d.mountDetail(
            tester,
            fake,
            width: width,
            query: 'period=month&view=detail&dim=request',
            reduced: true,
          );
        }
        final row = find.byKey(const Key('request-row-r0'));
        final color = LensPalette.of(tester.element(row)).muted;
        var checked = 0;
        for (final text in tester.widgetList<Text>(
          find.descendant(of: row, matching: find.byType(Text)),
        )) {
          final content = text.data ?? text.textSpan?.toPlainText();
          if (content != '—') continue;
          final style =
              text.style ??
              ((text.textSpan! as TextSpan).children!.first as TextSpan).style!;
          expect(style.color, color);
          expect(style.fontWeight, FontWeight.w400);
          checked++;
        }
        expect(checked, greaterThanOrEqualTo(7));
      });
    }
  }
  for (final width in [1440.0, 1024.0, 720.0]) {
    testWidgets('FIX1 计时两项 $width 整组换行，不孤立速度', (tester) async {
      final fake = FixSessionGateway();
      fake.data.count = 3;
      await s.mountSessions(tester, fake, width: width, reduced: true);
      await tester.tap(find.byKey(const Key('session-row-codex:s1')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('session-tabs')),
          matching: find.text('请求'),
        ),
      );
      await tester.pumpAndSettle();
      for (final i in [0, 1, 2]) {
        final meta = find.byKey(Key('request-meta-r$i'));
        final ttft = find.descendant(of: meta, matching: find.text('首字 '));
        final speed = find.descendant(of: meta, matching: find.text('速度 '));
        expect(
          tester.getTopLeft(speed).dy,
          closeTo(tester.getTopLeft(ttft).dy, .01),
          reason: 'r$i',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
