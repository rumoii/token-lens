import '../l10n/app_strings.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../stats_controller.dart';
import 'logic/comparison.dart';
import 'logic/detail_query.dart';
import 'logic/period.dart';
import 'logic/format.dart';
import 'logic/home_data.dart';
import 'logic/heatmap.dart';
import 'logic/chart.dart';
import 'logic/tool_order.dart';
import 'logic/tools.dart';
import 'theme/palette.dart';
import 'widgets/primitives.dart';
import 'widgets/empty_ledger.dart';
import 'widgets/sync_status.dart';
import 'widgets/session_usage.dart';
import 'widgets/charts.dart';
import 'widgets/date_range.dart';
import 'widgets/motion.dart';
import 'widgets/side_panel.dart';
import 'widgets/comparison_panel.dart';

class StatsHome extends StatefulWidget {
  const StatsHome({
    super.key,
    required this.controller,
    required this.onDetail,
    required this.onSessions,
    required this.onSources,
    required this.onSettings,
    this.onManageHidden,
    this.sidebarWidth = 0,
  });
  final StatsController controller;
  final ValueChanged<Map<String, String>> onDetail, onSessions;
  final VoidCallback onSources, onSettings;
  final VoidCallback? onManageHidden;
  final double sidebarWidth;
  @override
  State<StatsHome> createState() => _StatsHomeState();
}

class _StatsHomeState extends State<StatsHome> {
  String? highlight;
  bool trendCost = false;
  StatsController get c => widget.controller;
  LensPalette get p => LensPalette.of(context);
  bool get narrow => MediaQuery.sizeOf(context).width < 768;
  bool get large => MediaQuery.sizeOf(context).width >= 1024;
  String nt(num value) => tokenCount(value, unitSystem: c.unitSystem);
  Widget token(num? value, {TextStyle? style}) =>
      TokenText(value, unitSystem: c.unitSystem, style: style);
  Widget money(
    Object? value, {
    int? digits,
    TextStyle? style,
    bool animate = false,
  }) {
    Widget render(Object? amount) => MoneyText(
      amount,
      digits: digits,
      style: style,
      currency: c.preferences.currency,
      rate: rateFor(c.preferences.rates, c.preferences.currency),
    );
    final number = double.tryParse(value?.toString() ?? '');
    return animate && number != null
        ? TweenValue(value: number, builder: render)
        : render(value);
  }

  Widget delta(int value, StatsPeriod period) {
    final badge = LensBadge(
      percentage(value.abs() / 100),
      tone: value >= 0 ? 'clay' : 'ok',
      icon: value >= 0 ? Icons.arrow_upward : Icons.arrow_downward,
    );
    if (period.compare(c.clock()) == null) return badge;
    return LensFocusOutline(
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => openComparison(period),
        child: badge,
      ),
    );
  }

  void openComparison(StatsPeriod period) {
    final gateway = c.gateway.comparisonGateway;
    final previous = period.compare(c.clock(), context.strings);
    if (previous == null || gateway == null) return;
    final current = period.range(c.clock());
    final prior = (from: previous.from, to: previous.to);
    final title = context.strings.whatChangedFromPrevious;
    unawaited(
      showLensPanel(
        context,
        title: title,
        hint: comparisonSubtitle(current, prior, context.strings),
        icon: Icon(Icons.compare_arrows, size: 24, color: p['clay']),
        label: title,
        width: 500,
        sidebarInset: widget.sidebarWidth,
        body: Builder(
          builder: (panelContext) => ComparisonPanel(
            controller: c,
            gateway: gateway,
            current: current,
            previous: prior,
            onPick: (filter, value) {
              Navigator.of(panelContext).pop();
              widget.onDetail({
                ...Uri.splitQueryString(period.query),
                if (value != null && value.isNotEmpty)
                  filter: value
                else
                  'missing': filter,
                'dim': nextDim(filter),
              });
            },
          ),
        ),
      ),
    );
  }

  Widget link(String label, VoidCallback onTap) =>
      LensTextLink(label: label, onTap: onTap, arrow: true);
  Widget secHead(String title, String sub, {Widget? action}) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 0) * c.preferences.spacing,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: p.text(15, null, FontWeight.w600)),
              const SizedBox(height: 2),
              Text(sub, style: p.text(12.5, p.muted)),
            ],
          ),
        ),
        ?action,
      ],
    ),
  );
  Widget rowLink({required Widget child, VoidCallback? onTap, String? tool}) =>
      MouseRegion(
        onEnter: tool == null ? null : (_) => setState(() => highlight = tool),
        onExit: tool == null ? null : (_) => setState(() => highlight = null),
        child: LensFocusOutline(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: child,
          ),
        ),
      );
  Widget controls() => LensHeaderControls(
    children: [
      LensSegmented(
        options: {
          'overview': context.strings.overview,
          'detail': context.strings.breakdown,
        },
        value: 'overview',
        onChanged: (v) {
          if (v == 'detail') widget.onDetail({});
        },
        label: context.strings.view2,
      ),
      if (!c.emptyLedger)
        PeriodControl(
          period: c.period,
          now: c.clock(),
          onChanged: (v) => unawaited(c.setPeriod(v)),
        ),
    ],
  );
  Widget header(Widget summary) {
    final hour = c.clock().hour;
    final greet = hour < 6
        ? context.strings.stillUpLate
        : hour < 11
        ? context.strings.goodMorning
        : hour < 13
        ? context.strings.noonGreeting(hour)
        : hour < 18
        ? context.strings.goodAfternoon2
        : context.strings.goodEvening;
    return LensPageHeader(
      title: StatsSyncTitle(
        controller: c,
        title: Text(
          greet,
          style: p
              .serif(narrow ? 26 : 30, weight: FontWeight.w500)
              .copyWith(height: 1.25, letterSpacing: -.3),
        ),
      ),
      controls: controls(),
      description: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (c.firstSyncRunning)
            Text(
              context.strings.progressFirstHint,
              style: p.text(13, p.secondary),
            ),
          if (c.hiddenTools.isNotEmpty && widget.onManageHidden != null)
            StatsHiddenNotice(controller: c, onManage: widget.onManageHidden!),
          DefaultTextStyle(
            style: p.text(15, p.secondary).copyWith(height: 1.7),
            child: summary,
          ),
        ],
      ),
    );
  }

  Widget failure(String error, {bool sync = false}) => LensCard(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 16, color: p['danger']),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sync ? error : context.strings.couldNotLoadRequestFailed,
                style: p.text(12, null, FontWeight.w500),
              ),
              if (!sync) Text(error, style: p.text(12, p.muted)),
            ],
          ),
        ),
        LensButton(
          label: context.strings.retry,
          size: 'xs',
          variant: 'ghost',
          onPressed: c.busy
              ? null
              : () => unawaited(sync ? c.sync() : c.load()),
        ),
        if (sync) link(context.strings.viewDetails, widget.onSources),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final data = c.overview;
    final banner = <Widget>[
      if (c.fullSyncRunning || c.syncReceipt != null)
        StatsSyncBanner(controller: c, onSources: widget.onSources)
      else if (c.phase == StatsSyncPhase.idle &&
          c.syncError != null &&
          ![
            'failed',
            'abandoned',
          ].contains(c.overview?.sources.lastRun?.status))
        failure(c.syncError!, sync: true),
      if (c.error != null) failure(c.error!),
    ];
    if (data == null) {
      return Column(
        spacing: narrow ? 12 : 16,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...banner,
          header(const SizedBox(height: 16)),
          LensCard(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
            child: c.error == null
                ? const SkeletonLines(rows: 6)
                : const SizedBox.shrink(),
          ),
        ],
      );
    }
    final digest = digestPairs(data.pairs.groups, context.strings),
        totals = data.summary.totals;
    final rank = digest.rank, models = digest.models;
    final order = sortByToolOrder(
      rank.map((g) => g.id).toList(),
      sourceSequence(
        data.sources.sources.where((s) => !c.isHidden(s.source)).toList(),
      ),
    );
    final slots = assignToolColors(rank.map((g) => (g.id, g.tokens)), p);
    final period = data.period, now = c.clock();
    final compare = period.compare(now, context.strings);
    final buckets = buildBuckets(data.matrix.rows, data.axis, now);
    var comparison = compare?.label ?? '';
    int? cmp;
    final compared = data.comparison;
    if (compared != null) {
      cmp = deltaOf(
        compared.current.totals.grossTokens,
        compared.previous.totals.grossTokens,
      );
    } else if (period.period == 'today' && data.previousHours != null) {
      comparison = context.strings.theSameTimeYesterday;
      final cutoff =
          '${compare!.from}T${now.hour.toString().padLeft(2, '0')}:00:00';
      final prev = data.previousHours!.points
          .where((p) => p.bucket.compareTo(cutoff) <= 0)
          .fold<int>(0, (s, p) => s + p.grossTokens);
      cmp = deltaOf(
        data.matrix.rows.fold<int>(0, (s, p) => s + p.grossTokens),
        prev,
      );
    } else if (data.previous != null) {
      cmp = deltaOf(totals.grossTokens, data.previous!.totals.grossTokens);
    }
    Widget toolName(String id) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ToolTile(id, size: 16),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            toolOf(id).name,
            style: p.text(15, null, FontWeight.w700),
          ),
        ),
      ],
    );
    final emptyLedger = c.emptyLedger;
    final strings = context.strings;
    final periodLabel = period.period == 'custom'
        ? strings.selectedPeriodInSentence
        : period.inSentence(strings);
    String inSentence(String value) =>
        strings.isChinese ? value : value.toLowerCase();
    InlineSpan toolSpan(String id) => strings.isChinese
        ? WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: toolName(id),
          )
        : TextSpan(
            text: toolOf(id).name,
            style: p.text(15, null, FontWeight.w700),
          );
    final summary = <InlineSpan>[];
    if (totals.recordCount == 0) {
      summary.add(
        TextSpan(
          text: emptyLedger
              ? strings.afterSyncingYouLlSeeHowMany
              : strings.emptyPeriodHint(
                  inSentence(
                    strings.isChinese ? period.labelFor(strings) : periodLabel,
                  ),
                ),
        ),
      );
    } else {
      if (period.period == 'all') {
        final first = DateTime.tryParse(data.summary.activity.firstSeen ?? '')
            ?.toLocal();
        summary.add(
          TextSpan(
            text: strings.overviewTrackingSince(
              first == null
                  ? strings.theEarliestRecord
                  : strings.calendarDay(first.month, first.day),
            ),
          ),
        );
      } else if (cmp != null) {
        final similar = cmp.abs() < 10;
        final relation = similar
            ? strings.overviewComparisonEqualLink
            : strings.overviewComparisonOtherLink;
        final direction = cmp >= 50
            ? strings.overviewMuchHigher
            : cmp >= 10
            ? strings.overviewHigher
            : cmp <= -50
            ? strings.overviewMuchLower
            : cmp <= -10
            ? strings.overviewLower
            : strings.overviewSimilar;
        summary.addAll([
          TextSpan(
            text: strings.overviewComparisonLead(
              inSentence(periodLabel),
              inSentence(comparison),
              relation,
            ),
          ),
          TextSpan(
            text: direction,
            style: similar
                ? null
                : p.text(15, p[cmp >= 0 ? 'clay-ink' : 'ok'], FontWeight.w500),
          ),
          TextSpan(
            text: strings.overviewComparisonTail(
              relation,
              inSentence(comparison),
            ),
          ),
        ]);
      } else if (strings.isChinese || rank.isEmpty) {
        summary.add(TextSpan(text: periodLabel));
      }
      if (rank.isNotEmpty) {
        final most = rank.first.tokens / math.max(1, totals.grossTokens) >= .5;
        summary.add(
          TextSpan(
            text: most
                ? strings.overviewMajorityLead
                : strings.overviewTopToolLead,
          ),
        );
        summary.add(toolSpan(rank.first.id));
        if (most) summary.add(TextSpan(text: strings.overviewMajorityTail));
        if (rank.length > 1) {
          summary.add(TextSpan(text: strings.overviewSecondToolLead));
          summary.add(toolSpan(rank[1].id));
        }
      }
      if (strings.isChinese ||
          rank.isNotEmpty ||
          cmp == null && period.period != 'all') {
        summary.add(TextSpan(text: strings.overviewSentenceEnd));
      }
      if (compare != null && cmp == null) {
        summary.add(
          TextSpan(
            text: strings.noUsageRecordedFor0ToCompare(inSentence(comparison)),
            style: p.text(15, p.muted),
          ),
        );
      }
      if (projectChangeSentence(compared, strings, unitSystem: c.unitSystem)
          case final text?) {
        summary.add(TextSpan(text: strings.isChinese ? text : ' $text'));
      }
    }
    final yearMap = {
      for (final point in data.year.points)
        point.bucket.substring(0, 10): point.grossTokens,
    };
    final yearKeys = bucketKeys('day', (
      from: dayKey(DateTime(now.year, now.month, now.day - 364)),
      to: dayKey(now),
    ), now);
    var streak = 0, best = 0;
    for (final key in yearKeys) {
      streak = (yearMap[key] ?? 0) > 0 ? streak + 1 : 0;
      best = math.max(best, streak);
    }
    final active = yearKeys.where((key) => (yearMap[key] ?? 0) > 0).length;
    return Column(
      spacing: narrow ? 12 : 16,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c.loading)
          Semantics(
            label: context.strings.loading,
            child: SizedBox(
              height: 2,
              child: LinearProgressIndicator(
                value: MediaQuery.disableAnimationsOf(context) ? .33 : null,
                color: p['clay'],
                backgroundColor: LensPalette.transparent,
              ),
            ),
          ),
        ...banner,
        header(Text.rich(TextSpan(children: summary))),
        if (emptyLedger)
          EmptyLedgerCard(controller: c, onTools: widget.onSources)
        else if (totals.recordCount == 0)
          LensCard(
            child: EmptyState(
              title: strings.noUsageForPeriod(period.labelFor(strings)),
              hint: strings.usageAppearsHereAfterTheToolWrites,
              action: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  LensButton(
                    label: strings.viewThisMonth,
                    size: 'sm',
                    onPressed: () =>
                        unawaited(c.setPeriod(const StatsPeriod('month'))),
                  ),
                  LensButton(
                    label: strings.viewAll,
                    size: 'sm',
                    onPressed: () =>
                        unawaited(c.setPeriod(const StatsPeriod('all'))),
                  ),
                  if (compare != null)
                    LensTextLink(
                      label: strings.seeWhatChanged,
                      onTap: () => openComparison(period),
                    ),
                ],
              ),
            ),
          )
        else ...[
          LensEnter(
            index: 0,
            child: hero(data, rank, order, slots, cmp, comparison),
          ),
          kpis(data, buckets, best),
          pair(
            LensEnter(index: 5, child: trend(data, buckets, order, slots)),
            LensEnter(index: 6, child: modelList(data, models)),
          ),
          pair(
            c.resourceErrors.containsKey('year') ||
                    c.resourceErrors.containsKey('yearTools')
                ? failure(
                    c.resourceErrors['year'] ?? c.resourceErrors['yearTools']!,
                  )
                : LensEnter(
                    index: 7,
                    child: heatCard(data, yearMap, active, best),
                  ),
            c.resourceErrors.containsKey('recent')
                ? failure(c.resourceErrors['recent']!)
                : LensEnter(index: 8, child: recent(data)),
            alignStart: true,
          ),
        ],
      ],
    );
  }

  Widget hero(
    StatsHomeData data,
    List<ToolUsage> rank,
    List<String> order,
    Map<String, Color> slots,
    int? cmp,
    String comparison,
  ) {
    final total = data.summary.totals, by = {for (final g in rank) g.id: g};
    final allUnpriced = total.costUsd == null && total.recordCount > 0;
    final hasUnpriced = total.unpricedRecords > 0;
    final pricingNote = allUnpriced
        ? context.strings.thereAreNoPricesForTheModels
        : context.strings.atListPrices0RecordWithoutA(
            toDisplayNumber(total.unpricedRecords),
          );
    final value = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          data.period.period == 'all'
              ? context.strings.totalUsage
              : context.strings.periodUsage(
                  data.period.labelFor(context.strings),
                ),
          style: p.text(13, p.muted),
        ),
        const SizedBox(height: 6),
        Tooltip(
          message:
              '${toDisplayNumber(total.grossTokens)} ${context.strings.tokenUnit}',
          child: TweenValue(
            value: total.grossTokens,
            builder: (value) {
              final number = nt(value),
                  match = RegExp(r'^(-?[\d,.]+)(万亿|亿|万|[KMBT])?$')
                      .firstMatch(number);
              return Text.rich(
                TextSpan(
                  style: p.serif(narrow ? 44 : 52),
                  children: [
                    TextSpan(text: match?[1] ?? number),
                    TextSpan(
                      text: match?[2] ?? '',
                      style: TextStyle(
                        fontSize: (narrow ? 44 : 52) * .6,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                    TextSpan(
                      text: ' ${context.strings.tokenUnit}',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                        color: p.secondary,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (total.grossTokens > 0 && total.recordCount > 0)
          Text(
            '= ${toDisplayNumber(total.grossTokens)} ${context.strings.tokenUnit}',
            key: const Key('home-conversion'),
            style: p.text(13, p.muted),
          ),
        if (comparison.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (cmp != null) delta(cmp, data.period),
              if (cmp != null)
                Text(
                  context.strings.vs0(comparison),
                  style: p.text(12.5, p.muted),
                ),
              LensTextLink(
                label: context.strings.seeWhatChanged,
                onTap: () => openComparison(data.period),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              context.strings.estimatedCostPrefix,
              style: p.text(15, p.secondary),
            ),
            money(total.costUsd, style: p.serif(22), animate: true),
          ],
        ),
        const SizedBox(height: 10),
        if (allUnpriced || hasUnpriced)
          Tooltip(
            message: context.strings.recordsWithoutPricesAreExcludedFromCost,
            child: LensTextLink(
              label: pricingNote,
              fontSize: 12.5,
              onTap: widget.onSettings,
              wrap: true,
            ),
          )
        else
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                flex: 2,
                child: Text(
                  context.strings.estimatedAtListPrices,
                  style: p.text(12.5, p.muted),
                ),
              ),
              Text(' · ', style: p.text(12.5, p.muted)),
              Flexible(
                child: LensTextLink(
                  label: context.strings.howPricesWork,
                  fontSize: 12.5,
                  onTap: widget.onSettings,
                ),
              ),
            ],
          ),
      ],
    );
    String percent(int n) {
      final ratio = n / math.max(1, total.grossTokens);
      return percentage(ratio);
    }

    final distribution = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Semantics(
          label: context.strings.usageByTool,
          image: true,
          child: LensGrow(
            reveal: true,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Row(
                children: [
                  for (final key in order)
                    Expanded(
                      flex: math.max(1, by[key]!.tokens),
                      child: AnimatedOpacity(
                        opacity: highlight == null || highlight == key
                            ? 1
                            : .35,
                        duration: LensTokens.hover,
                        child: Container(
                          height: 12,
                          margin: EdgeInsets.only(
                            right: key == order.last ? 0 : 2,
                          ),
                          color: slots[key],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        for (final g in rank.take(5))
          rowLink(
            tool: g.id,
            onTap: () => widget.onDetail({'tool': g.id, 'dim': 'model'}),
            child: SizedBox(
              height: 42,
              child: LayoutBuilder(
                builder: (context, box) => Row(
                  children: [
                    ToolTile(g.id, size: 28),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: narrow ? math.max(0, box.maxWidth - 168) : 108.0,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            toolOf(g.id).name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: p.text(14, null, FontWeight.w500),
                          ),
                          Text(
                            context.strings.modelCount(g.models),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: p.text(12, p.muted),
                          ),
                        ],
                      ),
                    ),
                    if (!narrow) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 180,
                        child: bar(
                          g.tokens / math.max(1, rank.first.tokens),
                          slots[g.id]!,
                          height: 6,
                          delay: 230 + rank.indexOf(g) * 57,
                        ),
                      ),
                    ],
                    const SizedBox(width: 12),
                    SizedBox(
                      width: narrow ? 64 : 72,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TweenValue(
                          value: g.tokens,
                          builder: (n) => token(n, style: p.text(13.5)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: narrow ? 40 : 46,
                      child: Text(
                        percent(g.tokens),
                        textAlign: TextAlign.right,
                        style: p.text(12.5, p.muted),
                      ),
                    ),
                    if (!narrow) ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 72,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: money(
                            g.costUsd,
                            style: p.text(13, p.secondary),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        if (rank.length > 5)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              context.strings.remainingTools(
                rank
                    .skip(5)
                    .map((g) => toolOf(g.id).name)
                    .join(context.strings.listSeparator),
                percent(rank.skip(5).fold<int>(0, (s, g) => s + g.tokens)),
              ),
              style: p.text(12.5, p.muted),
            ),
          ),
      ],
    );
    return LensCard(
      key: const Key('home-hero'),
      padding:
          const EdgeInsets.fromLTRB(18, 22, 18, 20) * c.preferences.spacing,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 155),
        child: large && MediaQuery.sizeOf(context).width >= 1200
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 300, child: value),
                  const SizedBox(width: 28),
                  Expanded(child: distribution),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [value, const SizedBox(height: 20), distribution],
              ),
      ),
    );
  }

  Widget bar(double ratio, Color color, {double height = 5, int delay = 230}) =>
      ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: height,
          color: p['fill-hover'],
          alignment: Alignment.centerLeft,
          child: LensGrow(
            delay: delay,
            child: FractionallySizedBox(
              widthFactor: ratio.clamp(0, 1),
              child: Container(color: color),
            ),
          ),
        ),
      );

  Widget kpis(StatsHomeData data, List<TrendBucket> buckets, int streak) {
    final days = data.days.points,
        totals = data.summary.totals,
        now = c.clock(),
        period = data.period;
    final active = days.where((d) => d.grossTokens > 0).length;
    final perDay =
        days.fold<int>(0, (s, d) => s + d.grossTokens) / math.max(1, active);
    final prevDays = data.previousDays?.points;
    final prevPerDay = prevDays == null
        ? null
        : prevDays.fold<int>(0, (s, d) => s + d.grossTokens) /
              math.max(1, prevDays.where((d) => d.grossTokens > 0).length);
    final sessions = data.summary.activity.sessions,
        prevSessions = data.previous?.activity.sessions;
    final numStyle = p
        .serif(large ? 26 : 22)
        .copyWith(height: 1.2, letterSpacing: -.26);
    Widget hint(List<Widget> children) => Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          if (i == children.length - 1)
            Flexible(child: children[i])
          else
            children[i],
        ],
      ],
    );
    Widget card(String title, Widget value, Widget hint, {Widget? spark}) =>
        LensCard(
          padding:
              const EdgeInsets.fromLTRB(18, 16, 18, 14) * c.preferences.spacing,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title.startsWith(context.strings.cache)
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            context.strings.cacheSavings,
                            style: p.text(13, p.muted),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Tooltip(
                          message:
                              context.strings.whenRepeatedContextHitsTheCacheIt,
                          child: Container(
                            width: 15,
                            height: 15,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                width: LensPalette.hairline(context),
                                color: p['line-strong'],
                              ),
                            ),
                            child: Text(
                              '?',
                              style: p.text(10, p.muted).copyWith(height: 1),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Text(title, style: p.text(13, p.muted)),
              const SizedBox(height: 4),
              if (spark == null)
                value
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(flex: 3, child: value),
                    const SizedBox(width: 12),
                    Flexible(
                      flex: 2,
                      child: SizedBox(width: 76, height: 28, child: spark),
                    ),
                  ],
                ),
              const SizedBox(height: 4),
              hint,
            ],
          ),
        );
    final items = <Widget>[];
    if (period.period == 'today' && data.axis.granularity == 'hour') {
      final live = buckets.where((b) => !b.future).toList()
        ..sort((a, b) => b.total - a.total);
      final busy = live.isEmpty ? null : live.first;
      final h = busy == null ? 0 : int.parse(busy.bucket.substring(11, 13));
      items.add(
        card(
          context.strings.busiestHour,
          Text.rich(
            TextSpan(
              text: busy == null ? '—' : '$h:00',
              style: numStyle,
              children: busy == null
                  ? []
                  : [
                      TextSpan(
                        text: ' – ${h + 1}:00',
                        style: p.text(15, p.muted),
                      ),
                    ],
            ),
          ),
          Text(
            keepTailTogether(
              busy == null
                  ? ''
                  : context.strings.peakHourShare(
                      nt(busy.total),
                      percentage(busy.total / math.max(1, totals.grossTokens)),
                    ),
            ),
            style: p.text(12, p.muted),
          ),
        ),
      );
      final current =
          buckets
              .where((b) => b.bucket == nowBucketKey('hour', now))
              .firstOrNull
              ?.total ??
          0;
      final yesterday = data.previousHours?.points
          .where(
            (b) => b.bucket.endsWith(
              'T${now.hour.toString().padLeft(2, '0')}:00:00',
            ),
          )
          .firstOrNull
          ?.grossTokens;
      final change = deltaOf(
        current,
        yesterday == null ? null : yesterday * now.minute / 60,
      );
      items.add(
        card(
          context.strings.thisHour,
          token(current, style: numStyle),
          hint([
            if (change != null) delta(change, period),
            Text(
              context.strings.thisHourSoFar(
                now.hour,
                change != null ? context.strings.vsThisTimeYesterday : '',
              ),
              style: p.text(12, p.muted),
            ),
          ]),
        ),
      );
    } else {
      final change = deltaOf(perDay, prevPerDay);
      final range = period.range(now),
          map = {for (final d in days) d.bucket: d.grossTokens};
      final keys = range.from == null
          ? days.map((d) => d.bucket).toList()
          : bucketKeys('day', (
              from: range.from,
              to: (range.to ?? '').compareTo(dayKey(now)) > 0
                  ? dayKey(now)
                  : range.to,
            ), now);
      items.add(
        card(
          context.strings.dailyAverage,
          TweenValue(
            value: perDay,
            builder: (n) => token(n, style: numStyle),
          ),
          hint([
            if (change != null) delta(change, period),
            Text(context.strings.onDaysWithUsage, style: p.text(12, p.muted)),
          ]),
          spark: keys.length < 2
              ? null
              : CustomPaint(
                  painter: _SparkPainter([
                    for (final key in keys) map[key] ?? 0,
                  ], p),
                ),
        ),
      );
    }
    final sessionDelta = deltaOf(sessions, prevSessions);
    items.add(
      card(
        context.strings.sessions,
        TweenValue(
          value: sessions,
          builder: (n) => Text('${n.round()}', style: numStyle),
        ),
        hint([
          if (sessionDelta != null) delta(sessionDelta, period),
          Text(
            context.strings.average0PerSession(
              nt(totals.grossTokens / math.max(1, sessions)),
            ),
            style: p.text(12, p.muted),
          ),
        ]),
      ),
    );
    if (period.period != 'today') {
      final elapsed = period.elapsedDays(now, data.summary.activity.firstSeen),
          used = {for (final d in days) d.bucket: d.grossTokens};
      items.add(
        card(
          context.strings.activeDays,
          TweenValue(
            value: active,
            builder: (n) => Text.rich(
              TextSpan(
                text: '${n.round()}',
                style: numStyle,
                children: [
                  TextSpan(
                    text: context.strings.outOfDays(elapsed),
                    style: p.text(15, p.muted),
                  ),
                ],
              ),
            ),
          ),
          period.period == 'week'
              ? Wrap(
                  spacing: 4,
                  children: [
                    for (final key in bucketKeys('day', (
                      from: data.axis.from,
                      to: data.axis.to,
                    ), now))
                      Tooltip(
                        message:
                            '$key${key.compareTo(dayKey(now)) > 0
                                ? context.strings.upcoming
                                : (used[key] ?? 0) > 0
                                ? ''
                                : context.strings.noUsage}',
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: key.compareTo(dayKey(now)) > 0
                                ? null
                                : (used[key] ?? 0) > 0
                                ? p['clay']
                                : p['fill-active'],
                            border: key.compareTo(dayKey(now)) > 0
                                ? Border.all(
                                    width: LensPalette.hairline(context),
                                    color: p['line-strong'],
                                  )
                                : null,
                          ),
                        ),
                      ),
                  ],
                )
              : Text(
                  keepTailTogether(context.strings.longestStreakDays(streak)),
                  style: p.text(12, p.muted),
                ),
        ),
      );
    }
    final ratio = data.summary.activity.cacheHitRatio;
    items.add(
      card(
        context.strings.cacheSavings2,
        c.resourceErrors.containsKey('pricing')
            ? failure(c.resourceErrors['pricing']!)
            : money(
                cacheSavings(data.pairs.groups, data.pricing),
                digits: 0,
                style: numStyle,
                animate: true,
              ),
        c.resourceErrors.containsKey('pricing')
            ? const SizedBox.shrink()
            : Tooltip(
                message: context.strings.whenRepeatedContextHitsTheCacheIt,
                child: Text(
                  ratio == null
                      ? '—'
                      : context.strings.cacheInputShare(percentage(ratio)),
                  style: p.text(12, p.muted),
                ),
              ),
      ),
    );
    return Column(
      children: [
        for (var start = 0; start < items.length; start += large ? 4 : 2) ...[
          if (start > 0) const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (
                  var i = start;
                  i < math.min(items.length, start + (large ? 4 : 2));
                  i++
                ) ...[
                  if (i > start) SizedBox(width: large ? 16 : 12),
                  Expanded(
                    child: LensEnter(index: i + 1, child: items[i]),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget pair(Widget left, Widget right, {bool alignStart = false}) =>
      MediaQuery.sizeOf(context).width >= 1200
      ? (alignStart
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 13, child: left),
                  const SizedBox(width: 16),
                  Expanded(flex: 7, child: right),
                ],
              )
            : IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 2, child: left),
                    const SizedBox(width: 16),
                    Expanded(child: right),
                  ],
                ),
              ))
      : Column(
          spacing: narrow ? 12 : 16,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [left, right],
        );
  Widget trend(
    StatsHomeData data,
    List<TrendBucket> usageBuckets,
    List<String> order,
    Map<String, Color> slots,
  ) {
    final buckets = trendCost
        ? buildBuckets(data.matrix.rows, data.axis, c.clock(), cost: true)
        : usageBuckets;
    final granularity = data.axis.granularity,
        unit = data.axis.granularity == 'hour'
            ? context.strings.hour
            : data.axis.granularity == 'month'
            ? context.strings.month
            : context.strings.day;
    final unallocated = data.matrix.unallocated?.grossTokens ?? 0;
    return LensCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          secHead(
            context.strings.trend,
            context.strings.trendWithAverageHint(
              unit,
              granularity == 'hour'
                  ? ''
                  : context.strings.selectABarForThat0S(unit),
            ),
            action: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                TrendMetricControl(
                  key: const Key('trend-metric'),
                  cost: trendCost,
                  onChanged: (value) => setState(() => trendCost = value),
                ),
                link(context.strings.viewBreakdown, () => widget.onDetail({})),
              ],
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.fromLTRB(18, 14, 18, 18) *
                c.preferences.spacing,
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    children: [
                      for (final key in order.take(8))
                        MouseRegion(
                          onEnter: (_) => setState(() => highlight = key),
                          onExit: (_) => setState(() => highlight = null),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(
                                  color: slots[key],
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                toolOf(key).name,
                                style: p.text(12, p.secondary),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                TrendChart(
                  buckets: buckets,
                  order: order,
                  slots: slots,
                  granularity: granularity,
                  now: c.clock(),
                  weekdays: data.period.weekdays,
                  costMode: trendCost,
                  highlight: highlight,
                  onPick: granularity == 'hour'
                      ? null
                      : (key) =>
                            widget.onDetail({'bucket': key, 'dim': 'tool'}),
                  unitSystem: c.unitSystem,
                  currency: c.preferences.currency,
                  rate: rateFor(c.preferences.rates, c.preferences.currency),
                ),
                if (trendCost && data.summary.totals.unpricedRecords > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      context.strings.trendUnpricedNote,
                      style: p.text(12, p.muted),
                    ),
                  ),
                if (unallocated > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      context.strings.chartUnallocatedUsage(
                        nt(unallocated),
                        unit,
                        unit,
                      ),
                      style: p.text(12.5, p.muted),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget modelList(StatsHomeData data, List<ModelUsage> models) => LensCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        secHead(
          context.strings.topModels,
          context.strings.topFiveModels(
            data.period.period == 'all'
                ? context.strings.allTime2
                : data.period.labelFor(context.strings),
          ),
          action: link(
            context.strings.all,
            () => widget.onDetail({'dim': 'model'}),
          ),
        ),
        Padding(
          padding:
              const EdgeInsets.fromLTRB(18, 14, 18, 18) * c.preferences.spacing,
          child: Column(
            children: [
              for (final (i, model) in models.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: rowLink(
                    onTap: model.name == context.strings.unknownModel
                        ? null
                        : () => widget.onDetail({'model': model.name}),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: 6) *
                          c.preferences.spacing,
                      child: Column(
                        children: [
                          Row(
                            children: [
                              ToolTile(model.topTool, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Tooltip(
                                  message: model.name,
                                  child: Text(
                                    model.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: p.text(13, null, FontWeight.w500),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              token(
                                model.tokens,
                                style: p.text(13, p.secondary),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 38,
                                child: Text(
                                  percentage(
                                    model.tokens /
                                        math.max(
                                          1,
                                          data.summary.totals.grossTokens,
                                        ),
                                  ),
                                  textAlign: TextAlign.right,
                                  style: p.text(13, p.muted),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          bar(
                            model.tokens / math.max(1, models.first.tokens),
                            p.category(i + 1),
                            delay: 230 + i * 57,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget heatCard(
    StatsHomeData data,
    Map<String, int> map,
    int active,
    int streak,
  ) {
    final days = heatmapDays(c.clock(), narrow, c.preferences.weekStartsOn);
    final scale = heatScale(days.map((day) => map[dayKey(day)] ?? 0));
    String rangeLabel(int level) {
      final (from, to) = scale.range(level);
      if (level == 0) return '0 ${context.strings.tokenUnit}';
      if (to == null) return context.strings.heatTokensAndAbove(nt(from));
      if (to < from) return '—';
      return context.strings.heatTokenRange(nt(from), nt(to));
    }

    final entries = map.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final busy = entries.isEmpty
        ? null
        : (entries.toList()..sort((a, b) => b.value - a.value)).first;
    final first = entries.isEmpty ? null : DateTime.parse(entries.first.key),
        newcomer = active < 30;
    final top =
        (data.yearTools.groups.where((g) => g.key != null).toList()
              ..sort((a, b) => b.grossTokens - a.grossTokens))
            .firstOrNull;
    final busyDay = busy == null ? null : DateTime.parse(busy.key);
    final cells = <Widget>[];
    Widget cell(String title, Widget value, Widget hint) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: p.text(12, p.muted)),
          const SizedBox(height: 2),
          value,
          hint,
        ],
      ),
    );
    cells.add(
      cell(
        newcomer ? context.strings.totalSoFar : context.strings.thisYearSTotal,
        token(
          data.yearTools.totals.grossTokens,
          style: p.text(16, null, FontWeight.w600),
        ),
        Wrap(
          children: [
            Text(
              context.strings.estimatedCostPrefix,
              style: p.text(12, p.muted),
            ),
            money(
              data.yearTools.totals.costUsd,
              digits: 0,
              style: p.text(12, p.muted),
            ),
          ],
        ),
      ),
    );
    cells.add(
      cell(
        context.strings.busiestDay,
        Text(
          busyDay == null
              ? '—'
              : context.strings.calendarDay(busyDay.month, busyDay.day),
          style: p.text(16, null, FontWeight.w600),
        ),
        Text(
          busy == null ? '' : '${nt(busy.value)} ${context.strings.tokenUnit}',
          style: p.text(12, p.muted),
        ),
      ),
    );
    cells.add(
      cell(
        context.strings.longestStreak,
        Text(
          context.strings.dayCount(streak),
          style: p.text(16, null, FontWeight.w600),
        ),
        Text(
          newcomer && streak == active
              ? context.strings.activeEveryDaySinceTrackingBegan
              : context.strings.activeDayCount(active),
          style: p.text(12, p.muted),
        ),
      ),
    );
    cells.add(
      cell(
        context.strings.mostUsed,
        top == null
            ? const Text('—')
            : Row(
                children: [
                  ToolTile(top.key!, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      toolOf(top.key!).name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: p.text(16, null, FontWeight.w600),
                    ),
                  ),
                ],
              ),
        Text(
          top == null
              ? ''
              : context.strings.shareOfTotal(
                  percentage(
                    top.grossTokens /
                        math.max(1, data.yearTools.totals.grossTokens),
                  ),
                ),
          style: p.text(12, p.muted),
        ),
      ),
    );
    return LensCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          secHead(
            narrow ? context.strings.last20Weeks : context.strings.pastYear,
            context.strings.eachSquareIsADayDarkerSquares,
          ),
          Padding(
            padding:
                const EdgeInsets.fromLTRB(18, 14, 18, 18) *
                c.preferences.spacing,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Heatmap(
                  weekStartsOn: c.preferences.weekStartsOn,
                  values: map,
                  now: c.clock(),
                  narrow: narrow,
                  unitSystem: c.unitSystem,
                  scale: scale,
                ),
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: newcomer
                                ? context.strings.yearNewcomerLead(
                                    first == null
                                        ? ''
                                        : context.strings.calendarDay(
                                            first.month,
                                            first.day,
                                          ),
                                  )
                                : context.strings.yearActivityLead,
                          ),
                          TextSpan(
                            text: '\u2060$active\u2060',
                            style: p.text(12, p.ink, FontWeight.w700),
                          ),
                          TextSpan(
                            text: keepTailTogether(
                              newcomer
                                  ? context.strings.yearActiveDaysTail(active)
                                  : context.strings.yearActiveDaysAndStreakTail(
                                      active,
                                      streak,
                                    ),
                            ),
                          ),
                        ],
                      ),
                      style: p.text(12, p.muted),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(context.strings.less, style: p.text(12, p.muted)),
                        for (var level = 0; level <= 4; level++)
                          Tooltip(
                            message: rangeLabel(level),
                            child: Container(
                              width: 11,
                              height: 11,
                              margin: const EdgeInsets.only(left: 3),
                              decoration: BoxDecoration(
                                color: p['heat-$level'],
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        const SizedBox(width: 3),
                        Text(context.strings.more, style: p.text(12, p.muted)),
                      ],
                    ),
                  ],
                ),
                if (data.yearTools.totals.grossTokens > 0) ...[
                  const SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      color: p['fill-hover'],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        for (var start = 0; start < 4; start += narrow ? 2 : 4)
                          IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (
                                  var i = start;
                                  i < math.min(4, start + (narrow ? 2 : 4));
                                  i++
                                )
                                  Expanded(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border(
                                          left: i > start
                                              ? BorderSide(
                                                  width: LensPalette.hairline(
                                                    context,
                                                  ),
                                                  color: p['line-soft'],
                                                )
                                              : BorderSide.none,
                                          top: start > 0
                                              ? BorderSide(
                                                  width: LensPalette.hairline(
                                                    context,
                                                  ),
                                                  color: p['line-soft'],
                                                )
                                              : BorderSide.none,
                                        ),
                                      ),
                                      child: cells[i],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget recent(StatsHomeData data) => LensCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        secHead(
          data.period.period == 'all'
              ? context.strings.recentSessions
              : context.strings.sessions0(
                  sessionPeriodLabel(data.period, context.strings),
                ),
          data.period.period == 'all'
              ? context.strings.aSessionIsATaskInAn
              : context.strings.sortedByUsageInThisPeriod,
        ),
        Padding(
          padding:
              const EdgeInsets.fromLTRB(18, 8, 18, 18) * c.preferences.spacing,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in data.recent.items)
                rowLink(
                  onTap: () => widget.onSessions({
                    ...Uri.splitQueryString(data.period.query),
                    'source': item.source,
                    'session': item.sessionId,
                  }),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 9) *
                        c.preferences.spacing,
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final stacked = box.maxWidth < 330;
                        final amounts = Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${data.period.period == 'all' ? context.strings.total : sessionPeriodLabel(data.period, context.strings)} ${nt(item.grossTokens)}',
                              maxLines: 1,
                              style: p.text(13, null, FontWeight.w600),
                            ),
                            if (item.cumulative.grossTokens != item.grossTokens)
                              Text(
                                context.strings.total0(
                                  nt(item.cumulative.grossTokens),
                                ),
                                maxLines: 1,
                                style: p.text(11.5, p.muted),
                              ),
                          ],
                        );
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ToolTile(item.source, size: 28),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  LayoutBuilder(
                                    builder: (context, nameBox) => Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        ConstrainedBox(
                                          constraints: BoxConstraints(
                                            maxWidth: nameBox.maxWidth,
                                          ),
                                          child: Tooltip(
                                            message:
                                                item.projectKey ??
                                                toolOf(item.source).name,
                                            child: Text(
                                              item.projectKey
                                                      ?.split(RegExp(r'[/\\]'))
                                                      .where(
                                                        (s) => s.isNotEmpty,
                                                      )
                                                      .lastOrNull ??
                                                  context
                                                      .strings
                                                      .noProjectLogged,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: p.text(
                                                13.5,
                                                null,
                                                FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                        ),
                                        if (sessionStartedBefore(
                                          item.startedAt,
                                          data.period,
                                          c.clock(),
                                          offsetMinutes: data
                                              .recent
                                              .snapshot
                                              .filters
                                              .offsetMinutes,
                                        ))
                                          SessionStartChip(
                                            startedAt: item.startedAt,
                                            now: c.clock(),
                                            offsetMinutes: data
                                                .recent
                                                .snapshot
                                                .filters
                                                .offsetMinutes,
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 2,
                                    children: [
                                      Text(
                                        toolOf(item.source).name,
                                        maxLines: 1,
                                        style: p.text(12, p.muted),
                                      ),
                                      Text(
                                        item.requestCount == null &&
                                                item.cumulative.requestCount !=
                                                    null
                                            ? context
                                                  .strings
                                                  .noIndividualRequestsInThisPeriod
                                            : item.hasCumulative &&
                                                  item
                                                          .cumulative
                                                          .requestCount ==
                                                      null
                                            ? context
                                                  .strings
                                                  .onlyASessionTotalIsLoggedCounted
                                            : requestText(
                                                item.requestCount,
                                                strings: context.strings,
                                              ),
                                        maxLines: 1,
                                        softWrap: false,
                                        style: p.text(12, p.muted),
                                      ),
                                    ],
                                  ),
                                  if (stacked) ...[
                                    const SizedBox(height: 4),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: amounts,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (!stacked) ...[
                              const SizedBox(width: 8),
                              amounts,
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
              link(
                context.strings.viewAllSessions,
                () =>
                    widget.onSessions(Uri.splitQueryString(data.period.query)),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.p);
  final List<int> values;
  final LensPalette p;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    final points = sparkPoints(values, size.width, size.height);
    for (var i = 0; i < points.length; i++) {
      final x = points[i].x, y = points[i].y;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = p['clay']
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) => true;
}
