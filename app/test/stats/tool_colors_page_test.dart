import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/charts.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';

import 'fake_gateway.dart';

Iterable<Color> swatches(WidgetTester tester, Finder root) sync* {
  for (final box in tester.widgetList<Container>(
    find.descendant(of: root, matching: find.byType(Container)),
  )) {
    if (box.color case final Color color) yield color;
    if (box.decoration case BoxDecoration(color: final Color color)) {
      yield color;
    }
    if (box.decoration case BoxDecoration(border: final Border border)) {
      yield border.top.color;
    }
  }
}

void main() {
  testWidgets('总览工具条、侧栏和趋势使用品牌色与用量墨色', (tester) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = StatsController(
      FakeStatsGateway(),
      clock: () => demoNow,
      preferences: const UiPreferences(
        onboarded: true,
        period: StatsPeriod('month'),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: const LensPalette(false).theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: StatsPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    const colors = {
      'claude': Color(0xffd97757),
      'opencode': Color(0xff3b3936),
      'cursor': Color(0xff66635d),
      'pi': Color(0xff8f8c85),
      'kimi': Color(0xffb3b0a8),
    };
    final strip = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == chineseStrings.usageByTool,
    );
    expect(strip, findsOneWidget);
    expect(swatches(tester, strip), containsAll(colors.values));
    for (final entry in colors.entries) {
      final row = find.byKey(ValueKey('sidebar-tool-${entry.key}'));
      expect(swatches(tester, row), contains(entry.value));
    }
    final chart = tester.widget<TrendChart>(find.byType(TrendChart));
    expect(chart.slots, containsPair('claude', const Color(0xffd97757)));
    for (final entry in colors.entries) {
      expect(chart.slots, containsPair(entry.key, entry.value));
    }

    final models = find
        .ancestor(
          of: find.text(chineseStrings.topModels),
          matching: find.byType(LensCard),
        )
        .first;
    final modelColors = swatches(tester, models);
    expect(modelColors, contains(const LensPalette(false).category(1)));
    expect(modelColors, isNot(contains(const Color(0xffd97757))));
  });
}
