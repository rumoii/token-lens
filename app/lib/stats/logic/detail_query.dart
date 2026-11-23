import 'period.dart';

const _dimensionFilters = ['tool', 'model', 'project'];
const _missingFilters = ['project', 'model'];

bool _hasDimensionFilter(Map<String, String> query) =>
    _dimensionFilters.any((key) => query[key]?.isNotEmpty == true) ||
    _missingFilters.contains(query['missing']);

String detailSearch(
  StatsPeriod period, [
  Map<String, String> detail = const {},
]) => Uri(
  queryParameters: {
    ...Uri.splitQueryString(period.query),
    'view': 'detail',
    for (final key in [..._dimensionFilters, 'bucket'])
      if (detail[key]?.isNotEmpty == true) key: detail[key]!,
    if (detail['dim']?.isNotEmpty == true &&
        (detail['dim'] != 'project' || _hasDimensionFilter(detail)))
      'dim': detail['dim']!,
    if (detail['compare'] == '1') 'compare': '1',
    if (_missingFilters.contains(detail['missing']))
      'missing': detail['missing']!,
  },
).query;
String nextDim(String key) =>
    const {
      'tool': 'model',
      'model': 'date',
      'project': 'date',
      'bucket': 'tool',
    }[key] ??
    'date';
DayRange? bucketRange(String bucket, [DayRange? range]) {
  final m = RegExp(r'^(\d{4})-(\d{2})(?:-(\d{2}))?$').firstMatch(bucket);
  if (m == null) return null;
  final year = int.parse(m[1]!), month = int.parse(m[2]!);
  if (month < 1 || month > 12) return null;
  final last = DateTime(year, month + 1, 0).day;
  if (m[3] != null && (int.parse(m[3]!) < 1 || int.parse(m[3]!) > last)) {
    return null;
  }
  var from = m[3] != null ? bucket : '$bucket-01';
  var to = m[3] != null ? bucket : '$bucket-${last.toString().padLeft(2, '0')}';
  if (range?.from != null && range!.from!.compareTo(from) > 0) {
    from = range.from!;
  }
  if (range?.to != null && range!.to!.compareTo(to) < 0) to = range.to!;
  return from.compareTo(to) <= 0 ? (from: from, to: to) : null;
}

Map<String, String> readDetail(String text) {
  final q = Uri.splitQueryString(
    text.startsWith('?') ? text.substring(1) : text,
  );
  final bucket = q['bucket'] ?? '';
  return {
    'view': q['view'] == 'detail' ? 'detail' : 'overview',
    for (final key in _dimensionFilters) key: q[key] ?? '',
    'bucket':
        bucketRange(bucket) != null ||
            RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:00:00$').hasMatch(bucket)
        ? bucket
        : '',
    'dim': ['date', 'tool', 'model', 'project', 'request'].contains(q['dim'])
        ? q['dim']!
        : _hasDimensionFilter(q)
        ? 'date'
        : 'project',
    if (q['compare'] == '1') 'compare': '1',
    if (_missingFilters.contains(q['missing'])) 'missing': q['missing']!,
  };
}

int? spanDaysOf(DayRange range, DateTime now) {
  final start = DateTime.tryParse(range.from ?? '');
  if (start == null) return null;
  final endDay = DateTime.tryParse(range.to ?? '');
  final end = (range.to?.isNotEmpty == true)
      ? endDay == null
            ? null
            : DateTime.utc(endDay.year, endDay.month, endDay.day)
      : now;
  if (end == null) return null;
  final days =
      (end
                  .toUtc()
                  .difference(DateTime.utc(start.year, start.month, start.day))
                  .inMilliseconds /
              86400000)
          .floor() +
      1;
  return days < 1 ? 1 : days;
}

String granularityForRange(DayRange range, DateTime now) {
  final days = spanDaysOf(range, now);
  return days == null
      ? 'month'
      : days <= 1
      ? 'hour'
      : days <= 90
      ? 'day'
      : 'month';
}
