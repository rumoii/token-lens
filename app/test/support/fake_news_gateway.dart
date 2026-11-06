import 'package:token_lens_app/news_gateway.dart';

const openaiSource = NewsSource(
  id: 'openai',
  name: 'OpenAI',
  category: SourceCategory.official,
  homeUrl: 'https://openai.com/news/',
  lastSuccessMs: 1700000000000,
);
const hnSource = NewsSource(
  id: 'hn-ai',
  name: 'Hacker News',
  category: SourceCategory.community,
  homeUrl: 'https://news.ycombinator.com/',
);
const codexSource = NewsSource(
  id: 'gh-release:openai/codex',
  name: 'Codex',
  category: SourceCategory.tools,
  homeUrl: 'https://github.com/openai/codex',
);
const qbitSource = NewsSource(
  id: 'qbitai',
  name: '量子位',
  category: SourceCategory.chinese,
  homeUrl: 'https://www.qbitai.com/',
);
const cachedItem = NewsItem(
  id: 'cached',
  sourceId: 'openai',
  title: 'Cached article',
  url: 'https://openai.com/index/cached/',
  description: 'A cached source excerpt.',
);
const freshItem = NewsItem(
  id: 'fresh',
  sourceId: 'openai',
  title: 'Fresh article',
  url: 'https://openai.com/index/fresh/',
);
const cachedNews = NewsSnapshot(sources: [openaiSource], items: [cachedItem]);
const previewSources = <NewsSource>[
  NewsSource(
    id: 'openai',
    name: 'OpenAI',
    category: SourceCategory.official,
    homeUrl: 'https://openai.com/news/',
    lastSuccessMs: 1793890800000,
  ),
  NewsSource(
    id: 'deepmind',
    name: 'Google DeepMind',
    category: SourceCategory.official,
    homeUrl: 'https://deepmind.google/',
    lastSuccessMs: 1793890800000,
  ),
  NewsSource(
    id: 'google-ai',
    name: 'Google AI',
    category: SourceCategory.official,
    homeUrl: 'https://blog.google/technology/ai/',
    lastSuccessMs: 1793890800000,
  ),
  NewsSource(
    id: 'deepseek',
    name: 'DeepSeek',
    category: SourceCategory.official,
    homeUrl: 'https://www.deepseek.com/',
    lastSuccessMs: 1793890800000,
    error: NewsError(kind: 'network', message: 'Synthetic source failure'),
  ),
  NewsSource(
    id: 'gh-release:anthropics/claude-code',
    name: 'Claude Code',
    category: SourceCategory.tools,
    homeUrl: 'https://github.com/anthropics/claude-code',
    lastSuccessMs: 1793890800000,
  ),
  NewsSource(
    id: 'gh-release:openai/codex',
    name: 'Codex',
    category: SourceCategory.tools,
    homeUrl: 'https://github.com/openai/codex',
    lastSuccessMs: 1793890800000,
  ),
  NewsSource(
    id: 'gh-release:google-gemini/gemini-cli',
    name: 'Gemini CLI',
    category: SourceCategory.tools,
    homeUrl: 'https://github.com/google-gemini/gemini-cli',
    lastSuccessMs: 1793890800000,
    error: NewsError(kind: 'timeout', message: 'Synthetic source failure'),
  ),
  NewsSource(
    id: 'gh-release:anomalyco/opencode',
    name: 'OpenCode',
    category: SourceCategory.tools,
    homeUrl: 'https://github.com/anomalyco/opencode',
    lastSuccessMs: 1793890800000,
  ),
  NewsSource(
    id: 'gh-release:earendil-works/pi',
    name: 'Pi',
    category: SourceCategory.tools,
    homeUrl: 'https://github.com/earendil-works/pi',
    lastSuccessMs: 1793890800000,
    enabled: false,
  ),
  NewsSource(
    id: 'gh-release:ollama/ollama',
    name: 'Ollama',
    category: SourceCategory.tools,
    homeUrl: 'https://github.com/ollama/ollama',
    lastSuccessMs: 1793890800000,
  ),
  NewsSource(
    id: 'github-new',
    name: 'GitHub 新项目',
    category: SourceCategory.community,
    homeUrl: 'https://github.com/',
    lastSuccessMs: 1793890800000,
  ),
  NewsSource(
    id: 'hf-models',
    name: 'Hugging Face 模型',
    category: SourceCategory.community,
    homeUrl: 'https://huggingface.co/models',
    lastSuccessMs: 1793890800000,
  ),
  NewsSource(
    id: 'hf-spaces',
    name: 'Hugging Face Spaces',
    category: SourceCategory.community,
    homeUrl: 'https://huggingface.co/spaces',
    lastSuccessMs: 1793890800000,
    enabled: false,
  ),
  NewsSource(
    id: 'hf-papers',
    name: 'Hugging Face 论文',
    category: SourceCategory.community,
    homeUrl: 'https://huggingface.co/papers',
    lastSuccessMs: 1793890800000,
  ),
  NewsSource(
    id: 'hn-ai',
    name: 'Hacker News',
    category: SourceCategory.community,
    homeUrl: 'https://news.ycombinator.com/',
    lastSuccessMs: 1793890800000,
    error: NewsError(kind: 'rate_limited', message: 'Synthetic source failure'),
  ),
  NewsSource(
    id: 'qbitai',
    name: '量子位',
    category: SourceCategory.chinese,
    homeUrl: 'https://www.qbitai.com/',
    lastSuccessMs: 1793890800000,
  ),
];

const multiNews = NewsSnapshot(
  sources: previewSources,
  items: [
    NewsItem(
      id: 'o',
      sourceId: 'openai',
      title: 'OpenAI 模型更新',
      url: 'https://example.com/model',
      publishedAt: '2026-11-05T15:00:00Z',
      description: '来自官方的模型能力与使用说明。',
      alsoIn: ['hn-ai'],
    ),
    NewsItem(
      id: 'c',
      sourceId: 'gh-release:openai/codex',
      title: 'Codex 新版本',
      url: 'https://example.com/codex',
      publishedAt: '2026-11-05T14:00:00Z',
      description: 'CLI 工作流更新与修复。',
      popularityKind: 'stars',
      popularity: 1200,
    ),
    NewsItem(
      id: 'h',
      sourceId: 'hn-ai',
      title: 'Community MODEL discussion',
      url: 'https://example.com/discuss',
      publishedAt: '2026-11-05T13:00:00Z',
      description: 'Local inference benchmark',
      popularityKind: 'points',
      popularity: 312,
    ),
    NewsItem(
      id: 'q',
      sourceId: 'qbitai',
      title: '本周 AI 研究动态',
      url: 'https://example.com/research',
      description: '中文资讯与研究进展。',
    ),
    NewsItem(
      id: 'preview-1',
      sourceId: 'deepmind',
      title: 'Google DeepMind · 发布动态',
      url: 'https://example.com/preview/1',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      id: 'preview-2',
      sourceId: 'google-ai',
      title: 'Google AI · 发布动态',
      url: 'https://example.com/preview/2',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      id: 'preview-3',
      sourceId: 'deepseek',
      title: 'DeepSeek · 发布动态',
      url: 'https://example.com/preview/3',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      id: 'preview-4',
      sourceId: 'gh-release:anthropics/claude-code',
      title: 'Claude Code · 发布动态',
      url: 'https://example.com/preview/4',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      id: 'preview-6',
      sourceId: 'gh-release:google-gemini/gemini-cli',
      title: 'Gemini CLI · 发布动态',
      url: 'https://example.com/preview/6',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      id: 'preview-7',
      sourceId: 'gh-release:anomalyco/opencode',
      title: 'OpenCode · 发布动态',
      url: 'https://example.com/preview/7',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      id: 'preview-8',
      sourceId: 'gh-release:earendil-works/pi',
      title: 'Pi · 发布动态',
      url: 'https://example.com/preview/8',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      id: 'preview-9',
      sourceId: 'gh-release:ollama/ollama',
      title: 'Ollama · 发布动态',
      url: 'https://example.com/preview/9',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      id: 'preview-10',
      sourceId: 'github-new',
      title: 'GitHub 新项目 · 发布动态',
      url: 'https://example.com/preview/10',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      id: 'preview-11',
      sourceId: 'hf-models',
      title: 'Hugging Face 模型 · 发布动态',
      url: 'https://example.com/preview/11',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      id: 'preview-12',
      sourceId: 'hf-spaces',
      title: 'Hugging Face Spaces · 发布动态',
      url: 'https://example.com/preview/12',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      id: 'preview-13',
      sourceId: 'hf-papers',
      title: 'Hugging Face 论文 · 发布动态',
      url: 'https://example.com/preview/13',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
  ],
);

class FakeNewsGateway implements NewsGateway {
  FakeNewsGateway({this.cached = const NewsSnapshot(sources: [openaiSource])});

  NewsSnapshot cached;
  NewsSnapshot? cancelSnapshot;
  Future<NewsSnapshot>? nextRefresh;
  final failures = <String, NewsError>{};
  final refreshedItems = <String, List<NewsItem>>{};
  final refreshRequests = <List<String>?>[];
  final enableRequests = <(String, bool)>[];
  int snapshotCalls = 0;
  int refreshCalls = 0;
  int cancelCalls = 0;
  int shutdownCalls = 0;
  int _generation = 0;
  bool _closed = false;

  @override
  Future<NewsSnapshot> snapshot() async {
    snapshotCalls++;
    return _visible();
  }

  NewsSnapshot _visible() => NewsSnapshot(
    sources: cached.sources,
    items: cached.items
        .where(
          (item) => cached.sources.any(
            (source) =>
                source.enabled &&
                (source.id == item.sourceId || item.alsoIn.contains(source.id)),
          ),
        )
        .toList(),
    refreshing: cached.refreshing,
    error: cached.error,
  );

  @override
  Future<NewsSnapshot> refresh({List<String>? sourceIds}) async {
    refreshCalls++;
    refreshRequests.add(sourceIds == null ? null : List.of(sourceIds));
    if (_closed) {
      return const NewsSnapshot(
        error: NewsError(kind: 'closed', message: 'Closed'),
      );
    }
    final generation = ++_generation;
    final ids = cached.sources
        .where(
          (source) =>
              source.enabled &&
              (sourceIds == null || sourceIds.contains(source.id)),
        )
        .map((source) => source.id)
        .toSet();
    cached = NewsSnapshot(
      sources: cached.sources
          .map((source) => source.copyWith(refreshing: ids.contains(source.id)))
          .toList(),
      items: cached.items,
      refreshing: ids.isNotEmpty,
    );
    if (nextRefresh != null) {
      final result = await nextRefresh!;
      if (!_closed && generation == _generation) cached = result;
      return result;
    }
    final items = [...cached.items];
    for (final id in ids) {
      if (failures.containsKey(id) || !refreshedItems.containsKey(id)) continue;
      items.removeWhere((item) => item.sourceId == id);
      items.addAll(refreshedItems[id]!);
    }
    cached = NewsSnapshot(
      sources: cached.sources.map((source) {
        if (!ids.contains(source.id)) return source;
        return source.copyWith(
          refreshing: false,
          error: failures[source.id],
          clearError: !failures.containsKey(source.id),
          lastSuccessMs: failures.containsKey(source.id) ? null : 1793890800000,
        );
      }).toList(),
      items: items,
    );
    return _visible();
  }

  @override
  Future<NewsSnapshot> setSourceEnabled(String id, bool enabled) async {
    enableRequests.add((id, enabled));
    cached = NewsSnapshot(
      sources: cached.sources
          .map(
            (source) =>
                source.id == id ? source.copyWith(enabled: enabled) : source,
          )
          .toList(),
      items: cached.items,
      refreshing: cached.refreshing,
      error: cached.error,
    );
    return _visible();
  }

  @override
  Future<void> cancelRefresh() async {
    cancelCalls++;
    ++_generation;
    cached =
        cancelSnapshot ??
        NewsSnapshot(
          sources: cached.sources
              .map(
                (source) => source.refreshing
                    ? source.copyWith(
                        refreshing: false,
                        error: const NewsError(
                          kind: 'cancelled',
                          message: 'Cancelled',
                        ),
                      )
                    : source,
              )
              .toList(),
          items: cached.items,
        );
  }

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    _closed = true;
    ++_generation;
  }
}
