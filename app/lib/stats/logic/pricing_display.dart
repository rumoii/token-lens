import '../../stats_gateway.dart';
import 'format.dart';

const pricingStates = {
  'verified': ('已对照官方价', '和厂商的价格页逐项对过', 'ok'),
  'aggregate': ('估算价', '厂商没单独公布，或者还没核对，按同类模型估算', 'warn'),
  'unknown': ('查不到价格', '这些用量照常统计 token，但不计入金额', 'danger'),
  'local': ('本地', '本地提供方，金额按 0 计', 'neutral'),
};
String priceText(num? value) => value == null
    ? '—'
    : '\$${value.toString().replaceFirst(RegExp(r'\.0$'), '')}';
String recordText(num? count) => toDisplayNumber(count ?? 0);
bool hasConditionalPrices(StatsModelPrice model) =>
    model.tiers?.isNotEmpty == true || model.timeOfDay != null;
String holidayText(StatsTimeOfDay tod) => tod.holidaysThrough != null
    ? '节假日仅登记到 ${tod.holidaysThrough!.substring(0, 4)} 年'
    : '尚未登记节假日';
String timeText(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
String timeZoneText(int offset) => offset == 480
    ? '北京时间（UTC+8）'
    : 'UTC${offset < 0 ? '-' : '+'}${offset.abs() ~/ 60}${offset.abs() % 60 == 0 ? '' : ':${(offset.abs() % 60).toString().padLeft(2, '0')}'}';
String conditionalSummary(StatsModelPrice model) {
  final marks = model.priceMarks;
  final items = [
    for (final tier in model.tiers ?? <StatsPriceTier>[])
      '单次提示 > ${recordText(tier.above)} token · ${recordText(marks['tier:${tier.above}'])} 条按长上下文计',
    if (model.tiers?.isNotEmpty == true && (marks['tier:unknown'] ?? 0) != 0)
      '${recordText(marks['tier:unknown'])} 条提示长度不完整 · 基础档',
    if (model.timeOfDay != null) ...[
      '峰谷分时 · ${recordText(marks['tod:offpeak'])} 条低谷',
      '${recordText(marks['tod:blend'])} 条区间加权',
      '${recordText(marks['tod:weekly'])} 条周占比估算',
      holidayText(model.timeOfDay!),
    ],
  ];
  return items.join(' · ');
}

String priceMarkLabel(String mark) =>
    const {
      '': '未标记',
      'tier:unknown': '提示长度不完整 · 基础档',
      'tier:cumulative': '累计快照 · 基础档',
      'tod:peak': '高峰',
      'tod:offpeak': '低谷',
      'tod:blend': '区间加权',
      'tod:weekly': '周占比估算',
    }[mark] ??
    (RegExp(r'^tier:\d+$').hasMatch(mark)
        ? '长上下文（提示 > ${recordText(int.parse(mark.substring(5)))} token）'
        : mark);

Map<String?, int> modelUsage(StatsBreakdown? usage) {
  final totals = <String?, int>{};
  for (final group in usage?.groups ?? <StatsGroup>[]) {
    totals.update(
      group.model,
      (n) => n + group.grossTokens,
      ifAbsent: () => group.grossTokens,
    );
  }
  return totals;
}
