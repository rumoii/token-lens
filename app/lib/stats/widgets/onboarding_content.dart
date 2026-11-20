import '../../l10n/app_strings.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../smooth_wheel.dart';
import '../../stats_controller.dart';
import '../../stats_gateway.dart';
import '../logic/format.dart';
import '../logic/tools.dart';
import '../theme/palette.dart';
import 'motion.dart';
import 'primitives.dart';
import 'resource.dart';

enum OnboardingStep { discover, counting, done }

class OnboardingContent extends StatefulWidget {
  const OnboardingContent({
    super.key,
    required this.controller,
    required this.step,
    required this.discovery,
    required this.completed,
    required this.onStart,
    required this.localOnly,
    required this.onLocalOnlyChanged,
    required this.onRescan,
    required this.onEnter,
  });
  final StatsController controller;
  final OnboardingStep step;
  final LensResource<StatsDiscovery> discovery;
  final LensResource<StatsSummary> completed;
  final VoidCallback onStart, onRescan, onEnter;
  final bool localOnly;
  final ValueChanged<bool> onLocalOnlyChanged;
  @override
  State<OnboardingContent> createState() => _OnboardingContentState();
}

class _OnboardingContentState extends State<OnboardingContent> {
  final scroll = SmoothWheelController();
  bool moreOpen = false;
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final counting = widget.step == OnboardingStep.counting;
    final done = widget.step == OnboardingStep.done;
    final found = widget.discovery.data?.sources ?? <StatsDiscoveredSource>[];
    final supported = widget.discovery.data?.supported ?? tools.length;
    final denied = {
      for (final issue in widget.discovery.data?.discoveryIssues ?? [])
        if (issue.permissionDenied > 0) issue.source,
    };
    final filesByTool = {for (final item in found) item.source: item.files};
    final detected = {...filesByTool.keys, ...denied};
    final missing = tools.keys.where((id) => !detected.contains(id));
    final missingCount = math.max(0, supported - detected.length);
    final c = widget.controller;
    Widget text(
      String value,
      double size, {
      Color? color,
      FontWeight weight = FontWeight.w400,
      TextAlign? align,
    }) => Text(
      value,
      textAlign: align,
      style: p.text(size, color, weight).copyWith(height: 1.5),
    );
    Widget statusText(String value) => Semantics(
      liveRegion: true,
      child: text(value, 12.5, color: p.secondary, align: TextAlign.center),
    );
    Widget action(
      String label,
      VoidCallback? onPressed, {
      bool arrow = false,
    }) => LensButton(
      label: label,
      variant: 'primary',
      size: label == context.strings.scanAgain ? 'md' : 'lg',
      onPressed: onPressed,
      icon: arrow ? Icons.arrow_forward : null,
      trailingIcon: arrow,
    );
    final title = Text(
      done ? context.strings.usageIsReady : context.strings.welcomeToTokenLens,
      textAlign: TextAlign.center,
      style: p
          .serif(width >= 768 ? 34 : 28, weight: FontWeight.w500)
          .copyWith(
            height: 1.5,
            letterSpacing: -(width >= 768 ? 34 : 28) * .01,
          ),
    );
    final summary = widget.completed.fresh ? widget.completed.data : null;
    final firstSeen = DateTime.tryParse(summary?.activity.firstSeen ?? '')
        ?.toLocal();
    final firstSeenText = firstSeen == null
        ? '—'
        : context.strings.calendarDayWithYear(
            firstSeen.year,
            firstSeen.month,
            firstSeen.day,
          );
    final completionMetrics = [
      (
        summary == null
            ? '—'
            : tokenCount(
                summary.totals.grossTokens,
                mode: c.preferences.tokenMode,
                unitSystem: c.unitSystem,
              ),
        context.strings.tokenUnit,
      ),
      (
        summary == null ? '—' : toDisplayNumber(summary.totals.recordCount),
        context.strings.recordsNoun(summary?.totals.recordCount ?? 0),
      ),
      (
        summary == null ? '—' : toDisplayNumber(summary.activity.sessions),
        context.strings.sessionsNoun(summary?.activity.sessions ?? 0),
      ),
    ];
    return Material(
      color: p['surface-0'],
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _OnboardingGlow(p['clay'])),
            ),
          ),
          SingleChildScrollView(
            controller: scroll,
            padding: EdgeInsets.fromLTRB(
              width >= 768 ? 20 : 14,
              width >= 768 ? 56 : 32,
              width >= 768 ? 20 : 14,
              40,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: done
                          ? Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: p['clay'],
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x8cd97757),
                                    offset: Offset(0, 8),
                                    blurRadius: 24,
                                    spreadRadius: -6,
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.check,
                                size: 30,
                                color: p['tile-ink'],
                              ),
                            )
                          : ExcludeSemantics(
                              child: BrandMark(
                                key: const Key('onboarding-mark'),
                                size: 48,
                              ),
                            ),
                    ),
                    const SizedBox(height: 18),
                    Semantics(header: true, child: title),
                    const SizedBox(height: 6),
                    text(
                      done
                          ? context.strings.theFirstRecordIsFrom0Older(
                              firstSeenText,
                            )
                          : context.strings.seeHowManyTokensYourAiCoding,
                      16,
                      color: p.secondary,
                      align: TextAlign.center,
                    ),
                    const SizedBox(height: 28),
                    if (done) ...[
                      LensCard(
                        child: Table(
                          defaultVerticalAlignment:
                              TableCellVerticalAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          border: TableBorder(
                            verticalInside: BorderSide(
                              width: LensPalette.hairline(context),
                              color: p['line-soft'],
                            ),
                          ),
                          children: [
                            TableRow(
                              children: [
                                for (final (index, (number, unit))
                                    in completionMetrics.indexed)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      18,
                                      16,
                                      18,
                                      0,
                                    ),
                                    child: Tooltip(
                                      message: index == 0 && summary != null
                                          ? '${toDisplayNumber(summary.totals.grossTokens)} $unit'
                                          : '',
                                      child: Text(
                                        number,
                                        style: p
                                            .serif(width >= 1024 ? 26 : 20)
                                            .copyWith(height: 1.2),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            TableRow(
                              children: [
                                for (final (_, unit) in completionMetrics)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      18,
                                      0,
                                      18,
                                      16,
                                    ),
                                    child: text(unit, 12.5, color: p.muted),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final item in found)
                            ToolTile(item.source, size: 32),
                        ],
                      ),
                      const SizedBox(height: 24),
                      if (c.warning != null) ...[
                        statusText(
                          context.strings.syncFinishedWithWarnings(c.warning),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (widget.completed.error != null) ...[
                        ResourceBlock(
                          resource: widget.completed,
                          builder: (_) => const SizedBox(),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Center(
                        child: action(
                          context.strings.viewUsage,
                          widget.onEnter,
                          arrow: true,
                        ),
                      ),
                    ] else ...[
                      LensCard(
                        child: ResourceBlock(
                          resource: widget.discovery,
                          builder: (_) => Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (counting)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    14,
                                    18,
                                    6,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Semantics(
                                        liveRegion: true,
                                        child: text(
                                          context.strings.readingLogs,
                                          14,
                                          weight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        child: SizedBox(
                                          height: 6,
                                          child: ColoredBox(
                                            color: p['fill-hover'],
                                            child: LayoutBuilder(
                                              builder: (context, size) => LensLoop(
                                                duration: const Duration(
                                                  milliseconds: 2200,
                                                ),
                                                builder: (context, value) => Align(
                                                  alignment: Alignment(
                                                    -1 +
                                                        2 *
                                                            Curves.easeInOut
                                                                .transform(
                                                                  1 -
                                                                      (value * 2 -
                                                                              1)
                                                                          .abs(),
                                                                ),
                                                    0,
                                                  ),
                                                  child: Container(
                                                    width: size.maxWidth * .4,
                                                    decoration: BoxDecoration(
                                                      color: p['clay'],
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            999,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (!counting)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    16,
                                    18,
                                    6,
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: [
                                      Flexible(
                                        child: text(
                                          context.strings.toolsFound(
                                            found.length,
                                          ),
                                          14,
                                          weight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      text(
                                        context.strings.supportedToolCount(
                                          supported,
                                        ),
                                        12.5,
                                        color: p.muted,
                                      ),
                                    ],
                                  ),
                                ),
                              if (found.isEmpty && !counting)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    4,
                                    18,
                                    16,
                                  ),
                                  child: text(
                                    denied.isEmpty
                                        ? context
                                              .strings
                                              .noLogsFoundForSupportedToolsOn
                                        : context.strings
                                              .couldNotAccessLogDirectoriesFor0(
                                                denied.length,
                                              ),
                                    13,
                                    color: p.muted,
                                  ),
                                ),
                              if (detected.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    4,
                                    10,
                                    8,
                                  ),
                                  child: Column(
                                    children: [
                                      for (final item in detected.indexed)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 9,
                                          ),
                                          foregroundDecoration: BoxDecoration(
                                            border: item.$1 == 0
                                                ? null
                                                : Border(
                                                    top: BorderSide(
                                                      width:
                                                          LensPalette.hairline(
                                                            context,
                                                          ),
                                                      color: p['line-soft'],
                                                    ),
                                                  ),
                                          ),
                                          child: Row(
                                            children: [
                                              ToolTile(item.$2, size: 32),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    text(
                                                      toolOf(item.$2).name,
                                                      14,
                                                      weight: FontWeight.w500,
                                                    ),
                                                    if (filesByTool[item.$2]
                                                        case final files?)
                                                      text(
                                                        context.strings
                                                            .logFileCount(
                                                              toDisplayNumber(
                                                                files,
                                                              ),
                                                            ),
                                                        12.5,
                                                        color: p.muted,
                                                      ),
                                                    if (denied.contains(
                                                      item.$2,
                                                    ))
                                                      text(
                                                        context
                                                            .strings
                                                            .foundTheLogDirectoryButCouldNot,
                                                        12.5,
                                                        color: p['warn'],
                                                      ),
                                                  ],
                                                ),
                                              ),
                                              if (counting &&
                                                  filesByTool.containsKey(
                                                    item.$2,
                                                  ))
                                                text(
                                                  context.strings.reading,
                                                  12.5,
                                                  color: p.muted,
                                                )
                                              else if (filesByTool.containsKey(
                                                item.$2,
                                              )) ...[
                                                Icon(
                                                  Icons.check,
                                                  size: 14,
                                                  color: p['ok'],
                                                ),
                                                const SizedBox(width: 4),
                                                text(
                                                  context.strings.found,
                                                  12.5,
                                                  color: p['ok'],
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              if (!counting && missingCount > 0) ...[
                                Container(
                                  foregroundDecoration: BoxDecoration(
                                    border: Border(
                                      top: BorderSide(
                                        width: LensPalette.hairline(context),
                                        color: p['line-soft'],
                                      ),
                                    ),
                                  ),
                                  child: LensDisclosure(
                                    expanded: moreOpen,
                                    onPressed: () =>
                                        setState(() => moreOpen = !moreOpen),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                      vertical: 12,
                                    ),
                                    child: text(
                                      context.strings.supportedToolsMissing(
                                        missingCount,
                                      ),
                                      13,
                                      color: p.secondary,
                                    ),
                                  ),
                                ),
                                if (moreOpen)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      18,
                                      0,
                                      18,
                                      16,
                                    ),
                                    child: LayoutBuilder(
                                      builder: (context, size) => Wrap(
                                        spacing: 16,
                                        runSpacing: 6,
                                        children: [
                                          for (final id in missing)
                                            SizedBox(
                                              width: (size.maxWidth - 16) / 2,
                                              child: Row(
                                                children: [
                                                  Opacity(
                                                    opacity: .65,
                                                    child: ColorFiltered(
                                                      colorFilter:
                                                          const ColorFilter.matrix(
                                                            [
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
                                                            ],
                                                          ),
                                                      child: ToolTile(
                                                        id,
                                                        size: 20,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Flexible(
                                                    child: text(
                                                      toolOf(id).name,
                                                      13,
                                                      color: p.muted,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (!counting) ...[
                        const SizedBox(height: 12),
                        LensCard(
                          child: LensCheckbox(
                            value: widget.localOnly,
                            onChanged: widget.onLocalOnlyChanged,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 4,
                            ),
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 72),
                              alignment: AlignmentDirectional.centerStart,
                              padding: const EdgeInsetsDirectional.only(
                                start: 20,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  text(
                                    context.strings.localStatisticsOnly,
                                    14,
                                    weight: FontWeight.w500,
                                  ),
                                  text(
                                    context.strings.localStatisticsOnlyHint,
                                    12.5,
                                    color: p.muted,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      if (counting && c.phase == StatsSyncPhase.conflict) ...[
                        statusText(
                          context.strings.aSyncIsAlreadyRunningWaitingFor,
                        ),
                        const SizedBox(height: 12),
                      ],
                      Center(
                        child: found.isEmpty && !counting
                            ? action(
                                context.strings.scanAgain,
                                widget.discovery.loading
                                    ? null
                                    : widget.onRescan,
                              )
                            : action(
                                counting
                                    ? context.strings.counting
                                    : c.syncError != null
                                    ? context.strings.retry
                                    : context.strings.startCounting,
                                counting ? null : widget.onStart,
                              ),
                      ),
                      if (counting && c.firstSyncRunning) ...[
                        const SizedBox(height: 8),
                        Center(
                          child: LensTextLink(
                            label: context.strings.viewUsage,
                            onTap: widget.onEnter,
                          ),
                        ),
                      ],
                      if (!counting && found.isNotEmpty && denied.isNotEmpty)
                        Center(
                          child: action(
                            context.strings.scanAgain,
                            widget.discovery.loading ? null : widget.onRescan,
                          ),
                        ),
                      if (c.syncError != null) ...[
                        const SizedBox(height: 12),
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: Semantics(
                              liveRegion: true,
                              child: text(
                                c.syncError!,
                                12.5,
                                color: p['danger'],
                                align: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.lock_outline, size: 14, color: p.muted),
                          const SizedBox(width: 6),
                          Flexible(
                            child: text(
                              context.strings.readsLogsOnThisComputerAndLeaves,
                              12.5,
                              color: p.muted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingGlow extends CustomPainter {
  const _OnboardingGlow(this.clay);
  final Color clay;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, -size.height * .1);
    canvas.scale(1200, 500);
    canvas.drawCircle(
      Offset.zero,
      .7,
      Paint()
        ..shader = RadialGradient(
          colors: [clay.withValues(alpha: .09), clay.withValues(alpha: 0)],
        ).createShader(const Rect.fromLTRB(-.7, -.7, .7, .7)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OnboardingGlow oldDelegate) => clay != oldDelegate.clay;
}
