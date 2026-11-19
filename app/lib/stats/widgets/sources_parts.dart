import '../../l10n/app_strings.dart';
import '../../l10n/sync_messages.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../stats_controller.dart';
import '../../stats_gateway.dart';
import '../logic/format.dart';
import '../logic/tools.dart';
import '../theme/palette.dart';
import 'motion.dart';
import 'primitives.dart';

// Arbitrary text sizes in SourcesPage.jsx inherit Tailwind's 1.5 line height.
TextStyle _sourceText(
  LensPalette p, [
  double size = 14,
  Color? color,
  FontWeight weight = FontWeight.w400,
]) => p.text(size, color, weight).copyWith(height: 1.5, letterSpacing: 0);
String sourceRelativeTime(String? iso, DateTime now, AppStrings strings) {
  final then = DateTime.tryParse(iso ?? '');
  if (then == null) return '—';
  final minutes = (now.difference(then).inMilliseconds / 60000 + .5).floor();
  return minutes < 1
      ? strings.justNow
      : minutes < 60
      ? strings.minutesAgo(minutes)
      : minutes < 1440
      ? strings.hoursAgo((minutes / 60 + .5).floor())
      : strings.daysAgo((minutes / 1440 + .5).floor());
}

class SourcesTech extends StatefulWidget {
  const SourcesTech({super.key, this.title, required this.child});
  final String? title;
  final Widget child;
  @override
  State<SourcesTech> createState() => _SourcesTechState();
}

class _SourcesTechState extends State<SourcesTech> {
  bool open = false;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p['fill-hover'],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: open,
            child: LensFocusOutline(
              child: TextButton(
                onPressed: () => setState(() => open = !open),
                style: TextButton.styleFrom(
                  foregroundColor: p.secondary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: open ? .25 : 0,
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : LensTokens.fast,
                      child: const Icon(Icons.chevron_right, size: 14),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.title ?? context.strings.technicalDetails,
                      style: _sourceText(p, 13, p.secondary),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: DefaultTextStyle(
                style: _sourceText(p, 12.5, p.secondary),
                child: widget.child,
              ),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, {this.tone, this.check = false});
  final String label;
  final String? tone;
  final bool check;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final color = tone == null ? p.secondary : p[tone!];
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LensTokens.radii['pill']!),
        color: tone == null
            ? p['fill-hover']
            : color.withValues(alpha: tone == 'ok' ? .12 : .14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (check) ...[
            Icon(Icons.check, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _sourceText(
                p,
                11.5,
                color,
                FontWeight.w500,
              ).copyWith(height: 20 / 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

class SourcesSyncStatus extends StatelessWidget {
  const SourcesSyncStatus({
    super.key,
    required this.controller,
    this.run,
    this.result,
    this.discoveryFailures = 0,
  });
  final StatsController controller;
  final StatsSourceRun? run;
  final StatsSync? result;
  final int discoveryFailures;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context), c = controller;
    final result = this.result;
    final failures = (run?.anomalyCount ?? 0) + discoveryFailures;
    final problem = run == null
        ? context.strings.noSyncYet
        : run!.status == 'running'
        ? context.strings.syncing
        : failures > 0
        ? context.strings.lastSyncReadFailures(failures)
        : run!.status == 'ok'
        ? null
        : context.strings.lastSyncIncomplete;
    final syncing =
        c.busy || c.phase == StatsSyncPhase.idle && run?.status == 'running';
    final rereading = c.rereading;
    final reused = result == null
        ? 0
        : result.cachedFiles + result.skippedFiles;
    return LensCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            overflowAlignment: OverflowBarAlignment.end,
            spacing: 12,
            overflowSpacing: 10,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: problem == null
                          ? [
                              BoxShadow(
                                color: p['ok'].withValues(alpha: .18),
                                spreadRadius: 3,
                              ),
                            ]
                          : null,
                    ),
                    child: SizedBox(
                      width: 7,
                      height: 7,
                      child: FittedBox(
                        child: SyncDot(
                          color: problem == null
                              ? p['ok']
                              : run != null && run!.status != 'running'
                              ? p['warn']
                              : p.faint,
                          revision: c.ledgerVersion,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          problem ??
                              context.strings.synced0NoIssues(
                                sourceRelativeTime(
                                  run!.finishedAt,
                                  c.clock(),
                                  context.strings,
                                ),
                              ),
                          style: _sourceText(p, 14, null, FontWeight.w500),
                        ),
                        Text(
                          context.strings.tokenLensSyncsOnceEachTimeIt,
                          style: _sourceText(p, 12.5, p.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Opacity(
                opacity: syncing ? .6 : 1,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Tooltip(
                      message:
                          context.strings.rereadAllLogsWithoutUsingThePrevious,
                      child: SizedBox(
                        height: 34,
                        child: LensButton(
                          label: rereading
                              ? context.strings.rereading
                              : context.strings.rereadAllLogs,
                          onPressed: syncing
                              ? null
                              : () => unawaited(c.rereadLogs()),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 34,
                      child: Theme(
                        // The old sync action uses text-white in both schemes.
                        data: Theme.of(context)
                            .copyWith(brightness: Brightness.light),
                        child: LensButton(
                          label: syncing && !rereading
                              ? context.strings.syncing2
                              : context.strings.syncNow,
                          variant: 'primary',
                          icon: Icons.refresh,
                          spinning: syncing && !rereading,
                          onPressed: syncing ? null : () => unawaited(c.sync()),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (c.phase == StatsSyncPhase.success && result != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                context.strings.syncCompleted(
                  result.fileCount,
                  reused > 0 ? context.strings.unchangedFiles(reused) : '',
                  result.inserted,
                  result.updated,
                  (result.durationMs / 1000).toStringAsFixed(1),
                ),
                style: _sourceText(p, 12.5, p.secondary),
              ),
            ),
          ],
          if (c.phase == StatsSyncPhase.conflict) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                context.strings.aSyncIsAlreadyRunningWaitingFor,
                style: _sourceText(p),
              ),
            ),
          ],
          if (c.warning != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                context.strings.syncFinishedWithWarnings(c.warning),
                style: _sourceText(p, 12.5, p.secondary),
              ),
            ),
          ],
          if (c.phase == StatsSyncPhase.error) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                context.strings.syncFailed0(
                  c.syncError ?? context.strings.requestFailed,
                ),
                style: _sourceText(p, 12.5, p['danger']),
              ),
            ),
          ],
          if (run != null) ...[
            const SizedBox(height: 12),
            SourcesTech(
              title: context.strings.lastSyncDetails,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.strings.recordsProcessed(
                      toDisplayNumber(run!.attempted),
                      run!.inserted,
                      run!.updated,
                      toDisplayNumber(run!.unchanged),
                      run!.rejected,
                    ),
                  ),
                  if (run!.skippedFiles > 0)
                    Text(
                      context.strings.skipped0FileFromToolsWithNo(
                        run!.skippedFiles,
                      ),
                    ),
                  if (run!.anomalies.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    for (final anomaly in run!.anomalies)
                      Text(
                        '• ${localizedAnomaly(anomaly, context.strings)}',
                        style: p
                            .text(12, p.secondary)
                            .copyWith(
                              fontFamily: LensPalette.monoFonts.first,
                              fontFamilyFallback: LensPalette.monoFonts
                                  .skip(1)
                                  .toList(),
                            ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class SourcesUnreadableToolCard extends StatelessWidget {
  const SourcesUnreadableToolCard({super.key, required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return LensCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      child: Row(
        children: [
          ToolTile(source, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  toolOf(source).name,
                  style: _sourceText(p, 15, null, FontWeight.w600),
                ),
                const SizedBox(height: 4),
                const _SourcePermissionStatus(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SourcePermissionStatus extends StatelessWidget {
  const _SourcePermissionStatus();

  @override
  Widget build(BuildContext context) => Tooltip(
    message: context.strings.tokenLensOnlyReadsLogFilesCheck,
    child: _Pill(context.strings.cannotReadLogDirectory, tone: 'warn'),
  );
}

class SourcesToolCard extends StatelessWidget {
  const SourcesToolCard({
    super.key,
    required this.item,
    this.permissionDenied = false,
    this.showHeading = true,
    required this.monthTokens,
    required this.controller,
    required this.onDetail,
  });
  final StatsSource item;
  final bool permissionDenied, showHeading;
  final int monthTokens;
  final StatsController controller;
  final VoidCallback onDetail;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final real = item.evidence == 'A';
    final mode = switch (item.recordMode) {
      'cumulative' => (
        context.strings.sessionTotalsOnly2,
        context.strings.sessionUsageIsAvailableRequestTimesAre,
      ),
      'mixed' => (
        context.strings.mostlyPerRequest,
        context.strings.someSessionsHaveOnlyATotalAnd,
      ),
      _ => (
        context.strings.perRequest,
        context.strings.eachRequestIncludesItsTimeModelAnd,
      ),
    };
    final strings = context.strings;
    final limits = strings.isChinese
        ? item.limits
        : item.limitsEn ?? item.limits;
    final checks = [
      (
        context.strings.timeOutsideExpectedRange,
        item.checks.timeOutOfRange,
        strings.sourceCheckRecordCount,
      ),
      (
        context.strings.over100MillionTokensInOneRequest,
        item.checks.hugeRequests,
        strings.sourceCheckRecordCount,
      ),
      (
        context.strings.unpricedBecauseTheModelIsMissing,
        item.checks.nullModel,
        strings.sourceCheckRecordCount,
      ),
      (
        context.strings.sessionsMixingBothRecordTypes,
        item.checks.mixedKindSessions,
        strings.sourceCheckSessionCount,
      ),
    ].where((check) => check.$2 > 0).toList();
    final status = [
      if (item.recordMode == 'event') context.strings.perRequest,
      if (item.retention.logsGone == 0) context.strings.recordsComplete,
      if (checks.isEmpty) context.strings.checksPassed,
    ];
    Widget text(String value, {bool muted = false, bool balance = false}) =>
        Text(
          balance ? keepTailTogether(value) : value,
          style: _sourceText(p, muted ? 12.5 : 13, muted ? p.muted : p.ink),
        );
    Widget field(String label, Widget value) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: text(label, muted: true),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: value),
      ],
    );
    Widget stack(List<Widget> children, {double gap = 0}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0 && gap > 0) SizedBox(height: gap),
          children[i],
        ],
      ],
    );
    Widget note(String label, String value, {String? tone}) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: _Pill(label, tone: tone),
        ),
        const SizedBox(width: 8),
        Expanded(child: text(value, balance: true)),
      ],
    );
    return LensCard(
      padding:
          const EdgeInsets.fromLTRB(18, 16, 18, 14) *
          controller.preferences.spacing,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeading) ...[
            Row(
              children: [
                ToolTile(item.source, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: stack([
                    Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          toolOf(item.source).name,
                          style: _sourceText(p, 15, null, FontWeight.w600),
                        ),
                        _Pill(
                          context.strings.supported,
                          tone: 'ok',
                          check: true,
                        ),
                      ],
                    ),
                    Wrap(
                      runSpacing: 2,
                      children: [
                        Text(
                          context.strings.lastUsed0(
                            sourceRelativeTime(
                              item.lastObservedAt,
                              controller.clock(),
                              context.strings,
                            ),
                          ),
                          maxLines: 1,
                          softWrap: false,
                          style: _sourceText(p, 12.5, p.muted),
                        ),
                        Text(
                          context.strings.sourceMonthlyTokens(
                            tokenCount(
                              monthTokens,
                              mode: controller.preferences.tokenMode,
                              unitSystem: controller.unitSystem,
                            ),
                          ),
                          maxLines: 1,
                          softWrap: false,
                          style: _sourceText(p, 12.5, p.muted),
                        ),
                        Text(
                          context.strings.sourceRecordCount(
                            toDisplayNumber(item.records),
                          ),
                          maxLines: 1,
                          softWrap: false,
                          style: _sourceText(p, 12.5, p.muted),
                        ),
                      ],
                    ),
                  ]),
                ),
                const SizedBox(width: 12),
                Semantics(
                  link: true,
                  child: LensButton(
                    label: context.strings.sourceViewUsage,
                    size: 'link',
                    variant: 'ghost',
                    icon: Icons.arrow_forward,
                    trailingIcon: true,
                    onPressed: onDetail,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          stack([
            field(
              context.strings.status,
              permissionDenied
                  ? const _SourcePermissionStatus()
                  : Wrap(
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Tooltip(
                                message: real
                                    ? context
                                          .strings
                                          .checkedAgainstRealUsageLogs
                                    : context
                                          .strings
                                          .checkedAgainstPublicReferencesAndSamplesReport,
                                child: _Pill(
                                  real
                                      ? context.strings.verifiedWithRealLogs
                                      : context.strings.checkedWithSampleLogs,
                                  tone: real ? 'ok' : null,
                                  check: real,
                                ),
                              ),
                            ),
                            if (status.isNotEmpty) text(' · ', muted: true),
                          ],
                        ),
                        for (var i = 0; i < status.length; i++)
                          Text(
                            '${status[i]}${i < status.length - 1 ? ' · ' : ''}',
                            maxLines: 1,
                            softWrap: false,
                            style: _sourceText(p, 12.5, p.muted),
                          ),
                      ],
                    ),
            ),
            if (item.recordMode != 'event')
              field(
                context.strings.recordType,
                stack([
                  text(mode.$1),
                  text(mode.$2, muted: true, balance: true),
                ]),
              ),
            if (item.retention.logsGone > 0)
              field(
                context.strings.logRetention,
                stack([
                  text(
                    context.strings.reviewableRecords(
                      toDisplayNumber(item.retention.reviewable),
                    ),
                  ),
                  text(
                    context.strings.logsGone(
                      toDisplayNumber(item.retention.logsGone),
                    ),
                    muted: true,
                  ),
                ]),
              ),
            if (checks.isNotEmpty)
              field(
                context.strings.checks,
                stack([
                  for (final check in checks)
                    note(
                      context.strings.needsReview,
                      strings.sourceCheckLabel(check.$1, check.$3(check.$2)),
                      tone: 'warn',
                    ),
                ], gap: 6),
              ),
            if (item.notes.isNotEmpty)
              field(
                context.strings.knownLimitations,
                stack([
                  for (final n in item.notes)
                    note(
                      n.impact == 'affects'
                          ? context.strings.affectsData
                          : context.strings.handled,
                      strings.isChinese ? n.text : n.textEn ?? n.text,
                      tone: n.impact == 'affects' ? 'warn' : null,
                    ),
                ], gap: 6),
              ),
          ], gap: 8),
          const SizedBox(height: 12),
          SourcesTech(
            child: stack([
              field(
                context.strings.sourceId,
                Text(
                  item.source,
                  style: p
                      .text(12, p.secondary)
                      .copyWith(
                        fontFamily: LensPalette.monoFonts.first,
                        fontFamilyFallback: LensPalette.monoFonts
                            .skip(1)
                            .toList(),
                      ),
                ),
              ),
              field(
                context.strings.evidence,
                Text(
                  real
                      ? context.strings.aRealSamples
                      : context.strings.bSyntheticSamples,
                ),
              ),
              if (limits.isNotEmpty)
                field(
                  context.strings.technicalNotes,
                  stack([for (final limit in limits) Text(limit)]),
                ),
            ], gap: 4),
          ),
        ],
      ),
    );
  }
}

class SourcesMissingTools extends StatefulWidget {
  const SourcesMissingTools({super.key, required this.ids});
  final List<String> ids;
  @override
  State<SourcesMissingTools> createState() => _SourcesMissingToolsState();
}

class _SourcesMissingToolsState extends State<SourcesMissingTools> {
  bool open = false;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return LensCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: open,
            child: LensFocusOutline(
              child: TextButton(
                onPressed: () => setState(() => open = !open),
                style: TextButton.styleFrom(
                  foregroundColor: p.secondary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: open ? .25 : 0,
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : LensTokens.fast,
                      child: const Icon(Icons.chevron_right, size: 14),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        context.strings.supportedToolsMissing(
                          widget.ids.length,
                        ),
                        style: _sourceText(p, 13.5, p.secondary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns = MediaQuery.sizeOf(context).width >= 768
                      ? 4
                      : 2;
                  return Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      for (final id in widget.ids)
                        SizedBox(
                          width:
                              (constraints.maxWidth - 16 * (columns - 1)) /
                              columns,
                          child: Row(
                            children: [
                              Opacity(
                                opacity: .6,
                                child: ColorFiltered(
                                  colorFilter: const ColorFilter.matrix([
                                    .2126,
                                    .7152,
                                    .0722,
                                    0,
                                    0,
                                    .2126,
                                    .7152,
                                    .0722,
                                    0,
                                    0,
                                    .2126,
                                    .7152,
                                    .0722,
                                    0,
                                    0,
                                    0,
                                    0,
                                    0,
                                    1,
                                    0,
                                  ]),
                                  child: ToolTile(id, size: 20),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  toolOf(id).name,
                                  style: _sourceText(p, 13, p.muted),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
              child: Text(
                context.strings.installAndUseASupportedToolThen,
                style: _sourceText(p, 12.5, p.muted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
