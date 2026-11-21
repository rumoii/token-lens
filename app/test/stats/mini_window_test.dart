import 'dart:async';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/mini/mini_panel.dart';
import 'package:token_lens_app/stats/mini/mini_window.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';

class MiniGateway extends FakeStatsGateway implements StatsMiniGateway {
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
    hours: [780],
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
  Future<StatsMiniUsage> miniUsage(DateTime now, List<String> excluded) async =>
      data;
}

class MiniPlatform implements MiniWindowPlatform {
  final calls = <Object>[];
  ValueChanged<Size?>? onResize;
  Rect bounds = const Rect.fromLTWH(240, 96, 1050, 800);
  @override
  Future<Rect> getBounds() async => bounds;
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

void main() {
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
        hours: [0],
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

Widget panel(StatsController c, MiniWindow window) => MaterialApp(
  theme: const LensPalette(false).theme,
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
