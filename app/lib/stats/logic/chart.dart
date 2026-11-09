import 'dart:math' as math;

typedef Point = ({double x, double y});
typedef RingSegment = ({
  int index,
  double startDeg,
  double endDeg,
  double share,
});

double trendCeiling(num max) {
  final magnitude = math.pow(
    10,
    (math.log(math.max(max, 1)) / math.ln10).floor(),
  );
  final f = math.max(max, 1) / magnitude;
  return (f <= 1
          ? 1
          : f <= 2
          ? 2
          : f <= 2.5
          ? 2.5
          : f <= 5
          ? 5
          : 10) *
      magnitude.toDouble();
}

({double x, double width}) trendColumn(int index, int count, double width) {
  final gap = count > 20 ? 3.0 : 8.0;
  final slot = (width + gap) / count;
  final bar = math.max(0.0, math.min(48.0, slot - gap));
  return (x: index * slot + (slot - gap - bar) / 2, width: bar);
}

List<Point> sparkPoints(List<num> values, double width, double height) {
  if (values.length < 2) return [];
  final max = values.fold<num>(1, math.max);
  return [
    for (var i = 0; i < values.length; i++)
      (
        x: i / (values.length - 1) * width,
        y: height - values[i] / max * (height - 2) - 1,
      ),
  ];
}

List<Point> scaleSeries(List<num> values, double width, double height) {
  final peak = values.fold<num>(0, math.max);
  final max = peak == 0 ? 1 : peak;
  return [
    for (var i = 0; i < values.length; i++)
      (
        x: values.length == 1 ? width / 2 : i / (values.length - 1) * width,
        y: height - math.max(values[i], 0) / max * height * .94,
      ),
  ];
}

String _round(double n) {
  final value = (n * 100).round() / 100;
  return value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toString();
}

String linePath(List<Point> points) => [
  for (var i = 0; i < points.length; i++)
    '${i == 0 ? 'M' : 'L'}${_round(points[i].x)},${_round(points[i].y)}',
].join(' ');
String areaPath(List<Point> points, double height) => points.isEmpty
    ? ''
    : '${linePath(points)} L${_round(points.last.x)},${_round(height)} L${_round(points.first.x)},${_round(height)} Z';
List<List<Point>> stackedPoints(
  List<List<num?>> layers,
  double width,
  double height,
) {
  final length = layers.fold<int>(0, (n, l) => math.max(n, l.length));
  if (length == 0) return [for (final _ in layers) <Point>[]];
  num value(List<num?> layer, int i) =>
      math.max(i < layer.length ? layer[i] ?? 0 : 0, 0);
  final totals = [
    for (var i = 0; i < length; i++)
      layers.fold<num>(0, (s, l) => s + value(l, i)),
  ];
  final peak = totals.fold<num>(0, math.max);
  final max = peak == 0 ? 1 : peak;
  final acc = List<num>.filled(length, 0);
  return [
    for (final layer in layers)
      [
        for (var i = 0; i < length; i++)
          (
            x: length == 1 ? width / 2 : i / (length - 1) * width,
            y: height - (acc[i] += value(layer, i)) / max * height * .94,
          ),
      ],
  ];
}

String areaBetweenPath(List<Point> top, List<Point> bottom) =>
    top.isEmpty || top.length != bottom.length
    ? ''
    : '${linePath(top)} ${bottom.reversed.map((p) => 'L${_round(p.x)},${_round(p.y)}').join(' ')} Z';
double niceCeiling(num value) {
  if (!value.isFinite || value <= 0) return 0;
  final magnitude = math
      .pow(10, (math.log(value) / math.ln10).floor())
      .toDouble();
  final normalized = value / magnitude;
  return (normalized <= 1
          ? 1
          : normalized <= 2
          ? 2
          : normalized <= 5
          ? 5
          : 10) *
      magnitude;
}

double barWidthPercent(num value, num max) =>
    !value.isFinite || value <= 0 || !max.isFinite || max <= 0
    ? 0
    : (value / max * 100).clamp(2, 100).toDouble();
List<RingSegment> ringSegments(List<num> values, {double gapDeg = 2}) {
  final positive = values.map((v) => v.isFinite && v > 0 ? v : 0).toList();
  final total = positive.fold<num>(0, (s, v) => s + v);
  if (total <= 0) return [];
  final count = positive.where((v) => v > 0).length;
  final gap = count > 1 ? gapDeg : 0.0;
  var cursor = 0.0;
  return [
    for (var i = 0; i < positive.length; i++)
      if (positive[i] > 0)
        (() {
          final start = cursor;
          final share = positive[i] / total;
          final sweep = share * (360 - gap * count);
          cursor += sweep + gap;
          return (
            index: i,
            startDeg: start,
            endDeg: start + sweep,
            share: share,
          );
        })(),
  ];
}

({double dash, double gap, double offset}) arcDash(
  double startDeg,
  double endDeg,
  double radius,
) {
  final circumference = 2 * math.pi * radius;
  final length = (endDeg - startDeg) / 360 * circumference;
  return (
    dash: length,
    gap: circumference - length,
    offset: -(startDeg - 90) / 360 * circumference,
  );
}
