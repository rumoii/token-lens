import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/date_range.dart';
import 'package:token_lens_app/stats/widgets/filters.dart';

Widget shell(AppStrings strings, Widget child) => MaterialApp(
  theme: const LensPalette(false).theme,
  builder: (_, child) => AppLanguageScope(strings: strings, child: child!),
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

void main() {
  for (final width in [1024.0, 1440.0]) {
    for (final strings in [chineseStrings, englishStrings]) {
      testWidgets('period menu at $width (${strings.isChinese})', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var current = const StatsPeriod();
        await tester.pumpWidget(
          shell(
            strings,
            StatefulBuilder(
              builder: (_, setState) {
                return PeriodControl(
                  period: current,
                  now: DateTime(2026, 11, 19),
                  onChanged: (value) => setState(() => current = value),
                );
              },
            ),
          ),
        );
        await tester.tap(find.text(strings.morePeriods));
        await tester.pumpAndSettle();
        for (final id in StatsPeriod.shortcuts) {
          expect(find.text(StatsPeriod(id).labelFor(strings)), findsOneWidget);
        }
        await tester.tap(find.text(strings.lastThirtyDays));
        await tester.pumpAndSettle();
        expect(current.period, 'last30');
        expect(find.text(strings.lastThirtyDays), findsOneWidget);
        expect(find.text(strings.morePeriods), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final strings in [chineseStrings, englishStrings]) {
    testWidgets('filter search on display names (${strings.isChinese})', (
      tester,
    ) async {
      String? selected;
      await tester.pumpWidget(
        shell(
          strings,
          FilterPick(
            label: strings.project,
            options: [
              for (var i = 0; i < 9; i++) FilterOption('$i', 'Sample $i'),
            ],
            onPick: (value) => selected = value,
          ),
        ),
      );
      await tester.tap(find.text(strings.project));
      await tester.pumpAndSettle();
      final search = find.byType(TextField);
      expect(search, findsOneWidget);
      await tester.enterText(search, 'nothing');
      await tester.pumpAndSettle();
      expect(find.text(strings.noMatchingOptions), findsOneWidget);
      await tester.enterText(search, 'sAMPLE 8');
      await tester.pumpAndSettle();
      expect(find.text('Sample 0'), findsNothing);
      await tester.tap(find.text('Sample 8'));
      await tester.pumpAndSettle();
      expect(selected, '8');
      expect(search, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
