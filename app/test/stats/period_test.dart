import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/period.dart';

void main() {
  final today = DateTime(2026, 10, 19, 15, 30);
  group('period.test.js', () {
    test(
      '本周从周一到今天',
      () => expect(const StatsPeriod().range(today), (
        from: '2026-10-19',
        to: '2026-10-19',
      )),
    );
    test(
      '上周同期',
      () => expect(const StatsPeriod().compare(DateTime(2026, 10, 21)), (
        from: '2026-10-12',
        to: '2026-10-14',
        label: '上周',
      )),
    );
    test(
      '上月月末截断',
      () => expect(
        const StatsPeriod('month').compare(DateTime(2026, 3, 31))?.to,
        '2026-02-28',
      ),
    );
    test('全部与自定义无比较', () {
      expect(const StatsPeriod('all').compare(today), isNull);
      expect(
        const StatsPeriod('custom', '2026-10-01', '2026-10-02').compare(today),
        isNull,
      );
    });
    test('查询兼容和默认周期', () {
      expect(StatsPeriod.parse('').period, 'week');
      expect(StatsPeriod.parse('?period=month').period, 'month');
      expect(StatsPeriod.parse('?period=nonsense').period, 'week');
    });
    test('24 小时槽', () {
      final keys = bucketKeys('hour', (
        from: '2026-10-19',
        to: '2026-10-19',
      ), today);
      expect(keys, hasLength(24));
      expect(keys.first, '2026-10-19T00:00:00');
      expect(keys.last, '2026-10-19T23:00:00');
    });
    test(
      '逐日连续槽',
      () => expect(
        bucketKeys('day', (from: '2026-10-19', to: '2026-10-23'), today),
        ['2026-10-19', '2026-10-20', '2026-10-21', '2026-10-22', '2026-10-23'],
      ),
    );
    test(
      '单日槽',
      () => expect(
        bucketKeys('day', (from: '2026-10-19', to: '2026-10-19'), today),
        ['2026-10-19'],
      ),
    );
    test(
      '跨年月份',
      () => expect(
        bucketKeys('month', (from: '2025-11-15', to: '2026-02-03'), today),
        ['2025-11', '2025-12', '2026-01', '2026-02'],
      ),
    );
    test('无范围不造轴', () {
      expect(bucketKeys('day', (from: null, to: null), today), isEmpty);
      expect(bucketKeys('month', (from: null, to: null), today), isEmpty);
    });
    test('周期粒度', () {
      expect(const StatsPeriod('today').granularity, 'hour');
      expect(const StatsPeriod().granularity, 'day');
      expect(const StatsPeriod('all').granularity, 'month');
    });
    test('只算到今天', () {
      expect(const StatsPeriod().elapsedDays(today), 1);
      expect(const StatsPeriod().elapsedDays(DateTime(2026, 10, 25)), 7);
      expect(const StatsPeriod('month').elapsedDays(today), 19);
      expect(const StatsPeriod('today').elapsedDays(today), 1);
    });
    test('全部最早记录和自定义天数', () {
      expect(
        const StatsPeriod('all').elapsedDays(today, '2026-10-17T02:00:00'),
        3,
      );
      expect(
        const StatsPeriod(
          'custom',
          '2026-10-01',
          '2026-10-10',
        ).elapsedDays(today),
        10,
      );
    });
    test('本周整周、本月整月轴', () {
      expect(const StatsPeriod().axis(today), (
        granularity: 'day',
        from: '2026-10-19',
        to: '2026-10-25',
      ));
      expect(const StatsPeriod('month').axis(today), (
        granularity: 'day',
        from: '2026-10-01',
        to: '2026-10-31',
      ));
      expect(const StatsPeriod('today').axis(today).granularity, 'hour');
    });
    test('全部短按日长按月', () {
      expect(const StatsPeriod('all').axis(today, '2026-10-17T02:00:00'), (
        granularity: 'day',
        from: '2026-10-17',
        to: '2026-10-19',
      ));
      expect(
        const StatsPeriod('all').axis(today, '2025-11-01T00:00:00').granularity,
        'month',
      );
      expect(const StatsPeriod('all').axis(today), (
        granularity: 'month',
        from: null,
        to: null,
      ));
    });
    // URL/localStorage precedence becomes a preference/controller test in step 3.
  });
}
