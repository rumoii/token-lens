import '../../l10n/app_strings.dart';

import '../../stats_gateway.dart';
import 'period.dart';
import 'tool_order.dart';

class ToolUsage {
  ToolUsage(this.id);
  final String id;
  int tokens = 0, models = 0, costMicros = 0;
  bool priced = false;
  String? get costUsd => priced ? microsUsd(costMicros) : null;
}

class ModelUsage {
  ModelUsage(this.name);
  final String name;
  int tokens = 0;
  final byTool = <String, int>{};
  String get topTool =>
      (byTool.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
}

({List<ToolUsage> rank, List<ModelUsage> models}) digestPairs(
  List<StatsGroup> groups, [
  AppStrings strings = chineseStrings,
]) {
  final sources = <String, ToolUsage>{}, models = <String, ModelUsage>{};
  for (final group in groups) {
    if (group.source == null ||
        group.source!.isEmpty ||
        group.grossTokens <= 0) {
      continue;
    }
    final tool = sources.putIfAbsent(
      group.source!,
      () => ToolUsage(group.source!),
    );
    tool.tokens += group.grossTokens;
    tool.models++;
    if (group.costUsd != null) {
      tool.priced = true;
      tool.costMicros += group.costMicros!;
    }
    final name = group.model == null || group.model!.isEmpty
        ? strings.unknownModel
        : group.model!;
    final model = models.putIfAbsent(name, () => ModelUsage(name));
    model.tokens += group.grossTokens;
    model.byTool.update(
      group.source!,
      (n) => n + group.grossTokens,
      ifAbsent: () => group.grossTokens,
    );
  }
  return (
    rank: sources.values.toList()..sort((a, b) => b.tokens - a.tokens),
    models: (models.values.toList()..sort((a, b) => b.tokens - a.tokens))
        .take(5)
        .toList(),
  );
}

String microsUsd(int micros) =>
    '${micros < 0 ? '-' : ''}${micros.abs() ~/ 1000000}.${(micros.abs() % 1000000).toString().padLeft(6, '0')}';
double cacheSavings(List<StatsGroup> groups, StatsPricing pricing) {
  final prices = {for (final p in pricing.models) p.model: p.prices};
  var sum = 0.0;
  for (final g in groups) {
    final p = prices[g.model];
    if (p?.input != null && p?.cacheRead != null) {
      sum += (g.cacheReadTokens ?? 0) * (p!.input! - p.cacheRead!) / 1e6;
    }
  }
  return sum;
}

int? deltaOf(num current, num? previous) => previous == null || previous == 0
    ? null
    : ((current - previous) / previous * 100 + .5).floor();

class TrendBucket {
  TrendBucket(this.bucket, {this.future = false});
  final String bucket;
  final bool future;
  final by = <String, int>{};
  int total = 0;
  int? costMicros;
  bool hasUsage = false;
}

String nowBucketKey(String granularity, DateTime now) => granularity == 'hour'
    ? '${dayKey(now)}T${now.hour.toString().padLeft(2, '0')}:00:00'
    : granularity == 'month'
    ? dayKey(now).substring(0, 7)
    : dayKey(now);
List<TrendBucket> buildBuckets(
  List<StatsBucket> rows,
  PeriodAxis axis,
  DateTime now, {
  bool cost = false,
}) {
  final map = <String, TrendBucket>{};
  for (final row in rows) {
    final entry = map.putIfAbsent(row.bucket, () => TrendBucket(row.bucket));
    final amount = cost ? (row.costMicros ?? 0) : row.grossTokens;
    entry.by[row.key ?? ''] = amount;
    entry.total += amount;
    entry.hasUsage |= row.recordCount > 0;
    if (row.costMicros != null) {
      entry.costMicros = (entry.costMicros ?? 0) + row.costMicros!;
    }
  }
  final nowKey = nowBucketKey(axis.granularity, now);
  for (final key in bucketKeys(axis.granularity, (
    from: axis.from,
    to: axis.to,
  ), now)) {
    map.putIfAbsent(
      key,
      () => TrendBucket(key, future: key.compareTo(nowKey) > 0),
    );
  }
  return map.values.toList()..sort((a, b) => a.bucket.compareTo(b.bucket));
}

List<String> sourceSequence(List<StatsSource> sources) => toolOrder([
  for (final s in sources)
    (source: s.source, firstObservedAt: s.firstObservedAt, records: s.records),
]);
