import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats/widgets/timing.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'demo_visual_support.dart' show loadSystemFonts;
import 'fake_gateway.dart';
import 'timings_e4b_test.dart' show sample;
import 'timings_test.dart' show TimingDetail;

class _ModelGateway extends FakeStatsGateway {
  static const _models = [
    ('claude', 'claude-main', 200),
    ('cursor', 'cursor-main', 150),
    ('pi', 'pi-main', 100),
    ('claude', 'claude-small', 50),
  ];

  @override
  List<StatsGroup> groups(StatsFilter filter, {String by = 'source_model'}) =>
      by == 'source_model'
      ? [
          for (final (source, model, tokens) in _models)
            StatsGroup(
              key: '$source|$model',
              source: source,
              model: model,
              grossTokens: tokens,
              recordCount: 1,
              unpricedRecords: 0,
            ),
        ]
      : super.groups(filter, by: by);

  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) async => StatsSessions(
    items: [
      for (final (source, model, tokens) in _models)
        StatsSessionItem(
          source: source,
          sessionId: model,
          projectKey: '/synthetic/$model',
          startedAt: '2026-11-09T05:00:00Z',
          lastSeenAt: '2026-11-09T06:00:00Z',
          grossTokens: tokens,
          requestCount: 1,
          recordCount: 1,
          unpricedRecords: 0,
          hasCumulative: false,
          cumulative: const StatsTotals(
            grossTokens: 0,
            recordCount: 0,
            unpricedRecords: 0,
          ),
        ),
    ],
    snapshot: demoSnapshot,
  );

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
      projectKey: '/synthetic/$sessionId',
      startedAt: '2026-11-09T05:00:00Z',
      lastSeenAt: '2026-11-09T06:00:00Z',
      grossTokens: 150,
      inputTokens: 100,
      outputTokens: 50,
      recordCount: 2,
      unpricedRecords: 0,
    ),
    models: [
      for (final (name, tokens) in [('main', 100), ('small', 50)])
        StatsSessionModel(
          model: '$source-$name',
          grossTokens: tokens,
          priceState: 'verified',
          recordCount: 1,
          unpricedRecords: 0,
        ),
    ],
    timeline: const [],
    kinds: const StatsSessionKinds(event: 2, cumulative: 0),
    granularity: granularity,
    snapshot: demoSnapshot,
  );
}

Future<void> _mount(
  WidgetTester tester,
  FakeStatsGateway gateway, {
  String language = 'zh',
  double width = 1440,
  bool dark = false,
}) async {
  tester.view.physicalSize = Size(width, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = StatsController(
    gateway,
    clock: () => demoNow,
    prefetchEnabled: false,
    preferences: UiPreferences(
      language: language,
      onboarded: true,
      period: const StatsPeriod('all'),
    ),
  );
  addTearDown(controller.dispose);
  await controller.load();
  await tester.pumpWidget(
    MaterialApp(
      theme: LensPalette(dark).theme,
      builder: (context, child) => AppLanguageScope(
        strings: controller.strings,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
      ),
      home: StatsPage(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _navigate(
  WidgetTester tester,
  String page, [
  Map<String, String> params = const {},
]) async {
  final state = tester.state(find.byType(StatsPage)) as dynamic;
  state.navigate(page, params);
  await tester.pumpAndSettle();
}

Finder _within(Finder parent, Finder child) =>
    find.descendant(of: parent, matching: child);

Finder _card(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(LensCard)).first;

Color? _overviewBarColor(WidgetTester tester, Finder label) {
  final row = find.ancestor(of: label, matching: find.byType(InkWell)).first;
  final bar = tester.widget<FractionallySizedBox>(
    _within(row, find.byType(FractionallySizedBox)),
  );
  return (bar.child! as Container).color;
}

Iterable<Color?> _sessionModelColors(WidgetTester tester) => tester
    .widgetList<LinearProgressIndicator>(
      _within(
        _card(chineseStrings.modelsUsed),
        find.byType(LinearProgressIndicator),
      ),
    )
    .map((bar) => bar.color);

ToolTile _toolTile(WidgetTester tester, String source, double size) =>
    tester.widget<ToolTile>(
      find.byWidgetPredicate(
        (w) => w is ToolTile && w.id == source && w.size == size,
      ),
    );

void main() {
  for (final dark in [false, true]) {
    final palette = LensPalette(dark);
    final claude = dark ? palette.toolBrand('claude') : const Color(0xffd97757);
    testWidgets('总览的 Claude 模型共用工具色 dark=$dark', (tester) async {
      await _mount(tester, _ModelGateway(), dark: dark);
      final card = _card(chineseStrings.topModels);
      for (final model in ['claude-main', 'claude-small']) {
        expect(
          _overviewBarColor(tester, _within(card, find.text(model))),
          claude,
        );
      }
    });

    testWidgets('总览的 Pi 模型条沿用工具条的墨色档位 dark=$dark', (tester) async {
      await _mount(tester, _ModelGateway(), dark: dark);
      final piTool = _overviewBarColor(
        tester,
        find.byWidgetPredicate(
          (w) => w is ToolTile && w.id == 'pi' && w.size == 28,
        ),
      );
      expect(piTool, palette.toolInk(2));
      final piModel = _within(
        _card(chineseStrings.topModels),
        find.text('pi-main'),
      );
      expect(_overviewBarColor(tester, piModel), piTool);
    });
  }

  testWidgets('从会话列表打开 Claude 后两条模型条共用 Claude 工具色', (tester) async {
    await _mount(tester, _ModelGateway());
    await _navigate(tester, 'sessions');
    await tester.tap(find.byKey(const Key('session-row-claude:claude-main')));
    await tester.pumpAndSettle();
    const claude = Color(0xffd97757);
    expect(_toolTile(tester, 'claude', 40).accent, claude);
    expect(_sessionModelColors(tester), [claude, claude]);
  });

  testWidgets('Pi 会话从列表打开时沿用列表墨色', (tester) async {
    const palette = LensPalette(false);
    await _mount(tester, _ModelGateway());
    await _navigate(tester, 'sessions');
    final row = find.byKey(const Key('session-row-pi:pi-main'));
    final listTile = tester.widget<ToolTile>(
      _within(row, find.byType(ToolTile)),
    );
    final ink = palette.toolInk(2);
    expect(listTile.accent, ink);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(_toolTile(tester, 'pi', 40).accent, ink);
    expect(_sessionModelColors(tester), [ink, ink]);
  });

  testWidgets('Pi 会话从链接打开时用第一档墨色，即使列表已经加载', (tester) async {
    await _mount(tester, _ModelGateway());
    await _navigate(tester, 'sessions');
    await _navigate(tester, 'sessions', {'source': 'pi', 'session': 'pi-main'});
    final firstInk = const LensPalette(false).toolInk(1);
    expect(_toolTile(tester, 'pi', 40).accent, firstInk);
    expect(_sessionModelColors(tester), [firstInk, firstInk]);
  });

  testWidgets('会话 token 构成条按 token 种类上色', (tester) async {
    await _mount(tester, _ModelGateway());
    await _navigate(tester, 'sessions', {
      'source': 'claude',
      'session': 'claude-main',
    });
    final breakdown = find.byWidgetPredicate(
      (w) =>
          w is Semantics && w.properties.label == chineseStrings.tokenBreakdown,
    );
    final segments = tester
        .widgetList<Container>(_within(breakdown, find.byType(Container)))
        .map((box) => box.color);
    const palette = LensPalette(false);
    expect(segments, [palette.category(1), palette.category(2)]);
  });

  for (final language in ['en', 'zh']) {
    testWidgets('明细按模型的请求和对话计时指标左对齐 $language', (tester) async {
      await loadSystemFonts(tester);
      await _mount(
        tester,
        TimingDetail()..timing = sample('both'),
        language: language,
      );
      await _navigate(tester, 'detail', {'dim': 'model'});
      final row = find.byKey(const Key('detail-row-m'));
      final request = _within(row, find.byKey(const Key('detail-ttft-m')));
      final turn = _within(row, find.byKey(const Key('detail-turn-ttft-m')));
      expect(
        tester.getTopLeft(turn).dx,
        closeTo(tester.getTopLeft(request).dx, .5),
      );
    });
  }

  testWidgets('计时指标换行时第一个指标仍接在范围标签后', (tester) async {
    await loadSystemFonts(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: const LensPalette(false).theme,
        home: AppLanguageScope(
          strings: englishStrings,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 350,
                child: TimingStrip(
                  timing: sample('both'),
                  metricKey: (kind) => ValueKey(kind),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final label = tester.getRect(find.text(englishStrings.perRequest2));
    final first = tester.getRect(find.byKey(const ValueKey(TimingKind.ttft)));
    final last = tester.getRect(
      find.byKey(const ValueKey(TimingKind.throughput)),
    );
    expect(first.left, greaterThan(label.right));
    expect(first.center.dy, closeTo(label.center.dy, .5));
    expect(last.top, greaterThanOrEqualTo(first.bottom));
    expect(tester.takeException(), isNull);
  });
}
