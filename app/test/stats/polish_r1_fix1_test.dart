import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/date_range.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats/widgets/sync_status.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import '../support/fake_news_gateway.dart';
import 'demo_visual_support.dart';
import 'fake_gateway.dart';
import 'language_test.dart' as language;

final _now = DateTime(2026, 11, 19, 11, 15);

class _LayoutGateway extends language.LanguageGateway
    implements StatsSessionQueryGateway {
  @override
  Future<StatsDiscovery> discovery({bool fresh = false}) async {
    final data = await super.discovery(fresh: fresh);
    return StatsDiscovery(
      sources: data.sources,
      supported: data.supported,
      tools: const [
        StatsDiscoveredTool(source: 'claude', status: 'found', directories: []),
        StatsDiscoveredTool(source: 'codex', status: 'found', directories: []),
        StatsDiscoveredTool(source: 'kimi', status: 'missing', directories: []),
      ],
    );
  }

  @override
  Future<StatsSessions> querySessions(
    StatsFilter filter,
    StatsSessionQuery query,
  ) async => const StatsSessions(
    items: [
      StatsSessionItem(
        source: 'claude',
        sessionId: 'layout',
        projectKey: '/synthetic/inventory',
        startedAt: '2026-11-12T23:18:00',
        lastSeenAt: '2026-11-17T20:03:00',
        grossTokens: 585201,
        requestCount: 1234,
        costUsd: '12.080000',
        costMicros: 12080000,
        unpricedRecords: 0,
        hasCumulative: false,
        recordCount: 1234,
        cumulative: StatsTotals(
          grossTokens: 585201,
          recordCount: 1234,
          requestCount: 1234,
          unpricedRecords: 0,
        ),
      ),
      StatsSessionItem(
        source: 'codex',
        sessionId: 'older',
        projectKey: '/synthetic/warehouse-migration',
        startedAt: '2026-10-31T02:07:00',
        lastSeenAt: '2026-11-05T03:02:00',
        grossTokens: 4300000,
        requestCount: 19,
        costUsd: '10.200000',
        costMicros: 10200000,
        unpricedRecords: 0,
        hasCumulative: false,
        recordCount: 19,
        cumulative: StatsTotals(
          grossTokens: 4320000,
          recordCount: 23,
          requestCount: 23,
          unpricedRecords: 0,
        ),
      ),
    ],
    snapshot: demoSnapshot,
  );
}

Future<void> _mount(
  WidgetTester tester,
  String locale,
  Size size, {
  bool onboarded = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await loadSystemFonts(tester);
  final stats = StatsController(
    _LayoutGateway()..empty = !onboarded,
    clock: () => _now,
    preferences: UiPreferences(
      language: locale,
      onboarded: onboarded,
      autoCheckUpdates: false,
    ),
  );
  final news = NewsController(
    FakeNewsGateway(cached: cachedNews),
    now: () => _now,
  );
  addTearDown(stats.dispose);
  addTearDown(news.dispose);
  if (onboarded) {
    await stats.load();
  } else {
    await stats.onboardingRequired();
  }
  await news.load();
  await tester.pumpWidget(
    MaterialApp(
      theme: const LensPalette(false).theme,
      builder: (_, child) =>
          AppLanguageScope(strings: stats.strings, child: child!),
      home: StatsPage(
        controller: stats,
        newsListenable: news,
        news: NewsPage(
          controller: news,
          openLink: (_) async => true,
          now: () => _now,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(StatsPage), findsOneWidget);
}

Finder _within(Finder parent, Finder child) =>
    find.descendant(of: parent, matching: child);

Rect _fill(WidgetTester tester, Finder field) {
  final box = InputDecorator.containerOf(
    tester.element(_within(field, find.byType(EditableText))),
  )!;
  return box.localToGlobal(Offset.zero) & box.size;
}

void _oneLine(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderParagraph>(finder);
  expect(
    box.didExceedMaxLines,
    isFalse,
    reason: '${box.text.toPlainText()} must fit in one line',
  );
  expect(
    box.size.height,
    closeTo(box.getMinIntrinsicHeight(double.infinity), 0.1),
    reason: box.text.toPlainText(),
  );
  expect(
    box.size.width,
    greaterThanOrEqualTo(box.getMaxIntrinsicWidth(double.infinity) - 0.1),
    reason: box.text.toPlainText(),
  );
}

void main() {
  group('Windows system-font layout', _layoutTests, skip: !Platform.isWindows);
}

void _layoutTests() {
  for (final locale in ['en', 'zh']) {
    final strings = resolveStrings(locale, 'en');
    const desktop = Size(1180, 820);

    testWidgets('FIX1 painted input fills and toolbar alignment $locale', (
      tester,
    ) async {
      await _mount(tester, locale, desktop);
      await language.navigate(tester, 'sessions');
      final search = find.byType(LensInput);
      final sort = find.byKey(const Key('sessions-sort'));
      expect(
        _fill(tester, search).size.height,
        32,
        reason: 'Sessions search fill',
      );
      expect(
        _fill(tester, search).center.dy,
        closeTo(tester.getCenter(sort).dy, 0.1),
      );
      await language.navigate(tester, 'sources');
      final sourceChip = find.byKey(const ValueKey('source-filter-all'));
      expect(
        _fill(tester, search).size.height,
        tester.getSize(sourceChip).height,
      );
      await language.navigate(tester, 'news');
      final newsSearch = find.byKey(const Key('news-search'));
      final newsFilter = find.byKey(const Key('news-filter'));
      expect(_fill(tester, newsSearch).size.height, 28);
      expect(
        _fill(tester, newsSearch).center.dy,
        closeTo(tester.getCenter(newsFilter).dy, 0.1),
      );
      await language.navigate(tester, 'home');
      await tester.tap(
        _within(
          find.byType(PeriodControl),
          find.byIcon(Icons.calendar_month_outlined),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in [strings.from, strings.to]) {
        expect(_fill(tester, find.byKey(Key('range-$label'))).size.height, 28);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'FIX1 header title and controls share a row above a full-width description $locale',
      (tester) async {
        await _mount(tester, locale, desktop);
        for (final page in ['home', 'detail']) {
          await language.navigate(tester, page);
          final title = _within(
            find.byType(StatsSyncTitle),
            find.text(
              page == 'home' ? strings.noonGreeting(11) : strings.breakdown,
            ),
          );
          final headerControls = find.byType(LensHeaderControls);
          final period = find.byType(PeriodControl);
          final view = _within(
            headerControls,
            find.byType(LensSegmented),
          ).first;
          final summary = page == 'home'
              ? find
                    .byWidgetPredicate(
                      (w) => w is Text && w.textSpan != null && w.style == null,
                    )
                    .first
              : find.text(
                  strings.breakdownDescription(
                    const StatsPeriod('week').inSentence(strings),
                  ),
                );
          _oneLine(tester, title);
          expect(
            tester.getRect(period).center.dy,
            closeTo(tester.getRect(view).center.dy, 0.1),
          );
          expect(
            tester.getCenter(title).dy,
            closeTo(tester.getCenter(period).dy, 0.1),
          );
          expect(
            tester.getTopRight(title).dx,
            lessThan(tester.getTopLeft(view).dx),
          );
          expect(
            tester.getRect(summary).top,
            greaterThanOrEqualTo(tester.getRect(title).bottom),
          );
          expect(
            tester.getRect(summary).left,
            closeTo(tester.getRect(title).left, 0.1),
          );
          expect(
            tester.getRect(summary).right,
            greaterThanOrEqualTo(tester.getRect(period).right - 0.1),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );

    for (final size in [desktop, const Size(1024, 768)]) {
      testWidgets(
        'FIX1 session values fit on single lines $locale ${size.width}',
        (tester) async {
          await _mount(tester, locale, size);
          await language.navigate(tester, 'sessions', {'period': 'month'});
          final row = find.byKey(const Key('session-row-claude:layout'));
          final older = find.byKey(const Key('session-row-codex:older'));
          for (final session in [row, older]) {
            final texts = _within(session, find.byType(Text));
            expect(texts.evaluate().length, greaterThanOrEqualTo(9));
            for (final widget in tester.widgetList<Text>(texts)) {
              final text = find.byWidget(widget);
              _oneLine(tester, text);
              expect(
                tester.getRect(text).height,
                closeTo(tester.getSize(text).height, 0.1),
                reason: widget.data,
              );
              expect(
                tester.getTopRight(text).dx,
                lessThanOrEqualTo(tester.getTopRight(session).dx),
              );
            }
          }
          final table = find.ancestor(
            of: row,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is SingleChildScrollView &&
                  w.scrollDirection == Axis.horizontal,
            ),
          );
          final scroll = _within(table, find.byType(Scrollable));
          expect(
            tester.state<ScrollableState>(scroll).position.maxScrollExtent,
            0,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'FIX1 disclosure arrows and labels start at their leading inset $locale',
      (tester) async {
        await _mount(tester, locale, desktop);
        await language.navigate(tester, 'sources');
        void check(Finder row, double inset) {
          final arrow = _within(row, find.byType(LensDisclosureArrow));
          final label = _within(row, find.byType(Text));
          expect(
            tester.getRect(arrow).left - tester.getRect(row).left,
            closeTo(inset, 0.1),
          );
          expect(
            tester.getRect(label).left - tester.getRect(arrow).right,
            closeTo(6, 0.1),
          );
          expect(
            tester.getRect(label).center.dy,
            closeTo(tester.getRect(arrow).center.dy, 0.1),
          );
        }

        check(find.widgetWithText(LensDisclosure, strings.lastSyncDetails), 14);
        check(find.byKey(const ValueKey('source-group-missing')), 12);
        await _mount(tester, locale, desktop, onboarded: false);
        check(find.byType(LensDisclosure), 18);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'FIX1 onboarding checkbox card matches the previous insets and height $locale',
      (tester) async {
        await _mount(tester, locale, desktop, onboarded: false);
        final checkbox = find.byType(LensCheckbox);
        final card = find
            .ancestor(of: checkbox, matching: find.byType(LensCard))
            .first;
        final square = _within(
          checkbox,
          find.byWidgetPredicate(
            (w) =>
                w is AnimatedContainer &&
                w.constraints?.maxWidth == 16 &&
                w.constraints?.maxHeight == 16,
          ),
        );
        final title = find.text(strings.localStatisticsOnly);
        expect(tester.getSize(card).height, 80);
        expect(
          tester.getRect(square).center.dx - tester.getRect(card).left,
          closeTo(32, 0.1),
        );
        expect(
          tester.getRect(square).center.dy,
          closeTo(tester.getRect(card).center.dy, 0.1),
        );
        expect(
          tester.getRect(title).left - tester.getRect(card).left,
          closeTo(68, 0.1),
        );
        await tester.tap(title);
        await tester.pumpAndSettle();
        expect(tester.widget<LensCheckbox>(checkbox).value, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
