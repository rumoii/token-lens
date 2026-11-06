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
    items: List.unmodifiable(
      value.items.map(
        (item) => NewsItem(
          id: item.id,
          sourceId: item.sourceId,
          title: item.title,
          url: item.url,
          publishedAt: item.publishedAt,
          description: item.description,
          popularityKind: item.popularityKind,
          popularity: item.popularity,
          alsoIn: List.unmodifiable(item.alsoIn),
        ),
      ),
    ),
    refreshing: value.refreshing,
    error: _error(value.error),
  );
}
