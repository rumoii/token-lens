import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:token_lens_app/news_gateway.dart';
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
        expect(snapshot.sources, hasLength(16));
        expect(snapshot.sources.first.id, 'openai');
        expect(snapshot.sources.first.lastSuccessMs, 1700000000000);
        expect(snapshot.items.single.id, 'openai:fixture-1');
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
        expect((await reopened.snapshot()).items.single.id, 'openai:fixture-1');
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

  test(
    'real D2 bridge maps v2 metadata, popularity and cross-source duplicates',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'news-d2-snapshot-',
      );
      RustNewsGateway? gateway;
      Map<String, Object?> item(
        String source,
        String id,
        String url, {
        String? kind,
        int? popularity,
      }) => {
        'id': '$source:$id',
        'source_id': source,
        'title': 'Cached $source',
        'url': url,
        'published_at': '2026-11-05T15:00:00Z',
        'description': 'Literal <example>',
        'popularity_kind': kind,
        'popularity': popularity,
        'also_in': <String>[],
      };
      try {
        await File('${directory.path}/news-cache.json').writeAsString(
          jsonEncode({
            'version': 2,
            'disabled': <String>[],
            'sources': {
              'openai': {
                'items': [
                  item('openai', 'official', 'https://example.com/shared'),
                ],
                'last_success_ms': 123,
              },
              'github-new': {
                'items': [
                  item(
                    'github-new',
                    'duplicate',
                    'https://example.com/shared/?utm_source=github#top',
                    kind: 'stars',
                    popularity: 42,
                  ),
                  item(
                    'github-new',
                    'unique',
                    'https://example.com/project',
                    kind: 'stars',
                    popularity: 42,
                  ),
                ],
                'last_success_ms': 124,
              },
              'gh-release:openai/codex': {
                'items': [
                  item(
                    'gh-release:openai/codex',
                    'release',
                    'https://example.com/release',
                  ),
                ],
                'last_success_ms': 125,
              },
              'qbitai': {
                'items': [
                  item('qbitai', 'chinese', 'https://example.com/chinese'),
                ],
                'last_success_ms': 126,
              },
            },
          }),
        );
        gateway = RustNewsGateway(
          await native.NewsClient.newInstance(dataDir: directory.path),
        );
        final snapshot = await gateway.snapshot();
        expect(snapshot.error, isNull);
        expect(snapshot.sources, hasLength(16));
        expect(
          snapshot.sources.map((s) => s.category).toSet(),
          SourceCategory.values.toSet(),
        );
        expect(snapshot.items, hasLength(4));
        final official = snapshot.items.singleWhere(
          (i) => i.sourceId == 'openai',
        );
        expect(official.alsoIn, ['github-new']);
        expect(official.description, 'Literal <example>');
        final project = snapshot.items.singleWhere(
          (i) => i.id == 'github-new:unique',
        );
        expect(project.popularityKind, 'stars');
        expect(project.popularity, 42);
        expect(
          snapshot.sources.singleWhere((s) => s.id == 'qbitai').lastSuccessMs,
          126,
        );
      } finally {
        await gateway?.shutdown();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'controlled FFI constructor rejects external URLs before opening files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'news-d2-local-boundary-',
      );
      final target = '${directory.path}/unopened';
      try {
        for (final endpoint in [
          'https://example.invalid/rss',
          'http://127.0.0.1.example.invalid/rss',
          'http://127.0.0.1@evil.invalid/rss',
          'file:///local/rss',
          'https://127.0.0.1/rss',
        ]) {
          await expectLater(
            native.NewsClient.newForLocalTest(
              dataDir: target,
              endpoints: [endpoint],
            ),
            throwsA(anything),
          );
          expect(await Directory(target).exists(), isFalse);
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
