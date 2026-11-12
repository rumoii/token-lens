import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';

import 'support/developer_news.dart';
import 'support/fake_news_gateway.dart';

void main() {
  for (final width in [1440.0, 700.0]) {
    testWidgets('D2.5 sources and kinds at ${width.toInt()} pixels', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final output = Platform.environment['D25D_SCREENSHOT_DIR'];
      if (output != null && Platform.isWindows) {
        await tester.runAsync(() async {
          final bytes = await File(
            '${Platform.environment['SystemRoot']}/Fonts/msyh.ttc',
          ).readAsBytes();
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
      final gateway = FakeNewsGateway(cached: developerNews);
      final controller = NewsController(gateway);
      addTearDown(controller.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: const LensPalette(false).theme,
            home: NewsPage(controller: controller, openLink: (_) async => true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.snapshot.sources.length, 19);
      expect(find.byKey(const Key('item-kind-release')), findsWidgets);
      expect(find.byKey(const Key('item-kind-general')), findsNothing);
      final search = tester.getRect(find.byKey(const Key('news-search')));
      final filter = tester.getRect(find.byKey(const Key('news-filter')));
      expect(filter.left, greaterThan(search.right));
      expect(filter.center.dy, closeTo(search.center.dy, 2));
      expect(tester.takeException(), isNull);
      expect(gateway.refreshCalls, 0);
      if (output != null) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File('$output/D25D-${width.toInt()}.png')
              .writeAsBytes(png!.buffer.asUint8List());
        });
      }
    });
  }

  testWidgets(
    '700px dark mode at scale 2 supports type filter and keyboard sort',
    (tester) async {
      tester.view.physicalSize = const Size(700, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = NewsController(FakeNewsGateway(cached: developerNews));
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: const LensPalette(true).theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: NewsPage(controller: controller, openLink: (_) async => true),
        ),
      );
      await tester.pumpAndSettle();
      final filter = find.byKey(const Key('news-filter'));
      await tester.scrollUntilVisible(
        filter,
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('news-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(filter);
      await tester.pumpAndSettle();
      await tester.tap(filter);
      await tester.pumpAndSettle();
      final option = find.byKey(const Key('kind-filter-general')).first;
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.kindIds, {'general'});
      controller.toggleSourceFilter('hn-ai');
      await tester.pumpAndSettle();
      final hot = find.descendant(
        of: find.byKey(const Key('news-sort')),
        matching: find.text('热度'),
      );
      await tester.ensureVisible(hot);
      await tester.pumpAndSettle();
      Focus.of(tester.element(hot)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(controller.sort, NewsSort.hot);
      expect(tester.takeException(), isNull);
    },
  );
}
