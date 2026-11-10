import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';

import 'fake_gateway.dart';

Future<void> mount(
  WidgetTester tester,
  Widget child, {
  bool dark = false,
  bool reduced = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: LensPalette(dark).theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: Scaffold(body: Center(child: child)),
  ),
);

Finder transforms(Finder owner) =>
    find.descendant(of: owner, matching: find.byType(Transform));
double scale(WidgetTester tester, Finder owner) =>
    transforms(owner).evaluate().isEmpty
    ? 1
    : tester.widget<Transform>(transforms(owner).first).transform.entry(0, 0);
BoxDecoration decoration(WidgetTester tester, Finder owner, Color color) =>
    tester
        .widgetList<DecoratedBox>(
          find.descendant(of: owner, matching: find.byType(DecoratedBox)),
        )
        .map((w) => w.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((d) => d.color == color);

void main() {
  testWidgets(
    'press cancellation, disabling during build, and keyboard activation',
    (tester) async {
      var enabled = true;
      var calls = 0;
      late StateSetter update;
      await mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return LensButton(
              label: 'Action',
              onPressed: enabled ? () => calls++ : null,
            );
          },
        ),
      );
      final owner = find.byType(LensButton);
      final gesture = await tester.startGesture(tester.getCenter(owner));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(scale(tester, owner), .98);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(scale(tester, owner), 1);
      expect(calls, 0);
      update(() => enabled = false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Action'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(scale(tester, owner), 1);
      update(() => enabled = true);
      await tester.pumpAndSettle();
      Focus.of(tester.element(find.text('Action'))).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(scale(tester, owner), lessThan(1));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(scale(tester, owner), 1);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
  test('Windows variable family and original macOS fallbacks', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(LensPalette.bodyFonts, [
      'Segoe UI Variable Text',
      'Segoe UI',
      'Microsoft YaHei',
      'Geist',
      'Arial',
      'PingFang SC',
    ]);
    expect(
      const LensPalette(false).text().fontFamily,
      'Segoe UI Variable Text',
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(LensPalette.bodyFonts, [
      '.AppleSystemUIFont',
      'SF Pro Text',
      'PingFang SC',
      'Arial',
    ]);
  });
  for (final dark in [false, true]) {
    test('explicit weight axis $dark; serif stays unchanged', () {
      final p = LensPalette(dark);
      final weights = dark
          ? [400.0, 465.0, 560.0, 660.0]
          : [400.0, 500.0, 580.0, 660.0];
      for (var i = 0; i < 4; i++) {
        final style = p.text(14, null, FontWeight.values[i + 3]);
        expect(style.fontVariations, [FontVariation('wght', weights[i])]);
        expect(style.fontWeight, FontWeight.values[i + 3]);
      }
      final serif = p.serif(30);
      expect(serif.fontVariations ?? [], isEmpty);
      expect(serif.fontFamily, LensPalette.serifFonts.first);
      expect(serif.fontWeight, FontWeight.w600);
      expect(serif.fontSize, 30);
    });
    for (final reduced in [false, true]) {
      testWidgets('segmented CDS colors and spring $dark $reduced', (
        tester,
      ) async {
        var selected = 'a';
        await mount(
          tester,
          StatefulBuilder(
            builder: (context, setState) => LensSegmented(
              options: const {'a': 'Alpha', 'b': 'Beta'},
              value: selected,
              onChanged: (v) => setState(() => selected = v),
              label: 'Segments',
            ),
          ),
          dark: dark,
          reduced: reduced,
        );
        final owner = find.byType(LensSegmented);
        final track = (dark ? Colors.white : Colors.black).withValues(
          alpha: dark ? .08 : .06,
        );
        final thumb = dark ? const Color(0xff2c2c2a) : Colors.white;
        expect(
          decoration(tester, owner, track).borderRadius,
          BorderRadius.circular(999),
        );
        final thumbDecoration = decoration(tester, owner, thumb);
        expect(
          thumbDecoration.border!.top.color,
          (dark ? Colors.white : Colors.black).withValues(alpha: .06),
        );
        expect(thumbDecoration.boxShadow, [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .4 : .08),
            offset: const Offset(0, 1),
            blurRadius: 3,
          ),
        ]);
        expect(
          tester.widget<Text>(find.text('Alpha')).style!.fontWeight,
          FontWeight.w600,
        );
        final slider = transforms(owner).first;
        final width = tester
            .getSize(
              find.ancestor(
                of: find.text('Beta'),
                matching: find.byType(InkWell),
              ),
            )
            .width;
        await tester.tap(find.text('Beta'));
        await tester.pump();
        double x() => tester.widget<Transform>(slider).transform.entry(0, 3);
        expect(x(), reduced ? closeTo(width, .001) : closeTo(0, .001));
        if (!reduced) {
          await tester.pump(const Duration(milliseconds: 50));
          final expected =
              SpringSimulation(
                const SpringDescription(mass: 1, stiffness: 500, damping: 35),
                0,
                1,
                0,
              ).x(.05) *
              width;
          expect(x(), closeTo(expected, .01));
          await tester.pumpAndSettle();
          expect(x(), closeTo(width, .1));
        }
      });
      for (final variant in [
        'primary',
        'secondary',
        'ghost',
        'outline',
        'danger',
      ]) {
        testWidgets('press $variant reduced=$reduced dark=$dark', (
          tester,
        ) async {
          var calls = 0;
          await mount(
            tester,
            LensButton(
              label: 'Press',
              variant: variant,
              onPressed: () => calls++,
            ),
            dark: dark,
            reduced: reduced,
          );
          final owner = find.byType(LensButton);
          final size = tester.getSize(owner);
          final gesture = await tester.startGesture(
            tester.getCenter(find.text('Press')),
          );
          await tester.pump(const Duration(milliseconds: 150));
          await tester.pump(const Duration(milliseconds: 100));
          expect(scale(tester, owner), closeTo(reduced ? 1 : .98, .0001));
          expect(tester.getSize(owner), size);
          await gesture.up();
          await tester.pumpAndSettle();
          expect(scale(tester, owner), 1);
          expect(calls, 1);
        });
      }
      testWidgets('card hover lift shadow and stable layout $dark $reduced', (
        tester,
      ) async {
        await mount(
          tester,
          const LensCard(child: SizedBox(width: 200, height: 100)),
          dark: dark,
          reduced: reduced,
        );
        final owner = find.byType(LensCard);
        final before = tester.getSize(owner);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(owner));
        await tester.pumpAndSettle();
        final offset = transforms(owner).evaluate().isEmpty
            ? 0.0
            : tester
                  .widget<Transform>(transforms(owner).first)
                  .transform
                  .entry(1, 3);
        expect(offset, reduced ? 0 : -1.5);
        expect(tester.getSize(owner), before);
        expect(
          decoration(tester, owner, LensPalette(dark).surface).boxShadow!.last,
          LensPalette(dark).shadow('hover').last,
        );
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Transform>(transforms(owner).first)
              .transform
              .entry(1, 3),
          0,
        );
      });
    }
  }
  for (final dpr in [1.0, 2.0, 3.0]) {
    testWidgets('card outer ring hairline DPR $dpr', (tester) async {
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(
        tester,
        const LensCard(child: SizedBox(width: 100, height: 80)),
      );
      expect(
        LensPalette.hairline(tester.element(find.byType(LensCard))),
        1 / dpr,
      );
      final ring = decoration(
        tester,
        find.byType(LensCard),
        const LensPalette(false).surface,
      ).boxShadow!.first;
      expect(ring.spreadRadius, closeTo(1 / dpr, .0001));
    });
  }
  for (final reduced in [false, true]) {
    testWidgets('sidebar press and reduced motion $reduced', (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = StatsController(
        FakeStatsGateway(),
        clock: () => demoNow,
      );
      addTearDown(controller.dispose);
      await controller.load();
      await mount(tester, StatsPage(controller: controller), reduced: reduced);
      await tester.pumpAndSettle();
      final menu = find
          .ancestor(of: find.text('用量明细'), matching: find.byType(InkWell))
          .first;
      final gesture = await tester.startGesture(tester.getCenter(menu));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 100));
      // The scale surrounds the InkWell so its hit area and semantics are kept.
      final ancestors = tester.widgetList<Transform>(
        find.ancestor(of: menu, matching: find.byType(Transform)),
      );
      expect(
        ancestors.map((w) => w.transform.entry(0, 0)),
        contains(closeTo(reduced ? 1 : .98, .0001)),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('用量明细'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
