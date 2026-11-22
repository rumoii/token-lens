import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/pricing_update.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/update/update_check.dart';

class _Timer implements Timer {
  _Timer(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int get tick => isActive ? 0 : 1;
  @override
  void cancel() => isActive = false;
  void fire() {
    expect(isActive, true);
    cancel();
    callback();
  }
}

class _Harness {
  _Harness() {
    controller = PricingUpdateController(
      readPreferences: () => preferences,
      savePreferences: (value) async => preferences = value,
      install: (text) async {
        installs++;
        return result;
      },
      remove: () async => removes++,
      sync: () async {
        syncs++;
        return true;
      },
      clock: () => now,
      request: (uri, headers, cancel) async {
        expect(
          uri.toString(),
          'https://raw.githubusercontent.com/rumoii/token-lens/main/app/rust/src/stats/pricing-catalog.json',
        );
        expect(headers, {
          'Accept': 'application/json',
          'User-Agent': 'TokenLens-Pricing',
        });
        requests++;
        if (request case final pending?) return pending.future;
        return response;
      },
      createTimer: (delay, callback) {
        final timer = _Timer(delay, callback);
        timers.add(timer);
        return timer;
      },
    );
    addTearDown(controller.dispose);
  }
  late final PricingUpdateController controller;
  UiPreferences preferences = const UiPreferences(onboarded: true);
  DateTime now = DateTime.utc(2026, 11, 22);
  int requests = 0, installs = 0, removes = 0, syncs = 0;
  final timers = <_Timer>[];
  UpdateResponse response = const UpdateResponse(200, '{}');
  StatsPriceInstall result = const StatsPriceInstall(kind: 'unchanged');
  Completer<UpdateResponse>? request;
  _Timer timer(Duration duration) =>
      timers.lastWhere((value) => value.isActive && value.delay == duration);
}

void main() {
  test('15 秒超时和超出 1 MiB 的正文都不安装', () async {
    final h = _Harness()..request = Completer<UpdateResponse>();
    final check = h.controller.check();
    await Future<void>.delayed(Duration.zero);
    h.timer(const Duration(seconds: 15)).fire();
    await check;
    expect(h.preferences.pricingLastKind, 'offline');
    h.request!.complete(h.response);
    expect(h.installs, 0);
    h.request = null;
    h.response = UpdateResponse(200, ' ' * ((1 << 20) + 1));
    await h.controller.check();
    expect(h.preferences.pricingLastKind, 'invalid');
    expect(h.installs, 0);
    expect(h.preferences.pricingCheckedMs, isNull);
  });

  test('10 秒首次判断，每小时判断，24 小时间隔和手动重试', () async {
    final h = _Harness();
    h.response = const UpdateResponse(503, '');
    h.controller.start();
    h.timer(const Duration(seconds: 10)).fire();
    await Future<void>.delayed(Duration.zero);
    expect(h.requests, 1);
    expect(h.preferences.pricingLastKind, 'offline');
    h.now = h.now.add(const Duration(hours: 1));
    h.timer(const Duration(hours: 1)).fire();
    await Future<void>.delayed(Duration.zero);
    expect(h.requests, 1);
    await h.controller.check();
    expect(h.requests, 2);
    h.now = h.now.add(const Duration(hours: 24));
    h.timer(const Duration(hours: 1)).fire();
    await Future<void>.delayed(Duration.zero);
    expect(h.requests, 3);
  });

  test('上次尝试在未来时自动检查，并从当前时间重新计算间隔', () async {
    final h = _Harness();
    h.preferences = h.preferences.copyWith(
      pricingLastAttemptMs: h.now
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
    await h.controller.check(automatic: true);
    expect(h.requests, 1);
    expect(h.preferences.pricingLastAttemptMs, h.now.millisecondsSinceEpoch);
    await h.controller.check(automatic: true);
    expect(h.requests, 1);
  });

  test('同一时间只有一次检查，关闭后丢弃迟到结果，删除并触发同步', () async {
    final h = _Harness()..request = Completer<UpdateResponse>();
    final checking = h.controller.check();
    await Future<void>.delayed(Duration.zero);
    await h.controller.check();
    expect(h.requests, 1);
    final disabling = h.controller.setAutomatic(false);
    h.request!.complete(h.response);
    await Future.wait([checking, disabling]);
    expect(h.installs, 0);
    expect(h.removes, 1);
    expect(h.syncs, 1);
    expect(h.preferences.autoUpdatePricing, false);
  });

  test('六种结果、合法检查时间和安装信息', () async {
    final h = _Harness();
    for (final kind in [
      'older',
      'unchanged',
      'invalid',
      'installed',
      'limited',
      'offline',
    ]) {
      h.result = StatsPriceInstall(
        kind: kind,
        publishedAt: '2026-11-23',
        newlyPriced: 2,
      );
      h.response = UpdateResponse(switch (kind) {
        'limited' => 429,
        'offline' => 302,
        _ => 200,
      }, '{}');
      await h.controller.check();
      expect(h.preferences.pricingLastKind, kind);
      expect(
        h.preferences.pricingUpdatedNote?.newlyPriced,
        kind == 'installed' ? 2 : null,
      );
    }
    expect(h.installs, 4);
    expect(h.syncs, 1);
    expect(h.preferences.pricingCheckedMs, h.now.millisecondsSinceEpoch);
  });
}
