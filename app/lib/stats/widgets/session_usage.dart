import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../stats_gateway.dart' show StatsFilter;
import '../logic/period.dart';
import 'primitives.dart';

String sessionPeriodLabel(
  StatsPeriod period, [
  AppStrings strings = chineseStrings,
]) => switch (period.period) {
  'week' => strings.thisWeek2,
  'month' => strings.thisMonth2,
  'custom' => strings.selectedPeriod,
  _ => period.labelFor(strings),
};

String sessionUsageLabel(
  StatsPeriod period,
  StatsFilter filter, [
  AppStrings strings = chineseStrings,
]) =>
    [
      filter.source,
      filter.project,
      filter.model,
    ].any((value) => value?.isNotEmpty == true)
    ? strings.filteredPeriod(
        period.period == 'all' ? '' : sessionPeriodLabel(period, strings),
      )
    : sessionPeriodLabel(period, strings);

String requestText(
  int? count, {
  int? lifetimeCount,
  AppStrings strings = chineseStrings,
}) => count == null
    ? (lifetimeCount == null ? strings.notLogged : '—')
    : strings.requestCount(count);

bool sessionStartedBefore(
  String startedAt,
  StatsPeriod period,
  DateTime now, {
  required int offsetMinutes,
}) {
  final from = period.range(now).from;
  final start = DateTime.tryParse(startedAt)
      ?.toUtc()
      .add(Duration(minutes: offsetMinutes));
  return from != null && start != null && dayKey(start).compareTo(from) < 0;
}

class SessionStartChip extends StatelessWidget {
  const SessionStartChip({
    super.key,
    required this.startedAt,
    required this.offsetMinutes,
    required this.now,
    this.showDate = true,
  });
  final String startedAt;
  final bool showDate;
  final int offsetMinutes;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.parse(startedAt)
        .toUtc()
        .add(Duration(minutes: offsetMinutes));
    final year = now.toUtc().add(Duration(minutes: offsetMinutes)).year;
    final strings = context.strings;
    final day = date.year == year
        ? strings.calendarDay(date.month, date.day)
        : strings.calendarDayWithYear(date.year, date.month, date.day);
    final started = strings.startedOn(day);
    return showDate
        ? LensBadge(started)
        : Tooltip(message: started, child: LensBadge(strings.spansPeriod));
  }
}
