enum SourceCategory { official, tools, community, chinese }

class NewsSource {
  const NewsSource({
    required this.id,
    required this.name,
    required this.category,
    required this.homeUrl,
    this.enabled = true,
    this.refreshing = false,
    this.lastSuccessMs,
    this.error,
  });

  final String id;
  final String name;
  final SourceCategory category;
  final String homeUrl;
  final bool enabled;
  final bool refreshing;
  final int? lastSuccessMs;
  final NewsError? error;

  NewsSource copyWith({
    bool? enabled,
    bool? refreshing,
    int? lastSuccessMs,
    NewsError? error,
    bool clearError = false,
  }) => NewsSource(
    id: id,
    name: name,
    category: category,
    homeUrl: homeUrl,
    enabled: enabled ?? this.enabled,
    refreshing: refreshing ?? this.refreshing,
    lastSuccessMs: lastSuccessMs ?? this.lastSuccessMs,
    error: clearError ? null : error ?? this.error,
  );
}

class NewsItem {
  const NewsItem({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.url,
    required this.firstSeenMs,
    this.publishedAt,
    this.description,
    this.popularityKind,
    this.popularity,
    this.alsoIn = const [],
    this.kind = 'general',
    this.aiSummary = false,
    this.origin,
  });

  final String id;
  final String sourceId;
  final String title;
  final String url;
  final String? publishedAt;
  final String? description;
  final String? popularityKind;
  final int? popularity;
  final List<String> alsoIn;
  final String kind;
  final bool aiSummary;
  final String? origin;
  final int firstSeenMs;
}

class NewsError {
  const NewsError({required this.kind, required this.message});

  final String kind;
  final String message;
}

class NewsSnapshot {
  const NewsSnapshot({
    this.sources = const [],
    this.items = const [],
    this.refreshing = false,
    this.error,
  });

  final List<NewsSource> sources;
  final List<NewsItem> items;
  final bool refreshing;
  final NewsError? error;
}

abstract interface class NewsGateway {
  Future<NewsSnapshot> snapshot();
  Future<NewsSnapshot> refresh({List<String>? sourceIds});
  Future<NewsSnapshot> setSourceEnabled(String id, bool enabled);
  Future<void> cancelRefresh();
  Future<void> shutdown();
}
