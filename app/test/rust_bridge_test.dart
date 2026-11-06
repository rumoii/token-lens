import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:token_lens_app/rust_gateway.dart';
import 'package:token_lens_app/src/rust/api/news.dart' as native;
import 'package:token_lens_app/src/rust/frb_generated.dart';

void main() {
  setUpAll(() async => RustLib.init());

  test(
    'real bridge reads a cache without refreshing and releases its lock',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'token-lens-news-ffi-',
      );
      native.NewsClient? first;
      native.NewsClient? reopened;
      try {
        final cacheFile = File('${directory.path}/news-cache.json');
        final bytes = utf8.encode(
          jsonEncode({
            'version': 1,
            'last_success_ms': 1700000000000,
            'items': [
              {
                'id': 'fixture-1',
                'title': 'A cached <example>',
                'url': 'https://example.com/news/1',
                'published_at': '2023-11-14T22:13:20+00:00',
                'description': 'Offline FFI fixture.',
              },
            ],
          }),
        );
        await cacheFile.writeAsBytes(bytes, flush: true);
        first = await native.NewsClient.newInstance(dataDir: directory.path);
        final gateway = RustNewsGateway(first);
        final snapshot = await gateway.snapshot();
        expect(snapshot.items.single.title, 'A cached <example>');
        expect(snapshot.lastSuccessMs, 1700000000000);
        expect(snapshot.refreshing, isFalse);
        expect(snapshot.error, isNull);
        await expectLater(
          native.NewsClient.newInstance(dataDir: directory.path),
          throwsA(anything),
        );
        await gateway.shutdown();
        await gateway.shutdown();
        final closed = await gateway.refresh();
        expect(closed.error?.kind, 'closed');
        expect(await cacheFile.readAsBytes(), bytes);
        reopened = await native.NewsClient.newInstance(dataDir: directory.path);
        expect((await reopened.snapshot()).items.single.id, 'fixture-1');
      } finally {
        await reopened?.shutdown();
        await first?.shutdown();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'real bridge rejects relative data directories before opening files',
    () async {
      await expectLater(
        native.NewsClient.newInstance(dataDir: 'relative-preview'),
        throwsA(anything),
      );
    },
  );
}
