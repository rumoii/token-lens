import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/onboarding_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';

class OnboardingGateway extends FakeStatsGateway {
  OnboardingGateway() {
    empty = true;
  }
  final scans = <bool>[];
  final summaries = <StatsFilter>[];
  List<StatsDiscoveredSource> found = const [
    StatsDiscoveredSource(source: 'codex', files: 2),
    StatsDiscoveredSource(source: 'claude', files: 3),
  ];
  bool discoveryFails = false, statusFails = false;
  String status = 'ok';
  List<String> anomalies = [];
  Completer<StatsDiscovery>? discoveryBarrier;
  @override
  Future<StatsSummary> summary(StatsFilter filter) {
    summaries.add(filter);
    return super.summary(filter);
  }

  @override
  Future<StatsDiscovery> discovery({bool fresh = false}) async {
    scans.add(fresh);
    if (discoveryFails) throw StateError('fixture discovery offline');
    return discoveryBarrier == null
        ? StatsDiscovery(sources: found, supported: 27)
        : discoveryBarrier!.future;
  }

  @override
  Future<StatsSources> sources() async {
    if (statusFails) throw StateError('fixture status offline');
    final result = await super.sources();
    return StatsSources(
      sources: result.sources,
      snapshot: result.snapshot,
      lastRun: StatsSourceRun(
        status: status,
        anomalies: anomalies,
        anomalyCount: anomalies.length,
        attempted: 1,
        inserted: 1,
        updated: 0,
        unchanged: 0,
        rejected: 0,
      ),
    );
  }

  @override
  Future<StatsSync> sync({String trigger = 'manual'}) async {
    final result = await super.sync();
    empty = false;
    return result;
  }
}

Future<void> mount(
  WidgetTester tester,
  StatsController controller, {
  bool dark = false,
  bool reduced = true,
  double width = 720,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: LensPalette(dark).theme,
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 1000),
          disableAnimations: reduced,
        ),
        child: StatsOnboardingGate(
          controller: controller,
          child: const Text('application shell'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

StatsController own(
  OnboardingGateway gateway, {
  PreferencesStore? store,
  UiPreferences preferences = const UiPreferences(),
}) {
  final c = StatsController(
    gateway,
    store: store,
    preferences: preferences,
    clock: () => demoNow,
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> click(WidgetTester tester, String text) async {
  await tester.tap(find.widgetWithText(TextButton, text));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Mark48 与引导按钮使用旧版局部尺寸', (tester) async {
    await mount(tester, own(OnboardingGateway()));
    expect(find.byKey(const Key('onboarding-mark')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('onboarding-mark'))),
      const Size(48, 48),
    );
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '开始统计'),
    );
    expect(tester.getSize(find.widgetWithText(TextButton, '开始统计')).height, 44);
    expect(
      button.style!.padding!.resolve({}),
      const EdgeInsets.symmetric(horizontal: 22),
    );
    expect(button.style!.textStyle!.resolve({})!.fontSize, 16);
    expect(
      (button.style!.shape!.resolve({}) as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(12),
    );
  });
  testWidgets('gate 未引导且全量 0 条显示引导，无应用外壳', (tester) async {
    final g = OnboardingGateway();
    await mount(tester, own(g));
    expect(find.text('欢迎使用 Token Lens'), findsOneWidget);
    expect(find.text('application shell'), findsNothing);
    expect(g.summaries.single.from, isNull);
    expect(g.summaries.single.to, isNull);
    expect(g.syncs, 0);
  });
  testWidgets('gate 已引导不读取；有数据或首次读取失败直接进入应用', (tester) async {
    for (final scenario in ['onboarded', 'records', 'failure']) {
      final g = OnboardingGateway()..empty = scenario != 'records';
      if (scenario == 'failure') g.failure = 'fixture summary offline';
      final c = own(
        g,
        preferences: UiPreferences(onboarded: scenario == 'onboarded'),
      );
      await mount(tester, c);
      expect(find.text('application shell'), findsOneWidget, reason: scenario);
      expect(find.text('欢迎使用 Token Lens'), findsNothing);
      expect(g.scans, isEmpty);
      if (scenario == 'onboarded') expect(g.summaries, isEmpty);
      await tester.pumpWidget(const SizedBox());
    }
  });
  for (final dark in [false, true]) {
    testWidgets('gate 首次读取中主题背景且两页均不闪出 dark=$dark', (tester) async {
      final barrier = Completer<void>();
      final g = OnboardingGateway()..readBarrier = barrier;
      await mount(tester, own(g), dark: dark);
      expect(find.text('application shell'), findsNothing);
      expect(find.text('欢迎使用 Token Lens'), findsNothing);
      expect(find.byType(ColoredBox), findsWidgets);
      expect(
        tester
            .widget<ColoredBox>(find.byKey(const Key('onboarding-loading')))
            .color,
        LensPalette(dark)['surface-0'],
      );
      barrier.complete();
      await tester.pumpAndSettle();
      expect(find.text('欢迎使用 Token Lens'), findsOneWidget);
    });
  }
  testWidgets('发现名称、图标、缺失工具折叠与隐私说明', (tester) async {
    final g = OnboardingGateway();
    await mount(tester, own(g));
    expect(find.text('在这台电脑上找到 2 个工具'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.byType(ToolTile), findsNWidgets(2));
    expect(find.byKey(const Key('onboarding-mark')), findsOneWidget);
    expect(find.text('只读取本机日志，不上传任何内容，也不改动这些工具。'), findsOneWidget);
    await tester.tap(find.text('还有 25 个支持的工具没在这台电脑上找到'));
    await tester.pump();
    expect(find.text('Qwen Code'), findsOneWidget);
    await tester.tap(find.text('还有 25 个支持的工具没在这台电脑上找到'));
    await tester.pump();
    expect(find.text('Qwen Code'), findsNothing);
  });
  testWidgets('找到 0 个工具，重新检测 fresh=true，失败可重试', (tester) async {
    final g = OnboardingGateway()..found = [];
    await mount(tester, own(g));
    expect(find.text('在这台电脑上找到 0 个工具'), findsOneWidget);
    expect(find.text('开始统计'), findsNothing);
    g.discoveryFails = true;
    await click(tester, '重新检测');
    expect(g.scans, [false, true]);
    expect(find.textContaining('fixture discovery offline'), findsOneWidget);
    g.discoveryFails = false;
    g.found = const [StatsDiscoveredSource(source: 'codex', files: 1)];
    await click(tester, '重试');
    expect(g.scans, [false, true, true]);
    expect(find.text('开始统计'), findsOneWidget);
  });
  testWidgets('正常统计完成只读取一次完成汇总，写入记录后不自动进应用', (tester) async {
    final g = OnboardingGateway()..syncBarrier = Completer<void>();
    final c = own(g);
    await mount(tester, c);
    await click(tester, '开始统计');
    expect(c.phase, StatsSyncPhase.running);
    expect(find.text('正在读取日志…'), findsOneWidget);
    expect(find.text('读取中…'), findsNWidgets(2));
    g.syncBarrier!.complete();
    await tester.pumpAndSettle();
    expect(c.phase, StatsSyncPhase.success);
    expect(find.text('统计好了'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('application shell'), findsNothing);
    final count = g.summaries.length;
    await c.load();
    await tester.pumpAndSettle();
    expect(g.summaries.length, count + 2); // controller current/previous only
    expect(find.text('统计好了'), findsOneWidget);
  });
  testWidgets('首次引导只判定一次，点击开始后同步并启用定时器', (tester) async {
    final g = OnboardingGateway()..syncBarrier = Completer<void>();
    final c = own(g);
    unawaited(c.start());
    try {
      await mount(tester, c);
      expect(g.scans, [false]);
      expect(g.syncs, 0);
      expect(
        g.summaries.where((filter) => filter.from == null && filter.to == null),
        hasLength(1),
      );
      await tester.pump(const Duration(minutes: 6));
      expect(g.syncs, 0);
      await click(tester, '开始统计');
      expect(find.text('正在读取日志…'), findsOneWidget);
      expect(g.syncs, 1);
      g.syncBarrier!.complete();
      await tester.pumpAndSettle();
      expect(find.text('统计好了'), findsOneWidget);
      expect(c.preferences.onboarded, isFalse);
      await tester.pump(const Duration(minutes: 5));
      expect(g.syncs, 2);
      expect(find.text('application shell'), findsNothing);
    } finally {
      await c.shutdown();
    }
  });
  testWidgets('后台同步完成也不自动离开发现', (tester) async {
    final g = OnboardingGateway();
    final c = own(g);
    await mount(tester, c);
    await c.sync();
    await tester.pumpAndSettle();
    expect(find.text('欢迎使用 Token Lens'), findsOneWidget);
    expect(find.text('application shell'), findsNothing);
    expect(find.text('统计好了'), findsNothing);
  });
  testWidgets('冲突等待后完成，等待期间不再次同步', (tester) async {
    final g = OnboardingGateway()
      ..syncFailure = 'SYNC_BUSY'
      ..status = 'running';
    final c = own(g);
    await mount(tester, c);
    await click(tester, '开始统计');
    expect(c.phase, StatsSyncPhase.conflict);
    expect(find.text('已有同步在执行，正在等待完成'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('统计好了'), findsNothing);
    g.status = 'ok';
    g.empty = false;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(c.phase, StatsSyncPhase.success);
    expect(find.text('统计好了'), findsOneWidget);
    expect(g.syncs, 1);
  });
  testWidgets('同步失败后重试真正重新同步', (tester) async {
    final g = OnboardingGateway()..syncFailure = 'fixture sync failure';
    final c = own(g);
    await mount(tester, c);
    await click(tester, '开始统计');
    await tester.pumpAndSettle();
    expect(c.phase, StatsSyncPhase.error);
    expect(find.text('同步失败，已保留先前采集的数据。'), findsOneWidget);
    g.syncFailure = null;
    await click(tester, '重试');
    await tester.pumpAndSettle();
    expect(g.syncs, 2);
    expect(find.text('统计好了'), findsOneWidget);
  });
  testWidgets('B2-5 状态检查失败重试只查状态，恢复后完成且显示异常警告', (tester) async {
    final g = OnboardingGateway()
      ..syncFailure = 'SYNC_BUSY'
      ..statusFails = true;
    final c = own(g);
    await mount(tester, c);
    await click(tester, '开始统计');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('无法确认同步状态：Bad state: fixture status offline'),
      findsOneWidget,
    );
    await click(tester, '重试');
    await tester.pumpAndSettle();
    expect(g.syncs, 1);
    g.statusFails = false;
    g.status = 'completed_with_anomalies';
    g.empty = false;
    g.anomalies = ['vanished: onboarding fixture'];
    await click(tester, '重试');
    await tester.pumpAndSettle();
    expect(find.text('统计好了'), findsOneWidget);
    expect(
      find.text('同步完成，有异常警告：vanished: onboarding fixture'),
      findsOneWidget,
    );
    expect(c.phase, StatsSyncPhase.success);
    expect(g.syncs, 1);
  });
  testWidgets('去看看偏好落盘，进入应用，再次挂载不再出现', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('onboarding-preferences-'),
    ))!;
    final store = PreferencesStore(directory);
    final first = OnboardingGateway();
    final c = own(first, store: store);
    await c.start();
    await mount(tester, c);
    expect(first.scans, [false]);
    expect(first.syncs, 0);
    await click(tester, '开始统计');
    expect(first.syncs, 1);
    expect(find.text('统计好了'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, '去看看'));
      await store.flush();
    });
    await tester.pumpAndSettle();
    expect(find.text('application shell'), findsOneWidget);
    final saved = await tester.runAsync(store.read);
    expect(saved!.onboarded, true);
    await tester.pumpWidget(const SizedBox());
    final g = OnboardingGateway();
    await mount(tester, own(g, preferences: saved));
    expect(find.text('application shell'), findsOneWidget);
    expect(g.summaries, isEmpty);
    await c.shutdown();
    await tester.runAsync(() => directory.delete(recursive: true));
  });
  for (final dark in [false, true]) {
    testWidgets('720 宽主题与减少动态效果 dark=$dark', (tester) async {
      final g = OnboardingGateway()..syncBarrier = Completer<void>();
      await mount(tester, own(g), dark: dark);
      await click(tester, '开始统计');
      await tester.pumpAndSettle();
      expect(find.text('统计中…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      g.syncBarrier!.complete();
      await tester.pumpAndSettle();
      expect(find.text('统计好了'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('发现请求未返回时卸载，晚到结果不通知', (tester) async {
    final g = OnboardingGateway()
      ..discoveryBarrier = Completer<StatsDiscovery>();
    await mount(tester, own(g));
    await tester.pumpWidget(const SizedBox());
    g.discoveryBarrier!.complete(
      const StatsDiscovery(sources: [], supported: 27),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
