import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/stats/logic/home_data.dart';

import 'fake_gateway.dart';

void main() {
  test('工具金额整数合计、未定价保留 null、模型跨工具合并', () {
    final data = digestPairs([
      const StatsGroup(
        source: 'a',
        model: 'shared',
        grossTokens: 10,
        costUsd: '0.000001',
        costMicros: 1,
        unpricedRecords: 0,
        recordCount: 1,
      ),
      const StatsGroup(
        source: 'a',
        model: 'second',
        grossTokens: 10,
        costUsd: '0.000002',
        costMicros: 2,
        unpricedRecords: 0,
        recordCount: 1,
      ),
      const StatsGroup(
        source: 'b',
        model: 'shared',
        grossTokens: 5,
        unpricedRecords: 1,
        recordCount: 1,
      ),
    ]);
    expect(data.rank.first.costUsd, '0.000003');
    expect(data.rank.last.costUsd, isNull);
    expect(data.models.first.name, 'shared');
    expect(data.models.first.tokens, 15);
  });
  test('缓存节省按旧前端浮点公式，不改变账本金额', () async {
    final fake = FakeStatsGateway();
    final groups = fake.groups(const StatsFilter(from: '2026-11-09'));
    expect(cacheSavings(groups, await fake.pricing()), closeTo(1.056, .000001));
    expect(groups.single.costMicros, 1040000);
  });
}
