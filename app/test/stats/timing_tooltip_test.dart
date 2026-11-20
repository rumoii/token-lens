import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/timing.dart';
import 'package:token_lens_app/stats_gateway.dart';

Future<void> mount(
  WidgetTester tester,
  StatsTiming timing, {
  AppStrings strings = chineseStrings,
  bool turn = false,
}) => tester.pumpWidget(
  AppLanguageScope(
    strings: strings,
    child: MaterialApp(
      theme: const LensPalette(false).theme,
      home: Scaffold(
        body: TimingStrip(
          timing: timing,
          turn: turn,
          metricKey: (kind) => ValueKey(kind),
        ),
      ),
    ),
  ),
);

const estimated = StatsTtft(
  method: 'log_timestamps',
  sampleCount: 2,
  medianMs: 1000,
  p90Ms: 1000,
);
const reported = StatsTtft(
  method: 'client_reported',
  sampleCount: 5,
  medianMs: 2000,
  p90Ms: 2000,
);
const proxy = StatsTtft(
  method: 'content_event_proxy',
  sampleCount: 1,
  medianMs: 3000,
  p90Ms: 3000,
);

void main() {
  testWidgets('中文计时默认收起来源、覆盖率和缺失指标', (tester) async {
    await mount(
      tester,
      const StatsTiming(requestCount: 5, ttft: [estimated, reported, proxy]),
    );
    expect(find.textContaining('次有记录'), findsNothing);
    expect(find.textContaining('客户端记录的计时'), findsNothing);
    expect(find.textContaining('按日志时间戳估算'), findsNothing);
    expect(find.textContaining('日志里没记'), findsNothing);
    expect(find.text('1.00 秒'), findsNothing);
    expect(find.text('3.00 秒'), findsNothing);
    expect(find.text('2.00 秒'), findsOneWidget);
    expect(find.text('· 另有 2 种估算'), findsOneWidget);
  });

  testWidgets('中文悬停主值 250 ms 后显示各来源及覆盖率', (tester) async {
    await mount(
      tester,
      const StatsTiming(requestCount: 5, ttft: [estimated, reported]),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('2.00 秒')));
    await tester.pump(const Duration(milliseconds: 249));
    expect(find.text('1.00 秒 · 按日志时间戳估算'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('1.00 秒 · 按日志时间戳估算'), findsOneWidget);
    expect(find.text('5 次请求里 2 次有记录'), findsOneWidget);
    expect(find.text('2.00 秒 · 客户端记录的计时'), findsOneWidget);
    expect(find.text('5 次请求里 5 次有记录'), findsNothing);

    await mouse.moveTo(const Offset(700, 500));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('1.00 秒 · 按日志时间戳估算'), findsNothing);
  });

  testWidgets('英文回合范围和值可用 Tab 打开浮层', (tester) async {
    await mount(
      tester,
      const StatsTiming(
        requestCount: 9,
        turn: StatsTurnTiming(turnCount: 5, ttft: [estimated]),
      ),
      strings: englishStrings,
      turn: true,
    );
    expect(find.text('Per turn'), findsOneWidget);
    expect(find.textContaining('Missing from logs'), findsNothing);
    expect(find.textContaining('Estimated from log timestamps'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.textContaining('Missing from logs'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.textContaining('Missing from logs'), findsNothing);
    expect(
      find.text('2 of 5 requests recorded · Estimated from log timestamps'),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.textContaining('2 of 5 requests recorded'), findsNothing);
  });

  testWidgets('英文没有客户端来源时取第一种，单数 estimate', (tester) async {
    await mount(
      tester,
      const StatsTiming(requestCount: 5, ttft: [estimated, proxy]),
      strings: englishStrings,
    );
    expect(find.text('1.00 s'), findsOneWidget);
    expect(find.text('3.00 s'), findsNothing);
    expect(find.text('· 1 more estimate'), findsOneWidget);
  });
}
