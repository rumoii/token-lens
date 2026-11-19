import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/home_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/date_range.dart';
import 'package:token_lens_app/stats/widgets/filters.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';

import 'fake_gateway.dart';
import 'language_test.dart' as language;
import 's5_controls_test.dart' show shell;

void main() {
  testWidgets('R1 menu moves with Home, End and arrows, then returns focus', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      shell(
        englishStrings,
        FilterPick(
          label: 'Project',
          searchable: false,
          selected: 'a',
          options: const [
            FilterOption('a', 'Alpha'),
            FilterOption('b', 'Beta'),
            FilterOption('c', 'Gamma'),
          ],
          onPick: (value) => selected = value,
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final trigger = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNot(trigger));
    final selectedRow = find.ancestor(
      of: find.text('Alpha'),
      matching: find.byType(LensMenuRow),
    );
    final check = find.descendant(
      of: selectedRow,
      matching: find.byIcon(Icons.check),
    );
    expect(tester.widget<Icon>(check).color, const LensPalette(false)['clay']);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 'b');
    expect(FocusManager.instance.primaryFocus, trigger);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsNothing);
    expect(FocusManager.instance.primaryFocus, trigger);
  });

  testWidgets('R1 Escape clears the active session search', (tester) async {
    await language.mount(tester, 1180, 'en', height: 820);
    await language.navigate(tester, 'sessions');
    final input = find.byType(EditableText);
    await tester.enterText(input, 'sample');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(input).controller.text, isEmpty);
  });

  testWidgets('R1 greeting at the morning and noon boundaries', (tester) async {
    var now = DateTime(2026, 11, 9, 10, 59);
    final controller = StatsController(
      language.LanguageGateway(),
      preferences: UiPreferences.decode('{"language":"en","onboarded":true}'),
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.load();
    for (final (hour, minute, greeting) in [
      (10, 59, 'Good morning'),
      (11, 0, 'Good morning'),
      (11, 59, 'Good morning'),
      (12, 0, 'Good afternoon'),
      (12, 59, 'Good afternoon'),
      (13, 0, 'Good afternoon'),
    ]) {
      now = DateTime(demoNow.year, demoNow.month, demoNow.day, hour, minute);
      await tester.pumpWidget(
        AppLanguageScope(
          strings: englishStrings,
          child: MaterialApp(
            theme: const LensPalette(false).theme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: StatsHome(
                  controller: controller,
                  onDetail: (_) {},
                  onSessions: (_) {},
                  onSources: () {},
                  onSettings: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(greeting), findsOneWidget, reason: '$hour:$minute');
    }
  });

  test('R1 English comparison and sort sentence casing', () {
    expect(englishStrings.compareWith('Last month'), 'Compare with last month');
    expect(englishStrings.sortBy0('Time'), 'Sort by time');
    expect(englishStrings.sortBy0('First token'), 'Sort by first token');
    expect(chineseStrings.compareWith('上个月'), '对比上个月');
    expect(chineseStrings.sortBy0('时间'), '排序：时间');
  });

  for (final locale in ['en', 'zh']) {
    final strings = resolveStrings(locale, 'en');
    for (final (width, height) in [(1180.0, 820.0), (1024.0, 768.0)]) {
      testWidgets('R1 session columns fit at $width $locale', (tester) async {
        await language.mount(tester, width, locale, height: height);
        await language.navigate(tester, 'sessions', {'period': 'month'});
        expect(tester.takeException(), isNull);
        final cost = find.byKey(const Key('sessions-header-cost'));
        expect(cost, findsOneWidget);
        expect(tester.getTopRight(cost).dx, lessThanOrEqualTo(width));
        final text = find.descendant(of: cost, matching: find.byType(Text));
        expect(
          tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
          isFalse,
        );
        final table = find.ancestor(
          of: cost,
          matching: find.byWidgetPredicate(
            (w) =>
                w is SingleChildScrollView &&
                w.scrollDirection == Axis.horizontal,
          ),
        );
        for (final element in table.evaluate()) {
          final scrollable = find.descendant(
            of: find.byWidget(element.widget),
            matching: find.byType(Scrollable),
          );
          expect(
            tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
            0,
          );
        }
      });

      testWidgets('R1 page header controls at $width $locale', (tester) async {
        await language.mount(tester, width, locale, height: height);
        for (final page in ['home', 'detail']) {
          await language.navigate(tester, page);
          expect(tester.takeException(), isNull);
          final period = find.byType(PeriodControl);
          final view = find.byWidgetPredicate(
            (w) => w is LensSegmented && w.label == strings.view2,
          );
          expect(tester.getTopRight(period).dx, lessThanOrEqualTo(width));
          if (width == 1180) {
            expect(
              tester.getTopLeft(period).dy,
              closeTo(tester.getTopLeft(view).dy, 1),
            );
          }
        }
      });
    }

    testWidgets('R1 session search hint fits at 1180 $locale', (tester) async {
      await language.mount(tester, 1180, locale, height: 820);
      await language.navigate(tester, 'sessions');
      final hint = find.text(strings.sessionSearch);
      expect(hint, findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(hint).didExceedMaxLines,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final dark in [false, true]) {
    testWidgets('R1 button sizes and interaction colors dark=$dark', (
      tester,
    ) async {
      final palette = LensPalette(dark);
      final semantics = tester.ensureSemantics();
      var pressed = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: palette.theme,
          home: Scaffold(
            body: Column(
              children: [
                for (final size in ['xs', 'sm', 'md', 'lg', 'settings'])
                  LensButton(
                    label: size,
                    variant: 'ghost',
                    size: size,
                    onPressed: () => pressed++,
                  ),
                const LensButton(label: 'disabled'),
              ],
            ),
          ),
        ),
      );
      final ghost = find.widgetWithText(TextButton, 'xs');
      final style = tester.widget<TextButton>(ghost).style!;
      expect(style.backgroundColor!.resolve({}), LensPalette.transparent);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 400));
      await mouse.moveTo(tester.getCenter(ghost));
      await tester.pumpAndSettle();
      expect(
        style.backgroundColor!.resolve({WidgetState.hovered}),
        palette['fill-hover'],
      );
      await mouse.down(tester.getCenter(ghost));
      await tester.pumpAndSettle();
      expect(
        style.backgroundColor!.resolve({WidgetState.pressed}),
        palette['fill-active'],
      );
      expect(
        tester
            .widgetList<AnimatedScale>(find.byType(AnimatedScale))
            .first
            .scale,
        .98,
      );
      await mouse.up();
      expect(pressed, 1);
      for (final (size, height, radius) in [
        ('xs', 24.0, 6.0),
        ('sm', 28.0, 8.0),
        ('md', 32.0, 8.0),
        ('lg', 40.0, 10.0),
        ('settings', 32.0, 8.0),
      ]) {
        final button = find.widgetWithText(TextButton, size);
        expect(tester.getSize(button).height, height);
        final shape = tester
            .widget<TextButton>(button)
            .style!
            .shape!
            .resolve({})!;
        expect(
          (shape as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(radius),
        );
      }
      final ring = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.foregroundPainter is LensFocusRing,
      );
      expect(ring, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(ring, findsOneWidget);
      final painter =
          tester.widget<CustomPaint>(ring).foregroundPainter! as LensFocusRing;
      expect(painter.strokeWidth, 1.5);
      expect(painter.color, palette['clay']);
      await tester.tap(find.text('disabled'), warnIfMissed: false);
      expect(pressed, 1);
      expect(
        tester.getSemantics(find.bySemanticsLabel('disabled')),
        matchesSemantics(
          label: 'disabled',
          isButton: true,
          hasEnabledState: true,
        ),
      );
      await mouse.removePointer();
      semantics.dispose();
    });
  }
}
