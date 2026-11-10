import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats_controller.dart';

import 'fake_gateway.dart';
import 'demo_visual_support.dart';

void main() {
  for (final period in ['today', 'week', 'month', 'all']) {
    for (final dark in [false, true]) {
      for (final width in [1440.0, 1024.0, 720.0]) {
        testWidgets('总览 $period ${dark ? 'dark' : 'light'} $width', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, width == 1440 ? 1000 : 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final output = Platform.environment['D34_SCREENSHOT_DIR'];
          if (output != null) await loadSystemFonts(tester);
          final oldError = FlutterError.onError;
          FlutterError.onError = (details) {
            FlutterError.dumpErrorToConsole(details);
            oldError?.call(details);
          };
          addTearDown(() => FlutterError.onError = oldError);
          final fake = FakeStatsGateway();
          final controller = StatsController(
            fake,
            clock: () => demoNow,
            preferences: UiPreferences(
              period: StatsPeriod(period),
              appearance: dark ? 'dark' : 'light',
            ),
          );
          addTearDown(controller.dispose);
          await controller.load();
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: LensPalette(dark).theme,
                home: StatsPage(controller: controller),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('home-hero')), findsOneWidget);
          expect(find.text('趋势'), findsOneWidget);
          expect(tester.takeException(), isNull);
          if (output != null) {
            await capture(
              tester,
              boundary,
              '$output/home-$period-${dark ? 'dark' : 'light'}-${width.toInt()}.png',
            );
          }
          await tester.drag(
            find.byKey(const Key('stats-scroll')),
            const Offset(0, -1800),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (output != null) {
            await capture(
              tester,
              boundary,
              '$output/home-$period-${dark ? 'dark' : 'light'}-${width.toInt()}-bottom.png',
            );
          }
        });
      }
    }
  }
}
