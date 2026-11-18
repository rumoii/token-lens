import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/update/update_check.dart';
import 'package:token_lens_app/update/update_controller.dart';

import 'update_check_test.dart' show release, NoUpdateNetwork;

void main() {
  late UiPreferences preferences;
  late DateTime now;
  late UpdateController c;
  late int requests;
  late NoUpdateNetwork network;
  final saves = <UiPreferences>[];
  UpdateRequest? fake;
  setUp(() {
    network = NoUpdateNetwork();
    HttpOverrides.global = network;
    preferences = const UiPreferences(onboarded: true);
    now = DateTime(2026, 11, 17, 14, 2);
    requests = 0;
    saves.clear();
    fake = null;
    c = UpdateController(
      readPreferences: () => preferences,
      savePreferences: (value) async {
        preferences = value;
        saves.add(value);
      },
      clock: () => now,
      request: (uri, headers, cancel) {
        requests++;
        return fake?.call(uri, headers, cancel) ??
            Future.value(UpdateResponse(200, release()));
      },
    );
  });
  tearDown(() {
    c.dispose();
    expect(network.calls, 0);
    HttpOverrides.global = null;
  });

  testWidgets(
    '10 second startup then hourly checks use 24 hour attempt TTL including failures',
    (t) async {
      c.setCurrentVersion('0.1.0');
      c.start();
      c.start();
      await t.pump(const Duration(seconds: 9));
      expect(requests, 0);
      await t.pump(const Duration(seconds: 1));
      expect(requests, 1);
      expect(preferences.updateLastAttemptMs, now.millisecondsSinceEpoch);
      now = now.add(const Duration(hours: 23));
      await t.pump(const Duration(hours: 1));
      expect(requests, 1);
      now = now.add(const Duration(hours: 1));
      fake = (_, _, _) async => const UpdateResponse(500, '');
      await t.pump(const Duration(hours: 1));
      expect(requests, 2);
      expect(preferences.updateResult!.kind, UpdateKind.offline);
      await c.check(automatic: true);
      expect(requests, 2);
      preferences = preferences.copyWith(
        updateLastAttemptMs: now
            .add(const Duration(days: 2))
            .millisecondsSinceEpoch,
      );
      await c.check(automatic: true);
      expect(requests, 3);
      c.close();
      await t.pump(const Duration(days: 3));
      expect(requests, 3);
    },
  );
  test('onboarding, invalid version and automatic switch gate requests; manual ignores TTL and switch', () async {
    c.setCurrentVersion('0.1.0');
    preferences = preferences.copyWith(onboarded: false);
    await c.check(automatic: true);
    expect(requests, 0);
    preferences = preferences.copyWith(
      onboarded: true,
      autoCheckUpdates: false,
    );
    await c.check(automatic: true);
    expect(requests, 0);
    await c.check();
    await c.check();
    expect(requests, 2);
    c.setCurrentVersion('0.1.0+1');
    await c.check();
    await c.check(automatic: true);
    expect(requests, 2);
    expect(c.currentVersion, isNull);
    c.setCurrentVersion('0.1.0');
    preferences = preferences.copyWith(updateLastAttemptMs: null);
    await c.setAutomatic(true);
    expect(requests, 3);
    await c.setAutomatic(false);
    await c.setAutomatic(true);
    expect(requests, 3);
    now = now.add(const Duration(days: 1));
    await c.setAutomatic(false);
    await c.setAutomatic(true);
    expect(requests, 4);
  });
  test('concurrent triggers ignored; attempt is saved before completion; disposal cancels and drops late result', () async {
    c.setCurrentVersion('0.1.0');
    final pending = Completer<UpdateResponse>();
    UpdateCancellation? cancellation;
    fake = (_, _, cancel) {
      cancellation = cancel;
      return pending.future;
    };
    final work = c.check();
    await Future<void>.delayed(Duration.zero);
    expect(c.checking, true);
    expect(preferences.updateLastAttemptMs, now.millisecondsSinceEpoch);
    await c.check();
    await c.check(automatic: true);
    expect(requests, 1);
    c.close();
    expect(cancellation!.cancelled, true);
    final saved = saves.length;
    pending.complete(UpdateResponse(200, release()));
    await work;
    expect(saves.length, saved);
    expect(preferences.updateResult, isNull);
  });
  test(
    'hint ignores one version, reappears for next and disappears after upgrade',
    () async {
      c.setCurrentVersion('0.1.0');
      await c.check();
      expect(c.showHint, true);
      await c.ignoreVersion();
      expect(c.showHint, false);
      expect(preferences.updateIgnoredVersion, '0.2.0');
      expect(preferences.updateResult!.kind, UpdateKind.available);
      fake = (_, _, _) async => UpdateResponse(200, release(tag: 'v0.3.0'));
      await c.check();
      expect(c.showHint, true);
      c.setCurrentVersion('0.3.0');
      expect(c.showHint, false);
      c.setCurrentVersion('1.0.0');
      expect(c.showHint, false);
      c.setCurrentVersion('bad');
      expect(c.showHint, false);
    },
  );
  test('preferences round trip every result; invalid timestamps and version fields discarded independently', () {
    for (final kind in UpdateKind.values) {
      final value = UiPreferences(
        onboarded: true,
        autoCheckUpdates: false,
        updateLastAttemptMs: 1000,
        updateIgnoredVersion: '0.2.0',
        updateResult: UpdateResult(
          kind,
          version: '0.3.0',
          publishedAt: DateTime.utc(2026, 11, 17),
        ),
      );
      final loaded = UiPreferences.decode(value.encode());
      expect(loaded.updateResult!.kind, kind);
      expect(loaded.updateLastAttemptMs, 1000);
      expect(loaded.autoCheckUpdates, false);
      expect(loaded.updateIgnoredVersion, '0.2.0');
      expect(
        loaded.updateResult!.version,
        kind == UpdateKind.available ? '0.3.0' : null,
      );
    }
    for (final bad in [-1, 0, 1.5, '100', false]) {
      final loaded = UiPreferences.decode(
        jsonEncode({
          'updateLastAttemptMs': bad,
          'updateKind': 'available',
          'updateLatestVersion': '0.3.0',
          'updatePublishedAtMs': bad,
        }),
      );
      expect(loaded.updateLastAttemptMs, isNull);
      expect(loaded.updateResult!.publishedAt, isNull);
    }
  });
}
