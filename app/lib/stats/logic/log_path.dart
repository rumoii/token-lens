bool _separator(String character) => character == '/' || character == r'\';

String abbreviateHome(String path, String? home) {
  if (home == null || home.isEmpty) return path;
  final prefix = home.replaceFirst(RegExp(r'[/\\]+$'), '');
  if (path.length <= prefix.length || !_separator(path[prefix.length])) {
    return path;
  }
  return path.substring(0, prefix.length).toLowerCase() == prefix.toLowerCase()
      ? '~${path.substring(prefix.length)}'
      : path;
}

String shortenLogPath(String path, bool Function(String) fits) {
  if (fits(path)) return path;
  final separators = RegExp(r'[/\\]').allMatches(path).toList();
  if (separators.length < 3) return path;

  final suffix = path.substring(separators[separators.length - 2].start);
  for (final separator
      in separators.take(separators.length - 2).toList().reversed) {
    final shortened = '${path.substring(0, separator.end)}…$suffix';
    if (fits(shortened) || separator == separators.first) return shortened;
  }
  return path;
}
