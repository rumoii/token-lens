import '../../l10n/app_strings.dart';
import '../../stats_gateway.dart';
import 'display.dart';
import 'format.dart';
import 'period.dart';
import 'tools.dart';

class GroupChange {
  const GroupChange(this.key, this.current, this.previous);

  final String? key;
  final StatsGroup? current, previous;

  int value(StatsGroup? group, {bool cost = false}) =>
      (cost ? group?.costMicros : group?.grossTokens) ?? 0;

  int delta({bool cost = false}) =>
      value(current, cost: cost) - value(previous, cost: cost);

  bool get unused => value(previous) > 0 && value(current) == 0;

  String? badge(AppStrings strings) {
    if (current != null && previous == null) return strings.comparisonNew;
    if (unused) return strings.comparisonUnused;
    return null;
  }
}

List<GroupChange> groupChanges(StatsComparison comparison) {
  final current = {for (final g in comparison.current.groups) g.key: g};
  final previous = {for (final g in comparison.previous.groups) g.key: g};
  return [
    for (final key in {...current.keys, ...previous.keys})
      GroupChange(key, current[key], previous[key]),
  ];
}

String comparisonGroupName(
  String by,
  String? key,
  Iterable<String?> peers,
  AppStrings strings,
) => switch (by) {
  'source' => toolOf(key ?? '').name,
  'model' => key ?? strings.modelNotLogged,
  _ => projectName(key, peers: peers) ?? strings.noProjectLogged,
};

String? projectChangeSentence(
  StatsComparison? comparison,
  AppStrings strings, {
  required String unitSystem,
}) {
  if (comparison == null) return null;
  final previous = comparison.previous.totals.grossTokens;
  final difference = comparison.current.totals.grossTokens - previous;
  if (previous == 0 || difference.abs() / previous < .1) return null;
  final changes = groupChanges(comparison);
  final projects = changes.map((change) => change.key);
  final matching =
      changes
          .where(
            (row) =>
                row.key?.isNotEmpty == true &&
                row.delta().sign == difference.sign,
          )
          .toList()
        ..sort((a, b) {
          final bySize = b.delta().abs().compareTo(a.delta().abs());
          return bySize == 0 ? a.key!.compareTo(b.key!) : bySize;
        });
  if (matching.isEmpty) return null;
  final row = matching.first;
  final name = comparisonGroupName('project', row.key, projects, strings);
  final value = tokenCount(row.delta().abs(), unitSystem: unitSystem);
  return difference > 0
      ? strings.biggestIncrease(name, value)
      : strings.biggestDrop(name, value);
}

String comparisonSubtitle(
  DayRange current,
  DayRange previous,
  AppStrings strings,
) {
  String day(String key) {
    final date = DateTime.parse(key);
    return strings.calendarDay(date.month, date.day);
  }

  String dates(DayRange range) => range.from == range.to
      ? day(range.from!)
      : '${day(range.from!)} – ${day(range.to!)}';
  final n = rangeDays(current), m = rangeDays(previous);
  return n == m
      ? strings.comparisonDateRanges(dates(current), dates(previous))
      : strings.comparisonDates(dates(current), n, dates(previous), m);
}

String signedValue(int n, String Function(int) format) =>
    '${n > 0
        ? '+'
        : n < 0
        ? '−'
        : ''}${format(n.abs())}';
