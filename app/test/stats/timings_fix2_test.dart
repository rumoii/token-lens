import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats/widgets/timing.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'detail_page_test.dart' show DetailGateway, mountDetail, pageQuery;
import 'timings_e4b_test.dart' show sample;

class LayoutTimingGateway extends DetailGateway {
  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) async {
    final value = await super.breakdown(by, filter);
    return StatsBreakdown(
      by: by,
      groups: [
        for (final source in ['kimi', 'claude', 'grok', 'pi'])
          StatsGroup(
            key: source,
            source: source,
            model: '$source-model',
            grossTokens: 100,
            inputTokens: 25,
            outputTokens: 25,
            cacheReadTokens: 25,
            cacheWriteTokens: 25,
            recordCount: 4,
            requestCount: 4,
            unpricedRecords: 0,
            timing: source == 'pi'
                ? const StatsTiming(requestCount: 4)
                : sample(source == 'grok' ? 'turn' : 'request'),
            modelTiming: sample(source == 'grok' ? 'turn' : 'request'),
          ),
      ],
      totals: value.totals,
      snapshot: value.snapshot,
    );
  }
}

Finder row(String source) => find.byKey(Key('detail-row-$source'));

void main() {
  for (final width in [1440.0, 1100.0, 720.0]) {
    testWidgets('FIX2 $width 工具名可见，计时在同行下面，无横向滚动', (tester) async {
      await mountDetail(
        tester,
        LayoutTimingGateway(),
        query: 'period=all&view=detail&dim=tool',
        width: width,
      );
      for (final state in tester.stateList<ScrollableState>(
        find.byType(Scrollable),
      )) {
        if (axisDirectionToAxis(state.axisDirection) == Axis.horizontal) {
          expect(state.position.maxScrollExtent, 0);
        }
      }
      for (final source in ['kimi', 'claude', 'grok', 'pi']) {
        final name = find.descendant(
          of: row(source),
          matching: find.text(
            {
              'kimi': 'Kimi',
              'claude': 'Claude Code',
              'grok': 'Grok CLI',
              'pi': 'Pi',
            }[source]!,
          ),
        );
        expect(name, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(name);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(tester.getRect(name).left, greaterThanOrEqualTo(0));
        expect(tester.getRect(name).right, lessThanOrEqualTo(width));
        final label = find.descendant(
          of: row(source),
          matching: find.text(source == 'grok' ? '每轮对话' : '每次请求'),
        );
        expect(label, source == 'pi' ? findsNothing : findsOneWidget);
        if (source != 'pi') {
          expect(
            tester.getTopLeft(label).dy,
            greaterThan(tester.getBottomLeft(name).dy),
          );
          final ink = find
              .ancestor(of: label, matching: find.byType(InkWell))
              .first;
          expect(tester.widget(ink), same(tester.widget(row(source))));
        }
      }
      final label = find.descendant(
        of: row('kimi'),
        matching: find.text('每次请求'),
      );
      await tester.ensureVisible(label);
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(pageQuery(tester)['tool'], 'kimi');
      expect(pageQuery(tester)['dim'], 'model');
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [1440.0, 1100.0]) {
    testWidgets('FIX2 $width 悬停墨水像素边界限制在卡片内并覆盖计时行', (tester) async {
      await mountDetail(
        tester,
        LayoutTimingGateway(),
        query: 'period=all&view=detail&dim=tool',
        width: width,
        reduced: true,
      );
      final target = row('kimi');
      await tester.ensureVisible(target);
      final card = find
          .ancestor(of: target, matching: find.byType(LensCard))
          .first;
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      // Keep the card hovered in both frames so its animated shadow is excluded.
      final bounds = tester.getRect(card);
      await mouse.moveTo(Offset(bounds.center.dx, bounds.top + 4));
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
      );
      final origin = boundary.localToGlobal(Offset.zero);
      Future<({ByteData bytes, int width})> capture() async =>
          (await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final result = (bytes: bytes!, width: image.width);
            image.dispose();
            return result;
          }))!;
      final before = await capture();
      await mouse.moveTo(tester.getTopLeft(target) + const Offset(30, 10));
      await tester.pumpAndSettle();
      final after = await capture();
      final a = before.bytes;
      final b = after.bytes;
      final r = tester.getRect(target);
      final strip = find.byKey(const Key('detail-throughput-kimi'));
      final stripTop = tester.getTopLeft(strip).dy;
      var minX = after.width, maxX = -1, mainChanges = 0, timingChanges = 0;
      // Inspect the row's full screen-width band, including outside the card.
      for (
        var y = (r.top - origin.dy).ceil();
        y < (r.bottom - origin.dy).floor();
        y++
      ) {
        for (var x = 0; x < after.width; x++) {
          final i = (y * after.width + x) * 4;
          if (a.getUint32(i) != b.getUint32(i)) {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y + origin.dy < stripTop) {
              mainChanges++;
            } else {
              timingChanges++;
            }
          }
        }
      }
      expect(minX + origin.dx, greaterThanOrEqualTo(bounds.left));
      expect(maxX + origin.dx, lessThanOrEqualTo(bounds.right));
      expect(mainChanges, greaterThan(0));
      expect(timingChanges, greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  }

  for (final single in [true, false]) {
    testWidgets('FIX2 首字${single ? '单样本' : '相同分位数'}只显示一个秒数且不显示完整覆盖', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimingMetric(
              timing: StatsTiming(
                requestCount: single ? 1 : 4,
                ttft: [
                  StatsTtft(
                    method: 'client_reported',
                    sampleCount: single ? 1 : 4,
                    medianMs: 12340,
                    p90Ms: single ? 23450 : 12340,
                  ),
                ],
              ),
              kind: TimingKind.ttft,
            ),
          ),
        ),
      );
      expect(find.text('12.34 秒'), findsOneWidget);
      expect(find.textContaining('一般'), findsNothing);
      expect(find.textContaining('次有记录'), findsNothing);
      expect(find.textContaining('覆盖'), findsNothing);
    });
  }

  testWidgets('FIX2 零样本指标不显示破折号或覆盖率', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TimingMetric(
            timing: StatsTiming(
              requestCount: 4,
              speed: [
                StatsSpeed(
                  method: 'client_reported',
                  sampleCount: 0,
                  outputTokens: 0,
                  generationMs: 0,
                  tokensPerSecond: 0,
                ),
              ],
            ),
            kind: TimingKind.speed,
          ),
        ),
      ),
    );
    expect(find.text('—'), findsNothing);
    expect(find.textContaining('覆盖'), findsNothing);
    expect(find.textContaining('token/s'), findsNothing);
  });
}
