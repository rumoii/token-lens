import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/sessions_page.dart';
import 'package:token_lens_app/stats/settings_page.dart';
import 'package:token_lens_app/stats/sources_page.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/update/update_check.dart';

import '../support/fake_news_gateway.dart';
import 'demo_visual_support.dart';
import 'fake_gateway.dart';
import 'language_test.dart' show LanguageGateway, navigate;
import 'onboarding_flow_test.dart' show OnboardingGateway;
import 'timings_test.dart' show exampleTiming;

final _now = DateTime(2026, 11, 19, 11);

class _Gateway extends LanguageGateway implements StatsSessionQueryGateway {
  @override
  int amount(StatsFilter filter) => empty ? 0 : 3846674;

  @override
  StatsTotals totals(StatsFilter filter) => StatsTotals(
    grossTokens: amount(filter),
    costUsd: '1.040000',
    costMicros: 1040000,
    unpricedRecords: 0,
    recordCount: empty ? 0 : 100,
  );

  @override
  Future<StatsSources> sources() async => empty
      ? const StatsSources(sources: [], snapshot: demoSnapshot)
      : super.sources();

  @override
  Future<StatsDiscovery> discovery({bool fresh = false}) async =>
      const StatsDiscovery(
        sources: [StatsDiscoveredSource(source: 'kimi', files: 1)],
        supported: 2,
        tools: [
          StatsDiscoveredTool(source: 'kimi', status: 'found', directories: []),
          StatsDiscoveredTool(
            source: 'codex',
            status: 'missing',
            directories: [],
          ),
        ],
      );

  @override
  Future<StatsSessions> querySessions(
    StatsFilter filter,
    StatsSessionQuery query,
  ) async => const StatsSessions(
    items: [
      StatsSessionItem(
        source: 'kimi',
        sessionId: 's1',
        startedAt: '2026-11-14T10:05:00',
        lastSeenAt: '2026-11-19T10:00:00',
        grossTokens: 42,
        requestCount: 1,
        unpricedRecords: 0,
        hasCumulative: false,
        recordCount: 1,
        cumulative: StatsTotals(
          grossTokens: 42,
          recordCount: 1,
          requestCount: 1,
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
      startedAt: '2026-11-14T10:05:00',
      lastSeenAt: '2026-11-19T10:00:00',
      grossTokens: 42,
      requestCount: 1,
      recordCount: 1,
      unpricedRecords: 0,
    ),
    models: const [],
    timeline: const [],
    kinds: const StatsSessionKinds(event: 1, cumulative: 0),
    granularity: granularity,
    snapshot: demoSnapshot,
    timing: exampleTiming('log_timestamps'),
  );
}

class _OnboardingGateway extends OnboardingGateway {
  @override
  Future<StatsSummary> summary(StatsFilter filter) async {
    final base = await super.summary(filter);
    return empty
        ? base
        : StatsSummary(
            totals: const StatsTotals(
              grossTokens: 68390000,
              recordCount: 806,
              unpricedRecords: 0,
            ),
            activity: const StatsActivity(
              sessions: 160,
              turns: 806,
              firstSeen: '2026-07-22T11:00:00',
            ),
            rolling: base.rolling,
            snapshot: base.snapshot,
          );
  }
}

Future<StatsController> _mount(
  WidgetTester tester,
  String locale, {
  FakeStatsGateway? gateway,
  double width = 1180,
  double textScale = 1,
  bool dark = false,
  bool onboarded = true,
  String tokenMode = 'compact',
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1200);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await loadSystemFonts(tester);
  final stats = StatsController(
    gateway ?? _Gateway(),
    clock: () => _now,
    preferences: UiPreferences(
      language: locale,
      onboarded: onboarded,
      period: const StatsPeriod('month'),
      autoCheckUpdates: false,
      newsEnabled: onboarded,
      tokenMode: tokenMode,
    ),
    updateRequest: (_, _, _) async => const UpdateResponse(503, ''),
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
      theme: LensPalette(dark).theme,
      builder: (context, child) => AppLanguageScope(
        strings: stats.strings,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
      ),
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
  return stats;
}

Finder _in(Finder parent, Finder child) =>
    find.descendant(of: parent, matching: child);
Finder _key(String key) => find.byKey(Key(key));
Finder _switchTrack(Finder control) => _in(
  control,
  find.byWidgetPredicate(
    (w) => w is AnimatedContainer && w.constraints?.maxWidth == 44,
  ),
);

double _baseline(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return box
      .localToGlobal(
        Offset(
          0,
          box.getDryBaseline(
            BoxConstraints.tight(box.size),
            TextBaseline.alphabetic,
          )!,
        ),
      )
      .dy;
}

Future<void> _finishOnboarding(
  WidgetTester tester,
  String locale, {
  double width = 1180,
  double textScale = 1,
  String tokenMode = 'compact',
}) async {
  await _mount(
    tester,
    locale,
    gateway: _OnboardingGateway(),
    onboarded: false,
    width: width,
    textScale: textScale,
    tokenMode: tokenMode,
  );
  final start = find.text(locale == 'zh' ? '开始统计' : 'Start counting');
  await tester.ensureVisible(start);
  await tester.tap(start);
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in ['zh', 'en']) {
    final zh = locale == 'zh';
    final strings = zh ? chineseStrings : englishStrings;

    testWidgets(
      'R2A 01 automatic updates use the right-aligned switch $locale',
      (tester) async {
        final stats = await _mount(tester, locale);
        await navigate(tester, 'settings');
        final title = find.text(
          zh ? '每天自动检查一次' : 'Check automatically once a day',
        );
        final automatic = find.ancestor(
          of: title,
          matching: find.byType(LensSwitch),
        );
        final news = find.widgetWithText(LensSwitch, zh ? 'AI 热点' : 'AI news');
        expect(automatic, findsOneWidget);
        final track = _switchTrack(automatic);
        expect(
          tester.getRect(title).right,
          lessThan(tester.getRect(track).left),
        );
        expect(
          tester.getRect(track).right,
          closeTo(tester.getRect(_switchTrack(news)).right, 1),
        );
        final hint = _in(
          automatic,
          find.text(strings.asksApiGithubComForTheLatest),
        );
        expect(
          tester.getTopLeft(hint).dx,
          closeTo(tester.getTopLeft(title).dx, 1),
        );
        await tester.ensureVisible(track);
        await tester.tap(track);
        await tester.pumpAndSettle();
        expect(stats.preferences.autoCheckUpdates, isTrue);
      },
    );

    testWidgets('R2A 02 empty ledger navigates to Tools $locale', (
      tester,
    ) async {
      await _mount(tester, locale, gateway: _Gateway()..empty = true);
      final tools = zh ? '工具' : 'Tools';
      final action = find.text(zh ? '查看工具' : 'View tools');
      expect(find.text(tools), findsOneWidget);
      expect(
        find.text(
          zh ? 'Token Lens 读取 AI 编程工具的日志。去「工具」页看看找到了哪些工具，或者立即同步。' : 'Token Lens reads AI coding tool logs. See which tools it found under Tools, or sync now.',
        ),
        findsOneWidget,
      );
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(
        _in(find.byType(StatsSourcesPage), find.text(tools)),
        findsWidgets,
      );
      expect(action, findsNothing);
    });

    testWidgets(
      'R2A 03 onboarding displays the localized calendar date $locale',
      (tester) async {
        await _finishOnboarding(tester, locale);
        expect(
          find.textContaining(zh ? '2026年7月22日' : 'Jul 22, 2026'),
          findsOneWidget,
        );
      },
    );

    for (final width in [1180.0, 1920.0]) {
      testWidgets(
        'R2A 04 daily rows show date, weekday and muted relative marker $locale $width',
        (tester) async {
          await _mount(tester, locale, width: width);
          if (!zh && width == 1920 && !requireWindowsLayoutFonts()) return;
          await navigate(tester, 'detail', {'period': 'month', 'dim': 'date'});
          for (final (bucket, date, relative) in [
            (
              '2026-11-19',
              zh ? '11月19日 周四' : 'Nov 19, Thu',
              zh ? '今天' : 'Today',
            ),
            (
              '2026-11-18',
              zh ? '11月18日 周三' : 'Nov 18, Wed',
              zh ? '昨天' : 'Yesterday',
            ),
            ('2026-11-17', zh ? '11月17日 周二' : 'Nov 17, Tue', null),
          ]) {
            final row = _key('detail-row-$bucket');
            final labelText = relative == null ? date : '$date · $relative';
            final label = _in(row, find.text(labelText));
            expect(label, findsOneWidget);
            final paragraph = tester.renderObject<RenderParagraph>(label);
            expect(
              paragraph.getBoxesForSelection(
                TextSelection(
                  baseOffset: labelText.length - 1,
                  extentOffset: labelText.length,
                ),
              ),
              isNotEmpty,
              reason: labelText,
            );
            if (relative != null) {
              final spans = tester.widget<Text>(label).textSpan as TextSpan;
              final suffix = spans.children!.whereType<TextSpan>().last;
              expect(suffix.toPlainText(), ' · $relative');
              expect(
                suffix.style?.color,
                LensPalette.of(tester.element(label)).secondary,
              );
            }
          }
          await navigate(tester, 'detail', {'period': 'today', 'dim': 'date'});
          expect(
            _in(_key('detail-row-2026-11-19T00:00:00'), find.text('0:00')),
            findsOneWidget,
          );
        },
      );
    }

    testWidgets('R2A 05 usage sort and column follow selected period $locale', (
      tester,
    ) async {
      await _mount(tester, locale, width: 1440);
      for (final (period, label, inSentence) in [
        ('month', zh ? '本月' : 'This month', 'This month'),
        ('week', zh ? '本周' : 'This week', 'This week'),
        ('last7', zh ? '最近 7 天' : 'Last 7 days', 'the last 7 days'),
      ]) {
        final usage = zh ? '$label用量' : 'Usage · $label';
        await navigate(tester, 'sessions', {'period': period, 'sort': 'cost'});
        expect(find.text(usage), findsOneWidget);
        final sort = _key('sessions-sort');
        await tester.tap(sort);
        await tester.pumpAndSettle();
        await tester.tap(find.text(usage).last);
        await tester.pumpAndSettle();
        expect(_in(sort, find.text(usage)), findsOneWidget);
        expect(
          find.text(
            zh
                ? '$label有用量的会话，按$label用量排序。累计是整个会话的总数。'
                : 'Sessions with usage ($inSentence), sorted by usage in that period. Totals cover the full session.',
          ),
          findsOneWidget,
        );
      }
    });

    testWidgets('R2A 06 exact token count ignores display units $locale', (
      tester,
    ) async {
      final stats = await _mount(tester, locale);
      for (final unit in ['chinese', 'english']) {
        await stats.setPreferences(
          stats.preferences.copyWith(unitSystem: unit),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(_key('home-conversion')).data,
          zh ? '= 3,846,674 token' : '= 3,846,674 tokens',
        );
      }
    });

    testWidgets(
      'R2A 07 price explanation and settings link are in the hero $locale',
      (tester) async {
        await _mount(tester, locale);
        final hero = _key('home-hero');
        final note = zh
            ? '按公开标准价估算，不是账单'
            : 'Estimated at list prices, not a bill';
        final link = _in(hero, find.text(zh ? '价格怎么算' : 'How prices work'));
        expect(find.text(note), findsOneWidget);
        expect(_in(hero, find.text(' · ')), findsOneWidget);
        expect(link, findsOneWidget);
        expect(
          tester.getRect(link).left,
          greaterThan(tester.getRect(_in(hero, find.text(note))).right),
        );
        expect(
          _baseline(tester, link),
          closeTo(_baseline(tester, _in(hero, find.text(note))), .1),
        );
        expect(
          find.text(
            zh ? '金额按各模型的公开标准价估算，用来比较和感知，不是你的账单。套餐用户的实际花费通常更低。' : "Costs are estimated at each model's list price for comparison, not your bill. Subscription users usually pay less.",
          ),
          findsNothing,
        );
        await tester.tap(link);
        await tester.pumpAndSettle();
        expect(find.byType(StatsSettingsPage), findsOneWidget);
        expect(
          find.text(strings.costsAreEstimatesAtEachModelS3),
          findsOneWidget,
        );
      },
    );

    testWidgets('R2A 07 detail footer is removed $locale', (tester) async {
      await _mount(tester, locale);
      await navigate(tester, 'detail');
      expect(find.text(zh ? '价格怎么算' : 'How prices work'), findsNothing);
      expect(
        find.text(
          zh ? '金额按各模型的公开标准价估算，用来比较和感知，不是你的账单。 ' : "Costs are estimated at each model's list price for comparison, not your bill. ",
        ),
        findsNothing,
      );
    });

    for (final (minutes, cn, en) in [
      (1439, '23 小时 59 分', '23 hr 59 min'),
      (1440, '1 天', '1 d'),
      (1441, '1 天', '1 d'),
      (7195, '4 天 23 小时', '4 d 23 hr'),
      (7200, '5 天', '5 d'),
    ]) {
      test('R2A 08 duration at $minutes minutes $locale', () {
        final start = DateTime.utc(2026, 11, 14);
        expect(
          spanText(
            start.toIso8601String(),
            start.add(Duration(minutes: minutes)).toIso8601String(),
            strings,
          ),
          zh ? cn : en,
        );
      });
    }

    testWidgets(
      'R2A 08 unlabelled project keeps list name and uses tool session title $locale',
      (tester) async {
        await _mount(tester, locale);
        await navigate(tester, 'sessions');
        final row = _key('session-row-kimi:s1');
        expect(
          _in(row, find.text(zh ? '没有记录项目' : 'No project logged')),
          findsOneWidget,
        );
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.text(zh ? 'Kimi 会话' : 'Kimi session'), findsOneWidget);
        expect(
          find.textContaining(zh ? '4 天 23 小时' : '4 d 23 hr'),
          findsWidgets,
        );
      },
    );

    testWidgets(
      'R2A 09 per-request title matches the by-day card title $locale',
      (tester) async {
        await _mount(tester, locale);
        await navigate(tester, 'sessions', {'source': 'kimi', 'session': 's1'});
        final perRequest = tester
            .widget<Text>(find.text(zh ? '每次请求' : 'Per request'))
            .style!;
        final byDay = tester
            .widget<Text>(find.text(zh ? '按天' : 'By day'))
            .style!;
        expect(perRequest.color, byDay.color);
        expect(perRequest.fontSize, byDay.fontSize);
        expect(perRequest.fontWeight, byDay.fontWeight);
      },
    );

    for (final width in [1180.0, 1920.0]) {
      for (final dark in [false, true]) {
        testWidgets(
          'R2A 10 daily average sparkline geometry $locale $width dark=$dark',
          (tester) async {
            await _mount(tester, locale, width: width, dark: dark);
            final title = find.text(zh ? '日均用量' : 'Daily average');
            final card = find
                .ancestor(of: title, matching: find.byType(LensCard))
                .first;
            final spark = _in(
              card,
              find.byWidgetPredicate(
                (w) =>
                    w is CustomPaint &&
                    w.painter.runtimeType.toString() == '_SparkPainter',
              ),
            );
            final number = _in(card, find.byType(TokenText));
            final sparkRect = tester.getRect(spark);
            final titleRect = tester.getRect(title);
            final numberRect = tester.getRect(number);
            expect(sparkRect.top, greaterThanOrEqualTo(titleRect.bottom));
            expect(sparkRect.overlaps(titleRect), isFalse);
            expect(sparkRect.overlaps(numberRect), isFalse);
            expect(sparkRect.bottom, closeTo(numberRect.bottom, .1));
            expect(sparkRect.left - numberRect.right, greaterThanOrEqualTo(12));
            final size = tester.getRect(card);
            final contentWidth =
                size.right - titleRect.left - (titleRect.left - size.left);
            expect(sparkRect.width, lessThanOrEqualTo(contentWidth * .4 + .1));
            final hint = _in(card, find.text(strings.onDaysWithUsage));
            expect(
              sparkRect.bottom,
              lessThanOrEqualTo(tester.getTopLeft(hint).dy),
            );
            final delta = _in(card, find.byType(LensBadge));
            expect(delta, findsOneWidget);
            expect(sparkRect.overlaps(tester.getRect(delta)), isFalse);
          },
        );
      }
    }

    testWidgets(
      'R2A 11 all omits empty groups and the empty filter still works $locale',
      (tester) async {
        await _mount(tester, locale);
        await navigate(tester, 'sources');
        expect(_key('source-group-found'), findsOneWidget);
        expect(_key('source-group-missing'), findsOneWidget);
        expect(_key('source-group-issues'), findsNothing);
        final issues = _key('source-filter-issues');
        expect(_in(issues, find.text(zh ? '有问题' : 'Issues')), findsOneWidget);
        await tester.tap(issues);
        await tester.pumpAndSettle();
        expect(tester.widget<LensChip>(issues).selected, isTrue);
        expect(_key('source-group-found'), findsNothing);
        expect(_key('source-group-issues'), findsNothing);
      },
    );

    for (final largeText in [false, true]) {
      testWidgets(
        'R2A 12 onboarding values and units have shared baselines $locale largeText=$largeText',
        (tester) async {
          await _finishOnboarding(
            tester,
            locale,
            width: largeText ? 720 : 1180,
            textScale: largeText ? 2 : 1,
            tokenMode: largeText ? 'full' : 'compact',
          );
          for (final labels in [
            [largeText ? '68,390,000' : (zh ? '6839万' : '68.4M'), '806', '160'],
            [
              zh ? 'token' : 'tokens',
              zh ? '条记录' : 'records',
              zh ? '个会话' : 'sessions',
            ],
          ]) {
            final first = _baseline(tester, find.text(labels.first));
            for (final label in labels.skip(1)) {
              expect(
                _baseline(tester, find.text(label)),
                closeTo(first, .1),
                reason: label,
              );
            }
          }
        },
      );
    }

    testWidgets(
      'R2A 13 news controls center on the title above the description $locale',
      (tester) async {
        await _mount(tester, locale);
        await navigate(tester, 'news');
        final news = find.byType(NewsPage);
        final title = _in(news, find.text(zh ? 'AI 热点' : 'AI news'));
        final manage = _in(news, _key('manage-sources'));
        final refresh = _in(news, _key('refresh-news'));
        expect(
          _in(manage, find.text(zh ? '管理来源' : 'Manage sources')),
          findsOneWidget,
        );
        for (final control in [manage, refresh]) {
          expect(
            tester.getCenter(control).dy,
            closeTo(tester.getCenter(title).dy, .1),
          );
        }
        final subtitle = _in(
          news,
          find.textContaining(
            zh ? '每 30 分钟自动刷新' : 'Auto-refreshes every 30 min',
          ),
        );
        expect(
          tester.getRect(subtitle).top,
          greaterThanOrEqualTo(tester.getRect(title).bottom),
        );
        expect(
          tester.getRect(subtitle).left,
          greaterThanOrEqualTo(tester.getRect(title).left),
        );
      },
    );
  }
}
