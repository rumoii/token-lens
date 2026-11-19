import '../../l10n/app_strings.dart';

import '../../stats_gateway.dart';
import 'format.dart';

Map<String, (String, String, String)> pricingStates(AppStrings strings) => {
  'verified': (
    strings.officialPrice,
    strings.verifiedAgainstTheProviderSPricingPage,
    'ok',
  ),
  'aggregate': (
    strings.estimatedPrice,
    strings.pricingIsUnpublishedOrUnverifiedEstimatedFrom,
    'warn',
  ),
  'unknown': (
    strings.priceUnavailable,
    strings.tokensCountTowardUsageTheirCostIs,
    'danger',
  ),
  'local': (strings.local, strings.localProviderZeroCost, 'neutral'),
};
String priceText(num? value) => value == null
    ? '—'
    : '\$${value.toString().replaceFirst(RegExp(r'\.0$'), '')}';
String recordText(num? count) => toDisplayNumber(count ?? 0);
bool hasConditionalPrices(StatsModelPrice model) =>
    model.tiers?.isNotEmpty == true || model.timeOfDay != null;
String holidayText(StatsTimeOfDay tod, AppStrings strings) =>
    tod.holidaysThrough != null
    ? strings.holidaysListedThrough0(tod.holidaysThrough!.substring(0, 4))
    : strings.noHolidaysListed;
String timeText(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
String timeZoneText(int offset, AppStrings strings) => offset == 480
    ? strings.chinaStandardTimeUtc8
    : 'UTC${offset < 0 ? '-' : '+'}${offset.abs() ~/ 60}${offset.abs() % 60 == 0 ? '' : ':${(offset.abs() % 60).toString().padLeft(2, '0')}'}';
String conditionalSummary(
  StatsModelPrice model, [
  AppStrings strings = chineseStrings,
]) {
  final marks = model.priceMarks;
  final items = [
    for (final tier in model.tiers ?? <StatsPriceTier>[])
      if ((marks['tier:${tier.above}'] ?? 0) > 0)
        strings.longContextSummary(
          tokenCount(
            tier.above,
            unitSystem: strings.isChinese ? 'chinese' : 'english',
          ),
          recordText(marks['tier:${tier.above}']),
        ),
    if (model.timeOfDay != null && (marks['tod:offpeak'] ?? 0) > 0)
      strings.offPeakSummary(recordText(marks['tod:offpeak'])),
  ];
  return items.join(' · ');
}

String priceMarkLabel(String mark, AppStrings strings) =>
    {
      '': strings.unmarked,
      'tier:unknown': strings.incompletePromptLengthBaseTier,
      'tier:cumulative': strings.sessionSnapshotBaseTier,
      'tod:peak': strings.peak,
      'tod:offpeak': strings.offPeak,
      'tod:blend': strings.weightedByTime,
      'tod:weekly': strings.estimatedFromWeeklyShare,
    }[mark] ??
    (RegExp(r'^tier:\d+$').hasMatch(mark)
        ? strings.longContextPrompt0Tokens(
            recordText(int.parse(mark.substring(5))),
          )
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
