import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/logic/comparison.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'f1_polish_test.dart' show PolishGateway, mountPolish;

Future<StatsController> _mountOverview(
  WidgetTester tester,
  String language,
) async {
  tester.view.physicalSize = const Size(1440, 1440);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = StatsController(
    _AcceptanceGateway(),
    clock: () => DateTime(2026, 11, 19),
    preferences: UiPreferences(
      onboarded: true,
      language: language,
      period: const StatsPeriod('last7'),
    ),
  );
  addTearDown(controller.dispose);
  await controller.load();
  await tester.pumpWidget(
    MaterialApp(
      theme: const LensPalette(false).theme,
      builder: (context, child) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) =>
            AppLanguageScope(strings: controller.strings, child: child!),
      ),
      home: StatsPage(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

class _AcceptanceGateway extends PolishGateway
    implements StatsComparisonGateway {
  @override
  Future<StatsComparison> comparison(
    String by,
    StatsFilter current,
    StatsFilter previous,
  ) async => StatsComparison(
    by: by,
    current: const StatsComparisonSide(
      totals: StatsTotals(
        grossTokens: 7516000,
        costMicros: 7070000,
        recordCount: 2,
        unpricedRecords: 1,
      ),
      groups: [
        StatsGroup(
          key: '/synthetic/checkout',
          grossTokens: 7070000,
          costMicros: 7070000,
          recordCount: 1,
          unpricedRecords: 0,
          requestCount: 1,
          eventGrossTokens: 7070000,
        ),
        StatsGroup(
          key: '/synthetic/search',
          grossTokens: 446000,
          recordCount: 1,
          unpricedRecords: 1,
        ),
      ],
    ),
    previous: const StatsComparisonSide(
      totals: StatsTotals(
        grossTokens: 2760000,
        costMicros: 2350000,
        recordCount: 2,
        unpricedRecords: 1,
      ),
      groups: [
        StatsGroup(
          key: '/synthetic/checkout',
          grossTokens: 2350000,
          costMicros: 2350000,
          recordCount: 1,
          unpricedRecords: 0,
        ),
        StatsGroup(
          key: '/synthetic/migration',
          grossTokens: 410000,
          recordCount: 1,
          unpricedRecords: 1,
        ),
      ],
    ),
  );
}

void main() {
  for (final (strings, checkout, search, dates) in [
    (
      chineseStrings,
      '235万 → 707万',
      '0 → 44.6万',
      '11月13日 – 11月19日 对比 11月6日 – 11月12日',
    ),
    (
      englishStrings,
      '2.4M → 7.1M',
      '0 → 446K',
      'Nov 13 – Nov 19 vs. Nov 6 – Nov 12',
    ),
  ]) {
    testWidgets(
      'S5 panel shows previous then current (${strings.languageCode})',
      (tester) async {
        await _mountOverview(tester, strings.languageCode);
        await tester.tap(find.text(strings.seeWhatChanged));
        await tester.pumpAndSettle();
        expect(find.text(checkout), findsOneWidget);
        expect(find.text(search), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('comparison-metric')),
            matching: find.text(strings.trendCost),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(r'$2.35 → $7.07'), findsOneWidget);
      },
    );

    testWidgets(
      'S5 both comparison subtitles localize dates (${strings.languageCode})',
      (tester) async {
        await _mountOverview(tester, strings.languageCode);
        await tester.tap(find.text(strings.seeWhatChanged));
        await tester.pumpAndSettle();
        expect(find.text(dates), findsOneWidget);
        await tester.tap(find.text('checkout'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('detail-compare')));
        await tester.pumpAndSettle();
        expect(find.text(dates), findsOneWidget);
      },
    );
  }

  testWidgets(
    'S5 overview sentence honors the numeric unit setting and language',
    (tester) async {
      final c = await _mountOverview(tester, 'zh');
      Finder sentence(String text) =>
          find.textContaining(text, findRichText: true);
      expect(sentence('。增加最多的是 checkout（+472万 token）。'), findsOneWidget);
      await c.setPreferences(c.preferences.copyWith(unitSystem: 'english'));
      await tester.pumpAndSettle();
      expect(sentence('。增加最多的是 checkout（+4.7M token）。'), findsOneWidget);
      await c.setPreferences(c.preferences.copyWith(language: 'en'));
      await tester.pumpAndSettle();
      expect(
        sentence('. The biggest increase was checkout (+4.7M tokens).'),
        findsOneWidget,
      );
    },
  );

  test('S5 comparison dates include day counts only for unequal ranges', () {
    const date = (from: '2026-11-19', to: '2026-11-19');
    const prior = (from: '2026-11-18', to: '2026-11-18');
    expect(comparisonSubtitle(date, prior, chineseStrings), '11月19日 对比 11月18日');
    expect(
      comparisonSubtitle(date, prior, englishStrings),
      'Nov 19 vs. Nov 18',
    );
    const october = (from: '2026-10-01', to: '2026-10-31');
    const september = (from: '2026-09-01', to: '2026-09-30');
    expect(
      comparisonSubtitle(october, september, chineseStrings),
      '10月1日 – 10月31日（31 天） 对比 9月1日 – 9月30日（30 天）',
    );
    expect(
      comparisonSubtitle(october, september, englishStrings),
      'Oct 1 – Oct 31 (31 days) vs. Sep 1 – Sep 30 (30 days)',
    );
  });

  for (final (width, compact) in [(1024.0, true), (1440.0, false)]) {
    testWidgets(
      'S5 unused comparison row shows three empty cells at ${width.toInt()}',
      (tester) async {
        await mountPolish(
          tester,
          gateway: _AcceptanceGateway(),
          page: 'detail',
          query: 'period=last7&dim=project&compare=1',
          width: width,
        );
        Finder row(String project) =>
            find.byKey(Key('detail-row-/synthetic/$project'));
        Finder cell(String project, String text) =>
            find.descendant(of: row(project), matching: find.text(text));
        expect(cell('migration', '本期未用'), findsOneWidget);
        expect(
          cell('migration', chineseStrings.estimatedCostPrefix),
          compact ? findsOneWidget : findsNothing,
        );
        expect(cell('migration', '—'), findsNWidgets(7));
        expect(cell('migration', chineseStrings.unpriced), findsNothing);
        expect(cell('migration', chineseStrings.notLogged), findsNothing);
        expect(cell('search', chineseStrings.unpriced), findsOneWidget);
        expect(cell('search', chineseStrings.notLogged), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
