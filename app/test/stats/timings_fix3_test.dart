import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/tools.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats/widgets/timing.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'detail_page_test.dart' show DetailGateway, mountDetail;

const model = 'synthetic-shared-model-with-a-long-name';
const sources = [
  'kimi',
  'claude',
  'codex',
  'qwen',
  'pi',
  'opencode',
  'kilo',
  'grok',
];
const ttftHint = '从发出请求到看到第一段输出（含思考）的时间。‘一般’是一半请求不超过这个时间，‘慢时’是九成请求不超过这个时间。';

Future<void> hover(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  // 1192 outer pixels leave exactly 860 for the table after sidebar/padding.
  for (final width in [1192.0, 1440.0, 860.0, 720.0]) {
    for (final count in [1, 3, 8]) {
      testWidgets('FIX3 模型列 $width 外窗 $count 工具，图标封顶且保留模型名', (tester) async {
        await mountDetail(
          tester,
          DetailGateway()
            ..modelGroups = [
              for (final source in sources.take(count))
                StatsGroup(
                  key: model,
                  model: model,
                  source: source,
                  grossTokens: 100,
                  recordCount: 1,
                  requestCount: 1,
                  inputTokens: 25,
                  outputTokens: 25,
                  cacheReadTokens: 25,
                  cacheWriteTokens: 25,
                  unpricedRecords: 0,
                ),
            ],
          query: 'period=all&view=detail&dim=model',
          width: width,
          reduced: true,
        );
        // Includes any RenderFlex overflow reported during real page layout.
        expect(tester.takeException(), isNull);
        final row = find.byKey(const Key('detail-row-$model'));
        if (width == 1192) expect(tester.getSize(row).width, 860);
        final name = find.descendant(of: row, matching: find.text(model));
        expect(name, findsOneWidget);
        final text = tester.renderObject<RenderParagraph>(name);
        expect(text.size.width, greaterThanOrEqualTo(40));
        expect(tester.widget<Text>(name).overflow, TextOverflow.ellipsis);
        final icons = find.descendant(of: row, matching: find.byType(ToolTile));
        expect(icons, findsNWidgets(count > 3 ? 3 : count));
        expect(
          tester.widgetList<ToolTile>(icons).map((w) => w.id),
          orderedEquals(sources.take(count > 3 ? 3 : count)),
        );
        final badge = find.descendant(of: row, matching: find.text('+5'));
        expect(badge, count == 8 ? findsOneWidget : findsNothing);
        expect(
          find.descendant(
            of: row,
            matching: find.textContaining(RegExp(r'^\+\d+$')),
          ),
          count == 8 ? findsOneWidget : findsNothing,
        );
        final fullName = find.descendant(
          of: row,
          matching: find.byTooltip(model),
        );
        expect(fullName, findsOneWidget);
        if (count == 8) {
          final names = sources.map((id) => toolOf(id).name).join('、');
          expect(
            find.descendant(of: row, matching: find.byTooltip(names)),
            findsOneWidget,
          );
          await hover(tester, badge);
          // Existing subtitle plus the visible tooltip, including hidden tools.
          expect(find.text(names), findsNWidgets(2));
        } else {
          await hover(tester, fullName);
          expect(find.text(model), findsNWidgets(2));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('FIX3 首字提示准确说明中位数和 p90 而非最慢一次', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TimingMetric(
            timing: StatsTiming(
              requestCount: 10,
              ttft: [
                StatsTtft(
                  method: 'client_reported',
                  sampleCount: 10,
                  medianMs: 5000,
                  p90Ms: 9000,
                ),
              ],
            ),
            kind: TimingKind.ttft,
          ),
        ),
      ),
    );
    expect(find.text('一般 5.00 秒，慢时 9.00 秒'), findsOneWidget);
    expect(find.byTooltip(ttftHint), findsOneWidget);
    await hover(tester, find.byTooltip(ttftHint));
    expect(find.text(ttftHint), findsOneWidget);
    expect(find.textContaining('最慢那'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final turn in [false, true]) {
    for (final kind in TimingKind.values) {
      for (final counts in [
        (2048, 1024, '2,048 次里 1,024 次有记录'),
        (65536, 32768, '65,536 次里 32,768 次有记录'),
      ]) {
        testWidgets('FIX3 ${kind.name} turn=$turn ${counts.$1} 记录次数千位分隔', (
          tester,
        ) async {
          final ttft = [
            StatsTtft(
              method: 'client_reported',
              sampleCount: counts.$2,
              medianMs: 1000,
              p90Ms: 2000,
            ),
          ];
          final speed = [
            StatsSpeed(
              method: 'client_reported',
              sampleCount: counts.$2,
              outputTokens: 100,
              generationMs: 2000,
              tokensPerSecond: 50,
            ),
          ];
          final throughput = [
            StatsThroughput(
              method: 'client_reported',
              sampleCount: counts.$2,
              outputTokens: 100,
              durationMs: 4000,
              tokensPerSecond: 25,
            ),
          ];
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TimingMetric(
                  timing: StatsTiming(
                    requestCount: counts.$1,
                    ttft: ttft,
                    speed: speed,
                    throughput: throughput,
                    turn: StatsTurnTiming(
                      turnCount: counts.$1,
                      ttft: ttft,
                      speed: speed,
                      throughput: throughput,
                    ),
                  ),
                  kind: kind,
                  turn: turn,
                ),
              ),
            ),
          );
          expect(find.text(counts.$3), findsOneWidget);
          expect(find.text('${counts.$1} 次里 ${counts.$2} 次有记录'), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
