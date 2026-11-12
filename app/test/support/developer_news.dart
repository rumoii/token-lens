import 'package:token_lens_app/news_gateway.dart';

import 'fake_news_gateway.dart';

final developerSources = <NewsSource>[
  ...previewSources.take(4),
  const NewsSource(
    id: 'anthropic-api',
    name: 'Anthropic API',
    category: SourceCategory.official,
    homeUrl: 'https://example.com/anthropic-api',
  ),
  const NewsSource(
    id: 'openai-api',
    name: 'OpenAI API',
    category: SourceCategory.official,
    homeUrl: 'https://example.com/openai-api',
  ),
  ...previewSources.skip(4),
  const NewsSource(
    id: 'aibase',
    name: 'AIbase 日报',
    category: SourceCategory.chinese,
    homeUrl: 'https://example.com/aibase',
  ),
].map((source) => source.copyWith(enabled: true, clearError: true)).toList();

// D2 fixtures remain unchanged; this separate snapshot covers the D2.5 registry.
final developerNews = NewsSnapshot(
  sources: developerSources,
  items: [
    for (final item in multiNews.items)
      NewsItem(
        firstSeenMs: 1700000000000,
        id: item.id,
        sourceId: item.sourceId,
        title: item.title,
        url: item.url,
        publishedAt: item.publishedAt,
        description: item.description,
        popularityKind: item.popularityKind,
        popularity: item.popularity,
        alsoIn: item.alsoIn,
        kind: switch (item.sourceId) {
          'gh-release:openai/codex' ||
          'gh-release:anthropics/claude-code' ||
          'gh-release:google-gemini/gemini-cli' ||
          'gh-release:anomalyco/opencode' ||
          'gh-release:earendil-works/pi' ||
          'gh-release:ollama/ollama' => 'release',
          'deepseek' => 'pricing',
          'hf-models' => 'model',
          _ => 'general',
        },
      ),
    const NewsItem(
      firstSeenMs: 1793836800000,
      id: 'api',
      sourceId: 'openai-api',
      title: '新增批量请求状态字段',
      url: 'https://example.com/openai-api#2026-11-05',
      publishedAt: '2026-11-05T00:00:00Z',
      description: '合成 API 更新：新增批量任务状态字段。',
      kind: 'api',
    ),
    const NewsItem(
      firstSeenMs: 1793836800000,
      id: 'deprecation',
      sourceId: 'anthropic-api',
      title: '旧版请求参数即将停用',
      url: 'https://example.com/anthropic-api#2026-11-05',
      publishedAt: '2026-11-05T00:00:00Z',
      description: '合成弃用说明：迁移到新的请求参数。',
      kind: 'deprecation',
    ),
    const NewsItem(
      firstSeenMs: 1793750400000,
      id: 'aibase',
      sourceId: 'aibase',
      title: 'AIbase 日报 · 开发工具与模型动态',
      url: 'https://example.com/aibase/1',
      publishedAt: '2026-11-04T00:00:00Z',
      description: '合成日报摘要，不请求详情。',
    ),
    const NewsItem(
      firstSeenMs: 1793793600000,
      id: 'hot-older',
      sourceId: 'hn-ai',
      title: 'A popular AI tooling discussion',
      url: 'https://example.com/hn/older',
      publishedAt: '2026-11-04T12:00:00Z',
      popularityKind: 'points',
      popularity: 480,
    ),
    const NewsItem(
      firstSeenMs: 1793797200000,
      id: 'hot-newer',
      sourceId: 'hn-ai',
      title: 'A newer AI tooling discussion',
      url: 'https://example.com/hn/newer',
      publishedAt: '2026-11-04T13:00:00Z',
      popularityKind: 'points',
      popularity: 480,
    ),
    const NewsItem(
      firstSeenMs: 1700000000000,
      id: 'unranked',
      sourceId: 'hn-ai',
      title: 'AI tooling without heat or date',
      url: 'https://example.com/hn/unranked',
    ),
    const NewsItem(
      firstSeenMs: 1700000000000,
      id: 'stars',
      sourceId: 'github-new',
      title: 'A local agent toolkit',
      url: 'https://example.com/github/new',
      popularityKind: 'stars',
      popularity: 200,
    ),
  ],
);
