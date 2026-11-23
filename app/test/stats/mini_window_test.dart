import 'dart:async';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/mini/mini_panel.dart';
import 'package:token_lens_app/stats/mini/mini_window.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/motion.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';

class MiniGateway extends FakeStatsGateway implements StatsMiniGateway {
  final miniReads = <DateTime>[];
  final windows = <int>[];

  StatsMiniUsage data = StatsMiniUsage(
    totals: const StatsTotals(
      grossTokens: 780,
      unpricedRecords: 12,
      recordCount: 12,
    ),
    projects: [
      for (var n = 12; n > 0; n--)
        StatsMiniProject(
          key: '/synthetic/project-$n',
          grossTokens: n * 10,
          tools: [StatsMiniTool(source: 'claude', grossTokens: n * 10)],
        ),
    ],
    minutes: [780],
    activeModels: const [
      StatsGroup(
        key: 'model-without-timing',
        source: 'claude',
        grossTokens: 1250,
        unpricedRecords: 1,
        recordCount: 1,
      ),
      StatsGroup(
        key: 'model-b',
        source: 'codex',
        grossTokens: 2,
        unpricedRecords: 1,
        recordCount: 1,
      ),
      StatsGroup(
        key: 'model-c',
        source: 'claude',
        grossTokens: 2,
        unpricedRecords: 1,
        recordCount: 1,
      ),
      StatsGroup(
        key: 'model-d',
        source: 'claude',
        grossTokens: 2,
        unpricedRecords: 1,
        recordCount: 1,
      ),
    ],
    requests: const StatsRequests(
      items: [
        StatsRequest(
          id: 'request',
          observedAt: '2026-11-09T05:00:00Z',
          source: 'claude',
          sessionId: 's',
          projectKey:
              '/synthetic/a-very-long-project-name-with-many-characters',
          model: 'model-a',
          outputTokens: 482,
          throughputTps: 39.4,
          ttftMs: 5800,
          unpricedRecords: 1,
          priceState: 'unknown',
        ),
      ],
      snapshot: demoSnapshot,
    ),
  );

  @override
  Future<StatsMiniUsage> miniUsage(
    DateTime now,
    int windowMinutes,
    List<String> excluded,
  ) async {
    miniReads.add(now);
    windows.add(windowMinutes);
    final values = data.minutes.reversed.take(windowMinutes).toList();
    return StatsMiniUsage(
      totals: data.totals,
      projects: data.projects,
      minutes: [
        ...List.filled(windowMinutes - values.length, 0),
        ...values.reversed,
      ],
      activeModels: data.activeModels,
      requests: data.requests,
    );
  }
}

class MiniPlatform implements MiniWindowPlatform {
  @override
  String? get pendingMethod => null;

  final calls = <Object>[];
  ValueChanged<Size?>? onResize;
  Rect bounds = const Rect.fromLTWH(240, 96, 1050, 800);
  @override
  Future<Rect> getBounds() async => bounds;
  @override
  Future<MiniFrame> getFrame() async => (bounds: bounds, scale: 1.0);
  @override
  bool get supportsPillTuck => false;
  @override
  Future<void> setPillFrame(bool value) async => calls.add(('pill', value));
  @override
  Future<void> setPillTooltip(String? text) async {}
  @override
  Future<void> setPillBounds(Rect value, MiniDisplay display) =>
      setBounds(value);
  @override
  Future<bool> isPrimaryButtonDown() async => true;
  @override
  Future<bool> dragPill({
    Color? edgeAccent,
    bool requirePressed = false,
  }) async {
    await startDragging();
    return true;
  }

  @override
  Future<List<MiniDisplay>> workAreas() async => [
    const MiniDisplay(Rect.fromLTWH(0, 0, 1920, 1040)),
  ];
  @override
  Future<bool> isMaximized() async => false;
  @override
  Future<void> setMaximized(bool value) async => calls.add(('maximize', value));
  @override
  Future<void> setCompact(bool value, {required bool rounded}) async =>
      calls.add(('compact', value, rounded));
  @override
  Future<void> setPinned(bool value) async => calls.add(('pin', value));
  @override
  Future<void> setLimits(Size min, Size? max) async => calls.add((min, max));
  @override
  Future<void> setBounds(Rect value) async {
    bounds = value;
    calls.add(value);
  }

  @override
  Future<void> startDragging() async {}
  @override
  void observeBounds(VoidCallback? callback, {ValueChanged<Size?>? onResize}) {
    this.onResize = onResize;
  }
}

class _MiniTickCanvas extends TestRecordingCanvas {
  final ticks = <double>[];

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    if (p1.dy == 50.5 && p2.dy == 53.5 && p1.dx == p2.dx) {
      ticks.add(p1.dx);
    }
  }
}

List<double> _paintedMiniTicks(WidgetTester tester, Finder chart) {
  final axes = find
      .descendant(
        of: chart,
        matching: find.byWidgetPredicate(
          (widget) => widget is CustomPaint && widget.painter != null,
        ),
      )
      .first;
  final canvas = _MiniTickCanvas();
  tester.widget<CustomPaint>(axes).painter!.paint(canvas, tester.getSize(axes));
  return canvas.ticks;
}

void main() {
  testWidgets('a normal mini transition logs only start and end', (
    tester,
  ) async {
    final controller = StatsController(MiniGateway(), clock: () => demoNow);
    final messages = <(String, String)>[];
    final window = MiniWindow(
      controller: controller,
      platform: MiniPlatform(),
      log: (level, message) => messages.add((level, message)),
    );
    addTearDown(controller.dispose);
    addTearDown(window.dispose);
    await window.enter();
    await tester.pump(const Duration(seconds: 6));
    expect(messages, hasLength(2));
    expect(messages.first, ('INFO', 'start action=enter id=1'));
    expect(messages.last.$1, 'INFO');
    expect(
      messages.last.$2,
      matches(r'^end action=enter id=1 elapsedMs=\d+ result=ok$'),
    );
    await controller.shutdown();
  });

  testWidgets('warns after five seconds with the pending platform method', (
    tester,
  ) async {
    const channel = MethodChannel('token_lens/window');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final reply = Completer<Object?>();
    final sent = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'workAreas');
      sent.complete();
      return reply.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final controller = StatsController(MiniGateway(), clock: () => demoNow);
    final platform = DesktopMiniWindowPlatform();
    final messages = <(String, String)>[];
    final window = MiniWindow(
      controller: controller,
      platform: platform,
      log: (level, message) => messages.add((level, message)),
    );
    addTearDown(controller.dispose);
    addTearDown(window.dispose);

    final result = window.enter().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    await sent.future;
    expect(platform.pendingMethod, 'workAreas');
    await tester.pump(const Duration(milliseconds: 4999));
    expect(messages, [('INFO', 'start action=enter id=1')]);
    await tester.pump(const Duration(milliseconds: 1));
    expect(messages.last.$1, 'WARN');
    expect(messages.last.$2, contains('platformMethod=workAreas'));
    expect(window.switching, isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(messages.where((entry) => entry.$1 == 'WARN'), hasLength(1));

    reply.completeError(PlatformException(code: 'synthetic-error'));
    expect(await result, isA<PlatformException>());
    expect(platform.pendingMethod, isNull);
    expect(window.switching, isFalse);
    expect(
      messages.last.$2,
      endsWith('result=error errorType=PlatformException'),
    );
    await controller.shutdown();
  });

  testWidgets('mini window entry is in both page headers', (tester) async {
    final c = StatsController(
      MiniGateway(),
      preferences: const UiPreferences(onboarded: true),
      clock: () => demoNow,
    );
    final window = MiniWindow(controller: c, platform: MiniPlatform());
    addTearDown(c.dispose);
    addTearDown(window.dispose);
    await c.load();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(720, 950);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: const LensPalette(false).theme,
        home: StatsPage(controller: c, miniWindow: window),
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.widgetWithText(LensButton, '小窗');
    final navigation = find.widgetWithText(LensSegmented, '明细');
    void expectEntry() {
      expect(entry, findsOneWidget);
      expect(find.byTooltip('小窗'), findsNothing);
      expect(
        tester.getTopLeft(entry).dy,
        lessThanOrEqualTo(tester.getTopLeft(navigation).dy),
      );
    }

    expectEntry();
    await tester.tap(
      find.descendant(of: navigation, matching: find.text('明细')),
    );
    await tester.pumpAndSettle();
    expectEntry();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(c.miniMode, isTrue);
    await c.shutdown();
  });

  for (final scenario in [
    'dismiss',
    'open',
    'no window',
    'empty',
    'not onboarded',
  ]) {
    testWidgets('overview mini window hint $scenario', (tester) async {
      final g = MiniGateway()..empty = scenario == 'empty';
      final c = StatsController(
        g,
        preferences: UiPreferences(onboarded: scenario != 'not onboarded'),
        clock: () => demoNow,
      );
      final window = MiniWindow(controller: c, platform: MiniPlatform());
      addTearDown(c.dispose);
      addTearDown(window.dispose);
      await c.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: const LensPalette(false).theme,
          home: StatsPage(
            controller: c,
            miniWindow: scenario == 'no window' ? null : window,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final hint = find.text('想边用 AI 边看 token 用量？');
      final show = scenario == 'dismiss' || scenario == 'open';
      expect(hint, show ? findsOneWidget : findsNothing);
      if (!show) return;
      if (scenario == 'dismiss') {
        await tester.tap(find.byTooltip('不再提示'));
      } else {
        await tester.tap(find.text('打开小窗'));
        await tester.pumpAndSettle();
        expect(c.miniMode, isTrue);
        await window.exit();
      }
      await tester.pumpAndSettle();
      expect(hint, findsNothing);
      expect(
        UiPreferences.decode(c.preferences.encode()).encode(),
        contains('"miniHintDismissed":true'),
      );
    });
  }

  test('mini chart range decodes, validates and persists', () async {
    final dir = await Directory.systemTemp.createTemp('mini-chart-prefs-');
    addTearDown(() => dir.delete(recursive: true));
    final store = PreferencesStore(dir);
    for (final (input, expected) in [(15, 15), (30, 30), (60, 60), (17, 15)]) {
      await store.write(
        UiPreferences.decode('{"mini":{"chartMinutes":$input}}'),
      );
      expect((await store.read()).mini.encode()['chartMinutes'], expected);
    }
    expect(UiPreferences.decode('{}').mini.encode()['chartMinutes'], 15);
  });

  testWidgets('an exact minute boundary reads the ledger without syncing', (
    tester,
  ) async {
    final gateway = MiniGateway();
    final start = DateTime(2026, 11, 21, 14, 26, 59, 900);
    var now = start;
    final c = StatsController(gateway, clock: () => now);
    addTearDown(c.dispose);
    await c.setMiniMode(true);
    expect(gateway.miniReads, [start]);
    now = start.add(const Duration(milliseconds: 99));
    await tester.pump(const Duration(milliseconds: 99));
    expect(gateway.miniReads, [start]);
    now = now.add(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(gateway.miniReads, [start, now]);
    expect(c.lastSync, isNull);
    expect(c.miniUpdatedAt, start);
    await c.setMiniMode(false);
    await tester.pump(const Duration(minutes: 1));
    expect(gateway.miniReads.length, 2);
    await c.shutdown();
  });

  testWidgets('mini chart shows axes and reachable hover at default size', (
    tester,
  ) async {
    final gateway = MiniGateway();
    final c = StatsController(
      gateway,
      clock: () => DateTime(2026, 11, 21, 14, 26),
    );
    final window = MiniWindow(controller: c, platform: MiniPlatform());
    addTearDown(() async {
      window.dispose();
      c.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.binding.setSurfaceSize(const Size(304, 620));
    await c.setMiniMode(true);
    await tester.pumpWidget(panel(c, window));
    await tester.pumpAndSettle();
    expect(find.text('Now'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Usage in the last 15 min, one point per minute'),
      findsOneWidget,
    );
    final chart = find.byKey(const Key('mini-usage-chart'));
    final bounds = tester.getRect(chart);
    expect(bounds.width, inInclusiveRange(96, 176));
    expect(bounds.right, lessThan(304));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: bounds.topRight + const Offset(-2, 16));
    await tester.pumpAndSettle();
    expect(miniStatusText('14:26 so far · 780 tokens'), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await c.shutdown();
  });

  testWidgets('chart ticks, compact labels, and range settings', (
    tester,
  ) async {
    final gateway = MiniGateway();
    gateway.data = StatsMiniUsage(
      totals: const StatsTotals(
        grossTokens: 1560000,
        unpricedRecords: 0,
        recordCount: 12,
      ),
      projects: gateway.data.projects,
      minutes: [16000],
      activeModels: gateway.data.activeModels,
      requests: gateway.data.requests,
    );
    final c = StatsController(
      gateway,
      preferences: const UiPreferences(language: 'en'),
      clock: () => DateTime(2026, 11, 21, 14, 26),
    );
    final window = MiniWindow(controller: c, platform: MiniPlatform());
    addTearDown(() async {
      window.dispose();
      c.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    await c.setMiniMode(true);
    await tester.binding.setSurfaceSize(const Size(304, 620));
    await tester.pumpWidget(panel(c, window, reduced: true));
    await tester.pumpAndSettle();
    final chart = find.byKey(const Key('mini-usage-chart'));
    final bounds = tester.getRect(chart);
    expect(tester.getTopRight(find.text('tokens')).dx, lessThan(bounds.left));
    expect(bounds.width, inInclusiveRange(96, 176));
    expect(bounds.right, lessThanOrEqualTo(304 - 16));
    expect(find.byType(MiniProjectRow), findsNWidgets(5));
    const curveKey = Key('mini-usage-curve');
    expect(find.byKey(curveKey), findsOneWidget);
    expect(
      find.descendant(
        of: chart,
        matching: find.byWidgetPredicate((w) => w is TweenAnimationBuilder),
      ),
      findsNothing,
    );
    await tester.binding.setSurfaceSize(const Size(480, 620));
    await tester.pumpAndSettle();
    expect(tester.getSize(chart).width, 176);
    Finder axis(String text) =>
        find.descendant(of: chart, matching: find.text(text));
    for (final value in ['0', '10K', '20K', 'Now', '14:15', '14:20']) {
      expect(axis(value), findsOneWidget);
    }
    expect(axis('14:25'), findsNothing);
    await tester.tap(find.byTooltip('Compact window settings'));
    await tester.pumpAndSettle();
    expect(find.text('Chart range'), findsOneWidget);
    for (final label in ['15 min', '30 min', '1 hour']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('30 min'));
    await tester.pumpAndSettle();
    for (final value in ['14:00', '14:10']) {
      expect(axis(value), findsOneWidget);
    }
    expect(axis('14:15'), findsNothing);
    expect(axis('14:20'), findsNothing);
    await tester.tap(find.byTooltip('Compact window settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 hour'));
    await tester.pumpAndSettle();
    expect(gateway.windows, [15, 30, 60]);
    final step = (tester.getSize(chart).width - 30) / 60;
    expect(_paintedMiniTicks(tester, chart), [
      closeTo(28 + 18.5 * step, .01), // 13:45
      closeTo(28 + 33.5 * step, .01), // 14:00
    ]);
    expect(axis('14:00'), findsOneWidget);
    expect(axis('14:20'), findsNothing);
    expect(axis('13:30'), findsNothing); // 8.5 px from the left of the plot.
    expect(axis('14:15'), findsNothing); // 28 px from the right of the plot.
    expect(c.lastSync, isNull);
    expect(tester.takeException(), isNull);
    final focus = find.descendant(of: chart, matching: find.byType(Focus));
    Focus.of(
      tester.element(
        find
            .descendant(of: focus.first, matching: find.byType(MouseRegion))
            .first,
      ),
    ).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(miniStatusText('14:25 · 0 tokens'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await c.shutdown();
  });

  testWidgets('narrow hour chart keeps full-size labels and favors the hour', (
    tester,
  ) async {
    final c = StatsController(
      MiniGateway(),
      preferences: const UiPreferences(mini: MiniPreferences(chartMinutes: 60)),
      clock: () => DateTime(2026, 11, 21, 14, 38),
    );
    final window = MiniWindow(controller: c, platform: MiniPlatform());
    addTearDown(() async {
      window.dispose();
      c.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.binding.setSurfaceSize(const Size(356, 620));
    await c.setMiniMode(true);
    await tester.pumpWidget(panel(c, window, reduced: true));
    await tester.pumpAndSettle();
    final chart = find.byKey(const Key('mini-usage-chart'));
    final width = tester.getSize(chart).width;
    expect(width, lessThan(176));
    final step = (width - 30) / 60;
    expect(_paintedMiniTicks(tester, chart), [
      closeTo(28 + 6.5 * step, .01), // 13:45
      closeTo(28 + 21.5 * step, .01), // 14:00
      closeTo(28 + 36.5 * step, .01), // 14:15
    ]);

    Finder axis(String text) =>
        find.descendant(of: chart, matching: find.text(text));
    final hour = axis('14:00');
    final now = axis('Now');
    final hourRect = tester.getRect(hour);
    final nowRect = tester.getRect(now);
    expect(
      tester.widget<Text>(hour).style!.fontSize,
      tester.widget<Text>(now).style!.fontSize,
    );
    expect(hourRect.width, closeTo(tester.getSize(hour).width, .01));
    expect(nowRect.width, closeTo(tester.getSize(now).width, .01));
    expect(nowRect.left - hourRect.right, greaterThanOrEqualTo(4));
    expect(axis('13:45'), findsNothing);
    expect(axis('14:15'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await c.shutdown();
  });

  testWidgets('hover replaces the status through a clock tick until exit', (
    tester,
  ) async {
    final start = DateTime(2026, 11, 21, 14, 26);
    var now = start;
    final c = StatsController(MiniGateway(), clock: () => now);
    final window = MiniWindow(controller: c, platform: MiniPlatform());
    addTearDown(() {
      window.dispose();
      c.dispose();
    });
    await c.setMiniMode(true);
    await tester.pumpWidget(panel(c, window, reduced: true));
    now = start.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(miniStatusText(englishStrings.miniUpdated(3, 10)), findsOneWidget);

    final chart = find.byKey(const Key('mini-usage-chart'));
    final bounds = tester.getRect(chart);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: bounds.topLeft + const Offset(29, 16));
    await tester.pump();
    expect(miniStatusText('14:12 · 0 tokens'), findsOneWidget);
    await mouse.moveTo(bounds.topRight + const Offset(-2, 16));
    await tester.pump();
    const current = '14:26 so far · 780 tokens';
    expect(miniStatusText(current), findsOneWidget);
    expect(find.text(current), findsOneWidget);
    expect(
      find.descendant(of: chart, matching: find.byType(OverlayPortal)),
      findsNothing,
    );
    const palette = LensPalette(false);
    expect(tester.widget<SyncDot>(find.byType(SyncDot)).color, palette['clay']);
    expect(
      tester.widget<Text>(miniStatusText(current)).style!.color,
      palette.secondary,
    );

    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(miniStatusText(current), findsOneWidget);
    expect(find.textContaining('Updated '), findsNothing);

    await mouse.moveTo(bounds.bottomRight + const Offset(0, 10));
    await tester.pump();
    expect(find.text(current), findsNothing);
    expect(miniStatusText(englishStrings.miniUpdated(4, 10)), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await c.shutdown();
  });

  testWidgets(
    'keyboard selection updates status and chart semantics until blur',
    (tester) async {
      final c = StatsController(
        MiniGateway(),
        clock: () => DateTime(2026, 11, 21, 14, 26),
      );
      final window = MiniWindow(controller: c, platform: MiniPlatform());
      addTearDown(() {
        window.dispose();
        c.dispose();
      });
      await c.setMiniMode(true);
      await tester.pumpWidget(panel(c, window, reduced: true));
      await tester.pumpAndSettle();
      final chart = find.byKey(const Key('mini-usage-chart'));
      final focus = Focus.of(
        tester.element(
          find.descendant(of: chart, matching: find.byType(MouseRegion)),
        ),
      );
      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(miniStatusText('14:26 so far · 780 tokens'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      const earlier = '14:25 · 0 tokens';
      expect(miniStatusText(earlier), findsOneWidget);
      expect(
        tester
            .getSemantics(
              find.bySemanticsLabel(englishStrings.miniChartLabel(15)),
            )
            .value,
        earlier,
      );
      expect(find.bySemanticsLabel(earlier), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(miniStatusText('14:26 so far · 780 tokens'), findsOneWidget);
      focus.unfocus();
      await tester.pumpAndSettle();
      expect(miniStatusText(englishStrings.miniUpdated(0, 10)), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await c.shutdown();
    },
  );

  for (final syncing in [false, true]) {
    testWidgets(
      'hover takes precedence while sync is ${syncing ? 'running' : 'failed'}',
      (tester) async {
        final gateway = MiniGateway();
        final c = StatsController(
          gateway,
          clock: () => DateTime(2026, 11, 21, 14, 26),
        );
        final window = MiniWindow(controller: c, platform: MiniPlatform());
        addTearDown(() {
          window.dispose();
          c.dispose();
        });
        await c.setMiniMode(true);
        await tester.pumpWidget(panel(c, window, reduced: true));
        if (syncing) {
          gateway.syncBarrier = Completer<void>();
        } else {
          gateway.syncFailure = 'fixture failure';
        }
        final sync = c.sync();
        if (!syncing) await sync;
        await tester.pump();
        final label = syncing
            ? englishStrings.syncing
            : englishStrings.miniSyncFailed;
        final retry = find.text(englishStrings.retry);
        final retryWhenIdle = syncing ? findsNothing : findsOneWidget;
        expect(miniStatusText(label), findsOneWidget);
        expect(retry, retryWhenIdle);

        final chart = find.byKey(const Key('mini-usage-chart'));
        final bounds = tester.getRect(chart);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(
          location: bounds.topRight + const Offset(-2, 16),
        );
        await tester.pump();
        expect(miniStatusText('14:26 so far · 780 tokens'), findsOneWidget);
        expect(find.text(label), findsNothing);
        expect(retry, findsNothing);
        await mouse.moveTo(bounds.bottomRight + const Offset(0, 10));
        await tester.pump();
        expect(miniStatusText(label), findsOneWidget);
        expect(retry, retryWhenIdle);

        gateway.syncBarrier?.complete();
        await sync;
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
        await c.shutdown();
      },
    );
  }

  testWidgets('empty chart has zero axis only and no line or point', (
    tester,
  ) async {
    final gateway = MiniGateway();
    gateway.data = const StatsMiniUsage(
      totals: StatsTotals(grossTokens: 0, unpricedRecords: 0, recordCount: 0),
      projects: [],
      minutes: [0],
      activeModels: [],
      requests: StatsRequests(items: [], snapshot: demoSnapshot),
    );
    final c = StatsController(
      gateway,
      clock: () => DateTime(2026, 11, 21, 14, 26),
    );
    final window = MiniWindow(controller: c, platform: MiniPlatform());
    addTearDown(() {
      window.dispose();
      c.dispose();
    });
    await c.setMiniMode(true);
    await tester.pumpWidget(panel(c, window));
    await tester.pumpAndSettle();
    final chart = find.byKey(const Key('mini-usage-chart'));
    expect(
      find.descendant(of: chart, matching: find.text('0')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chart, matching: find.text('Now')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('mini-usage-curve')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await c.shutdown();
  });

  testWidgets('resize grip follows hover and live size follows the window', (
    tester,
  ) async {
    final c = StatsController(MiniGateway());
    final platform = MiniPlatform();
    final window = MiniWindow(controller: c, platform: platform);
    await window.enter();
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(304, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(panel(c, window));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(-10, -10));
    final grip = find.byKey(const Key('mini-resize-grip'));
    expect(tester.widget<AnimatedOpacity>(grip).opacity, 0);
    await mouse.moveTo(const Offset(240, 560));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(grip).opacity, .8);
    platform.onResize?.call(const Size(319.6, 640.2));
    await tester.pumpAndSettle();
    expect(find.text('320 × 640'), findsOneWidget);
    platform.onResize?.call(null);
    await tester.pumpAndSettle();
    expect(find.text('320 × 640'), findsNothing);
    await mouse.moveTo(const Offset(-10, -10));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(grip).opacity, 0);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    window.dispose();
    await c.shutdown();
    c.dispose();
  });

  test('mini prefs round trip and validate defaults', () async {
    final dir = await Directory.systemTemp.createTemp('mini-prefs-');
    addTearDown(() => dir.delete(recursive: true));
    final store = PreferencesStore(dir);
    const bounds = Rect.fromLTWH(-550, 112, 320, 650);
    await store.write(
      const UiPreferences(
        mini: MiniPreferences(
          bounds: bounds,
          pinned: false,
          seconds: 15,
          projects: 5,
        ),
      ),
    );
    final mini = (await store.read()).mini;
    expect(
      (mini.bounds, mini.pinned, mini.seconds, mini.projects),
      (bounds, false, 15, 5),
    );
    expect(UiPreferences.decode('{}').mini.seconds, 10);
    expect(
      UiPreferences.decode('{"mini":{"seconds":17,"projects":-2}}')
          .mini
          .projects,
      -1,
    );
  });

  testWidgets('window operations restore the captured full window', (
    tester,
  ) async {
    final c = StatsController(MiniGateway());
    final platform = MiniPlatform();
    final window = MiniWindow(controller: c, platform: platform);
    final full = platform.bounds;
    await c.setPreferences(
      const UiPreferences(
        mini: MiniPreferences(bounds: Rect.fromLTWH(10000, 0, 330, 690)),
      ),
    );
    await window.enter();
    expect(platform.calls, [
      ('compact', true, true),
      (const Size(296, 480), const Size(480, 900)),
      const Rect.fromLTWH(1574, 16, 330, 690),
      ('pin', true),
    ]);
    await window.exit();
    expect(platform.calls.sublist(4), [
      ('pin', false),
      (const Size(700, 500), null),
      ('compact', false, false),
      full,
    ]);
    expect(c.preferences.mini.bounds, const Rect.fromLTWH(1574, 16, 330, 690));
    window.dispose();
    await c.shutdown();
    c.dispose();
  });

  testWidgets('one timer changes cadence and skips a running sync', (
    tester,
  ) async {
    final gateway = MiniGateway();
    final c = StatsController(
      gateway,
      preferences: const UiPreferences(
        onboarded: true,
        autoCheckUpdates: false,
      ),
    );
    await c.start();
    await c.setMiniMode(true);
    await tester.pump(const Duration(seconds: 9));
    expect(gateway.syncs, 1);
    gateway.syncBarrier = Completer<void>();
    await tester.pump(const Duration(seconds: 1));
    expect(gateway.syncs, 2);
    await tester.pump(const Duration(seconds: 30));
    expect(gateway.syncs, 2);
    gateway.syncBarrier!.complete();
    await tester.pump();
    expect(gateway.syncs, 2);
    await c.setPreferences(
      c.preferences.copyWith(mini: const MiniPreferences(seconds: 5)),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(gateway.syncs, 3);
    await c.setMiniMode(false);
    await tester.pump(const Duration(minutes: 4, seconds: 59));
    expect(gateway.syncs, 3);
    await tester.pump(const Duration(seconds: 1));
    expect(gateway.syncs, 4);
    await c.shutdown();
    c.dispose();
  });

  testWidgets(
    'fit uses the resize constraints and retains the totals of the rest',
    (tester) async {
      final gateway = MiniGateway();
      final c = StatsController(gateway);
      await c.setMiniMode(true);
      final window = MiniWindow(controller: c, platform: MiniPlatform());
      Future<void> resize(double height) async {
        await tester.binding.setSurfaceSize(Size(304, height));
        await tester.pumpWidget(panel(c, window));
        await tester.pumpAndSettle();
      }

      addTearDown(() => tester.binding.setSurfaceSize(null));
      await resize(480);
      final short = find.byKey(
        const ValueKey<String?>('/synthetic/project-12'),
      );
      expect(short, findsOneWidget);
      final segment = find.descendant(
        of: short,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox &&
              widget.color == const LensPalette(false).toolBrand('claude'),
        ),
      );
      expect(tester.getSize(segment), const Size(52, 2));
      final shortCount = find.byType(MiniProjectRow).evaluate().length;
      await resize(620);
      expect(find.byType(MiniProjectRow), findsNWidgets(5));
      expect(shortCount, lessThan(5));
      expect(find.text('7 more projects'), findsOneWidget);
      expect(find.text('280'), findsOneWidget);
      expect(find.byType(Scrollable), findsNothing);
      await resize(870);
      expect(find.byType(MiniProjectRow).evaluate().length, greaterThan(5));
      await resize(620);
      await c.setPreferences(
        c.preferences.copyWith(mini: const MiniPreferences(projects: 3)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MiniProjectRow), findsNWidgets(3));
      expect(find.text('9 more projects'), findsOneWidget);
      expect(find.text('450'), findsOneWidget);
      expect(find.byType(Scrollable), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      window.dispose();
      await c.shutdown();
      c.dispose();
    },
  );

  testWidgets(
    'empty and failed states, no timing, and intact English request metrics',
    (tester) async {
      final gateway = MiniGateway();
      final c = StatsController(gateway);
      final window = MiniWindow(controller: c, platform: MiniPlatform());
      await c.setMiniMode(true);
      await tester.binding.setSurfaceSize(const Size(296, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(panel(c, window));
      await tester.pumpAndSettle();
      expect(
        find.byTooltip(
          "Claude Code doesn't log generation time, so this shows usage in the last 5 min.",
        ),
        findsNWidgets(3),
      );
      await tester.tap(find.text('Requests'));
      await tester.pumpAndSettle();
      final metrics = find.byKey(const Key('mini-request-metrics'));
      expect(tester.getRect(metrics).right, lessThanOrEqualTo(296));
      expect(find.textContaining('39.4', findRichText: true), findsOneWidget);
      expect(
        find.textContaining('First token 5.8s', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      gateway.syncFailure = 'fixture failure';
      await c.sync();
      await tester.pumpAndSettle();
      expect(find.text('Sync failed. Showing earlier data.'), findsOneWidget);
      expect(find.text('Output 482'), findsOneWidget);
      gateway.syncFailure = null;
      gateway.data = const StatsMiniUsage(
        totals: StatsTotals(grossTokens: 0, unpricedRecords: 0, recordCount: 0),
        projects: [],
        minutes: [0],
        activeModels: [],
        requests: StatsRequests(items: [], snapshot: demoSnapshot),
      );
      await c.sync();
      await tester.pumpAndSettle();
      expect(find.text('No requests yet today'), findsOneWidget);
      await tester.tap(find.text('Overview'));
      await tester.pumpAndSettle();
      expect(find.text('No usage yet today'), findsOneWidget);
      expect(find.text('No models used in the last 5 min'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      window.dispose();
      await c.shutdown();
      c.dispose();
    },
  );
}

Finder miniStatusText(String text) => find.descendant(
  of: find.ancestor(of: find.byType(SyncDot), matching: find.byType(Row)).first,
  matching: find.text(text),
);

Widget panel(StatsController c, MiniWindow window, {bool reduced = false}) =>
    MaterialApp(
      theme: const LensPalette(false).theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: AppLanguageScope(
        strings: englishStrings,
        child: MiniPanel(
          controller: c,
          window: window,
          onExpand: () {},
          onProject: (_) {},
          onRequest: (_) {},
        ),
      ),
    );
