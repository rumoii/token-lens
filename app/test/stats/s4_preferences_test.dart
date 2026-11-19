import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats_controller.dart';

import 'fake_gateway.dart';

Map<String, Object?> display(UiPreferences prefs) {
  final json = jsonDecode(prefs.encode()) as Map;
  return {
    for (final key in [
      'density',
      'uiScale',
      'defaultPeriod',
      'weekStart',
      'newsEnabled',
    ])
      key: json[key],
  };
}

void main() {
  const defaults = {
    'density': 'comfortable',
    'uiScale': 1.0,
    'defaultPeriod': 'last',
    'weekStart': 'monday',
    'newsEnabled': true,
  };
  test('S4 old and unknown display preferences preserve existing settings', () {
    for (final fields in [
      {},
      {
        'density': 'space',
        'uiScale': '1.25',
        'defaultPeriod': 'year',
        'weekStart': 7,
        'newsEnabled': 'false',
      },
    ]) {
      final prefs = UiPreferences.decode(
        jsonEncode({
          ...fields,
          'period': {'period': 'month'},
          'language': 'en',
          'onboarded': true,
          'autoCheckUpdates': false,
        }),
      );
      expect(display(prefs), defaults);
      expect(prefs.period.period, 'month');
      expect(prefs.language, 'en');
      expect(prefs.autoCheckUpdates, isFalse);
    }
  });

  test('S4 display and news preferences survive a store round trip', () async {
    final dir = await Directory.systemTemp.createTemp('s4-preferences-');
    addTearDown(() => dir.delete(recursive: true));
    final store = PreferencesStore(dir);
    for (final scale in [0.9, 1.0, 1.1, 1.25]) {
      final fields = {
        'density': 'compact',
        'uiScale': scale,
        'defaultPeriod': 'today',
        'weekStart': 'sunday',
        'newsEnabled': false,
      };
      final prefs = UiPreferences.decode(jsonEncode(fields));
      expect(await store.write(prefs.copyWith(currency: 'CNY')), isTrue);
      expect(display(await store.read()), fields);
    }
  });

  for (final (selected, expected) in [
    ('last', 'all'),
    ('today', 'today'),
    ('week', 'week'),
    ('month', 'month'),
  ]) {
    test(
      'S4 $selected applies at startup and manual changes are remembered',
      () async {
        final c = StatsController(
          FakeStatsGateway(),
          clock: () => demoNow,
          preferences: UiPreferences.decode(
            jsonEncode({
              'defaultPeriod': selected,
              'period': {'period': 'all'},
              'onboarded': true,
              'autoCheckUpdates': false,
            }),
          ),
        );
        addTearDown(c.dispose);
        expect(c.period.period, expected);
        expect(c.preferences.period.period, 'all');
        await c.setPeriod(
          const StatsPeriod('custom', '2026-11-01', '2026-11-04'),
        );
        await c.load();
        expect(c.preferences.period.period, 'custom');
        expect(c.overview?.period.period, 'custom');
        await c.setPreferences(
          UiPreferences.decode(
            jsonEncode({
              'defaultPeriod': 'today',
              'period': {
                'period': 'custom',
                'from': '2026-11-01',
                'to': '2026-11-04',
              },
              'onboarded': true,
              'autoCheckUpdates': false,
            }),
          ),
        );
        expect(c.preferences.period.period, 'custom');
      },
    );
  }
  for (final (date, from, previousFrom, previousTo, axisEnd) in [
    (
      DateTime(2026, 1, 1),
      '2025-12-28',
      '2025-12-21',
      '2025-12-25',
      '2026-01-03',
    ),
    (
      DateTime(2026, 2, 1),
      '2026-02-01',
      '2026-01-25',
      '2026-01-25',
      '2026-02-07',
    ),
  ]) {
    test('S4 Sunday week and comparison at $date', () async {
      final g = FakeStatsGateway();
      final c = StatsController(
        g,
        clock: () => date,
        preferences: UiPreferences.decode('{"weekStart":"sunday"}'),
      );
      addTearDown(c.dispose);
      await c.load();
      expect(g.requests, contains('summary:$from:${dayKey(date)}'));
      expect(g.requests, contains('summary:$previousFrom:$previousTo'));
      expect(c.overview?.axis.from, from);
      expect(c.overview?.axis.to, axisEnd);
    });
  }
}
