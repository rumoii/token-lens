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
  int _generation = 0;

  NewsSnapshot get snapshot => _snapshot;
  bool get loadingSnapshot => _loadingSnapshot;
  bool get cancelling => _cancelling;

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
        lastSuccessMs: _snapshot.lastSuccessMs,
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

  Future<void> refresh() {
    if (_closed || _busy) return Future.value();
    _busy = true;
    final generation = ++_generation;
    return _refreshTask = _refresh(generation);
  }

  Future<void> _refresh(int generation) async {
    try {
      if (!_loaded) await load();
      if (_closed || generation != _generation) return;
      _snapshot = NewsSnapshot(
        items: _snapshot.items,
        lastSuccessMs: _snapshot.lastSuccessMs,
        refreshing: true,
      );
      _emit();
      final value = await gateway.refresh();
      if (_closed || generation != _generation) return;
      _snapshot = _freeze(value, preserveOnError: true);
    } catch (_) {
      if (_closed || generation != _generation) return;
      _snapshot = NewsSnapshot(
        items: _snapshot.items,
        lastSuccessMs: _snapshot.lastSuccessMs,
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
          lastSuccessMs: value.lastSuccessMs,
          refreshing: value.refreshing,
          error: cancelError ?? value.error,
        ),
      );
    } catch (_) {
      if (_closed) return;
      _snapshot = NewsSnapshot(
        items: _snapshot.items,
        lastSuccessMs: _snapshot.lastSuccessMs,
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
      lastSuccessMs: preserve ? _snapshot.lastSuccessMs : value.lastSuccessMs,
      refreshing: value.refreshing,
      error: value.error,
    );
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
