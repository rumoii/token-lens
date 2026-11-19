import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/update/update_check.dart';
import 'package:token_lens_app/update/update_controller.dart';
import 'package:token_lens_app/update/update_widgets.dart';

import 'update_check_test.dart' show release, NoUpdateNetwork;

void main() {
  late UiPreferences preferences;
  late UpdateController c;
  late NoUpdateNetwork network;
  final now = DateTime(2026, 11, 17, 14, 2);
  setUp(() {
    network = NoUpdateNetwork();
    HttpOverrides.global = network;
    preferences = UiPreferences(
      onboarded: true,
      updateLastAttemptMs: now.millisecondsSinceEpoch,
    );
    c = UpdateController(
      readPreferences: () => preferences,
      savePreferences: (value) async {
        preferences = value;
      },
      clock: () => now,
      request: (_, _, _) async => UpdateResponse(200, release()),
    );
    c.setCurrentVersion('0.1.0');
  });
  tearDown(() {
    c.dispose();
    expect(network.calls, 0);
    HttpOverrides.global = null;
  });
  Future<void> mount(
    WidgetTester t, {
    double width = 1440,
    bool dark = false,
    Future<bool> Function(Uri)? openLink,
    bool hint = false,
    VoidCallback? onOpen,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 1000);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: LensPalette(dark).theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: hint ? 212 : width - 80,
              child: hint
                  ? UpdateHint(controller: c, onOpen: onOpen ?? () {})
                  : SettingsUpdate(controller: c, openLink: openLink),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('all finalized states, buttons, dates and switch suffixes', (
    t,
  ) async {
    for (final auto in [true, false]) {
      for (final kind in [null, ...UpdateKind.values]) {
        preferences = preferences.copyWith(
          autoCheckUpdates: auto,
          updateResult: kind == null
              ? null
              : UpdateResult(
                  kind,
                  version: kind == UpdateKind.available ? '0.2.0' : null,
                  publishedAt: DateTime(2026, 11, 15, 12),
                ),
        );
        await mount(t);
        expect(find.text('更新'), findsOneWidget);
        expect(find.text('每天自动检查一次'), findsOneWidget);
        final suffix = auto ? '明天会再试，也可以现在重试。' : '可以现在重试。';
        final expected = switch (kind) {
          null => ('你现在用的是 0.1.0', auto ? '还没检查过' : '还没检查过 · 自动检查已关', '检查更新'),
          UpdateKind.available => (
            '0.2.0 可以更新了',
            '11月15日发布 · 你现在用的是 0.1.0',
            '打开下载页',
          ),
          UpdateKind.latest => ('0.1.0 已是最新', '今天 14:02 检查过', '检查更新'),
          UpdateKind.offline => (
            '没检查成功',
            '连不上 GitHub · 今天 14:02。$suffix',
            '重试',
          ),
          UpdateKind.invalid => (
            '没检查成功',
            'GitHub 返回的内容读不懂 · 今天 14:02。$suffix',
            '重试',
          ),
          UpdateKind.limited => (
            '没检查成功',
            'GitHub 暂时拒绝了请求（同一网络下请求太多）· 今天 14:02。过一会儿再试。',
            '重试',
          ),
          UpdateKind.none => (
            '0.1.0 是目前唯一的版本',
            'GitHub 上还没有正式发布的版本 · 今天 14:02 检查过',
            '检查更新',
          ),
        };
        expect(find.text(expected.$1), findsOneWidget);
        expect(find.text(expected.$2), findsOneWidget);
        expect(find.text(expected.$3), findsOneWidget);
        expect(
          find.text('这个版本不再提示'),
          kind == UpdateKind.available ? findsOneWidget : findsNothing,
        );
      }
    }
    preferences = preferences.copyWith(
      updateResult: const UpdateResult(UpdateKind.available, version: '0.2.0'),
    );
    await mount(t);
    expect(find.text('你现在用的是 0.1.0'), findsOneWidget);
    preferences = preferences.copyWith(
      updateResult: const UpdateResult(UpdateKind.latest),
    );
    for (final pair in [
      (DateTime(2026, 11, 16, 14, 2), '昨天 14:02'),
      (DateTime(2026, 11, 15, 14, 2), '11月15日 14:02'),
      (DateTime(2025, 11, 15, 14, 2), '2025年11月15日 14:02'),
    ]) {
      preferences = preferences.copyWith(
        updateLastAttemptMs: pair.$1.millisecondsSinceEpoch,
      );
      await mount(t);
      expect(find.text('${pair.$2} 检查过'), findsOneWidget);
    }
  });
  testWidgets(
    'download, ignore, checking, invalid current version and clickable automatic label',
    (t) async {
      preferences = preferences.copyWith(
        updateResult: const UpdateResult(
          UpdateKind.available,
          version: '0.2.0',
        ),
      );
      Uri? opened;
      await mount(
        t,
        openLink: (uri) async {
          opened = uri;
          return true;
        },
      );
      await t.tap(find.text('打开下载页'));
      await t.pump();
      expect(opened, updateDownloadPage('0.2.0'));
      await t.tap(find.text('这个版本不再提示'));
      await t.pumpAndSettle();
      expect(find.text('这个版本不再提示'), findsNothing);
      expect(find.text('0.2.0 可以更新了'), findsOneWidget);
      await t.tap(find.text('每天自动检查一次'));
      await t.pumpAndSettle();
      expect(preferences.autoCheckUpdates, false);
      c.checking = true;
      await mount(t);
      expect(find.text('正在检查…'), findsNWidgets(2));
      expect(
        t
            .widget<LensButton>(find.byKey(const Key('update-check-button')))
            .onPressed,
        isNull,
      );
      c.checking = false;
      c.setCurrentVersion('bad');
      await mount(t);
      expect(find.text('你现在用的是 —'), findsOneWidget);
      expect(
        t
            .widget<LensButton>(find.byKey(const Key('update-check-button')))
            .onPressed,
        isNull,
      );
    },
  );
  test('attempt time follows usageTime with an unpadded hour', () {
    expect(
      updateAttemptTime(
        DateTime(2026, 11, 17, 9, 5).millisecondsSinceEpoch,
        now,
      ),
      '今天 9:05',
    );
  });
  for (final width in [1440.0, 1024.0, 720.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'update buttons and checkbox align; focused dismiss fits hint $width $dark',
        (t) async {
          preferences = preferences.copyWith(
            updateResult: const UpdateResult(
              UpdateKind.available,
              version: '0.2.0',
            ),
          );
          await mount(t, width: width, dark: dark);
          final primary = find
              .ancestor(
                of: find.text('打开下载页'),
                matching: find.byType(TextButton),
              )
              .first;
          final outlined = find.byKey(const Key('update-check-button'));
          final ignore = find
              .ancestor(
                of: find.text('这个版本不再提示'),
                matching: find.byType(LensTextLink),
              )
              .first;
          final primaryRect = t.getRect(primary),
              outlinedRect = t.getRect(outlined),
              ignoreRect = t.getRect(ignore);
          expect(primaryRect.height, closeTo(outlinedRect.height, 1));
          expect(primaryRect.center.dy, closeTo(outlinedRect.center.dy, 1));
          expect(ignoreRect.center.dy, closeTo(outlinedRect.center.dy, 1));
          final shape = t.widget<TextButton>(primary).style!.shape!.resolve({});
          expect(shape, isA<RoundedRectangleBorder>());
          final checkbox = t.getRect(find.byType(LensCheckbox));
          final visibleLeft = checkbox.center.dx - 16 / 2;
          final titleLeft = t.getTopLeft(find.text('更新')).dx;
          expect(visibleLeft, closeTo(titleLeft, 1));
          final dot = find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.constraints?.maxWidth == 8 &&
                w.constraints?.maxHeight == 8,
          );
          expect(t.getTopLeft(dot).dx, closeTo(visibleLeft, 1));

          await mount(t, width: width, dark: dark, hint: true);
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.pumpAndSettle();
          final close = find.byKey(const Key('update-hint-dismiss'));
          expect(
            FocusManager.instance.primaryFocus!.context!
                .findAncestorWidgetOfExactType<LensIconButton>()
                ?.key,
            const Key('update-hint-dismiss'),
          );
          final closeRect = t.getRect(close);
          expect(closeRect.width, inInclusiveRange(24, 28));
          expect(closeRect.height, inInclusiveRange(24, 28));
          final ring = find.byWidgetPredicate(
            (w) => w is CustomPaint && w.foregroundPainter is LensFocusRing,
          );
          expect(ring, findsOneWidget);
          final painter =
              t.widget<CustomPaint>(ring).foregroundPainter! as LensFocusRing;
          final painted = t
              .getRect(ring)
              .inflate(painter.offset + painter.strokeWidth);
          expect(painted.width, inInclusiveRange(24, 28));
          expect(painted.height, inInclusiveRange(24, 28));
          final hint = t.getRect(find.byKey(const Key('update-hint')));
          expect(painted.left, greaterThanOrEqualTo(hint.left));
          expect(painted.right, lessThanOrEqualTo(hint.right));
          expect(painted.top, greaterThanOrEqualTo(hint.top));
          expect(painted.bottom, lessThanOrEqualTo(hint.bottom));
          final outline = t.widget<LensFocusOutline>(
            find
                .descendant(of: close, matching: find.byType(LensFocusOutline))
                .first,
          );
          expect(outline.radius, 6);
          expect(t.takeException(), isNull);
        },
      );
    }
  }
  for (final width in [1440.0, 1024.0, 720.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'update card and hint stay inside parents without horizontal scroll $width $dark',
        (t) async {
          for (final kind in UpdateKind.values) {
            preferences = preferences.copyWith(
              updateResult: UpdateResult(
                kind,
                version: '0.2.0',
                publishedAt: now,
              ),
            );
            await mount(t, width: width, dark: dark);
            expect(t.takeException(), isNull);
            final card = t.getRect(find.byKey(const Key('update-card')));
            for (final finder in [
              find.byType(Text),
              find.byKey(const Key('update-check-button')),
              find.byType(LensCheckbox),
            ]) {
              for (final element in finder.evaluate()) {
                final rect = t.getRect(find.byWidget(element.widget));
                expect(rect.left, greaterThanOrEqualTo(card.left));
                expect(rect.right, lessThanOrEqualTo(card.right));
                expect(rect.top, greaterThanOrEqualTo(card.top));
                expect(rect.bottom, lessThanOrEqualTo(card.bottom));
              }
            }
            expect(
              find.byWidgetPredicate(
                (w) => w is ScrollView && w.scrollDirection == Axis.horizontal,
              ),
              findsNothing,
            );
          }
          preferences = preferences.copyWith(
            updateResult: const UpdateResult(
              UpdateKind.available,
              version: '0.2.0',
            ),
          );
          await mount(t, width: width, dark: dark, hint: true);
          expect(t.takeException(), isNull);
          final row = t.getRect(find.byKey(const Key('update-hint')));
          final close = t.getRect(find.byKey(const Key('update-hint-dismiss')));
          expect(close.left, greaterThanOrEqualTo(row.left));
          expect(close.right, lessThanOrEqualTo(row.right));
          expect(close.top, greaterThanOrEqualTo(row.top));
          expect(close.bottom, lessThanOrEqualTo(row.bottom));
        },
      );
    }
  }
  testWidgets(
    'sidebar row and dismiss are reachable with Tab and Enter; dismissal does not navigate',
    (t) async {
      preferences = preferences.copyWith(
        updateResult: const UpdateResult(
          UpdateKind.available,
          version: '0.2.0',
        ),
      );
      var navigations = 0;
      await mount(t, hint: true, onOpen: () => navigations++);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(navigations, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(
        FocusManager.instance.primaryFocus!.context!
            .findAncestorWidgetOfExactType<LensIconButton>(),
        isNotNull,
      );
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(preferences.updateIgnoredVersion, '0.2.0');
      expect(navigations, 1);
      expect(find.byKey(const Key('update-hint')), findsNothing);
    },
  );
}
