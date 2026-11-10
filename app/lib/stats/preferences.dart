import 'dart:io';
import 'dart:convert';

import 'logic/period.dart';
import 'logic/format.dart';

class UiPreferences {
  const UiPreferences({
    this.appearance = 'system',
    this.tokenMode = 'compact',
    this.unitSystem = 'chinese',
    this.currency = 'USD',
    this.period = const StatsPeriod(),
    this.onboarded = false,
    this.rates = defaultRates,
    this.rateSource = 'default',
    this.ratesFetchedAt,
  });
  final String appearance, tokenMode, unitSystem, currency;
  final StatsPeriod period;
  final bool onboarded;
  final Map<String, num> rates;
  final String rateSource;
  final int? ratesFetchedAt;
  static const _unchanged = Object();

  static Map<String, num> _rates(Object? value) {
    if (value is! Map) return defaultRates;
    final raw = value['CNY'];
    // The dashboard also accepts numeric strings from its stored rate map.
    final cny = raw is String ? double.tryParse(raw.trim()) : raw;
    return isValidRate(cny)
        ? Map.unmodifiable({'USD': 1.0, 'CNY': cny as num})
        : defaultRates;
  }

  static String _rateSource(Object? value) =>
      value == 'fetched' ? 'fetched' : 'default';
  static int? _fetchedAt(Object? value) =>
      value is int && value > 0 ? value : null;
  UiPreferences copyWith({
    String? appearance,
    String? tokenMode,
    String? unitSystem,
    String? currency,
    StatsPeriod? period,
    bool? onboarded,
    Map<String, num>? rates,
    String? rateSource,
    Object? ratesFetchedAt = _unchanged,
  }) => UiPreferences(
    appearance: appearance ?? this.appearance,
    tokenMode: tokenMode ?? this.tokenMode,
    unitSystem: unitSystem ?? this.unitSystem,
    currency: currency ?? this.currency,
    period: period ?? this.period,
    onboarded: onboarded ?? this.onboarded,
    rates: rates ?? this.rates,
    rateSource: rateSource ?? this.rateSource,
    ratesFetchedAt: identical(ratesFetchedAt, _unchanged)
        ? this.ratesFetchedAt
        : _fetchedAt(ratesFetchedAt),
  );
  static UiPreferences decode(String text) {
    try {
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic>) return const UiPreferences();
      for (final key in ['appearance', 'tokenMode', 'unitSystem', 'currency']) {
        if (value[key] != null && value[key] is! String) {
          return const UiPreferences();
        }
      }
      final rawPeriod = value['period'];
      var period = const StatsPeriod();
      if (rawPeriod != null) {
        if (rawPeriod is! Map<String, dynamic> ||
            rawPeriod['period'] is! String) {
          return const UiPreferences();
        }
        for (final key in ['from', 'to']) {
          if (rawPeriod[key] is String) {
            final date = DateTime.tryParse(rawPeriod[key]);
            if (date == null || dayKey(date) != rawPeriod[key]) {
              return const UiPreferences();
            }
          }
          if (rawPeriod[key] != null &&
              (rawPeriod[key] is! String ||
                  !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(rawPeriod[key]))) {
            return const UiPreferences();
          }
        }
        period = StatsPeriod(
          StatsPeriod.values.contains(rawPeriod['period'])
              ? rawPeriod['period']
              : 'week',
          rawPeriod['from'],
          rawPeriod['to'],
        );
      }
      return UiPreferences(
        appearance: ['system', 'light', 'dark'].contains(value['appearance'])
            ? value['appearance']
            : 'system',
        tokenMode: normalizeTokenMode(value['tokenMode']),
        unitSystem: value['unitSystem'] == null
            ? 'chinese'
            : normalizeTokenUnit(value['unitSystem']),
        currency: normalizeCurrency(value['currency']),
        period: period,
        onboarded: value['onboarded'] is bool ? value['onboarded'] : false,
        rates: _rates(value['rates']),
        rateSource: _rateSource(value['rateSource']),
        ratesFetchedAt: _fetchedAt(value['ratesFetchedAt']),
      );
    } catch (_) {
      return const UiPreferences();
    }
  }

  String encode() => jsonEncode({
    'appearance': appearance,
    'tokenMode': tokenMode,
    'unitSystem': unitSystem,
    'currency': normalizeCurrency(currency),
    'period': {'period': period.period, 'from': period.from, 'to': period.to},
    'onboarded': onboarded,
    'rates': _rates(rates),
    'rateSource': _rateSource(rateSource),
    'ratesFetchedAt': _fetchedAt(ratesFetchedAt),
  });
}

class PreferencesStore {
  PreferencesStore(this.directory);
  final Directory directory;
  static final _writes = <String, Future<bool>>{};
  static var _serial = 0;
  String get _path =>
      '${directory.absolute.path}${Platform.pathSeparator}ui-preferences.json';
  Future<UiPreferences> read() async {
    try {
      return UiPreferences.decode(await File(_path).readAsString());
    } catch (_) {
      return const UiPreferences();
    }
  }

  Future<bool> write(UiPreferences preferences) {
    final path = _path;
    final previous = _writes[path] ?? Future.value(true);
    final work = previous.then((_) async {
      try {
        await directory.create(recursive: true);
        final temp = File('$path.$pid.${_serial++}.tmp');
        await temp.writeAsString(preferences.encode(), flush: true);
        await temp.rename(path);
        return true;
      } catch (_) {
        return false;
      }
    });
    _writes[path] = work;
    work.then((_) {
      if (identical(_writes[path], work)) _writes.remove(path);
    });
    return work;
  }

  Future<void> flush() async {
    await _writes[_path];
  }
}
