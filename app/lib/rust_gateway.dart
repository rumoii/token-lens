import 'news_gateway.dart';
import 'src/rust/api/news.dart' as native;

class RustNewsGateway implements NewsGateway {
  RustNewsGateway(this._client);

  final native.NewsClient _client;
  Future<void>? _shutdown;

  @override
  Future<NewsSnapshot> snapshot() async => _map(await _client.snapshot());

  @override
  Future<NewsSnapshot> refresh() async => _map(await _client.refresh());

  @override
  Future<void> cancelRefresh() async => _client.cancelRefresh();

  @override
  Future<void> shutdown() => _shutdown ??= _client.shutdown();

  static NewsSnapshot _map(native.NewsSnapshot value) => NewsSnapshot(
    items: List.unmodifiable(
      value.items.map(
        (item) => NewsItem(
          id: item.id,
          title: item.title,
          url: item.url,
          publishedAt: item.publishedAt,
          description: item.description,
        ),
      ),
    ),
    lastSuccessMs: value.lastSuccessMs,
    refreshing: value.refreshing,
    error: value.error == null
        ? null
        : NewsError(kind: value.error!.kind, message: value.error!.message),
  );
}
