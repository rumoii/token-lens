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

// Slot 0 is the neutral 'other' colour; the palette owns all actual colours.
Map<String, int> assignToolColors(List<String> order) => {
  for (var i = 0; i < order.length; i++) order[i]: i < 8 ? i + 1 : 0,
};
List<String> sortByToolOrder(List<String> ids, List<String> order) {
  final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
  return ids.toList()..sort((a, b) {
    final delta = (rank[a] ?? order.length) - (rank[b] ?? order.length);
    return delta != 0 ? delta : a.compareTo(b);
  });
}
