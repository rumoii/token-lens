import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../stats_gateway.dart';
import '../logic/pricing_display.dart';
import '../logic/format.dart';
import '../preferences.dart';
import '../theme/palette.dart';
import 'primitives.dart';

class SettingsStateBadge extends StatelessWidget {
  const SettingsStateBadge(this.state, {super.key});
  final String state;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context),
        item = pricingStates[state] ?? pricingStates['unknown']!;
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
    this.openLink,
  });
  final StatsPricing pricing;
  final StatsBreakdown? usage;
  final UiPreferences preferences;
  final Future<bool> Function(Uri)? openLink;
  @override
  State<SettingsPrices> createState() => _SettingsPricesState();
}

class _SettingsPricesState extends State<SettingsPrices> {
  String? expanded;
  LensPalette get p => LensPalette.of(context);
  bool get narrow => MediaQuery.sizeOf(context).width < 768;
  Widget _line(StatsModelPrice m) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        m.prices?.input != null
            ? '输入 ${priceText(m.prices!.input)} · 输出 ${priceText(m.prices!.output)}'
            : '没有公开价',
        style: p.text(
          narrow ? 12.5 : 13,
          m.prices?.input == null ? p.muted : p.secondary,
        ),
      ),
      if (m.localRecords > 0 && m.state != 'local')
        Text(
          '其中 ${recordText(m.localRecords)} 条本地 · 金额按 0 计',
          style: p.text(12, p.muted),
        ),
    ],
  );
  Widget _summary(StatsModelPrice m) {
    final summary = conditionalSummary(m);
    if (summary.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        summary,
        style: p.text(12, p.secondary).copyWith(height: 1.625),
      ),
    );
  }

  Widget _row(StatsModelPrice m, int tokens, bool open) {
    final name = m.model ?? '没写模型';
    return Semantics(
      button: true,
      expanded: open,
      child: LensFocusOutline(
        child: InkWell(
          onTap: () => setState(() => expanded = open ? null : name),
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
                          _line(m),
                          Text(
                            '累计 ${tokenCount(tokens, unitSystem: widget.preferences.unitSystem)}',
                            style: p.text(12.5, p.secondary),
                          ),
                          if (m.billing == 'plan')
                            Text('套餐', style: p.text(12.5, p.secondary)),
                        ],
                      ),
                      if (hasConditionalPrices(m)) _summary(m),
                    ],
                  )
                : _desktopCells([
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
                          Text('套餐', style: p.text(12, p.muted)),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _line(m),
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
                        unitSystem: widget.preferences.unitSystem,
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

  Widget _desktopCells(List<Widget> cells) => LayoutBuilder(
    builder: (context, constraints) {
      final modelWidth =
          [
            'claude-sonnet-5-5',
            'gemini-3.8-flash-k',
            'kimi-code/k3.1-pro',
          ].fold(0.0, (width, name) {
            final painter = TextPainter(
              text: TextSpan(
                text: name,
                style: DefaultTextStyle.of(context).style
                    .merge(p.text(13, null, FontWeight.w500)),
              ),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            final measured = painter.width;
            painter.dispose();
            return math.max(width, measured);
          }) +
          20;
      final widths = [
        modelWidth,
        constraints.maxWidth - modelWidth - 193,
        105.0,
        88.0,
      ];
      return Row(
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
    },
  );

  Widget _expanded(StatsModelPrice model) => Container(
    margin: EdgeInsets.only(bottom: narrow ? 8 : 0),
    padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 10, vertical: 12),
    decoration: BoxDecoration(
      color: p['fill-hover'],
      borderRadius: BorderRadius.circular(narrow ? 12 : 0),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasConditionalPrices(model))
          _conditional(model)
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = narrow ? 2 : 5;
              return Wrap(
                spacing: 18,
                runSpacing: 10,
                children: [
                  for (final pair in [
                    ('新输入', model.prices?.input),
                    ('输出', model.prices?.output),
                    ('读缓存', model.prices?.cacheRead),
                    ('写缓存（存 5 分钟）', model.prices?.cacheWrite5M),
                    ('写缓存（存 1 小时）', model.prices?.cacheWrite1H),
                  ])
                    SizedBox(
                      width:
                          (constraints.maxWidth - 18 * (columns - 1)) / columns,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(pair.$1, style: p.text(12.5, p.muted)),
                          Text(
                            priceText(pair.$2),
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
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${model.note ?? (model.state == 'verified' ? '和厂商价格页逐项对过。' : pricingStates[model.state]?.$2 ?? '')}${model.billing == 'plan' ? ' 用套餐时不按这个价扣费。' : ''}',
              style: p.text(12.5, p.muted),
            ),
            if (model.sourceUrl != null)
              Semantics(
                link: true,
                child: LensButton(
                  label: '官方价格页',
                  icon: Icons.open_in_new,
                  trailingIcon: true,
                  size: 'link',
                  variant: 'ghost',
                  onPressed: widget.openLink == null
                      ? null
                      : () => unawaited(
                          widget.openLink!(Uri.parse(model.sourceUrl!)),
                        ),
                ),
              ),
          ],
        ),
      ],
    ),
  );
  Widget _conditional(StatsModelPrice model) {
    final tod = model.timeOfDay;
    final rows = [
      (tod == null ? '基础档' : '高峰', model.prices),
      for (final tier in model.tiers ?? <StatsPriceTier>[])
        ('提示 > ${recordText(tier.above)} token', tier.prices),
      if (tod != null) ('低谷', tod.offPeakPrices),
    ];
    final labels = ['档位', '新输入', '输出', '读缓存', '写缓存（短时）', '写缓存（存 1 小时）'];
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
            if (model.tiers?.isNotEmpty == true) '长上下文分档',
            if (tod != null) '峰谷分时',
          ].join(' · '),
          style: p.text(13, null, FontWeight.w500),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) => Semantics(
            label: '条件价格表，可横向滚动',
            container: true,
            explicitChildNodes: true,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Semantics(
                label: '${model.model ?? '没写模型'} 条件价格',
                container: true,
                explicitChildNodes: true,
                child: SizedBox(
                  width: constraints.maxWidth.clamp(520.0, double.infinity),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'USD / 百万 token · — 表示不单独计价',
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
                  Text(priceMarkLabel(e.key), style: p.text(12.5, p.secondary)),
                  const SizedBox(width: 4),
                  Text(
                    '${recordText(e.value)} 条',
                    style: p.text(12.5, null, FontWeight.w500),
                  ),
                ],
              ),
          ],
        ),
        if (model.tiers?.isNotEmpty == true) ...[
          const SizedBox(height: 12),
          Text(
            '提示长度含新输入、缓存读和缓存写；恰好等于门槛仍用较低档。累计快照用基础档。提示长度不完整且已知部分未超过门槛时，用基础档并标记。',
            style: p.text(12.5, p.secondary),
          ),
        ],
        if (tod != null) ...[
          const SizedBox(height: 12),
          Text(
            '${timeZoneText(tod.utcOffsetMinutes)}，以下时段为高峰，结束时刻不含在内：',
            style: p.text(12.5, p.secondary),
          ),
          const SizedBox(height: 4),
          for (final peak in tod.peak)
            Text(
              '${peak.days.map((day) => ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][day]).join('、')} ${timeText(peak.from)}–${timeText(peak.to)}',
              style: p.text(12.5, p.secondary),
            ),
          const SizedBox(height: 4),
          Text(
            '其余时段与已登记节假日全天按低谷价；周末补班日按周末计。',
            style: p.text(12.5, p.secondary),
          ),
          const SizedBox(height: 4),
          Text(
            '${holidayText(tod)}${tod.holidaysThrough == null ? '' : '（${recordText(tod.holidaysCount)} 天，最晚 ${tod.holidaysThrough}）'}；未登记年份仍按星期和时段判断。',
            style: p.text(12.5, p.secondary),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.pricing, usage = modelUsage(widget.usage);
    if (data.models.isEmpty) {
      return const EmptyState(title: '还没有用到的模型', hint: '同步之后，出现过的模型会逐条列在这里。');
    }
    final counts = [
      data.counts.verified,
      data.counts.aggregate,
      data.counts.unknown,
      data.counts.local,
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
          SettingsStateBadge(pricingStates.keys.elementAt(i)),
          const SizedBox(height: 4),
          Text('${counts[i]} 个模型', style: p.text(20, null, FontWeight.w600)),
          Text(
            keepTailTogether(pricingStates.values.elementAt(i).$2),
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
              for (var i = 0; i < 4; i++) ...[
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
                for (var i = 0; i < 4; i++) ...[
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
            child: _desktopCells([
              for (final label in ['模型', '每百万 token', '价格', '累计用量'])
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  textAlign: label == '累计用量' ? TextAlign.right : TextAlign.left,
                  style: p.text(12, p.muted),
                ),
            ]),
          ),
        for (final model in data.models) ...[
          _row(
            model,
            usage[model.model] ?? 0,
            expanded == (model.model ?? '没写模型'),
          ),
          if (expanded == (model.model ?? '没写模型')) _expanded(model),
        ],
        const SizedBox(height: 10),
        Text('点一行看缓存价格和说明。价格表随软件内置，不联网也能用。', style: p.text(12.5, p.muted)),
      ],
    );
  }
}
