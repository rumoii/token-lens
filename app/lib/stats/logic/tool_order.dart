import 'package:flutter/painting.dart';

import '../theme/palette.dart';

typedef SourceOrderRow = ({
  String source,
  String? firstObservedAt,
  int records,
});
List<String> toolOrder(List<SourceOrderRow> sources) {
  final active = sources.where((s) => s.records > 0).toList()
    ..sort((a, b) {
      final time = (a.firstObservedAt ?? '\uffff').compareTo(
        b.firstObservedAt ?? '\uffff',
      );
      return time != 0 ? time : a.source.compareTo(b.source);
    });
  return active.map((s) => s.source).toList();
}

Map<String, Color> assignToolColors(
  Iterable<(String, int)> usage,
  LensPalette palette,
) {
  final totals = <String, int>{};
  for (final (id, tokens) in usage) {
    totals.update(id, (total) => total + tokens, ifAbsent: () => tokens);
  }
  final ranked = totals.entries.toList()
    ..sort((a, b) {
      final byTokens = b.value.compareTo(a.value);
      return byTokens != 0 ? byTokens : a.key.compareTo(b.key);
    });
  var inkRank = 0;
  return {
    for (final entry in ranked)
      entry.key: palette.toolBrand(entry.key) ?? palette.toolInk(++inkRank),
  };
}

List<String> sortByToolOrder(List<String> ids, List<String> order) {
  final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
  return ids.toList()..sort((a, b) {
    final delta = (rank[a] ?? order.length) - (rank[b] ?? order.length);
    return delta != 0 ? delta : a.compareTo(b);
  });
}
