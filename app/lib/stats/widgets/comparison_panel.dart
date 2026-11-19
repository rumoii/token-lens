import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../stats_controller.dart';
import '../../stats_gateway.dart';
import '../logic/comparison.dart';
import '../logic/format.dart';
import '../logic/home_data.dart';
import '../logic/period.dart';
import '../theme/palette.dart';
import 'primitives.dart';
import 'resource.dart';

class ComparisonPanel extends StatefulWidget {
  const ComparisonPanel({
    super.key,
    required this.controller,
    required this.gateway,
    required this.current,
    required this.previous,
    required this.onPick,
  });

  final StatsController controller;
  final StatsComparisonGateway gateway;
  final DayRange current, previous;
  final void Function(String filter, String? value) onPick;

  @override
  State<ComparisonPanel> createState() => _ComparisonPanelState();
}

class _ComparisonPanelState extends State<ComparisonPanel> {
  late final data = LensResource<StatsComparison>(() {
    if (mounted) setState(() {});
  });
  String by = 'project';
  bool cost = false, expanded = false;

  void refresh() {
    final c = widget.controller;
    StatsFilter filter(DayRange range) =>
        c.visibleFilter(StatsFilter(from: range.from, to: range.to));
    final dimension = by;
    data.read(
      (dimension, c.ledgerVersion, c.hiddenScope),
      () => widget.gateway.comparison(
        dimension,
        filter(widget.current),
        filter(widget.previous),
      ),
      retainData: false,
    );
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(refresh);
    refresh();
  }

  @override
  void dispose() {
    widget.controller.removeListener(refresh);
    data.dispose();
    super.dispose();
  }

  String tokens(int n) =>
      tokenCount(n, unitSystem: widget.controller.unitSystem);

  String amount(int micros) {
    final prefs = widget.controller.preferences;
    return usdCurrency(
      microsUsd(micros),
      decimals: micros > 0 && micros < 10000 ? 4 : 2,
      currency: prefs.currency,
      rate: rateFor(prefs.rates, prefs.currency),
    );
  }

  Widget values(StatsComparison comparison) {
    final s = context.strings, p = LensPalette.of(context);
    final current = comparison.current.totals,
        prior = comparison.previous.totals;
    final unpriced = current.unpricedRecords > 0 || prior.unpricedRecords > 0;
    final tokenDelta = current.grossTokens - prior.grossTokens;
    final costDelta = (current.costMicros ?? 0) - (prior.costMicros ?? 0);
    String percent(int difference, int? previous) =>
        previous == null || previous == 0
        ? ''
        : ' · ${difference.sign > 0
              ? '+'
              : difference.sign < 0
              ? '−'
              : ''}${percentage(difference.abs() / previous)}';
    Widget block(
      String title,
      String usage,
      String estimated, {
      bool changed = false,
    }) => Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: p.text(12, p.muted)),
            const SizedBox(height: 5),
            Text(usage, style: p.text(14, p.ink, FontWeight.w600)),
            Text(estimated, style: p.text(12, p.secondary)),
            if (changed && unpriced) ...[
              const SizedBox(height: 4),
              Tooltip(
                message: s.comparisonUnpricedNote,
                child: Text(s.partlyUnpriced, style: p.text(11, p['clay-ink'])),
              ),
            ],
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            block(
              s.comparisonCurrent,
              '${tokens(current.grossTokens)} ${s.tokenUnit}',
              amount(current.costMicros ?? 0),
            ),
            block(
              s.comparisonPrevious,
              '${tokens(prior.grossTokens)} ${s.tokenUnit}',
              amount(prior.costMicros ?? 0),
            ),
            block(
              s.comparisonChange,
              '${signedValue(tokenDelta, tokens)}${percent(tokenDelta, prior.grossTokens)}',
              '${signedValue(costDelta, amount)}${percent(costDelta, prior.costMicros)}',
              changed: true,
            ),
          ],
        ),
        if (unpriced)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(s.comparisonUnpricedNote, style: p.text(12, p.muted)),
          ),
      ],
    );
  }

  Widget list(StatsComparison comparison) {
    final s = context.strings, p = LensPalette.of(context);
    final changes = groupChanges(comparison);
    if (changes.isEmpty) {
      return EmptyState(title: s.noUsageInEitherPeriod);
    }
    changes.sort((a, b) {
      final compare = b
          .delta(cost: cost)
          .abs()
          .compareTo(a.delta(cost: cost).abs());
      return compare == 0 ? (a.key ?? '').compareTo(b.key ?? '') : compare;
    });
    final max = changes.first.delta(cost: cost).abs();
    final peers = changes.map((row) => row.key);
    final format = cost ? amount : tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(s.sortedBySizeOfChange, style: p.text(12, p.muted)),
        const SizedBox(height: 8),
        for (final row in expanded ? changes : changes.take(5))
          LensFocusOutline(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => widget.onPick(by == 'source' ? 'tool' : by, row.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 5,
                  children: [
                    Row(
                      spacing: 8,
                      children: [
                        Expanded(
                          child: Text(
                            comparisonGroupName(by, row.key, peers, s),
                            overflow: TextOverflow.ellipsis,
                            style: p.text(13, p.ink, FontWeight.w600),
                          ),
                        ),
                        if (row.badge(s) case final badge?)
                          Text(badge, style: p.text(11, p.muted)),
                        Text(
                          signedValue(row.delta(cost: cost), format),
                          style: p.text(13, p.ink, FontWeight.w600),
                        ),
                      ],
                    ),
                    Text(
                      '${format(row.value(row.previous, cost: cost))} → ${format(row.value(row.current, cost: cost))}',
                      style: p.text(12, p.muted),
                    ),
                    LinearProgressIndicator(
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(8),
                      value: max == 0 ? 0 : row.delta(cost: cost).abs() / max,
                      color: row.delta(cost: cost) >= 0 ? p['clay'] : p['ok'],
                      backgroundColor: p['fill-hover'],
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (!expanded && changes.length > 5)
          Align(
            alignment: Alignment.centerLeft,
            child: LensTextLink(
              label: s.showMoreComparisonRows(changes.length - 5),
              onTap: () => setState(() => expanded = true),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 14,
      children: [
        if (data.data case final comparison?) values(comparison),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          runSpacing: 8,
          children: [
            LensSegmented(
              options: {
                'project': s.byProject,
                'source': s.byTool,
                'model': s.byModel,
              },
              value: by,
              label: s.groupBy,
              small: true,
              onChanged: (value) {
                if (value == by) return;
                setState(() {
                  by = value;
                  expanded = false;
                });
                refresh();
              },
            ),
            TrendMetricControl(
              key: const Key('comparison-metric'),
              cost: cost,
              onChanged: (value) => setState(() => cost = value),
            ),
          ],
        ),
        ResourceBlock(
          resource: data,
          builder: (value) =>
              value == null ? const SizedBox.shrink() : list(value),
        ),
      ],
    );
  }
}
