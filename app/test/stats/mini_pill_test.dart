import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/mini/mini_panel.dart';
import 'package:token_lens_app/stats/mini/mini_window.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';
import 'mini_window_test.dart' show MiniGateway, MiniPlatform;

void main() {
  test('compact window copy matches in both languages', () {
    expect(
      [
        chineseStrings.miniWindow,
        chineseStrings.miniHintOpen,
        chineseStrings.miniSettings,
        chineseStrings.miniHintDescription,
      ],
      ['小窗', '打开小窗', '小窗设置', '小窗可以置顶在屏幕一角，随时看今天的用量和正在用的模型。'],
    );
    expect(
      [
        englishStrings.miniWindow,
        englishStrings.miniHintOpen,
        englishStrings.miniSettings,
        englishStrings.miniHintDescription,
      ],
      [
        'Compact window',
        'Open compact window',
        'Compact window settings',
        "The compact window stays on top in a corner, showing today's usage and the models in use.",
      ],
    );
  });

  test(
    'mini preferences round-trip pill mode, visible anchor and edge',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mini-pill-prefs-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = PreferencesStore(directory);
      const anchor = [1700, 24, 148, 36];
      final saved = MiniPreferences.decode({
        'bounds': [1440, 24, 400, 640],
        'pill': true,
        'pillBounds': anchor,
        'pillEdge': 'right',
      });
      expect(saved.encode(), containsPair('pill', true));
      expect(saved.encode(), containsPair('pillBounds', anchor));
      expect(saved.encode(), containsPair('pillEdge', 'right'));
      await store.write(UiPreferences(mini: saved));
      expect((await store.read()).mini.encode(), saved.encode());
      final old = MiniPreferences.decode({'seconds': 5});
      expect((old.pill, old.pillBounds, old.pillEdge), (false, null, null));
      expect(MiniPreferences.decode({'pillEdge': 'top'}).pillEdge, isNull);
    },
  );

  for (final (strings, currency, unitSystem, tokens, estimate, enter, label)
      in [
        (
          chineseStrings,
          'CNY',
          'chinese',
          '62万',
          '约 ¥7.12',
          '缩成迷你模式',
          '今天 62万 token，约 ¥7.12。点击展开小窗',
        ),
        (
          englishStrings,
          'USD',
          'english',
          '620K',
          'Est. \$0.99',
          'Shrink to mini mode',
          'Today 620K tokens, about \$0.99. Click to open the compact window',
        ),
      ]) {
    testWidgets(
      'compact header opens the pill with $currency usage and keyboard activation',
      (tester) async {
        final gateway = MiniGateway();
        final usage = gateway.data;
        gateway.data = StatsMiniUsage(
          totals: const StatsTotals(
            grossTokens: 620000,
            costMicros: 990000,
            unpricedRecords: 0,
            recordCount: 1,
          ),
          activeModels: usage.activeModels,
          minutes: usage.minutes,
          projects: usage.projects,
          requests: usage.requests,
        );
        final c = StatsController(
          gateway,
          clock: () => demoNow,
          preferences: UiPreferences(
            onboarded: true,
            currency: currency,
            rates: const {'CNY': 7.192},
          ).copyWith(unitSystem: unitSystem),
        );
        final platform = _PillPlatform(false);
        final window = MiniWindow(controller: c, platform: platform);
        addTearDown(c.dispose);
        addTearDown(window.dispose);
        await window.enter();
        await tester.pumpWidget(
          AppLanguageScope(
            strings: strings,
            child: MaterialApp(
              theme: const LensPalette(false).theme,
              home: StatsPage(controller: c, miniWindow: window),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final shrink = find.byTooltip(enter);
        expect(shrink, findsOneWidget);
        expect(
          tester.getCenter(shrink).dx,
          lessThan(tester.getCenter(find.byTooltip(strings.miniUnpin)).dx),
        );
        await tester.tap(shrink);
        await tester.pumpAndSettle();
        expect(find.byType(MiniPanel), findsNothing);
        expect(find.text(tokens), findsOneWidget);
        expect(find.text(strings.tokenUnit), findsOneWidget);
        expect(find.text(estimate), findsOneWidget);
        expect(platform.tooltip, strings.miniPillTooltip);
        final semantics = tester.ensureSemantics();
        try {
          await tester.pump();
          expect(find.bySemanticsLabel(label), findsOneWidget);
        } finally {
          semantics.dispose();
        }
        expect(platform.bounds.height, 36);
        expect(platform.bounds.width, inInclusiveRange(80, 240));
        await tester.sendKeyEvent(
          currency == 'CNY'
              ? LogicalKeyboardKey.enter
              : LogicalKeyboardKey.space,
        );
        await tester.pumpAndSettle();
        expect(find.byType(MiniPanel), findsOneWidget);
        expect(c.miniMode, isTrue);
        await tester.tap(shrink);
        await tester.pumpAndSettle();
        final pill = find.byType(MiniPill);
        final click = await tester.startGesture(tester.getCenter(pill));
        await click.moveBy(const Offset(3, 0));
        await click.up();
        await tester.pumpAndSettle();
        expect(find.byType(MiniPanel), findsOneWidget);
        await tester.tap(shrink);
        await tester.pumpAndSettle();
        platform.dragTo = const Rect.fromLTWH(150, 120, 150, 36);
        final drag = await tester.startGesture(tester.getCenter(pill));
        await drag.moveBy(const Offset(5, 0));
        await drag.up();
        await tester.pumpAndSettle();
        expect(pill, findsOneWidget);
        expect(platform.bounds.topLeft, const Offset(150, 120));
        await tester.pumpWidget(const SizedBox());
        await c.shutdown();
      },
    );
  }

  testWidgets('pill aligns to the compact right edge and expands inwards', (
    tester,
  ) async {
    final (c, platform, window) = await _window(
      compact: const Rect.fromLTWH(640, 150, 330, 650),
    );
    await window.enterPill(148);
    expect(platform.bounds, const Rect.fromLTWH(822, 150, 148, 36));
    expect(platform.calls.last, ('pin', true));
    await window.expandPill();
    expect(platform.bounds, const Rect.fromLTWH(640, 150, 330, 650));
    expect(platform.calls.last, ('pin', false));

    await window.enterPill(148);
    platform.dragTo = const Rect.fromLTWH(56, 780, 148, 36);
    await window.startPillDragging();
    await window.expandPill();
    expect(platform.bounds, const Rect.fromLTWH(56, 150, 330, 650));
    expect(platform.calls.last, ('pin', false));
    await c.shutdown();
  });

  testWidgets('pill enter clamps the content width and top to the work area', (
    tester,
  ) async {
    final (c, platform, window) = await _window();
    platform.bounds = const Rect.fromLTWH(-100, -40, 300, 600);
    await window.enterPill(300);
    expect(platform.bounds, const Rect.fromLTWH(0, 0, 240, 36));
    await c.shutdown();
  });

  for (final scale in [1.0, 1.5]) {
    testWidgets(
      'horizontal 24 DIP threshold on the center display at ${scale}x',
      (tester) async {
        final (c, platform, window) = await _window();
        await window.enterPill(150);
        const left = 1000.0, right = 2200.0;
        platform.displays[0] = const MiniDisplay(
          Rect.fromLTWH(0, 0, 1000, 128),
        );
        platform.displays.add(
          MiniDisplay(const Rect.fromLTRB(left, 0, right, 900), scale),
        );
        platform.scale = scale;
        for (final distance in [23, 25]) {
          for (final side in ['left', 'right']) {
            final x = side == 'left'
                ? left + distance * scale
                : right - (150 + distance) * scale;
            platform.dragTo = Rect.fromLTWH(x, 160, 150, 36);
            await window.startPillDragging();
            expect(
              c.preferences.mini.encode()['pillEdge'],
              distance == 23 ? side : null,
            );
            expect(
              platform.bounds.left,
              distance == 25
                  ? x
                  : side == 'left'
                  ? left - (150 - 26) * scale
                  : right - 26 * scale,
            );
          }
        }
        for (final y in [0.0, 900 - 36 * scale]) {
          platform.dragTo = Rect.fromLTWH(1400, y, 150, 36);
          await window.startPillDragging();
          expect(c.preferences.mini.encode()['pillEdge'], isNull);
          expect(platform.bounds.top, y);
        }
        // The leading x crosses the primary's range, but the center is on screen two.
        platform.dragTo = const Rect.fromLTWH(985, 160, 150, 36);
        await window.startPillDragging();
        expect(c.preferences.mini.encode()['pillEdge'], 'left');
        expect(platform.bounds.left, left - (150 - 26) * scale);
        await c.shutdown();
      },
    );
  }

  for (final edge in MiniPillEdge.values) {
    final left = edge == MiniPillEdge.left;
    final neighborX = left ? -1000.0 : 1000.0;
    final alignedX = left ? 0.0 : 850.0;
    final tuckedX = left ? -124.0 : 974.0;
    for (final adjacent in [true, false]) {
      testWidgets(
        '${edge.name} snap with neighbor at pill height = $adjacent',
        (tester) async {
          final (c, platform, window) = await _window(
            extraDisplays: [
              MiniDisplay(
                Rect.fromLTWH(neighborX, adjacent ? 180 : 196, 1000, 500),
              ),
            ],
          );
          await window.enterPill(150);
          platform.dragTo = Rect.fromLTWH(left ? 23 : 827, 160, 150, 36);
          await window.startPillDragging();
          expect(platform.bounds.left, adjacent ? alignedX : tuckedX);
          expect(window.pillState.value?.edge, adjacent ? null : edge);
          expect(c.preferences.mini.pillEdge, adjacent ? null : edge);
          if (adjacent) {
            window.setPillHovered(true, reduceMotion: true);
            expect(platform.bounds.left, alignedX);
          }
          await c.shutdown();
        },
      );
    }

    testWidgets(
      'restored ${edge.name} tuck stays visible beside a new screen',
      (tester) async {
        final (c, platform, window) = await _window(
          saved: MiniPreferences(
            pill: true,
            pillBounds: Rect.fromLTWH(alignedX, 160, 150, 36),
            pillEdge: edge,
          ),
          extraDisplays: [MiniDisplay(Rect.fromLTWH(neighborX, 0, 1000, 800))],
        );
        expect(platform.bounds, Rect.fromLTWH(alignedX, 160, 150, 36));
        expect(window.pillState.value?.edge, isNull);
        expect(c.preferences.mini.pillEdge, isNull);
        await c.shutdown();
      },
    );
  }

  for (final reduce in [false, true]) {
    testWidgets('tucked hover timing with reduced motion = $reduce', (
      tester,
    ) async {
      final (c, platform, window) = await _window();
      await window.enterPill(150);
      platform.dragTo = const Rect.fromLTWH(829, 160, 150, 36);
      await window.startPillDragging();
      expect(platform.bounds.left, 974);
      window.setPillHovered(true, reduceMotion: reduce);
      await tester.pump();
      expect(platform.bounds.left, reduce ? 850 : 974);
      if (!reduce) {
        await tester.pump(const Duration(milliseconds: 80));
        expect(platform.bounds.left, inExclusiveRange(850, 974));
        await tester.pump(LensTokens.normal);
      }
      expect(platform.bounds.left, 850);
      window.setPillHovered(false, reduceMotion: reduce);
      await tester.pump(const Duration(milliseconds: 399));
      expect(platform.bounds.left, 850);
      await tester.pump(const Duration(milliseconds: 1));
      if (!reduce) await tester.pump(LensTokens.normal);
      expect(platform.bounds.left, 974);
      await window.expandPill();
      expect(platform.bounds.right, 1000);
      await c.shutdown();
    });
  }

  testWidgets('macOS stays on screen and never tucks', (tester) async {
    final (c, platform, window) = await _window(tuck: false);
    await window.enterPill(150);
    platform.dragTo = const Rect.fromLTWH(-25, -20, 150, 36);
    await window.startPillDragging();
    expect(platform.bounds, const Rect.fromLTWH(0, 0, 150, 36));
    expect(c.preferences.mini.encode()['pillEdge'], isNull);
    await c.shutdown();
  });

  testWidgets(
    'restart with a missing display returns to the primary work area',
    (tester) async {
      final saved = MiniPreferences.decode({
        'bounds': [640, 24, 330, 650],
        'pill': true,
        'pillBounds': [3000, 140, 150, 36],
        'pillEdge': 'left',
      });
      final (c, platform, window) = await _window(saved: saved);
      expect(platform.bounds, const Rect.fromLTWH(834, 16, 150, 36));
      expect(c.preferences.mini.encode()['pillEdge'], isNull);
      await window.expandPill();
      expect(platform.bounds, const Rect.fromLTWH(654, 16, 330, 650));
      await c.shutdown();
    },
  );
}

Future<(StatsController, _PillPlatform, MiniWindow)> _window({
  Rect compact = const Rect.fromLTWH(500, 40, 330, 650),
  bool tuck = true,
  MiniPreferences? saved,
  List<MiniDisplay> extraDisplays = const [],
}) async {
  final c = StatsController(
    MiniGateway(),
    clock: () => demoNow,
    preferences: UiPreferences(
      mini: saved ?? MiniPreferences(bounds: compact, pinned: false),
    ),
  );
  final platform = _PillPlatform(tuck)..displays.addAll(extraDisplays);
  final window = MiniWindow(controller: c, platform: platform);
  addTearDown(c.dispose);
  addTearDown(window.dispose);
  if (saved == null) {
    await window.enter();
  } else {
    await window.restorePill();
  }
  return (c, platform, window);
}

class _PillPlatform extends MiniPlatform {
  _PillPlatform(this.supportsPillTuck);

  @override
  final bool supportsPillTuck;
  double scale = 1;
  Rect? dragTo;
  String? tooltip;
  final displays = [const MiniDisplay(Rect.fromLTWH(0, 0, 1000, 800))];

  @override
  Future<List<MiniDisplay>> workAreas() async => displays;

  @override
  Future<MiniFrame> getFrame() async => (bounds: bounds, scale: scale);

  @override
  Future<void> setPillTooltip(String? text) async => tooltip = text;

  @override
  Future<void> dragPill({Color? edgeAccent}) async {
    bounds = dragTo!;
  }
}
