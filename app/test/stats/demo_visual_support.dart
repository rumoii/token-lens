import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/src/rust/frb_generated.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

Future<void> loadSystemFonts(WidgetTester tester) async {
  if (!Platform.isWindows) return;
  await tester.runAsync(() async {
    for (final e in {
      'Segoe UI Variable Text': ['SegUIVar.ttf'],
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
  Future<StatsDiscovery> discovery({bool fresh = false}) =>
      track(super.discovery(fresh: fresh));
  @override
  Future<StatsHealth> health() => track(super.health());
  @override
  Future<StatsSync> sync() =>
      throw StateError('Demo visual test must never sync');
}

/// Creates owned TEMP directories. A null ledger leaves data without ledger.db.
Future<({Directory data, Directory logs})> createDemoVisualData(
  WidgetTester tester, {
  String? ledger,
}) async {
  // Only these two test-owned TEMP directories are ever opened by StatsClient.
  final root = await tester.runAsync(
    () => Directory.systemTemp.createTemp('token-lens-demo-data-'),
  );
  final logs = await tester.runAsync(
    () => Directory.systemTemp.createTemp('token-lens-demo-logs-'),
  );
  final data = Directory('${root!.path}/data');
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
  await tester.runAsync(() async {
    await data.create();
    if (ledger != null) await File(ledger).copy('${data.path}/ledger.db');
  });
  return (data: data, logs: logs!);
}

Future<void>? _rustInitialization;
Future<void> _initializeRust() => _rustInitialization ??= RustLib.init();

typedef DemoVisualRoute = ({String name, String page, String query});
typedef DemoVisualReady = FutureOr<void> Function(
  WidgetTester tester,
  DemoVisualRoute route,
  bool dark,
  double width,
);

/// Renders each route at 1440/1024/720 x 3600, light/dark, DPR 1.
/// Uses only load; sync is rejected. Omit ledger to render a new empty ledger.
/// Mounts as already onboarded, like the old dashboard's reference shots; pass
/// `onboarded: false` to render the first-run onboarding instead.
Future<void> captureDemoVisuals(
  WidgetTester tester, {
  required List<DemoVisualRoute> routes,
  required String output,
  String? ledger,
  DateTime Function()? clock,
  DemoVisualReady? onReady,
  bool onboarded = true,
}) async {
  await loadSystemFonts(tester);
  await tester.runAsync(() async {
    await _initializeRust();
    await Directory(output).create(recursive: true);
  });
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final directories = await createDemoVisualData(tester, ledger: ledger);
  final targets = routes;
  for (final target in targets) {
    for (final dark in [false, true]) {
      for (final width in [1440.0, 1024.0, 720.0]) {
        tester.view.physicalSize = Size(width, 3600);
        final client = await tester.runAsync(
          () => StatsClient.newInstance(
            dataDir: directories.data.path,
            logsHome: directories.logs.path,
          ),
        );
        final gateway = _DemoGateway(client!);
        final c = StatsController(
          gateway,
          clock: clock ?? () => DateTime(2026, 11, 9, 0),
          preferences: UiPreferences(
            period: StatsPeriod.parse(target.query),
            appearance: dark ? 'dark' : 'light',
            onboarded: onboarded,
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
          if (onReady != null) await onReady(tester, target, dark, width);
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
}
