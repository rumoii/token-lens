import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/heatmap.dart';

void main() {
  group('heatmap.test.ts', () {
    test('空矩阵', () {
      final data = buildHeatmap([]);
      expect(data.weeks, isEmpty);
      expect(data.max, 0);
      expect(data.total, 0);
    });
    test('周一对齐、每列7格', () {
      final data = buildHeatmap(
        [(day: '2026-10-05', value: 10)],
        from: '2026-10-05',
        to: '2026-10-05',
      );
      expect(data.weeks, hasLength(1));
      expect(data.weeks.single, hasLength(7));
      expect(data.weeks.single.first.day, '2026-10-05');
      expect(data.weeks.single[1].day, isNull);
      expect(data.weeks.single[1].outside, isTrue);
    });
    test('周四前补空', () {
      final data = buildHeatmap(
        [(day: '2026-10-08', value: 5)],
        from: '2026-10-08',
        to: '2026-10-08',
      );
      expect(data.weeks.single.first, (
        day: null,
        value: 0,
        level: 0,
        outside: true,
      ));
      expect(data.weeks.single[3].day, '2026-10-08');
    });
    test('跨月补零', () {
      final data = buildHeatmap(
        [(day: '2026-09-29', value: 100), (day: '2026-10-02', value: 50)],
        from: '2026-09-28',
        to: '2026-10-04',
      );
      expect(data.total, 150);
      final days = data.weeks.expand((w) => w).where((c) => c.day != null);
      expect(days, hasLength(7));
      expect(days.firstWhere((c) => c.day == '2026-09-30').value, 0);
    });
    test('零无高亮', () {
      final data = buildHeatmap(
        [(day: '2026-10-05', value: 0), (day: '2026-10-06', value: 0)],
        from: '2026-10-05',
        to: '2026-10-06',
      );
      expect(data.max, 0);
      expect(data.weeks.expand((w) => w).every((c) => c.level == 0), isTrue);
    });
    test('对数分档', () {
      expect(levelOf(0, 1000), 0);
      expect(levelOf(1, 1000), 1);
      expect(levelOf(1000, 1000), 4);
      expect(levelOf(50, 1000), 3);
      expect(levelOf(500, 1000), 4);
    });
    test(
      'UTC 日期',
      () => expect(isoDay(DateTime.utc(2026, 10, 5, 23, 30)), '2026-10-05'),
    );
    test('跨度文案', () {
      expect(formatSpan(null), isNull);
      expect(formatSpan(0), isNull);
      expect(formatSpan(90000), '2 分');
      expect(formatSpan(3 * 3600000), '3.0 小时');
      expect(formatSpan(72 * 3600000), '3.0 天');
    });
  });
}
