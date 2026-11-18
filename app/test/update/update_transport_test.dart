import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/update/update_check.dart';

import 'update_check_test.dart' show NoUpdateNetwork, release;

class LoopbackHttp extends HttpOverrides {
  HttpClient client() =>
      super.createHttpClient(null)..findProxy = (_) => 'DIRECT';
}

class FakeHeaders implements HttpHeaders {
  final values = <String, String>{
    'host': 'api.github.com',
    'accept-encoding': 'gzip',
  };
  @override
  void clear() => values.clear();
  @override
  void removeAll(String name) => values.remove(name.toLowerCase());
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  FakeResponse(this.chunks, {this.contentLength = -1, this.statusCode = 200});
  final Stream<List<int>> chunks;
  @override
  final int contentLength, statusCode;
  int listens = 0;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listens++;
    return chunks.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeRequest implements HttpClientRequest {
  FakeRequest(this.response);
  final FakeResponse response;
  @override
  final FakeHeaders headers = FakeHeaders();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeClient implements HttpClient {
  FakeClient(this.request);
  final FakeRequest request;
  Uri? uri;
  int forceCloses = 0;
  @override
  String? userAgent = 'default agent';
  @override
  bool autoUncompress = true;
  @override
  Future<HttpClientRequest> getUrl(Uri value) async {
    uri = value;
    return request;
  }

  @override
  void close({bool force = false}) {
    if (force) forceCloses++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late NoUpdateNetwork network;
  setUp(() {
    network = NoUpdateNetwork();
    HttpOverrides.global = network;
  });
  tearDown(() {
    expect(network.calls, 0);
    HttpOverrides.global = null;
  });
  test(
    'loopback transport preserves Host and sends exactly four header names',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final uri = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: '/latest',
      );
      final received = Completer<Map<String, List<String>>>();
      server.listen((request) async {
        final headers = <String, List<String>>{};
        request.headers.forEach((name, values) => headers[name] = values);
        received.complete(headers);
        request.response.write(release());
        await request.response.close();
      });
      try {
        final response = await requestUpdate(
          uri,
          updateHeaders,
          UpdateCancellation(),
          createClient: LoopbackHttp().client,
        );
        final headers = await received.future;
        expect(response.statusCode, 200);
        expect(headers.keys.toSet(), {
          'host',
          'accept',
          'user-agent',
          'x-github-api-version',
        });
        expect(headers['host'], ['${uri.host}:${uri.port}']);
        for (final header in updateHeaders.entries) {
          expect(headers[header.key.toLowerCase()], [header.value]);
        }
      } finally {
        await server.close(force: true);
      }
    },
  );
  test('loopback 302 is offline and never sends a second request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/latest',
    );
    var requests = 0;
    server.listen((request) async {
      requests++;
      if (request.uri.path == '/latest') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          uri.resolve('/redirected').toString(),
        );
      } else {
        request.response.write(release());
      }
      await request.response.close();
    });
    UpdateResult result;
    try {
      final operation = UpdateOperation(
        request: (_, headers, cancellation) => requestUpdate(
          uri,
          headers,
          cancellation,
          createClient: LoopbackHttp().client,
        ),
      );
      result = await operation.fetch('0.1.0');
    } finally {
      await server.close(force: true);
    }
    expect(result.kind, UpdateKind.offline);
    expect(requests, 1);
  });
  test('fake client preserves Host, removes encoding, disables redirects, and closes connection', () async {
    final response = FakeResponse(Stream.value(utf8.encode(release())));
    final client = FakeClient(FakeRequest(response));
    final result = await requestUpdate(
      updateEndpoint,
      updateHeaders,
      UpdateCancellation(),
      createClient: () => client,
    );
    expect(result.statusCode, 200);
    expect(client.uri, updateEndpoint);
    expect(client.request.headers.values, {
      'host': 'api.github.com',
      ...updateHeaders,
    });
    expect(client.request.followRedirects, false);
    expect(client.userAgent, isNull);
    expect(client.autoUncompress, false);
    expect(client.forceCloses, 1);
  });
  test('oversize Content-Length aborts before reading; chunked body stops at the first excess byte', () async {
    final declared = FakeResponse(
      const Stream.empty(),
      contentLength: updateMaxBytes + 1,
    );
    final declaredClient = FakeClient(FakeRequest(declared));
    await expectLater(
      requestUpdate(
        updateEndpoint,
        updateHeaders,
        UpdateCancellation(),
        createClient: () => declaredClient,
      ),
      throwsA(isA<UpdateBodyTooLarge>()),
    );
    expect(declared.listens, 0);
    expect(declaredClient.forceCloses, 1);
    var emitted = 0;
    Stream<List<int>> body() async* {
      for (final size in [updateMaxBytes, 1, 1]) {
        emitted++;
        yield List.filled(size, 32);
      }
    }

    final client = FakeClient(FakeRequest(FakeResponse(body())));
    final operation = UpdateOperation(
      request: (uri, headers, cancel) =>
          requestUpdate(uri, headers, cancel, createClient: () => client),
    );
    expect((await operation.fetch('0.1.0')).kind, UpdateKind.invalid);
    expect(emitted, 2);
    expect(client.forceCloses, 1);
  });
  testWidgets(
    'cancellation closes a stalled read; late transport completion is ignored',
    (t) async {
      final stream = StreamController<List<int>>();
      final client = FakeClient(FakeRequest(FakeResponse(stream.stream)));
      final operation = UpdateOperation(
        request: (uri, headers, cancel) =>
            requestUpdate(uri, headers, cancel, createClient: () => client),
      );
      final pending = operation.fetch('0.1.0');
      await t.pump();
      operation.cancel();
      await t.pump();
      expect(client.forceCloses, greaterThanOrEqualTo(1));
      expect((await pending).kind, UpdateKind.offline);
      stream.add(utf8.encode(release()));
      unawaited(stream.close());
      await t.pump();
    },
  );
}
