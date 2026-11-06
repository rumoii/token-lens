class NewsItem {
  const NewsItem({
    required this.id,
    required this.title,
    required this.url,
    this.publishedAt,
    this.description,
  });

  final String id;
  final String title;
  final String url;
  final String? publishedAt;
  final String? description;
}

class NewsError {
  const NewsError({required this.kind, required this.message});

  final String kind;
  final String message;
}

class NewsSnapshot {
  const NewsSnapshot({
    this.items = const [],
    this.lastSuccessMs,
    this.refreshing = false,
    this.error,
  });

  final List<NewsItem> items;
  final int? lastSuccessMs;
  final bool refreshing;
  final NewsError? error;
}

abstract interface class NewsGateway {
  Future<NewsSnapshot> snapshot();
  Future<NewsSnapshot> refresh();
  Future<void> cancelRefresh();
  Future<void> shutdown();
}
