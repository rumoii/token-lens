import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum UpdateKind { available, latest, none, limited, invalid, offline }

class UpdateResult {
  const UpdateResult(this.kind, {this.version, this.publishedAt});
  final UpdateKind kind;
  final String? version;
  final DateTime? publishedAt;
}

class UpdateVersion implements Comparable<UpdateVersion> {
  UpdateVersion(this.value);
  final String value;
  static UpdateVersion? parse(Object? value) {
    if (value is! String) return null;
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(value);
    return match != null && match.end == value.length
        ? UpdateVersion(value)
        : null;
  }

  @override
  int compareTo(UpdateVersion other) {
    final left = value.split('.').map(BigInt.parse).toList();
    final right = other.value.split('.').map(BigInt.parse).toList();
    for (var i = 0; i < 3; i++) {
      final order = left[i].compareTo(right[i]);
      if (order != 0) return order;
    }
    return 0;
  }
}

const _repository = 'rumoii/token-lens';
const updateMaxBytes = 512 * 1024;
Uri get updateEndpoint =>
    Uri.https('api.github.com', '/repos/$_repository/releases/latest');
Uri updateDownloadPage(String version) {
  if (UpdateVersion.parse(version) == null) {
    throw ArgumentError.value(version, 'version');
  }
  return Uri.https('github.com', '/$_repository/releases/tag/v$version');
}

const updateHeaders = {
  'Accept': 'application/vnd.github+json',
  'X-GitHub-Api-Version': '2022-11-28',
  'User-Agent': 'TokenLens-Update',
};

class UpdateResponse {
  const UpdateResponse(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

class UpdateCancellation {
  final _done = Completer<void>();
  final _listeners = <void Function()>{};
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

  void Function() addListener(void Function() listener) {
    if (cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }
}

typedef UpdateRequest = Future<UpdateResponse> Function(
  Uri uri,
  Map<String, String> headers,
  UpdateCancellation cancellation,
);
typedef UpdateTimer = Timer Function(Duration delay, void Function() callback);

UpdateResult parseUpdateResponse(UpdateResponse response, String current) {
  if (response.statusCode == 404) return const UpdateResult(UpdateKind.none);
  if (response.statusCode == 403 || response.statusCode == 429) {
    return const UpdateResult(UpdateKind.limited);
  }
  if (response.statusCode != 200) return const UpdateResult(UpdateKind.offline);
  try {
    if (utf8.encode(response.body).length > updateMaxBytes) {
      throw const UpdateBodyTooLarge();
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic> ||
        body['draft'] != false ||
        body['prerelease'] != false) {
      return const UpdateResult(UpdateKind.invalid);
    }
    final tag = body['tag_name'];
    final version = tag is String && tag.startsWith('v')
        ? UpdateVersion.parse(tag.substring(1))
        : null;
    final installed = UpdateVersion.parse(current);
    if (version == null || installed == null) {
      return const UpdateResult(UpdateKind.invalid);
    }
    final published = body['published_at'];
    return UpdateResult(
      version.compareTo(installed) > 0
          ? UpdateKind.available
          : UpdateKind.latest,
      version: version.value,
      publishedAt: published is String ? DateTime.tryParse(published) : null,
    );
  } catch (_) {
    return const UpdateResult(UpdateKind.invalid);
  }
}

class UpdateBodyTooLarge implements Exception {
  const UpdateBodyTooLarge();
}

Future<UpdateResponse> requestUpdate(
  Uri uri,
  Map<String, String> headers,
  UpdateCancellation cancellation, {
  HttpClient Function()? createClient,
  int maxBytes = updateMaxBytes,
  bool readSuccessfulOnly = false,
}) async {
  if (cancellation.cancelled) throw const HttpException('Update cancelled');
  final client = (createClient ?? HttpClient.new)();
  final detach = cancellation.addListener(() => client.close(force: true));
  try {
    client.userAgent = null;
    client.autoUncompress = false;
    final request = await client.getUrl(uri);
    if (cancellation.cancelled) throw const HttpException('Update cancelled');
    request.followRedirects = false;
    request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
    headers.forEach((key, value) => request.headers.set(key, value));
    final response = await request.close();
    if (response.contentLength > maxBytes) {
      throw const UpdateBodyTooLarge();
    }
    if (readSuccessfulOnly && response.statusCode != HttpStatus.ok) {
      return UpdateResponse(response.statusCode, '');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const UpdateBodyTooLarge();
      }
      bytes.addAll(chunk);
    }
    return UpdateResponse(response.statusCode, utf8.decode(bytes));
  } finally {
    detach();
    client.close(force: true);
  }
}

class UpdateOperation {
  UpdateOperation({this.request = requestUpdate, this.createTimer = Timer.new});
  final UpdateRequest request;
  final UpdateTimer createTimer;
  final cancellation = UpdateCancellation();
  Future<UpdateResult> fetch(String current) async {
    if (cancellation.cancelled) return const UpdateResult(UpdateKind.offline);
    final deadline = createTimer(const Duration(seconds: 15), cancel);
    try {
      final response = await Future.any([
        Future.sync(() => request(updateEndpoint, updateHeaders, cancellation)),
        cancellation.whenCancelled.then<UpdateResponse>(
          (_) => throw const HttpException('Update cancelled'),
        ),
      ]);
      if (cancellation.cancelled) return const UpdateResult(UpdateKind.offline);
      return parseUpdateResponse(response, current);
    } on UpdateBodyTooLarge {
      return const UpdateResult(UpdateKind.invalid);
    } on FormatException {
      return const UpdateResult(UpdateKind.invalid);
    } catch (_) {
      return const UpdateResult(UpdateKind.offline);
    } finally {
      deadline.cancel();
    }
  }

  void cancel() => cancellation.cancel();
}
