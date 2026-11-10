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
  });
  final List<TrendBucket> buckets;
  final List<String> order;
  final Map<String, int> slots;
  final String granularity, unitSystem, currency;
  final DateTime now;
  final String? highlight, selected;
  final bool weekdays;
  final ValueChanged<String>? onPick;
  final double rate, growth;
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
  String format(num n) => tokenCount(n, unitSystem: widget.unitSystem);
  void pick() {
    if (hot != null && widget.buckets[hot!].total > 0) {
      widget.onPick?.call(widget.buckets[hot!].bucket);
    }
  }

  void point(Offset position, double width) {
    if (widget.buckets.isEmpty) return;
    final index = ((position.dx - 44) / (width - 44) * widget.buckets.length)
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
    return SizedBox(
      height: 210,
      child: LayoutBuilder(
        builder: (context, box) {
          final tip = hot == null || hot! >= widget.buckets.length
              ? null
              : widget.buckets[hot!];
          return Semantics(
            label: widget.onPick == null
                ? '趋势图：聚焦后用左右方向键逐个查看时段'
                : '趋势图：聚焦后用左右方向键逐个查看时段，回车看这个时段的明细',
            child: Focus(
              focusNode: focusNode,
              onFocusChange: (focus) => setState(() {
                hot = focus && widget.buckets.isNotEmpty
                    ? hot ??
                          math.max(
                            0,
                            widget.buckets.lastIndexWhere((b) => b.total > 0),
                          )
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
                    height: 210,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: TimelineMotion(
                            key: ValueKey(
                              widget.buckets
                                  .map((b) => '${b.bucket}:${b.total}')
                                  .join('|'),
                            ),
                            duration: const Duration(milliseconds: 1500),
                            builder: (context, ms) => CustomPaint(
                              painter: _TrendPainter(
                                widget,
                                p,
                                hot,
                                ms,
                                LensPalette.hairline(context),
                              ),
                            ),
                          ),
                        ),
                        if (tip != null)
                          Positioned(
                            top: 0,
                            left: hot! < widget.buckets.length / 2
                                ? (44 +
                                          (hot! + .5) /
                                              widget.buckets.length *
                                              (box.maxWidth - 44) +
                                          10)
                                      .clamp(0, math.max(0, box.maxWidth - 210))
                                : null,
                            right: hot! >= widget.buckets.length / 2
                                ? ((1 - (hot! + .5) / widget.buckets.length) *
                                              (box.maxWidth - 44) +
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
                                      '${_tipLabel(tip.bucket, widget.granularity, widget.now)}   ${tip.future
                                          ? '还没到'
                                          : tip.total == 0
                                          ? '没有用量'
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
                                              color: p.category(
                                                widget.slots[id] ?? 0,
                                              ),
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
                                    if (tip.total > 0)
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            '约值',
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
                                    if (widget.onPick != null && tip.total > 0)
                                      Text(
                                        '点一下看这${widget.granularity == 'month' ? '个月' : '天'}的明细',
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

String _tipLabel(String key, String granularity, DateTime now) {
  if (granularity == 'month') {
    return '${key.substring(0, 4)}年${int.parse(key.substring(5, 7))}月';
  }
  final d = DateTime.parse(key.substring(0, 10));
  if (granularity == 'hour') {
    return '${key.substring(0, 10) == dayKey(now) ? '今天' : '${d.month}月${d.day}日'} ${int.parse(key.substring(11, 13))}:00';
  }
  return '${d.month}月${d.day}日 周${'日一二三四五六'[d.weekday % 7]}';
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.w, this.p, this.hot, this.elapsed, this.lineWidth);
  final double lineWidth;
  final double elapsed;
  final TrendChart w;
  final LensPalette p;
  final int? hot;
  void label(
    Canvas c,
    String text,
    Offset at, {
    Color? color,
    bool right = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: p.text(11, color ?? p.faint)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, at - Offset(right ? tp.width : 0, 0));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final max = trendCeiling(
      w.buckets.fold<int>(1, (m, b) => math.max(m, b.total)),
    );
    const top = 8.0, h = 180.0, left = 44.0;
    final width = size.width - left;
    for (final f in [0.0, .5, 1.0]) {
      final y = top + h * (1 - f);
      canvas.drawLine(
        Offset(left, y),
        Offset(size.width, y),
        Paint()
          ..color = p['line-soft']
          ..strokeWidth = lineWidth,
      );
      label(
        canvas,
        f == 0 ? '0' : tokenCount(max * f, unitSystem: w.unitSystem),
        Offset(40, y - 8),
        right: true,
      );
    }
    if (w.buckets.isEmpty) return;
    final count = w.buckets.length, gap = count > 20 ? 3.0 : 8.0;
    final slot = (width + gap) / count;
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
            ..color = p
                .category(w.slots[id] ?? 0)
                .withValues(alpha: opacity.toDouble()),
        );
        baseline -= height;
      }
      String text = '';
      if (w.granularity == 'hour') {
        if (i % 3 == 0) text = '${int.parse(bucket.bucket.substring(11, 13))}时';
      } else if (w.granularity == 'month') {
        text = '${int.parse(bucket.bucket.substring(5, 7))}月';
      } else {
        final d = DateTime.parse(bucket.bucket);
        if (w.weekdays) {
          text = '周${'日一二三四五六'[d.weekday % 7]}';
        } else if (count <= 10 || i % 5 == 0 || i == count - 1) {
          text = '${d.month}/${d.day}';
        }
      }
      final tp = TextPainter(
        text: TextSpan(text: text, style: p.text(11, p.faint)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(left + i * slot + (slot - gap - tp.width) / 2, 192),
      );
    }
    final nonzero = w.buckets.where((b) => b.total > 0).toList();
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
          text: '平均 ${tokenCount(avg, unitSystem: w.unitSystem)}',
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
  });
  final Map<String, int> values;
  final DateTime now;
  final bool narrow;
  final String unitSystem;
  @override
  State<Heatmap> createState() => _HeatmapState();
}

class _HeatmapState extends State<Heatmap> {
  int? hot;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context), today = widget.now;
    final start = DateTime(
      today.year,
      today.month,
      today.day - (widget.narrow ? today.weekday % 7 + 133 : 364),
    );
    final days = <DateTime>[];
    for (
      var d = start;
      !d.isAfter(today);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      days.add(d);
    }
    final blanks = start.weekday % 7,
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
            : '${days[hot!].month}月${days[hot!].day}日 周${'日一二三四五六'[days[hot!].weekday % 7]} · ${(widget.values[dayKey(days[hot!])] ?? 0) == 0 ? '没有用量' : '${tokenCount(widget.values[dayKey(days[hot!])], unitSystem: widget.unitSystem)} token'}';
        final lines = text?.split(' · ');
        final tipWidth = lines == null
            ? 0.0
            : lines
                      .map(
                        (line) => (TextPainter(
                          text: TextSpan(text: line, style: p.text(12)),
                          textDirection: TextDirection.ltr,
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
                        hot,
                        widget.unitSystem,
                        ms,
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
                            Text(lines!.first, style: p.text(12)),
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
    this.hot,
    this.units,
    this.elapsed,
  );
  final LensPalette p;
  final List<DateTime> days;
  final int blanks, weeks;
  final Map<String, int> values;
  final int? hot;
  final String units;
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
          text: TextSpan(text: '${d.month}月', style: p.text(11, p.faint)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(w * (cell + 3), 0));
      }
    }
    for (var i = 0; i < days.length; i++) {
      final value = values[dayKey(days[i])] ?? 0;
      final level = homeHeatLevel(value);
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
            label: '${dayKey(days[i])} ${values[dayKey(days[i])] ?? 0} token',
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
