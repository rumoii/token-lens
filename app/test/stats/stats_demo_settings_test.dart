import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/settings_page.dart';

import 'demo_visual_support.dart';

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => throw StateError(
    'Settings screenshots must never request exchange rates',
  );
}

void main() {
  testWidgets('settings 合成账本六图，未点击时禁止联网', (tester) async {
    final ledger = Platform.environment['D34_DEMO_LEDGER'];
    final output = Platform.environment['D34_SCREENSHOT_DIR'];
    if (ledger == null || output == null) return;
    await HttpOverrides.runZoned(
      () => captureDemoVisuals(
        tester,
        routes: [(name: 'settings', page: 'settings', query: '')],
        output: output,
        ledger: ledger,
        onReady: (tester, route, dark, width) async {
          // The helper chooses a rendered theme; the reference preference is system.
          final c = tester
              .widget<StatsSettingsPage>(find.byType(StatsSettingsPage))
              .controller;
          await c.setPreferences(c.preferences.copyWith(appearance: 'system'));
          await tester.pumpAndSettle();
          expect(find.text('更新汇率'), findsOneWidget);
          expect(find.text('1 美元 ≈ 6.70 元 · 内置汇率'), findsOneWidget);
          expect(find.text('claude-sonnet-5-5'), findsOneWidget);
        },
      ),
      createHttpClient: _NoNetwork().createHttpClient,
    );
  });
}
