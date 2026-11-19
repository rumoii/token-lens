import 'src/rust/api/stats.dart';

export 'src/rust/api/stats.dart';

abstract interface class StatsGateway {
  Future<StatsSummary> summary(StatsFilter filter);
  Future<StatsTimeseries> timeseries(String granularity, StatsFilter filter);
  Future<StatsMatrix> matrix(String granularity, String by, StatsFilter filter);
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter);
  Future<StatsRequests> requestList(
    StatsFilter filter,
    StatsRequestQuery query,
  );
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  });
  Future<StatsSessionDetail?> sessionDetail(
    String source,
    String sessionId,
    String granularity, {
    StatsFilter filter = const StatsFilter(),
  });
  Future<StatsSources> sources();
  Future<StatsPricing> pricing();
  Future<StatsDiscovery> discovery({bool fresh = false});
  Future<StatsHealth> health();
  Future<StatsSync> sync({String trigger = 'manual'});
  Future<String> exportDiagnostics(String directory);
  Future<void> logError(String type, String message, String stack);
  Future<void> shutdown();
}

abstract interface class StatsProgressGateway {
  Future<StatsSyncProgress?> syncProgress();
}

abstract interface class StatsUsageExporter {
  Future<String> exportUsage({
    required String by,
    required String period,
    required StatsFilter filter,
    required String format,
    required bool projectPaths,
    required String directory,
  });
}

class RustStatsGateway
    implements StatsGateway, StatsProgressGateway, StatsUsageExporter {
  RustStatsGateway(this.client);
  final StatsClient client;
  int get _offset => DateTime.now().timeZoneOffset.inMinutes;
  @override
  Future<StatsRequests> requestList(
    StatsFilter filter,
    StatsRequestQuery query,
  ) => client.requests(filter: filter, query: query, offsetMinutes: _offset);
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
    String granularity, {
    StatsFilter filter = const StatsFilter(),
  }) => client.sessionDetailInPeriod(
    source: source,
    sessionId: sessionId,
    granularity: granularity,
    filter: filter,
    offsetMinutes: _offset,
  );
  @override
  Future<StatsSources> sources() => client.sources();
  @override
  Future<StatsPricing> pricing() => client.pricing();
  @override
  Future<StatsDiscovery> discovery({bool fresh = false}) =>
      client.discovery(fresh: fresh);
  @override
  Future<StatsHealth> health() => client.health();
  @override
  Future<StatsSyncProgress?> syncProgress() => client.syncProgress();
  @override
  Future<StatsSync> sync({String trigger = 'manual'}) =>
      client.syncTriggered(trigger: trigger);
  @override
  Future<String> exportDiagnostics(String directory) =>
      client.exportDiagnostics(directory: directory);
  @override
  Future<String> exportUsage({
    required String by,
    required String period,
    required StatsFilter filter,
    required String format,
    required bool projectPaths,
    required String directory,
  }) => client.exportUsage(
    request: StatsUsageExport(
      by: by,
      period: period,
      filter: filter,
      format: format,
      projectPaths: projectPaths,
      directory: directory,
    ),
    offsetMinutes: _offset,
  );
  @override
  Future<void> logError(String type, String message, String stack) =>
      client.logError(errorType: type, message: message, stack: stack);
  @override
  Future<void> shutdown() => client.shutdown();
}
