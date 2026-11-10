import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';

class SessionsGateway extends FakeStatsGateway {
  final pages = <({StatsFilter filter, int limit, String? cursor})>[];
  final details = <(String, String, String)>[];
  bool paged = false, missing = false;
  int? input = 100, cached = 100;
  Completer<StatsSessions>? delayed;
  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) async {
    pages.add((filter: filter, limit: limit, cursor: cursor));
    if (delayed != null) return delayed!.future;
    if (limit == 5) return super.sessions(filter, limit: limit, cursor: cursor);
    if (failure != null) throw StateError(failure!);
    return StatsSessions(
      items: empty
          ? []
          : [
              StatsSessionItem(
                source: 'codex',
                sessionId: cursor == null ? 's1' : 's2',
                projectKey: cursor == null ? null : 'C:/demo',
                startedAt: '2026-11-09T05:00:00Z',
                lastSeenAt: '2026-11-09T06:00:00Z',
                grossTokens: 42,
                costUsd: '1.500000',
                costMicros: 1500000,
                recordCount: 1,
              ),
            ],
      nextCursor: paged && cursor == null ? 'opaque-next' : null,
      snapshot: demoSnapshot,
    );
  }

  @override
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity,
  ) async {
    details.add((source, sessionId, granularity));
    if (failure != null) throw StateError(failure!);
    if (missing) return null;
    return StatsSessionDetail(
      session: StatsSessionSummary(
        source: source,
        sessionId: sessionId,
        startedAt: '2026-11-09T05:00:00Z',
        lastSeenAt: '2026-11-09T06:00:00Z',
        grossTokens: 200,
        inputTokens: input,
        cacheReadTokens: cached,
        costMicros: 1500000,
        costUsd: '1.500000',
        unpricedRecords: 0,
        recordCount: 1,
      ),
      models: const [],
      timeline: const [],
      kinds: const StatsSessionKinds(event: 1, cumulative: 0),
      granularity: granularity,
      snapshot: demoSnapshot,
    );
  }
}

Future<StatsController> mountSessions(
  WidgetTester tester,
  SessionsGateway fake, {
  String query = '',
  double width = 1440,
  bool dark = false,
  bool reduced = false,
}) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = StatsController(fake, clock: () => demoNow);
  addTearDown(c.dispose);
  await c.load();
  fake.pages.clear();
  await tester.pumpWidget(
    MaterialApp(
      theme: LensPalette(dark).theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: StatsPage(controller: c),
    ),
  );
  (tester.state(find.byType(StatsPage)) as dynamic).navigate(
    'sessions',
    Uri.splitQueryString(query),
  );
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('pages.test 会话空态', (tester) async {
    await mountSessions(tester, SessionsGateway()..empty = true);
    expect(find.text('还没有会话'), findsOneWidget);
  });
  testWidgets('pages.test 分页标题不显示 ID；游标加载到末页', (tester) async {
    final fake = SessionsGateway()..paged = true;
    await mountSessions(tester, fake);
    expect(find.text('没有记录项目'), findsOneWidget);
    expect(find.text('s1'), findsNothing);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(fake.pages.last.limit, 50);
    expect(fake.pages.last.cursor, 'opaque-next');
    expect(find.text('已显示 2 个会话'), findsOneWidget);
    expect(find.text('已经是全部了'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
  });
  testWidgets('pages.test 地址直接开详情；Esc 关闭并清理 source/session', (tester) async {
    final fake = SessionsGateway();
    await mountSessions(
      tester,
      fake,
      query: 'source=codex&session=s9&tool=codex',
    );
    expect(find.bySemanticsLabel('会话详情'), findsOneWidget);
    expect(fake.details.single, ('codex', 's9', 'hour'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('会话详情'), findsNothing);
    final query =
        (tester.state(find.byType(StatsPage)) as dynamic).query as String;
    expect(Uri.splitQueryString(query), {'tool': 'codex'});
  });
  for (final testCase in <(int?, int?, String)>[
    (null, 100, '—'),
    (100, null, '—'),
    (null, null, '—'),
    (100, 100, '50%'),
    (0, 100, '100%'),
    (0, 0, '—'),
  ]) {
    testWidgets('pages.test 缓存命中 ${testCase.$1} ${testCase.$2}', (
      tester,
    ) async {
      final fake = SessionsGateway()
        ..input = testCase.$1
        ..cached = testCase.$2;
      await mountSessions(
        tester,
        fake,
        query: 'source=codex&session=cache-test',
      );
      expect(find.byKey(const Key('session-hit')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('session-hit')),
          matching: find.text(testCase.$3),
        ),
        findsOneWidget,
      );
    });
  }
}
