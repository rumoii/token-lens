import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/stats/detail_page.dart';
import 'package:token_lens_app/stats/logic/format.dart';
import 'package:token_lens_app/stats/logic/heatmap.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/sessions_page.dart';
import 'package:token_lens_app/stats/settings_page.dart';
import 'package:token_lens_app/stats/sources_page.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/date_range.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import '../support/fake_news_gateway.dart';
import 'demo_visual_support.dart';
import 'fake_gateway.dart';
import 'language_test.dart' show navigate;
import 'onboarding_flow_test.dart' show OnboardingGateway;

const _project = 'synthetic-warehouse-migration-with-a-very-long-name';
const _id = 'abcdef0123456789';
const _path =
    r'C:\synthetic\an-extraordinarily-long-directory-for-testing-truncation\another-long-directory-for-the-fixture\logs\projects';
const _fallback = r'C:\synthetic\logs\alternate';
final _clock = DateTime(2026, 11, 19, 11);

class _Gateway extends FakeStatsGateway
    implements StatsSessionQueryGateway, StatsUsageExporter {
  _Gateway({this.additionalSessionId});

  final String? additionalSessionId;
  String discoveryResult = 'found';
  int scans = 0;

  @override
  Future<StatsDiscovery> discovery({bool fresh = false}) async {
    scans++;
    if (discoveryResult == 'failed') {
      throw StateError('synthetic discovery failure');
    }
    return discoveryResult == 'empty'
        ? const StatsDiscovery(sources: [], supported: 27)
        : StatsDiscovery(
            sources: [
              for (final id in toolIds.take(8))
                StatsDiscoveredSource(source: id, files: 3),
            ],
            supported: 27,
            tools: const [
              StatsDiscoveredTool(
                source: 'claude',
                status: 'found',
                directories: [
                  StatsLogDirectory(
                    path: _path,
                    status: 'found',
                    files: 3,
                    exists: true,
                  ),
                  StatsLogDirectory(
                    path: _fallback,
                    status: 'found',
                    files: 3,
                    exists: true,
                  ),
                ],
              ),
            ],
          );
  }

  StatsSessionItem _session(String id, String? project, int tokens) =>
      StatsSessionItem(
        source: 'claude',
        sessionId: id,
        projectKey: project,
        startedAt: '2026-10-30T17:00:00Z',
        lastSeenAt: '2026-11-19T11:00:00Z',
        grossTokens: tokens,
        unpricedRecords: 0,
        hasCumulative: false,
        recordCount: 7,
        requestCount: 7,
        cumulative: StatsTotals(
          grossTokens: tokens,
          recordCount: 7,
          unpricedRecords: 0,
        ),
      );

  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) async => StatsSessions(
    items: empty ? [] : [_session(_id, 'warehouse', 42000)],
    snapshot: demoSnapshot,
  );

  @override
  Future<StatsSessions> querySessions(
    StatsFilter filter,
    StatsSessionQuery query,
  ) async => StatsSessions(
    items: empty
        ? []
        : [
            _session(_id, _project, 42000),
            _session('short', null, 420),
            if (additionalSessionId case final id?)
              _session(id, 'another-synthetic-project', 21000),
          ],
    snapshot: demoSnapshot,
  );

  @override
  Future<String> exportUsage({
    required String by,
    required String period,
    required StatsFilter filter,
    required String format,
    required bool projectPaths,
    required String directory,
  }) async => throw StateError('This fixture does not export files');
}

class _HeatmapGateway extends _Gateway {
  @override
  Future<StatsTimeseries> timeseries(
    String granularity,
    StatsFilter filter,
  ) async {
    if (granularity != 'day' ||
        filter.from != dayKey(DateTime(2026, 11, 19 - 364))) {
      return super.timeseries(granularity, filter);
    }
    return StatsTimeseries(
      granularity: granularity,
      points: [
        for (var i = 1; i <= 7; i++)
          StatsBucket(
            bucket: dayKey(DateTime(2026, 11, 10 + i)),
            grossTokens: i < 7 ? i * 500000 : 4000000,
            unpricedRecords: 0,
            recordCount: 1,
          ),
      ],
      snapshot: demoSnapshot,
    );
  }
}

class _OnboardingGateway extends OnboardingGateway {
  _OnboardingGateway(this.result);
  final String result;
  int completionBreakdowns = 0;

  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) async {
    if (by != 'source' || filter != const StatsFilter()) {
      return super.breakdown(by, filter);
    }
    completionBreakdowns++;
    if (result == 'failed') throw StateError('synthetic breakdown failure');
    return StatsBreakdown(
      by: by,
      groups: result == 'empty' ? [] : groups(filter, by: by).take(7).toList(),
      totals: totals(filter),
      snapshot: demoSnapshot,
    );
  }
}

Future<void> _mount(
  WidgetTester tester,
  String locale,
  double width,
  FakeStatsGateway gateway, {
  bool onboarded = true,
  double height = 1200,
  Future<bool> Function(Uri)? openLink,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await loadSystemFonts(tester);
  final stats = StatsController(
    gateway,
    clock: () => _clock,
    preferences: UiPreferences(
      language: locale,
      onboarded: onboarded,
      autoCheckUpdates: false,
      newsEnabled: onboarded,
    ),
  );
  final news = NewsController(
    FakeNewsGateway(cached: cachedNews),
    now: () => _clock,
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
      builder: (context, child) => AppLanguageScope(
        strings: stats.strings,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
      ),
      home: StatsPage(
        controller: stats,
        openLink: openLink,
        newsListenable: news,
        news: NewsPage(
          controller: news,
          openLink: (_) async => true,
          now: () => _clock,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _in(Finder parent, Finder matching) =>
    find.descendant(of: parent, matching: matching);

Finder _card(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(LensCard)).first;

List<int> _levels(List<int> values) =>
    values.map(heatScale(values).level).toList();

void main() {
  test('R2B 03 no active days', () => expect(_levels([0, 0]), [0, 0]));
  test(
    'R2B 03 one active day takes the top level',
    () => expect(_levels([0, 800]), [0, 4]),
  );
  test(
    'R2B 03 seven active days use percentages',
    () => expect(_levels([249, 250, 251, 500, 501, 750, 1000]), [
      1,
      1,
      2,
      2,
      3,
      3,
      4,
    ]),
  );
  test(
    'R2B 03 eight active days use quartiles',
    () => expect(_levels([10, 20, 30, 40, 50, 60, 70, 1000]), [
      1,
      1,
      2,
      2,
      3,
      3,
      4,
      4,
    ]),
  );
  test(
    'R2B 03 one outlier does not collapse the rest',
    () => expect(
      _levels([for (var i = 1; i <= 40; i++) i * 10000, 1000000000])
          .take(40)
          .toSet(),
      {1, 2, 3, 4},
    ),
  );
  test(
    'R2B 03 equal active days share one level',
    () => expect(_levels(List.filled(8, 500)).toSet(), {1}),
  );
  test('R2B 05 dark tool tile and heat colors', () {
    const dark = LensPalette(true);
    expect(
      [dark['tile'], for (var i = 1; i <= 4; i++) dark['heat-$i']],
      const [
        Color(0xffceccc6),
        Color(0xff5c3629),
        Color(0xff914d36),
        Color(0xffc96848),
        Color(0xfff09778),
      ],
    );
  });

  testWidgets('R2B 02 short IDs distinguish sessions with the same prefix', (
    tester,
  ) async {
    const other = 'abcdef01fedcba98';
    await _mount(tester, 'en', 1180, _Gateway(additionalSessionId: other));
    await navigate(tester, 'sessions', {'period': 'month'});

    String? shortIdFor(String id) {
      final row = find.byKey(Key('session-row-claude:$id'));
      final copy = _in(row, find.byTooltip('Copy session ID'));
      return tester.widget<Text>(_in(copy, find.byType(Text))).data;
    }

    expect([shortIdFor(_id), shortIdFor(other)], ['23456789', 'fedcba98']);
  });

  for (final locale in ['zh', 'en']) {
    final s = resolveStrings(locale, 'en');
    final zh = s.isChinese;
    final spans = zh ? '跨时段' : 'Spans period';
    testWidgets(
      'R2B 01 sessions and overview align their period control $locale',
      (tester) async {
        await _mount(tester, locale, 1180, _Gateway());
        if (!zh && !requireWindowsLayoutFonts(serif: true, diagnose: true)) {
          return;
        }
        final period = find.byType(PeriodControl);
        final right = tester.getTopRight(period).dx;
        await navigate(tester, 'sessions', {'period': 'month'});
        final title = _in(find.byType(LensPageHeader), find.text(s.sessions));
        expect(period, findsOneWidget);
        expect(title, findsOneWidget);
        expect(
          tester.getCenter(period).dy,
          closeTo(tester.getCenter(title).dy, 1),
        );
        expect(tester.getTopRight(period).dx, closeTo(right, 1));
        expect(tester.takeException(), isNull);
      },
    );

    for (final width in [1180.0, 1024.0]) {
      testWidgets('R2B 02 session badge stays beside name $locale $width', (
        tester,
      ) async {
        await _mount(tester, locale, width, _Gateway());
        await navigate(tester, 'sessions', {'period': 'month'});
        final row = find.byKey(const Key('session-row-claude:$_id'));
        final badge = _in(row, find.widgetWithText(LensBadge, spans));
        final name = _in(row, find.text(_project));
        expect(badge, findsOneWidget);
        expect(
          tester.getCenter(name).dy,
          closeTo(tester.getCenter(badge).dy, 1),
        );
        expect(
          tester.getTopRight(name).dx,
          lessThanOrEqualTo(tester.getTopLeft(badge).dx),
        );
        final date = tester.widget<Tooltip>(
          _in(
            row,
            find.byWidgetPredicate(
              (widget) =>
                  widget is Tooltip &&
                  widget.message == s.startedOn(s.calendarDay(10, 30)),
            ),
          ),
        );
        expect(date.child, isA<LensBadge>());
        expect(
          tester.renderObject<RenderParagraph>(name).didExceedMaxLines,
          isTrue,
        );
        expect(
          tester
              .renderObject<RenderParagraph>(_in(badge, find.text(spans)))
              .didExceedMaxLines,
          isFalse,
        );
        expect(find.text(s.noProjectLogged), findsOneWidget);
        expect(find.text('short', findRichText: true), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      'R2B 02 short ID copies the full ID and does not open a session $locale',
      (tester) async {
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await _mount(tester, locale, 1180, _Gateway());
        final date = s.startedOn(s.calendarDay(10, 30));
        expect(find.widgetWithText(LensBadge, date), findsOneWidget);
        await navigate(tester, 'sessions', {'period': 'month'});
        final copy = find.byTooltip(zh ? '复制会话 ID' : 'Copy session ID').first;
        expect(
          _in(copy, find.text('23456789', findRichText: true)),
          findsOneWidget,
        );
        await tester.tap(copy);
        await tester.pump();
        expect(copied, _id);
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.byType(SessionDetail), findsNothing);
      },
    );

    testWidgets('R2B 03 overview legend exposes actual tier ranges $locale', (
      tester,
    ) async {
      await _mount(tester, locale, 1180, _HeatmapGateway());
      final card = _card(s.pastYear);
      String format(int count) =>
          tokenCount(count, unitSystem: zh ? 'chinese' : 'english');
      for (final tip in [
        '0 ${s.tokenUnit}',
        s.heatTokenRange(format(1), format(1000000)),
        s.heatTokenRange(format(1000001), format(2000000)),
        s.heatTokenRange(format(2000001), format(3000000)),
        s.heatTokensAndAbove(format(3000001)),
      ]) {
        expect(_in(card, find.byTooltip(tip)), findsOneWidget);
      }
    });

    testWidgets('R2B 04 detail second row aligns controls at 1180 $locale', (
      tester,
    ) async {
      await _mount(tester, locale, 1180, _Gateway());
      if (!zh && !requireWindowsLayoutFonts()) return;
      await navigate(tester, 'detail', {'period': 'month'});
      final grouping = find.byWidgetPredicate(
        (w) => w is LensSegmented && w.label == s.groupBy,
      );
      final compare = find.byKey(const Key('detail-compare'));
      final sort = find.byKey(const Key('detail-sort'));
      final direction = _in(
        _card(s.breakdown2),
        find.byType(LensSortDirection),
      );
      final center = tester.getCenter(grouping).dy;
      final centers = [
        for (final control in [compare, sort, direction])
          tester.getCenter(control).dy,
      ];
      debugPrint('R2B detail $locale centers: $center, $centers');
      expect(centers, everyElement(closeTo(center, 1)));
      expect(
        tester.getTopRight(grouping).dx,
        lessThanOrEqualTo(tester.getTopLeft(compare).dx),
      );
      expect(tester.getSize(compare).width, 44);
      final export = find.widgetWithText(LensButton, s.export);
      expect(tester.widget<LensButton>(export).variant, 'secondary');
      expect(tester.widget<LensButton>(export).size, 'sm');
      expect(_in(export, find.byIcon(Icons.download_outlined)), findsOneWidget);
      expect(
        tester.getBottomRight(export).dy,
        lessThan(tester.getTopLeft(grouping).dy),
      );
      expect(
        tester.getTopRight(export).dx,
        closeTo(tester.getTopRight(direction).dx, 1),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'R2B 06 source paths gain width and keep whole directory segments $locale',
      (tester) async {
        Uri? opened;
        await _mount(
          tester,
          locale,
          1180,
          _Gateway(),
          openLink: (uri) async {
            opened = uri;
            return true;
          },
        );
        await navigate(tester, 'sources');
        final row = find.byKey(const ValueKey('tool-claude'));
        final path = _in(row, find.byTooltip(_path));
        final width = tester.getSize(path).width;
        final shown = tester
            .widget<RichText>(_in(path, find.byType(RichText)))
            .text
            .toPlainText();
        debugPrint('R2B source path $locale: $width px, $shown');
        expect(width, greaterThan(219.88764044943818 * 1.5));
        expect(shown, startsWith(r'C:\'));
        expect(shown, contains('…'));
        expect(shown, endsWith(r'\logs\projects'));
        final open = _in(row, find.byTooltip(s.inventoryOpen));
        await tester.tap(open);
        await tester.pump();
        expect(opened, Uri.directory(_path));
        await tester.tap(_in(row, find.text('Claude Code')).first);
        await tester.pumpAndSettle();
        expect(_in(row, find.byTooltip(_fallback)), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('R2B 07 full page widths and overview layout $locale', (
      tester,
    ) async {
      await _mount(tester, locale, 1180, _Gateway());
      final heat = _card(s.pastYear);
      final recentTitle = s.sessions0(s.thisWeek2);
      final recent = _card(recentTitle);
      final layout1180 = [tester.getRect(heat), tester.getRect(recent)];
      debugPrint('R2B overview $locale 1180 heat/recent: $layout1180');
      expect(layout1180.map((r) => r.width), everyElement(closeTo(864, 1)));
      expect(layout1180.last.top, greaterThan(layout1180.first.bottom));
      for (final width in [1440.0, 1920.0]) {
        tester.view.physicalSize = Size(width, 1200);
        await navigate(tester, 'home');
        final homeWidth = tester.getSize(find.byType(LensPageHeader)).width;
        final name = _in(recent, find.text('warehouse'));
        final usage = _in(
          recent,
          find.textContaining(RegExp(r'^' + RegExp.escape(s.thisWeek2) + r' ')),
        ).first;
        final left = tester.getSize(heat).width;
        final right = tester.getSize(recent).width;
        final y = [tester.getCenter(name).dy, tester.getCenter(usage).dy];
        debugPrint(
          'R2B overview $locale $width: $homeWidth px, cards $left/$right px, name and usage $y',
        );
        final widths = <String, double>{};
        for (final (page, type) in [
          ('detail', StatsDetail),
          ('sessions', StatsSessionsPage),
          ('sources', StatsSourcesPage),
          ('settings', StatsSettingsPage),
          ('news', NewsPage),
        ]) {
          await navigate(tester, page);
          widths[page] = tester.getSize(find.byType(type)).width;
          if (page == 'news') {
            widths['news article list'] = tester
                .renderObject<RenderSliver>(find.byKey(const Key('news-list')))
                .constraints
                .crossAxisExtent;
          }
          expect(tester.takeException(), isNull);
        }
        debugPrint('R2B page widths $locale $width: $widths');
        if (width == 1920) {
          expect(homeWidth, 1440 - 72);
          expect(left / right, closeTo(13 / 7, .01));
          expect(y.last, closeTo(y.first, 2));
          for (final page in ['detail', 'sessions', 'sources', 'settings']) {
            expect(widths[page], 1440 - 72);
          }
        }
      }
    });

    for (final result in ['found', 'empty', 'failed']) {
      testWidgets(
        'R2B 08 full empty ledger shares discovery state $locale $result',
        (tester) async {
          final gateway = _Gateway()
            ..empty = true
            ..discoveryResult = result;
          await _mount(tester, locale, 1180, gateway);
          for (final page in ['home', 'detail', 'sessions']) {
            await navigate(tester, page);
            expect(find.byType(PeriodControl), findsNothing, reason: page);
            expect(find.text(s.noUsageYet), findsOneWidget, reason: page);
            expect(
              find.text(s.readsLogsOnThisComputerAndLeaves),
              findsOneWidget,
            );
            final title = find.text(
              zh
                  ? '这台电脑上找到 8 个工具的日志'
                  : 'Found logs for 8 tools on this computer',
            );
            final empty = find.text(
              zh
                  ? '这台电脑上还没找到支持的 AI 编程工具'
                  : 'No supported AI coding tools found on this computer yet',
            );
            expect(title, result == 'found' ? findsOneWidget : findsNothing);
            expect(empty, result == 'empty' ? findsOneWidget : findsNothing);
            if (result == 'found') {
              expect(find.text(zh ? '3 个文件' : '3 files'), findsNWidgets(6));
              expect(find.text(zh ? '还有 2 个' : '2 more'), findsOneWidget);
            }
            expect(
              tester
                  .widget<LensButton>(
                    find.widgetWithText(LensButton, s.syncNow),
                  )
                  .variant,
              'primary',
            );
          }
          expect(gateway.scans, 1);
        },
      );
    }

    for (final result in ['found', 'empty', 'failed']) {
      testWidgets('R2B 09 completion breakdown $locale $result', (
        tester,
      ) async {
        final gateway = _OnboardingGateway(result);
        await _mount(tester, locale, 1180, gateway, onboarded: false);
        await tester.tap(find.text(s.startCounting));
        await tester.pumpAndSettle();
        final title = find.text(s.usageIsReady);
        expect(title, findsOneWidget);
        expect(gateway.completionBreakdowns, 1);
        final byTool = find.text(zh ? '按工具拆开' : 'By tool');
        expect(byTool, result == 'found' ? findsOneWidget : findsNothing);
        if (result == 'found') {
          expect(find.text(zh ? '7 个工具' : '7 tools'), findsOneWidget);
          expect(find.text(zh ? '其他 3 个工具' : '3 other tools'), findsOneWidget);
        }
        expect(
          find.textContaining(zh ? 'token · 约值 ' : 'tokens · est. '),
          findsOneWidget,
        );
        final done = find
            .ancestor(of: title, matching: find.byType(SingleChildScrollView))
            .first;
        final check = _in(done, find.byIcon(Icons.check));
        final enter = _in(done, find.byType(LensButton)).last;
        expect(
          (tester.getTopLeft(check).dy + tester.getBottomRight(enter).dy) / 2,
          closeTo(600, 24),
        );
        tester.view.physicalSize = const Size(720, 280);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(check).dy, lessThan(80));
        await tester.ensureVisible(enter);
        await tester.pumpAndSettle();
        expect(enter.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'R2B 08 populated ledger never discovers for the statistics pages',
    (tester) async {
      final gateway = _Gateway();
      await _mount(tester, 'en', 1180, gateway);
      for (final page in ['home', 'detail', 'sessions']) {
        await navigate(tester, page);
        expect(find.byType(PeriodControl), findsOneWidget);
      }
      expect(gateway.scans, 0);
    },
  );
}
