import 'dart:async';

import 'package:flutter/foundation.dart';

import 'news_gateway.dart';

enum NewsSort { latest, hot }

class NewsController extends ChangeNotifier {
  NewsController(this.gateway);

  final NewsGateway gateway;
  NewsSnapshot _snapshot = const NewsSnapshot();
  Future<void>? _loadTask;
  Future<void>? _refreshTask;
  Future<void>? _cancelTask;
  Future<void>? _shutdownTask;
  bool _loadingSnapshot = false;
  bool _loaded = false;
  bool _busy = false;
  bool _cancelling = false;
  bool _closed = false;
  bool _disposed = false;
  String? _updatingSourceId;
  SourceCategory? _category;
  Set<String> _sourceIds = {};
  final Set<String> _kindIds = {};
  NewsSort _sort = NewsSort.latest;
  String _query = '';
  int _generation = 0;

  NewsSnapshot get snapshot => _snapshot;
  bool get loadingSnapshot => _loadingSnapshot;
  bool get cancelling => _cancelling;
  String? get updatingSourceId => _updatingSourceId;
  SourceCategory? get category => _category;
  Set<String> get sourceIds => Set.unmodifiable(_sourceIds);
  String get query => _query;
  Set<String> get kindIds => Set.unmodifiable(_kindIds);
  NewsSort get sort => _sort;

  List<NewsItem> _filteredItems(SourceCategory? category) {
    final sources = {for (final source in _snapshot.sources) source.id: source};
    final query = _query.trim().toLowerCase();
    return _snapshot.items
        .where((item) {
          final matchesSource = [item.sourceId, ...item.alsoIn].any((id) {
            final source = sources[id];
            return source != null &&
                source.enabled &&
                (category == null || source.category == category) &&
                (_sourceIds.isEmpty || _sourceIds.contains(id));
          });
          return sources.containsKey(item.sourceId) &&
              matchesSource &&
              (_kindIds.isEmpty || _kindIds.contains(item.kind)) &&
              (query.isEmpty ||
                  item.title.toLowerCase().contains(query) ||
                  (item.description?.toLowerCase().contains(query) ?? false));
        })
        .toList(growable: false);
  }

  int categoryCount(SourceCategory? category) =>
      _filteredItems(category).length;

  Set<String> get _heatUnits => _filteredItems(_category)
      .where((item) => item.popularity != null && item.popularityKind != null)
      .map((item) => item.popularityKind!)
      .toSet();

  bool get hotSortAvailable => _heatUnits.length == 1;

  String get sortExplanation {
    final units = _heatUnits;
    if (units.isEmpty) return '当前结果没有热度数据，暂不能按热度排序。';
    if (units.length > 1) {
      return '当前结果包含 ${units.join('、')}，不同热度单位无法比较。';
    }
    return '按 ${units.single} 降序；无热度排在最后，同热度按时间。';
  }

  List<NewsItem> get visibleItems {
    final items = _filteredItems(_category);
    final sourceOrder = {
      for (var i = 0; i < _snapshot.sources.length; i++)
        _snapshot.sources[i].id: i,
    };
    final itemOrder = {
      for (var i = 0; i < _snapshot.items.length; i++) _snapshot.items[i].id: i,
    };
    int byTime(NewsItem a, NewsItem b) {
      final aTime = DateTime.tryParse(a.publishedAt ?? '');
      final bTime = DateTime.tryParse(b.publishedAt ?? '');
      if (aTime == null && bTime != null) return 1;
      if (aTime != null && bTime == null) return -1;
      final timeOrder = aTime == null ? 0 : bTime!.compareTo(aTime);
      if (timeOrder != 0) return timeOrder;
      final registrationOrder = sourceOrder[a.sourceId]!.compareTo(
        sourceOrder[b.sourceId]!,
      );
      return registrationOrder != 0
          ? registrationOrder
          : itemOrder[a.id]!.compareTo(itemOrder[b.id]!);
    }

    items.sort((a, b) {
      if (_sort == NewsSort.hot) {
        final aHeat = a.popularityKind == null ? null : a.popularity;
        final bHeat = b.popularityKind == null ? null : b.popularity;
        if (aHeat == null && bHeat != null) return 1;
        if (aHeat != null && bHeat == null) return -1;
        if (aHeat != null && bHeat != null) {
          final heatOrder = bHeat.compareTo(aHeat);
          if (heatOrder != 0) return heatOrder;
        }
      }
      return byTime(a, b);
    });
    return items;
  }

  void toggleKindFilter(String kind) {
    if (_closed) return;
    if (!_kindIds.remove(kind)) _kindIds.add(kind);
    _emit();
  }

  void clearKindFilters() {
    if (_closed) return;
    _kindIds.clear();
    _emit();
  }

  void setSort(NewsSort sort) {
    if (_closed) return;
    _sort = sort;
    _emit();
  }

  void setCategory(SourceCategory? category) {
    if (_closed) return;
    _category = category;
    _emit();
  }

  void toggleSourceFilter(String id) {
    if (_closed) return;
    if (!_sourceIds.remove(id)) _sourceIds.add(id);
    _emit();
  }

  void setQuery(String query) {
    if (_closed) return;
    _query = query;
    _emit();
  }

  void clearFilters() {
    if (_closed) return;
    _category = null;
    _sourceIds = {};
    _kindIds.clear();
    _query = '';
    _emit();
  }

  Future<void> load() {
    if (_closed) return Future.value();
    return _loadTask ??= _load();
  }

  Future<void> _load() async {
    _loadingSnapshot = true;
    _emit();
    try {
      final value = await gateway.snapshot();
      if (_closed) return;
      _snapshot = _freeze(value);
    } catch (_) {
      if (_closed) return;
      _snapshot = NewsSnapshot(
        items: _snapshot.items,
        sources: _snapshot.sources,
        error: const NewsError(kind: 'cache', message: '本地缓存读取失败，可尝试手动刷新。'),
      );
    } finally {
      if (!_closed) {
        _loadingSnapshot = false;
        _loaded = true;
        _emit();
      }
    }
  }

  Future<void> refresh({List<String>? sourceIds}) {
    if (_closed || _busy || _updatingSourceId != null) return Future.value();
    _busy = true;
    final generation = ++_generation;
    return _refreshTask = _refresh(
      generation,
      sourceIds == null ? null : List.of(sourceIds),
    );
  }

  Future<void> _refresh(int generation, List<String>? sourceIds) async {
    try {
      if (!_loaded) await load();
      if (_closed || generation != _generation) return;
      _snapshot = NewsSnapshot(
        items: _snapshot.items,
        sources: _snapshot.sources
            .map(
              (source) => source.copyWith(
                refreshing:
                    source.enabled &&
                    (sourceIds == null || sourceIds.contains(source.id)),
                clearError:
                    source.enabled &&
                    (sourceIds == null || sourceIds.contains(source.id)),
              ),
            )
            .toList(),
        refreshing: true,
      );
      _emit();
      final value = await gateway.refresh(sourceIds: sourceIds);
      if (_closed || generation != _generation) return;
      _snapshot = _freeze(value, preserveOnError: true);
    } catch (_) {
      if (_closed || generation != _generation) return;
      _snapshot = NewsSnapshot(
        items: _snapshot.items,
        sources: _snapshot.sources
            .map((source) => source.copyWith(refreshing: false))
            .toList(),
        error: const NewsError(kind: 'network', message: '刷新失败，请稍后重试。'),
      );
    } finally {
      if (!_closed && generation == _generation) {
        _busy = false;
        _emit();
      }
    }
  }

  Future<void> cancelRefresh() {
    if (_closed || !_busy) return Future.value();
    if (_cancelTask != null) return _cancelTask!;
    _cancelling = true;
    return _cancelTask = _cancelRefresh();
  }

  Future<void> _cancelRefresh() async {
    ++_generation;
    // The native operation must settle before another refresh can begin.
    final activeRefresh = _refreshTask;
    NewsError? cancelError;
    _emit();
    try {
      await gateway.cancelRefresh();
    } catch (_) {
      cancelError = const NewsError(
        kind: 'cancel',
        message: '取消请求失败，请等待当前刷新结束。',
      );
    }
    await activeRefresh;
    if (_closed) return;
    try {
      final value = await gateway.snapshot();
      if (_closed) return;
      _snapshot = _freeze(
        NewsSnapshot(
          items: value.items,
          sources: value.sources,
          refreshing: value.refreshing,
          error: cancelError ?? value.error,
        ),
      );
    } catch (_) {
      if (_closed) return;
      _snapshot = NewsSnapshot(
        items: _snapshot.items,
        sources: _snapshot.sources
            .map((source) => source.copyWith(refreshing: false))
            .toList(),
        error:
            cancelError ??
            const NewsError(kind: 'cache', message: '刷新结束后无法读取本地状态，可尝试再次手动刷新。'),
      );
    } finally {
      if (!_closed) {
        _busy = false;
        _cancelTask = null;
        _cancelling = false;
        _emit();
      }
    }
  }

  NewsSnapshot _freeze(NewsSnapshot value, {bool preserveOnError = false}) {
    final preserve =
        preserveOnError &&
        value.error != null &&
        value.items.isEmpty &&
        _snapshot.items.isNotEmpty;
    return NewsSnapshot(
      items: List.unmodifiable(preserve ? _snapshot.items : value.items),
      sources: List.unmodifiable(
        preserve
            ? _snapshot.sources.map(
                (source) => source.copyWith(refreshing: false),
              )
            : value.sources,
      ),
      refreshing: value.refreshing,
      error: value.error,
    );
  }

  Future<void> setSourceEnabled(String id, bool enabled) async {
    if (_closed || _busy || _updatingSourceId != null) return;
    if (!_loaded) await load();
    if (_closed || _busy || _updatingSourceId != null) return;
    _updatingSourceId = id;
    _emit();
    try {
      final value = await gateway.setSourceEnabled(id, enabled);
      if (_closed) return;
      _snapshot = _freeze(value);
    } catch (_) {
      if (_closed) return;
      _snapshot = NewsSnapshot(
        sources: _snapshot.sources,
        items: _snapshot.items,
        error: const NewsError(kind: 'cache', message: '来源设置保存失败。'),
      );
    } finally {
      if (!_closed) {
        _updatingSourceId = null;
        _emit();
      }
    }
  }

  Future<void> shutdown() {
    if (_shutdownTask != null) return _shutdownTask!;
    _closed = true;
    ++_generation;
    return _shutdownTask = Future.sync(gateway.shutdown);
  }

  void _emit() {
    if (_sort == NewsSort.hot && !hotSortAvailable) _sort = NewsSort.latest;
    if (!_closed && !_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(shutdown().catchError((Object _) {}));
    super.dispose();
  }
}
