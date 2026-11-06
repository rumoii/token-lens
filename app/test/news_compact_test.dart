import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';
import 'package:token_lens_app/news_page.dart';

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
    'source filter is a dropdown beside search, with lightweight counted tabs',
    (tester) async {
      final controller = NewsController(FakeNewsGateway(cached: multiNews));
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: NewsPage(controller: controller, openLink: (_) async => true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(FilterChip), findsNothing);
      final dropdown = find.byKey(const Key('source-filter-menu'));
      expect(dropdown, findsOneWidget);
      expect(
        tester.getTopLeft(dropdown).dx,
        greaterThan(tester.getTopLeft(find.byKey(const Key('news-search'))).dx),
      );
      expect(
        tester.getTopLeft(dropdown).dy,
        closeTo(tester.getTopLeft(find.byKey(const Key('news-search'))).dy, 1),
      );
      expect(find.byKey(const Key('category-all')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('category-all')),
          matching: find.text('${controller.visibleItems.length}'),
        ),
        findsOneWidget,
      );
      await tester.tap(dropdown, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      for (final category in SourceCategory.values) {
        expect(
          find.byKey(Key('filter-group-${category.name}')),
          findsOneWidget,
        );
      }
      await tester.tap(
        find.byKey(const Key('filter-openai')).first,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-all')).first, findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('filter-hn-ai')).first);
      await tester.tap(
        find.byKey(const Key('filter-hn-ai')).first,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(controller.sourceIds, {'openai', 'hn-ai'});
      await tester.ensureVisible(find.byKey(const Key('filter-all')).first);
      await tester.tap(
        find.byKey(const Key('filter-all')).first,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(controller.sourceIds, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-openai')), findsNothing);
      expect(
        tester.widget<OutlinedButton>(dropdown).focusNode!.hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-openai')), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('source status uses compact grouped rows with hidden actions', (
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
        theme: ThemeData(platform: TargetPlatform.windows),
        home: NewsPage(controller: controller, openLink: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('刷新此来源'), findsNothing);
    expect(find.byType(Switch), findsNothing);
    final row = find.byKey(const Key('source-row-openai'));
    expect(row, findsOneWidget);
    expect(tester.getSize(row).height, inInclusiveRange(36, 40));
    expect(
      tester.getSize(find.byKey(const Key('source-status-panel'))).height,
      lessThanOrEqualTo(1100),
    );
    for (final category in SourceCategory.values) {
      expect(find.byKey(Key('status-group-${category.name}')), findsOneWidget);
    }
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('refresh-openai')), findsOneWidget);
    expect(find.byKey(const Key('enabled-openai')), findsOneWidget);
  });

  testWidgets(
    '700px at text scale 2 supports the grouped dropdown and source actions',
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
      final dropdown = find.byKey(const Key('source-filter-menu'));
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      final option = find.byKey(const Key('filter-hn-ai')).first;
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.visibleItems.map((item) => item.id), ['h']);
      final row = find.byKey(const Key('source-row-hn-ai'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('error-hn-ai')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
