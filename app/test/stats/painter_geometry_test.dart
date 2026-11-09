import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/chart.dart';
import 'package:token_lens_app/stats/logic/heatmap.dart';

void main() {
  test('趋势用 2.5 档，与基础折线的 1/2/5 档区分', () {
    expect(trendCeiling(210), 250);
    expect(niceCeiling(210), 500);
    expect(trendColumn(0, 7, 608).width, 48);
    expect(trendColumn(1, 7, 608).x, greaterThan(trendColumn(0, 7, 608).x));
    expect(trendColumn(0, 365, 100).width, 0);
  });
  test('热力格列优先和绝对分档，区别于通用对数热力图', () {
    final first = heatCellGeometry(0, 1, 53, 652),
        next = heatCellGeometry(7, 1, 53, 652);
    expect(first.top, next.top);
    expect(next.left, greaterThan(first.left));
    expect([0, 14999999, 15000000, 30000000, 50000000].map(homeHeatLevel), [
      0,
      1,
      2,
      3,
      4,
    ]);
  });
  test('日均小折线留 1px 上下间距、不跳过零日', () {
    expect(sparkPoints([0, 10], 76, 28), [
      (x: 0.0, y: 27.0),
      (x: 76.0, y: 1.0),
    ]);
    expect(sparkPoints([10], 76, 28), isEmpty);
  });
}
