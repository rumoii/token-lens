import 'dart:async';

import 'package:flutter/foundation.dart';

import 'stats_gateway.dart';

class StatsController extends ChangeNotifier {
  StatsController(this.gateway);
  final StatsGateway gateway;
  StatsOverview? overview;
  String? error;
  bool busy = false;
  bool loading = false;
  bool _closed = false;
  bool _disposed = false;
  Timer? _timer;
  Future<void>? _load;
  Future<void>? _sync;
  Future<void>? _shutdown;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    await load();
    if (_closed) return;
    _timer ??= Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(sync()),
    );
    await sync();
  }

  Future<void> load() {
    if (_closed) return Future.value();
    return _load ??= _read().whenComplete(() => _load = null);
  }

  Future<void> _read() async {
    loading = true;
    _notify();
    try {
      final result = await gateway.load();
      if (!_closed) {
        overview = result;
        error = null;
      }
    } catch (_) {
      if (!_closed) error = '无法读取统计，请重试同步。';
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> sync() {
    if (_closed) return Future.value();
    return _sync ??= _synchronize().whenComplete(() => _sync = null);
  }

  Future<void> _synchronize() async {
    busy = true;
    error = null;
    _notify();
    try {
      await gateway.sync();
      if (!_closed) await load();
    } catch (failure) {
      if (!_closed) {
        error = failure.toString().contains('SYNC_BUSY')
            ? '已有同步或采集任务在执行中，本次已跳过。'
            : failure.toString().contains('LEGACY_SYNC_LOCK')
            ? '检测到旧版采集锁，请退出旧版后处理遗留锁文件。'
            : '同步失败，已保留先前采集的数据。';
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    await gateway.shutdown();
    await _sync;
    await _load;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}
