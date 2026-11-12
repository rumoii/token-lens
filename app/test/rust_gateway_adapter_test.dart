import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_gateway.dart';
import 'package:token_lens_app/rust_gateway.dart';
import 'package:token_lens_app/src/rust/api/news.dart' as native;
import 'package:token_lens_app/src/rust/frb_generated.dart';

import 'support/local_news_server.dart';

void main() {
  setUpAll(() async => RustLib.init());

  test(
    'D26A real FFI preserves summary, origin and first seen fields',
    () async {
      final directory = await Directory.systemTemp.createTemp('news-d26a-ffi-');
      RustNewsGateway? gateway;
      try {
        final cache = File('${directory.path}/news-cache.json');
        final bytes = utf8.encode(
          jsonEncode({
            'version': 2,
            'disabled': <String>[],
            'sources': {
              'aihot': {
                'last_success_ms': 1794000000100,
                'items': [
                  {
                    'id': 'aihot:one',
                    'source_id': 'aihot',
                    'title': 'AIHOT fixture',
                    'url': 'https://example.com/aihot',
                    'published_at': '2026-11-05T00:00:00Z',
                    'description': 'A synthetic summary.',
                    'popularity_kind': null,
                    'popularity': null,
                    'also_in': <String>[],
                    'kind': 'model',
                    'ai_summary': true,
                    'origin': 'OpenRouter：Announcements',
                    'first_seen_ms': 1794000000001,
                  },
                ],
              },
              'openai': {
                'last_success_ms': 123,
                'items': [
                  {
                    'id': 'openai:old',
                    'source_id': 'openai',
                    'title': 'Old cached item',
                    'url': 'https://example.com/old',
                    'published_at': null,
                    'description': null,
                    'popularity_kind': null,
                    'popularity': null,
                    'also_in': <String>[],
                  },
                ],
              },
            },
          }),
        );
        await cache.writeAsBytes(bytes, flush: true);
        for (var attempt = 0; attempt < 2; attempt++) {
          final client = await native.NewsClient.newInstance(
            dataDir: directory.path,
          );
          gateway = RustNewsGateway(client);
          final nativeSnapshot = await client.snapshot();
          expect(nativeSnapshot.error, isNull);
          final nativeItem = nativeSnapshot.items.singleWhere(
            (i) => i.sourceId == 'aihot',
          );
          expect(nativeItem.aiSummary, isTrue);
          expect(nativeItem.origin, 'OpenRouter：Announcements');
          expect(nativeItem.firstSeenMs, 1794000000001);
          final snapshot = await gateway.snapshot();
          expect(snapshot.error, isNull);
          final item = snapshot.items.singleWhere((i) => i.sourceId == 'aihot');
          expect(item.aiSummary, isTrue);
          expect(item.origin, nativeItem.origin);
          expect(item.firstSeenMs, nativeItem.firstSeenMs);
          final legacy = snapshot.items.singleWhere(
            (i) => i.sourceId == 'openai',
          );
          expect(legacy.aiSummary, isFalse);
          expect(legacy.origin, isNull);
          expect(legacy.firstSeenMs, 123);
          expect(await cache.readAsBytes(), bytes);
          await gateway.shutdown();
        }
      } finally {
        await gateway?.shutdown();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'D25E real gateway preserves FFI kinds and old v2 source defaults',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'news-d25e-kinds-',
      );
      RustNewsGateway? gateway;
      Map<String, Object?> entry(String source, String id, {String? kind}) => {
        'id': '$source:$id',
        'source_id': source,
        'title': 'Cached entry',
        'url': 'https://example.com/$source/$id',
        'published_at': null,
        'description': null,
        'popularity_kind': null,
        'popularity': null,
        'also_in': <String>[],
        'kind': ?kind,
      };
      try {
        final cache = File('${directory.path}/news-cache.json');
        final bytes = utf8.encode(
          jsonEncode({
            'version': 2,
            'disabled': <String>[],
            'sources': {
              'openai': {
                'items': [
                  for (final kind in [
                    'release',
                    'api',
                    'deprecation',
                    'pricing',
                    'model',
                    'general',
                  ])
                    entry('openai', kind, kind: kind),
                  entry('openai', 'old'),
                ],
                'last_success_ms': 123,
              },
              for (final source in [
                'gh-release:openai/codex',
                'anthropic-api',
                'openai-api',
              ])
                source: {
                  'items': [entry(source, 'old')],
                  'last_success_ms': 123,
                },
            },
          }),
        );
        await cache.writeAsBytes(bytes, flush: true);
        final client = await native.NewsClient.newInstance(
          dataDir: directory.path,
        );
        gateway = RustNewsGateway(client);
        final snapshot = await gateway.snapshot();
        expect(snapshot.error, isNull);
        for (final kind in [
          'release',
          'api',
          'deprecation',
          'pricing',
          'model',
          'general',
        ]) {
          expect(
            snapshot.items
                .singleWhere((item) => item.id == 'openai:$kind')
                .kind,
            kind,
          );
        }
        for (final (source, expected) in [
          ('openai', 'general'),
          ('gh-release:openai/codex', 'release'),
          ('anthropic-api', 'api'),
          ('openai-api', 'api'),
        ]) {
          expect(
            snapshot.items.singleWhere((item) => item.id == '$source:old').kind,
            expected,
          );
        }
        expect(await cache.readAsBytes(), bytes);
      } finally {
        await gateway?.shutdown();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'real D2 gateway forwards sourceIds to controlled Rust requests',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'news-d2-gateway-',
      );
      final server = await LocalNewsServer.start();
      RustNewsGateway? gateway;
      try {
        gateway = RustNewsGateway(
          await native.NewsClient.newForLocalTest(
            dataDir: directory.path,
            endpoints: server.endpoints,
          ),
        );
        final initial = await gateway.snapshot();
        expect(initial.sources.map((s) => s.id), ['local-0', 'local-1']);
        expect(initial.sources.first.category, SourceCategory.official);
        expect(initial.items, isEmpty);
        expect(server.requests, isEmpty);
        final selected = await gateway.refresh(sourceIds: ['local-1']);
        expect(server.requests, ['/1']);
        expect(selected.items.single.id, 'local-1:one');
        expect(selected.items.single.sourceId, 'local-1');
        expect(selected.items.single.kind, 'general');
        expect(selected.items.single.publishedAt, '2026-11-05T15:00:00Z');
        expect(selected.sources.first.lastSuccessMs, isNull);
        expect(selected.sources.last.lastSuccessMs, isNotNull);
        expect(
          (await gateway.refresh(sourceIds: ['unknown'])).items,
          hasLength(1),
        );
        expect(server.requests, ['/1']);
        final all = await gateway.refresh();
        expect(all.items, hasLength(2));
        expect(server.requests.where((p) => p == '/0'), hasLength(1));
        expect(server.requests.where((p) => p == '/1'), hasLength(2));
        final previous = all.sources.last.lastSuccessMs;
        server.failures['/1'] = 429;
        final partial = await gateway.refresh(sourceIds: ['local-1']);
        expect(partial.error, isNull);
        expect(partial.sources.last.error?.kind, 'rate_limited');
        expect(partial.sources.last.lastSuccessMs, previous);
        expect(
          partial.items.map((i) => i.id).toSet(),
          all.items.map((i) => i.id).toSet(),
        );
        await gateway.shutdown();
        await gateway.shutdown();
        expect(
          (await gateway.refresh(sourceIds: ['local-0'])).error?.kind,
          'closed',
        );
        expect(
          (await gateway.setSourceEnabled('local-0', false)).error?.kind,
          'closed',
        );
        expect(server.requests, hasLength(4));
      } finally {
        await gateway?.shutdown();
        await server.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'real D2 gateway persists enablement while keeping source cache',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'news-d2-enabled-',
      );
      final server = await LocalNewsServer.start();
      RustNewsGateway? gateway;
      try {
        Future<RustNewsGateway> open() async => RustNewsGateway(
          await native.NewsClient.newForLocalTest(
            dataDir: directory.path,
            endpoints: server.endpoints,
          ),
        );
        gateway = await open();
        expect((await gateway.refresh()).items, hasLength(2));
        expect(
          (await gateway.setSourceEnabled(
            'local-1',
            false,
          )).items.single.sourceId,
          'local-0',
        );
        await gateway.shutdown();
        gateway = await open();
        final reopened = await gateway.snapshot();
        expect(reopened.sources.last.enabled, isFalse);
        expect(reopened.items.single.sourceId, 'local-0');
        expect(
          (await gateway.setSourceEnabled('local-1', true)).items,
          hasLength(2),
        );
        expect(server.requests, hasLength(2));
      } finally {
        await gateway?.shutdown();
        await server.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
