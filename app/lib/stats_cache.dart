import 'dart:async';
import 'dart:convert';

import 'stats/logic/period.dart';
import 'stats_gateway.dart';

// Cached values are available to the UI before the next frame. The Future
// methods still follow the normal asynchronous contract.
final class StatsCacheHit<T> implements Future<T> {
  StatsCacheHit(this.value);

  final T value;
  late final Future<T> _future = Future.value(value);

  @override
  Stream<T> asStream() => _future.asStream();
  @override
  Future<T> catchError(Function onError, {bool Function(Object)? test}) =>
      _future.catchError(onError, test: test);
  @override
  Future<R> then<R>(FutureOr<R> Function(T) onValue, {Function? onError}) =>
      _future.then(onValue, onError: onError);
  @override
  Future<T> timeout(Duration timeLimit, {FutureOr<T> Function()? onTimeout}) =>
      _future.timeout(timeLimit, onTimeout: onTimeout);
  @override
  Future<T> whenComplete(FutureOr<void> Function() action) =>
      _future.whenComplete(action);
}

Future<List<T>> waitForStats<T>(List<Future<T>> reads) {
  if (reads.every((read) => read is StatsCacheHit<T>)) {
    return StatsCacheHit([
      for (final read in reads) (read as StatsCacheHit<T>).value,
    ]);
  }
  return Future.wait(reads);
}

Future<R> mapStats<T, R>(Future<T> read, FutureOr<R> Function(T) map) {
  if (read is! StatsCacheHit<T>) return read.then(map);
  final result = map(read.value);
  return result is Future<R> ? result : StatsCacheHit(result);
}

final class CachedStatsGateway
    implements StatsGateway, StatsSessionQueryGateway, StatsComparisonGateway {
  CachedStatsGateway(this._inner, this._clock);

  static const capacity = 128;
  final StatsGateway _inner;
  final DateTime Function() _clock;
  final _values = <Object, Object?>{};
  final _pending = <Object, Future<Object?>>{};
  (String, int)? _context;
  int _generation = 0;

  StatsProgressGateway? get progressGateway =>
      _inner is StatsProgressGateway ? _inner as StatsProgressGateway : null;
  StatsUsageExporter? get usageExporter =>
      _inner is StatsUsageExporter ? _inner as StatsUsageExporter : null;
  StatsSessionQueryGateway? get sessionQueryGateway =>
      _inner is StatsSessionQueryGateway ? this : null;
  StatsComparisonGateway? get comparisonGateway =>
      _inner is StatsComparisonGateway ? this : null;

  void clear() {
    _generation++;
    _values.clear();
    _pending.clear();
  }

  static Object _filter(StatsFilter f) => (
    f.from,
    f.to,
    f.source,
    f.model,
    f.project,
    f.missing,
    f.excludeSources == null ? null : jsonEncode(f.excludeSources),
  );

  Future<T> _read<T>(Object key, Future<T> Function() fetch) {
    final now = _clock();
    final gateway = _inner;
    final context = (
      dayKey(now),
      gateway is RustStatsGateway
          ? gateway.offsetMinutes
          : now.timeZoneOffset.inMinutes,
    );
    if (_context != context) {
      _context = context;
      clear();
    }
    if (_values.containsKey(key)) {
      final value = _values.remove(key) as T;
      _values[key] = value;
      return StatsCacheHit(value);
    }
    if (_pending[key] case final Future<T> pending) return pending;

    final generation = _generation;
    final future = Future<T>.sync(fetch).then(
      (value) {
        if (generation == _generation) {
          _pending.remove(key);
          _values[key] = value;
          if (_values.length > capacity) _values.remove(_values.keys.first);
        }
        return value;
      },
      onError: (Object error, StackTrace stack) {
        if (generation == _generation) _pending.remove(key);
        Error.throwWithStackTrace(error, stack);
      },
    );
    _pending[key] = future;
    return future;
  }

  @override
  Future<StatsSummary> summary(StatsFilter filter) =>
      _read(('summary', _filter(filter)), () => _inner.summary(filter));

  @override
  Future<StatsTimeseries> timeseries(String granularity, StatsFilter filter) =>
      _read((
        'timeseries',
        granularity,
        _filter(filter),
      ), () => _inner.timeseries(granularity, filter));

  @override
  Future<StatsMatrix> matrix(
    String granularity,
    String by,
    StatsFilter filter,
  ) => _read((
    'matrix',
    granularity,
    by,
    _filter(filter),
  ), () => _inner.matrix(granularity, by, filter));

  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) => _read((
    'breakdown',
    by,
    _filter(filter),
  ), () => _inner.breakdown(by, filter));

  @override
  Future<StatsRequests> requestList(
    StatsFilter filter,
    StatsRequestQuery query,
  ) => _read((
    'requestList',
    _filter(filter),
    query,
  ), () => _inner.requestList(filter, query));

  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) => _read((
    'sessions',
    _filter(filter),
    limit,
    cursor,
  ), () => _inner.sessions(filter, limit: limit, cursor: cursor));

  @override
  Future<StatsSessions> querySessions(
    StatsFilter filter,
    StatsSessionQuery query,
  ) => _read((
    'querySessions',
    _filter(filter),
    query,
  ), () => (_inner as StatsSessionQueryGateway).querySessions(filter, query));

  @override
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity, {
    StatsFilter filter = const StatsFilter(),
  }) => _read(
    ('sessionDetail', source, sessionId, granularity, _filter(filter)),
    () => _inner.sessionDetail(source, sessionId, granularity, filter: filter),
  );

  @override
  Future<StatsComparison> comparison(
    String by,
    StatsFilter current,
    StatsFilter previous,
  ) => _read(
    ('comparison', by, _filter(current), _filter(previous)),
    () => (_inner as StatsComparisonGateway).comparison(by, current, previous),
  );

  @override
  Future<StatsSources> sources() => _read('sources', _inner.sources);

  Future<StatsSources> sourcesFresh() => _inner.sources();

  @override
  Future<StatsPricing> pricing() => _read('pricing', _inner.pricing);

  @override
  Future<StatsDiscovery> discovery({bool fresh = false}) =>
      _inner.discovery(fresh: fresh);

  @override
  Future<StatsHealth> health() => _inner.health();

  @override
  Future<StatsSync> sync({String trigger = 'manual'}) =>
      _inner.sync(trigger: trigger);

  @override
  Future<String> exportDiagnostics(String directory) =>
      _inner.exportDiagnostics(directory);

  @override
  Future<void> logError(String type, String message, String stack) =>
      _inner.logError(type, message, stack);

  @override
  Future<void> shutdown() {
    clear();
    return _inner.shutdown();
  }
}
