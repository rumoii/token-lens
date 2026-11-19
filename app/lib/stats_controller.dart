import 'l10n/app_strings.dart';
import 'l10n/sync_messages.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'stats_gateway.dart';
import 'stats/logic/period.dart';
import 'stats/logic/tools.dart';
import 'stats/preferences.dart';
import 'news_controller.dart';
import 'update/update_check.dart';
import 'update/update_controller.dart';

class StatsHomeData {
  const StatsHomeData({
    required this.period,
    required this.summary,
    required this.days,
    required this.pairs,
    required this.matrix,
    required this.axis,
    required this.year,
    required this.yearTools,
    required this.recent,
    required this.sources,
    required this.pricing,
    required this.sidebar,
    this.previous,
    this.previousDays,
    this.previousHours,
    this.comparison,
  });
  final StatsPeriod period;
  final StatsSummary summary;
  final StatsTimeseries days, year;
  final StatsTimeseries? previousDays, previousHours;
  final StatsSummary? previous;
  final StatsComparison? comparison;
  final StatsBreakdown pairs, yearTools, sidebar;
  final StatsMatrix matrix;
  final PeriodAxis axis;
  final StatsSessions recent;
  final StatsSources sources;
  final StatsPricing pricing;
}

enum StatsSyncPhase { idle, running, conflict, success, error }

enum StatsSyncErrorKind { sync, status }

class StatsController extends ChangeNotifier {
  StatsController(
    this.gateway, {
    this.store,
    UiPreferences preferences = const UiPreferences(),
    this.news,
    DateTime Function()? clock,
    String Function()? systemLanguage,
    this.updateRequest = requestUpdate,
    this.updateTimer = Timer.new,
  }) : preferences = preferences,
       _period = preferences.defaultPeriod == 'last'
           ? preferences.period
           : StatsPeriod(preferences.defaultPeriod),
       clock = clock ?? DateTime.now,
       _systemLanguage = systemLanguage ?? _defaultLanguage;

  static String _defaultLanguage() => 'zh';
  final String Function() _systemLanguage;
  AppStrings get strings =>
      resolveStrings(preferences.language, _systemLanguage());
  String get unitSystem => preferences.unitSystemFor(strings.languageCode);
  final StatsGateway gateway;
  final PreferencesStore? store;
  final DateTime Function() clock;
  final UpdateRequest updateRequest;
  final UpdateTimer updateTimer;
  late final updates = UpdateController(
    readPreferences: () => preferences,
    savePreferences: setPreferences,
    clock: clock,
    request: updateRequest,
    createTimer: updateTimer,
  )..addListener(_notify);
  Future<StatsHealth>? _health;
  Future<StatsHealth> health() => _health ??= gateway.health().then(
    (value) {
      updates.setCurrentVersion(value.version);
      return value;
    },
    onError: (Object error, StackTrace stack) {
      _health = null;
      Error.throwWithStackTrace(error, stack);
    },
  );
  UiPreferences preferences;
  StatsPeriod _period;
  StatsPeriod get period => _period.withWeekStart(preferences.weekStartsOn);
  final NewsController? news;
  bool _newsReady = false;

  void _applyNewsPreference() {
    if (news case final controller?) {
      unawaited(controller.setEnabled(_newsReady && preferences.newsEnabled));
    }
  }

  StatsHomeData? overview;
  StatsSync? lastSync;
  String Function(AppStrings)? _error, _syncError;
  List<String> _warnings = const [];

  String? get error => _error?.call(strings);
  set error(String? text) => _error = text == null ? null : (_) => text;
  String? get syncError => _syncError?.call(strings);
  set syncError(String? text) => _syncError = text == null ? null : (_) => text;
  String? get warning => localizedWarnings(_warnings, strings);
  set warning(String? text) => _warnings = text == null ? const [] : [text];
  final resourceErrors = <String, String>{};
  StatsSyncPhase phase = StatsSyncPhase.idle;
  StatsSyncErrorKind? syncErrorKind;
  bool loading = false;
  bool sourcesReadSucceeded = false;
  int ledgerVersion = 0, syncDiscoveryRevision = 0;

  Iterable<String> get hiddenTools =>
      preferences.hiddenTools.where(tools.containsKey);
  bool isHidden(String? source) =>
      tools.containsKey(source) && preferences.hiddenTools.contains(source);
  String get hiddenScope => hiddenTools.join(',');

  StatsFilter visibleFilter(StatsFilter filter) {
    final hidden = hiddenTools.toList();
    if (hidden.isEmpty) return filter;
    return StatsFilter(
      from: filter.from,
      to: filter.to,
      source: filter.source,
      model: filter.model,
      project: filter.project,
      missing: filter.missing,
      excludeSources: hidden,
    );
  }

  Future<void> setToolVisible(String source, bool visible) {
    final ids = preferences.hiddenTools.toSet();
    if (visible) {
      ids.remove(source);
    } else {
      ids.add(source);
    }
    return setPreferences(preferences.copyWith(hiddenTools: ids.toList()));
  }

  Map<String, String> visibleQuery(Map<String, String> query) {
    if (isHidden(query['tool'])) query.remove('tool');
    if (isHidden(query['source'])) {
      query.remove('source');
      query.remove('session');
    }
    return query;
  }

  StatsSyncProgress? progress;
  bool recentlySynced = false, _hasSucceeded = false;
  int _syncId = 0;
  String? _dismissedReceipt;
  int _refreshedThrough = 0;
  Timer? _progressTimer, _syncedTimer;
  bool _pollingProgress = false;
  bool get firstSyncRunning =>
      phase == StatsSyncPhase.running &&
      (progress?.firstSync ?? !(_hasSucceeded || syncSuccessful));
  bool get fullSyncRunning =>
      firstSyncRunning || (phase == StatsSyncPhase.running && rereading);

  ({String id, String? reason, int issues})? get syncReceipt {
    if (busy) return null;
    final run = overview?.sources.lastRun;
    final active = _syncId > 0 && phase != StatsSyncPhase.idle;
    final id = active
        ? 'local:$_syncId'
        : 'ledger:${run?.id ?? run?.startedAt}';
    if (_dismissedReceipt == id) return null;
    final reason = active && phase == StatsSyncPhase.error
        ? syncFailureReason(syncError ?? strings.requestFailed, strings)
        : !active && ['failed', 'abandoned'].contains(run?.status)
        ? strings.recentSyncIncomplete
        : null;
    final issues = active
        ? (phase == StatsSyncPhase.success ? _warnings.length : 0)
        : (run?.anomalyCount ?? 0);
    return reason == null && issues == 0
        ? null
        : (id: id, reason: reason, issues: issues);
  }

  void dismissSyncReceipt(String id) {
    _dismissedReceipt = id;
    _notify();
  }

  void _startProgress() {
    final provider = gateway;
    if (provider is! StatsProgressGateway) return;
    final id = _syncId;
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => unawaited(_pollProgress(provider as StatsProgressGateway, id)),
    );
  }

  Future<void> _pollProgress(StatsProgressGateway provider, int id) async {
    if (_pollingProgress || _closed || phase != StatsSyncPhase.running) return;
    _pollingProgress = true;
    try {
      final next = await provider.syncProgress();
      if (_closed ||
          _syncId != id ||
          phase != StatsSyncPhase.running ||
          next == null) {
        return;
      }
      progress = next;
      if (fullSyncRunning && next.index > _refreshedThrough + 1 && !loading) {
        _refreshedThrough = next.index - 1;
        ledgerVersion++;
        unawaited(load());
      } else {
        _notify();
      }
    } catch (_) {
      // A failed progress sample can be retried while ingestion is still running.
    } finally {
      _pollingProgress = false;
    }
  }

  void _stopProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
    progress = null;
  }

  void _showSynced() {
    _hasSucceeded = true;
    recentlySynced = true;
    _syncedTimer?.cancel();
    _syncedTimer = Timer(const Duration(seconds: 4), () {
      recentlySynced = false;
      _notify();
    });
  }

  bool get busy =>
      phase == StatsSyncPhase.running ||
      phase == StatsSyncPhase.conflict ||
      phase == StatsSyncPhase.idle &&
          overview?.sources.lastRun?.status == 'running';
  bool get rereading => busy && _syncTrigger == 'reread';
  bool get syncFailed =>
      syncError != null ||
      phase == StatsSyncPhase.error ||
      ['failed', 'abandoned'].contains(overview?.sources.lastRun?.status);
  bool get syncSuccessful =>
      phase == StatsSyncPhase.success ||
      [
        'ok',
        'completed_with_anomalies',
      ].contains(overview?.sources.lastRun?.status);
  bool _closed = false, _disposed = false, _started = false;
  int _generation = 0, _statusGeneration = 0;
  Timer? _timer, _conflictTimer;
  String? _syncTrigger;
  Future<void>? _sync, _shutdown, _statusRead;
  Future<bool>? _onboardingRequired;
  final _reads = <Future<void>>{};
  void _notify() {
    if (!_closed && !_disposed) notifyListeners();
  }

  // Keep the initial verdict for both startup sync and the onboarding gate.
  Future<bool> onboardingRequired() =>
      _onboardingRequired ??= _readOnboardingRequired();

  Future<bool> _readOnboardingRequired() async {
    if (_closed || preferences.onboarded) return false;
    try {
      final summary = await gateway.summary(const StatsFilter());
      return summary.totals.recordCount == 0;
    } catch (_) {
      // Preserve the existing fallback to the main application on read failure.
      return false;
    }
  }

  Future<void> start() async {
    if (_started || _closed) return;
    _started = true;
    updates.start();
    unawaited(
      health().then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    final onboarding = onboardingRequired();
    _applyNewsPreference();
    if (news != null) {
      if (preferences.newsEnabled) unawaited(news!.load());
      unawaited(
        onboarding.then((required) {
          if (required || _closed) return;
          _newsReady = true;
          _applyNewsPreference();
        }),
      );
    }
    await load();
    if (await onboarding || _closed) return;
    _startSyncTimer();
    await sync(trigger: 'startup');
  }

  Future<void> startOnboardingSync({bool? localOnly}) async {
    if (_closed) return;
    final enableNews = localOnly == null ? preferences.newsEnabled : !localOnly;
    if (enableNews != preferences.newsEnabled) {
      preferences = preferences.copyWith(newsEnabled: enableNews);
      if (!enableNews) _applyNewsPreference();
      // Publish the new choice with the new sync phase, after persisting it.
      await store?.write(preferences);
      if (_closed) return;
    }
    _newsReady = true;
    _applyNewsPreference();
    _startSyncTimer();
    return syncErrorKind == StatsSyncErrorKind.status ? retryStatus() : sync();
  }

  void _startSyncTimer() {
    if (!_started || _closed) return;
    _timer ??= Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(sync(trigger: 'timer')),
    );
  }

  Future<void> setPreferences(UiPreferences value) => _savePreferences(value);

  Future<void> _savePreferences(
    UiPreferences value, {
    StatsPeriod? selected,
  }) async {
    if (_closed) return;
    final beforeHidden = hiddenScope;
    final oldPeriod = period;
    if (selected != null || value.period.query != preferences.period.query) {
      _period = selected ?? value.period;
    }
    final newsChanged = value.newsEnabled != preferences.newsEnabled;
    preferences = value;
    if (newsChanged) _applyNewsPreference();
    final periodChanged =
        period.query != oldPeriod.query ||
        period.weekStartsOn != oldPeriod.weekStartsOn;
    final visibilityChanged = beforeHidden != hiddenScope;
    if (visibilityChanged) overview = null;
    _notify();
    final save = store?.write(value);
    if (periodChanged || visibilityChanged) await load();
    await save;
  }

  Future<void> setPeriod(StatsPeriod period) =>
      _savePreferences(preferences.copyWith(period: period), selected: period);
  Future<void> load() {
    if (_closed) return Future.value();
    final work = _read(++_generation, period);
    _reads.add(work);
    unawaited(work.whenComplete(() => _reads.remove(work)));
    return work;
  }

  Future<void> _read(int ticket, StatsPeriod period) async {
    loading = true;
    sourcesReadSucceeded = false;
    _notify();
    final readErrors = <String, String>{};
    final now = clock();
    final range = period.range(now), compare = period.compare(now);
    final filter = visibleFilter(StatsFilter(from: range.from, to: range.to));
    final yearFilter = visibleFilter(
      StatsFilter(
        from: dayKey(DateTime(now.year, now.month, now.day - 364)),
        to: dayKey(now),
      ),
    );
    final prevFilter = visibleFilter(
      StatsFilter(from: compare?.from, to: compare?.to),
    );
    final stats = gateway;
    const emptySnapshot = StatsSnapshot(
      generatedAt: '',
      priceVersion: '',
      tz: '',
      filters: StatsAppliedFilter(from: '', to: '', offsetMinutes: 0),
    );
    const emptyTotals = StatsTotals(
      grossTokens: 0,
      unpricedRecords: 0,
      recordCount: 0,
    );
    Future<T> resource<T>(String key, Future<T> request, T fallback) async {
      try {
        return await request;
      } catch (failure) {
        readErrors[key] = failure.toString();
        return fallback;
      }
    }

    try {
      final results = await Future.wait<Object?>([
        gateway.summary(filter),
        gateway.timeseries('day', filter),
        gateway.breakdown('source_model', filter),
        resource(
          'year',
          gateway.timeseries('day', yearFilter),
          overview?.year ??
              const StatsTimeseries(
                granularity: 'day',
                points: [],
                snapshot: emptySnapshot,
              ),
        ),
        resource(
          'yearTools',
          gateway.breakdown('source', yearFilter),
          overview?.yearTools ??
              const StatsBreakdown(
                by: 'source',
                groups: [],
                totals: emptyTotals,
                snapshot: emptySnapshot,
              ),
        ),
        resource(
          'recent',
          gateway.sessions(filter),
          overview?.recent ??
              const StatsSessions(items: [], snapshot: emptySnapshot),
        ),
        resource(
          'sources',
          gateway.sources(),
          overview?.sources ??
              const StatsSources(sources: [], snapshot: emptySnapshot),
        ),
        resource(
          'pricing',
          gateway.pricing(),
          overview?.pricing ??
              const StatsPricing(
                priceVersion: '',
                currency: 'USD',
                provisional: false,
                models: [],
                counts: StatsPriceCounts(
                  verified: 0,
                  aggregate: 0,
                  unknown: 0,
                  local: 0,
                ),
                snapshot: emptySnapshot,
              ),
        ),
        gateway.breakdown('source', filter),
        if (compare != null && period.period != 'today')
          gateway.summary(prevFilter)
        else
          Future.value(null),
        if (compare != null)
          gateway.timeseries(
            period.period == 'today' ? 'hour' : 'day',
            prevFilter,
          )
        else
          Future.value(null),
        if (compare != null && stats is StatsComparisonGateway)
          resource<StatsComparison?>(
            'comparison',
            (stats as StatsComparisonGateway).comparison(
              'project',
              filter,
              prevFilter,
            ),
            null,
          )
        else
          Future.value(null),
      ]);
      if (_closed || ticket != _generation) return;
      final summary = results[0] as StatsSummary;
      final axis = period.axis(now, summary.activity.firstSeen);
      final matrix = await gateway.matrix(axis.granularity, 'source', filter);
      if (_closed || ticket != _generation) return;
      overview = StatsHomeData(
        period: period,
        summary: summary,
        days: results[1] as StatsTimeseries,
        pairs: results[2] as StatsBreakdown,
        year: results[3] as StatsTimeseries,
        yearTools: results[4] as StatsBreakdown,
        recent: results[5] as StatsSessions,
        sources: results[6] as StatsSources,
        pricing: results[7] as StatsPricing,
        sidebar: results[8] as StatsBreakdown,
        previous: results[9] as StatsSummary?,
        previousDays: period.period == 'today'
            ? null
            : results[10] as StatsTimeseries?,
        previousHours: period.period == 'today'
            ? results[10] as StatsTimeseries?
            : null,
        matrix: matrix,
        axis: axis,
        comparison: results[11] as StatsComparison?,
      );
      error = null;
      resourceErrors
        ..clear()
        ..addAll(readErrors);
      sourcesReadSucceeded = !readErrors.containsKey('sources');
      _hasSucceeded |=
          syncSuccessful || overview!.sources.hasSuccessfulSync == true;
    } catch (failure) {
      if (!_closed && ticket == _generation) {
        _error = (strings) => strings.requestFailed0(failure);
      }
    } finally {
      if (!_closed && ticket == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> sync({String trigger = 'manual'}) {
    if (_closed || phase == StatsSyncPhase.conflict) return Future.value();
    return _sync ??= _synchronize(trigger).whenComplete(() => _sync = null);
  }

  Future<void> rereadLogs() => sync(trigger: 'reread');

  Future<void> _synchronize(String trigger) async {
    _statusGeneration++;
    _conflictTimer?.cancel();
    _syncTrigger = trigger;
    _syncId++;
    _refreshedThrough = 0;
    recentlySynced = false;
    _syncedTimer?.cancel();
    phase = StatsSyncPhase.running;
    _startProgress();
    syncError = null;
    syncErrorKind = null;
    warning = null;
    _notify();
    try {
      final result = await gateway.sync(trigger: trigger);
      if (_closed) return;
      final wasFullSync = fullSyncRunning;
      _stopProgress();
      lastSync = result;
      syncDiscoveryRevision++;
      ledgerVersion++;
      _warnings = result.anomalies;
      phase = StatsSyncPhase.success;
      _hasSucceeded = true;
      if (!wasFullSync &&
          _warnings.isEmpty &&
          gateway is StatsProgressGateway) {
        _showSynced();
      }
      await load();
    } catch (failure) {
      if (_closed) return;
      _stopProgress();
      if (failure.toString().contains('SYNC_BUSY')) {
        phase = StatsSyncPhase.conflict;
        _watchConflict(clock());
      } else {
        phase = StatsSyncPhase.error;
        syncErrorKind = StatsSyncErrorKind.sync;
        _syncError = (strings) => syncFailureMessage(failure, strings);
        // A failed ingestion can still have committed earlier files.
        syncDiscoveryRevision++;
        ledgerVersion++;
        await load();
      }
    } finally {
      _notify();
    }
  }

  void _watchConflict(DateTime started) {
    _conflictTimer?.cancel();
    final ticket = _statusGeneration;
    _conflictTimer = Timer(const Duration(seconds: 2), () {
      if (_closed || ticket != _statusGeneration) return;
      unawaited(_checkStatus(started, ticket));
    });
  }

  Future<void> retryStatus() {
    if (_closed) return Future.value();
    if (_statusRead != null) return _statusRead!;
    if (_sync != null) return _sync!;
    _conflictTimer?.cancel();
    final ticket = ++_statusGeneration;
    phase = StatsSyncPhase.conflict;
    syncError = null;
    syncErrorKind = null;
    _notify();
    return _checkStatus(clock(), ticket);
  }

  Future<void> _checkStatus(DateTime started, int ticket) => _statusRead ??=
      _readStatus(started, ticket).whenComplete(() => _statusRead = null);

  Future<void> _readStatus(DateTime started, int ticket) async {
    try {
      final status = await gateway.sources();
      if (_closed || ticket != _statusGeneration) return;
      final run = status.lastRun;
      if (run?.status == 'ok' || run?.status == 'completed_with_anomalies') {
        ledgerVersion++;
        phase = StatsSyncPhase.success;
        syncError = null;
        syncErrorKind = null;
        _warnings = run!.anomalies;
        await load();
      } else if (run?.status == 'failed' || run?.status == 'abandoned') {
        phase = StatsSyncPhase.error;
        syncErrorKind = StatsSyncErrorKind.sync;
        _syncError = (strings) => strings.recentSyncIncomplete;
        await load();
      } else if (clock().difference(started) >= const Duration(minutes: 2)) {
        phase = StatsSyncPhase.error;
        syncErrorKind = StatsSyncErrorKind.sync;
        _syncError = (strings) => strings.theWaitTimedOutSyncMayStill;
      } else {
        _watchConflict(started);
      }
    } catch (failure) {
      if (_closed || ticket != _statusGeneration) return;
      phase = StatsSyncPhase.error;
      syncErrorKind = StatsSyncErrorKind.status;
      _syncError = (strings) => strings.syncStatusReadFailed(failure);
    }
    _notify();
  }

  String get syncLabel {
    if (phase == StatsSyncPhase.conflict) {
      return strings.aSyncIsAlreadyRunningWaitingFor;
    }
    if (phase == StatsSyncPhase.running) return strings.syncing3;
    if (syncError != null) return syncError!;
    final run = overview?.sources.lastRun;
    if (run?.status == 'failed' || run?.status == 'abandoned') {
      return strings.recentSyncIncomplete;
    }
    if (run?.status == 'running') return strings.syncing3;
    final note =
        warning ?? localizedWarnings(run?.anomalies ?? const [], strings);
    if (note != null) return strings.syncFinishedWithWarnings(note);
    if (phase == StatsSyncPhase.success ||
        run?.status == 'ok' ||
        run?.status == 'completed_with_anomalies') {
      final finished = DateTime.tryParse(run?.finishedAt ?? '');
      if (finished == null) return strings.syncComplete;
      final minutes = (clock().difference(finished).inMilliseconds / 60000)
          .round()
          .clamp(0, 1 << 30);
      return minutes < 1
          ? strings.syncedJustNow
          : minutes < 60
          ? strings.syncedMinutesAgo(minutes)
          : minutes < 1440
          ? strings.syncedHoursAgo((minutes / 60).round())
          : strings.syncedDaysAgo((minutes / 1440).round());
    }
    return strings.noSyncHistory;
  }

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    _closed = true;
    updates.close();
    _generation++;
    _statusGeneration++;
    _timer?.cancel();
    _conflictTimer?.cancel();
    _stopProgress();
    _syncedTimer?.cancel();
    await gateway.shutdown();
    await _sync;
    await _statusRead;
    await Future.wait(_reads.toList());
    await _onboardingRequired;
    await store?.flush();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    updates.removeListener(_notify);
    updates.dispose();
    super.dispose();
  }
}
