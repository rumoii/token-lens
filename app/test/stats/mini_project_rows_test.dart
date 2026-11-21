import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/mini/mini_panel.dart';
import 'package:token_lens_app/stats/mini/mini_window.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'mini_window_test.dart' show MiniGateway, MiniPlatform;

const _longName = 'a-project-name-long-enough-to-overflow-the-mini-window';

void main() {
  for (final (language, token, width) in [
    ('en', '175.2K', 304.0),
    ('zh', '17.5万', 296.0),
  ]) {
    testWidgets('aligns project bars and totals in $language', (tester) async {
      final palette = LensPalette(language == 'en');
      final controller = await _pumpOverview(tester, language, width, palette);
      final bars = [
        for (final name in ['atlas', _longName, 'relay'])
          find.descendant(
            of: _projectRow(name),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is SizedBox &&
                  widget.width == 52 &&
                  widget.height == 2,
            ),
          ),
      ];
      final barX = tester.getTopLeft(bars.first).dx;
      for (final bar in bars) {
        expect(tester.getTopLeft(bar).dx, barX);
      }
      for (final bar in bars) {
        expect(
          find.descendant(
            of: bar,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).color ==
                      palette['line-soft'],
            ),
          ),
          findsOneWidget,
        );
      }
      for (final column in [
        [token, '9', '3', '2'],
        [r'$0.06', r'$12.34', '—', r'$0.22'],
      ]) {
        final right = tester
            .getTopRight(
              find.descendant(
                of: _projectRow('atlas'),
                matching: find.text(column.first),
              ),
            )
            .dx;
        for (final value in column.skip(1)) {
          expect(tester.getTopRight(find.text(value)).dx, closeTo(right, .01));
        }
      }
      expect(
        find.text(
          (language == 'en' ? englishStrings : chineseStrings).miniMoreProjects(
            1,
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await controller.shutdown();
    });
  }

  testWidgets('only the long project name is ellipsized', (tester) async {
    final controller = await _pumpOverview(
      tester,
      'en',
      296,
      const LensPalette(false),
    );
    final shortName = find.text('atlas');
    final shortParagraph = tester.renderObject<RenderParagraph>(shortName);
    expect(
      shortParagraph.size.width,
      closeTo(shortParagraph.getMaxIntrinsicWidth(double.infinity), .01),
    );
    final shortTile = find.descendant(
      of: _projectRow('atlas'),
      matching: find.byType(ToolTile),
    );
    expect(
      tester.getTopLeft(shortTile).dx - tester.getTopRight(shortName).dx,
      8,
    );

    final name = find.text(_longName);
    final paragraph = tester.renderObject<RenderParagraph>(name);
    expect(paragraph.overflow, TextOverflow.ellipsis);
    expect(paragraph.didExceedMaxLines, isTrue);
    final tiles = find.descendant(
      of: _projectRow(_longName),
      matching: find.byType(ToolTile),
    );
    expect(tiles, findsNWidgets(3));
    expect(tester.getTopLeft(tiles.first).dx - tester.getTopRight(name).dx, 8);
    for (var i = 0; i < 3; i++) {
      expect(tester.getSize(tiles.at(i)), const Size(14, 14));
      expect(
        tester.getTopLeft(tiles.at(i)).dx - tester.getTopLeft(tiles.first).dx,
        i * 10,
      );
    }
    expect(tester.takeException(), isNull);
    await controller.shutdown();
  });
}

Finder _projectRow(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(MiniProjectRow));

Future<StatsController> _pumpOverview(
  WidgetTester tester,
  String language,
  double width,
  LensPalette palette,
) async {
  final gateway = MiniGateway();
  gateway.data = StatsMiniUsage(
    totals: const StatsTotals(
      grossTokens: 175214,
      costMicros: 12620000,
      unpricedRecords: 1,
      recordCount: 6,
    ),
    projects: const [
      StatsMiniProject(
        key: '/synthetic/atlas',
        grossTokens: 175200,
        costMicros: 60000,
        tools: [StatsMiniTool(source: 'claude', grossTokens: 175200)],
      ),
      StatsMiniProject(
        key: '/synthetic/$_longName',
        grossTokens: 9,
        costMicros: 12340000,
        tools: [
          StatsMiniTool(source: 'claude', grossTokens: 3),
          StatsMiniTool(source: 'codex', grossTokens: 3),
          StatsMiniTool(source: 'gemini', grossTokens: 3),
        ],
      ),
      StatsMiniProject(
        key: '/synthetic/relay',
        grossTokens: 3,
        tools: [StatsMiniTool(source: 'codex', grossTokens: 3)],
      ),
      StatsMiniProject(
        key: '/synthetic/overflow',
        grossTokens: 2,
        costMicros: 220000,
        tools: [StatsMiniTool(source: 'codex', grossTokens: 2)],
      ),
    ],
    minutes: [175214],
    activeModels: [],
    requests: gateway.data.requests,
  );
  final controller = StatsController(
    gateway,
    preferences: UiPreferences(
      language: language,
      mini: const MiniPreferences(projects: 3),
    ),
  );
  final window = MiniWindow(controller: controller, platform: MiniPlatform());
  addTearDown(() async {
    window.dispose();
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  await controller.setMiniMode(true);
  await tester.binding.setSurfaceSize(Size(width, 620));
  await tester.pumpWidget(
    MaterialApp(
      theme: palette.theme,
      home: AppLanguageScope(
        strings: controller.strings,
        child: MiniPanel(
          controller: controller,
          window: window,
          onExpand: () {},
          onProject: (_) {},
          onRequest: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}
