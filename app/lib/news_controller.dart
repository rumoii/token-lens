import 'dart:async';

import 'package:flutter/foundation.dart';

import 'news_gateway.dart';

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
  String _query = '';
  int _generation = 0;

  NewsSnapshot get snapshot => _snapshot;
  bool get loadingSnapshot => _loadingSnapshot;
  bool get cancelling => _cancelling;
  String? get updatingSourceId => _updatingSourceId;
  SourceCategory? get category => _category;
  Set<String> get sourceIds => Set.unmodifiable(_sourceIds);
  String get query => _query;

  List<NewsItem> get visibleItems {
    final sources = {for (final source in _snapshot.sources) source.id: source};
    final query = _query.trim().toLowerCase();
    return _snapshot.items
        .where((item) {
          final source = sources[item.sourceId];
          return source != null &&
              source.enabled &&
              (_category == null || source.category == _category) &&
              (_sourceIds.isEmpty || _sourceIds.contains(item.sourceId)) &&
              (query.isEmpty ||
                  item.title.toLowerCase().contains(query) ||
                  (item.description?.toLowerCase().contains(query) ?? false));
        })
        .toList(growable: false);
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
