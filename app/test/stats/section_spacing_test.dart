import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/detail_page.dart';
import 'package:token_lens_app/stats/home_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';

import 'fake_gateway.dart';

Future<void> mount(
  WidgetTester tester,
  String page,
  double width, {
  String state = 'ready',
}) async {
  tester.view.physicalSize = Size(width, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fake = FakeStatsGateway()
    ..empty = state == 'empty'
    ..failure = state == 'error' ? 'spacing fixture' : null
    ..readBarrier = state == 'loading' ? Completer<void>() : null;
  final c = StatsController(
    fake,
    clock: () => demoNow,
    preferences: const UiPreferences(
      onboarded: true,
      period: StatsPeriod('month'),
    ),
  );
  final pending = c.load();
  addTearDown(c.dispose);
  if (state != 'loading') await pending;
  if (state == 'banners') {
    c.syncError = 'sync spacing fixture';
    c.warning = 'warning spacing fixture';
    c.resourceErrors['year'] = 'year spacing fixture';
    c.resourceErrors['recent'] = 'recent spacing fixture';
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: const LensPalette(false).theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: StatsPage(controller: c),
    ),
  );
  if (page == 'detail') {
    (tester.state(find.byType(StatsPage)) as dynamic).navigate('detail', {
      'period': 'month',
    });
  }
  await tester.pumpAndSettle();
}

Finder cardWith(Finder page, String label) => find
    .ancestor(
      of: find.descendant(of: page, matching: find.text(label)).first,
      matching: find.byType(LensCard),
    )
    .first;

void gap(
  WidgetTester tester,
  Finder above,
  Finder below,
  double expected,
  String label,
) {
  final actual = tester.getTopLeft(below).dy - tester.getBottomLeft(above).dy;
  debugPrint('GAP $label actual=$actual expected=$expected');
  expect(actual, closeTo(expected, .001), reason: label);
}

void allSectionGaps(
  WidgetTester tester,
  Finder page,
  double expected,
  String label,
) {
  final root = tester.element(
    find.descendant(of: page, matching: find.byType(Column)).first,
  );
  final sections = <Element>[];
  root.visitChildren((element) {
    final w = element.widget;
    if (w is SizedBox && w.child == null && w.height != null) return;
    sections.add(element);
  });
  expect(sections.length, greaterThan(1));
  final gaps = <double>[];
  for (var i = 1; i < sections.length; i++) {
    final upper = sections[i - 1].findRenderObject()! as RenderBox;
    final lower = sections[i].findRenderObject()! as RenderBox;
    gaps.add(
      lower.localToGlobal(Offset.zero).dy -
          upper.localToGlobal(Offset(0, upper.size.height)).dy,
    );
  }
  debugPrint('SECTIONS $label gaps=$gaps expected=$expected');
  expect(gaps, everyElement(closeTo(expected, .001)), reason: label);
}

void main() {
  for (final width in [1440.0, 720.0]) {
    final expected = width == 720 ? 12.0 : 16.0;
    testWidgets('detail filter-strip-trend-breakdown gaps at $width', (
      tester,
    ) async {
      await mount(tester, 'detail', width);
      final page = find.byType(StatsDetail);
      final cards = find.descendant(of: page, matching: find.byType(LensCard));
      expect(cards, findsNWidgets(3));
      final root = tester.widget<Column>(
        find.descendant(of: page, matching: find.byType(Column)).first,
      );
      final filters = find.byWidget(
        root.children.firstWhere(
          (w) => w.runtimeType.toString().startsWith('ResourceBlock'),
        ),
      );
      gap(
        tester,
        filters,
        cards.at(0),
        expected,
        'detail $width filters -> strip',
      );
      gap(
        tester,
        cards.at(0),
        cards.at(1),
        expected,
        'detail $width strip -> trend',
      );
      gap(
        tester,
        cards.at(1),
        cards.at(2),
        expected,
        'detail $width trend -> breakdown',
      );
      allSectionGaps(
        tester,
        page,
        expected,
        'detail $width ready, header and footer',
      );
    });
    testWidgets('home pair rows separated at $width', (tester) async {
      await mount(tester, 'home', width);
      final page = find.byType(StatsHome);
      final heat = cardWith(page, width == 720 ? '最近 20 周' : '这一年');
      if (width == 1440) {
        gap(
          tester,
          cardWith(page, '趋势'),
          heat,
          expected,
          'home $width trend -> year',
        );
        gap(
          tester,
          cardWith(page, '常用模型'),
          cardWith(page, '最近会话'),
          expected,
          'home $width models -> recent',
        );
      } else {
        gap(
          tester,
          cardWith(page, '常用模型'),
          heat,
          expected,
          'home $width first pair -> second pair',
        );
      }
      allSectionGaps(
        tester,
        page,
        expected,
        'home $width ready, header and footer',
      );
    });
    for (final pageName in ['home', 'detail']) {
      testWidgets('$pageName loading-empty-error sections at $width', (
        tester,
      ) async {
        for (final state in [
          'loading',
          'empty',
          'error',
          if (pageName == 'home') 'banners',
        ]) {
          await mount(tester, pageName, width, state: state);
          final page = pageName == 'home'
              ? find.byType(StatsHome)
              : find.byType(StatsDetail);
          allSectionGaps(tester, page, expected, '$pageName $width $state');
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
  testWidgets('900-wide stacked pair uses non-narrow section gap', (
    tester,
  ) async {
    await mount(tester, 'home', 900);
    final page = find.byType(StatsHome);
    gap(
      tester,
      cardWith(page, '趋势'),
      cardWith(page, '常用模型'),
      16,
      'home 900 stacked pair',
    );
    gap(
      tester,
      cardWith(page, '常用模型'),
      cardWith(page, '这一年'),
      16,
      'home 900 pair boundary',
    );
    allSectionGaps(tester, page, 16, 'home 900 ready');
  });
}
