import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/detail_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'detail_page_test.dart' show DetailGateway;
import 'fake_gateway.dart' show demoNow;

class ExportGateway extends DetailGateway implements StatsUsageExporter {
  List<Object?>? exported;
  bool fail = false;

  @override
  Future<String> exportUsage({
    required String by,
    required String period,
    required StatsFilter filter,
    required String format,
    required bool projectPaths,
    required String directory,
  }) async {
    exported = [
      by,
      period,
      filter.source,
      filter.from,
      format,
      projectPaths,
      directory,
    ];
    if (fail) throw StateError('synthetic failure');
    return '/synthetic/token-lens-model.csv';
  }
}

void main() {
  for (final english in [false, true]) {
    testWidgets('localized detail export menu and results ($english)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = ExportGateway();
      final c = StatsController(
        gateway,
        clock: () => demoNow,
        preferences: const UiPreferences(onboarded: true),
      );
      addTearDown(c.dispose);
      final strings = english ? englishStrings : chineseStrings;
      Future<void> mount(String dim) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: const LensPalette(false).theme,
            home: AppLanguageScope(
              strings: strings,
              child: Scaffold(
                body: SingleChildScrollView(
                  child: StatsDetail(
                    controller: c,
                    query: 'period=month&view=detail&tool=claude&dim=$dim',
                    onQuery: (_) {},
                    onHome: () {},
                    onSettings: () {},
                    downloadsDirectory: () async => Directory('/synthetic'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      final button = find.text(english ? 'Export' : '导出');
      await mount('request');
      expect(button, findsNothing);
      await mount('model');
      expect(button, findsOneWidget);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      final include = find.text(
        english ? 'Include full project paths' : '包含完整项目路径',
      );
      expect(include, findsOneWidget);
      expect(find.text(english ? 'Export JSON' : '导出 JSON'), findsOneWidget);
      await tester.tap(find.text(english ? 'Export CSV' : '导出 CSV'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          english
              ? 'Exported token-lens-model.csv'
              : '已导出 token-lens-model.csv',
        ),
        findsOneWidget,
      );
      expect(gateway.exported?.sublist(0, 3), ['model', 'month', 'claude']);
      expect(gateway.exported?[5], false);
      gateway.fail = true;
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(include);
      await tester.pumpAndSettle();
      await tester.tap(find.text(english ? 'Export JSON' : '导出 JSON'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(english ? 'Export failed: ' : '导出失败：'),
        findsOneWidget,
      );
      expect(gateway.exported?[5], true);
    });
  }
}
