import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/chart.dart';

void main() {
  group('chart.test.ts', () {
    test('零值贴底，最大值留出 6%', () {
      final points = scaleSeries([0, 100], 100, 100);
      expect(points.first, (x: 0.0, y: 100.0));
      expect(points.last.y, closeTo(6, .00001));
    });
    test('全零不除零', () {
      final points = scaleSeries([0, 0, 0], 90, 60);
      expect(points, hasLength(3));
      expect(points.every((p) => p.y.isFinite && p.y == 60), isTrue);
    });
    test('单点居中', () => expect(scaleSeries([5], 100, 50), [(x: 50.0, y: 3.0)]));
    test('空序列空路径', () {
      expect(scaleSeries([], 10, 10), isEmpty);
      expect(linePath([]), '');
      expect(areaPath([], 10), '');
    });
    test('面积闭合', () {
      final path = areaPath(scaleSeries([1, 2], 100, 100), 100);
      expect(path, startsWith('M'));
      expect(path, endsWith('Z'));
      expect(path, contains('L100,100'));
    });
    test('整纵轴', () {
      for (final pair in [(0, 0), (7, 10), (12, 20), (41, 50), (600, 1000)]) {
        expect(niceCeiling(pair.$1), pair.$2);
      }
    });
    test('条宽最小 2%', () {
      expect(barWidthPercent(0, 100), 0);
      expect(barWidthPercent(1, 1000000), 2);
      expect(barWidthPercent(50, 100), 50);
      expect(barWidthPercent(200, 100), 100);
    });
  });
  group('chart-ring.test.ts', () {
    test('全零无段', () {
      expect(ringSegments([0, 0, 0, 0]), isEmpty);
      expect(ringSegments([]), isEmpty);
    });
    test('跳过零', () {
      final segments = ringSegments([10, 0, 10, 0]);
      expect(segments.map((s) => s.index), [0, 2]);
      expect(segments.every((s) => (s.share - .5).abs() < .000001), isTrue);
    });
    test('单段整圈', () {
      final only = ringSegments([42]).single;
      expect(only.startDeg, 0);
      expect(only.endDeg, closeTo(360, .000001));
    });
    test('段加缝共 360', () {
      final segments = ringSegments([1, 2, 3, 4]);
      expect(
        segments.fold<double>(0, (s, p) => s + p.endDeg - p.startDeg) +
            2 * segments.length,
        closeTo(360, .000001),
      );
    });
    test('非法和负数为零', () {
      final segments = ringSegments([-5, 10, double.nan, 10]);
      expect(segments, hasLength(2));
      expect(segments.every((s) => s.endDeg > s.startDeg), isTrue);
    });
    test('弧长与半径', () {
      final circumference = 2 * math.pi * 60;
      final full = arcDash(0, 360, 60);
      expect(full.dash, closeTo(circumference, .000001));
      expect(full.gap, closeTo(0, .000001));
      final half = arcDash(0, 180, 60);
      expect(half.dash, closeTo(circumference / 2, .000001));
      expect(half.gap, closeTo(circumference / 2, .000001));
    });
  });
  group('chart-stacks.test.ts', () {
    test('各层累计，顶层等于总量', () {
      final layers = stackedPoints(
        [
          [10, 20],
          [30, 10],
        ],
        1000,
        180,
      );
      expect(layers, hasLength(2));
      expect(layers[1][0].y, lessThan(layers[0][0].y));
      final total = stackedPoints(
        [
          [40, 30],
        ],
        1000,
        180,
      ).single;
      expect(layers[1][0].y, closeTo(total[0].y, .000001));
      expect(layers[1][1].y, closeTo(total[1].y, .000001));
    });
    test('空输入和单点', () {
      expect(stackedPoints([], 100, 100), isEmpty);
      final single = stackedPoints(
        [
          [5],
          [5],
        ],
        100,
        100,
      );
      expect(single, hasLength(2));
      expect(single[1][0].x, 50);
      expect(single[1][0].y, lessThan(single[0][0].y));
    });
    test('负数和缺位为零', () {
      final layers = stackedPoints(
        [
          [10, -5],
          [null, 10],
        ],
        100,
        100,
      );
      expect(layers[0][1].y, 100);
      expect(layers[1][1].y, layers[1][0].y);
    });
    test('面积要求等长', () {
      const top = [(x: 0.0, y: 10.0), (x: 100.0, y: 20.0)];
      const bottom = [(x: 0.0, y: 50.0), (x: 100.0, y: 60.0)];
      final d = areaBetweenPath(top, bottom);
      expect(d, startsWith('M0,10'));
      expect(d, endsWith('Z'));
      expect(d, contains('L100,60 L0,50'));
      expect(areaBetweenPath(top, []), '');
    });
  });
}
