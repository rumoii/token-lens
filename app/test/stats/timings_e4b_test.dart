import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'detail_page_test.dart' show mountDetail;
import 'sessions_page_test.dart' show mountSessions;
import 'timings_test.dart' show TimingDetail, TimingSessions;

const throughputHint = '整次请求的输出 token 除以总耗时，等待时间也算在内，所以通常比“速度”低。';

StatsTiming sample(String state) => StatsTiming(
  requestCount: state == 'turn' ? 0 : 4,
  ttft: state == 'empty' || state == 'turn'
      ? null
      : const [
          StatsTtft(
            method: 'content_event_proxy',
            sampleCount: 2,
            medianMs: 1000,
            p90Ms: 4000,
          ),
        ],
  speed: state == 'empty' || state == 'turn'
      ? null
      : const [
          StatsSpeed(
            method: 'content_event_proxy',
            sampleCount: 2,
            outputTokens: 100,
            generationMs: 2000,
            tokensPerSecond: 50,
          ),
        ],
  throughput: state == 'empty' || state == 'turn'
      ? null
      : const [
          StatsThroughput(
            method: 'client_reported',
            sampleCount: 2,
            outputTokens: 100,
            durationMs: 4000,
            tokensPerSecond: 25,
          ),
        ],
  turn: state == 'request'
      ? null
      : StatsTurnTiming(
          turnCount: 3,
          ttft: state == 'empty'
              ? null
              : const [
                  StatsTtft(
                    method: 'log_timestamps',
                    sampleCount: 2,
                    medianMs: 5000,
                    p90Ms: 7000,
                  ),
                ],
          throughput: state == 'empty'
              ? null
              : const [
                  StatsThroughput(
                    method: 'client_reported',
                    sampleCount: 1,
                    outputTokens: 100,
                    durationMs: 8000,
                    tokensPerSecond: 12.5,
                  ),
                ],
        ),
);

Future<void> mount(
  WidgetTester tester,
  String page,
  double width,
  StatsTiming timing,
) async {
  if (page == 'session') {
    await mountSessions(
      tester,
      TimingSessions()..timing = timing,
      query: 'source=kimi&session=s',
      width: width,
    );
  } else {
    await mountDetail(
      tester,
      TimingDetail()..timing = timing,
      query: 'period=all&view=detail&dim=$page',
      width: width,
    );
  }
}

Finder cell(String page, String metric, {bool turn = false}) => find.byKey(
  Key(
    page == 'session'
        ? 'session-${turn ? 'turn-' : ''}$metric'
        : 'detail-${turn ? 'turn-' : ''}$metric-${page == 'model' ? 'm' : 'kimi'}',
  ),
);

void expectCell(Finder target, String value, String coverage) {
  expect(target, findsOneWidget);
  expect(
    find.descendant(of: target, matching: find.text(value)),
    findsOneWidget,
  );
  expect(
    find.descendant(of: target, matching: find.text(coverage)),
    findsOneWidget,
  );
}

void main() {
  for (final width in [720.0, 1100.0, 1440.0]) {
    for (final timing in [
      null,
      const StatsTiming(requestCount: 0, turn: StatsTurnTiming(turnCount: 0)),
    ]) {
      testWidgets('E4b Grok 空时段 $width ${timing == null} 保留回合作用域', (
        tester,
      ) async {
        await mountSessions(
          tester,
          TimingSessions()..timing = timing,
          query: 'source=grok&session=s',
          width: width,
        );
        expect(cell('session', 'throughput'), findsNothing);
        expect(cell('session', 'throughput', turn: true), findsNothing);
        expect(find.text('每轮对话'), findsOneWidget);
        expect(find.text('日志里没记：首字、速度、平均速度'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
    for (final page in ['session', 'tool', 'model']) {
      for (final state in ['request', 'mixed', 'turn', 'empty']) {
        testWidgets('E4b A $page $width $state 指标顺序可换行，回合另区', (tester) async {
          await mount(tester, page, width, sample(state));
          if (page != 'session') {
            for (final state in tester.stateList<ScrollableState>(
              find.byType(Scrollable),
            )) {
              if (axisDirectionToAxis(state.axisDirection) == Axis.horizontal) {
                expect(state.position.maxScrollExtent, 0);
              }
            }
          }
          final request = cell(page, 'throughput');
          final turn = cell(page, 'throughput', turn: true);
          if (state == 'request' || state == 'mixed') {
            expectCell(request, '约 25.0 token/s', '4 次里 2 次有记录');
            expectCell(cell(page, 'speed'), '约 50.0 token/s', '4 次里 2 次有记录');
            final speed = tester.getRect(cell(page, 'speed'));
            final throughput = tester.getRect(request);
            if (throughput.top > speed.top + 2) {
              expect(throughput.top, greaterThanOrEqualTo(speed.bottom));
            } else {
              expect(throughput.top, closeTo(speed.top, 2));
              expect(throughput.left, greaterThanOrEqualTo(speed.right));
            }
            expect(throughput.left, greaterThanOrEqualTo(0));
            expect(throughput.right, lessThanOrEqualTo(width));
            expect(find.byTooltip('按推理开始事件估算'), findsNWidgets(2));
          } else {
            expect(request, findsNothing);
            expect(
              find.text('每次请求'),
              page == 'session' && state == 'empty'
                  ? findsOneWidget
                  : findsNothing,
            );
          }
          if (state != 'request') {
            expect(find.text('每轮对话'), findsOneWidget);
            if (state == 'empty') {
              expect(turn, findsNothing);
              expect(
                find.text('日志里没记：首字、速度、平均速度'),
                page == 'session' ? findsNWidgets(2) : findsOneWidget,
              );
            } else {
              expectCell(turn, '约 12.5 token/s', '3 次里 1 次有记录');
              expect(find.text('日志里没记：速度'), findsOneWidget);
            }
            expect(cell(page, 'speed', turn: true), findsNothing);
            if (state == 'mixed') {
              expect(
                find.descendant(
                  of: request,
                  matching: find.text('约 12.5 token/s'),
                ),
                findsNothing,
              );
              expect(
                find.descendant(
                  of: turn,
                  matching: find.text('约 25.0 token/s'),
                ),
                findsNothing,
              );
              expect(
                tester.getTopLeft(turn).dy,
                greaterThan(tester.getBottomLeft(request).dy),
              );
            }
          } else {
            expect(turn, findsNothing);
          }
          expect(
            find.byTooltip(throughputHint),
            state == 'empty' ? findsNothing : findsWidgets,
          );
          if (state == 'request') {
            await tester.ensureVisible(request);
            expect(tester.getRect(request).right, lessThanOrEqualTo(width));
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(location: Offset.zero);
            addTearDown(mouse.removePointer);
            final help = find.descendant(
              of: request,
              matching: find.byTooltip(throughputHint),
            );
            await mouse.moveTo(tester.getCenter(help));
            await tester.pump(const Duration(seconds: 1));
            await tester.pumpAndSettle();
            expect(find.textContaining(throughputHint), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
