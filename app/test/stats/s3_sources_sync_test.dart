import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

import 'fake_gateway.dart';
import 'language_test.dart' show expectEnglish;

class S3Gateway extends FakeStatsGateway implements StatsProgressGateway {
  int polls = 0;
  List<String> issues = [];
  final seenFilters = <StatsFilter>[];

  @override
  int amount(StatsFilter filter) =>
      filter.excludeSources?.contains('claude') == true
      ? super.amount(filter) ~/ 2
      : super.amount(filter);

  @override
  List<StatsGroup> groups(StatsFilter filter, {String by = 'source_model'}) =>
      super
          .groups(filter, by: by)
          .where(
            (group) => filter.excludeSources?.contains(group.source) != true,
          )
          .toList();

  @override
  Future<StatsSummary> summary(StatsFilter filter) {
    seenFilters.add(filter);
    return super.summary(filter);
  }

  @override
  Future<StatsSync> sync({String trigger = 'manual'}) async {
    final result = await super.sync(trigger: trigger);
    return StatsSync(
      attempted: result.attempted,
      inserted: result.inserted,
      updated: result.updated,
      unchanged: result.unchanged,
      rejected: result.rejected,
      repriced: result.repriced,
      counts: result.counts,
      anomalies: issues,
      fileCount: result.fileCount,
      durationMs: result.durationMs,
    );
  }

  StatsSyncProgress? progress;
  @override
  Future<StatsSyncProgress?> syncProgress() async {
    polls++;
    return progress;
  }

  @override
  Future<StatsDiscovery> discovery({bool fresh = false}) async =>
      const StatsDiscovery(
        sources: [],
        supported: 3,
        tools: [
          StatsDiscoveredTool(
            source: 'claude',
            status: 'found',
            directories: [
              StatsLogDirectory(
                path: r'C:\Synthetic\Claude\projects',
                status: 'found',
                files: 2,
                exists: true,
              ),
            ],
          ),
          StatsDiscoveredTool(
            source: 'codex',
            status: 'permission_denied',
            directories: [
              StatsLogDirectory(
                path: r'C:\Synthetic\Private\Codex',
                status: 'permission_denied',
                files: 0,
                exists: false,
              ),
            ],
          ),
          StatsDiscoveredTool(
            source: 'hermes',
            status: 'missing',
            directories: [
              StatsLogDirectory(
                path: r'C:\Synthetic\Hermes\usage',
                status: 'missing',
                files: 0,
                exists: false,
              ),
            ],
          ),
        ],
      );
}

Future<StatsController> mountS3(
  WidgetTester tester,
  S3Gateway gateway,
  String language,
) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = StatsController(
    gateway,
    clock: () => demoNow,
    preferences: UiPreferences(language: language),
  );
  addTearDown(c.dispose);
  await c.load();
  await tester.pumpWidget(
    ListenableBuilder(
      listenable: c,
      builder: (context, _) => MaterialApp(
        locale: Locale(language),
        theme: LensPalette(false).theme,
        home: AppLanguageScope(
          strings: c.strings,
          child: StatsPage(controller: c),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('S3 first sync shows progress and does not poll when idle', (
    tester,
  ) async {
    final g = S3Gateway()..syncBarrier = Completer<void>();
    final c = await mountS3(tester, g, 'en');
    await tester.pump(const Duration(seconds: 1));
    expect(g.polls, 0);
    g.progress = const StatsSyncProgress(
      stage: 'reading',
      source: 'claude',
      index: 1,
      total: 28,
      filesRead: 2,
      trigger: 'startup',
      firstSync: true,
    );
    final sync = c.sync(trigger: 'startup');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pump();
    expect(
      find.textContaining('First sync: reading Claude Code'),
      findsOneWidget,
    );
    expect(
      find.text(
        'The first sync is still running. Below is what has been read so far.',
      ),
      findsOneWidget,
    );
    g.syncBarrier!.complete();
    await sync;
    await tester.pump();
    final stoppedAt = g.polls;
    await tester.pump(const Duration(seconds: 5));
    expect(g.polls, stoppedAt);
    expect(find.textContaining('First sync:'), findsNothing);
  });

  for (final language in ['zh', 'en']) {
    final en = language == 'en';
    testWidgets(
      'S3 inventory searches paths and copies a directory ($language)',
      (tester) async {
        final c = await mountS3(tester, S3Gateway(), language);
        await tester.tap(find.text(en ? 'Tools' : '工具'));
        await tester.pumpAndSettle();
        expect(
          find.text(en ? 'Search tools or paths' : '搜工具或路径'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('tool-hermes')), findsNothing);
        await tester.enterText(find.byType(TextField), 'Private');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tool-claude')), findsNothing);
        expect(find.byKey(const ValueKey('tool-codex')), findsOneWidget);
        String? copied;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        await tester.tap(find.byTooltip(en ? 'Copy path' : '复制路径'));
        await tester.pump();
        expect(copied, r'C:\Synthetic\Private\Codex');
        expect(c.preferences.hiddenTools, isEmpty);
        if (en) expectEnglish(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in ['zh', 'en']) {
    final en = language == 'en';

    testWidgets(
      'groups and hidden filter keep inventory rows in place ($language)',
      (tester) async {
        final g = S3Gateway();
        final c = await mountS3(tester, g, language);
        final before = c.overview!.summary.totals.grossTokens;
        await tester.tap(find.text(c.strings.toolSources));
        await tester.pumpAndSettle();
        for (final group in ['found', 'issues', 'missing']) {
          expect(find.byKey(ValueKey('source-group-$group')), findsOneWidget);
        }
        final hermes = find.byKey(const ValueKey('tool-hermes'));
        expect(hermes, findsNothing);
        await tester.tap(find.byKey(const ValueKey('source-group-missing')));
        await tester.pumpAndSettle();
        expect(hermes, findsOneWidget);
        expect(
          find.descendant(of: hermes, matching: find.byType(LensSwitch)),
          findsNothing,
        );

        await tester.tap(find.byKey(const ValueKey('source-filter-issues')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tool-claude')), findsNothing);
        await tester.tap(find.text('Codex').last);
        await tester.pumpAndSettle();
        expect(find.text(c.strings.inventoryLocations), findsOneWidget);
        expect(
          find.text(c.strings.tokenLensOnlyReadsLogFilesCheck),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('source-filter-all')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('show-claude')));
        await tester.pumpAndSettle();
        final claude = find.byKey(const ValueKey('tool-claude'));
        expect(tester.widget<Opacity>(claude).opacity, lessThan(1));
        expect(
          find.descendant(
            of: claude,
            matching: find.text(c.strings.inventoryHidden),
          ),
          findsOneWidget,
        );
        expect(c.overview!.summary.totals.grossTokens, lessThan(before));
        expect(g.seenFilters.last.excludeSources, ['claude']);

        await tester.tap(find.text(c.strings.usageOverview));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('sidebar-tool-claude')), findsNothing);
        expect(
          find.text('${c.strings.hiddenToolsNotice(1)} ·'),
          findsOneWidget,
        );
        await tester.tap(find.text(c.strings.hiddenToolsManage));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<LensChip>(
                find.byKey(const ValueKey('source-filter-hidden')),
              )
              .selected,
          isTrue,
        );
        expect(claude, findsOneWidget);
        expect(find.byKey(const ValueKey('tool-codex')), findsNothing);
        if (en) expectEnglish(tester);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'sync capsule, result dismissal and navigation persist across pages ($language)',
      (tester) async {
        final g = S3Gateway()..syncBarrier = Completer<void>();
        final c = await mountS3(tester, g, language);
        final heading = find.text(c.strings.stillUpLate);
        final position = tester.getTopLeft(heading);
        g.progress = const StatsSyncProgress(
          stage: 'reading',
          source: 'claude',
          index: 1,
          total: 28,
          filesRead: 2,
          trigger: 'manual',
          firstSync: false,
        );
        final sync = c.sync();
        await tester.pump(const Duration(milliseconds: 301));
        await tester.pump();
        expect(
          find.text(c.strings.progressSyncing('Claude Code')),
          findsOneWidget,
        );
        expect(tester.getTopLeft(heading), position);
        g.syncBarrier!.complete();
        await sync;
        await tester.pump();
        expect(find.text(c.strings.progressSynced), findsOneWidget);
        await tester.pump(const Duration(seconds: 4));
        expect(find.byKey(const Key('stats-sync-capsule')), findsNothing);
        g.syncBarrier = null;

        g.syncFailure = 'synthetic failure';
        await c.sync();
        await tester.pumpAndSettle();
        expect(
          find.text(
            c.strings.progressFailed(c.strings.progressEarlierDataPreserved),
          ),
          findsOneWidget,
        );
        if (en) expectEnglish(tester);
        await tester.tap(find.byTooltip(c.strings.progressDismiss));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('nav-detail')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('stats-sync-receipt')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('nav-sessions')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('stats-sync-receipt')), findsNothing);

        g.syncFailure = null;
        g.issues = ['read_failed: claude — fixture'];
        await c.sync();
        await tester.pumpAndSettle();
        expect(find.text(c.strings.progressIssues(1)), findsOneWidget);
        await tester.tap(find.byTooltip(c.strings.progressDismiss));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('stats-sync-receipt')), findsNothing);
        await c.sync();
        await tester.pumpAndSettle();
        await tester.tap(find.text(c.strings.viewDetails));
        await tester.pumpAndSettle();
        expect(find.text(c.strings.inventorySearch), findsOneWidget);
        if (en) expectEnglish(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
