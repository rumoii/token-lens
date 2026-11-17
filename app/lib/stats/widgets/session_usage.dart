import 'package:flutter/material.dart';

import '../../stats_gateway.dart' show StatsFilter;
import '../logic/period.dart';
import '../theme/palette.dart';

String sessionPeriodLabel(StatsPeriod period) => switch (period.period) {
  'week' => '本周',
  'month' => '本月',
  'custom' => '所选时段',
  _ => period.label,
};

String sessionUsageLabel(StatsPeriod period, StatsFilter filter) =>
    [
      filter.source,
      filter.project,
      filter.model,
    ].any((value) => value?.isNotEmpty == true)
    ? '${period.period == 'all' ? '' : sessionPeriodLabel(period)}筛选后'
    : sessionPeriodLabel(period);

String requestText(int? count, {int? lifetimeCount}) =>
    count == null ? (lifetimeCount == null ? '不记录' : '—') : '$count 次请求';

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
  });
  final String startedAt;
  final int offsetMinutes;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final date = DateTime.parse(startedAt)
        .toUtc()
        .add(Duration(minutes: offsetMinutes));
    final year = now.toUtc().add(Duration(minutes: offsetMinutes)).year;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: p['clay-wash'],
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        '开始于 ${date.year == year ? '' : '${date.year}年'}${date.month}月${date.day}日',
        style: p.text(11, p['clay-ink'], FontWeight.w500),
      ),
    );
  }
}
