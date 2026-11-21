import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/date_range.dart';
import 'package:token_lens_app/stats/widgets/filters.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

import 'language_test.dart' as language;

Finder rings(Finder parent) => find.descendant(
  of: parent,
  matching: find.byWidgetPredicate(
    (w) => w is CustomPaint && w.foregroundPainter is LensFocusRing,
  ),
);

Widget surface(LensPalette palette, Widget child) => MaterialApp(
  theme: palette.theme,
  builder: (_, child) =>
      AppLanguageScope(strings: englishStrings, child: child!),
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

void main() {
  for (final dark in [false, true]) {
    final palette = LensPalette(dark);

    testWidgets('R1 switch and checkbox state and semantics dark=$dark', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        bool switched = false, checked = false;
        const switchKey = Key('r1-switch');
        const checkKey = Key('r1-check');
        await tester.pumpWidget(
          surface(
            palette,
            StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  LensSwitch(
                    key: switchKey,
                    label: 'Switch',
                    value: switched,
                    onChanged: (value) => setState(() => switched = value),
                  ),
                  LensCheckbox(
                    key: checkKey,
                    label: 'Check',
                    value: checked,
                    onChanged: (value) => setState(() => checked = value),
                  ),
                  const LensSwitch(
                    label: 'Disabled switch',
                    value: true,
                    onChanged: null,
                  ),
                  const LensCheckbox(
                    label: 'Disabled checkbox',
                    value: false,
                    onChanged: null,
                  ),
                ],
              ),
            ),
          ),
        );
        final toggle = find.byKey(switchKey);
        final check = find.byKey(checkKey);
        expect(tester.getSize(toggle), const Size(44, 24));
        expect(tester.getSize(check), const Size(16, 16));
        final toggleTrack = find.descendant(
          of: toggle,
          matching: find.byWidgetPredicate(
            (w) => w is AnimatedContainer && w.constraints?.maxWidth == 44,
          ),
        );
        BoxDecoration toggleDecoration() =>
            tester.widget<AnimatedContainer>(toggleTrack).decoration!
                as BoxDecoration;
        expect(toggleDecoration().color, palette['line-strong']);
        final checkBox = find.descendant(
          of: check,
          matching: find.byWidgetPredicate(
            (w) => w is AnimatedContainer && w.constraints?.maxWidth == 16,
          ),
        );
        BoxDecoration checkDecoration() =>
            tester.widget<AnimatedContainer>(checkBox).decoration!
                as BoxDecoration;
        expect(
          checkDecoration().border,
          Border.all(color: palette['line-heavy'], width: 1.5),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(rings(toggle), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(switched, isTrue);
        expect(toggleDecoration().color, palette['clay']);
        expect(
          tester.widget<AnimatedContainer>(toggleTrack).duration,
          const Duration(milliseconds: 200),
        );
        await tester.tap(check, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(checked, isTrue);
        expect(rings(check), findsNothing);
        expect(checkDecoration().color, palette['clay']);
        expect(
          find.descendant(of: check, matching: find.byIcon(Icons.check)),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Switch')),
          matchesSemantics(
            label: 'Switch',
            hasToggledState: true,
            isToggled: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Disabled checkbox')),
          matchesSemantics(
            label: 'Disabled checkbox',
            hasCheckedState: true,
            hasEnabledState: true,
          ),
        );
        await tester.tap(
          find.bySemanticsLabel('Disabled switch'),
          warnIfMissed: false,
        );
        expect(switched, isTrue);
      } finally {
        handle.dispose();
      }
    });

    testWidgets(
      'R1 shared input clear, keyboard focus layers and error dark=$dark',
      (tester) async {
        final controller = TextEditingController(text: 'sample');
        addTearDown(controller.dispose);
        const key = Key('r1-field');
        var last = 'sample';
        await tester.pumpWidget(
          surface(
            palette,
            SizedBox(
              width: 280,
              child: LensInput(
                key: key,
                search: true,
                size: 'sm',
                error: true,
                controller: controller,
                onChanged: (value) => last = value,
              ),
            ),
          ),
        );
        final input = find.byKey(key);
        expect(tester.getSize(input).height, 28);
        expect(
          tester
              .widget<TextField>(find.byType(TextField))
              .decoration!
              .fillColor,
          palette['fill-hover'],
        );
        await tester.tap(input, kind: PointerDeviceKind.mouse);
        await tester.pump();
        expect(rings(input), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        final ring =
            tester.widget<CustomPaint>(rings(input)).foregroundPainter!
                as LensFocusRing;
        expect(ring.isolationWidth, 1);
        expect(ring.strokeWidth, 1.5);
        expect(ring.haloWidth, 6);
        expect(ring.color, palette['danger']);
        expect(ring.isolation, palette['surface-1']);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(controller.text, isEmpty);
        expect(last, isEmpty);
        await tester.enterText(input, 'again');
        await tester.pumpAndSettle();
        final clear = find.byTooltip(englishStrings.clearSearch);
        expect(clear, findsOneWidget);
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(last, isEmpty);
        expect(clear, findsNothing);
      },
    );

    testWidgets('R1 chip, badge and disclosure use shared tones dark=$dark', (
      tester,
    ) async {
      const chip = Key('r1-chip'), badge = Key('r1-badge'), row = Key('r1-row');
      var selected = false, expanded = false;
      await tester.pumpWidget(
        surface(
          palette,
          StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                LensChip(
                  key: chip,
                  label: 'Category',
                  count: 3,
                  selected: selected,
                  onPressed: () => setState(() => selected = !selected),
                ),
                const LensBadge('Badge', key: badge, tone: 'warn'),
                LensDisclosure(
                  key: row,
                  expanded: expanded,
                  onPressed: () => setState(() => expanded = !expanded),
                  child: const Text('Details'),
                ),
              ],
            ),
          ),
        ),
      );
      final decoration =
          tester
                  .widget<Container>(
                    find.descendant(
                      of: find.byKey(badge),
                      matching: find.byType(Container),
                    ),
                  )
                  .decoration!
              as BoxDecoration;
      expect(decoration.color, palette.warnWash);
      expect(decoration.borderRadius, BorderRadius.circular(4));
      expect(tester.getSize(find.byKey(badge)).height, 20);
      AnimatedContainer background(Finder finder) =>
          tester.widget<AnimatedContainer>(
            find
                .descendant(
                  of: finder,
                  matching: find.byType(AnimatedContainer),
                )
                .first,
          );
      final category = find.byKey(chip);
      expect(
        (background(category).decoration as BoxDecoration).color,
        palette['fill-hover'],
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final disclosure = find.byKey(row);
      await mouse.addPointer(location: const Offset(350, 350));
      await mouse.moveTo(tester.getCenter(disclosure));
      await tester.pumpAndSettle();
      expect(
        (background(disclosure).decoration as BoxDecoration).color,
        palette['fill-hover'],
      );
      await mouse.down(tester.getCenter(disclosure));
      await tester.pumpAndSettle();
      expect(
        (background(disclosure).decoration as BoxDecoration).color,
        palette['fill-active'],
      );
      await mouse.up();
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
        .25,
      );
      await tester.tap(category);
      await tester.pumpAndSettle();
      expect(
        (background(category).decoration as BoxDecoration).color,
        palette['clay-wash'],
      );
    });

    testWidgets('R1 icon sizes, tonal state and link arrow dark=$dark', (
      tester,
    ) async {
      var activations = 0;
      await tester.pumpWidget(
        surface(
          palette,
          Column(
            children: [
              for (final size in ['xs', 'sm', 'md'])
                LensIconButton(
                  key: ValueKey(size),
                  icon: Icons.copy,
                  tooltip: size,
                  size: size,
                  tonal: size == 'sm',
                  onPressed: size == 'md' ? null : () => activations++,
                ),
              LensTextLink(
                label: 'Next',
                onTap: () => activations++,
                arrow: true,
              ),
            ],
          ),
        ),
      );
      final tonal = find.byKey(const ValueKey('sm'));
      final arrow = find.byIcon(Icons.arrow_forward);
      for (final (size, pixels) in [('xs', 24.0), ('sm', 28.0), ('md', 32.0)]) {
        expect(tester.getSize(find.byKey(ValueKey(size))), Size.square(pixels));
      }
      Color? fill() =>
          (tester
                      .widget<AnimatedContainer>(
                        find.descendant(
                          of: tonal,
                          matching: find.byType(AnimatedContainer),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color;
      expect(fill(), palette['fill-hover']);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 400));
      await mouse.moveTo(tester.getCenter(tonal));
      await tester.pumpAndSettle();
      expect(fill(), palette['fill-active']);
      final before = tester.getTopLeft(arrow).dx;
      await mouse.moveTo(tester.getCenter(find.text('Next')));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(arrow).dx - before, closeTo(2, .01));
      await mouse.removePointer();
      await tester.tap(find.byKey(const ValueKey('md')), warnIfMissed: false);
      expect(activations, 0);
    });
  }

  testWidgets(
    'R1 selected filters are inline, clear without opening and preserve query',
    (tester) async {
      await language.mount(tester, 1180, 'en', height: 820);
      for (final page in ['sessions', 'detail']) {
        await language.navigate(tester, page, {
          'period': 'month',
          'tool': 'codex',
          'model': 'm',
        });
        final filter = find.byWidgetPredicate(
          (w) => w is LensFilterTrigger && w.value == 'm',
        );
        expect(filter, findsOneWidget);
        expect(find.byType(FilterTag), findsNothing);
        final clear = find.descendant(
          of: filter,
          matching: find.byTooltip(
            englishStrings.remove0Filter(englishStrings.model),
          ),
        );
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(find.byType(LensMenu), findsNothing);
        expect(filter, findsNothing);
        final trigger = find.byWidgetPredicate(
          (w) => w is LensFilterTrigger && w.tool == 'codex',
        );
        expect(trigger, findsOneWidget);
        final dynamic shell = tester.state(find.byType(StatsPage));
        final query = Uri.splitQueryString(shell.query as String);
        expect(query['tool'], 'codex');
        expect(query['period'], 'month');
        expect(query['model'], isNull);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'R1 sidebar slides between appearances and long press follows system',
    (tester) async {
      final stats = await language.mount(tester, 1180, 'en', height: 820);
      final thumb = find.byKey(const Key('theme-thumb'));
      final sun = find.byIcon(Icons.light_mode_outlined);
      final moon = find.byIcon(Icons.dark_mode_outlined);
      double opacity() => tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(of: thumb, matching: find.byType(AnimatedOpacity))
                .first,
          )
          .opacity;
      expect(opacity(), 1);
      await tester.tap(sun);
      await tester.pumpAndSettle();
      expect(stats.preferences.appearance, 'light');
      expect(opacity(), 1);
      expect(tester.getCenter(thumb), tester.getCenter(sun));
      await tester.tap(moon);
      await tester.pumpAndSettle();
      expect(stats.preferences.appearance, 'dark');
      expect(tester.getCenter(thumb), tester.getCenter(moon));
      await tester.longPress(moon);
      await tester.pumpAndSettle();
      expect(stats.preferences.appearance, 'system');
      expect(opacity(), 0);
    },
  );

  testWidgets(
    'R1 capture entry points still open from their original finders',
    (tester) async {
      await language.mount(tester, 1180, 'zh', height: 820);
      final strings = chineseStrings;
      Finder period(Finder target) =>
          find.descendant(of: find.byType(PeriodControl), matching: target);
      await tester.tap(period(find.text(strings.morePeriods)));
      await tester.pumpAndSettle();
      expect(find.byType(LensMenu), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(period(find.byIcon(Icons.calendar_month_outlined)));
      await tester.pumpAndSettle();
      expect(find.byType(CustomRangePopover), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await language.navigate(tester, 'detail', {'period': 'month'});
      final project = find
          .ancestor(
            of: find.text(strings.project),
            matching: find.byType(TextButton),
          )
          .first;
      await tester.tap(project);
      await tester.pumpAndSettle();
      expect(find.byType(LensMenu), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail-compare')), findsOneWidget);
      await language.navigate(tester, 'sessions');
      await tester.tap(find.byKey(const Key('sessions-sort')));
      await tester.pumpAndSettle();
      expect(find.byType(LensMenu), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
