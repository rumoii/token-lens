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
  firstSeenMs: 1700000000000,
  id: 'cached',
  sourceId: 'openai',
  title: 'Cached article',
  url: 'https://openai.com/index/cached/',
  description: 'A cached source excerpt.',
);
const freshItem = NewsItem(
  firstSeenMs: 1700000000000,
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
      firstSeenMs: 1793890800000,
      id: 'o',
      sourceId: 'openai',
      title: 'OpenAI 模型更新',
      url: 'https://example.com/model',
      publishedAt: '2026-11-05T15:00:00Z',
      description: '来自官方的模型能力与使用说明。',
      alsoIn: ['hn-ai'],
    ),
    NewsItem(
      firstSeenMs: 1793887200000,
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
      firstSeenMs: 1793883600000,
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
      firstSeenMs: 1700000000000,
      id: 'q',
      sourceId: 'qbitai',
      title: '本周 AI 研究动态',
      url: 'https://example.com/research',
      description: '中文资讯与研究进展。',
    ),
    NewsItem(
      firstSeenMs: 1700000000000,
      id: 'preview-1',
      sourceId: 'deepmind',
      title: 'Google DeepMind · 发布动态',
      url: 'https://example.com/preview/1',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      firstSeenMs: 1700000000000,
      id: 'preview-2',
      sourceId: 'google-ai',
      title: 'Google AI · 发布动态',
      url: 'https://example.com/preview/2',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      firstSeenMs: 1700000000000,
      id: 'preview-3',
      sourceId: 'deepseek',
      title: 'DeepSeek · 发布动态',
      url: 'https://example.com/preview/3',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      firstSeenMs: 1700000000000,
      id: 'preview-4',
      sourceId: 'gh-release:anthropics/claude-code',
      title: 'Claude Code · 发布动态',
      url: 'https://example.com/preview/4',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      firstSeenMs: 1700000000000,
      id: 'preview-6',
      sourceId: 'gh-release:google-gemini/gemini-cli',
      title: 'Gemini CLI · 发布动态',
      url: 'https://example.com/preview/6',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      firstSeenMs: 1700000000000,
      id: 'preview-7',
      sourceId: 'gh-release:anomalyco/opencode',
      title: 'OpenCode · 发布动态',
      url: 'https://example.com/preview/7',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      firstSeenMs: 1700000000000,
      id: 'preview-8',
      sourceId: 'gh-release:earendil-works/pi',
      title: 'Pi · 发布动态',
      url: 'https://example.com/preview/8',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      firstSeenMs: 1700000000000,
      id: 'preview-9',
      sourceId: 'gh-release:ollama/ollama',
      title: 'Ollama · 发布动态',
      url: 'https://example.com/preview/9',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      firstSeenMs: 1700000000000,
      id: 'preview-10',
      sourceId: 'github-new',
      title: 'GitHub 新项目 · 发布动态',
      url: 'https://example.com/preview/10',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      firstSeenMs: 1700000000000,
      id: 'preview-11',
      sourceId: 'hf-models',
      title: 'Hugging Face 模型 · 发布动态',
      url: 'https://example.com/preview/11',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      firstSeenMs: 1700000000000,
      id: 'preview-12',
      sourceId: 'hf-spaces',
      title: 'Hugging Face Spaces · 发布动态',
      url: 'https://example.com/preview/12',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
    NewsItem(
      firstSeenMs: 1700000000000,
      id: 'preview-13',
      sourceId: 'hf-papers',
      title: 'Hugging Face 论文 · 发布动态',
      url: 'https://example.com/preview/13',
      description: '来源内容的本地合成样例，用于验证多来源布局。',
    ),
  ],
);

class FakeNewsGateway implements NewsGateway {
  FakeNewsGateway({this.cached = const NewsSnapshot(sources: [openaiSource])})
    : _stateWritable = cached.stateError == null,
      _stateError = cached.stateError {
    if (!_stateWritable) return;
    for (final item in [...cached.items, ...cached.starred]) {
      if (item.read) _read[item.id] = nowMs;
    }
    for (final (index, item) in cached.starred.indexed) {
      _starred[item.id] = (nowMs - index, item);
    }
    for (final item in cached.items.where((item) => item.starred)) {
      _starred.putIfAbsent(item.id, () => (nowMs, item));
    }
  }

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
  int nowMs = 1794000000000;
  final readRequests = <(List<String>, bool)>[];
  final starRequests = <(String, bool)>[];
  Map<String, int> _read = {};
  Map<String, (int, NewsItem)> _starred = {};
  final bool _stateWritable;
  NewsError? _stateError;
  NewsError? stateWriteError;
  int _generation = 0;
  bool _closed = false;

  @override
  Future<NewsSnapshot> setRead(List<String> ids, bool read) async {
    readRequests.add((List.of(ids), read));
    if (_closed) return _closedSnapshot();
    if (!_stateWritable || ids.isEmpty) return _visible();
    final known = {...cached.items.map((i) => i.id), ..._starred.keys};
    final candidate = Map.of(_read);
    var accepted = false;
    for (final id in ids.where(known.contains)) {
      accepted = true;
      if (read) {
        candidate.putIfAbsent(id, () => nowMs);
      } else {
        candidate.remove(id);
      }
    }
    if (accepted) _saveState(candidate, Map.of(_starred));
    return _visible();
  }

  @override
  Future<NewsSnapshot> setStarred(String id, bool starred) async {
    starRequests.add((id, starred));
    if (_closed) return _closedSnapshot();
    if (!_stateWritable) return _visible();
    final candidate = Map.of(_starred);
    if (starred) {
      if (!candidate.containsKey(id)) {
        final matches = _visible().items.where(
          (i) =>
              i.id == id &&
              cached.sources.any((s) => s.id == i.sourceId && s.enabled),
        );
        if (matches.isEmpty) return _visible();
        candidate[id] = (nowMs, matches.first);
      }
    } else if (candidate.remove(id) == null) {
      return _visible();
    }
    _saveState(Map.of(_read), candidate);
    return _visible();
  }

  void _saveState(Map<String, int> read, Map<String, (int, NewsItem)> starred) {
    if (stateWriteError != null) {
      _stateError = stateWriteError;
      return;
    }
    final cachedIds = cached.items.map((i) => i.id).toSet();
    read.removeWhere(
      (id, time) =>
          time < nowMs - 30 * 24 * 60 * 60 * 1000 && !cachedIds.contains(id),
    );
    _read = read;
    _starred = starred;
    _stateError = null;
  }

  NewsSnapshot _closedSnapshot() {
    final snapshot = _visible();
    return NewsSnapshot(
      sources: snapshot.sources,
      items: snapshot.items,
      starred: snapshot.starred,
      stateError: snapshot.stateError,
      error: const NewsError(kind: 'closed', message: 'Closed'),
    );
  }

  void _updateCopies(Set<String> successful) {
    if (!_stateWritable) return;
    final candidate = Map.of(_starred);
    final visible = _visible().items;
    var changed = false;
    for (final item in cached.items.where(
      (i) => successful.contains(i.sourceId),
    )) {
      final previous = candidate[item.id];
      if (previous == null) continue;
      final current = visible.where((i) => i.id == item.id);
      candidate[item.id] = (
        previous.$1,
        current.isEmpty ? item : current.first,
      );
      changed = true;
    }
    if (changed) _saveState(Map.of(_read), candidate);
  }

  @override
  Future<NewsSnapshot> snapshot() async {
    snapshotCalls++;
    return _visible();
  }

  NewsSnapshot _visible() {
    NewsItem flags(NewsItem item) => item.copyWith(
      read: _read.containsKey(item.id),
      starred: _starred.containsKey(item.id),
    );
    final items = cached.items
        .where(
          (item) => cached.sources.any(
            (source) =>
                source.enabled &&
                (source.id == item.sourceId || item.alsoIn.contains(source.id)),
          ),
        )
        .map(flags)
        .toList();
    final saved = _starred.values.toList()
      ..sort((a, b) {
        final order = b.$1.compareTo(a.$1);
        return order == 0 ? a.$2.id.compareTo(b.$2.id) : order;
      });
    return NewsSnapshot(
      sources: cached.sources,
      items: items,
      starred: saved.map((entry) {
        final current = items.where((i) => i.id == entry.$2.id);
        return flags(current.isEmpty ? entry.$2 : current.first);
      }).toList(),
      stateError: _stateError,
      refreshing: cached.refreshing,
      error: cached.error,
    );
  }

  @override
  Future<NewsSnapshot> refresh({List<String>? sourceIds}) async {
    refreshCalls++;
    refreshRequests.add(sourceIds == null ? null : List.of(sourceIds));
    if (_closed) {
      return _closedSnapshot();
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
      if (!_closed && generation == _generation) {
        cached = result;
        _updateCopies(
          ids
              .where(
                (id) =>
                    !result.sources.any((s) => s.id == id && s.error != null),
              )
              .toSet(),
        );
        return _visible();
      }
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
    _updateCopies(ids.where((id) => !failures.containsKey(id)).toSet());
    return _visible();
  }

  @override
  Future<NewsSnapshot> setSourceEnabled(String id, bool enabled) async {
    enableRequests.add((id, enabled));
    if (_closed) return _closedSnapshot();
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
