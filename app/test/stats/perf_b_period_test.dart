import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/detail_page.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';

final _now = DateTime(2026, 11, 11, 12);

class _Gateway extends FakeStatsGateway {
  final reads = <(String, String?)>[];
  final blocked = <String?, Completer<void>>{};
  String? failSummaryFrom;
  String status = 'ok';

  @override
  Future<StatsSummary> summary(StatsFilter filter) async {
    reads.add(('summary', filter.from));
    await blocked[filter.from]?.future;
    if (filter.from != null && filter.from == failSummaryFrom) {
      throw StateError('synthetic summary failure');
    }
    return super.summary(filter);
  }

  @override
  Future<StatsMatrix> matrix(
    String granularity,
    String by,
    StatsFilter filter,
  ) {
    reads.add(('matrix', filter.from));
    return super.matrix(granularity, by, filter);
  }

  @override
  Future<StatsTimeseries> timeseries(String granularity, StatsFilter filter) {
    reads.add(('timeseries', filter.from));
    return super.timeseries(granularity, filter);
  }

  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) {
    reads.add(('breakdown:$by', filter.from));
    return super.breakdown(by, filter);
  }

  @override
  Future<StatsSources> sources() async {
    final base = await super.sources();
    return StatsSources(
      sources: base.sources,
      snapshot: base.snapshot,
      lastRun: StatsSourceRun(
        id: status == 'ok' ? 1 : 2,
        status: status,
        attempted: 1,
        inserted: 1,
        updated: 0,
        unchanged: 0,
        rejected: 0,
        anomalyCount: 0,
        anomalies: const [],
      ),
    );
  }
}

StatsController _controller(_Gateway fake, {bool onboarded = true}) {
  final controller = StatsController(
    fake,
    clock: () => _now,
    preferences: UiPreferences(
      period: const StatsPeriod('month'),
      onboarded: onboarded,
    ),
  );
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  test('month, week, month reuses the first month without loading', () async {
    final fake = _Gateway();
    final c = _controller(fake);
    await c.load();
    final original = c.overview!;
    await c.setPeriod(const StatsPeriod('week'));
    final calls = fake.requests.length;
    final loadingStates = <bool>[];
    c.addListener(() => loadingStates.add(c.loading));
    final back = c.setPeriod(const StatsPeriod('month'));
    expect(c.loading, isFalse);
    await back;
    expect(loadingStates, everyElement(isFalse));
    expect(fake.requests, hasLength(calls));
    expect(c.overview!.summary, same(original.summary));
    expect(c.overview!.matrix, same(original.matrix));
    final yearFrom = dayKey(DateTime(_now.year, _now.month, _now.day - 364));
    expect(
      fake.reads.where((read) => read == ('timeseries', yearFrom)),
      hasLength(1),
    );
    expect(
      fake.reads.where((read) => read == ('breakdown:source', yearFrom)),
      hasLength(1),
    );
    for (final method in ['sources', 'pricing']) {
      expect(fake.requests.where((call) => call == method), hasLength(1));
    }
  });

  test(
    'sync completion reloads the same period at a new ledger version',
    () async {
      final fake = _Gateway();
      final c = _controller(fake);
      await c.load();
      fake.reads.clear();
      final version = c.ledgerVersion;
      await c.sync();
      expect(c.ledgerVersion, version + 1);
      expect(fake.reads, contains(('matrix', '2026-11-01')));
    },
  );

  for (final terminal in ['failed', 'abandoned', 'completed_with_anomalies']) {
    test(
      'status bypasses the cached response and invalidates on $terminal',
      () async {
        final fake = _Gateway();
        final c = _controller(fake);
        await c.load();
        fake.reads.clear();
        fake.status = terminal;
        final version = c.ledgerVersion;
        await c.retryStatus();
        expect(c.ledgerVersion, version + 1);
        expect(c.overview!.sources.lastRun!.status, terminal);
        expect(fake.reads, contains(('matrix', '2026-11-01')));
      },
    );
  }

  testWidgets(
    'prefetch waits for entry after onboarding and a ready overview',
    (tester) async {
      final fake = _Gateway();
      final c = _controller(fake, onboarded: false);
      await c.load();
      await c.sync();
      await tester.pump(Duration.zero);
      const today = ('summary', '2026-11-11');
      expect(fake.reads, isNot(contains(today)));

      c.ledgerVersion++;
      final current = fake.blocked['2026-11-01'] = Completer<void>();
      final entering = c.setPreferences(
        c.preferences.copyWith(onboarded: true),
      );
      await tester.pump(Duration.zero);
      expect(c.loading, isTrue);
      expect(fake.reads, isNot(contains(today)));
      current.complete();
      await entering;
      await tester.pump(Duration.zero);
      expect(c.loading, isFalse);
      expect(fake.reads, contains(today));
      await c.shutdown();
    },
  );

  testWidgets(
    'prefetch starts after the current load and visits other periods in order',
    (tester) async {
      final fake = _Gateway();
      final c = _controller(fake);
      final current = fake.blocked['2026-11-01'] = Completer<void>();
      final today = fake.blocked['2026-11-11'] = Completer<void>();
      final load = c.load();
      await tester.pump(Duration.zero);
      expect(fake.reads, isNot(contains(('summary', '2026-11-11'))));
      current.complete();
      await load;
      await tester.pump(Duration.zero);
      expect(c.loading, isFalse);
      expect(fake.reads, contains(('summary', '2026-11-11')));
      expect(fake.reads, isNot(contains(('summary', '2026-11-09'))));
      final notifications = <bool>[];
      c.addListener(() => notifications.add(c.loading));
      today.complete();
      await tester.pump(Duration.zero);
      expect(
        fake.reads.where((read) => read.$1 == 'matrix').map((read) => read.$2),
        ['2026-11-01', '2026-11-11', '2026-11-09', null],
      );
      expect(notifications, isEmpty);
      expect(c.preferences.period.period, 'month');
      await c.shutdown();
    },
  );

  for (final syncing in [false, true]) {
    testWidgets(
      'a ${syncing ? 'sync' : 'period switch'} stops an in-progress prefetch',
      (tester) async {
        final fake = _Gateway();
        final c = _controller(fake);
        final today = fake.blocked['2026-11-11'] = Completer<void>();
        await c.load();
        await tester.pump(Duration.zero);
        expect(fake.reads, contains(('summary', '2026-11-11')));
        final user = Completer<void>();
        if (syncing) {
          fake.syncBarrier = user;
        } else {
          fake.blocked[null] = user;
        }
        final work = syncing ? c.sync() : c.setPeriod(const StatsPeriod('all'));
        today.complete();
        await tester.pump(Duration.zero);
        expect(fake.reads, isNot(contains(('matrix', '2026-11-11'))));
        expect(fake.reads, isNot(contains(('summary', '2026-11-09'))));
        user.complete();
        await work;
        await c.shutdown();
      },
    );
  }

  testWidgets(
    'a failed background query leaves the foreground errors untouched',
    (tester) async {
      final fake = _Gateway()..failSummaryFrom = '2026-11-11';
      final c = _controller(fake);
      await c.load();
      await tester.pump(Duration.zero);
      expect(fake.reads, contains(('summary', '2026-11-11')));
      expect(fake.reads, contains(('matrix', '2026-11-09')));
      expect(c.resourceErrors, isEmpty);
      expect(c.error, isNull);
      expect(c.overview!.period.period, 'month');
      await c.shutdown();
    },
  );

  testWidgets(
    'returning to a detail period draws cached content on the first frame',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fake = _Gateway();
      final c = _controller(fake);
      Future<void> show(String period) => tester.pumpWidget(
        MaterialApp(
          theme: LensPalette(false).theme,
          home: Scaffold(
            body: StatsDetail(
              controller: c,
              query: 'period=$period&view=detail',
              onQuery: (_) {},
              onHome: () {},
              onSettings: () {},
            ),
          ),
        ),
      );
      await show('month');
      await tester.pumpAndSettle();
      await show('week');
      await tester.pumpAndSettle();
      final calls = fake.requests.length;
      await show('month');
      expect(find.byType(SkeletonLines), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is LinearProgressIndicator && widget.value == null,
        ),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(fake.requests, hasLength(calls));
      await c.shutdown();
    },
  );
}
