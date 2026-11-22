import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../stats_gateway.dart';
import '../../update/update_check.dart';
import '../preferences.dart';

Uri get pricingEndpoint => Uri.https(
  'raw.githubusercontent.com',
  '/rumoii/token-lens/main/app/rust/src/stats/pricing-catalog.json',
);
const pricingHeaders = {
  'Accept': 'application/json',
  'User-Agent': 'TokenLens-Pricing',
};

Future<UpdateResponse> requestPricing(
  Uri uri,
  Map<String, String> headers,
  UpdateCancellation cancellation,
) => requestUpdate(
  uri,
  headers,
  cancellation,
  maxBytes: 1 << 20,
  readSuccessfulOnly: true,
);

class PricingUpdateController extends ChangeNotifier {
  PricingUpdateController({
    required this.readPreferences,
    required this.savePreferences,
    required this.install,
    required this.remove,
    required this.sync,
    required this.clock,
    this.request = requestPricing,
    this.createTimer = Timer.new,
  });

  final UiPreferences Function() readPreferences;
  final Future<void> Function(UiPreferences) savePreferences;
  final Future<StatsPriceInstall> Function(String) install;
  final Future<void> Function() remove;
  final Future<bool> Function() sync;
  final DateTime Function() clock;
  final UpdateRequest request;
  final UpdateTimer createTimer;

  bool _closed = false, _changing = false;
  bool get changingAutomatic => _changing;
  bool get checking => _active != null;
  Timer? _schedule;
  Future<void>? _active;
  UpdateCancellation? _cancellation;
  int _generation = 0;

  void start() {
    if (_closed || _schedule != null) return;
    _schedule = createTimer(const Duration(seconds: 10), _tick);
  }

  void _tick() {
    if (_closed) return;
    _schedule = createTimer(const Duration(hours: 1), _tick);
    unawaited(check(automatic: true));
  }

  Future<void> check({bool automatic = false}) {
    final prefs = readPreferences();
    final last = prefs.pricingLastAttemptMs;
    final now = clock().millisecondsSinceEpoch;
    if (_closed ||
        _changing ||
        checking ||
        !prefs.onboarded ||
        !prefs.autoUpdatePricing ||
        (automatic &&
            last != null &&
            last <= now &&
            now - last < const Duration(days: 1).inMilliseconds)) {
      return Future.value();
    }
    final generation = _generation;
    final cancel = _cancellation = UpdateCancellation();
    final work = _active =
        Future<void>.microtask(() => _check(now, generation, cancel))
            .whenComplete(() {
              _active = null;
              _cancellation = null;
              if (!_closed) notifyListeners();
            });
    notifyListeners();
    return work;
  }

  Future<void> _check(
    int now,
    int generation,
    UpdateCancellation cancel,
  ) async {
    bool current() => !_closed && generation == _generation;
    if (!current()) return;
    await savePreferences(
      readPreferences().copyWith(
        pricingLastAttemptMs: now,
        pricingUpdatedNote: null,
      ),
    );
    if (!current()) return;
    StatsPriceInstall? result;
    String kind;
    try {
      final deadline = createTimer(const Duration(seconds: 15), cancel.cancel);
      final UpdateResponse response;
      try {
        response = await Future.any([
          Future.sync(() => request(pricingEndpoint, pricingHeaders, cancel)),
          cancel.whenCancelled.then<UpdateResponse>(
            (_) => throw const HttpException('Pricing request cancelled'),
          ),
        ]);
      } finally {
        deadline.cancel();
      }
      if (!current()) return;
      if (cancel.cancelled) {
        throw const HttpException('Pricing request timed out');
      }
      if (response.statusCode == 200) {
        if (utf8.encode(response.body).length > 1 << 20) {
          throw const UpdateBodyTooLarge();
        }
        result = await install(response.body);
        kind = result.kind;
      } else {
        kind = response.statusCode == 403 || response.statusCode == 429
            ? 'limited'
            : 'offline';
      }
    } on UpdateBodyTooLarge {
      kind = 'invalid';
    } on FormatException {
      kind = 'invalid';
    } catch (_) {
      kind = 'offline';
    } finally {
      cancel.cancel();
    }
    if (!current()) return;
    PricingUpdatedNote? note;
    if (kind == 'installed') {
      final recalculated = await sync();
      if (!current()) return;
      final date = result?.publishedAt;
      if (recalculated && date != null) {
        note = (publishedAt: date, newlyPriced: result?.newlyPriced ?? 0);
      }
    }
    final settings = readPreferences();
    await savePreferences(
      settings.copyWith(
        pricingLastKind: kind,
        pricingCheckedMs: switch (kind) {
          'installed' ||
          'older' ||
          'unchanged' => clock().millisecondsSinceEpoch,
          _ => settings.pricingCheckedMs,
        },
        pricingUpdatedNote: note,
      ),
    );
  }

  Future<void> setAutomatic(bool value) async {
    if (_closed || _changing || readPreferences().autoUpdatePricing == value) {
      return;
    }
    _changing = true;
    _generation++;
    _cancellation?.cancel();
    notifyListeners();
    try {
      if (!value) {
        await _active;
        if (_closed) return;
        await remove();
      }
      if (_closed) return;
      await savePreferences(
        readPreferences().copyWith(
          autoUpdatePricing: value,
          pricingLastKind: null,
          pricingUpdatedNote: null,
        ),
      );
      if (!value && !_closed) await sync();
    } finally {
      _changing = false;
      if (!_closed) notifyListeners();
    }
    if (value) await check(automatic: true);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _schedule?.cancel();
    _cancellation?.cancel();
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
