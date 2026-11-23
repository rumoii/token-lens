import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

import 'demo_visual_support.dart' show requireWindowsLayoutFonts;
import 'f1_polish_test.dart'
    show mountPolish, PolishGateway, singleLine, insideCard;
import 'fake_gateway.dart';
import 'settings_pricing_test.dart' as prices;

const referenceModels = [
  'claude-sonnet-5-5',
  'gemini-3.8-flash-k',
  'kimi-code/k3.1-pro',
];

class DaysGateway extends PolishGateway {
  @override
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity, {
    StatsFilter filter = const StatsFilter(),
  }) async {
    final value = (await super.sessionDetail(
      source,
      sessionId,
      granularity,
      filter: filter,
    ))!;
    return StatsSessionDetail(
      session: value.session,
      models: value.models,
      kinds: value.kinds,
      granularity: value.granularity,
      snapshot: value.snapshot,
      timeline: [
        for (final day in ['2026-11-17', '2026-11-16', '2026-11-15'])
          StatsBucket(
            bucket: day,
            grossTokens: 123456,
            requestCount: 1234,
            eventGrossTokens: 123456,
            costMicros: 1234567,
            recordCount: 1234,
            unpricedRecords: 0,
          ),
      ],
    );
  }
}

class RequestsGateway extends PolishGateway {
  @override
  List<StatsGroup> groups(StatsFilter filter, {String by = 'source_model'}) =>
      by == 'project'
      ? const [
          StatsGroup(
            key: '/synthetic/project',
            grossTokens: 123456,
            requestCount: 1234,
            eventGrossTokens: 123456,
            recordCount: 1234,
            unpricedRecords: 0,
          ),
        ]
      : super.groups(filter, by: by);
}

class PricesGateway extends FakeStatsGateway {
  PricesGateway(this.models);
  final List<StatsModelPrice> models;
  @override
  Future<StatsPricing> pricing() async => StatsPricing(
    priceVersion: 'synthetic',
    currency: 'USD',
    provisional: false,
    models: models,
    counts: StatsPriceCounts(
      verified: models.length,
      aggregate: 0,
      unknown: 0,
      local: 0,
    ),
    snapshot: demoSnapshot,
  );
}

void untruncated(WidgetTester tester, Finder text) {
  singleLine(tester, text);
  final paragraph = tester.renderObject<RenderParagraph>(text);
  final painter = TextPainter(
    text: paragraph.text,
    textScaler: paragraph.textScaler,
    textDirection: TextDirection.ltr,
  )..layout();
  expect(
    paragraph.size.width,
    greaterThanOrEqualTo(painter.width - .1),
    reason: paragraph.text.toPlainText(),
  );
  painter.dispose();
  insideCard(tester, text);
}

class TabGateway extends FakeStatsGateway implements StatsUsageExporter {
  @override
  List<StatsGroup> groups(StatsFilter filter, {String by = 'source_model'}) =>
      super.groups(const StatsFilter(from: '2026-11-10'), by: by);

  @override
  Future<String> exportUsage({
    required String by,
    required String period,
    required StatsFilter filter,
    required String format,
    required bool projectPaths,
    required String directory,
  }) async => throw StateError('The Tab order test does not export files');
}

const sidebarStops = [
  '用量总览',
  '用量明细',
  '会话记录',
  '工具',
  '价格与设置',
  'Claude Code',
  'Codex',
  'Cursor',
  'Pi',
  'Qwen Code',
  'Gemini CLI',
  'OpenCode',
  'DSH',
  'Kimi',
  'Aider',
  '同步用量',
  '浅色；长按跟随系统',
  '深色；长按跟随系统',
];

String focusLabel() {
  final element = FocusManager.instance.primaryFocus!.context! as Element;
  String? label;
  void visit(Element e) {
    final w = e.widget;
    if (w is ToolTile) return;
    if (w is Tooltip) label ??= w.message;
    if (w is Text) label ??= w.data ?? w.textSpan?.toPlainText();
    if (w is IconButton) label ??= w.tooltip;
    if (label == null) e.visitChildren(visit);
  }

  visit(element);
  element.visitAncestorElements((e) {
    if (label == null && e.widget is Tooltip) {
      label = (e.widget as Tooltip).message;
    }
    return label == null;
  });
  return label ?? element.widget.runtimeType.toString();
}

Future<List<String>> tabs(WidgetTester tester, int count) async {
  final labels = <String>[];
  for (var i = 0; i < count; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    labels.add(focusLabel());
  }
  return labels;
}

void main() {
  for (final width in [1440.0, 1024.0, 720.0]) {
    testWidgets('F1-R2-02 daily dates are separate unbroken lines at $width', (
      tester,
    ) async {
      await mountPolish(
        tester,
        width: width,
        page: 'sessions',
        query: 'source=claude&session=polish',
        gateway: DaysGateway(),
        now: DateTime(2026, 11, 17),
      );
      if (width != 720 && !requireWindowsLayoutFonts(chinese: true)) return;
      for (final day in [(17, '二', '今天'), (16, '一', '昨天'), (15, '日', null)]) {
        final row = find.byKey(Key('session-day-2026-11-${day.$1}'));
        final calendar = find.descendant(
          of: row,
          matching: find.text('11月${day.$1}日 周${day.$2}'),
        );
        untruncated(tester, calendar);
        final relatives = find.descendant(
          of: row,
          matching: find.textContaining(RegExp(r'今天|昨天')),
        );
        if (day.$3 == null) {
          expect(relatives, findsNothing);
        } else {
          final relative = find.descendant(
            of: row,
            matching: find.text(day.$3!),
          );
          expect(relative, findsOneWidget);
          expect(
            tester.getTopLeft(relative).dy,
            greaterThanOrEqualTo(tester.getBottomLeft(calendar).dy),
          );
          final first = tester.widget<Text>(calendar).style!;
          final second = tester.widget<Text>(relative).style!;
          expect(second.fontSize, lessThan(first.fontSize!));
          expect(second.color, isNot(first.color));
          insideCard(tester, relative);
        }
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'F1-R2-03 daily requests match token and money style at $width',
      (tester) async {
        await mountPolish(
          tester,
          width: width,
          page: 'sessions',
          query: 'source=claude&session=polish',
          gateway: DaysGateway(),
          now: DateTime(2026, 11, 17),
        );
        final row = find.byKey(const Key('session-day-2026-11-17'));
        final request = tester.widget<Text>(
          find.descendant(of: row, matching: find.text('1,234')),
        );
        final token = tester.widget<TokenText>(
          find.descendant(of: row, matching: find.byType(TokenText)).first,
        );
        final money = tester.widget<MoneyText>(
          find.descendant(of: row, matching: find.byType(MoneyText)),
        );
        for (final style in [token.style!, money.style!]) {
          expect(request.style!.fontSize, style.fontSize);
          expect(request.style!.color, style.color);
        }
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('F1-R2-04 compact detail requests carry label at $width', (
      tester,
    ) async {
      await mountPolish(
        tester,
        width: width,
        page: 'detail',
        query: 'period=month&dim=project',
        gateway: RequestsGateway(),
      );
      final label = find.text(width < 1440 ? '1,234 次请求' : '1,234');
      expect(label, findsOneWidget);
      untruncated(tester, label);
      expect(tester.takeException(), isNull);
    });
    testWidgets('F1-R2-05 reference model names fit at $width', (tester) async {
      await mountPolish(
        tester,
        width: width,
        page: 'settings',
        gateway: PricesGateway([
          for (final name in referenceModels) prices.model(name),
        ]),
      );
      for (final name in referenceModels) {
        untruncated(tester, find.text(name));
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'F1-R2-06 only nonzero conditional summaries appear at $width',
      (tester) async {
        const tier = StatsPriceTier(above: 272000, prices: prices.high);
        await mountPolish(
          tester,
          width: width,
          page: 'settings',
          gateway: PricesGateway([
            prices.model('zero-tier', tiers: [tier], marks: {'tier:272000': 0}),
            prices.model(
              'zero-time',
              timeOfDay: prices.timed(),
              marks: {'tod:offpeak': 0},
            ),
            prices.model('used-tier', tiers: [tier], marks: {'tier:272000': 2}),
            prices.model(
              'used-time',
              timeOfDay: prices.timed(),
              marks: {'tod:offpeak': 3},
            ),
          ]),
        );
        for (final model in ['zero-tier', 'zero-time']) {
          final row = find.byKey(ValueKey('settings-model-$model'));
          expect(
            find.descendant(
              of: row,
              matching: find.textContaining(RegExp('超过|按时段计价')),
            ),
            findsNothing,
          );
        }
        expect(find.text('超过 27.2万 token 的长提示按更高价算：2 次'), findsOneWidget);
        expect(find.text('按时段计价：3 次在低谷时段'), findsOneWidget);
        await tester.ensureVisible(find.text('zero-tier'));
        await tester.tap(find.text('zero-tier'));
        await tester.pumpAndSettle();
        expect(find.text('长上下文分档'), findsOneWidget);
        expect(find.text('提示 > 272,000 token'), findsOneWidget);
        await tester.ensureVisible(find.text('zero-time'));
        await tester.tap(find.text('zero-time'));
        await tester.pumpAndSettle();
        expect(find.text('峰谷分时'), findsOneWidget);
        expect(find.text('低谷'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('F1-R2-07 source separators stay attached at $width', (
      tester,
    ) async {
      await mountPolish(tester, width: width, page: 'sources');
      if (width == 1024 && !requireWindowsLayoutFonts(chinese: true)) return;
      for (final prefix in ['最近一次使用 ', '本月 ']) {
        final units = find.textContaining(RegExp('^$prefix'));
        expect(units, findsWidgets);
        for (final element in units.evaluate()) {
          final text = element.widget as Text;
          expect(text.data, endsWith(' · '));
          final finder = find.byWidget(text);
          untruncated(tester, finder);
        }
      }
      for (final element
          in find.textContaining(RegExp(r'^最近一次使用 ')).evaluate()) {
        final subtitle = find
            .ancestor(
              of: find.byWidget(element.widget),
              matching: find.byType(Wrap),
            )
            .first;
        expect(
          find.descendant(
            of: subtitle,
            matching: find.textContaining(RegExp(r'^\s*·')),
          ),
          findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets('F1-R2-08 empty ledger subtitle uses exact copy at $width', (
      tester,
    ) async {
      await mountPolish(
        tester,
        width: width,
        gateway: FakeStatsGateway()..empty = true,
      );
      expect(
        find.textContaining('同步之后，这里会显示每个 AI 编程工具用了多少 token。'),
        findsOneWidget,
      );
      expect(find.text('还没有任何用量'), findsOneWidget);
      expect(find.text('还没有任何用量。'), findsNothing);
      expect(tester.takeException(), isNull);
    });
    for (final page in ['home', 'detail', 'settings']) {
      testWidgets('F1-R2-01 $page concrete Tab order at $width', (
        tester,
      ) async {
        final c = await mountPolish(
          tester,
          width: width,
          page: page,
          gateway: TabGateway(),
        );
        if (page == 'home') {
          c.syncError = 'Synthetic sync failure';
          await c.load();
          await tester.pumpAndSettle();
        }
        final body = switch (page) {
          'home' => [
            '重试',
            '查看详情',
            '概览',
            '明细',
            '今天',
            '本周',
            '本月',
            '全部',
            '更多',
            '自定义',
          ],
          'detail' => [
            '概览',
            '明细',
            '今天',
            '本周',
            '本月',
            '全部',
            '更多',
            '自定义',
            '工具',
            '模型',
            '项目',
            'token',
            '金额',
            '今天 0:00   1080万',
            '导出',
            '按小时',
            '按工具',
            '按模型',
            '按项目',
            '按请求',
            '对比昨天',
            if (width < 1440) ...['排序：用量', '从大到小'],
          ],
          _ => ['浅色', '深色', '跟随系统'],
        };
        if (width < 768) {
          expect(await tabs(tester, body.length + 1), ['打开导航菜单', ...body]);
        } else {
          final expected = [...sidebarStops, ...body];
          expect(await tabs(tester, expected.length), expected);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('F1-R2-01 drawer starts at navigation and ends at close', (
    tester,
  ) async {
    await mountPolish(tester, width: 720, gateway: TabGateway());
    await tester.tap(find.byTooltip('打开导航菜单'));
    await tester.pumpAndSettle();
    expect(await tabs(tester, sidebarStops.length + 2), [
      ...sidebarStops,
      '关闭导航菜单',
      sidebarStops.first,
    ]);
    expect(tester.takeException(), isNull);
  });
}
