import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/src/rust/frb_generated.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'stats_visual_test.dart' show loadSystemFonts, capture;

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

class _DemoGateway extends RustStatsGateway {
  _DemoGateway(super.client);
  final pending = <Future<void>>{};
  Future<T> track<T>(Future<T> request) {
    final finished = request.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    pending.add(finished);
    unawaited(finished.whenComplete(() => pending.remove(finished)));
    return request;
  }

  Future<void> settle() async {
    while (pending.isNotEmpty) {
      await Future.wait(pending.toList());
    }
  }

  @override
  Future<StatsSummary> summary(StatsFilter filter) =>
      track(super.summary(filter));
  @override
  Future<StatsTimeseries> timeseries(String granularity, StatsFilter filter) =>
      track(super.timeseries(granularity, filter));
  @override
  Future<StatsMatrix> matrix(
    String granularity,
    String by,
    StatsFilter filter,
  ) => track(super.matrix(granularity, by, filter));
  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) =>
      track(super.breakdown(by, filter));
  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) => track(super.sessions(filter, limit: limit, cursor: cursor));
  @override
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity,
  ) => track(super.sessionDetail(source, sessionId, granularity));
  @override
  Future<StatsSources> sources() => track(super.sources());
  @override
  Future<StatsPricing> pricing() => track(super.pricing());
  @override
  Future<StatsSync> sync() =>
      throw StateError('Demo visual test must never sync');
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
    await loadSystemFonts(tester);
    await tester.runAsync(() async {
      await RustLib.init();
      await Directory(output).create(recursive: true);
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Only these two test-owned TEMP directories are ever opened by StatsClient.
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('token-lens-d34b-demo-'),
    );
    final logs = await tester.runAsync(
      () => Directory.systemTemp.createTemp('token-lens-d34b-logs-'),
    );
    final data = Directory('${root!.path}/data');
    await tester.runAsync(() async {
      await data.create();
      await File(ledger).copy('${data.path}/ledger.db');
    });
    addTearDown(() async {
      for (final owned in [root, logs!]) {
        final temp = await Directory.systemTemp.resolveSymbolicLinks();
        final resolved = await owned.resolveSymbolicLinks();
        if (!resolved.startsWith('$temp${Platform.pathSeparator}')) {
          throw StateError('Demo directory escaped TEMP');
        }
        // Refuse to traverse any unexpected links during cleanup.
        await for (final item in owned.list(
          recursive: true,
          followLinks: false,
        )) {
          if (await FileSystemEntity.type(item.path, followLinks: false) ==
              FileSystemEntityType.link) {
            throw StateError('Unexpected link in demo TEMP');
          }
        }
        await owned.delete(recursive: true);
      }
    });
    for (final target in targets) {
      for (final dark in [false, true]) {
        for (final width in [1440.0, 1024.0, 720.0]) {
          tester.view.physicalSize = Size(width, 3600);
          final client = await tester.runAsync(
            () => StatsClient.newInstance(
              dataDir: data.path,
              logsHome: logs!.path,
            ),
          );
          final gateway = _DemoGateway(client!);
          final c = StatsController(
            gateway,
            clock: () => DateTime(2026, 11, 9, 0),
            preferences: UiPreferences(
              period: StatsPeriod.parse(target.query),
              appearance: dark ? 'dark' : 'light',
            ),
          );
          try {
            await tester.runAsync(c.load);
            expect(c.error, isNull);
            expect(c.resourceErrors, isEmpty);
            final boundary = GlobalKey();
            await tester.runAsync(() async {
              await tester.pumpWidget(
                RepaintBoundary(
                  key: boundary,
                  child: MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: LensPalette(dark).theme,
                    home: StatsPage(controller: c),
                  ),
                ),
              );
              if (target.page != 'home') {
                (tester.state(find.byType(StatsPage)) as dynamic).navigate(
                  target.page,
                  Uri.splitQueryString(target.query),
                );
              }
              for (var i = 0; i < 3; i++) {
                await tester.pump();
                await gateway.settle();
              }
            });
            await tester.pumpAndSettle();
            expect(find.byType(SkeletonLines), findsNothing);
            expect(find.text('加载失败（request_failed）'), findsNothing);
            expect(
              tester.takeException(),
              isNull,
              reason: '${target.name} $dark $width',
            );
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
            await capture(
              tester,
              boundary,
              '$output/${target.name}-${dark ? 'dark' : 'light'}-${width.toInt()}.png',
            );
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
          } finally {
            await tester.runAsync(c.shutdown);
            c.dispose();
          }
        }
      }
    }
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
