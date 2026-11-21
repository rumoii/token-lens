import 'dart:io';
import 'dart:convert';
import 'dart:ui' show Rect;

import 'logic/period.dart';
import 'logic/format.dart';
import '../update/update_check.dart';

class MiniPreferences {
  const MiniPreferences({
    this.bounds,
    this.pinned = true,
    this.seconds = 10,
    this.projects = -1,
    this.chartMinutes = 15,
  });

  static const intervals = [5, 10, 15, 30, 60, 300];
  static const projectCounts = [-1, 3, 5, 10, 0];
  static const chartRanges = [15, 30, 60];
  final Rect? bounds;
  final bool pinned;
  final int seconds, projects, chartMinutes;

  MiniPreferences copyWith({
    Rect? bounds,
    bool? pinned,
    int? seconds,
    int? projects,
    int? chartMinutes,
  }) => MiniPreferences(
    bounds: bounds ?? this.bounds,
    pinned: pinned ?? this.pinned,
    seconds: seconds ?? this.seconds,
    projects: projects ?? this.projects,
    chartMinutes: chartMinutes ?? this.chartMinutes,
  );

  static MiniPreferences decode(Object? value) {
    if (value is! Map) return const MiniPreferences();
    final rect = value['bounds'];
    return MiniPreferences(
      bounds:
          rect is List &&
              rect.length == 4 &&
              rect.every((part) => part is num && part.isFinite)
          ? Rect.fromLTWH(
              (rect[0] as num).toDouble(),
              (rect[1] as num).toDouble(),
              (rect[2] as num).toDouble(),
              (rect[3] as num).toDouble(),
            )
          : null,
      pinned: value['pinned'] != false,
      seconds: value['seconds'] is int && intervals.contains(value['seconds'])
          ? value['seconds'] as int
          : 10,
      projects:
          value['projects'] is int && projectCounts.contains(value['projects'])
          ? value['projects'] as int
          : -1,
      chartMinutes:
          value['chartMinutes'] is int &&
              chartRanges.contains(value['chartMinutes'])
          ? value['chartMinutes'] as int
          : 15,
    );
  }

  Map<String, Object> encode() => {
    if (bounds case final b?) 'bounds': [b.left, b.top, b.width, b.height],
    'pinned': pinned,
    'seconds': seconds,
    'projects': projects,
    'chartMinutes': chartMinutes,
  };
}

class UiPreferences {
  const UiPreferences({
    this.appearance = 'light',
    this.tokenMode = 'compact',
    this._unitSystem,
    this.language = 'system',
    this.currency = 'CNY',
    this.period = const StatsPeriod(),
    this.onboarded = false,
    this.rates = defaultRates,
    this.rateSource = 'default',
    this.ratesFetchedAt,
    this.autoCheckUpdates = true,
    this.updateLastAttemptMs,
    this.updateResult,
    this.updateIgnoredVersion,
    this.hiddenTools = const [],
    this.density = 'comfortable',
    this.uiScale = 1.0,
    this.defaultPeriod = 'last',
    this.weekStart = 'monday',
    this.newsEnabled = true,
    this.mini = const MiniPreferences(),
    this.miniHintDismissed = false,
  }); // Null keeps the language default implicit.

  final String appearance, tokenMode, currency, language;
  final String? _unitSystem;

  String get unitSystem => unitSystemFor(language);
  String unitSystemFor(String resolvedLanguage) =>
      _unitSystem ?? (resolvedLanguage == 'en' ? 'english' : 'chinese');

  static String _language(Object? value) => switch (value) {
    'zh' => 'zh',
    'en' => 'en',
    _ => 'system',
  };
  final StatsPeriod period;
  final bool onboarded;
  final Map<String, num> rates;
  final String rateSource;
  final int? ratesFetchedAt;
  final bool autoCheckUpdates;
  final int? updateLastAttemptMs;
  final UpdateResult? updateResult;
  final String? updateIgnoredVersion;
  final List<String> hiddenTools;
  final String density, defaultPeriod, weekStart;
  final double uiScale;
  final bool newsEnabled;
  final MiniPreferences mini;
  final bool miniHintDismissed;
  double get spacing => density == 'compact' ? .75 : 1;
  int get weekStartsOn =>
      weekStart == 'sunday' ? DateTime.sunday : DateTime.monday;
  static const interfaceScales = [0.9, 1.0, 1.1, 1.25];
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
    String? language,
    StatsPeriod? period,
    bool? onboarded,
    Map<String, num>? rates,
    String? rateSource,
    Object? ratesFetchedAt = _unchanged,
    bool? autoCheckUpdates,
    Object? updateLastAttemptMs = _unchanged,
    Object? updateResult = _unchanged,
    Object? updateIgnoredVersion = _unchanged,
    List<String>? hiddenTools,
    String? density,
    double? uiScale,
    String? defaultPeriod,
    String? weekStart,
    bool? newsEnabled,
    MiniPreferences? mini,
    bool? miniHintDismissed,
  }) => UiPreferences(
    appearance: appearance ?? this.appearance,
    tokenMode: tokenMode ?? this.tokenMode,
    unitSystem: unitSystem ?? _unitSystem,
    language: _language(language ?? this.language),
    currency: currency ?? this.currency,
    period: period ?? this.period,
    onboarded: onboarded ?? this.onboarded,
    rates: rates ?? this.rates,
    rateSource: rateSource ?? this.rateSource,
    ratesFetchedAt: identical(ratesFetchedAt, _unchanged)
        ? this.ratesFetchedAt
        : _fetchedAt(ratesFetchedAt),
    autoCheckUpdates: autoCheckUpdates ?? this.autoCheckUpdates,
    density: density ?? this.density,
    uiScale: uiScale ?? this.uiScale,
    defaultPeriod: defaultPeriod ?? this.defaultPeriod,
    weekStart: weekStart ?? this.weekStart,
    newsEnabled: newsEnabled ?? this.newsEnabled,
    mini: mini ?? this.mini,
    miniHintDismissed: miniHintDismissed ?? this.miniHintDismissed,
    updateLastAttemptMs: identical(updateLastAttemptMs, _unchanged)
        ? this.updateLastAttemptMs
        : _fetchedAt(updateLastAttemptMs),
    updateResult: identical(updateResult, _unchanged)
        ? this.updateResult
        : updateResult as UpdateResult?,
    hiddenTools: hiddenTools == null
        ? this.hiddenTools
        : List.unmodifiable(hiddenTools),
    updateIgnoredVersion: identical(updateIgnoredVersion, _unchanged)
        ? this.updateIgnoredVersion
        : UpdateVersion.parse(updateIgnoredVersion)?.value,
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
            : 'light',
        tokenMode: normalizeTokenMode(value['tokenMode']),
        unitSystem: value['unitSystem'] == null
            ? null
            : normalizeTokenUnit(value['unitSystem']),
        language: _language(value['language']),
        currency: normalizeCurrency(value['currency'], fallback: 'CNY'),
        period: period,
        density: value['density'] == 'compact' ? 'compact' : 'comfortable',
        uiScale: interfaceScales.contains(value['uiScale'])
            ? (value['uiScale'] as num).toDouble()
            : 1.0,
        defaultPeriod:
            ['today', 'week', 'month'].contains(value['defaultPeriod'])
            ? value['defaultPeriod'] as String
            : 'last',
        weekStart: value['weekStart'] == 'sunday' ? 'sunday' : 'monday',
        newsEnabled: value['newsEnabled'] is bool ? value['newsEnabled'] : true,
        mini: MiniPreferences.decode(value['mini']),
        miniHintDismissed: value['miniHintDismissed'] == true,
        onboarded: value['onboarded'] is bool ? value['onboarded'] : false,
        rates: _rates(value['rates']),
        rateSource: _rateSource(value['rateSource']),
        ratesFetchedAt: _fetchedAt(value['ratesFetchedAt']),
        autoCheckUpdates: value['autoCheckUpdates'] is bool
            ? value['autoCheckUpdates']
            : true,
        updateLastAttemptMs: _fetchedAt(value['updateLastAttemptMs']),
        updateResult: _updateResult(value),
        hiddenTools: value['hiddenTools'] is List
            ? List.unmodifiable(
                (value['hiddenTools'] as List).whereType<String>().toSet(),
              )
            : const [],
        updateIgnoredVersion: UpdateVersion.parse(value['updateIgnoredVersion'])
            ?.value,
      );
    } catch (_) {
      return const UiPreferences();
    }
  }

  String encode() => jsonEncode({
    'appearance': appearance,
    'hiddenTools': hiddenTools,
    'tokenMode': tokenMode,
    if (_unitSystem != null) 'unitSystem': _unitSystem,
    'language': _language(language),
    'currency': normalizeCurrency(currency, fallback: 'CNY'),
    'period': {'period': period.period, 'from': period.from, 'to': period.to},
    'density': density,
    'uiScale': uiScale,
    'defaultPeriod': defaultPeriod,
    'weekStart': weekStart,
    'newsEnabled': newsEnabled,
    'mini': mini.encode(),
    'miniHintDismissed': miniHintDismissed,
    'onboarded': onboarded,
    'rates': _rates(rates),
    'rateSource': _rateSource(rateSource),
    'ratesFetchedAt': _fetchedAt(ratesFetchedAt),
    'autoCheckUpdates': autoCheckUpdates,
    'updateLastAttemptMs': _fetchedAt(updateLastAttemptMs),
    'updateKind': updateResult?.kind.name,
    'updateLatestVersion': updateResult?.kind == UpdateKind.available
        ? updateResult?.version
        : null,
    'updatePublishedAtMs': updateResult?.kind == UpdateKind.available
        ? _fetchedAt(updateResult?.publishedAt?.millisecondsSinceEpoch)
        : null,
    'updateIgnoredVersion': UpdateVersion.parse(updateIgnoredVersion)?.value,
  });

  static UpdateResult? _updateResult(Map<String, dynamic> value) {
    final kind = UpdateKind.values
        .where((k) => k.name == value['updateKind'])
        .firstOrNull;
    if (kind == null) return null;
    final version = UpdateVersion.parse(value['updateLatestVersion'])?.value;
    if (kind == UpdateKind.available && version == null) return null;
    final ms = _fetchedAt(value['updatePublishedAtMs']);
    DateTime? published;
    try {
      if (ms != null) {
        published = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
      }
    } catch (_) {
      /* Out-of-range dates are absent. */
    }
    return UpdateResult(
      kind,
      version: kind == UpdateKind.available ? version : null,
      publishedAt: kind == UpdateKind.available ? published : null,
    );
  }
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
