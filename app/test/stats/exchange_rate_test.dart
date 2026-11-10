import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/exchange_rate.dart';
import 'package:token_lens_app/stats/logic/format.dart';

class _HttpResponse extends Stream<List<int>> implements HttpClientResponse {
  _HttpResponse(this.body);
  final String body;
  @override
  int get statusCode => 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HttpRequest implements HttpClientRequest {
  _HttpRequest(this.response);
  final Future<HttpClientResponse> response;
  @override
  Future<HttpClientResponse> close() => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HttpClient implements HttpClient {
  _HttpClient(this.response);
  final Future<HttpClientResponse> response;
  Uri? uri;
  int closes = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uri = url;
    return _HttpRequest(response);
  }

  @override
  void close({bool force = false}) {
    expect(force, true);
    closes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('dart:io adapter reads UTF-8 and closes its client on success/error/cancellation', () async {
    final uri = Uri.parse('https://open.er-api.com/v6/latest/USD');
    final client = _HttpClient(
      Future.value(_HttpResponse('{"rates":{"CNY":8},"message":"汇率"}')),
    );
    final cancellation = ExchangeRateCancellation();
    final result = await requestExchangeRate(
      uri,
      cancellation,
      createClient: () => client,
    );
    expect(client.uri, uri);
    expect(client.closes, 1);
    expect(result.statusCode, 200);
    expect(jsonDecode(result.body)['message'], '汇率');
    cancellation.cancel();
    expect(
      client.closes,
      1,
      reason: 'settled request detached cancellation listener',
    );
    final failure = Completer<HttpClientResponse>();
    final failed = _HttpClient(failure.future);
    final failedAssertion = expectLater(
      requestExchangeRate(
        uri,
        ExchangeRateCancellation(),
        createClient: () => failed,
      ),
      throwsStateError,
    );
    await Future<void>.value();
    failure.completeError(StateError('offline'));
    await failedAssertion;
    expect(failed.closes, 1);
    final pending = Completer<HttpClientResponse>();
    final aborted = _HttpClient(pending.future);
    final token = ExchangeRateCancellation();
    final work = requestExchangeRate(uri, token, createClient: () => aborted);
    final abortedAssertion = expectLater(work, throwsStateError);
    token.cancel();
    expect(aborted.closes, 1);
    await Future<void>.value();
    pending.completeError(StateError('closed client'));
    await abortedAssertion;
    expect(aborted.closes, 2);
    var creations = 0;
    await expectLater(
      requestExchangeRate(
        uri,
        token,
        createClient: () {
          creations++;
          return aborted;
        },
      ),
      throwsA(isA<Exception>()),
    );
    expect(creations, 0);
  });
  test(
    'click authorization, CNY required, endpoint and only USD/CNY returned',
    () async {
      var calls = 0;
      Uri? endpoint;
      final operation = ExchangeRateOperation(
        clock: () => DateTime.fromMillisecondsSinceEpoch(123456),
        request: (uri, cancellation) async {
          calls++;
          endpoint = uri;
          return const ExchangeRateResponse(
            200,
            '{"rates":{"USD":50,"CNY":7.64,"EUR":0.9}}',
          );
        },
      );
      await expectLater(
        operation.fetch(),
        throwsA(predicate((e) => e.toString().contains('click'))),
      );
      await expectLater(
        operation.fetch(reason: 'timer'),
        throwsA(predicate((e) => e.toString().contains('click'))),
      );
      await expectLater(
        operation.fetch(reason: 'user-click', codes: ['EUR']),
        throwsA(predicate((e) => e.toString().contains('CNY'))),
      );
      expect(calls, 0);
      final result = await operation.fetch(reason: 'user-click');
      expect(calls, 1);
      expect(endpoint.toString(), 'https://open.er-api.com/v6/latest/USD');
      expect(result.rates, {'USD': 1, 'CNY': 7.64});
      expect(result.fetchedAt, 123456);
    },
  );
  test(
    'HTTP, invalid JSON/payload and network failures have no retry',
    () async {
      for (final response in [
        const ExchangeRateResponse(503, '{}'),
        const ExchangeRateResponse(200, 'not-json'),
        const ExchangeRateResponse(200, '[]'),
        const ExchangeRateResponse(200, 'null'),
        const ExchangeRateResponse(200, '{"rates":{"CNY":"7.4"}}'),
        const ExchangeRateResponse(200, '{"rates":{"CNY":0}}'),
        const ExchangeRateResponse(200, '{"rates":{"CNY":-1}}'),
        const ExchangeRateResponse(200, '{"rates":{"EUR":1}}'),
        const ExchangeRateResponse(200, '{"rates":{"CNY":1e400}}'),
      ]) {
        var calls = 0;
        final op = ExchangeRateOperation(
          request: (_, _) async {
            calls++;
            return response;
          },
        );
        await expectLater(
          op.fetch(reason: 'user-click'),
          throwsA(isA<Exception>()),
        );
        expect(calls, 1);
      }
      final offline = ExchangeRateOperation(
        request: (_, _) async => throw StateError('offline'),
      );
      await expectLater(offline.fetch(reason: 'user-click'), throwsStateError);
    },
  );
  testWidgets(
    'five second deadline cancels uncooperative request and ignores late completion',
    (t) async {
      final pending = Completer<ExchangeRateResponse>();
      var cancelled = 0;
      final op = ExchangeRateOperation(
        request: (_, token) {
          token.addListener(() => cancelled++);
          return pending.future;
        },
      );
      final work = op.fetch(reason: 'user-click');
      final assertion = expectLater(
        work,
        throwsA(predicate((e) => e.toString().contains('interrupted'))),
      );
      await t.pump(const Duration(milliseconds: 4999));
      expect(op.cancellation.cancelled, false);
      await t.pump(const Duration(milliseconds: 1));
      await assertion;
      expect(op.cancellation.cancelled, true);
      expect(cancelled, 1);
      pending.complete(const ExchangeRateResponse(200, '{"rates":{"CNY":8}}'));
      await t.pump();
      op.cancel();
      expect(cancelled, 1);
    },
  );
  testWidgets(
    'external cancellation, pre-cancel and settled outcomes release timers',
    (t) async {
      final pending = Completer<ExchangeRateResponse>();
      final op = ExchangeRateOperation(request: (_, _) => pending.future);
      final assertion = expectLater(
        op.fetch(reason: 'user-click'),
        throwsA(isA<Exception>()),
      );
      op.cancel();
      await t.pump();
      await assertion;
      pending.completeError(StateError('late offline'));
      await t.pump();
      var calls = 0;
      final before = ExchangeRateOperation(
        request: (_, _) async {
          calls++;
          return const ExchangeRateResponse(200, '{}');
        },
      );
      before.cancel();
      await expectLater(
        before.fetch(reason: 'user-click'),
        throwsA(isA<Exception>()),
      );
      expect(calls, 0);
      for (final body in ['{"rates":{"CNY":8}}', '{}']) {
        final settled = ExchangeRateOperation(
          request: (_, _) async => ExchangeRateResponse(200, body),
        );
        try {
          await settled.fetch(reason: 'user-click');
        } catch (_) {}
        await t.pump(const Duration(seconds: 6));
        expect(settled.cancellation.cancelled, false);
      }
    },
  );
  test('age reporting is pure and never schedules updates', () {
    const start = 900000000;
    expect(exchangeRateTtlMs, 86400000);
    for (final missing in [null, 0, double.nan, double.infinity]) {
      expect(shouldRefetch(missing), true);
    }
    expect(shouldRefetch(start, ttlMs: 30, now: start + 30), false);
    expect(shouldRefetch(start, ttlMs: 30, now: start + 31), true);
    expect(shouldRefetch(start + 40, ttlMs: 30, now: start), false);
  });
  test(
    'currency-rate and currency runtime display cases use existing foundation',
    () {
      expect(defaultRates['CNY'], 6.7);
      expect(
        usdCurrency('10.00', currency: 'CNY', rate: defaultRates['CNY']),
        '¥67.00',
      );
      expect(usdCurrency('10.00'), r'$10.00');
      expect(usdCurrency('10.00', currency: 'USD', rate: 6.7), r'$10.00');
      for (final empty in [null, '  ']) {
        expect(usdCurrency(empty, currency: 'CNY', rate: 6.7), '-');
      }
      for (final invalid in ['7.8', 0, -3, double.nan, double.infinity, null]) {
        expect(isValidRate(invalid), false);
      }
      expect(isValidRate(7.8), true);
      expect(rateFor({'USD': 400, 'CNY': 7.8}, 'USD'), 1);
      expect(rateFor({'CNY': 0}, 'CNY'), 6.7);
      expect(applyCurrency(13, 'CNY', {'CNY': 8}), (value: 104.0, symbol: '¥'));
      expect(applyCurrency(13, 'EUR', null), (value: 13.0, symbol: r'$'));
    },
  );
}
