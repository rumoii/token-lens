import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/preferences.dart';

void main() {
  const cases = [
    (
      'yesterday',
      2024,
      3,
      1,
      '2024-02-29',
      '2024-02-29',
      '2024-02-28',
      '2024-02-28',
      1,
      'hour',
    ),
    (
      'lastWeek',
      2026,
      1,
      1,
      '2025-12-21',
      '2025-12-27',
      '2025-12-14',
      '2025-12-20',
      7,
      'day',
    ),
    (
      'lastMonth',
      2024,
      3,
      10,
      '2024-02-01',
      '2024-02-29',
      '2024-01-01',
      '2024-01-31',
      29,
      'day',
    ),
    (
      'lastMonth',
      2026,
      1,
      1,
      '2025-12-01',
      '2025-12-31',
      '2025-11-01',
      '2025-11-30',
      31,
      'day',
    ),
    (
      'last7',
      2026,
      1,
      2,
      '2025-12-27',
      '2026-01-02',
      '2025-12-20',
      '2025-12-26',
      7,
      'day',
    ),
    (
      'last30',
      2024,
      3,
      1,
      '2024-02-01',
      '2024-03-01',
      '2024-01-02',
      '2024-01-31',
      30,
      'day',
    ),
  ];
  for (final (id, year, month, day, from, to, prevFrom, prevTo, days, grain)
      in cases) {
    test('$id on $year-$month-$day uses complete calendar dates', () {
      final now = DateTime(year, month, day, 12);
      final period = StatsPeriod.parse('period=$id')
          .withWeekStart(DateTime.sunday);
      expect(period.query, 'period=$id');
      expect(period.range(now), (from: from, to: to));
      final previous = period.compare(now)!;
      expect((previous.from, previous.to), (prevFrom, prevTo));
      expect(period.elapsedDays(now), days);
      expect(period.axis(now), (granularity: grain, from: from, to: to));
    });
  }

  test('saved period accepts shortcuts and preserves legacy defaults', () {
    for (final id in [
      'today',
      'week',
      'month',
      'all',
      'custom',
      ...cases.map((c) => c.$1),
    ]) {
      final stored = UiPreferences.decode('{"period":{"period":"$id"}}');
      expect(stored.period.period, id);
      expect(stored.defaultPeriod, 'last');
    }
    expect(
      UiPreferences.decode('{"period":{"period":"unknown"}}').period.period,
      'week',
    );
  });
}
