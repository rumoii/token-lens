import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

import 'detail_page_test.dart' as d;
import 'fake_gateway.dart';
import 'fix1_regressions_test.dart' show mountHome;
import 'sessions_page_test.dart' as s;

void main() {
  testWidgets('FIX1 会话窄屏：内容对齐卡片内边缘，命中区向两侧各扩 10', (tester) async {
    await s.mountSessions(
      tester,
      s.SessionsGateway(),
      width: 720,
      reduced: true,
    );
    final row = find.byKey(const Key('session-row-codex:s1'));
    final card = find.ancestor(of: row, matching: find.byType(LensCard)).first;
    final icon = find.descendant(of: row, matching: find.byType(ToolTile));
    final tokens = find.descendant(of: row, matching: find.byType(TokenText));
    final cardBox = tester.getRect(card), hit = tester.getRect(row);
    expect(tester.getTopLeft(icon).dx, closeTo(cardBox.left + 18, .01));
    expect(tester.getRect(tokens).right, closeTo(cardBox.right - 18, .01));
    expect(hit.left, closeTo(cardBox.left + 8, .01));
    expect(hit.width, closeTo(cardBox.width - 36 + 20, .01));
    expect(cardBox.right, closeTo(702, .01));
    // This point is outside the content but inside the old -mx-2.5 hit area.
    await tester.tapAt(Offset(cardBox.left + 9, hit.center.dy));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('会话详情'), findsOneWidget);
  });
  testWidgets('FIX1 明细窄屏：内容对齐卡片内边缘，命中区向两侧各扩 10', (tester) async {
    await d.mountDetail(tester, d.DetailGateway(), width: 720, reduced: true);
    final row = find.byKey(const Key('detail-row-2026-11-09'));
    final card = find.ancestor(of: row, matching: find.byType(LensCard)).first;
    final name = find.descendant(of: row, matching: find.text('11月9日 周一 · 今天'));
    final cardBox = tester.getRect(card), hit = tester.getRect(row);
    expect(tester.getTopLeft(name).dx, closeTo(cardBox.left + 18, .01));
    expect(hit.left, closeTo(cardBox.left + 8, .01));
    expect(hit.width, closeTo(cardBox.width - 36 + 20, .01));
    await tester.tapAt(Offset(cardBox.left + 9, hit.center.dy));
    await tester.pumpAndSettle();
    expect(d.pageQuery(tester)['bucket'], '2026-11-09');
  });
  testWidgets('明细宽屏：列留在卡片内并保留文字锚点', (tester) async {
    await d.mountDetail(tester, d.DetailGateway(), reduced: true);
    final row = find.byKey(const Key('detail-row-2026-11-09'));
    final card = find.ancestor(of: row, matching: find.byType(LensCard)).first;
    final name = find.descendant(of: row, matching: find.text('11月9日 周一 · 今天'));
    final cardBox = tester.getRect(card);
    expect(tester.getRect(row).left, closeTo(cardBox.left + 8, .01));
    expect(tester.getRect(row).right, closeTo(cardBox.right - 8, .01));
    expect(tester.getTopLeft(name).dx, closeTo(cardBox.left + 18, .01));
  });
  testWidgets('FIX1 价格链接：line-strong 下划线、baseline + 2、hover ink', (
    tester,
  ) async {
    await mountHome(tester, FakeStatsGateway(), const StatsPeriod('week'));
    final text = find.descendant(
      of: find.byKey(const Key('home-hero')),
      matching: find.text('价格怎么算'),
    );
    final paint = find.ancestor(
      of: text,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.foregroundPainter is LensLinkUnderline,
      ),
    );
    expect(paint, findsOneWidget);
    final dynamic underline = tester
        .widget<CustomPaint>(paint)
        .foregroundPainter;
    final palette = LensPalette.of(tester.element(text));
    final paragraph = tester.renderObject<RenderParagraph>(text);
    expect(underline.color, palette['line-strong']);
    expect(underline.offset, 2);
    expect(
      underline.y,
      closeTo(
        paragraph.getDryBaseline(
              BoxConstraints.tight(paragraph.size),
              TextBaseline.alphabetic,
            )! +
            2,
        .01,
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(text));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(text).style!.color, palette.ink);
    await mouse.removePointer();
  });
}
