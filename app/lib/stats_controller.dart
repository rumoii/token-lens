import 'dart:async';

import 'package:flutter/foundation.dart';

import 'stats_gateway.dart';
import 'stats/logic/period.dart';
import 'stats/preferences.dart';

class StatsHomeData {
  const StatsHomeData({
    required this.period,
    required this.summary,
    required this.days,
    required this.pairs,
    required this.matrix,
    required this.axis,
    required this.year,
    required this.yearTools,
    required this.recent,
    required this.sources,
    required this.pricing,
    required this.sidebar,
    this.previous,
    this.previousDays,
    this.previousHours,
  });
  final StatsPeriod period;
  final StatsSummary summary;
  final StatsTimeseries days, year;
  final StatsTimeseries? previousDays, previousHours;
  final StatsSummary? previous;
  final StatsBreakdown pairs, yearTools, sidebar;
  final StatsMatrix matrix;
  final PeriodAxis axis;
  final StatsSessions recent;
  final StatsSources sources;
  final StatsPricing pricing;
}

enum StatsSyncPhase { idle, running, conflict, success, error }

class StatsController extends ChangeNotifier {
  StatsController(
    this.gateway, {
    this.store,
    this.preferences = const UiPreferences(),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final StatsGateway gateway;
  final PreferencesStore? store;
  final DateTime Function() clock;
  UiPreferences preferences;
  StatsHomeData? overview;
  String? error, syncError, warning;
  final resourceErrors = <String, String>{};
  StatsSyncPhase phase = StatsSyncPhase.idle;
  bool loading = false;
  int ledgerVersion = 0;
  bool get busy =>
      phase == StatsSyncPhase.running ||
      phase == StatsSyncPhase.conflict ||
      phase == StatsSyncPhase.idle &&
          overview?.sources.lastRun?.status == 'running';
  bool get syncFailed =>
      syncError != null ||
      phase == StatsSyncPhase.error ||
      ['failed', 'abandoned'].contains(overview?.sources.lastRun?.status);
  bool get syncSuccessful =>
      phase == StatsSyncPhase.success ||
      [
        'ok',
        'completed_with_anomalies',
      ].contains(overview?.sources.lastRun?.status);
  bool _closed = false, _disposed = false, _started = false;
  int _generation = 0;
  Timer? _timer, _conflictTimer;
  Future<void>? _sync, _shutdown;
  final _reads = <Future<void>>{};
  void _notify() {
    if (!_closed && !_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (_started || _closed) return;
    _started = true;
    await load();
    if (_closed) return;
    _timer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(sync()),
    );
    await sync();
  }

  Future<void> setPreferences(UiPreferences value) async {
    if (_closed) return;
    final changed = value.period.query != preferences.period.query;
    preferences = value;
    _notify();
    final save = store?.write(value);
    if (changed) await load();
    await save;
  }

  Future<void> setPeriod(StatsPeriod period) =>
      setPreferences(preferences.copyWith(period: period));
  Future<void> load() {
    if (_closed) return Future.value();
    final work = _read(++_generation, preferences.period);
    _reads.add(work);
    unawaited(work.whenComplete(() => _reads.remove(work)));
    return work;
  }

  Future<void> _read(int ticket, StatsPeriod period) async {
    loading = true;
    error = null;
    resourceErrors.clear();
    _notify();
    final now = clock();
    final range = period.range(now), compare = period.compare(now);
    final filter = StatsFilter(from: range.from, to: range.to);
    final yearFilter = StatsFilter(
      from: dayKey(DateTime(now.year, now.month, now.day - 364)),
      to: dayKey(now),
    );
    final prevFilter = StatsFilter(from: compare?.from, to: compare?.to);
    const emptySnapshot = StatsSnapshot(
      generatedAt: '',
      priceVersion: '',
      tz: '',
      filters: StatsAppliedFilter(from: '', to: '', offsetMinutes: 0),
    );
    const emptyTotals = StatsTotals(
      grossTokens: 0,
      unpricedRecords: 0,
      recordCount: 0,
    );
    Future<T> resource<T>(String key, Future<T> request, T fallback) async {
      try {
        return await request;
      } catch (failure) {
        if (!_closed && ticket == _generation) {
          resourceErrors[key] = failure.toString();
        }
        return fallback;
      }
    }

    try {
      final results = await Future.wait<Object?>([
        gateway.summary(filter),
        gateway.timeseries('day', filter),
        gateway.breakdown('source_model', filter),
        resource(
          'year',
          gateway.timeseries('day', yearFilter),
          overview?.year ??
              const StatsTimeseries(
                granularity: 'day',
                points: [],
                snapshot: emptySnapshot,
              ),
        ),
        resource(
          'yearTools',
          gateway.breakdown('source', yearFilter),
          overview?.yearTools ??
              const StatsBreakdown(
                by: 'source',
                groups: [],
                totals: emptyTotals,
                snapshot: emptySnapshot,
              ),
        ),
        resource(
          'recent',
          gateway.sessions(const StatsFilter()),
          overview?.recent ??
              const StatsSessions(items: [], snapshot: emptySnapshot),
        ),
        resource(
          'sources',
          gateway.sources(),
          overview?.sources ??
              const StatsSources(sources: [], snapshot: emptySnapshot),
        ),
        resource(
          'pricing',
          gateway.pricing(),
          overview?.pricing ??
              const StatsPricing(
                priceVersion: '',
                currency: 'USD',
                provisional: false,
                models: [],
                counts: StatsPriceCounts(
                  verified: 0,
                  aggregate: 0,
                  unknown: 0,
                  local: 0,
                ),
                snapshot: emptySnapshot,
              ),
        ),
        gateway.breakdown('source', filter),
        if (compare != null && period.period != 'today')
          gateway.summary(prevFilter)
        else
          Future.value(null),
        if (compare != null)
          gateway.timeseries(
            period.period == 'today' ? 'hour' : 'day',
            prevFilter,
          )
        else
          Future.value(null),
      ]);
      if (_closed || ticket != _generation) return;
      final summary = results[0] as StatsSummary;
      final axis = period.axis(now, summary.activity.firstSeen);
      final matrix = await gateway.matrix(axis.granularity, 'source', filter);
      if (_closed || ticket != _generation) return;
      overview = StatsHomeData(
        period: period,
        summary: summary,
        days: results[1] as StatsTimeseries,
        pairs: results[2] as StatsBreakdown,
        year: results[3] as StatsTimeseries,
        yearTools: results[4] as StatsBreakdown,
        recent: results[5] as StatsSessions,
        sources: results[6] as StatsSources,
        pricing: results[7] as StatsPricing,
        sidebar: results[8] as StatsBreakdown,
        previous: results[9] as StatsSummary?,
        previousDays: period.period == 'today'
            ? null
            : results[10] as StatsTimeseries?,
        previousHours: period.period == 'today'
            ? results[10] as StatsTimeseries?
            : null,
        matrix: matrix,
        axis: axis,
      );
    } catch (failure) {
      if (!_closed && ticket == _generation) error = '请求失败：$failure';
    } finally {
      if (!_closed && ticket == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> sync() {
    if (_closed || phase == StatsSyncPhase.conflict) return Future.value();
    return _sync ??= _synchronize().whenComplete(() => _sync = null);
  }

  Future<void> _synchronize() async {
    phase = StatsSyncPhase.running;
    syncError = null;
    warning = null;
    _notify();
    try {
      final result = await gateway.sync();
      if (_closed) return;
      ledgerVersion++;
      warning = result.anomalies.isEmpty ? null : result.anomalies.join('；');
      phase = StatsSyncPhase.success;
      await load();
    } catch (failure) {
      if (_closed) return;
      if (failure.toString().contains('SYNC_BUSY')) {
        phase = StatsSyncPhase.conflict;
        _watchConflict(clock());
      } else {
        phase = StatsSyncPhase.error;
        syncError = failure.toString().contains('LEGACY_SYNC_LOCK')
            ? '检测到旧版采集锁，请退出旧版后处理遗留锁文件。'
            : '同步失败，已保留先前采集的数据。';
        // A failed ingestion can still have committed earlier files.
        await load();
      }
    } finally {
      _notify();
    }
  }

  void _watchConflict(DateTime started) {
    _conflictTimer?.cancel();
    _conflictTimer = Timer(const Duration(seconds: 2), () async {
      try {
        final status = await gateway.sources();
        if (_closed) return;
        final run = status.lastRun;
        if (run?.status == 'ok' || run?.status == 'completed_with_anomalies') {
          ledgerVersion++;
          phase = StatsSyncPhase.success;
          warning = run!.anomalies.isEmpty ? null : run.anomalies.join('；');
          await load();
        } else if (run?.status == 'failed' || run?.status == 'abandoned') {
          phase = StatsSyncPhase.error;
          syncError = '最近的同步未完成';
          await load();
        } else if (clock().difference(started) >= const Duration(minutes: 2)) {
          phase = StatsSyncPhase.error;
          syncError = '等待超时，同步可能仍在进行';
        } else {
          _watchConflict(started);
        }
      } catch (_) {
        if (!_closed) {
          phase = StatsSyncPhase.error;
          syncError = '无法确认同步状态，请重试。';
        }
      }
      _notify();
    });
  }

  String get syncLabel {
    if (phase == StatsSyncPhase.conflict) return '已有同步在执行，正在等待完成';
    if (phase == StatsSyncPhase.running) return '正在同步';
    if (syncError != null) return syncError!;
    final run = overview?.sources.lastRun;
    if (run?.status == 'failed' || run?.status == 'abandoned') {
      return '最近的同步未完成';
    }
    if (run?.status == 'running') return '正在同步';
    final note =
        warning ??
        (run?.anomalies.isNotEmpty == true ? run!.anomalies.join('；') : null);
    if (note != null) return '同步完成，有异常警告：$note';
    if (phase == StatsSyncPhase.success ||
        run?.status == 'ok' ||
        run?.status == 'completed_with_anomalies') {
      final finished = DateTime.tryParse(run?.finishedAt ?? '');
      if (finished == null) return '已完成同步';
      final minutes = (clock().difference(finished).inMilliseconds / 60000)
          .round()
          .clamp(0, 1 << 30);
      return minutes < 1
          ? '刚刚完成同步'
          : minutes < 60
          ? '$minutes 分钟前完成'
          : minutes < 1440
          ? '${(minutes / 60).round()} 小时前完成'
          : '${(minutes / 1440).round()} 天前完成';
    }
    return '还没有同步记录';
  }

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    _closed = true;
    _generation++;
    _timer?.cancel();
    _conflictTimer?.cancel();
    await gateway.shutdown();
    await _sync;
    await Future.wait(_reads.toList());
    await store?.flush();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}
