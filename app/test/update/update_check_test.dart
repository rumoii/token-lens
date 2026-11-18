import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/update/update_check.dart';
import 'package:token_lens_app/stats/preferences.dart';

String release({
  String tag = 'v0.2.0',
  bool draft = false,
  bool prerelease = false,
  Object? published = '2026-11-15T12:00:00Z',
}) => jsonEncode({
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'published_at': published,
  'html_url': 'https://evil.example/download',
});

class NoUpdateNetwork extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('Update tests must never reach the default HTTP client');
  }
}

void main() {
  final network = NoUpdateNetwork();
  setUp(() {
    network.calls = 0;
    HttpOverrides.global = network;
  });
  tearDown(() {
    expect(network.calls, 0);
    HttpOverrides.global = null;
  });

  test('official release compares numbers and builds its own trusted URL', () {
    final result = parseUpdateResponse(UpdateResponse(200, release()), '0.1.0');
    expect(result.kind, UpdateKind.available);
    expect(result.version, '0.2.0');
    expect(result.publishedAt, DateTime.utc(2026, 11, 15, 12));
    expect(
      updateDownloadPage(result.version!).toString(),
      'https://github.com/rumoii/token-lens/releases/tag/v0.2.0',
    );
    expect(
      updateEndpoint.toString(),
      'https://api.github.com/repos/rumoii/token-lens/releases/latest',
    );
    for (final pair in [
      ('0.10.0', '0.9.99'),
      ('1.0.0', '0.999.999'),
      ('0.1.10', '0.1.9'),
      ('999999999999999999999999.0.0', '9.0.0'),
    ]) {
      expect(
        UpdateVersion.parse(pair.$1)!.compareTo(UpdateVersion.parse(pair.$2)!),
        greaterThan(0),
      );
    }
    for (final current in ['0.2.0', '1.0.0']) {
      expect(
        parseUpdateResponse(UpdateResponse(200, release()), current).kind,
        UpdateKind.latest,
      );
    }
  });
  test('HTTP statuses include redirects and rate limits', () {
    for (final code in [301, 302, 307, 308, 201, 500, 401]) {
      expect(
        parseUpdateResponse(UpdateResponse(code, ''), '0.1.0').kind,
        UpdateKind.offline,
      );
    }
    expect(
      parseUpdateResponse(const UpdateResponse(404, ''), '0.1.0').kind,
      UpdateKind.none,
    );
    for (final code in [403, 429]) {
      expect(
        parseUpdateResponse(UpdateResponse(code, ''), '0.1.0').kind,
        UpdateKind.limited,
      );
    }
  });
  test('invalid JSON, flags, strict tags and missing dates', () {
    for (final body in [
      '[]',
      '{}',
      'null',
      '{',
      release(draft: true),
      release(prerelease: true),
      jsonEncode({'tag_name': 'v0.2.0', 'draft': false}),
      for (final tag in [
        '0.2.0',
        'v0.2',
        'v0.2.0-beta',
        'v0.2.0+1',
        ' v0.2.0',
        'v0.2.0\n',
        'v-1.0.0',
        'v1.0.1.0',
      ])
        release(tag: tag),
      'x' * (512 * 1024 + 1),
    ]) {
      expect(
        parseUpdateResponse(UpdateResponse(200, body), '0.1.0').kind,
        UpdateKind.invalid,
        reason: body.substring(0, body.length.clamp(0, 100)),
      );
    }
    for (final date in [null, false, 'invalid']) {
      final result = parseUpdateResponse(
        UpdateResponse(200, release(published: date)),
        '0.1.0',
      );
      expect(result.kind, UpdateKind.available);
      expect(result.publishedAt, isNull);
    }
    for (final value in [null, 3, '0.1', 'v0.1.0', '0.1.0+1', '0.1.0\n']) {
      expect(UpdateVersion.parse(value), isNull);
    }
    expect(() => updateDownloadPage('0.1.0/../../evil'), throwsArgumentError);
  });
  testWidgets(
    'injected request has exactly three headers; timeout cancels at 15 seconds',
    (t) async {
      final pending = Completer<UpdateResponse>();
      final op = UpdateOperation(
        request: (uri, headers, cancellation) {
          expect(uri, updateEndpoint);
          expect(uri.query, isEmpty);
          expect(headers, {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'TokenLens-Update',
          });
          return pending.future;
        },
      );
      final future = op.fetch('0.1.0');
      await t.pump(const Duration(seconds: 14));
      expect(op.cancellation.cancelled, isFalse);
      await t.pump(const Duration(seconds: 1));
      expect((await future).kind, UpdateKind.offline);
      expect(op.cancellation.cancelled, isTrue);
      pending.complete(UpdateResponse(200, release()));
      await t.pump();
    },
  );
  test('network errors classify offline with fake request only', () async {
    final op = UpdateOperation(
      request: (_, _, _) async => throw const SocketException('fake'),
    );
    expect((await op.fetch('0.1.0')).kind, UpdateKind.offline);
  });
  test(
    'old preferences default updates on; malformed fields are discarded',
    () {
      expect(
        jsonDecode(const UiPreferences().encode())['autoCheckUpdates'],
        true,
      );
      final value = jsonDecode(
        UiPreferences.decode(
          jsonEncode({
            'autoCheckUpdates': 'no',
            'updateLastAttemptMs': -1,
            'updateKind': 'unknown',
            'updateLatestVersion': 'v1.2.3',
            'updatePublishedAtMs': 0,
            'updateIgnoredVersion': '1.2.3+1',
          }),
        ).encode(),
      );
      expect(value['autoCheckUpdates'], true);
      for (final key in [
        'updateLastAttemptMs',
        'updateKind',
        'updateLatestVersion',
        'updatePublishedAtMs',
        'updateIgnoredVersion',
      ]) {
        expect(value[key], isNull);
      }
    },
  );
}
