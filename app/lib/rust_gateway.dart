import 'news_gateway.dart';
import 'src/rust/api/news.dart' as native;

class RustNewsGateway implements NewsGateway {
  RustNewsGateway(this._client);

  final native.NewsClient _client;
  Future<void>? _shutdown;

  @override
  Future<NewsSnapshot> snapshot() async => _map(await _client.snapshot());

  @override
  Future<NewsSnapshot> refresh({List<String>? sourceIds}) async =>
      _map(await _client.refresh(sourceIds: sourceIds));

  @override
  Future<NewsSnapshot> setSourceEnabled(String id, bool enabled) async =>
      _map(await _client.setSourceEnabled(id: id, enabled: enabled));

  @override
  Future<NewsSnapshot> setRead(List<String> ids, bool read) async =>
      _map(await _client.setRead(ids: ids, read: read));

  @override
  Future<NewsSnapshot> setStarred(String id, bool starred) async =>
      _map(await _client.setStarred(id: id, starred: starred));

  @override
  Future<void> cancelRefresh() => _client.cancelRefresh();

  @override
  Future<void> shutdown() => _shutdown ??= _client.shutdown();

  NewsError? _error(native.NewsError? error) => error == null
      ? null
      : NewsError(kind: error.kind, message: error.message);

  NewsSnapshot _map(native.NewsSnapshot value) => NewsSnapshot(
    sources: List.unmodifiable(
      value.sources.map(
        (source) => NewsSource(
          id: source.id,
          name: source.name,
          category: SourceCategory.values.byName(source.category),
          homeUrl: source.homeUrl,
          enabled: source.enabled,
          refreshing: source.refreshing,
          lastSuccessMs: source.lastSuccessMs,
          error: _error(source.error),
        ),
      ),
    ),
    items: List.unmodifiable(value.items.map(_item)),
    starred: List.unmodifiable(value.starred.map(_item)),
    refreshing: value.refreshing,
    error: _error(value.error),
    stateError: _error(value.stateError),
  );

  NewsItem _item(native.NewsItem item) => NewsItem(
    id: item.id,
    sourceId: item.sourceId,
    title: item.title,
    url: item.url,
    publishedAt: item.publishedAt,
    description: item.description,
    popularityKind: item.popularityKind,
    popularity: item.popularity,
    alsoIn: List.unmodifiable(item.alsoIn),
    kind: item.kind,
    aiSummary: item.aiSummary,
    origin: item.origin,
    firstSeenMs: item.firstSeenMs,
    read: item.read,
    starred: item.starred,
  );
}
