import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/widgets/charts.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'f1_polish_test.dart' show mountPolish;
import 'fake_gateway.dart';

class RetryOverviewGateway extends FakeStatsGateway {
  Set<String> failures = {};
  final holds = <String, Completer<void>>{};
  final attempts = <String, int>{};

  bool annual(StatsFilter filter) =>
      filter.from ==
      dayKey(DateTime(demoNow.year, demoNow.month, demoNow.day - 364));

  Future<T> read<T>(String key, Future<T> Function() request) async {
    final fail = failures.contains(key);
    final attempt = (attempts[key] ?? 0) + 1;
    attempts[key] = attempt;
    final hold = holds[key];
    await hold?.future;
    if (fail) throw StateError('Synthetic $key failure $attempt');
    return request();
  }

  @override
  Future<StatsSummary> summary(StatsFilter filter) =>
      read('summary', () => super.summary(filter));
  @override
  Future<StatsPricing> pricing() => read('pricing', super.pricing);
  @override
  Future<StatsSources> sources() =>
      read('sources', () => FakeStatsGateway().sources());
  @override
  Future<StatsTimeseries> timeseries(String granularity, StatsFilter filter) =>
      annual(filter)
      ? read('year', () => super.timeseries(granularity, filter))
      : super.timeseries(granularity, filter);
  @override
  Future<StatsBreakdown> breakdown(String by, StatsFilter filter) =>
      annual(filter) && by == 'source'
      ? read('yearTools', () => super.breakdown(by, filter))
      : super.breakdown(by, filter);
  @override
  Future<StatsSessions> sessions(
    StatsFilter filter, {
    int limit = 5,
    String? cursor,
  }) => read(
    'recent',
    () => super.sessions(filter, limit: limit, cursor: cursor),
  );
}

Finder get savingsCard => find
    .ancestor(of: find.text('缓存帮你省了'), matching: find.byType(LensCard))
    .first;

Completer<void> heldRead() {
  final gate = Completer<void>();
  addTearDown(() {
    if (!gate.isCompleted) gate.complete();
  });
  return gate;
}

void expectResource(
  WidgetTester tester,
  StatsController c,
  String key, {
  required bool failed,
}) {
  if (failed) {
    expect(c.resourceErrors, contains(key));
  } else {
    expect(c.resourceErrors, isNot(contains(key)));
  }
  switch (key) {
    case 'pricing':
      final amount = find.descendant(
        of: savingsCard,
        matching: find.byType(MoneyText),
      );
      if (failed) {
        expect(amount, findsNothing);
        expect(
          find.textContaining('Synthetic pricing failure'),
          findsOneWidget,
        );
      } else {
        expect(amount, findsOneWidget);
        expect(tester.widget<MoneyText>(amount).value as num, greaterThan(0));
        expect(find.textContaining('Synthetic pricing failure'), findsNothing);
      }
    case 'year' || 'yearTools':
      if (failed) {
        expect(find.textContaining('Synthetic $key failure'), findsOneWidget);
        expect(find.byType(Heatmap), findsNothing);
      } else {
        expect(find.textContaining('Synthetic $key failure'), findsNothing);
        final map = tester.widget<Heatmap>(find.byType(Heatmap));
        expect(map.values.values.any((n) => n > 0), isTrue);
      }
    case 'recent':
      if (failed) {
        expect(find.textContaining('Synthetic recent failure'), findsOneWidget);
        expect(find.text('今天的会话'), findsNothing);
      } else {
        final card = find
            .ancestor(of: find.text('今天的会话'), matching: find.byType(LensCard))
            .first;
        expect(
          find.descendant(of: card, matching: find.text('lumen')),
          findsOneWidget,
        );
        expect(find.textContaining('Synthetic recent failure'), findsNothing);
      }
    case 'sources':
      expect(find.text('重试读取'), failed ? findsOneWidget : findsNothing);
      expect(find.text('今天还没有用量'), findsOneWidget);
      expect(find.text('看本月'), findsOneWidget);
      expect(find.text('看全部'), findsOneWidget);
      expect(find.text('还没有任何用量'), findsNothing);
      if (!failed) {
        expect(c.overview!.sources.sources.any((s) => s.records > 0), isTrue);
      }
  }
}

void main() {
  for (final key in ['pricing', 'year', 'yearTools', 'recent', 'sources']) {
    for (final retryFails in [false, true]) {
      testWidgets('F1-R4 $key failure pending retry fails=$retryFails', (
        tester,
      ) async {
        final gateway = RetryOverviewGateway()
          ..failures = {key}
          ..empty = key == 'sources';
        final c = await mountPolish(tester, gateway: gateway);
        expectResource(tester, c, key, failed: true);
        final old = c.overview;
        final oldErrors = Map<String, String>.of(c.resourceErrors);
        final gate = heldRead();
        gateway.holds[key] = gate;
        gateway.failures = retryFails ? {key} : {};
        final retry = c.load();
        await tester.pumpAndSettle();
        expect(c.loading, isTrue);
        expect(c.overview, same(old));
        expect(c.resourceErrors, oldErrors);
        expectResource(tester, c, key, failed: true);
        gate.complete();
        await retry;
        await tester.pumpAndSettle();
        expect(c.loading, isFalse);
        expect(c.overview, isNot(same(old)));
        expectResource(tester, c, key, failed: retryFails);
        if (retryFails) expect(c.resourceErrors[key], isNot(oldErrors[key]));
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('F1-R4 data and complete error set publish together', (
    tester,
  ) async {
    final gateway = RetryOverviewGateway()..failures = {'pricing'};
    final c = await mountPolish(tester, gateway: gateway);
    final old = c.overview;
    final oldErrors = Map<String, String>.of(c.resourceErrors);
    final gate = heldRead();
    gateway.holds['recent'] = gate;
    gateway.failures = {'year'};
    final retry = c.load();
    await tester.pumpAndSettle();
    expect(c.overview, same(old));
    expect(c.resourceErrors, oldErrors);
    expectResource(tester, c, 'pricing', failed: true);
    expectResource(tester, c, 'year', failed: false);
    gate.complete();
    await retry;
    await tester.pumpAndSettle();
    expect(c.resourceErrors.keys, ['year']);
    expectResource(tester, c, 'pricing', failed: false);
    expectResource(tester, c, 'year', failed: true);
    expect(tester.takeException(), isNull);
  });
  for (final oldFails in [false, true]) {
    testWidgets(
      'F1-R4 obsolete read cannot replace data or errors oldFails=$oldFails',
      (tester) async {
        final gateway = RetryOverviewGateway();
        final c = await mountPolish(tester, gateway: gateway);
        final gate = heldRead();
        gateway.holds['pricing'] = gate;
        gateway.failures = oldFails ? {'pricing'} : {};
        final oldRead = c.load();
        gateway.holds.clear();
        gateway.failures = oldFails ? {} : {'pricing'};
        await c.load();
        await tester.pumpAndSettle();
        final current = c.overview;
        final currentErrors = Map<String, String>.of(c.resourceErrors);
        expectResource(tester, c, 'pricing', failed: !oldFails);
        gate.complete();
        await oldRead;
        await tester.pumpAndSettle();
        expect(c.overview, same(current));
        expect(c.resourceErrors, currentErrors);
        expect(c.loading, isFalse);
        expectResource(tester, c, 'pricing', failed: !oldFails);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final retryFails in [false, true]) {
    testWidgets('F1-R4 main error survives pending retry fails=$retryFails', (
      tester,
    ) async {
      final gateway = RetryOverviewGateway()..failures = {'summary'};
      final c = await mountPolish(tester, gateway: gateway);
      final oldError = c.error;
      expect(oldError, contains('Synthetic summary failure'));
      final gate = heldRead();
      gateway.holds['summary'] = gate;
      gateway.failures = retryFails ? {'summary'} : {};
      final retry = c.load();
      await tester.pumpAndSettle();
      expect(c.loading, isTrue);
      expect(c.error, oldError);
      expect(find.textContaining('Synthetic summary failure'), findsOneWidget);
      gate.complete();
      await retry;
      await tester.pumpAndSettle();
      expect(c.loading, isFalse);
      if (retryFails) {
        expect(c.error, contains('Synthetic summary failure'));
        expect(c.error, isNot(oldError));
      } else {
        expect(c.error, isNull);
        expect(find.byKey(const Key('home-hero')), findsOneWidget);
        expect(find.textContaining('Synthetic summary failure'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
