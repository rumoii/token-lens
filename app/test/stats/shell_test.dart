import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';

import 'fake_gateway.dart';

void main() {
  for (final width in [1440.0, 720.0]) {
    testWidgets('侧栏及抽屉 $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = StatsController(
        FakeStatsGateway(),
        clock: () => demoNow,
      );
      addTearDown(controller.dispose);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: const LensPalette(false).theme,
          home: StatsPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      if (width < 768) {
        await tester.tap(find.byTooltip('打开导航菜单'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('用量明细'));
      await tester.pumpAndSettle();
      expect(find.text('这一页还在迁移'), findsOneWidget);
      expect(find.text('period=week&view=detail'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
