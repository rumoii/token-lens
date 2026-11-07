import 'src/rust/api/stats.dart' as native;

export 'src/rust/api/stats.dart' show StatsTotals, StatsGroup, StatsRun;

class StatsOverview {
  const StatsOverview({
    required this.totals,
    this.sources = const [],
    this.models = const [],
    this.lastRun,
    this.generatedAt,
  });
  final native.StatsTotals totals;
  final List<native.StatsGroup> sources;
  final List<native.StatsGroup> models;
  final native.StatsRun? lastRun;
  final String? generatedAt;
}

abstract interface class StatsGateway {
  Future<StatsOverview> load();
  Future<void> sync();
  Future<void> shutdown();
}

class RustStatsGateway implements StatsGateway {
  RustStatsGateway(this.client);
  final native.StatsClient client;

  @override
  Future<StatsOverview> load() async {
    const filter = native.StatsFilter();
    final offset = DateTime.now().timeZoneOffset.inMinutes;
    final summary = await client.summary(filter: filter, offsetMinutes: offset);
    final sources = await client.breakdown(
      by: 'source',
      filter: filter,
      offsetMinutes: offset,
    );
    final models = await client.breakdown(
      by: 'model',
      filter: filter,
      offsetMinutes: offset,
    );
    final run = await client.lastRun();
    return StatsOverview(
      totals: summary.totals,
      sources: sources.groups,
      models: models.groups,
      lastRun: run,
      generatedAt: summary.snapshot.generatedAt,
    );
  }

  @override
  Future<void> sync() async {
    await client.sync_();
  }

  @override
  Future<void> shutdown() => client.shutdown();
}
