import 'dart:io';

class LocalNewsServer {
  LocalNewsServer._(this._server);

  final HttpServer _server;
  final requests = <String>[];
  final failures = <String, int>{};

  List<String> get endpoints => [
    'http://127.0.0.1:${_server.port}/0',
    'http://127.0.0.1:${_server.port}/1',
  ];

  static Future<LocalNewsServer> start() async {
    final fixture = await File('rust/src/sources/fixtures/rss/rss-normal.xml')
        .readAsString();
    final server = LocalNewsServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._server.listen((request) async {
      server.requests.add(request.uri.path);
      request.response.statusCode = server.failures[request.uri.path] ?? 200;
      request.response.headers.contentType = ContentType(
        'application',
        'rss+xml',
        charset: 'utf-8',
      );
      request.response.write(
        fixture.replaceAll(
          'https://example.com/one',
          'https://example.com/local${request.uri.path}',
        ),
      );
      await request.response.close();
    });
    return server;
  }

  Future<void> close() async => _server.close(force: true);
}
