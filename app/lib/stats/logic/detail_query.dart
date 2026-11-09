import 'period.dart';

String detailSearch(
  StatsPeriod period, [
  Map<String, String> detail = const {},
]) => Uri(
  queryParameters: {
    ...Uri.splitQueryString(period.query),
    'view': 'detail',
    for (final key in ['tool', 'model', 'project', 'bucket'])
      if (detail[key]?.isNotEmpty == true) key: detail[key]!,
    if (detail['dim']?.isNotEmpty == true && detail['dim'] != 'date')
      'dim': detail['dim']!,
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
