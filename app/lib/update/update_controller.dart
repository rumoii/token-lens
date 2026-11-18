import 'dart:async';

import 'package:flutter/foundation.dart';

import '../stats/preferences.dart';
import 'update_check.dart';

class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.readPreferences,
    required this.savePreferences,
    required this.clock,
    this.request = requestUpdate,
    this.createTimer = Timer.new,
  });
  final UiPreferences Function() readPreferences;
  final Future<void> Function(UiPreferences) savePreferences;
  final DateTime Function() clock;
  final UpdateRequest request;
  final UpdateTimer createTimer;
  String? currentVersion;
  bool checking = false;
  bool _closed = false, _started = false;
  Timer? _schedule;
  UpdateOperation? _operation;
  void setCurrentVersion(String value) {
    if (_closed) return;
    final version = UpdateVersion.parse(value)?.value;
    if (version == currentVersion) return;
    currentVersion = version;
    notifyListeners();
  }

  void start() {
    if (_closed || _started) return;
    _started = true;
    _schedule = createTimer(const Duration(seconds: 10), _tick);
  }

  void _tick() {
    if (_closed) return;
    unawaited(check(automatic: true));
    _schedule = createTimer(const Duration(hours: 1), _tick);
  }

  bool get _due {
    final p = readPreferences(), last = readPreferences().updateLastAttemptMs;
    final elapsed = last == null ? null : clock().millisecondsSinceEpoch - last;
    return p.onboarded &&
        p.autoCheckUpdates &&
        (elapsed == null ||
            elapsed < 0 ||
            elapsed >= const Duration(days: 1).inMilliseconds);
  }

  Future<void> check({bool automatic = false}) async {
    final version = currentVersion;
    if (_closed || checking || version == null || (automatic && !_due)) return;
    checking = true;
    final operation = _operation = UpdateOperation(
      request: request,
      createTimer: createTimer,
    );
    notifyListeners();
    try {
      // Persist the attempt even when the process closes before a reply arrives.
      await savePreferences(
        readPreferences().copyWith(
          updateLastAttemptMs: clock().millisecondsSinceEpoch,
        ),
      );
      if (_closed) return;
      final result = await operation.fetch(version);
      if (_closed || !identical(operation, _operation)) return;
      await savePreferences(readPreferences().copyWith(updateResult: result));
    } finally {
      operation.cancel();
      if (!_closed) {
        checking = false;
        _operation = null;
        notifyListeners();
      }
    }
  }

  Future<void> setAutomatic(bool value) async {
    if (_closed) return;
    final was = readPreferences().autoCheckUpdates;
    await savePreferences(readPreferences().copyWith(autoCheckUpdates: value));
    if (_closed) return;
    notifyListeners();
    if (!was && value) await check(automatic: true);
  }

  Future<void> ignoreVersion() async {
    if (_closed) return;
    final version = readPreferences().updateResult?.version;
    if (version == null) return;
    await savePreferences(
      readPreferences().copyWith(updateIgnoredVersion: version),
    );
    if (!_closed) notifyListeners();
  }

  bool get showHint {
    final p = readPreferences(),
        installed = UpdateVersion.parse(currentVersion);
    final latest = UpdateVersion.parse(p.updateResult?.version);
    return p.updateResult?.kind == UpdateKind.available &&
        installed != null &&
        latest != null &&
        latest.compareTo(installed) > 0 &&
        latest.value != p.updateIgnoredVersion;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _schedule?.cancel();
    _operation?.cancel();
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
