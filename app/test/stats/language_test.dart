import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/l10n/sync_messages.dart';
import 'package:token_lens_app/stats/logic/display.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/update/update_check.dart';

import '../support/fake_news_gateway.dart';
import '../update/update_shell_test.dart' show VersionGateway;
import 'fake_gateway.dart';
import 'onboarding_flow_test.dart' show OnboardingGateway;
import 'request_log_test.dart' show RequestSessionGateway;

class LanguageGateway extends RequestSessionGateway {
  @override
  Future<StatsHealth> health() => VersionGateway().health();

  @override
  Future<StatsSources> sources() async {
    final base = await super.sources();
    return StatsSources(
      sources: [
        const StatsSource(
          source: 'claude',
          evidence: 'A',
          status: 'ready',
          lastObservedAt: '2026-11-08T18:30:00Z',
          records: 8,
          recordMode: 'event',
          retention: StatsRetention(reviewable: 8, logsGone: 0),
          checks: StatsSourceChecks(
            timeOutOfRange: 1,
            hugeRequests: 0,
            nullModel: 0,
            mixedKindSessions: 0,
          ),
          limits: ['合成技术细节'],
          limitsEn: ['Synthetic technical note'],
          notes: [
            StatsSourceNote(
              text: '合成来源说明',
              textEn: 'Synthetic source note',
              impact: 'handled',
            ),
          ],
        ),
      ],
      lastRun: base.lastRun,
      snapshot: base.snapshot,
    );
  }

  @override
  Future<StatsDiscovery> discovery({bool fresh = false}) =>
      OnboardingGateway().discovery(fresh: fresh);
}

Future<StatsController> mount(
  WidgetTester tester,
  double width,
  String language, {
  bool onboarded = true,
  double height = 1000,
  Widget Function(Widget)? wrap,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final previousErrorHandler = FlutterError.onError!;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('overflowed')) {
      debugPrint(details.toString());
    }
    previousErrorHandler(details);
  };
  addTearDown(() => FlutterError.onError = previousErrorHandler);
  final stats = StatsController(
    LanguageGateway()..empty = !onboarded,
    preferences: UiPreferences.decode(
      jsonEncode({
        'language': language,
        'onboarded': onboarded,
        'autoCheckUpdates': false,
      }),
    ),
    clock: () => demoNow,
    updateRequest: (_, _, _) async => const UpdateResponse(
      200,
      '{"tag_name":"v0.2.0","draft":false,"prerelease":false,"published_at":"2026-11-06T12:00:00Z"}',
    ),
  );
  final news = NewsController(
    FakeNewsGateway(cached: cachedNews),
    now: () => demoNow,
  );
  addTearDown(stats.dispose);
  addTearDown(news.dispose);
  if (onboarded) {
    await stats.load();
    await stats.health();
  } else {
    await stats.onboardingRequired();
  }
  await news.load();
  final app = MaterialApp(
    theme: const LensPalette(false).theme,
    builder: (_, child) => ListenableBuilder(
      listenable: stats,
      builder: (_, _) =>
          AppLanguageScope(strings: stats.strings, child: child!),
    ),
    home: StatsPage(
      controller: stats,
      news: NewsPage(
        controller: news,
        openLink: (_) async => true,
        now: () => demoNow,
      ),
      newsListenable: news,
    ),
  );
  await tester.pumpWidget(wrap?.call(app) ?? app);
  await tester.pumpAndSettle();
  return stats;
}

Future<void> navigate(
  WidgetTester tester,
  String page, [
  Map<String, String> query = const {},
]) async {
  final dynamic state = tester.state(find.byType(StatsPage));
  state.navigate(page, query);
  await tester.pumpAndSettle();
}

void expectEnglish(WidgetTester tester) {
  expect(tester.takeException(), isNull);
  final han = RegExp(r'\p{Script=Han}', unicode: true);
  // The 万 / 亿 option names the Chinese units it switches to.
  final text = find
      .byType(RichText)
      .evaluate()
      .map((element) => (element.widget as RichText).text.toPlainText())
      .where((text) => text != englishStrings.chineseNumberUnits);
  expect(text.where(han.hasMatch), isEmpty);
}

Future<void> tapText(WidgetTester tester, String text) async {
  final target = find.text(text).first;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  test('manual price copy tag is available in both languages', () {
    expect(chineseStrings.copyBaseOnlyTag, '只复制基础价');
    expect(englishStrings.copyBaseOnlyTag, 'Base price only');
  });

  test(
    'system mode resolves all Chinese locales and falls back to English',
    () {
      for (final locale in ['zh', 'zh-CN', 'zh-Hant', 'ZH-TW']) {
        expect(resolveStrings('system', locale), chineseStrings);
        expect(resolveStrings('en', locale), englishStrings);
      }
      for (final locale in ['en', 'fr', 'ja', '']) {
        expect(resolveStrings('system', locale), englishStrings);
        expect(resolveStrings('zh', locale), chineseStrings);
      }
    },
  );

  test(
    'unit defaults are implicit, explicit settings survive locale changes',
    () {
      final implicit = UiPreferences.decode('{"language":"en"}');
      expect(implicit.unitSystem, 'english');
      expect(implicit.copyWith(language: 'zh').unitSystem, 'chinese');
      expect(implicit.unitSystemFor('zh'), 'chinese');
      expect(implicit.unitSystemFor('en'), 'english');
      for (final unit in ['chinese', 'english']) {
        final explicit = UiPreferences.decode('{"unitSystem":"$unit"}');
        final switched = explicit.copyWith(language: 'en');
        final restored = UiPreferences.decode(switched.encode());
        expect(restored.unitSystemFor('zh'), unit);
        expect(restored.unitSystemFor('en'), unit);
      }
    },
  );

  test('short dates, relative times and English plurals', () {
    final now = DateTime(2026, 11, 9);
    expect(usageDate('2026-11-06', now), '11月6日 周五');
    expect(usageDate('2026-11-06', now, strings: englishStrings), 'Nov 6, Fri');
    expect(usageBucket('2026-11', now, englishStrings), 'Nov 2026');
    expect(englishStrings.daysAgo(1), 'yesterday');
    expect(englishStrings.daysAgo(3), '3 days ago');
    expect(englishStrings.requestCount(1), '1 request');
    expect(englishStrings.requestCount(2), '2 requests');
    expect(
      englishStrings.rateUpdatedAt(11, 6, '09', '30'),
      'Updated Nov 6, 09:30',
    );
  });

  test('coded anomalies translate and uncoded details stay verbatim', () {
    const raw = 'cross_file_conflict: record-id — 重复记录';
    expect(localizedAnomaly(raw, chineseStrings), raw);
    expect(
      localizedAnomaly(raw, englishStrings),
      'Conflicting usage in two copies of the same record: record-id',
    );
    const freeText = '没有稳定码的异常';
    expect(localizedAnomaly(freeText, englishStrings), freeText);
  });

  for (final language in ['system', 'zh', 'en', 'fr', null, 1]) {
    test('stores language $language', () async {
      final directory = await Directory.systemTemp.createTemp('lens-language-');
      addTearDown(() => directory.delete(recursive: true));
      final store = PreferencesStore(directory);
      await File(
        '${directory.path}/ui-preferences.json',
      ).writeAsString(jsonEncode({'language': ?language, 'onboarded': true}));
      final preferences = await store.read();
      expect(preferences.onboarded, isTrue);
      expect(await store.write(preferences), isTrue);
      final persisted = jsonDecode((await store.read()).encode()) as Map;
      expect(
        persisted['language'],
        ['zh', 'en'].contains(language) ? language : 'system',
      );
      expect(persisted.containsKey('unitSystem'), isFalse);
    });
  }

  testWidgets('switches the interface and default units in place', (
    tester,
  ) async {
    final stats = await mount(tester, 1440, 'zh');
    await navigate(tester, 'settings');
    expect(find.text('界面语言'), findsOneWidget);
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Usage overview'), findsOneWidget);
    await navigate(tester, 'home');
    expectEnglish(tester);
    expect(find.textContaining('K'), findsWidgets);
    await stats.setPreferences(
      stats.preferences.copyWith(unitSystem: 'chinese'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('万'), findsWidgets);
  });

  for (final width in [1024.0, 1440.0]) {
    testWidgets('English desktop pages at $width', (tester) async {
      await mount(tester, width, 'en');
      expectEnglish(tester);
      for (final page in [
        'detail',
        'sessions',
        'sources',
        'settings',
        'news',
      ]) {
        await navigate(tester, page);
        expectEnglish(tester);
        switch (page) {
          case 'detail':
            await tapText(tester, 'By request');
            expectEnglish(tester);
          case 'sessions':
            await navigate(tester, 'sessions', {
              'source': 'codex',
              'session': 's1',
            });
            expect(find.bySemanticsLabel('Session details'), findsOneWidget);
            expectEnglish(tester);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            expect(find.bySemanticsLabel('Session details'), findsNothing);
          case 'sources':
            await tapText(tester, 'Last sync details');
            expectEnglish(tester);
            await tapText(tester, 'Technical details');
            expect(find.text('Synthetic technical note'), findsOneWidget);
            expect(
              find.byWidgetPredicate(
                (widget) =>
                    widget is Text &&
                    widget.data?.replaceAll('\u2060', '') ==
                        'Synthetic source note',
              ),
              findsOneWidget,
            );
            expectEnglish(tester);
          case 'settings':
            await tapText(tester, 'Check for updates');
            expect(find.text('0.2.0 is available'), findsOneWidget);
            expect(find.text('New version 0.2.0'), findsOneWidget);
            expectEnglish(tester);
        }
      }
    });

    testWidgets('English first run at $width', (tester) async {
      await mount(tester, width, 'en', onboarded: false);
      expect(find.text('Welcome to Token Lens'), findsOneWidget);
      expectEnglish(tester);
    });
  }
}
