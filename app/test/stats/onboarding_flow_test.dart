import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/onboarding_page.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats/widgets/settings_display.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'demo_visual_support.dart'
    show loadSystemFonts, requireWindowsLayoutFonts;
import 'fake_gateway.dart';

class OnboardingGateway extends FakeStatsGateway
    implements DesktopShortcutGateway {
  OnboardingGateway() {
    empty = true;
  }
  final scans = <bool>[];
  final summaries = <StatsFilter>[];
  List<StatsDiscoveredSource> found = const [
    StatsDiscoveredSource(source: 'codex', files: 2),
    StatsDiscoveredSource(source: 'claude', files: 3),
  ];
  List<StatsDiscoveryIssue> discoveryIssues = [];
  bool discoveryFails = false, statusFails = false;
  String status = 'ok';
  List<String> anomalies = [];
  Completer<StatsDiscovery>? discoveryBarrier;
  Completer<void>? shortcutBarrier;
  bool shortcutExists = false, shortcutFails = false;
  int shortcutCreates = 0;
  final shortcutErrors = <String>[];

  @override
  Future<bool> desktopShortcutExists() async => shortcutExists;

  @override
  Future<void> createDesktopShortcut() async {
    shortcutCreates++;
    await shortcutBarrier?.future;
    if (shortcutFails) throw StateError('shortcut fixture failure');
    shortcutExists = true;
  }

  @override
  Future<void> logError(String type, String message, String stack) async {
    shortcutErrors.add(message);
  }

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
        ? StatsDiscovery(
            sources: found,
            supported: 27,
            discoveryIssues: discoveryIssues,
          )
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

class OnboardingProgressGateway extends OnboardingGateway
    implements StatsProgressGateway {
  StatsSyncProgress? progress;
  int polls = 0;

  @override
  Future<StatsSyncProgress?> syncProgress() async {
    polls++;
    return progress;
  }
}

Future<void> mount(
  WidgetTester tester,
  StatsController controller, {
  bool dark = false,
  bool reduced = true,
  double width = 720,
  TargetPlatform platform = TargetPlatform.android,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: LensPalette(dark).theme.copyWith(platform: platform),
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
  const shortcut = '在桌面创建快捷方式';
  const created = '已在桌面创建快捷方式';
  const failed = '没能创建桌面快捷方式，可以稍后在「价格与设置」里再试。';

  test('English onboarding hints use the approved copy', () {
    expect(
      englishStrings.onboardingTimeHint,
      "With lots of logs, the first count may take a few minutes. After that, only new entries are read, so it's much faster.",
    );
    expect(
      englishStrings.onboardingContinueHint,
      'No need to wait: look around while counting continues in the background. If you close the window, it picks up where it left off next time.',
    );
  });

  testWidgets('Chinese continue hint is centered on two lines at width 420', (
    tester,
  ) async {
    await loadSystemFonts(tester);
    if (!requireWindowsLayoutFonts(chinese: true)) return;
    final g = OnboardingGateway()..syncBarrier = Completer<void>();
    final c = own(g);
    await mount(tester, c);
    await click(tester, '开始统计');
    final hint = find.textContaining('不用等，可以先去看看');
    final rich = find.descendant(of: hint, matching: find.byType(RichText));
    final paragraph = tester.renderObject<RenderParagraph>(rich);
    final width = paragraph.constraints.maxWidth;
    expect(width, 420);
    final copy = paragraph.text.toPlainText();
    final painter = TextPainter(
      text: paragraph.text,
      textAlign: paragraph.textAlign,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
    )..layout(minWidth: width, maxWidth: width);
    addTearDown(painter.dispose);
    final lines = painter.computeLineMetrics();
    expect(lines, hasLength(2));
    final first = painter.getLineBoundary(const TextPosition(offset: 0));
    final second = painter.getLineBoundary(
      TextPosition(offset: copy.length - 1),
    );
    expect(first.textInside(copy).trimRight(), '不用等，可以先去看看，统计会在后台继续；');
    expect(second.textInside(copy).trimRight(), '关掉窗口也没关系，下次打开会接着读。');
    for (final line in lines) {
      expect(line.left + line.width / 2, closeTo(width / 2, .1));
    }
    g.syncBarrier!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('onboarding counts files and waits for sync to finish', (
    tester,
  ) async {
    final g = OnboardingProgressGateway()
      ..syncBarrier = Completer<void>()
      ..found = const [
        StatsDiscoveredSource(source: 'codex', files: 2),
        StatsDiscoveredSource(source: 'claude', files: 2),
        StatsDiscoveredSource(source: 'qwen', files: 1),
      ];
    final c = own(g);
    await mount(tester, c);
    await click(tester, '开始统计');
    expect(find.text('正在读取日志…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      find.byKey(const Key('onboarding-indeterminate-progress')),
      findsOneWidget,
    );
    g.progress = const StatsSyncProgress(
      stage: 'reading',
      source: 'codex',
      index: 2,
      total: 27,
      filesRead: 2,
      trigger: 'manual',
      firstSync: true,
      filesTotal: 5,
      filesProcessed: 2,
      sourceFilesProcessed: 1,
      sourceFilesTotal: 2,
      completedSources: ['qwen'],
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.text('正在读取日志… 已读 2 / 5 个文件'), findsOneWidget);
    expect(find.text('读取中 1 / 2'), findsOneWidget);
    expect(find.text('等待中'), findsOneWidget);
    expect(find.text('已读完'), findsOneWidget);
    expect(find.textContaining('· 40%'), findsOneWidget);
    expect(find.text('日志多的话，第一次统计可能要几分钟。以后打开只读新增的部分，会快很多。'), findsOneWidget);
    expect(
      find.text('不用等，可以先去看看，统计会在后台继续；\n关掉窗口也没关系，下次打开会接着读。'),
      findsOneWidget,
    );
    g.progress = const StatsSyncProgress(
      stage: 'reading',
      source: 'claude',
      index: 3,
      total: 27,
      filesRead: 4,
      trigger: 'manual',
      firstSync: true,
      filesTotal: 5,
      filesProcessed: 5,
      sourceFilesProcessed: 2,
      sourceFilesTotal: 2,
      completedSources: ['qwen', 'codex'],
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.text('日志读完了，正在整理统计…'), findsOneWidget);
    expect(find.textContaining('· 99%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .99,
    );
    expect(find.text('已读完'), findsNWidgets(3));
    expect(find.text('统计好了'), findsNothing);
    g.syncBarrier!.complete();
    await tester.pumpAndSettle();
    expect(find.text('统计好了'), findsOneWidget);
    final polls = g.polls;
    await tester.pump(const Duration(seconds: 2));
    expect(g.polls, polls);
  });

  for (final scenario in ['success', 'failure', 'unchecked', 'macOS']) {
    testWidgets('onboarding desktop shortcut $scenario', (tester) async {
      final windows = scenario != 'macOS';
      final enabled = windows && scenario != 'unchecked';
      final g = OnboardingGateway()
        ..shortcutBarrier = Completer<void>()
        ..shortcutFails = scenario == 'failure';
      await mount(
        tester,
        own(g),
        platform: windows ? TargetPlatform.windows : TargetPlatform.macOS,
      );
      expect(find.text(shortcut), windows ? findsOneWidget : findsNothing);
      if (windows) {
        final check = find.ancestor(
          of: find.text(shortcut),
          matching: find.byType(LensCheckbox),
        );
        expect(tester.widget<LensCheckbox>(check).value, isTrue);
        if (!enabled) await tester.tap(find.text(shortcut));
      }
      await click(tester, '开始统计');
      expect(g.shortcutCreates, enabled ? 1 : 0);
      expect(find.text('统计好了'), findsOneWidget);
      expect(find.text(created), findsNothing);
      g.shortcutBarrier!.complete();
      await tester.pumpAndSettle();
      expect(
        find.text(created),
        scenario == 'success' ? findsOneWidget : findsNothing,
      );
      expect(
        find.text(failed),
        scenario == 'failure' ? findsOneWidget : findsNothing,
      );
      if (scenario == 'failure') {
        expect(g.shortcutErrors.single, contains('shortcut fixture failure'));
        expect(find.textContaining('shortcut fixture failure'), findsNothing);
      }
    });
  }

  testWidgets('settings creates and recreates a desktop shortcut', (
    tester,
  ) async {
    final g = OnboardingGateway();
    final c = own(g);
    await tester.pumpWidget(
      MaterialApp(
        theme: LensPalette(false).theme
            .copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: SingleChildScrollView(child: SettingsDisplay(controller: c)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('桌面快捷方式'), findsOneWidget);
    await click(tester, '创建快捷方式');
    expect(find.text('已创建'), findsOneWidget);
    expect(find.text('重新创建'), findsOneWidget);
    g.shortcutFails = true;
    await click(tester, '重新创建');
    expect(find.text('已创建'), findsNothing);
    expect(find.text('没能创建桌面快捷方式。'), findsOneWidget);
    expect(g.shortcutErrors.single, contains('shortcut fixture failure'));
  });

  testWidgets('S0a 无日志可读时显示拒绝访问，并在重新检测后清除', (tester) async {
    final g = OnboardingGateway()
      ..found = []
      ..discoveryIssues = const [
        StatsDiscoveryIssue(
          source: 'claude',
          permissionDenied: 1,
          ioErrors: 0,
          unreadableEntries: 0,
        ),
      ];
    await mount(tester, own(g));
    const row = '找到了日志目录，但没有权限读取。检查文件夹权限后点「重新检测」。';
    expect(find.text(row), findsOneWidget);
    expect(
      find.text('有 1 个工具的日志目录没有权限读取，见下方。其余支持的工具没在这台电脑上找到。'),
      findsOneWidget,
    );
    expect(find.textContaining('这台电脑上还没找到支持的工具'), findsNothing);
    g.found = const [StatsDiscoveredSource(source: 'claude', files: 1)];
    g.discoveryIssues = [];
    await click(tester, '重新检测');
    expect(g.scans.last, isTrue);
    expect(find.text(row), findsNothing);
    expect(find.text('在这台电脑上找到 1 个工具'), findsOneWidget);
  });

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
    expect(tester.getSize(find.widgetWithText(TextButton, '开始统计')).height, 40);
    expect(
      button.style!.padding!.resolve({}),
      const EdgeInsets.symmetric(horizontal: 20),
    );
    expect(button.style!.textStyle!.resolve({})!.fontSize, 14.5);
    expect(
      (button.style!.shape!.resolve({}) as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(10),
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
  testWidgets('首次发现显示 Antigravity 和图标', (tester) async {
    final gateway = OnboardingGateway()
      ..found = const [StatsDiscoveredSource(source: 'antigravity', files: 2)];
    await mount(tester, own(gateway));
    expect(find.text('Antigravity'), findsOneWidget);
    final tile = find.byWidgetPredicate(
      (widget) => widget is ToolTile && widget.id == 'antigravity',
    );
    final image = find.descendant(of: tile, matching: find.byType(Image));
    expect(image, findsOneWidget);
    expect(
      tester.widget<Image>(image).image,
      const AssetImage('assets/tool-logos/antigravity.png'),
    );
    expect(find.descendant(of: tile, matching: find.text('A')), findsNothing);
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
