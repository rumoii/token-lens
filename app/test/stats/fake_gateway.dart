import 'dart:async';

import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/logic/home_data.dart';

final demoNow = DateTime(2026, 11, 9, 0, 0);
const demoSnapshot = StatsSnapshot(
  generatedAt: '2026-11-09T08:45:00Z',
  priceVersion: 'demo',
  tz: 'America/New_York',
  filters: StatsAppliedFilter(
    from: '2025-11-10',
    to: '2026-11-09',
    offsetMinutes: -300,
  ),
);
const zeroCounts = StatsCounts(
  readFailed: 0,
  badLines: 0,
  badFields: 0,
  badTimes: 0,
  zeroUsage: 0,
  crossFileCopies: 0,
  relabeled: 0,
  reactivated: 0,
  replaced: 0,
  deactivated: 0,
  vanished: 0,
  revCorrections: 0,
  cumulativeDecrease: 0,
);

class FakeStatsGateway implements StatsGateway {
  int syncs = 0, closes = 0;
  String? failure, syncFailure;
  String? failingResource;
  Completer<void>? readBarrier, syncBarrier;
  bool empty = false, unknown = false;
  int tokens = 1080000;
  final requests = <String>[];
  final modelNames = [
    'claude-sonnet-5-5',
    'gpt-6.1-sol',
    'deepseek-v4',
    'qwen3.6',
    'kimi-k2.5',
    'claude-haiku-5-5',
    'claude-opus-5-5',
    'gemini-3-pro',
    'synthetic-unpriced-model',
    'aider-model',
  ];
  final toolIds = [
    'claude',
    'codex',
    'dsh',
    'qwen',
    'kimi',
    'cursor',
    'pi',
    'gemini',
    'opencode',
    'aider',
  ];
  bool _week(StatsFilter f) => f.from == '2026-11-09';
  int amount(StatsFilter f) => empty
      ? 0
      : _week(f)
      ? tokens
      : f.from == '2026-11-02'
      ? 2570000
      : f.from == '2026-11-01'
      ? 21460000
      : f.from == '2026-10-01'
      ? 12480000
      : f.from == null
      ? 467000000
      : 680000000;
  StatsTotals totals(StatsFilter f) => StatsTotals(
    grossTokens: amount(f),
    inputTokens: unknown ? null : amount(f) ~/ 10,
    outputTokens: unknown ? null : amount(f) ~/ 20,
    cacheReadTokens: unknown ? null : amount(f) * 8 ~/ 10,
    cacheWriteTokens: unknown ? null : amount(f) ~/ 20,
    costUsd: unknown
        ? null
        : _week(f)
        ? '1.040000'
        : '84.347200',
    costMicros: unknown
        ? null
        : _week(f)
        ? 1040000
        : 84347200,
    unpricedRecords: unknown
        ? 1
        : _week(f)
        ? 0
        : 4,
    recordCount: empty ? 0 : 100,
  );
  Future<void> _read(String name) async {
    requests.add(name);
    final gate = readBarrier;
    await gate?.future;
    if (failure != null || failingResource == name) {
      throw StateError(failure ?? '$name fixture failure');
    }
  }

  @override
  Future<StatsSummary> summary(StatsFilter filter) async {
    await _read('summary:${filter.from}:${filter.to}');
    const rolling = StatsWindow(
      grossTokens: 1080000,
      costUsd: '1.040000',
      costMicros: 1040000,
    );
    return StatsSummary(
      totals: totals(filter),
      activity: StatsActivity(
        sessions: empty
            ? 0
            : _week(filter)
            ? 1
            : 6,
        turns: 100,
        cacheHitRatio: unknown ? null : .88,
        firstSeen: '2025-10-05T12:00:00Z',
        lastSeen: '2026-11-09T08:44:00Z',
      ),
      rolling: const StatsRolling(last7D: rolling, last30D: rolling),
      snapshot: demoSnapshot,
    );
  }

  List<StatsGroup> groups(StatsFilter filter, {String by = 'source_model'}) {
    if (empty) return [];
    final single = _week(filter);
    final n = single ? 1 : 10;
    final weights = filter.from == '2026-11-01'
        ? [262, 342, 24, 0, 26, 101, 60, 81, 104, 0]
        : [350, 240, 40, 70, 30, 74, 71, 60, 45, 20];
    return [
      for (var i = 0; i < n; i++)
        StatsGroup(
          key: by == 'source' ? toolIds[i] : '${toolIds[i]}|${modelNames[i]}',
          source: toolIds[i],
          model: modelNames[i],
          grossTokens: single
              ? tokens
              : (amount(filter) * weights[i] / 1000).round(),
          inputTokens: unknown ? null : 160000,
          cacheReadTokens: unknown
              ? null
              : single
              ? 880000
              : (amount(filter) * weights[i] / 1000 * .88).round(),
          costUsd: unknown || i == 8
              ? null
              : i == 0
              ? '1.040000'
              : '0.340000',
          costMicros: unknown || i == 8
              ? null
              : i == 0
              ? 1040000
              : 340000,
          unpricedRecords: unknown || i == 8 ? 1 : 0,
          recordCount: 20,
          priceState: i == 8 ? 'unknown' : 'verified',
        ),
    ];
  }

  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) async {
    await _read('breakdown:$by');
    return StatsBreakdown(
      by: by,
      groups: groups(filter, by: by),
      totals: totals(filter),
      snapshot: demoSnapshot,
    );
  }

  @override
  Future<StatsTimeseries> timeseries(
    String granularity,
    StatsFilter filter,
  ) async {
    await _read('timeseries:$granularity');
    if (granularity == 'hour' && filter.from == '2026-11-08') {
      return StatsTimeseries(
        granularity: granularity,
        points: [],
        snapshot: demoSnapshot,
      );
    }
    final start = DateTime.parse(filter.from ?? '2025-11-10');
    final end = DateTime.parse(filter.to ?? '2026-11-09');
    var keys = bucketKeys(granularity, (
      from: dayKey(start),
      to: dayKey(end),
    ), demoNow);
    return StatsTimeseries(
      granularity: granularity,
      points: empty
          ? []
          : [
              for (var i = 0; i < keys.length; i++)
                if (i % 13 != 7)
                  StatsBucket(
                    bucket: keys[i],
                    grossTokens: keys.length == 1
                        ? amount(filter)
                        : keys.length > 100
                        ? (i % 9 + 1) * 1350000
                        : (i % 5 + 1) * 220000,
                    recordCount: 1,
                    unpricedRecords: 0,
                    costUsd: '1.040000',
                    costMicros: 1040000,
                  ),
            ],
      snapshot: demoSnapshot,
      unallocated: _week(filter)
          ? null
          : const StatsUnallocated(
              grossTokens: 450000,
              costUsd: '0.3',
              costMicros: 300000,
              recordCount: 1,
              reason: '跨时段快照',
            ),
    );
  }

  @override
  Future<StatsMatrix> matrix(
    String granularity,
    String by,
    StatsFilter filter,
  ) async {
    await _read('matrix:$granularity:$by');
    final axis = StatsPeriod(
      _week(filter)
          ? 'week'
          : filter.from == null
          ? 'all'
          : filter.from == '2026-11-01'
          ? 'month'
          : 'today',
    ).axis(demoNow, '2025-11-10T12:00:00Z');
    final keys = bucketKeys(granularity, (
      from: axis.from,
      to: axis.to,
    ), demoNow);
    return StatsMatrix(
      granularity: granularity,
      by: by,
      rows: empty
          ? []
          : [
              for (var i = 0; i < keys.length; i++)
                if (keys[i].compareTo(
                      granularity == 'month'
                          ? '2026-11'
                          : granularity == 'hour'
                          ? nowBucketKey('hour', demoNow)
                          : '2026-11-09',
                    ) <=
                    0)
                  for (final g in groups(filter))
                    StatsBucket(
                      bucket: keys[i],
                      key: g.source,
                      grossTokens: _week(filter)
                          ? tokens
                          : (g.grossTokens / keys.length * (i % 3 + 1) / 2)
                                .round(),
                      costUsd: g.costUsd,
                      costMicros: g.costMicros,
                      unpricedRecords: g.unpricedRecords,
                      recordCount: 1,
                    ),
            ],
      snapshot: demoSnapshot,
      unallocated: _week(filter)
          ? null
          : const StatsUnallocated(
              grossTokens: 450000,
              costUsd: '0.3',
              costMicros: 300000,
              recordCount: 1,
              reason: '跨时段快照',
            ),
    );
  }

  @override
  Future<StatsSessions> sessions(StatsFilter filter, {int limit = 5}) async {
    await _read('sessions:$limit');
    return StatsSessions(
      items: empty
          ? []
          : [
              for (var i = 0; i < limit; i++)
                StatsSessionItem(
                  source: toolIds[[0, 2, 0, 1, 3][i % 5]],
                  sessionId: 'session-$i',
                  projectKey: [
                    'lumen',
                    'harbor-api',
                    'atlas',
                    'token-lens',
                    'studio',
                  ][i % 5],
                  startedAt: '2026-11-09T06:00:00Z',
                  lastSeenAt: demoNow
                      .toUtc()
                      .subtract(Duration(minutes: i * 190 + 1))
                      .toIso8601String(),
                  grossTokens: [1080000, 257000, 1200000, 480000, 93000][i % 5],
                  costUsd: i == 8 ? null : '1.04',
                  costMicros: i == 8 ? null : 1040000,
                  recordCount: 5,
                ),
            ],
      snapshot: demoSnapshot,
    );
  }

  @override
  Future<StatsSources> sources() async {
    await _read('sources');
    return StatsSources(
      sources: [
        for (var i = 0; i < toolIds.length; i++)
          StatsSource(
            source: toolIds[i],
            evidence: 'demo',
            status: 'ready',
            firstObservedAt:
                '2025-10-${([1, 0, 2, 6, 3, 5, 7, 8, 4, 9][i] + 5).toString().padLeft(2, '0')}T12:00:00Z',
            records: empty ? 0 : 10,
            recordMode: 'event',
            retention: const StatsRetention(reviewable: 10, logsGone: 0),
            checks: const StatsSourceChecks(
              timeOutOfRange: 0,
              hugeRequests: 0,
              nullModel: 0,
              mixedKindSessions: 0,
            ),
            limits: [],
            notes: [],
          ),
      ],
      lastRun: StatsSourceRun(
        status: 'ok',
        finishedAt: demoNow.toUtc().toIso8601String(),
        attempted: 10,
        inserted: 0,
        updated: 0,
        unchanged: 10,
        rejected: 0,
        anomalyCount: 0,
        anomalies: [],
      ),
      snapshot: demoSnapshot,
    );
  }

  @override
  Future<StatsPricing> pricing() async {
    await _read('pricing');
    return StatsPricing(
      priceVersion: 'demo',
      currency: 'USD',
      provisional: false,
      models: [
        for (final model in modelNames)
          StatsModelPrice(
            model: model,
            records: 10,
            state: model == 'synthetic-unpriced-model' ? 'unknown' : 'verified',
            billing: 'metered',
            localRecords: 0,
            localProviders: {},
            priceMarks: {},
            prices: model == 'synthetic-unpriced-model'
                ? null
                : const StatsPrices(input: 3, cacheRead: 1.8, output: 15),
          ),
      ],
      counts: const StatsPriceCounts(
        verified: 4,
        aggregate: 0,
        unknown: 1,
        local: 0,
      ),
      snapshot: demoSnapshot,
    );
  }

  @override
  Future<StatsSync> sync() async {
    syncs++;
    if (syncFailure != null) throw StateError(syncFailure!);
    await syncBarrier?.future;
    return const StatsSync(
      attempted: 10,
      inserted: 0,
      updated: 0,
      unchanged: 10,
      rejected: 0,
      repriced: 0,
      counts: zeroCounts,
      anomalies: [],
      fileCount: 10,
      durationMs: 1,
    );
  }

  @override
  Future<void> shutdown() async {
    closes++;
    if (readBarrier != null && !readBarrier!.isCompleted) {
      readBarrier!.complete();
    }
    if (syncBarrier != null && !syncBarrier!.isCompleted) {
      syncBarrier!.complete();
    }
  }
}
