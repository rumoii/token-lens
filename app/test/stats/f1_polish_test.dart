import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/logic/tools.dart';
import 'package:token_lens_app/stats/logic/format.dart';
import 'package:token_lens_app/stats/logic/display.dart';
import 'package:token_lens_app/stats/logic/home_data.dart';
import 'package:token_lens_app/stats/widgets/charts.dart';
import 'package:token_lens_app/stats/widgets/date_range.dart';
import 'package:token_lens_app/stats/widgets/filters.dart';
import 'package:token_lens_app/stats/logic/pricing_display.dart';
import 'package:token_lens_app/stats/detail_page.dart' as detail;
import 'package:token_lens_app/stats/sessions_page.dart' as sessions;
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'demo_visual_support.dart' show loadSystemFonts;
import 'fake_gateway.dart';

class ProjectsGateway extends PolishGateway {
  @override
  List<StatsGroup> groups(StatsFilter filter, {String by = 'source_model'}) =>
      by == 'project'
      ? const [
          StatsGroup(
            key: '/synthetic/one/lens',
            grossTokens: 12,
            recordCount: 1,
            unpricedRecords: 0,
          ),
          StatsGroup(
            key: '/synthetic/two/lens',
            grossTokens: 8,
            recordCount: 1,
            unpricedRecords: 0,
          ),
        ]
      : super.groups(filter, by: by);
}

class DelayedPolishGateway extends PolishGateway {
  final gate = Completer<void>();
  @override
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity, {
    StatsFilter filter = const StatsFilter(),
  }) async {
    await gate.future;
    return super.sessionDetail(source, sessionId, granularity, filter: filter);
  }
}

class PolishGateway extends FakeStatsGateway {
  int input = 4, cached = 996;
  bool hasProject = true;
  PolishGateway() {
    toolIds[1] = 'qwen';
    toolIds[3] = 'opencode';
  }
  @override
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity, {
    StatsFilter filter = const StatsFilter(),
  }) async => StatsSessionDetail(
    session: StatsSessionSummary(
      source: source,
      sessionId: sessionId,
      projectKey: hasProject ? '/synthetic/team/long-project-name' : null,
      startedAt: '2026-11-09T05:00:00Z',
      lastSeenAt: '2026-11-09T08:20:00Z',
      grossTokens: 123456,
      inputTokens: input,
      cacheReadTokens: cached,
      recordCount: 10,
      requestCount: 10,
      unpricedRecords: 0,
    ),
    models: const [],
    timeline: const [
      StatsBucket(
        bucket: '2026-11-09',
        grossTokens: 123456,
        inputTokens: 4,
        cacheReadTokens: 996,
        requestCount: 10,
        eventGrossTokens: 123456,
        costMicros: 1234567,
        costUsd: '1.234567',
        recordCount: 10,
        unpricedRecords: 0,
      ),
    ],
    kinds: const StatsSessionKinds(event: 10, cumulative: 0),
    granularity: granularity,
    snapshot: demoSnapshot,
  );
  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) async => StatsSessions(
    items: [
      const StatsSessionItem(
        source: 'claude',
        sessionId: 'polish',
        projectKey: '/synthetic/team/long-project-name',
        startedAt: '2026-11-08T12:00:00Z',
        lastSeenAt: '2026-11-09T05:00:00Z',
        grossTokens: 654321,
        recordCount: 246,
        requestCount: 246,
        hasCumulative: false,
        unpricedRecords: 0,
        cumulative: StatsTotals(
          grossTokens: 1654321,
          recordCount: 346,
          requestCount: 346,
          unpricedRecords: 0,
        ),
      ),
    ],
    snapshot: demoSnapshot,
  );
}

Future<StatsController> mountPolish(
  WidgetTester tester, {
  double width = 1440,
  String page = 'home',
  String query = '',
  FakeStatsGateway? gateway,
  bool onboarded = true,
  StatsPeriod period = const StatsPeriod('today'),
  DateTime? now,
}) async {
  await loadSystemFonts(tester);
  tester.view.physicalSize = Size(width, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = StatsController(
    gateway ?? PolishGateway(),
    clock: () => now ?? demoNow,
    preferences: UiPreferences(onboarded: onboarded, period: period),
  );
  addTearDown(c.dispose);
  await c.load();
  await tester.pumpWidget(
    MaterialApp(
      theme: const LensPalette(false).theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: StatsPage(controller: c),
    ),
  );
  if (page != 'home') {
    (tester.state(find.byType(StatsPage)) as dynamic).navigate(
      page,
      Uri.splitQueryString(query),
    );
  }
  await tester.pumpAndSettle();
  return c;
}

void singleLine(WidgetTester tester, Finder text) {
  expect(text, findsWidgets);
  for (final element in text.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    final painter = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
      textScaler: paragraph.textScaler,
      maxLines: 1,
    )..layout(maxWidth: paragraph.size.width);
    expect(
      paragraph.size.height,
      lessThanOrEqualTo(painter.height + .1),
      reason: paragraph.text.toPlainText(),
    );
    painter.dispose();
  }
}

void insideCard(WidgetTester tester, Finder element) {
  final card = find
      .ancestor(of: element, matching: find.byType(LensCard))
      .first;
  final outer = tester.getRect(card), inner = tester.getRect(element);
  expect(inner.left, greaterThanOrEqualTo(outer.left));
  expect(inner.right, lessThanOrEqualTo(outer.right));
  expect(inner.top, greaterThanOrEqualTo(outer.top));
  expect(inner.bottom, lessThanOrEqualTo(outer.bottom));
}

void main() {
  test('F1-10 orphan handling preserves short and long descriptions', () {
    for (final text in ['', '天', ' 天', '55%', '占今天的 55%', '一共活跃 42 天']) {
      expect(keepTailTogether(text).replaceAll('\u2060', ''), text);
    }
  });
  test('F1-14 only exact ratio endpoints display zero or one hundred', () {
    for (final entry in <num, String>{
      0: '0%',
      1: '100%',
      .996: '99.6%',
      .995: '99.5%',
      .004: '0.4%',
      .00001: '0.1%',
      .99999: '99.9%',
      .42: '42%',
    }.entries) {
      expect(percentage(entry.key), entry.value);
    }
    expect(percentage(null), '—');
  });
  test('F1-12 daily labels retain calendar day with injected clock', () {
    final now = DateTime(2026, 11, 17);
    expect(
      usageDate('2026-11-17', now, includeRelativeDate: true),
      '今天 · 11月17日 周二',
    );
    expect(
      usageDate('2026-11-16', now, includeRelativeDate: true),
      '昨天 · 11月16日 周一',
    );
    expect(
      usageDate('2026-11-15', now, includeRelativeDate: true),
      '11月15日 周日',
    );
    expect(usageDate('2025-11-15', now), '2025年11月15日');
  });
  test('F1-24 all axis labels are distinct in both unit systems', () {
    for (final unit in ['chinese', 'english']) {
      for (final amount in [0, 1, 2, 10, 12345, 123456789]) {
        final labels = trendAxisTicks([
          TrendBucket('2026-11-09')..total = amount,
        ], unit).map((tick) => tick.label).toList();
        expect(labels.toSet().length, labels.length);
        if (amount == 0) expect(labels, ['0']);
      }
    }
  });
  testWidgets(
    'F1-16 close before detail arrives does not update disposed header',
    (tester) async {
      final fake = DelayedPolishGateway();
      await mountPolish(
        tester,
        page: 'sessions',
        query: 'source=claude&session=outside-list',
        gateway: fake,
      );
      await tester.tap(find.byTooltip('关闭'));
      fake.gate.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('会话详情'), findsNothing);
    },
  );
  testWidgets(
    'F1-11 project rows and picker use labels with full path tooltips',
    (tester) async {
      await mountPolish(
        tester,
        page: 'detail',
        query: 'dim=project',
        gateway: ProjectsGateway(),
      );
      for (final name in ['one', 'two']) {
        expect(find.text('$name / lens'), findsOneWidget);
        expect(find.text('/synthetic/$name/lens'), findsNothing);
        expect(find.byTooltip('/synthetic/$name/lens'), findsOneWidget);
      }
      final pick = find.byWidgetPredicate(
        (widget) => widget is FilterPick && widget.label == '项目',
      );
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(find.byTooltip('/synthetic/one/lens'), findsNWidgets(2));
      expect(find.text('one / lens'), findsNWidgets(2));
    },
  );
  testWidgets('F1-16 no project uses tool name as panel title', (tester) async {
    await mountPolish(
      tester,
      page: 'sessions',
      query: 'source=claude&session=outside-list',
      gateway: PolishGateway()..hasProject = false,
    );
    final panel = find.bySemanticsLabel('会话详情');
    expect(
      find.descendant(of: panel, matching: find.text('Claude Code')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('会话详情')),
      findsNothing,
    );
  });
  testWidgets('F1-13 token composition follows the selected compact units', (
    tester,
  ) async {
    final fake = PolishGateway()
      ..input = 1234
      ..cached = 567890;
    final c = await mountPolish(
      tester,
      page: 'sessions',
      query: 'source=claude&session=polish',
      gateway: fake,
    );
    await c.setPreferences(c.preferences.copyWith(unitSystem: 'english'));
    await tester.pumpAndSettle();
    expect(find.text('1.2K'), findsOneWidget);
    expect(find.text('567.9K'), findsOneWidget);
    expect(find.text('1,234'), findsNothing);
  });
  testWidgets('F1-24 zero axis exposes only zero', (tester) async {
    final semantics = tester.ensureSemantics();
    await loadSystemFonts(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: const LensPalette(false).theme,
        home: Scaffold(
          body: TrendChart(
            buckets: const [],
            order: const [],
            slots: const {},
            granularity: 'day',
            now: demoNow,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('趋势纵轴：0'), findsOneWidget);
    semantics.dispose();
  });
  testWidgets('F1-28 keyboard paints clay outline and pointer hides it', (
    tester,
  ) async {
    await mountPolish(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final ring = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint &&
          widget.foregroundPainter?.runtimeType.toString() == 'LensFocusRing',
    );
    expect(ring, findsWidgets);
    final dynamic painter = tester
        .widget<CustomPaint>(ring.first)
        .foregroundPainter;
    expect(painter.color, const LensPalette(false)['clay']);
    expect(painter.strokeWidth, 2);
    expect(painter.offset, 2);
    await tester.tap(find.text('用量总览'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(ring, findsNothing);
  });
  for (final page in ['home', 'detail', 'settings']) {
    testWidgets('F1-29 $page tabs finish sidebar before content', (
      tester,
    ) async {
      await mountPolish(tester, page: page);
      final sequence = <bool>[];
      final labels = <String>[];
      FocusNode? first;
      for (var i = 0; i < 90; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final node = FocusManager.instance.primaryFocus!;
        if (i > 0 && node == first) break;
        first ??= node;
        final box = node.context!.findRenderObject()! as RenderBox;
        sequence.add(box.localToGlobal(Offset.zero).dx < 244);
        final texts = <String>[];
        void visit(Element element) {
          final widget = element.widget;
          if (widget is Text && widget.data != null) texts.add(widget.data!);
          if (widget is IconButton && widget.tooltip != null) {
            texts.add(widget.tooltip!);
          }
          if (texts.length < 3) element.visitChildren(visit);
        }

        visit(node.context! as Element);
        labels.add('${sequence.last ? '侧栏' : '正文'}: ${texts.join(' | ')}');
      }
      debugPrint('F1-29 $page focus sequence:\n${labels.join('\n')}');
      final content = sequence.indexOf(false);
      expect(content, greaterThan(5));
      expect(sequence.skip(content), everyElement(false), reason: '$sequence');
    });
  }
  testWidgets('F1-29 drawer keeps keyboard traversal inside', (tester) async {
    await mountPolish(tester, width: 720);
    await tester.tap(find.byTooltip('打开导航菜单'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 45; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final node = FocusManager.instance.primaryFocus!;
      final box = node.context!.findRenderObject()! as RenderBox;
      expect(box.localToGlobal(Offset.zero).dx, lessThan(272));
      expect(
        box.localToGlobal(Offset.zero).dx + box.size.width,
        lessThanOrEqualTo(272),
      );
      expect(
        find.ancestor(
          of: find.byWidget(node.context!.widget),
          matching: find.byKey(const Key('stats-scroll')),
        ),
        findsNothing,
      );
    }
  });
  test('F1-11 projects distinguish same leaf within a list', () {
    final data = StatsBreakdown(
      by: 'project',
      totals: const StatsTotals(
        grossTokens: 2,
        recordCount: 2,
        unpricedRecords: 0,
      ),
      snapshot: demoSnapshot,
      groups: const [
        StatsGroup(
          key: '/synthetic/one/lens',
          grossTokens: 1,
          recordCount: 1,
          unpricedRecords: 0,
        ),
        StatsGroup(
          key: r'C:\synthetic\two\lens',
          grossTokens: 1,
          recordCount: 1,
          unpricedRecords: 0,
        ),
      ],
    );
    expect(
      detail.detailRows('project', data, {'project': ''}).map((r) => r.name),
      ['one / lens', 'two / lens'],
    );
  });
  test('F1-12 dates include year across years using supplied clock', () {
    expect(
      sessions.dayName('2025-11-15T12:00:00', DateTime(2026, 11, 17)),
      '2025年11月15日',
    );
    expect(
      sessions.dayName('2026-11-16T12:00:00', DateTime(2026, 11, 17)),
      '昨天',
    );
    expect(
      sessions.dayName('2026-11-15T12:00:00', DateTime(2026, 11, 17)),
      '11月15日 周日',
    );
    expect(sessions.hm('2026-11-17T07:07:00'), '7:07');
  });
  testWidgets('F1-14 cache percentage preserves 99.6 percent', (tester) async {
    await mountPolish(
      tester,
      page: 'sessions',
      query: 'source=claude&session=polish',
    );
    expect(find.text('99.6%'), findsOneWidget);
  });
  testWidgets('F1-16 deep link resolves project header after loading', (
    tester,
  ) async {
    await mountPolish(
      tester,
      page: 'sessions',
      query: 'source=claude&session=outside-list',
    );
    final title = find.descendant(
      of: find.bySemanticsLabel('会话详情'),
      matching: find.text('long-project-name'),
    );
    expect(title, findsOneWidget);
    expect(
      find.text('Claude Code · 今天 0:00 开始 · 持续 3 小时 20 分'),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: title, matching: find.byType(Tooltip)),
      findsWidgets,
    );
  });
  test(
    'F1-21 conditional price summary is plain and omits secondary counts',
    () {
      const model = StatsModelPrice(
        model: 'synthetic-tier',
        records: 8,
        state: 'verified',
        billing: 'metered',
        localRecords: 0,
        localProviders: {},
        priceMarks: {'tier:272000': 7, 'tier:unknown': 1},
        tiers: [StatsPriceTier(above: 272000, prices: StatsPrices(input: 2))],
      );
      expect(conditionalSummary(model), '超过 27.2万 token 的长提示按更高价算：7 次');
    },
  );
  for (final width in [1440.0, 1024.0, 720.0]) {
    testWidgets('F1-26 session first columns fit at $width', (tester) async {
      await mountPolish(
        tester,
        width: width,
        page: 'sessions',
        period: const StatsPeriod('month'),
      );
      final title = find.text('long-project-name');
      final start = width >= 768
          ? find.text('开始')
          : find.textContaining(RegExp(r' 开始$'));
      insideCard(tester, title);
      insideCard(tester, start);
      if (width >= 768) {
        expect(
          tester.getRect(start).left - tester.getRect(title).right,
          lessThan(64),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('F1-27 close button has no default error border', (tester) async {
    await mountPolish(
      tester,
      page: 'sessions',
      query: 'source=claude&session=polish',
    );
    final containers = tester.widgetList<Container>(
      find.ancestor(of: find.byTooltip('关闭'), matching: find.byType(Container)),
    );
    final buttonBox = containers.firstWhere(
      (c) => c.constraints?.maxWidth == 30,
    );
    expect((buttonBox.decoration as BoxDecoration).border, isNull);
  });
  test('F1-22 tool table matches Rust PARSER_REV', () {
    final source = File('rust/src/stats/adapters/mod.rs').readAsStringSync();
    final block = source.split('pub const PARSER_REV:').last.split('];').first;
    final ids = RegExp(r'"([^"]+)"\s*,\s*\d+')
        .allMatches(block)
        .map((m) => m[1]!)
        .toSet();
    expect(ids, isNotEmpty);
    expect(tools.keys.toSet(), ids);
    expect(toolOf('anythingllm').name, 'AnythingLLM');
    expect(toolOf('commandcode').name, 'Command Code');
  });
  testWidgets('F1-18 detail omits navigation instruction', (tester) async {
    await mountPolish(tester, page: 'detail');
    expect(find.textContaining('从首页点工具、模型或柱子进来'), findsNothing);
  });
  testWidgets('F1-20 prices omit unfinished update copy', (tester) async {
    await mountPolish(tester, page: 'settings');
    expect(find.textContaining('联网更新价格还没有做'), findsNothing);
  });
  testWidgets('F1-23 empty ledger offers sync and sources', (tester) async {
    await mountPolish(tester, gateway: FakeStatsGateway()..empty = true);
    expect(find.text('还没有任何用量'), findsOneWidget);
    expect(find.text('看工具来源'), findsOneWidget);
    expect(find.text('看本月'), findsNothing);
    expect(find.text('看全部'), findsNothing);
    expect(find.textContaining('换个时间范围看看'), findsNothing);
  });
  testWidgets('F1-25 onboarding uses shared BrandMark', (tester) async {
    await mountPolish(
      tester,
      onboarded: false,
      gateway: FakeStatsGateway()..empty = true,
    );
    expect(
      tester.widget(find.byKey(const Key('onboarding-mark'))),
      isA<BrandMark>(),
    );
  });
  testWidgets('F1-30 healthy source fields merge into status', (tester) async {
    await mountPolish(tester, page: 'sources');
    expect(find.text('已接入'), findsWidgets);
    expect(find.text('正在统计'), findsNothing);
    for (final title in ['记录方式', '日志留存', '自检']) {
      expect(find.text(title), findsNothing);
    }
    expect(find.text('状态'), findsWidgets);
    for (final label in ['每次请求都有记录 · ', '记录完整 · ', '自检正常']) {
      expect(find.text(label), findsWidgets);
    }
  });
  for (final width in [1440.0, 1024.0, 720.0]) {
    testWidgets(
      'F1-31 display prices diagnostics and about share final card at $width',
      (tester) async {
        await mountPolish(tester, width: width, page: 'settings');
        final display = tester.getTopLeft(find.text('显示'));
        final price = tester.getTopLeft(find.text('价格').first);
        final diagnostics = find.text('诊断与关于');
        expect(diagnostics, findsOneWidget);
        expect(display.dy, lessThan(price.dy));
        expect(price.dy, lessThan(tester.getTopLeft(diagnostics).dy));
        final card = find
            .ancestor(of: diagnostics, matching: find.byType(LensCard))
            .first;
        expect(
          find.descendant(of: card, matching: find.text('关于这台电脑上的 Token Lens')),
          findsOneWidget,
        );
      },
    );
  }
  for (final width in [1440.0, 1024.0, 720.0]) {
    testWidgets('F1-10 descriptions avoid orphan tails at $width', (
      tester,
    ) async {
      await mountPolish(tester, width: width, page: 'settings');
      for (final phrase in ['和厂商的价格页逐项对过', '这些用量照常统计 token，但不计入金额']) {
        final text = find.byWidgetPredicate(
          (widget) =>
              widget is Text && widget.data?.replaceAll('\u2060', '') == phrase,
        );
        expect(text, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(text);
        final painter = TextPainter(
          text: paragraph.text,
          textDirection: TextDirection.ltr,
          textScaler: paragraph.textScaler,
        )..layout(maxWidth: paragraph.size.width);
        final plain = paragraph.text.toPlainText();
        final boundary = painter.getLineBoundary(
          TextPosition(offset: plain.length),
        );
        final last = plain
            .substring(boundary.start, boundary.end)
            .replaceAll('\u2060', '')
            .trim();
        expect(
          last.runes.length,
          greaterThanOrEqualTo(3),
          reason: '$phrase: $last',
        );
        painter.dispose();
        insideCard(tester, text);
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'F1-15 session period capsule is compact and left aligned at $width',
      (tester) async {
        await mountPolish(tester, width: width, page: 'sessions');
        final capsule = find.byType(PeriodControl);
        expect(tester.getSize(capsule).width, lessThan(400));
        expect(
          tester.getTopLeft(capsule).dx,
          closeTo(tester.getTopLeft(find.text('会话').first).dx, 1),
        );
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('F1-01 home session name and requests fit at $width', (
      tester,
    ) async {
      await mountPolish(tester, width: width);
      final name = find.text('long-project-name');
      singleLine(tester, name);
      expect(tester.getSize(name).width, greaterThanOrEqualTo(100));
      expect(
        find.ancestor(of: name, matching: find.byType(Tooltip)),
        findsWidgets,
      );
      singleLine(tester, find.textContaining('246 次请求'));
      insideCard(tester, name);
      insideCard(tester, find.textContaining('246 次请求'));
      expect(tester.takeException(), isNull);
    });
    testWidgets('F1-02 heatmap date remains one line at $width', (
      tester,
    ) async {
      await mountPolish(tester, width: width);
      final heat = find.byType(Heatmap);
      await tester.ensureVisible(heat);
      await tester.pumpAndSettle();
      final box = tester.getRect(heat), narrow = width < 768;
      final start = DateTime(
        demoNow.year,
        demoNow.month,
        demoNow.day - (narrow ? demoNow.weekday % 7 + 133 : 364),
      );
      final index = DateTime.utc(
        2026,
        10,
        11,
      ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
      final blanks = start.weekday % 7;
      final weeks =
          ((blanks +
                      DateTime.utc(demoNow.year, demoNow.month, demoNow.day)
                          .difference(
                            DateTime.utc(start.year, start.month, start.day),
                          )
                          .inDays +
                      1) /
                  7)
              .ceil();
      final cell = (box.width - (weeks - 1) * 3) / weeks;
      await tester.tapAt(
        box.topLeft +
            Offset(
              ((index + blanks) ~/ 7) * (cell + 3) + cell / 2,
              20 + ((index + blanks) % 7) * (cell + 3) + cell / 2,
            ),
      );
      await tester.pumpAndSettle();
      singleLine(tester, find.text('10月11日 周日'));
      expect(tester.takeException(), isNull);
    });
    testWidgets('F1-03 session day columns stay in card at $width', (
      tester,
    ) async {
      await mountPolish(
        tester,
        width: width,
        page: 'sessions',
        query: 'source=claude&session=polish',
      );
      for (final title in ['日期', '用量', '请求', '平均每次', '约值']) {
        final text = find.text(title).last;
        singleLine(tester, text);
        insideCard(tester, text);
      }
      insideCard(tester, find.byKey(const Key('session-day-2026-11-09')));
      expect(tester.takeException(), isNull);
    });
    for (final dim in ['project', 'date']) {
      testWidgets(
        'F1-04 detail $dim fits without horizontal scroll at $width',
        (tester) async {
          await mountPolish(
            tester,
            width: width,
            page: 'detail',
            query: 'period=month&dim=$dim',
          );
          final scrolls = tester.widgetList<SingleChildScrollView>(
            find.byType(SingleChildScrollView),
          );
          expect(
            scrolls.where((s) => s.scrollDirection == Axis.horizontal),
            isEmpty,
          );
          for (final label in ['新输入', '输出', '读缓存', '写缓存', '平均每次']) {
            final text = find.textContaining(RegExp('^$label\\s*\$')).first;
            singleLine(tester, text);
            insideCard(tester, text);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets('F1-05 home tool names receive width first at $width', (
      tester,
    ) async {
      await mountPolish(
        tester,
        width: width,
        period: const StatsPeriod('month'),
      );
      final card = find.byKey(const Key('home-hero'));
      for (final name in ['Claude Code', 'Qwen Code', 'OpenCode']) {
        final text = find.descendant(of: card, matching: find.text(name)).last;
        singleLine(tester, text);
        final paragraph = tester.renderObject<RenderParagraph>(text);
        final painter = TextPainter(
          text: paragraph.text,
          textDirection: TextDirection.ltr,
        )..layout();
        expect(
          paragraph.size.width,
          greaterThanOrEqualTo(painter.width - .1),
          reason: name,
        );
        painter.dispose();
        insideCard(tester, text);
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets('F1-06 model names have tooltip at $width', (tester) async {
      await mountPolish(
        tester,
        width: width,
        period: const StatsPeriod('month'),
      );
      final card = find
          .ancestor(of: find.text('常用模型'), matching: find.byType(LensCard))
          .first;
      final name = find.descendant(
        of: card,
        matching: find.text('claude-sonnet-5-5'),
      );
      singleLine(tester, name);
      expect(
        find.ancestor(of: name, matching: find.byType(Tooltip)),
        findsWidgets,
      );
      insideCard(tester, name);
      expect(tester.takeException(), isNull);
    });
    testWidgets('F1-07 price usage header remains one line at $width', (
      tester,
    ) async {
      await mountPolish(tester, width: width, page: 'settings');
      if (width >= 768) {
        singleLine(tester, find.text('累计用量'));
        insideCard(tester, find.text('累计用量'));
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets('F1-08 price model single line and tooltip at $width', (
      tester,
    ) async {
      await mountPolish(tester, width: width, page: 'settings');
      final name = find.text('claude-opus-5-5');
      singleLine(tester, name);
      expect(
        find.ancestor(of: name, matching: find.byType(Tooltip)),
        findsWidgets,
      );
      insideCard(tester, name);
      expect(tester.takeException(), isNull);
    });
    testWidgets('F1-09 source subtitle units remain whole at $width', (
      tester,
    ) async {
      await mountPolish(tester, width: width, page: 'sources');
      singleLine(tester, find.textContaining(RegExp(r'^本月 .* token · $')));
      singleLine(tester, find.text('10 条记录'));
      for (final element in find.text('10 条记录').evaluate()) {
        insideCard(tester, find.byWidget(element.widget));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
