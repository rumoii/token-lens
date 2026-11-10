import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_visual_support.dart';

Map<String, Object> sessionGeometry(WidgetTester tester, double width) {
  const labels = ['会话', '开始', '时长', '用量', '约值'];
  final positions = <double>[];
  for (final label in labels) {
    final header = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.data == label &&
          w.style?.fontSize == 12 &&
          w.style?.fontWeight == FontWeight.w400,
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
    final taskRoot = File(ledger).parent.parent.path;
    final routes = jsonDecode(
      (await tester.runAsync(
        () => File('$taskRoot/d34b-routes.json').readAsString(),
      ))!,
    ) as List;
    final targets = <({String name, String page, String query})>[
      for (final route in routes)
        (
          name: route[0] as String,
          page: (route[1] as String).startsWith('/sessions')
              ? 'sessions'
              : 'detail',
          query: Uri.parse(route[1] as String).query,
        ),
      for (final period in ['today', 'week', 'month', 'all'])
        (name: 'home-$period', page: 'home', query: 'period=$period'),
    ];
    await captureDemoVisuals(
      tester,
      routes: targets,
      output: output,
      ledger: ledger,
      onReady: (tester, target, dark, width) {
        if (target.name == 'sessions' && width >= 768) {
          final measurement = sessionGeometry(tester, width);
          measurement['scheme'] = dark ? 'dark' : 'light';
          geometries.add(measurement);
          final expected = width == 1440
              ? [347, 618, 1051, 1171, 1311]
              : [309, 488, 761, 840, 933];
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
