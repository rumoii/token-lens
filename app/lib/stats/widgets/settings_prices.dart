import '../../l10n/app_strings.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../stats_gateway.dart';
import '../../stats_controller.dart';
import '../logic/pricing_display.dart';
import '../logic/format.dart';
import '../preferences.dart';
import '../theme/palette.dart';
import 'primitives.dart';
import 'manual_price_dialog.dart';

class SettingsStateBadge extends StatelessWidget {
  const SettingsStateBadge(this.state, {super.key});
  final String state;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context),
        item =
            pricingStates(context.strings)[state] ??
            pricingStates(context.strings)['unknown']!;
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: item.$3 == 'neutral'
            ? p['fill-hover']
            : p[item.$3].withValues(alpha: item.$3 == 'warn' ? .14 : .12),
      ),
      child: Text(
        item.$1,
        style: p.text(
          11.5,
          item.$3 == 'neutral' ? p.secondary : p[item.$3],
          FontWeight.w500,
        ),
      ),
    );
  }
}

class SettingsPrices extends StatefulWidget {
  const SettingsPrices({
    super.key,
    required this.pricing,
    required this.usage,
    required this.preferences,
    this.controller,
    this.expandFirst = false,
    this.openLink,
  });
  final StatsPricing pricing;
  final StatsBreakdown? usage;
  final UiPreferences preferences;
  final StatsController? controller;
  final bool expandFirst;
  final Future<bool> Function(Uri)? openLink;
  @override
  State<SettingsPrices> createState() => _SettingsPricesState();
}

class _SettingsPricesState extends State<SettingsPrices> {
  String? expanded;
  String? _removing;
  Object? _removeError;
  LensPalette get p => LensPalette.of(context);
  @override
  void initState() {
    super.initState();
    if (widget.expandFirst) {
      expanded = widget.pricing.models
          .where(
            (m) => m.state == 'unknown' && m.model?.trim().isNotEmpty == true,
          )
          .firstOrNull
          ?.model;
    }
  }

  void _edit(StatsModelPrice model) {
    final controller = widget.controller;
    if (controller == null) return;
    unawaited(
      showManualPriceDialog(
        context,
        controller: controller,
        pricing: widget.pricing,
        model: model,
        usage: widget.usage,
      ),
    );
  }

  Future<void> _remove(StatsModelPrice model, {required bool confirm}) async {
    final controller = widget.controller, id = model.model;
    if (controller == null || id == null || _removing != null) return;
    if (confirm) {
      final s = context.strings;
      if (await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: LensPalette.of(context).surface,
                  title: Text(s.removeManualTitle),
                  content: Text(
                    s.removeManualBody(id, recordText(model.records)),
                  ),
                  actions: [
                    LensButton(
                      label: s.cancel,
                      onPressed: () => Navigator.pop(context, false),
                    ),
                    LensButton(
                      label: s.removeManualConfirm,
                      variant: 'danger',
                      onPressed: () => Navigator.pop(context, true),
                    ),
                  ],
                ),
              ) !=
              true ||
          !mounted) {
        return;
      }
    }
    setState(() {
      _removing = id;
      _removeError = null;
    });
    try {
      await controller.removeManualPrice(id);
    } catch (error) {
      if (mounted) setState(() => _removeError = error);
    } finally {
      if (mounted) setState(() => _removing = null);
    }
  }

  StatsPrices? _displayPrices(StatsModelPrice m) =>
      m.manual?.original ?? m.prices;
  String _price(StatsModelPrice model, num? value) =>
      priceText(value, model.manual?.currency ?? 'USD');
  Widget _line(StatsModelPrice m, {required bool narrow}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _displayPrices(m)?.input != null
            ? context.strings.inputOutputPrices(
                _price(m, _displayPrices(m)?.input),
                _price(m, _displayPrices(m)?.output),
              )
            : context.strings.noListPrice,
        style: p.text(
          narrow ? 12.5 : 13,
          m.prices?.input == null ? p.muted : p.secondary,
        ),
      ),
      if (m.localRecords > 0 && m.state != 'local')
        Text(
          context.strings.includes0LocalRecordZeroCost(
            recordText(m.localRecords),
          ),
          style: p.text(12, p.muted),
        ),
    ],
  );
  Widget _summary(StatsModelPrice m) {
    final summary = conditionalSummary(m, context.strings);
    if (summary.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        summary,
        style: p.text(12, p.secondary).copyWith(height: 1.625),
      ),
    );
  }

  Widget _row(
    StatsModelPrice m,
    int tokens,
    bool open,
    bool narrow,
    List<double> widths,
  ) {
    final name = m.model ?? context.strings.modelNotLogged;
    return Semantics(
      button: true,
      expanded: open,
      child: LensFocusOutline(
        child: InkWell(
          onTap: () => setState(() {
            expanded = open ? null : name;
            _removeError = null;
          }),
          borderRadius: BorderRadius.circular(narrow ? 12 : 0),
          child: Container(
            key: ValueKey('settings-model-$name'),
            padding: EdgeInsets.symmetric(
              horizontal: 0,
              vertical: narrow ? 12 : 10,
            ),
            decoration: BoxDecoration(
              border: narrow
                  ? null
                  : Border(
                      bottom: BorderSide(
                        width: LensPalette.hairline(context),
                        color: p['line-soft'],
                      ),
                    ),
            ),
            child: narrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Tooltip(
                              message: name,
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: p.text(14, null, FontWeight.w500),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SettingsStateBadge(m.state),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          _line(m, narrow: narrow),
                          Text(
                            context.strings.total0(
                              tokenCount(
                                tokens,
                                unitSystem: widget.preferences.unitSystemFor(
                                  context.strings.languageCode,
                                ),
                              ),
                            ),
                            style: p.text(12.5, p.secondary),
                          ),
                          if (m.billing == 'plan')
                            Text(
                              context.strings.subscription,
                              style: p.text(12.5, p.secondary),
                            ),
                        ],
                      ),
                      if (hasConditionalPrices(m)) _summary(m),
                    ],
                  )
                : _desktopCells(widths, [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(
                          message: name,
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: p.text(13, null, FontWeight.w500),
                          ),
                        ),
                        if (m.billing == 'plan')
                          Text(
                            context.strings.subscription,
                            style: p.text(12, p.muted),
                          ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _line(m, narrow: narrow),
                        if (hasConditionalPrices(m)) _summary(m),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SettingsStateBadge(m.state),
                    ),
                    Text(
                      tokenCount(
                        tokens,
                        unitSystem: widget.preferences.unitSystemFor(
                          context.strings.languageCode,
                        ),
                      ),
                      textAlign: TextAlign.right,
                      style: p.text(13, p.secondary),
                    ),
                  ]),
          ),
        ),
      ),
    );
  }

  List<double> _columnWidths(BuildContext context, double available) {
    double measure(String text, double size) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: DefaultTextStyle.of(context).style
              .merge(p.text(size, null, FontWeight.w500)),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final modelWidth =
        [
          'claude-sonnet-5-5',
          'gemini-3.8-flash-k',
          'kimi-code/k3.1-pro',
        ].fold(0.0, (width, name) => math.max(width, measure(name, 13))) +
        20;
    final statusWidth = pricingStates(context.strings).values.fold(
      105.0,
      (width, state) => math.max(width, measure(state.$1, 11.5) + 36),
    );
    const usageWidth = 88.0;
    return [
      modelWidth,
      available - modelWidth - statusWidth - usageWidth,
      statusWidth,
      usageWidth,
    ];
  }

  Widget _desktopCells(List<double> widths, List<Widget> cells) => Row(
    children: [
      for (var i = 0; i < cells.length; i++)
        SizedBox(
          width: widths[i],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: cells[i],
          ),
        ),
    ],
  );

  Widget _expanded(StatsModelPrice model, bool narrow) => Container(
    margin: EdgeInsets.only(bottom: narrow ? 8 : 0),
    padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 10, vertical: 12),
    decoration: BoxDecoration(
      color: p['fill-hover'],
      borderRadius: BorderRadius.circular(narrow ? 12 : 0),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (model.listPrices case final official?)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: LensCard(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Text(
                      context.strings.manualListPrice(
                        priceText(official.input),
                        priceText(official.output),
                      ),
                      style: p.text(12.5, p.secondary),
                    ),
                    LensTextLink(
                      label: context.strings.useListPrice,
                      tone: 'clay',
                      onTap: _removing == null
                          ? () => unawaited(_remove(model, confirm: false))
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (hasConditionalPrices(model))
          _conditional(model)
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = narrow
                  ? 2
                  : model.manual != null
                  ? 4
                  : 5;
              return Wrap(
                spacing: 18,
                runSpacing: 10,
                children: [
                  for (final pair in [
                    (context.strings.newInput, _displayPrices(model)?.input),
                    (context.strings.output, _displayPrices(model)?.output),
                    (
                      model.manual == null
                          ? context.strings.cacheRead
                          : context.strings.manualCacheRead,
                      _displayPrices(model)?.cacheRead,
                    ),
                    (
                      model.manual == null
                          ? context.strings.cacheWrite5m
                          : context.strings.manualCacheWrite,
                      _displayPrices(model)?.cacheWrite5M,
                    ),
                    if (model.manual == null)
                      (
                        context.strings.cacheWrite1h,
                        model.prices?.cacheWrite1H,
                      ),
                  ])
                    SizedBox(
                      width:
                          (constraints.maxWidth - 18 * (columns - 1)) / columns,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(pair.$1, style: p.text(12.5, p.muted)),
                          Text(
                            _price(model, pair.$2),
                            style: p.text(12.5, null, FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: 10),
        if (model.manual case final manual?)
          _manualDetails(model, manual)
        else
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${(context.strings.isChinese ? model.note : model.noteEn ?? model.note) ?? (model.state == 'verified' ? context.strings.checkedAgainstTheProviderSPricingPage : pricingStates(context.strings)[model.state]?.$2 ?? '')}${model.billing == 'plan' ? context.strings.subscriptionsAreBilledSeparately : ''}',
                style: p.text(12.5, p.muted),
              ),
              if (model.sourceUrl != null)
                LensTextLink(
                  label: context.strings.officialPricingPage,
                  trailingIcon: Icons.open_in_new,
                  onTap: widget.openLink == null
                      ? null
                      : () => unawaited(
                          widget.openLink!(Uri.parse(model.sourceUrl!)),
                        ),
                ),
            ],
          ),
        if (model.state == 'unknown' &&
            model.model?.trim().isNotEmpty == true &&
            widget.controller != null) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              LensButton(
                label: context.strings.addPrice,
                variant: 'primary',
                size: 'sm',
                onPressed: () => _edit(model),
              ),
              Text(
                context.strings.unpricedFillHelp(recordText(model.records)),
                style: p.text(12.5, p.muted),
              ),
            ],
          ),
        ],
        if (_removeError case final error?)
          Semantics(
            liveRegion: true,
            child: Text(
              context.strings.requestFailed0(error),
              style: p.text(12.5, p['danger']),
            ),
          ),
      ],
    ),
  );

  Widget _manualDetails(StatsModelPrice model, StatsManualPrice manual) {
    final s = context.strings;
    final timestamp = DateTime.tryParse(manual.createdAt)?.toLocal();
    final date = timestamp == null
        ? '—'
        : s.calendarDayWithYear(timestamp.year, timestamp.month, timestamp.day);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Text(s.manualPriceCreated(date), style: p.text(12.5, p.muted)),
        if (manual.rate case final rate?)
          Text(
            s.manualConverted(rate.toStringAsFixed(2)),
            style: p.text(12.5, p.muted),
          ),
        if (manual.note?.isNotEmpty == true)
          Text(s.manualSourceNote(manual.note!), style: p.text(12.5, p.muted)),
        Wrap(
          spacing: 10,
          children: [
            LensTextLink(
              label: s.editManualPrice,
              tone: 'clay',
              onTap: _removing == null ? () => _edit(model) : null,
            ),
            if (model.listPrices == null)
              LensTextLink(
                label: s.removeManualPrice,
                tone: 'danger',
                onTap: _removing == null
                    ? () => unawaited(_remove(model, confirm: true))
                    : null,
              ),
          ],
        ),
      ],
    );
  }

  Widget _conditional(StatsModelPrice model) {
    final tod = model.timeOfDay;
    final rows = [
      (
        tod == null ? context.strings.baseTier : context.strings.peak,
        model.prices,
      ),
      for (final tier in model.tiers ?? <StatsPriceTier>[])
        (context.strings.prompt0Tokens(recordText(tier.above)), tier.prices),
      if (tod != null) (context.strings.offPeak, tod.offPeakPrices),
    ];
    final labels = [
      context.strings.tier,
      context.strings.newInput,
      context.strings.output,
      context.strings.cacheRead,
      context.strings.cacheWriteShort,
      context.strings.cacheWrite1h,
    ];
    TableRow tableRow(List<String> values, {bool header = false}) => TableRow(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            width: LensPalette.hairline(context),
            color: p['line'],
          ),
        ),
      ),
      children: [
        for (var i = 0; i < values.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Text(
              values[i],
              textAlign: i == 0 ? TextAlign.left : TextAlign.right,
              style: p.text(12.5, header ? p.secondary : p.ink),
            ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [
            if (model.tiers?.isNotEmpty == true)
              context.strings.longContextTiers,
            if (tod != null) context.strings.peakAndOffPeak,
          ].join(' · '),
          style: p.text(13, null, FontWeight.w500),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) => Semantics(
            label: context.strings.scrollableTableOfConditionalPrices,
            container: true,
            explicitChildNodes: true,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Semantics(
                label: context.strings.conditionalPriceTableLabel(
                  model.model ?? context.strings.modelNotLogged,
                ),
                container: true,
                explicitChildNodes: true,
                child: SizedBox(
                  width: constraints.maxWidth.clamp(520.0, double.infinity),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        context.strings.usdMillionTokensADashMeansNo,
                        style: p.text(12.5, p.secondary),
                      ),
                      const SizedBox(height: 8),
                      Table(
                        columnWidths: const {0: FlexColumnWidth(1.7)},
                        defaultColumnWidth: const FlexColumnWidth(),
                        children: [
                          tableRow(labels, header: true),
                          for (final row in rows)
                            tableRow([
                              row.$1,
                              ...[
                                row.$2?.input,
                                row.$2?.output,
                                row.$2?.cacheRead,
                                row.$2?.cacheWrite5M,
                                row.$2?.cacheWrite1H,
                              ].map(priceText),
                            ]),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 20,
          runSpacing: 4,
          children: [
            for (final e in model.priceMarks.entries)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    priceMarkLabel(e.key, context.strings),
                    style: p.text(12.5, p.secondary),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    context.strings.recordCount(recordText(e.value)),
                    style: p.text(12.5, null, FontWeight.w500),
                  ),
                ],
              ),
          ],
        ),
        if (model.tiers?.isNotEmpty == true) ...[
          const SizedBox(height: 12),
          Text(
            context.strings.promptLengthIncludesNewInputCacheReads,
            style: p.text(12.5, p.secondary),
          ),
        ],
        if (tod != null) ...[
          const SizedBox(height: 12),
          Text(
            context.strings.peakHoursInTimeZone(
              timeZoneText(tod.utcOffsetMinutes, context.strings),
            ),
            style: p.text(12.5, p.secondary),
          ),
          const SizedBox(height: 4),
          for (final peak in tod.peak)
            Text(
              '${peak.days.map((day) => [context.strings.sun2, context.strings.mon2, context.strings.tue2, context.strings.wed2, context.strings.thu2, context.strings.fri2, context.strings.sat2][day]).join(context.strings.listSeparator)} ${timeText(peak.from)}–${timeText(peak.to)}',
              style: p.text(12.5, p.secondary),
            ),
          const SizedBox(height: 4),
          Text(
            context.strings.offPeakPricingAppliesAtOtherTimes,
            style: p.text(12.5, p.secondary),
          ),
          const SizedBox(height: 4),
          Text(
            context.strings.holidayPricingNote(
              holidayText(tod, context.strings),
              tod.holidaysThrough == null
                  ? ''
                  : context.strings.holidayCountAndEnd(
                      recordText(tod.holidaysCount),
                      tod.holidaysThrough,
                    ),
            ),
            style: p.text(12.5, p.secondary),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final widths = _columnWidths(context, constraints.maxWidth);
      final narrow = MediaQuery.sizeOf(context).width < 768 || widths[1] < 120;
      return _buildPricing(narrow, widths);
    },
  );

  Widget _buildPricing(bool narrow, List<double> widths) {
    final data = widget.pricing, usage = modelUsage(widget.usage);
    if (data.models.isEmpty) {
      return EmptyState(
        title: context.strings.noModelsUsedYet,
        hint: context.strings.modelsAppearHereAfterSyncingToolLogs,
      );
    }
    final counts = [
      data.counts.verified,
      data.counts.aggregate,
      data.counts.unknown,
      data.counts.local,
      if (data.counts.manual > 0) data.counts.manual,
    ];
    Widget statusCard(int i) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: p['fill-hover'],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsStateBadge(pricingStates(context.strings).keys.elementAt(i)),
          const SizedBox(height: 4),
          Text(
            context.strings.modelCount(counts[i]),
            style: p.text(20, null, FontWeight.w600),
          ),
          Text(
            keepTailTogether(
              pricingStates(context.strings).values.elementAt(i).$2,
            ),
            style: p.text(12, p.muted),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (narrow)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < counts.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                statusCard(i),
              ],
            ],
          )
        else
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < counts.length; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(child: statusCard(i)),
                ],
              ],
            ),
          ),
        const SizedBox(height: 12),
        if (!narrow)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  width: LensPalette.hairline(context),
                  color: p['line'],
                ),
              ),
            ),
            child: _desktopCells(widths, [
              for (final label in [
                context.strings.model,
                context.strings.perMillionTokens,
                context.strings.pricing,
                context.strings.totalUsage,
              ])
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  textAlign: label == context.strings.totalUsage
                      ? TextAlign.right
                      : TextAlign.left,
                  style: p.text(12, p.muted),
                ),
            ]),
          ),
        for (final model in data.models) ...[
          _row(
            model,
            usage[model.model] ?? 0,
            expanded == (model.model ?? context.strings.modelNotLogged),
            narrow,
            widths,
          ),
          if (expanded == (model.model ?? context.strings.modelNotLogged))
            _expanded(model, narrow),
        ],
        const SizedBox(height: 10),
        Text(
          context.strings.selectARowForCachePricesAnd,
          style: p.text(12.5, p.muted),
        ),
      ],
    );
  }
}
