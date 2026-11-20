import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';

class _Gateway extends FakeStatsGateway {
  int discoveries = 0, healthReads = 0, exports = 0, errors = 0;

  @override
  Future<StatsDiscovery> discovery({bool fresh = false}) {
    discoveries++;
    return super.discovery(fresh: fresh);
  }

  @override
  Future<StatsHealth> health() {
    healthReads++;
    return super.health();
  }

  @override
  Future<String> exportDiagnostics(String directory) {
    exports++;
    return super.exportDiagnostics(directory);
  }

  @override
  Future<void> logError(String type, String message, String stack) {
    errors++;
    return super.logError(type, message, stack);
  }
}

void main() {
  late _Gateway fake;
  late StatsController controller;
  late StatsGateway cache;
  late DateTime now;
  const filter = StatsFilter();

  setUp(() {
    now = demoNow;
    fake = _Gateway();
    controller = StatsController(fake, clock: () => now);
    cache = controller.gateway;
    addTearDown(controller.dispose);
  });

  test(
    'equivalent filters share results and every filter field keys the cache',
    () async {
      const filters = [
        StatsFilter(),
        StatsFilter(from: '2026-11-01'),
        StatsFilter(to: '2026-11-01'),
        StatsFilter(source: 'claude'),
        StatsFilter(model: 'model'),
        StatsFilter(project: 'project'),
        StatsFilter(missing: 'project'),
        StatsFilter(excludeSources: ['codex,pi']),
        StatsFilter(excludeSources: ['codex', 'pi']),
      ];
      for (final filter in filters) {
        await cache.summary(filter);
      }
      for (final filter in filters) {
        await cache.summary(filter);
      }
      await cache.summary(StatsFilter(excludeSources: ['codex', 'pi']));
      expect(fake.requests, hasLength(filters.length));
    },
  );

  test('concurrent identical reads return the same Future', () async {
    fake.readBarrier = Completer<void>();
    final first = cache.summary(filter);
    final second = cache.summary(filter);
    fake.readBarrier!.complete();
    await Future.wait([first, second]);
    expect(second, same(first));
    expect(fake.requests, hasLength(1));
  });

  test(
    'failed reads are retried and the successful result is reused',
    () async {
      fake.failure = 'read failed';
      await expectLater(cache.summary(filter), throwsStateError);
      fake.failure = null;
      await cache.summary(filter);
      await cache.summary(filter);
      expect(fake.requests, hasLength(2));
    },
  );

  test(
    'changing the ledger version discards completed and pending reads',
    () async {
      await cache.pricing();
      fake.readBarrier = Completer<void>();
      final pending = cache.summary(filter);
      controller.ledgerVersion++;
      fake.readBarrier!.complete();
      await pending;
      await cache.summary(filter);
      await cache.pricing();
      await cache.summary(filter);
      expect(fake.requests, [
        'pricing',
        'summary:null:null',
        'summary:null:null',
        'pricing',
      ]);
    },
  );

  test(
    'crossing local midnight expires even an unchanged all-time filter',
    () async {
      await cache.summary(filter);
      await cache.summary(filter);
      now = DateTime(now.year, now.month, now.day + 1);
      await cache.summary(filter);
      await cache.summary(filter);
      expect(fake.requests, hasLength(2));
    },
  );

  test('the 129th entry evicts the least recently used result', () async {
    Future<StatsSummary> read(int id) =>
        cache.summary(StatsFilter(model: '$id'));
    for (var id = 0; id < 128; id++) {
      await read(id);
    }
    await read(0);
    await read(128);
    await read(0);
    expect(fake.requests, hasLength(129));
    await read(1);
    expect(fake.requests, hasLength(130));
  });

  test('uncached operations make a new gateway call each time', () async {
    for (var attempt = 0; attempt < 2; attempt++) {
      await cache.discovery(fresh: true);
      await cache.health();
      await cache.sync();
      await cache.exportDiagnostics('/synthetic');
      await cache.logError('fixture', 'test', '');
      await cache.shutdown();
    }
    expect([
      fake.discoveries,
      fake.healthReads,
      fake.syncs,
      fake.exports,
      fake.errors,
      fake.closes,
    ], everyElement(2));
  });
}
