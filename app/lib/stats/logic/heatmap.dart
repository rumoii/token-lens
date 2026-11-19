import '../../l10n/app_strings.dart';

import 'dart:math' as math;

import 'period.dart';

typedef DayPoint = ({String day, num value});
typedef HeatCell = ({String? day, num value, int level, bool outside});
typedef HeatmapData = ({List<List<HeatCell>> weeks, num max, num total});

({double left, double top, double size}) heatCellGeometry(
  int index,
  int blanks,
  int weeks,
  double width,
) {
  final cell = (width - (weeks - 1) * 3) / weeks;
  return (
    left: (blanks + index) ~/ 7 * (cell + 3),
    top: 20 + (blanks + index) % 7 * (cell + 3),
    size: cell,
  );
}

int homeHeatLevel(num value) => value <= 0
    ? 0
    : value < 15e6
    ? 1
    : value < 30e6
    ? 2
    : value < 50e6
    ? 3
    : 4;
int levelOf(num value, num max) {
  if (!value.isFinite || value <= 0 || !max.isFinite || max <= 0) return 0;
  final ratio = math.log(1 + value) / math.log(1 + max);
  return ratio <= .25
      ? 1
      : ratio <= .5
      ? 2
      : ratio <= .75
      ? 3
      : 4;
}

HeatmapData buildHeatmap(
  List<DayPoint> points, {
  String? from,
  String? to,
  int weekStartsOn = 1,
}) {
  final max = points.fold<num>(0, (m, p) => math.max(m, p.value));
  final total = points.fold<num>(0, (s, p) => s + p.value);
  final weeks = <List<HeatCell>>[];
  if (points.isEmpty && from == null) {
    return (weeks: weeks, max: max, total: total);
  }
  final first = from ?? (points.isEmpty ? null : points.first.day);
  final last = to ?? (points.isEmpty ? null : points.last.day);
  if (first == null || last == null) {
    return (weeks: weeks, max: max, total: total);
  }
  final start = DateTime.parse('${first.substring(0, 10)}T00:00:00Z');
  final end = DateTime.parse('${last.substring(0, 10)}T00:00:00Z');
  var cursor = start.subtract(
    Duration(days: (start.weekday % 7 - weekStartsOn + 7) % 7),
  );
  final byDay = {for (final p in points) p.day.substring(0, 10): p.value};
  while (!cursor.isAfter(end)) {
    final column = <HeatCell>[];
    for (var i = 0; i < 7; i++) {
      final inRange = !cursor.isBefore(start) && !cursor.isAfter(end);
      final day = isoDay(cursor);
      final value = inRange ? byDay[day] ?? 0 : 0;
      column.add((
        day: inRange ? day : null,
        value: value,
        level: levelOf(value, max),
        outside: !inRange,
      ));
      cursor = cursor.add(const Duration(days: 1));
    }
    weeks.add(column);
  }
  return (weeks: weeks, max: max, total: total);
}

String isoDay(DateTime date) => dayKey(date.toUtc());
String? formatSpan(num? ms, [AppStrings strings = chineseStrings]) {
  if (ms == null || !ms.isFinite || ms <= 0) return null;
  final hours = ms / 3600000;
  return hours < 1
      ? strings.roundedMinutes((ms / 60000).round())
      : hours < 48
      ? strings.fractionalHours(hours.toStringAsFixed(1))
      : strings.dayCount((hours / 24).toStringAsFixed(1));
}
