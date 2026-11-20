import '../../l10n/app_strings.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../logic/home_data.dart';
import '../logic/chart.dart';
import '../logic/heatmap.dart';
import '../logic/period.dart';
import '../logic/format.dart';
import '../logic/tools.dart';
import '../theme/palette.dart';
import 'primitives.dart';
import 'motion.dart';

const _trendDateSize = 11.0;
const _trendDateTop = 192.0;

List<({double fraction, String label})> trendAxisTicks(
  List<TrendBucket> buckets,
  String unitSystem, {
  String Function(num)? format,
}) {
  final peak = buckets.fold<int>(
    0,
    (value, bucket) => math.max(value, bucket.total),
  );
  if (peak == 0) return [(fraction: 0, label: '0')];
  final ceiling = trendCeiling(peak);
  final unique = <String, ({double fraction, String label})>{};
  for (final fraction in [0.0, .5, 1.0]) {
    final label = fraction == 0
        ? '0'
        : format?.call(ceiling * fraction) ??
              tokenCount(ceiling * fraction, unitSystem: unitSystem);
    unique[label] = (fraction: fraction, label: label);
  }
  return unique.values.toList();
}

class TrendChart extends StatefulWidget {
  const TrendChart({
    super.key,
    required this.buckets,
    required this.order,
    required this.slots,
    required this.granularity,
    required this.now,
    this.weekdays = false,
    this.highlight,
    this.selected,
    this.onPick,
    this.unitSystem = 'chinese',
    this.currency = 'USD',
    this.rate = 1,
    this.growth = 1,
    this.costMode = false,
  });
  final List<TrendBucket> buckets;
  final List<String> order;
  final Map<String, Color> slots;
  final String granularity, unitSystem, currency;
  final DateTime now;
  final String? highlight, selected;
  final bool weekdays;
  final bool costMode;
  final ValueChanged<String>? onPick;
  final double rate, growth;
  String format(num n) => costMode
      ? usdCurrency(
          n / 1000000,
          decimals: n.abs() < 100
              ? 6
              : n.abs() < 10000
              ? 4
              : 2,
          currency: currency,
          rate: rate,
        )
      : tokenCount(n, unitSystem: unitSystem);
  double get axisInset => costMode ? 68 : 44;
  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart> {
  final focusNode = FocusNode();
  @override
  void dispose() {
    focusNode.dispose();
    super.dispose();
  }

  int? hot;
  String format(num n) => widget.format(n);
  bool canPick(TrendBucket bucket) =>
      widget.costMode ? bucket.hasUsage : bucket.total > 0;
  void pick() {
    if (hot != null &&
        hot! < widget.buckets.length &&
        canPick(widget.buckets[hot!])) {
      widget.onPick?.call(widget.buckets[hot!].bucket);
    }
  }

  void point(Offset position, double width) {
    if (widget.buckets.isEmpty) return;
    final inset = widget.axisInset;
    final index =
        ((position.dx - inset) /
                math.max(1, width - inset) *
                widget.buckets.length)
            .floor()
            .clamp(0, widget.buckets.length - 1);
    if (hot != index) setState(() => hot = index);
  }

  @override
  void didUpdateWidget(TrendChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.buckets, widget.buckets)) hot = null;
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final height =
        210.0 +
        math
            .max(0, (textScaler.scale(_trendDateSize) - _trendDateSize) * 1.55)
            .ceil();
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          final tip = hot == null || hot! >= widget.buckets.length
              ? null
              : widget.buckets[hot!];
          return Semantics(
            label: widget.onPick == null
                ? context.strings.trendChartFocusItAndUseThe
                : context.strings.trendChartFocusItAndUseThe2,
            child: Focus(
              focusNode: focusNode,
              onFocusChange: (focus) => setState(() {
                hot = focus && widget.buckets.isNotEmpty
                    ? hot ?? math.max(0, widget.buckets.lastIndexWhere(canPick))
                    : null;
              }),
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (event.logicalKey == LogicalKeyboardKey.escape) {
                  setState(() => hot = null);
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.enter) {
                  pick();
                  return KeyEventResult.handled;
                }
                if (widget.buckets.isNotEmpty &&
                    [
                      LogicalKeyboardKey.arrowLeft,
                      LogicalKeyboardKey.arrowRight,
                    ].contains(event.logicalKey)) {
                  setState(
                    () => hot =
                        ((hot ?? widget.buckets.length - 1) +
                                (event.logicalKey ==
                                        LogicalKeyboardKey.arrowLeft
                                    ? -1
                                    : 1))
                            .clamp(0, widget.buckets.length - 1),
                  );
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: MouseRegion(
                onHover: (e) => point(e.localPosition, box.maxWidth),
                onExit: (_) => setState(() => hot = null),
                cursor: widget.onPick == null
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
                child: GestureDetector(
                  onTapUp: (e) {
                    focusNode.requestFocus();
                    point(e.localPosition, box.maxWidth);
                    pick();
                  },
                  child: SizedBox(
                    height: height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: TimelineMotion(
                            key: ValueKey((
                              widget.buckets
                                  .map((b) => '${b.bucket}:${b.total}')
                                  .join('|'),
                              widget.costMode,
                            )),
                            duration: const Duration(milliseconds: 1500),
                            builder: (context, ms) => Semantics(
                              container: true,
                              label: context.strings.trendAxisLabels(
                                trendAxisTicks(
                                      widget.buckets,
                                      widget.unitSystem,
                                      format: widget.costMode
                                          ? widget.format
                                          : null,
                                    )
                                    .map((tick) => tick.label)
                                    .join(context.strings.listSeparator),
                              ),
                              child: CustomPaint(
                                painter: _TrendPainter(
                                  widget,
                                  p,
                                  hot,
                                  ms,
                                  LensPalette.hairline(context),
                                  textScaler,
                                  context.strings,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (tip != null)
                          Positioned(
                            top: 0,
                            left: hot! < widget.buckets.length / 2
                                ? (widget.axisInset +
                                          (hot! + .5) /
                                              widget.buckets.length *
                                              (box.maxWidth -
                                                  widget.axisInset) +
                                          10)
                                      .clamp(0, math.max(0, box.maxWidth - 210))
                                : null,
                            right: hot! >= widget.buckets.length / 2
                                ? ((1 - (hot! + .5) / widget.buckets.length) *
                                              (box.maxWidth -
                                                  widget.axisInset) +
                                          10)
                                      .clamp(0, math.max(0, box.maxWidth - 210))
                                : null,
                            width: 210,
                            child: IgnorePointer(
                              child: Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: p['surface-3'],
                                  borderRadius: BorderRadius.circular(10),
                                  boxShadow: p.popShadow,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '${_tipLabel(tip.bucket, widget.granularity, widget.now, context.strings)}   ${tip.future
                                          ? context.strings.upcoming2
                                          : widget.costMode && tip.costMicros == null && tip.hasUsage
                                          ? context.strings.unpriced
                                          : !canPick(tip)
                                          ? context.strings.noUsage2
                                          : format(tip.total)}',
                                      style: p.text(
                                        12.5,
                                        null,
                                        FontWeight.w500,
                                      ),
                                    ),
                                    for (final id in widget.order.where(
                                      (id) => (tip.by[id] ?? 0) > 0,
                                    ))
                                      Row(
                                        children: [
                                          Container(
                                            width: 8,
                                            height: 8,
                                            decoration: BoxDecoration(
                                              color:
                                                  widget.slots[id] ??
                                                  p.category(0),
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              toolOf(id).name,
                                              style: p.text(12.5, p.secondary),
                                            ),
                                          ),
                                          Text(
                                            format(tip.by[id]!),
                                            style: p.text(12.5),
                                          ),
                                        ],
                                      ),
                                    if (!widget.costMode && tip.total > 0)
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            context.strings.estCost,
                                            style: p.text(12.5, p.muted),
                                          ),
                                          MoneyText(
                                            tip.costMicros == null
                                                ? null
                                                : microsUsd(tip.costMicros!),
                                            currency: widget.currency,
                                            rate: widget.rate,
                                            style: p.text(12.5),
                                          ),
                                        ],
                                      ),
                                    if (widget.onPick != null && canPick(tip))
                                      Text(
                                        context.strings
                                            .selectToViewThis0SBreakdown(
                                              widget.granularity == 'month'
                                                  ? context.strings.month2
                                                  : context.strings.day,
                                            ),
                                        style: p.text(11.5, p.muted),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

String _tipLabel(
  String key,
  String granularity,
  DateTime now,
  AppStrings strings,
) {
  if (granularity == 'month') {
    return strings.calendarMonth(
      int.parse(key.substring(0, 4)),
      int.parse(key.substring(5, 7)),
    );
  }
  final date = DateTime.parse(key.substring(0, 10));
  if (granularity == 'hour') {
    final day = key.substring(0, 10) == dayKey(now)
        ? strings.today
        : strings.calendarDay(date.month, date.day);
    return '$day ${int.parse(key.substring(11, 13))}:00';
  }
  return strings.calendarDayWithWeekday(date.month, date.day, date.weekday);
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(
    this.w,
    this.p,
    this.hot,
    this.elapsed,
    this.lineWidth,
    this.textScaler,
    this.strings,
  );
  final double lineWidth;
  final double elapsed;
  final TrendChart w;
  final LensPalette p;
  final int? hot;
  final TextScaler textScaler;
  final AppStrings strings;

  @override
  void paint(Canvas canvas, Size size) {
    final max = trendCeiling(
      w.buckets.fold<int>(1, (m, b) => math.max(m, b.total)),
    );
    const top = 8.0, h = 180.0;
    final left = w.axisInset;
    final width = size.width - left;
    final ticks = trendAxisTicks(
      w.buckets,
      w.unitSystem,
      format: w.costMode ? w.format : null,
    );
    for (final f in [0.0, .5, 1.0]) {
      final y = top + h * (1 - f);
      canvas.drawLine(
        Offset(left, y),
        Offset(size.width, y),
        Paint()
          ..color = p['line-soft']
          ..strokeWidth = lineWidth,
      );
      for (final tick in ticks) {
        if (tick.fraction == f) {
          final label = TextPainter(
            text: TextSpan(text: tick.label, style: p.text(11, p.muted)),
            textDirection: TextDirection.ltr,
          )..layout();
          label.paint(
            canvas,
            Offset(math.max(0, left - 4 - label.width), y - 8),
          );
          label.dispose();
        }
      }
    }
    if (w.buckets.isEmpty) return;
    final count = w.buckets.length, gap = count > 20 ? 3.0 : 8.0;
    final slot = (width + gap) / count;
    const labelGap = 6.0;
    var labelRight = left - labelGap;
    for (var i = 0; i < count; i++) {
      final bucket = w.buckets[i];
      final column = trendColumn(i, count, width);
      final x = left + column.x, bar = column.width;
      var baseline = top + h;
      if (bucket.future) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, baseline - 3, math.max(0, bar), 3),
            const Radius.circular(5),
          ),
          Paint()..color = p['line-soft'],
        );
      }
      final stack = w.order.where((id) => (bucket.by[id] ?? 0) > 0).toList();
      for (var j = 0; j < stack.length; j++) {
        final id = stack[j];
        final delay = 230 + i * math.min(30, 360 / count) / .7;
        final progress = LensTokens.gentleEase.transform(
          ((elapsed - delay) / 690).clamp(0.0, 1.0),
        );
        final height = bucket.by[id]! / max * h * w.growth * progress;
        final opacity =
            (hot != null
                ? hot != i
                      ? .35
                      : 1
                : w.selected != null && w.selected != bucket.bucket
                ? .35
                : 1) *
            (w.highlight != null && w.highlight != id ? .35 : 1);
        final rect = Rect.fromLTWH(
          x,
          baseline - height,
          math.max(0, bar),
          math.max(0, height - 1),
        );
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect,
            topLeft: Radius.circular(j == stack.length - 1 ? 5 : 0),
            topRight: Radius.circular(j == stack.length - 1 ? 5 : 0),
          ),
          Paint()
            ..color = (w.slots[id] ?? p.category(0)).withValues(
              alpha: opacity.toDouble(),
            ),
        );
        baseline -= height;
      }
      String text = '';
      if (w.granularity == 'hour') {
        if (i % 3 == 0) {
          text = strings.hourTick(int.parse(bucket.bucket.substring(11, 13)));
        }
      } else if (w.granularity == 'month') {
        text = strings.shortMonth(int.parse(bucket.bucket.substring(5, 7)));
      } else {
        final d = DateTime.parse(bucket.bucket);
        if (w.weekdays) {
          text = strings.shortWeekday(d.weekday);
        } else if (count <= 10 || i % 5 == 0 || i == count - 1) {
          text = '${d.month}/${d.day}';
        }
      }
      if (text.isEmpty) continue;
      final label = TextPainter(
        text: TextSpan(text: text, style: p.text(_trendDateSize, p.muted)),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();
      if (label.width <= width) {
        final labelLeft = (left + i * slot + (slot - gap - label.width) / 2)
            .clamp(left, size.width - label.width);
        if (labelLeft >= labelRight + labelGap) {
          label.paint(canvas, Offset(labelLeft, _trendDateTop));
          labelRight = labelLeft + label.width;
        }
      }
      label.dispose();
    }
    final nonzero = w.buckets
        .where((b) => w.costMode ? b.costMicros != null : b.total > 0)
        .toList();
    if (nonzero.isNotEmpty) {
      final avg = nonzero.fold<int>(0, (s, b) => s + b.total) / nonzero.length;
      final y = top + h * (1 - avg / max);
      for (var x = left; x < size.width; x += 5) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 3, size.width), y),
          Paint()
            ..color = p.secondary.withValues(alpha: .55)
            ..strokeWidth = 1.5,
        );
      }
      final averageLabel = TextPainter(
        text: TextSpan(
          text: strings.avg0(w.format(avg)),
          style: p.text(11, p.secondary),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final background = Rect.fromLTWH(
        size.width - averageLabel.width - 8,
        y - 20,
        averageLabel.width + 8,
        averageLabel.height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          background,
          Radius.circular(LensTokens.radii['sm']!),
        ),
        Paint()..color = p.surface,
      );
      averageLabel.paint(canvas, background.topLeft + const Offset(4, 0));
      averageLabel.dispose();
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) => true;
}

class Heatmap extends StatefulWidget {
  const Heatmap({
    super.key,
    required this.values,
    required this.now,
    required this.narrow,
    this.unitSystem = 'chinese',
    this.weekStartsOn = DateTime.monday,
    this.scale,
  });
  final int weekStartsOn;
  final Map<String, int> values;
  final HeatScale? scale;
  final DateTime now;
  final bool narrow;
  final String unitSystem;
  @override
  State<Heatmap> createState() => _HeatmapState();
}

class _HeatmapState extends State<Heatmap> {
  int? hot;
  @override
  void didUpdateWidget(Heatmap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.now != widget.now ||
        oldWidget.narrow != widget.narrow ||
        oldWidget.weekStartsOn != widget.weekStartsOn) {
      hot = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final days = heatmapDays(widget.now, widget.narrow, widget.weekStartsOn);
    final scale =
        widget.scale ??
        heatScale(days.map((day) => widget.values[dayKey(day)] ?? 0));
    final blanks = weekdayIndex(days.first, widget.weekStartsOn),
        weeks = ((blanks + days.length) / 7).ceil();
    return LayoutBuilder(
      builder: (context, box) {
        final cell = (box.maxWidth - (weeks - 1) * 3) / weeks;
        void point(Offset offset) {
          final col = (offset.dx / (cell + 3)).floor(),
              row = ((offset.dy - 20) / (cell + 3)).floor();
          final index = col * 7 + row - blanks;
          setState(
            () => hot = row >= 0 && row < 7 && index >= 0 && index < days.length
                ? index
                : null,
          );
        }

        final text = hot == null
            ? null
            : '${context.strings.calendarDayWithWeekday(days[hot!].month, days[hot!].day, days[hot!].weekday)} · ${(widget.values[dayKey(days[hot!])] ?? 0) == 0 ? context.strings.noUsage2 : '${tokenCount(widget.values[dayKey(days[hot!])], unitSystem: widget.unitSystem)} ${context.strings.tokenUnit}'}';
        final lines = text?.split(' · ');
        final tipWidth = lines == null
            ? 0.0
            : lines
                      .map(
                        (line) => (TextPainter(
                          text: TextSpan(
                            text: line,
                            style: DefaultTextStyle.of(context).style
                                .merge(p.text(12)),
                          ),
                          textDirection: TextDirection.ltr,
                          textScaler: MediaQuery.textScalerOf(context),
                        )..layout()).width,
                      )
                      .reduce(math.max) +
                  20;
        final col = hot == null ? 0 : (blanks + hot!) ~/ 7,
            row = hot == null ? 0 : (blanks + hot!) % 7;
        final tipLeft =
            (col < 4
                    ? col * (cell + 3)
                    : col > weeks - 5
                    ? (col + 1) * (cell + 3) - tipWidth
                    : (col + .5) * (cell + 3) - tipWidth / 2)
                .clamp(0.0, math.max(0.0, box.maxWidth - tipWidth));
        return MouseRegion(
          onHover: (e) => point(e.localPosition),
          onExit: (_) => setState(() => hot = null),
          child: GestureDetector(
            onTapUp: (e) {
              final previous = hot;
              point(e.localPosition);
              if (previous == hot) setState(() => hot = null);
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                SizedBox(
                  width: box.maxWidth,
                  height: 20 + cell * 7 + 18,
                  child: TimelineMotion(
                    duration: const Duration(milliseconds: 1500),
                    builder: (context, ms) => CustomPaint(
                      painter: _HeatPainter(
                        p,
                        days,
                        blanks,
                        weeks,
                        widget.values,
                        scale,
                        hot,
                        widget.unitSystem,
                        ms,
                        context.strings,
                      ),
                    ),
                  ),
                ),
                if (text != null)
                  Positioned(
                    top: 20 + row * (cell + 3) - 8 - 12 * 1.55 * 2 - 12,
                    left: tipLeft.toDouble(),
                    width: tipWidth,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: p['surface-3'],
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: p.popShadow,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              lines!.first,
                              maxLines: 1,
                              softWrap: false,
                              style: p.text(12),
                            ),
                            Text(lines.last, style: p.text(12, p.secondary)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HeatPainter extends CustomPainter {
  _HeatPainter(
    this.p,
    this.days,
    this.blanks,
    this.weeks,
    this.values,
    this.scale,
    this.hot,
    this.units,
    this.elapsed,
    this.strings,
  );
  final LensPalette p;
  final List<DateTime> days;
  final int blanks, weeks;
  final Map<String, int> values;
  final HeatScale scale;
  final int? hot;
  final String units;
  final AppStrings strings;
  final double elapsed;
  @override
  void paint(Canvas canvas, Size size) {
    final cell = (size.width - (weeks - 1) * 3) / weeks;
    for (var w = 0; w < weeks; w++) {
      final d = DateTime(
        days.first.year,
        days.first.month,
        days.first.day - blanks + w * 7,
      );
      if (d.day <= 7) {
        final tp = TextPainter(
          text: TextSpan(
            text: strings.shortMonth(d.month),
            style: p.text(11, p.muted),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(w * (cell + 3), 0));
        tp.dispose();
      }
    }
    for (var i = 0; i < days.length; i++) {
      final value = values[dayKey(days[i])] ?? 0;
      final level = scale.level(value);
      final geometry = heatCellGeometry(i, blanks, weeks, size.width);
      final rect = Rect.fromLTWH(
        geometry.left,
        geometry.top,
        geometry.size,
        geometry.size,
      );
      if (hot == i) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect.inflate(2), const Radius.circular(3)),
          Paint()
            ..color = p.secondary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()
          ..color = p['heat-$level'].withValues(
            alpha:
                p['heat-$level'].a *
                Curves.ease.transform(
                  ((elapsed - 230 - ((blanks + i) ~/ 7) * 17) / 340).clamp(
                    0.0,
                    1.0,
                  ),
                ),
          ),
      );
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final cell = (size.width - (weeks - 1) * 3) / weeks;
    return [
      for (var i = 0; i < days.length; i++)
        CustomPainterSemantics(
          rect: Rect.fromLTWH(
            (blanks + i) ~/ 7 * (cell + 3),
            20 + (blanks + i) % 7 * (cell + 3),
            cell,
            cell,
          ),
          properties: SemanticsProperties(
            label:
                '${dayKey(days[i])} ${values[dayKey(days[i])] ?? 0} ${strings.tokenUnit}',
            textDirection: TextDirection.ltr,
          ),
        ),
    ];
  };
  @override
  bool shouldRepaint(_HeatPainter old) => true;
  @override
  bool shouldRebuildSemantics(_HeatPainter old) => true;
}
