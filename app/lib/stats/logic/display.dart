List<String> _parts(String path) =>
    path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).toList();

String? projectName(String? path, {Iterable<String?> peers = const []}) {
  final parts = path == null ? <String>[] : _parts(path);
  if (parts.isEmpty) return null;
  final duplicate = peers
      .whereType<String>()
      .where((other) => other != path)
      .any((other) => _parts(other).lastOrNull == parts.last);
  return duplicate && parts.length > 1
      ? '${parts[parts.length - 2]} / ${parts.last}'
      : parts.last;
}

String usageDate(
  String iso,
  DateTime now, {
  bool includeRelativeDate = false,
  bool relativeLabel = true,
}) {
  final date = DateTime.tryParse(iso)?.toLocal();
  if (date == null) return '时间未知';
  final day = '${date.month}月${date.day}日';
  final calendar = date.year == now.year
      ? '$day 周${'日一二三四五六'[date.weekday % 7]}'
      : '${date.year}年$day';
  if (!relativeLabel) return calendar;
  final distance = DateTime.utc(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime.utc(date.year, date.month, date.day)).inDays;
  final relative = distance == 0
      ? '今天'
      : distance == 1
      ? '昨天'
      : null;
  return relative == null
      ? calendar
      : includeRelativeDate
      ? '$relative · $calendar'
      : relative;
}

String usageTime(String iso) {
  final date = DateTime.tryParse(iso)?.toLocal();
  return date == null
      ? '—'
      : '${date.hour}:${date.minute.toString().padLeft(2, '0')}';
}

String usageBucket(String bucket, DateTime? now) {
  if (bucket.contains('T')) return '${int.parse(bucket.substring(11, 13))}:00';
  if (bucket.length == 7) {
    final date = DateTime.parse('$bucket-01');
    return '${date.year}年${date.month}月';
  }
  // Callers without a clock request a calendar label, without relative wording.
  return usageDate(bucket, now ?? DateTime(0));
}
