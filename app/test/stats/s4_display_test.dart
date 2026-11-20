import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/stats/detail_page.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/interface_scale.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats/widgets/charts.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

import '../support/fake_news_gateway.dart';
import 'fake_gateway.dart';
import 'language_test.dart' as language;
import 's3_sources_sync_test.dart' show S3Gateway;

Widget s4App(StatsController controller, {Widget? news, Key? captureKey}) =>
    RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: const LensPalette(false).theme,
        builder: (context, child) => ListenableBuilder(
          listenable: controller,
          builder: (context, _) => LensInterfaceScale(
            scale: controller.preferences.uiScale,
            child: AppLanguageScope(strings: controller.strings, child: child!),
          ),
        ),
        home: StatsPage(controller: controller, news: news),
      ),
    );

Finder rowKey(String prefix) => find
    .byWidgetPredicate(
      (widget) => switch (widget.key) {
        ValueKey<String>(value: final value) => value.startsWith(prefix),
        _ => false,
      },
    )
    .first;

void main() {
  for (final (choice, period) in [
    ('last', 'all'),
    ('today', 'today'),
    ('week', 'week'),
    ('month', 'month'),
  ]) {
    testWidgets('S4 startup period $choice reaches overview and detail', (
      tester,
    ) async {
      final c = StatsController(
        FakeStatsGateway(),
        clock: () => demoNow,
        preferences: UiPreferences(
          period: const StatsPeriod('all'),
          defaultPeriod: choice,
          onboarded: true,
        ),
      );
      addTearDown(c.dispose);
      await c.load();
      await tester.pumpWidget(s4App(c));
      await tester.pumpAndSettle();
      expect(c.overview!.period.period, period);
      await language.navigate(tester, 'detail');
      final detail = tester.widget<StatsDetail>(find.byType(StatsDetail));
      expect(StatsPeriod.parse(detail.query).period, period);
    });
  }

  testWidgets('S4 compact tightens the source inventory', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = StatsController(
      S3Gateway(),
      clock: () => demoNow,
      preferences: const UiPreferences(onboarded: true),
    );
    addTearDown(c.dispose);
    await c.load();
    await tester.pumpWidget(s4App(c));
    await tester.pumpAndSettle();
    await language.navigate(tester, 'sources');
    final row = find.byKey(const ValueKey('tool-claude'));
    final before = tester.getSize(row).height;
    await c.setPreferences(c.preferences.copyWith(density: 'compact'));
    await tester.pumpAndSettle();
    expect(tester.getSize(row).height, closeTo(before - 2.5, .1));
  });
  for (final lang in ['en', 'zh']) {
    for (final width in [1024.0, 1440.0]) {
      testWidgets('S4 125% desktop pages at $width in $lang', (tester) async {
        tester.view.devicePixelRatio = 1.5;
        tester.view.physicalSize = Size(width * 1.5, 900 * 1.5);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final c = StatsController(
          language.LanguageGateway(),
          clock: () => demoNow,
          preferences: UiPreferences(
            language: lang,
            uiScale: 1.25,
            onboarded: true,
            autoCheckUpdates: false,
          ),
        );
        final news = NewsController(
          FakeNewsGateway(cached: cachedNews),
          now: () => demoNow,
        );
        addTearDown(c.dispose);
        addTearDown(news.dispose);
        await c.load();
        await news.load();
        await tester.pumpWidget(
          s4App(
            c,
            news: NewsPage(
              controller: news,
              now: () => demoNow,
              openLink: (_) async => true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(StatsPage));
        expect(MediaQuery.sizeOf(context).width, width / 1.25);
        expect(MediaQuery.devicePixelRatioOf(context), 1.5 * 1.25);
        expect(
          tester.getRect(find.byKey(const Key('nav-home'))).height,
          closeTo(45, 1e-6),
        );
        for (final page in [
          'home',
          'detail',
          'sessions',
          'sources',
          'settings',
          'news',
        ]) {
          await language.navigate(tester, page);
          if (lang == 'en') {
            language.expectEnglish(tester);
          } else {
            expect(tester.takeException(), isNull);
          }
        }
        await language.navigate(tester, 'settings');
        await language.tapText(tester, c.strings.resetInterfaceScale);
        expect(c.preferences.uiScale, 1);
        expect(
          MediaQuery.sizeOf(tester.element(find.byType(StatsPage))).width,
          width,
        );
        expect(find.text(c.strings.resetInterfaceScale), findsNothing);
      });
    }

    testWidgets(
      'S4 compact reduces padding and row height without font changes in $lang',
      (tester) async {
        final c = await language.mount(tester, 1440, lang, height: 1500);
        for (final (page, target) in [
          ('home', find.byKey(const Key('home-hero'))),
          ('detail', rowKey('detail-row-')),
          ('sessions', rowKey('session-row-')),
          ('sources', find.byKey(const ValueKey('tool-claude'))),
        ]) {
          await c.setPreferences(
            c.preferences.copyWith(density: 'comfortable'),
          );
          await language.navigate(tester, page);
          List<double?> fonts() => find
              .descendant(of: target, matching: find.byType(Text))
              .evaluate()
              .map((element) => (element.widget as Text).style?.fontSize)
              .toList();
          final comfortable = tester.getSize(target).height;
          final fontSizes = fonts();
          expect(fontSizes, isNotEmpty);
          await c.setPreferences(c.preferences.copyWith(density: 'compact'));
          await tester.pumpAndSettle();
          expect(
            tester.getSize(target).height,
            lessThan(comfortable),
            reason: page,
          );
          expect(fonts(), fontSizes, reason: page);
        }
      },
    );
  }

  for (final date in [DateTime(2026, 1, 8), DateTime(2026, 3, 4)]) {
    for (final firstDay in [DateTime.monday, DateTime.sunday]) {
      testWidgets('S4 heatmap aligns $date with week beginning $firstDay', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 640,
                child: Heatmap(
                  values: const {},
                  now: date,
                  narrow: false,
                  weekStartsOn: firstDay,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final painter = find
            .descendant(
              of: find.byType(Heatmap),
              matching: find.byType(CustomPaint),
            )
            .first;
        final cells = tester
            .widget<CustomPaint>(painter)
            .painter!
            .semanticsBuilder!(tester.getSize(painter));
        final firstRow = cells.where((cell) => cell.rect.top == 20);
        expect(firstRow, isNotEmpty);
        for (final cell in firstRow) {
          final day = DateTime.parse(cell.properties.label!.substring(0, 10));
          expect(day.weekday, firstDay);
        }
        expect(
          firstRow.any((cell) => cell.properties.label!.startsWith('2025-')),
          isTrue,
        );
        expect(
          firstRow.any((cell) => cell.properties.label!.startsWith('2026-')),
          isTrue,
        );
      });
    }
  }
  testWidgets('S4 settings contain the three preference cards', (tester) async {
    await language.mount(tester, 1440, 'zh');
    await language.navigate(tester, 'settings');
    for (final title in ['外观与界面', '数字与时间', '联网与更新']) {
      expect(find.text(title), findsOneWidget);
    }
  });

  testWidgets(
    'S4 disabled news hides the entry and refuses direct navigation',
    (tester) async {
      final controller = await language.mount(tester, 1440, 'en');
      await controller.setPreferences(
        UiPreferences.decode(
          '{"language":"en","onboarded":true,"newsEnabled":false,"autoCheckUpdates":false}',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nav-news')), findsNothing);
      await language.navigate(tester, 'news');
      expect(find.byKey(const Key('home-hero')), findsOneWidget);
      await language.navigate(tester, 'settings');
      final toggle = find.widgetWithText(LensSwitch, 'AI news');
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(controller.preferences.newsEnabled, isTrue);
      expect(find.byKey(const ValueKey('nav-news')), findsOneWidget);
    },
  );

  testWidgets('S4 first-run local-only checkbox defaults off', (tester) async {
    await language.mount(tester, 1440, 'en', onboarded: false);
    expect(find.text('Local statistics only, no AI news'), findsOneWidget);
    expect(
      tester.widget<LensCheckbox>(find.byType(LensCheckbox)).value,
      isFalse,
    );
  });

  testWidgets('S4 default overview places Monday in the first row', (
    tester,
  ) async {
    await language.mount(tester, 1440, 'en');
    final heat = find.byType(Heatmap);
    await tester.ensureVisible(heat);
    await tester.pumpAndSettle();
    final rect = tester.getRect(heat);
    // The fixture ends on Monday. Its cell is the first row of the last column.
    await tester.tapAt(Offset(rect.right - 6, rect.top + 25));
    await tester.pumpAndSettle();
    expect(find.text('Nov 9, Mon'), findsOneWidget);
  });
}
