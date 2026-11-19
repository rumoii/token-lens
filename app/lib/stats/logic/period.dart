import '../../l10n/app_strings.dart';

typedef DayRange = ({String? from, String? to});
typedef PeriodAxis = ({String granularity, String? from, String? to});
typedef PeriodComparison = ({String from, String to, String label});

class StatsPeriod {
  const StatsPeriod([
    this.period = 'week',
    this.from,
    this.to,
    this.weekStartsOn = DateTime.monday,
  ]);
  final String period;
  final String? from;
  final String? to;
  final int weekStartsOn;
  StatsPeriod withWeekStart(int start) => StatsPeriod(period, from, to, start);
  static const shortcuts = [
    'yesterday',
    'lastWeek',
    'lastMonth',
    'last7',
    'last30',
  ];
  static const values = [
    'today',
    'week',
    'month',
    'all',
    'custom',
    ...shortcuts,
  ];
  bool get isShortcut => shortcuts.contains(period);
  bool get weekdays => period == 'week' || period == 'lastWeek';
  static StatsPeriod parse(String text) {
    final params = Uri.splitQueryString(
      text.startsWith('?') ? text.substring(1) : text,
    );
    String? day(String key) =>
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(params[key] ?? '')
        ? params[key]
        : null;
    return StatsPeriod(
      values.contains(params['period']) ? params['period']! : 'week',
      day('from'),
      day('to'),
    );
  }

  String get query => Uri(
    queryParameters: {
      'period': period,
      if (period == 'custom' && from != null) 'from': from!,
      if (period == 'custom' && to != null) 'to': to!,
    },
  ).query;
  String get label => labelFor(chineseStrings);
  String labelFor(AppStrings strings) =>
      {
        'today': strings.today,
        'week': strings.thisWeek,
        'month': strings.thisMonth,
        'all': strings.all,
        'custom': strings.custom,
        'yesterday': strings.yesterday,
        'lastWeek': strings.lastWeek,
        'lastMonth': strings.lastMonth,
        'last7': strings.lastSevenDays,
        'last30': strings.lastThirtyDays,
      }[period] ??
      strings.thisWeek;
  String inSentence(AppStrings strings) => switch (period) {
    'last7' => strings.lastSevenDaysInSentence,
    'last30' => strings.lastThirtyDaysInSentence,
    _ =>
      strings.isChinese ? labelFor(strings) : labelFor(strings).toLowerCase(),
  };

  DayRange _shortcutRange(DateTime today, {required bool previous}) {
    final weekStart = -weekdayIndex(today, weekStartsOn);
    String day(int offset) =>
        dayKey(DateTime(today.year, today.month, today.day + offset));
    final days = period == 'last7' ? 7 : 30;
    final end = previous ? -days : 0;
    final month = today.month - (previous ? 2 : 1);
    return switch (period) {
      'yesterday' => (
        from: day(previous ? -2 : -1),
        to: day(previous ? -2 : -1),
      ),
      'lastWeek' => (
        from: day(weekStart - (previous ? 14 : 7)),
        to: day(weekStart - (previous ? 8 : 1)),
      ),
      'lastMonth' => (
        from: dayKey(DateTime(today.year, month, 1)),
        to: dayKey(DateTime(today.year, month + 1, 0)),
      ),
      _ => (from: day(end - days + 1), to: day(end)),
    };
  }

  DayRange range(DateTime today) => switch (period) {
    'today' => (from: dayKey(today), to: dayKey(today)),
    'week' => (
      from: dayKey(
        DateTime(
          today.year,
          today.month,
          today.day - weekdayIndex(today, weekStartsOn),
        ),
      ),
      to: dayKey(today),
    ),
    'month' => (
      from: dayKey(DateTime(today.year, today.month, 1)),
      to: dayKey(today),
    ),
    'custom' when from != null && to != null => (from: from, to: to),
    _ when isShortcut => _shortcutRange(today, previous: false),
    _ => (from: null, to: null),
  };
  PeriodComparison? compare(
    DateTime today, [
    AppStrings strings = chineseStrings,
  ]) {
    if (period == 'today') {
      final yesterday = dayKey(
        DateTime(today.year, today.month, today.day - 1),
      );
      return (from: yesterday, to: yesterday, label: strings.yesterday);
    }
    if (period == 'week') {
      return (
        from: dayKey(
          DateTime(
            today.year,
            today.month,
            today.day - weekdayIndex(today, weekStartsOn) - 7,
          ),
        ),
        to: dayKey(DateTime(today.year, today.month, today.day - 7)),
        label: strings.lastWeek,
      );
    }
    if (period == 'month') {
      final last = DateTime(today.year, today.month, 0).day;
      return (
        from: dayKey(DateTime(today.year, today.month - 1, 1)),
        to: dayKey(
          DateTime(
            today.year,
            today.month - 1,
            today.day > last ? last : today.day,
          ),
        ),
        label: strings.lastMonth,
      );
    }
    if (isShortcut) {
      final range = _shortcutRange(today, previous: true);
      final label = switch (period) {
        'yesterday' => strings.dayBeforeYesterday,
        'lastWeek' => strings.weekBeforeLast,
        'lastMonth' => strings.monthBeforeLast,
        'last7' => strings.previousSevenDays,
        _ => strings.previousThirtyDays,
      };
      return (from: range.from!, to: range.to!, label: label);
    }
    return null;
  }

  String get granularity {
    if (period == 'today' || period == 'yesterday') return 'hour';
    if (period == 'week' || period == 'month' || isShortcut) return 'day';
    if (period == 'custom' && from != null && to != null) {
      final days = _days(DateTime.parse(from!), DateTime.parse(to!));
      return days <= 1
          ? 'hour'
          : days <= 62
          ? 'day'
          : 'month';
    }
    return 'month';
  }

  int elapsedDays(DateTime today, [String? firstSeen]) {
    if (period == 'today') return 1;
    if (period == 'week') return weekdayIndex(today, weekStartsOn) + 1;
    if (period == 'month') return today.day;
    if (isShortcut) return rangeDays(range(today));
    final first = DateTime.tryParse(
      period == 'custom' && from != null ? from! : firstSeen ?? '',
    )?.toLocal();
    final last = period == 'custom' && to != null
        ? DateTime.tryParse(to!)
        : today;
    final days = first == null || last == null ? 1 : _days(first, last);
    return days < 1 ? 1 : days;
  }

  PeriodAxis axis(DateTime today, [String? firstSeen]) {
    if (period == 'week') {
      return (
        granularity: 'day',
        from: range(today).from,
        to: dayKey(
          DateTime(
            today.year,
            today.month,
            today.day - weekdayIndex(today, weekStartsOn) + 6,
          ),
        ),
      );
    }
    if (period == 'month') {
      return (
        granularity: 'day',
        from: range(today).from,
        to: dayKey(DateTime(today.year, today.month + 1, 0)),
      );
    }
    if (period == 'all') {
      final first = DateTime.tryParse(firstSeen ?? '')?.toLocal();
      return first == null
          ? (granularity: 'month', from: null, to: null)
          : (
              granularity: _days(first, today) <= 62 ? 'day' : 'month',
              from: dayKey(first),
              to: dayKey(today),
            );
    }
    final r = range(today);
    return (granularity: granularity, from: r.from, to: r.to);
  }
}

int rangeDays(DayRange range) =>
    _days(DateTime.parse(range.from!), DateTime.parse(range.to!));

int weekdayIndex(DateTime date, int weekStartsOn) =>
    (date.weekday - weekStartsOn) % 7;

int _days(DateTime a, DateTime b) =>
    ((DateTime(
              b.year,
              b.month,
              b.day,
            ).difference(DateTime(a.year, a.month, a.day)).inMilliseconds /
            86400000)
        .round() +
    1);
String dayKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
List<String> bucketKeys(String granularity, DayRange range, DateTime today) {
  if (granularity == 'hour') {
    return [
      for (var i = 0; i < 24; i++)
        '${range.from ?? dayKey(today)}T${i.toString().padLeft(2, '0')}:00:00',
    ];
  }
  if (range.from == null || range.to == null) return [];
  var cursor = DateTime.parse(range.from!);
  final end = DateTime.parse(range.to!);
  if (granularity == 'month') cursor = DateTime(cursor.year, cursor.month, 1);
  final out = <String>[];
  while (!cursor.isAfter(end)) {
    if (granularity != 'day' && granularity != 'month') break;
    out.add(
      granularity == 'day' ? dayKey(cursor) : dayKey(cursor).substring(0, 7),
    );
    cursor = granularity == 'day'
        ? DateTime(cursor.year, cursor.month, cursor.day + 1)
        : DateTime(cursor.year, cursor.month + 1, 1);
  }
  return out;
}
