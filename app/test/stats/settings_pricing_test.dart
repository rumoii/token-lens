import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/settings_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/stats/widgets/settings_prices.dart';

import 'fake_gateway.dart';

const base = StatsPrices(
  input: 2,
  output: 10,
  cacheRead: .1,
  cacheWrite5M: 2.5,
);
const high = StatsPrices(input: 4, output: 15, cacheRead: .2, cacheWrite5M: 5);
StatsTimeOfDay timed({bool empty = false}) => StatsTimeOfDay(
  utcOffsetMinutes: empty ? -330 : 480,
  peak: empty
      ? [
          StatsPricePeak(days: Int32List.fromList([0, 6]), from: 60, to: 120),
        ]
      : [
          StatsPricePeak(
            days: Int32List.fromList([1, 2, 3, 4, 5]),
            from: 540,
            to: 720,
          ),
          StatsPricePeak(
            days: Int32List.fromList([1, 2, 3, 4, 5]),
            from: 840,
            to: 1080,
          ),
        ],
  offPeakPrices: const StatsPrices(input: .15, output: .6, cacheRead: .003),
  holidaysCount: empty ? 0 : 33,
  holidaysThrough: empty ? null : '2027-10-07',
);
StatsModelPrice model(
  String name, {
  String state = 'verified',
  String billing = 'metered',
  StatsPrices? prices = base,
  List<StatsPriceTier>? tiers,
  StatsTimeOfDay? timeOfDay,
  Map<String, int> marks = const {'': 1},
  int local = 0,
  String? url,
}) => StatsModelPrice(
  model: name,
  records: marks.values.fold(0, (a, b) => a + b),
  state: state,
  billing: billing,
  prices: prices,
  tiers: tiers,
  timeOfDay: timeOfDay,
  priceMarks: marks,
  localRecords: local,
  localProviders: local > 0 ? {'ollama': local} : {},
  sourceUrl: url,
);

class SettingsGateway extends FakeStatsGateway {
  SettingsGateway(this.models);
  final List<StatsModelPrice> models;
  List<StatsGroup> usage = [];
  bool healthFails = false;
  int healthReads = 0, priceReads = 0, usageReads = 0;
  @override
  Future<StatsPricing> pricing() async {
    priceReads++;
    if (failingResource == 'pricing') throw StateError('pricing failed');
    return StatsPricing(
      priceVersion: 'fixture',
      currency: 'USD',
      provisional: false,
      models: models,
      counts: StatsPriceCounts(
        verified: models.where((m) => m.state == 'verified').length,
        aggregate: models.where((m) => m.state == 'aggregate').length,
        unknown: models.where((m) => m.state == 'unknown').length,
        local: models.where((m) => m.state == 'local').length,
      ),
      snapshot: demoSnapshot,
    );
  }

  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) async {
    expect(by, 'source_model');
    expect(filter.from, isNull);
    expect(filter.to, isNull);
    usageReads++;
    if (failingResource == 'usage') throw StateError('usage failed');
    return StatsBreakdown(
      by: by,
      groups: usage,
      totals: totals(filter),
      snapshot: demoSnapshot,
    );
  }

  @override
  Future<StatsHealth> health() async {
    healthReads++;
    if (healthFails) throw StateError('health failed');
    return super.health();
  }
}

class SettingsController extends StatsController {
  SettingsController(super.gateway, {super.preferences});
  void reloadLedger() {
    ledgerVersion++;
    notifyListeners();
  }
}

Future<SettingsController> showSettings(
  WidgetTester tester,
  SettingsGateway gateway, {
  double width = 1100,
  bool dark = false,
  bool reduced = true,
  UiPreferences preferences = const UiPreferences(unitSystem: 'english'),
  Future<bool> Function(Uri)? openLink,
  Future<Directory?> Function()? downloadsDirectory,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 2400);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = SettingsController(gateway, preferences: preferences);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: LensPalette(dark).theme,
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 2400),
          disableAnimations: reduced,
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: StatsSettingsPage(
                controller: c,
                openLink: openLink,
                downloadsDirectory: downloadsDirectory,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return c;
}

Finder priceRow(String name) => find.byKey(ValueKey('settings-model-$name'));
Finder inRow(String name, String text) =>
    find.descendant(of: priceRow(name), matching: find.text(text));

void main() {
  for (final width in [1100.0, 720.0]) {
    group('SettingsPricing ${width.toInt()}', () {
      testWidgets('本地零价和混合用量', (t) async {
        const zero = StatsPrices(
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite5M: 0,
          cacheWrite1H: 0,
        );
        await showSettings(
          t,
          SettingsGateway([
            model(
              'local-model',
              state: 'local',
              billing: 'local',
              prices: zero,
              local: 1,
            ),
            model('mixed-model', local: 1),
          ]),
          width: width,
        );
        expect(inRow('local-model', '本地'), findsOneWidget);
        expect(inRow('local-model', r'输入 $0 · 输出 $0'), findsOneWidget);
        expect(inRow('local-model', '没有公开价'), findsNothing);
        expect(inRow('mixed-model', r'输入 $2 · 输出 $10'), findsOneWidget);
        expect(inRow('mixed-model', '其中 1 条本地 · 金额按 0 计'), findsOneWidget);
        await t.tap(find.text('local-model'));
        await t.pumpAndSettle();
        expect(find.text(r'$0'), findsNWidgets(5));
      });
      testWidgets('模型累计合并且不列工具，套餐独立', (t) async {
        final g = SettingsGateway([
          model('gpt-6.1-sol'),
          model('plan-model', billing: 'plan'),
        ]);
        g.usage = [
          const StatsGroup(
            source: 'codex',
            model: 'gpt-6.1-sol',
            grossTokens: 120,
            unpricedRecords: 0,
            recordCount: 1,
          ),
          const StatsGroup(
            source: 'pi',
            model: 'gpt-6.1-sol',
            grossTokens: 80,
            unpricedRecords: 0,
            recordCount: 1,
          ),
        ];
        await showSettings(t, g, width: width);
        expect(
          inRow('gpt-6.1-sol', width < 768 ? '累计 200' : '200'),
          findsOneWidget,
        );
        expect(find.text('Codex'), findsNothing);
        expect(find.text('Pi'), findsNothing);
        expect(inRow('plan-model', '套餐'), findsOneWidget);
      });
      testWidgets('累计用量遵循英文单位', (t) async {
        final g = SettingsGateway([model('gpt-6.1-sol')]);
        g.usage = [
          const StatsGroup(
            model: 'gpt-6.1-sol',
            grossTokens: 1200000,
            unpricedRecords: 0,
            recordCount: 1,
          ),
        ];
        await showSettings(t, g, width: width);
        expect(
          inRow('gpt-6.1-sol', width < 768 ? '累计 1.2M' : '1.2M'),
          findsOneWidget,
        );
      });
      testWidgets('分档摘要、全部档位、缺失单价、标记与收起', (t) async {
        await showSettings(
          t,
          SettingsGateway([
            model(
              'gpt-6.1-sol',
              tiers: [
                const StatsPriceTier(above: 272000, prices: high),
                const StatsPriceTier(
                  above: 512000,
                  prices: StatsPrices(input: 8, output: 30),
                ),
              ],
              marks: {
                'tier:272000': 1037,
                'tier:512000': 3,
                'tier:unknown': 13293,
                'tier:cumulative': 2,
                '': 22,
              },
            ),
          ]),
          width: width,
        );
        final summary = find.textContaining('超过 27.2万 token');
        expect(summary, findsOneWidget);
        expect((t.widget<Text>(summary)).data, contains('更高价算：1,037 次'));
        expect(
          (t.widget<Text>(summary)).data,
          contains('超过 51.2万 token 的长提示按更高价算：3 次'),
        );
        expect((t.widget<Text>(summary)).data, isNot(contains('提示长度不完整')));
        expect(find.bySemanticsLabel('gpt-6.1-sol 条件价格'), findsNothing);
        await t.tap(find.text('gpt-6.1-sol'));
        await t.pumpAndSettle();
        expect(find.bySemanticsLabel('gpt-6.1-sol 条件价格'), findsOneWidget);
        expect(find.text('提示 > 272,000 token'), findsOneWidget);
        expect(find.text('提示 > 512,000 token'), findsOneWidget);
        expect(find.text('基础档'), findsOneWidget);
        expect(find.text('—'), findsWidgets);
        expect(find.text(r'$4'), findsOneWidget);
        expect(find.text(r'$15'), findsOneWidget);
        expect(find.text(r'$0.2'), findsOneWidget);
        expect(find.text(r'$5'), findsOneWidget);
        expect(find.text('提示长度不完整 · 基础档'), findsOneWidget);
        expect(find.text('13,293 条'), findsOneWidget);
        expect(find.text('累计快照 · 基础档'), findsOneWidget);
        expect(find.text('未标记'), findsOneWidget);
        expect(find.text('写缓存（短时）'), findsOneWidget);
        final table = t.widget<Table>(
          find.descendant(
            of: find.bySemanticsLabel('gpt-6.1-sol 条件价格'),
            matching: find.byType(Table),
          ),
        );
        List<String> cells(TableRow row) => row.children
            .map((cell) => ((cell as Padding).child as Text).data!)
            .toList();
        expect(cells(table.children[1]), [
          '基础档',
          r'$2',
          r'$10',
          r'$0.1',
          r'$2.5',
          '—',
        ]);
        expect(cells(table.children[2]), [
          '提示 > 272,000 token',
          r'$4',
          r'$15',
          r'$0.2',
          r'$5',
          '—',
        ]);
        await t.tap(find.text('gpt-6.1-sol'));
        await t.pumpAndSettle();
        expect(find.bySemanticsLabel('gpt-6.1-sol 条件价格'), findsNothing);
        expect(summary, findsOneWidget);
      });
      testWidgets('峰谷、区间、周占比和接口节假日年份', (t) async {
        await showSettings(
          t,
          SettingsGateway([
            model(
              'deepseek-flash',
              timeOfDay: timed(),
              marks: {
                'tod:peak': 5,
                'tod:offpeak': 36,
                'tod:blend': 100,
                'tod:weekly': 37,
              },
            ),
          ]),
          width: width,
        );
        final summary = t
            .widget<Text>(find.textContaining('按时段计价：36 次在低谷时段'))
            .data!;
        for (final text in ['100 条区间加权', '37 条周占比估算', '节假日仅登记到 2027年']) {
          expect(summary, isNot(contains(text)));
        }
        await t.tap(find.text('deepseek-flash'));
        await t.pumpAndSettle();
        expect(
          find.descendant(
            of: find.bySemanticsLabel('deepseek-flash 条件价格'),
            matching: find.text('低谷'),
          ),
          findsOneWidget,
        );
        for (final text in [r'$0.15', r'$0.6', r'$0.003', '区间加权', '周占比估算']) {
          expect(find.text(text), findsOneWidget);
        }
        expect(find.textContaining('北京时间（UTC+8）'), findsOneWidget);
        expect(find.textContaining('09:00–12:00'), findsOneWidget);
        expect(find.textContaining('14:00–18:00'), findsOneWidget);
        expect(find.textContaining('33 天，最晚 2027-10-07'), findsOneWidget);
        final table = t.widget<Table>(
          find.descendant(
            of: find.bySemanticsLabel('deepseek-flash 条件价格'),
            matching: find.byType(Table),
          ),
        );
        expect(
          table.children.last.children
              .map((cell) => ((cell as Padding).child as Text).data!)
              .toList(),
          ['低谷', r'$0.15', r'$0.6', r'$0.003', '—', '—'],
        );
      });
      testWidgets('固定价和未定价保留原显示', (t) async {
        await showSettings(
          t,
          SettingsGateway([
            model(
              'opus',
              prices: const StatsPrices(
                input: 4,
                output: 20,
                cacheRead: .2,
                cacheWrite5M: 5,
                cacheWrite1H: 8,
              ),
            ),
            model('unlisted', state: 'unknown', prices: null),
          ]),
          width: width,
        );
        expect(inRow('opus', r'输入 $4 · 输出 $20'), findsOneWidget);
        expect(find.text('没有公开价'), findsOneWidget);
        expect(find.textContaining('条按长上下文计'), findsNothing);
        await t.tap(find.text('opus'));
        await t.pumpAndSettle();
        expect(find.text('写缓存（存 5 分钟）'), findsOneWidget);
        expect(find.text(r'$0.2'), findsOneWidget);
        expect(find.text('未标记'), findsNothing);
        await t.tap(find.text('unlisted'));
        await t.pumpAndSettle();
        expect(find.text('—'), findsNWidgets(5));
      });
      testWidgets('空节假日按接口偏移时段且不猜年份', (t) async {
        await showSettings(
          t,
          SettingsGateway([
            model(
              'timed',
              timeOfDay: timed(empty: true),
              marks: {'tod:offpeak': 1},
            ),
          ]),
          width: width,
        );
        expect(find.textContaining('尚未登记节假日'), findsNothing);
        await t.tap(find.text('timed'));
        await t.pumpAndSettle();
        expect(find.textContaining('尚未登记节假日'), findsOneWidget);
        expect(find.textContaining('UTC-5:30'), findsOneWidget);
        expect(find.text('周日、周六 01:00–02:00'), findsOneWidget);
        expect(find.textContaining('节假日仅登记到'), findsNothing);
      });
      testWidgets('旧响应可空字段和空分档仍为基础价格', (t) async {
        await showSettings(
          t,
          SettingsGateway([
            model('legacy', marks: {}),
            model('empty-tiers', tiers: []),
          ]),
          width: width,
        );
        expect(find.text(r'输入 $2 · 输出 $10'), findsNWidgets(2));
        await t.tap(find.text('legacy'));
        await t.pumpAndSettle();
        expect(find.text('新输入'), findsOneWidget);
        expect(find.textContaining('条按长上下文计'), findsNothing);
        expect(find.bySemanticsLabel('legacy 条件价格'), findsNothing);
      });
    });
  }
  testWidgets('四种价格状态与计费方式分开，外链由 openLink 打开', (t) async {
    Uri? opened;
    await showSettings(
      t,
      SettingsGateway([
        model('official', url: 'https://a.example/p'),
        model('estimate', state: 'aggregate'),
        model('plan', state: 'aggregate', billing: 'plan'),
        model('unknown', state: 'unknown', prices: null),
      ]),
      openLink: (uri) async {
        opened = uri;
        return true;
      },
    );
    expect(find.text('已对照官方价'), findsNWidgets(2));
    expect(find.text('估算价'), findsNWidgets(3));
    expect(find.text('查不到价格'), findsNWidgets(2));
    expect(inRow('plan', '估算价'), findsOneWidget);
    expect(inRow('plan', '套餐'), findsOneWidget);
    expect(find.text('fixture · 内置'), findsNothing);
    await t.tap(find.text('official'));
    await t.pumpAndSettle();
    await t.tap(find.text('官方价格页'));
    await t.pump();
    expect(opened.toString(), 'https://a.example/p');
    expect(find.text('新输入'), findsOneWidget);
    await t.tap(find.text('关于这台电脑上的 Token Lens'));
    await t.pumpAndSettle();
    for (final text in [
      'demo',
      '/synthetic-preview',
      '/synthetic-preview/ledger.db',
      '5',
      'fixture · 内置',
    ]) {
      expect(find.text(text), findsOneWidget);
    }
  });
  testWidgets('模型行支持 Enter 和 Space', (t) async {
    await showSettings(t, SettingsGateway([model('keyboard')]));
    final context = t.element(priceRow('keyboard'));
    Focus.of(context).requestFocus();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(find.text('新输入'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pumpAndSettle();
    expect(find.text('新输入'), findsNothing);
  });
  testWidgets('条件价表铺满可用宽度，窄屏保持至少 520 并能横向滚动', (t) async {
    for (final width in [1100.0, 360.0]) {
      await showSettings(
        t,
        SettingsGateway([
          model(
            'responsive',
            tiers: [const StatsPriceTier(above: 272000, prices: high)],
            marks: {},
          ),
        ]),
        width: width,
      );
      await t.tap(find.text('responsive'));
      await t.pumpAndSettle();
      final region = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == '条件价格表，可横向滚动',
      );
      final table = find.descendant(of: region, matching: find.byType(Table));
      final expected =
          (t.getSize(find.byType(SettingsPrices)).width -
                  (width < 768 ? 24 : 20))
              .clamp(520.0, double.infinity);
      expect(t.getSize(table).width, expected);
      if (width == 360) {
        final scroll = find.descendant(
          of: region,
          matching: find.byType(Scrollable),
        );
        final position = t.state<ScrollableState>(scroll).position;
        expect(position.maxScrollExtent, greaterThan(0));
        await t.drag(scroll, const Offset(-120, 0));
        await t.pumpAndSettle();
        expect(position.pixels, greaterThan(0));
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
    }
  });
}
