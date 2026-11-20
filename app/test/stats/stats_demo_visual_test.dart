import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/period.dart';

import 'demo_visual_support.dart';

Map<String, Object> sessionGeometry(WidgetTester tester, double width) {
  const labels = ['会话', '开始', '本周用量', '本周请求', '本周约值'];
  final positions = <double>[];
  for (final label in labels) {
    final header = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.data == label &&
          w.style?.fontSize == 12 &&
          w.style?.fontWeight == FontWeight.w400,
      description: 'session table header $label',
    );
    positions.add(tester.getTopLeft(header).dx);
  }
  return {'width': width, 'headerLeft': positions};
}

void main() {
  final ledger = Platform.environment['D34_DEMO_LEDGER'];
  final output = Platform.environment['D34_SCREENSHOT_DIR'];
  if (ledger == null || ledger.isEmpty || output == null || output.isEmpty) {
    return;
  }
  testWidgets('D34B 合成账本 72 张截图（只 load，不 start/sync）', (tester) async {
    final geometries = <Map<String, Object>>[];
    final geometryErrors = <String>[];
    final today = DateTime.now();
    final bucket = dayKey(DateTime(today.year, today.month));
    // Matches CLAUDE_SESSION_ID in scripts/desktop_demo.py.
    const session = '00000000-0000-4000-8000-000000000601';
    const detail = '/dashboard?period=month&view=detail';
    final routes = {
      'detail-date': detail,
      'detail-tool': '$detail&dim=tool',
      'detail-model': '$detail&dim=model',
      'detail-project': '$detail&dim=project',
      'detail-filter': '$detail&tool=claude&dim=model',
      'detail-bucket': '$detail&bucket=$bucket&dim=tool',
      'sessions': '/sessions',
      'session-panel': '/sessions?source=claude&session=$session',
    };
    final targets = <({String name, String page, String query})>[
      for (final route in routes.entries)
        (
          name: route.key,
          page: route.value.startsWith('/sessions') ? 'sessions' : 'detail',
          query: Uri.parse(route.value).query,
        ),
      for (final period in ['today', 'week', 'month', 'all'])
        (name: 'home-$period', page: 'home', query: 'period=$period'),
    ];
    await captureDemoVisuals(
      tester,
      routes: targets,
      output: output,
      ledger: ledger,
      clock: () => today,
      onReady: (tester, target, dark, width) {
        if (target.name == 'sessions' && width >= 768) {
          final measurement = sessionGeometry(tester, width);
          measurement['scheme'] = dark ? 'dark' : 'light';
          geometries.add(measurement);
          final expected = width == 1440
              ? [308, 547, 892.9, 1006.9, 1323]
              : [308, 547, 701.9, 762.2, 910.8];
          final actual = measurement['headerLeft']! as List<double>;
          for (var i = 0; i < 5; i++) {
            if ((actual[i] - expected[i]).abs() > 6) {
              geometryErrors.add(
                '$width $dark column $i: ${actual[i]} vs ${expected[i]}',
              );
            }
          }
        }
      },
    );
    await tester.runAsync(
      () => File(
        '$output/fix1-geometry.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(geometries)),
    );
    expect(
      geometryErrors,
      isEmpty,
      reason: 'FIX1 session column left edges must be within 6 px of reference ink bounds',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
