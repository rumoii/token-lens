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

abstract interface class StatsMiniGateway {
  Future<StatsMiniUsage> miniUsage(
    DateTime now,
    int windowMinutes,
    List<String> excluded,
  );
}

abstract interface class StatsSessionQueryGateway {
  Future<StatsSessions> querySessions(
    StatsFilter filter,
    StatsSessionQuery query,
  );
}

abstract interface class StatsComparisonGateway {
  Future<StatsComparison> comparison(
    String by,
    StatsFilter current,
    StatsFilter previous,
  );
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
    implements
        StatsGateway,
        StatsProgressGateway,
        StatsMiniGateway,
        StatsUsageExporter,
        StatsSessionQueryGateway,
        StatsComparisonGateway {
  RustStatsGateway(this.client);
  final StatsClient client;
  int get offsetMinutes => DateTime.now().timeZoneOffset.inMinutes;
  @override
  Future<StatsMiniUsage> miniUsage(
    DateTime now,
    int windowMinutes,
    List<String> excluded,
  ) {
    final local = now.toLocal();
    final midnight = DateTime(local.year, local.month, local.day);
    return client.miniUsage(
      localMidnightMs: midnight.millisecondsSinceEpoch,
      nowMs: local.millisecondsSinceEpoch,
      windowMinutes: windowMinutes,
      excludeSources: excluded,
    );
  }

  @override
  Future<StatsRequests> requestList(
    StatsFilter filter,
    StatsRequestQuery query,
  ) => client.requests(
    filter: filter,
    query: query,
    offsetMinutes: offsetMinutes,
  );
  @override
  Future<StatsSummary> summary(StatsFilter filter) =>
      client.summary(filter: filter, offsetMinutes: offsetMinutes);
  @override
  Future<StatsTimeseries> timeseries(String granularity, StatsFilter filter) =>
      client.timeseries(
        granularity: granularity,
        filter: filter,
        offsetMinutes: offsetMinutes,
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
    offsetMinutes: offsetMinutes,
  );
  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) =>
      client.breakdown(by: by, filter: filter, offsetMinutes: offsetMinutes);
  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) => client.sessions(
    filter: filter,
    limit: limit,
    cursor: cursor,
    offsetMinutes: offsetMinutes,
  );
  @override
  Future<StatsSessions> querySessions(
    StatsFilter filter,
    StatsSessionQuery query,
  ) => client.querySessions(
    filter: filter,
    query: query,
    offsetMinutes: offsetMinutes,
  );

  @override
  Future<StatsComparison> comparison(
    String by,
    StatsFilter current,
    StatsFilter previous,
  ) => client.comparison(
    by: by,
    current: current,
    previous: previous,
    offsetMinutes: offsetMinutes,
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
    offsetMinutes: offsetMinutes,
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
    offsetMinutes: offsetMinutes,
  );
  @override
  Future<void> logError(String type, String message, String stack) =>
      client.logError(errorType: type, message: message, stack: stack);
  @override
  Future<void> shutdown() => client.shutdown();
}
