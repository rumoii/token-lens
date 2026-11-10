import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'format.dart';

typedef ExchangeRateRequest = Future<ExchangeRateResponse> Function(
  Uri uri,
  ExchangeRateCancellation cancellation,
);

class ExchangeRateResponse {
  const ExchangeRateResponse(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

class ExchangeRateCancellation {
  final _done = Completer<void>();
  final _listeners = <VoidCallback>{};
  bool get cancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (cancelled) return;
    _done.complete();
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  VoidCallback addListener(VoidCallback listener) {
    if (cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }
}

typedef VoidCallback = void Function();

class ExchangeRateResult {
  const ExchangeRateResult(this.rates, this.fetchedAt);
  final Map<String, num> rates;
  final int fetchedAt;
}

const exchangeRateTtlMs = 86400000;
bool shouldRefetch(num? fetchedAt, {int ttlMs = exchangeRateTtlMs, int? now}) =>
    !isValidRate(fetchedAt) ||
    (now ?? DateTime.now().millisecondsSinceEpoch) - fetchedAt! > ttlMs;

Future<ExchangeRateResponse> requestExchangeRate(
  Uri uri,
  ExchangeRateCancellation cancellation, {
  HttpClient Function()? createClient,
}) async {
  if (cancellation.cancelled) {
    throw const ExchangeRateException(
      'Exchange request timed out or was interrupted.',
    );
  }
  final client = (createClient ?? HttpClient.new)();
  final detach = cancellation.addListener(() => client.close(force: true));
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return ExchangeRateResponse(response.statusCode, body);
  } finally {
    detach();
    client.close(force: true);
  }
}

class ExchangeRateException implements Exception {
  const ExchangeRateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ExchangeRateOperation {
  ExchangeRateOperation({this.request, this.clock});
  final ExchangeRateRequest? request;
  final DateTime Function()? clock;
  final cancellation = ExchangeRateCancellation();
  Future<ExchangeRateResult> fetch({
    String? reason,
    List<String>? codes,
  }) async {
    if (reason != 'user-click') {
      throw const ExchangeRateException(
        'An explicit update click is required.',
      );
    }
    if (codes != null && !codes.contains('CNY')) {
      throw const ExchangeRateException(
        'The requested currencies must include CNY.',
      );
    }
    const interrupted = ExchangeRateException(
      'Exchange request timed out or was interrupted.',
    );
    if (cancellation.cancelled) throw interrupted;
    final timeout = Timer(const Duration(seconds: 5), cancel);
    try {
      final response = await Future.any([
        Future.sync(
          () => (request ?? requestExchangeRate)(
            Uri.parse('https://open.er-api.com/v6/latest/USD'),
            cancellation,
          ),
        ),
        cancellation.whenCancelled.then<ExchangeRateResponse>(
          (_) => throw interrupted,
        ),
      ]);
      if (cancellation.cancelled) throw interrupted;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ExchangeRateException(
          'Exchange service returned HTTP ${response.statusCode}.',
        );
      }
      final payload = jsonDecode(response.body);
      final rates = payload is Map ? payload['rates'] : null;
      final cny = rates is Map ? rates['CNY'] : null;
      if (!isValidRate(cny)) {
        throw const ExchangeRateException(
          'Exchange response has no usable CNY rate.',
        );
      }
      return ExchangeRateResult({
        'USD': 1,
        'CNY': cny as num,
      }, (clock ?? DateTime.now)().millisecondsSinceEpoch);
    } catch (error) {
      if (cancellation.cancelled) throw interrupted;
      rethrow;
    } finally {
      timeout.cancel();
    }
  }

  void cancel() => cancellation.cancel();
}
