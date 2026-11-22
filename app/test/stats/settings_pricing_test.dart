import 'dart:async';
import 'dart:convert';
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
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/update/update_check.dart';

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
  StatsManualPrice? manual,
  StatsPrices? listPrices,
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
  manual: manual,
  listPrices: listPrices,
);

class SettingsGateway extends FakeStatsGateway implements StatsPricingEditor {
  SettingsGateway(this.models);
  final List<StatsModelPrice> models;
  List<StatsGroup> usage = [];
  bool healthFails = false;
  int healthReads = 0, priceReads = 0, usageReads = 0;
  String? publishedAt, saveError, attemptedSave, removed;
  bool downloaded = false;
  var catalogRemovals = 0;
  List<StatsCopyPrice> copyPrices = [];

  @override
  Future<StatsPriceInstall> installPriceCatalog(String text) async =>
      const StatsPriceInstall(kind: 'unchanged');
  @override
  Future<void> removePriceCatalog() async {
    catalogRemovals++;
  }

  @override
  Future<void> removeManualPrice(String model) async {
    removed = model;
  }

  @override
  Future<void> saveManualPrice(String text) async {
    attemptedSave = text;
    if (saveError case final error?) throw StateError(error);
  }

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
        manual: models.where((m) => m.state == 'manual').length,
      ),
      snapshot: demoSnapshot,
      publishedAt: publishedAt,
      builtinPublishedAt: publishedAt == null ? null : '2026-11-22',
      downloaded: downloaded,
      copyPrices: copyPrices,
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
  SettingsController(
    super.gateway, {
    super.preferences,
    super.pricingRequest,
    super.clock,
  });
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
  UpdateRequest? pricingRequest,
  String query = '',
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 2400);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = SettingsController(
    gateway,
    preferences: preferences,
    pricingRequest: pricingRequest,
    clock: () => demoNow,
  );
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
                query: query,
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

Future<void> showPriceEstimate(
  WidgetTester tester, {
  required StatsPrices prices,
  required int inputTokens,
  int? outputTokens,
  int? cacheReadTokens,
  int? cacheWriteTokens,
  UiPreferences preferences = const UiPreferences(currency: 'USD'),
}) async {
  const id = 'demo-unpriced-model';
  final gateway = SettingsGateway([model(id, state: 'unknown', prices: null)])
    ..copyPrices = [
      StatsCopyPrice(id: 'catalog-model', prices: prices, baseOnly: false),
    ]
    ..usage = [
      StatsGroup(
        source: 'claude',
        model: id,
        grossTokens:
            inputTokens +
            (outputTokens ?? 0) +
            (cacheReadTokens ?? 0) +
            (cacheWriteTokens ?? 0),
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cacheReadTokens: cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens,
        unpricedRecords: 1,
        recordCount: 1,
      ),
    ];
  await showSettings(tester, gateway, preferences: preferences);
  await tester.tap(priceRow(id));
  await tester.pumpAndSettle();
  await tester.tap(find.text('填写价格'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('manual-price-copy')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('catalog-model').last);
  await tester.pumpAndSettle();
}

Finder priceEstimate() => find.textContaining('条记录按这个价算，约');

void main() {
  testWidgets('未定价模型可打开共用价格对话框', (t) async {
    await showSettings(
      t,
      SettingsGateway([
        model('demo-unpriced-model', state: 'unknown', prices: null),
      ]),
    );
    await t.tap(priceRow('demo-unpriced-model'));
    await t.pumpAndSettle();
    await t.tap(find.text('填写价格'));
    await t.pumpAndSettle();
    expect(find.text('照已有模型的价格填'), findsOneWidget);
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(find.text('输入和输出价格要填。'), findsWidgets);
  });

  testWidgets('复制基础价、编辑复位、币种和分项预估、Rust 拒绝保留表单', (t) async {
    final gateway =
        SettingsGateway([
            model('demo-unpriced-model', state: 'unknown', prices: null),
          ])
          ..saveError = 'MODEL_ALREADY_PRICED'
          ..copyPrices = [
            const StatsCopyPrice(
              id: 'catalog-model',
              prices: StatsPrices(input: 2, output: 10, cacheWrite5M: 3),
              baseOnly: true,
            ),
          ]
          ..usage = [
            const StatsGroup(
              source: 'claude',
              model: 'demo-unpriced-model',
              grossTokens: 4000000,
              inputTokens: 1000000,
              outputTokens: 1000000,
              cacheReadTokens: 1000000,
              cacheWriteTokens: 1000000,
              unpricedRecords: 1,
              recordCount: 1,
            ),
          ];
    final c = await showSettings(
      t,
      gateway,
      query: 'prices=missing',
      preferences: const UiPreferences(
        currency: 'USD',
        rates: {'USD': 1, 'CNY': 7},
      ),
    );
    await t.ensureVisible(find.text('填写价格'));
    await t.tap(find.text('填写价格'));
    await t.pumpAndSettle();
    final copy = find.byKey(const ValueKey('manual-price-copy'));
    final input = find.byKey(const ValueKey('manual-price-0'));
    final output = find.byKey(const ValueKey('manual-price-1'));
    expect(
      t
          .widget<EditableText>(
            find.descendant(of: input, matching: find.byType(EditableText)),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
    await t.tap(copy);
    await t.pumpAndSettle();
    await t.tap(find.text('catalog-model （只复制基础价）').last);
    await t.pumpAndSettle();
    expect(t.widget<LensInput>(input).controller.text, '2');
    expect(t.widget<LensInput>(output).controller.text, '10');
    expect(find.textContaining('约 \$15.00（'), findsOneWidget);
    expect(find.textContaining('缓存写 \$3.00）'), findsOneWidget);
    expect(find.text('缓存读留空，这部分 token 不计金额。'), findsOneWidget);
    expect(find.text('照 catalog-model 的官方价'), findsOneWidget);
    await t.enterText(input, '-1');
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(t.widget<DropdownButton<String>>(copy).value, '');
    expect(find.text('价格只能填 0 或正数。'), findsOneWidget);
    await t.enterText(input, '7');
    await t.tap(
      find.descendant(of: find.byType(Dialog), matching: find.text('人民币 ¥')),
    );
    await t.pumpAndSettle();
    expect(find.text('按 1 美元 ≈ 7.00 元折成美元保存，以后汇率变了也不跟着变。'), findsOneWidget);
    await c.setPreferences(
      c.preferences.copyWith(rates: const {'USD': 1, 'CNY': 8}),
    );
    await t.pumpAndSettle();
    expect(find.text('按 1 美元 ≈ 8.00 元折成美元保存，以后汇率变了也不跟着变。'), findsOneWidget);
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(jsonDecode(gateway.attemptedSave!)['rate'], 8);
    expect(find.textContaining('MODEL_ALREADY_PRICED'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text('照已有模型的价格填'), findsNothing);
  });

  testWidgets('预估总额和各分项通常显示两位小数', (t) async {
    await showPriceEstimate(
      t,
      prices: const StatsPrices(input: 2, output: 1, cacheRead: .5),
      inputTokens: 1000000,
      outputTokens: 1000000,
      cacheReadTokens: 1000000,
    );
    expect(
      find.textContaining(r'约 $3.50（新输入 $2.00 · 输出 $1.00 · 缓存读 $0.50）'),
      findsOneWidget,
    );
  });

  testWidgets('预估按显示币种判断不足 0.01 的金额并显示四位小数', (t) async {
    await showPriceEstimate(
      t,
      prices: const StatsPrices(input: 1, output: 2),
      inputTokens: 700,
      outputTokens: 2550,
      preferences: const UiPreferences(
        currency: 'CNY',
        rates: {'USD': 1, 'CNY': 2},
      ),
    );
    expect(
      find.textContaining('约 ¥0.01（新输入 ¥0.0014 · 输出 ¥0.01）'),
      findsOneWidget,
    );
    await t.enterText(find.byKey(const ValueKey('manual-price-1')), '1');
    await t.pumpAndSettle();
    expect(
      find.textContaining('约 ¥0.0065（新输入 ¥0.0014 · 输出 ¥0.0051）'),
      findsOneWidget,
    );
  });

  testWidgets('预估省略 token 未知、为零和价格留空的分项', (t) async {
    await showPriceEstimate(
      t,
      prices: const StatsPrices(input: 2, output: 1, cacheWrite5M: 3),
      inputTokens: 1000000,
      outputTokens: 0,
      cacheReadTokens: 1000000,
    );
    final text = t.widget<Text>(priceEstimate()).data!;
    expect(text, isNot(contains('缓存写')));
    expect(text, isNot(contains('输出')));
    expect(text, isNot(contains('缓存读')));
    expect(find.text('缓存读留空，这部分 token 不计金额。'), findsOneWidget);
  });

  testWidgets('手填卡片显示人民币与来源，目录补价后只提供直接改用', (t) async {
    const manual = StatsManualPrice(
      currency: 'CNY',
      original: StatsPrices(input: 7, output: 14),
      rate: 7,
      note: 'example source',
      createdAt: '2026-11-21T12:00:00Z',
      updatedAt: '2026-11-21T12:00:00Z',
    );
    for (final hasListPrice in [false, true]) {
      final gateway = SettingsGateway([
        model(
          'manual-demo',
          state: 'manual',
          manual: manual,
          listPrices: hasListPrice ? base : null,
        ),
      ])..publishedAt = '2026-11-22';
      await showSettings(t, gateway);
      expect(find.text('手填'), findsNWidgets(2));
      expect(find.textContaining('¥7'), findsOneWidget);
      await t.tap(priceRow('manual-demo'));
      await t.pumpAndSettle();
      expect(find.text('出处：example source'), findsOneWidget);
      expect(find.text('按 1 美元 ≈ 7.00 元折成美元计算。'), findsOneWidget);
      if (hasListPrice) {
        expect(find.text('删除手填价'), findsNothing);
        await t.tap(find.text('改用价格表的价'));
        await t.pumpAndSettle();
        expect(find.text('删除手填价？'), findsNothing);
      } else {
        expect(find.text('改用价格表的价'), findsNothing);
        await t.tap(find.text('删除手填价'));
        await t.pumpAndSettle();
        expect(find.textContaining('回到「未定价」'), findsOneWidget);
        await t.tap(find.text('删除'));
        await t.pumpAndSettle();
      }
      expect(gateway.removed, 'manual-demo');
      expect(gateway.syncs, 1);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
    }
  });

  testWidgets('联网四种状态、检查中禁用和关于版本', (t) async {
    final pending = Completer<UpdateResponse>();
    final gateway = SettingsGateway([model('demo')])
      ..publishedAt = '2026-11-22';
    final c = await showSettings(
      t,
      gateway,
      preferences: UiPreferences(
        onboarded: true,
        pricingCheckedMs: demoNow.millisecondsSinceEpoch,
      ),
      pricingRequest: (_, _, _) => pending.future,
    );
    expect(find.textContaining('正在用'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^· .*检查过$')), findsOneWidget);
    await t.tap(find.text('立即更新'));
    await t.pump();
    expect(find.text('正在检查…'), findsOneWidget);
    pending.complete(const UpdateResponse(403, ''));
    await t.pumpAndSettle();
    expect(find.text('没更新成功，GitHub 暂时拒绝了请求。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await c.setPreferences(
      c.preferences.copyWith(
        pricingLastKind: 'installed',
        pricingUpdatedNote: (publishedAt: '2026-11-23', newlyPriced: 3),
      ),
    );
    gateway.downloaded = true;
    gateway.publishedAt = '2026-11-23';
    c.gateway.clear();
    c.reloadLedger();
    await t.pumpAndSettle();
    expect(find.textContaining('新增 3 个模型的价格'), findsOneWidget);
    await t.tap(find.text('关于这台电脑上的 Token Lens'));
    await t.pumpAndSettle();
    expect(
      find.text('联网 2026年11月23日版 · fixture（内置 2026年11月22日版）'),
      findsOneWidget,
    );
    gateway.downloaded = false;
    gateway.publishedAt = '2026-11-22';
    await c.pricingUpdates.setAutomatic(false);
    await t.pumpAndSettle();
    expect(find.text('只用程序自带的 2026年11月22日版价格表。'), findsOneWidget);
    expect(find.text('内置 2026年11月22日版 · fixture'), findsOneWidget);
    expect(gateway.catalogRemovals, 1);
  });

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
        await t.ensureVisible(scroll);
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
