import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/detail_query.dart';
import 'package:token_lens_app/stats/logic/period.dart';

void main() {
  test('请求维度读写往返，保留桶和筛选', () {
    final query = detailSearch(const StatsPeriod('month'), {
      'dim': 'request',
      'tool': 'codex',
      'bucket': '2026-11-09T08:00:00',
    });
    expect(readDetail(query)['dim'], 'request');
    expect(readDetail(query)['bucket'], '2026-11-09T08:00:00');
    expect(readDetail(query)['tool'], 'codex');
  });
  group('detail-query.test.js', () {
    test('读写往返；空筛选不进地址，显式按时间写进地址', () {
      final text = detailSearch(const StatsPeriod('month'), {
        'tool': 'dsh',
        'model': '',
        'dim': 'date',
      });
      expect(text, 'period=month&view=detail&tool=dsh&dim=date');
      final d = readDetail('?$text');
      expect(d['view'], 'detail');
      expect(d['tool'], 'dsh');
      expect(d['model'], '');
      expect(d['dim'], 'date');
    });
    test('不认识的拆法使用默认维度', () {
      expect(readDetail('?view=detail&dim=weird')['dim'], 'project');
      expect(readDetail('?dim=model')['view'], 'overview');
    });
    test('无筛选且未指定维度时默认按项目', () {
      final query = detailSearch(const StatsPeriod('month'));
      expect(query, 'period=month&view=detail');
      expect(readDetail(query)['dim'], 'project');
    });
    test('无筛选时显式按项目可以省略维度并往返', () {
      final query = detailSearch(const StatsPeriod('month'), {
        'model': '',
        'dim': 'project',
      });
      expect(query, 'period=month&view=detail');
      expect(readDetail(query)['dim'], 'project');
    });
    for (final (filter, value) in [
      ('tool', 'codex'),
      ('model', 'synthetic model'),
      ('project', 'C:/synthetic/project'),
      ('missing', 'project'),
      ('missing', 'model'),
    ]) {
      test('$filter=$value 无显式维度时按时间，显式按项目可往返', () {
        const period = StatsPeriod('month');
        final query = detailSearch(period, {filter: value});
        expect(Uri.splitQueryString(query), isNot(contains('dim')));
        expect(readDetail(query), containsPair(filter, value));
        expect(readDetail(query)['dim'], 'date');
        expect(readDetail('$query&dim=weird')['dim'], 'date');

        final explicit = detailSearch(period, {
          filter: value,
          'dim': 'project',
        });
        expect(Uri.splitQueryString(explicit)['dim'], 'project');
        expect(readDetail(explicit)['dim'], 'project');
      });
    }
    test('无筛选时显式按时间必须写进地址并能往返', () {
      final query = detailSearch(const StatsPeriod('month'), {'dim': 'date'});
      expect(Uri.splitQueryString(query)['dim'], 'date');
      expect(readDetail(query)['dim'], 'date');
    });
    test('下钻后换一个拆法', () {
      expect(nextDim('tool'), 'model');
      expect(nextDim('bucket'), 'tool');
    });
    for (final (filter, value, dim) in [
      ('tool', 'codex', 'model'),
      ('model', 'synthetic model', 'date'),
      ('project', 'C:/synthetic/project', 'date'),
      ('bucket', '2026-11-09', 'tool'),
    ]) {
      test('按 $filter 下钻后链接保留 $dim 维度', () {
        final query = detailSearch(const StatsPeriod('month'), {
          filter: value,
          'dim': nextDim(filter),
        });
        expect(Uri.splitQueryString(query)['dim'], dim);
        expect(readDetail(query), containsPair(filter, value));
        expect(readDetail(query)['dim'], dim);
      });
    }
    test('时间桶换成日期范围；小时桶不支持', () {
      expect(bucketRange('2026-10-19'), (from: '2026-10-19', to: '2026-10-19'));
      expect(bucketRange('2026-02'), (from: '2026-02-01', to: '2026-02-28'));
      expect(bucketRange('2026-10-19T08:00:00'), isNull);
    });
    test('月桶与当前周期取交集，保留首尾边界', () {
      const range = (from: '2026-08-15', to: '2026-11-04');
      expect(bucketRange('2026-08', range), (
        from: '2026-08-15',
        to: '2026-08-31',
      ));
      expect(bucketRange('2026-11', range), (
        from: '2026-11-01',
        to: '2026-11-04',
      ));
      expect(bucketRange('2026-09', range), (
        from: '2026-09-01',
        to: '2026-09-30',
      ));
      expect(bucketRange('2026-07', range), isNull);
      expect(bucketRange('2026-08', (from: null, to: null)), (
        from: '2026-08-01',
        to: '2026-08-31',
      ));
    });
    for (final bucket in ['garbage', '2026-13', '2026-00', '2026-02-30']) {
      test('非法 bucket $bucket 当作未选中', () {
        expect(bucketRange(bucket), isNull);
        expect(readDetail('?view=detail&bucket=$bucket')['bucket'], '');
      });
    }
    test('保留已有小时桶的读取语义', () {
      expect(
        readDetail('?bucket=2026-10-19T08:00:00')['bucket'],
        '2026-10-19T08:00:00',
      );
      expect(bucketRange('2024-02-29'), (from: '2024-02-29', to: '2024-02-29'));
    });
  });
  group('DateRange.test.js', () {
    final now = DateTime.utc(2026, 10, 19, 15);
    test(
      '两端都空是全部时间，跨度无界',
      () => expect(spanDaysOf((from: '', to: ''), now), isNull),
    );
    test(
      '今天的预设是 1 天',
      () => expect(spanDaysOf((from: '2026-10-19', to: ''), now), 1),
    );
    test(
      '同一天的自定义区间也是 1 天',
      () => expect(spanDaysOf((from: '2026-10-19', to: '2026-10-19'), now), 1),
    );
    test('区间天数含首尾', () {
      expect(spanDaysOf((from: '2026-10-18', to: '2026-10-19'), now), 2);
      expect(spanDaysOf((from: '2026-09-20', to: '2026-10-19'), now), 30);
    });
    test('单日按小时', () {
      expect(granularityForRange((from: '2026-10-19', to: ''), now), 'hour');
      expect(
        granularityForRange((from: '2026-10-19', to: '2026-10-19'), now),
        'hour',
      );
    });
    test('90 天内按日，更长按月', () {
      expect(
        granularityForRange((from: '2026-09-20', to: '2026-10-19'), now),
        'day',
      );
      expect(
        granularityForRange((from: '2026-07-22', to: '2026-10-19'), now),
        'day',
      );
      expect(
        granularityForRange((from: '2026-07-21', to: '2026-10-19'), now),
        'month',
      );
    });
    test(
      '全部时间按月',
      () => expect(granularityForRange((from: '', to: ''), now), 'month'),
    );
  });
}
