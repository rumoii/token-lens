import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';
import 'package:token_lens_app/news_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';

import 'support/fake_news_gateway.dart';

void main() {
  test(
    'preview covers the sixteen contract sources and realistic source states',
    () {
      expect(multiNews.sources.length, 16);
      expect(multiNews.sources.map((source) => source.id).toSet().length, 16);
      expect(
        multiNews.sources.where((source) => source.error != null).length,
        3,
      );
      expect(multiNews.sources.where((source) => !source.enabled).length, 2);
      expect(
        {
          for (final category in SourceCategory.values)
            category: multiNews.sources
                .where((source) => source.category == category)
                .length,
        },
        {
          SourceCategory.official: 4,
          SourceCategory.tools: 6,
          SourceCategory.community: 5,
          SourceCategory.chinese: 1,
        },
      );
    },
  );

  testWidgets(
    'filter popover sits in the toolbar beside search, with counted chips',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = NewsController(FakeNewsGateway(cached: multiNews));
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: const LensPalette(false).theme,
          home: NewsPage(controller: controller, openLink: (_) async => true),
        ),
      );
      await tester.pumpAndSettle();
      final filter = find.byKey(const Key('news-filter'));
      final search = find.byKey(const Key('news-search'));
      expect(filter, findsOneWidget);
      expect(
        tester.getTopLeft(filter).dx,
        greaterThan(tester.getTopLeft(search).dx),
      );
      expect(
        tester.getCenter(filter).dy,
        closeTo(tester.getCenter(search).dy, 2),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('category-all')),
          matching: find.text('${controller.visibleItems.length}'),
        ),
        findsOneWidget,
      );
      await tester.tap(filter, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-group-kind')), findsOneWidget);
      for (final category in SourceCategory.values) {
        expect(
          find.byKey(Key('filter-group-${category.name}')),
          findsOneWidget,
        );
      }
      expect(find.byKey(const Key('filter-hf-spaces')), findsNothing);
      await tester.tap(
        find.byKey(const Key('filter-openai')).first,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('filter-hn-ai')).first);
      await tester.tap(
        find.byKey(const Key('filter-hn-ai')).first,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(controller.sourceIds, {'openai', 'hn-ai'});
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-openai')), findsNothing);
      final button = tester.widget<TextButton>(
        find.descendant(of: filter, matching: find.byType(TextButton)),
      );
      expect(button.focusNode!.hasFocus, isTrue);
      expect(find.byKey(const Key('filter-tag-openai')), findsOneWidget);
      expect(find.byKey(const Key('filter-tag-hn-ai')), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('filter-tag-openai')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.sourceIds, {'hn-ai'});
      await tester.tap(find.text('清除筛选'));
      await tester.pumpAndSettle();
      expect(controller.sourceIds, isEmpty);
      expect(find.byKey(const Key('filter-tag-hn-ai')), findsNothing);
      button.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-openai')), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('manage sources opens a drawer with grouped rows and switches', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = NewsController(FakeNewsGateway(cached: multiNews));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: const LensPalette(false).theme,
        home: NewsPage(controller: controller, openLink: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('source-status-panel')), findsNothing);
    expect(find.text('3 个来源没更新'), findsOneWidget);
    final manage = find.byKey(const Key('manage-sources'));
    await tester.tap(manage);
    await tester.pumpAndSettle();
    final panel = find.byKey(const Key('source-status-panel'));
    expect(panel, findsOneWidget);
    for (final category in SourceCategory.values) {
      expect(find.byKey(Key('status-group-${category.name}')), findsOneWidget);
    }
    expect(find.byType(Switch), findsNWidgets(16));
    expect(
      tester.widget<Switch>(find.byKey(const Key('enabled-hf-spaces'))).value,
      isFalse,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('source-status-hf-spaces')))
          .data,
      '已停用',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('source-status-hn-ai'))).data,
      startsWith('限流'),
    );
    await tester.tap(find.byKey(const Key('source-row-openai')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('refresh-openai')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    final button = tester.widget<TextButton>(
      find.descendant(of: manage, matching: find.byType(TextButton)),
    );
    expect(button.focusNode!.hasFocus, isTrue);
  });

  testWidgets(
    '700px at text scale 2 supports the filter popover and source actions',
    (tester) async {
      tester.view.physicalSize = const Size(700, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = NewsController(FakeNewsGateway(cached: multiNews));
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: NewsPage(controller: controller, openLink: (_) async => true),
        ),
      );
      await tester.pumpAndSettle();
      final filter = find.byKey(const Key('news-filter'));
      await tester.ensureVisible(filter);
      await tester.pumpAndSettle();
      await tester.tap(filter);
      await tester.pumpAndSettle();
      final option = find.byKey(const Key('filter-hn-ai')).first;
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.visibleItems.map((item) => item.id), ['o', 'h']);
      await tester.scrollUntilVisible(
        find.byKey(const Key('manage-sources')),
        -200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('news-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(find.byKey(const Key('manage-sources')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('manage-sources')));
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('source-row-hn-ai'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('error-hn-ai')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
