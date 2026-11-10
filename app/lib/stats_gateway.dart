import 'src/rust/api/stats.dart';

export 'src/rust/api/stats.dart';

abstract interface class StatsGateway {
  Future<StatsSummary> summary(StatsFilter filter);
  Future<StatsTimeseries> timeseries(String granularity, StatsFilter filter);
  Future<StatsMatrix> matrix(String granularity, String by, StatsFilter filter);
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter);
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  });
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity,
  );
  Future<StatsSources> sources();
  Future<StatsPricing> pricing();
  Future<StatsSync> sync();
  Future<void> shutdown();
}

class RustStatsGateway implements StatsGateway {
  RustStatsGateway(this.client);
  final StatsClient client;
  int get _offset => DateTime.now().timeZoneOffset.inMinutes;
  @override
  Future<StatsSummary> summary(StatsFilter filter) =>
      client.summary(filter: filter, offsetMinutes: _offset);
  @override
  Future<StatsTimeseries> timeseries(String granularity, StatsFilter filter) =>
      client.timeseries(
        granularity: granularity,
        filter: filter,
        offsetMinutes: _offset,
      );
  @override
  Future<StatsMatrix> matrix(
    String granularity,
    String by,
    StatsFilter filter,
  ) => client.matrix(
    granularity: granularity,
    by: by,
    filter: filter,
    offsetMinutes: _offset,
  );
  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) =>
      client.breakdown(by: by, filter: filter, offsetMinutes: _offset);
  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) => client.sessions(
    filter: filter,
    limit: limit,
    cursor: cursor,
    offsetMinutes: _offset,
  );
  @override
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity,
  ) => client.sessionDetail(
    source: source,
    sessionId: sessionId,
    granularity: granularity,
    offsetMinutes: _offset,
  );
  @override
  Future<StatsSources> sources() => client.sources();
  @override
  Future<StatsPricing> pricing() => client.pricing();
  @override
  Future<StatsSync> sync() => client.sync_();
  @override
  Future<void> shutdown() => client.shutdown();
}
