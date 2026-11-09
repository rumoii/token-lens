import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats_controller.dart';

import 'fake_gateway.dart';

Future<void> loadSystemFonts(WidgetTester tester) async {
  if (!Platform.isWindows) return;
  await tester.runAsync(() async {
    for (final e in {
      'Segoe UI': ['segoeui.ttf', 'segoeuib.ttf'],
      'Microsoft YaHei': ['msyh.ttc', 'msyhbd.ttc'],
      'Noto Serif SC': ['NotoSerifSC-VF.ttf'],
      'Georgia': ['georgia.ttf', 'georgiab.ttf'],
      'SimSun': ['simsun.ttc'],
    }.entries) {
      final loader = FontLoader(e.key);
      for (final name in e.value) {
        final file = File('${Platform.environment['SystemRoot']}/Fonts/$name');
        if (await file.exists()) {
          loader.addFont(
            Future.value(ByteData.sublistView(await file.readAsBytes())),
          );
        }
      }
      await loader.load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
}

Future<void> capture(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File(path).writeAsBytes(png!.buffer.asUint8List());
  });
}

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
