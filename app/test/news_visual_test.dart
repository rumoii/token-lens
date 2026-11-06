import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_page.dart';

import 'support/fake_news_gateway.dart';

void main() {
  for (final width in [1440.0, 700.0]) {
    testWidgets('multi-source layout at ${width.toInt()} pixels', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final output = Platform.environment['D2E_SCREENSHOT_DIR'];
      if (output != null && Platform.isWindows) {
        final font = File(
          '${Platform.environment['SystemRoot']}/Fonts/msyh.ttc',
        );
        await tester.runAsync(() async {
          final bytes = await font.readAsBytes();
          await (FontLoader(
            'Microsoft YaHei',
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          final icons = await rootBundle.load(
            'fonts/MaterialIcons-Regular.otf',
          );
          await (FontLoader(
            'MaterialIcons',
          )..addFont(Future.value(icons))).load();
        });
      }
      final gateway = FakeNewsGateway(cached: multiNews);
      final controller = NewsController(gateway);
      addTearDown(controller.dispose);
      await controller.load();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              fontFamily: output == null ? null : 'Microsoft YaHei',
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xffa74b2d),
              ),
            ),
            home: NewsPage(controller: controller, openLink: (_) async => true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('OpenAI 模型更新'), findsOneWidget);
      expect(find.text('也见于 Hacker News'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(controller.snapshot.sources.length, 16);
      expect(
        controller.snapshot.sources
            .where((source) => source.error != null)
            .length,
        3,
      );
      expect(
        controller.snapshot.sources.where((source) => !source.enabled).length,
        2,
      );
      if (output != null) {
        await _capture(tester, boundary, '$output/D2E-${width.toInt()}.png');
      }
      if (width == 1440) {
        await tester.tap(find.byKey(const Key('source-filter-menu')));
        await tester.pumpAndSettle();
        expect(find.byType(CheckboxMenuButton), findsNWidgets(17));
        if (output != null) {
          await _capture(tester, boundary, '$output/D2E-1440-sources.png');
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(find.byTooltip('卡片布局'));
      await tester.tap(find.byTooltip('卡片布局'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('news-cards')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('source-row-hn-ai')));
      await tester.tap(find.byKey(const Key('source-row-hn-ai')));
      await tester.pumpAndSettle();
      expect(find.textContaining('来源暂时限制请求'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  String path,
) async {
  await tester.runAsync(() async {
    final image =
        await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File(path).writeAsBytes(png!.buffer.asUint8List());
  });
}
