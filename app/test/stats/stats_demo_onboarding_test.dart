import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_visual_support.dart';

void main() {
  testWidgets('空账本首次发现 light/dark × 1440/1024/720', (tester) async {
    if (Platform.environment['D34_DEMO_LEDGER'] == null ||
        Platform.environment['D34_SCREENSHOT_DIR'] == null) {
      return;
    }
    await captureDemoVisuals(
      tester,
      routes: [(name: 'onboarding', page: 'home', query: '')],
      output: Platform.environment['D34_SCREENSHOT_DIR']!,
      // Deliberately omit ledger: the real Rust client only sees empty TEMP data.
      onReady: (tester, route, dark, width) {
        expect(find.text('欢迎使用 Token Lens'), findsOneWidget);
        expect(find.text('在这台电脑上找到 0 个工具'), findsOneWidget);
        expect(find.text('支持 27 个'), findsOneWidget);
        expect(find.text('重新检测'), findsOneWidget);
        expect(find.text('页面导航'), findsNothing);
        expect(find.byKey(const Key('onboarding-mark')), findsOneWidget);
      },
    );
  });
}
