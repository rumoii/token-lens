import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/news_controller.dart';
import 'package:token_lens_app/news_gateway.dart';

import 'support/fake_news_gateway.dart';

NewsSource source(
  String id, {
  bool enabled = true,
  SourceCategory category = SourceCategory.community,
  int? lastSuccessMs,
  NewsError? error,
}) => NewsSource(
  id: id,
  name: id,
  category: category,
  homeUrl: 'https://example.com',
  enabled: enabled,
  lastSuccessMs: lastSuccessMs,
  error: error,
);

NewsItem item(
  String id, {
  String sourceId = 'a',
  int seen = 1,
  String? published,
  bool read = false,
  bool starred = false,
  List<String> alsoIn = const [],
  String kind = 'general',
  int? heat,
  String? unit,
  String? description,
}) => NewsItem(
  id: id,
  sourceId: sourceId,
  title: id,
  url: 'https://example.com/$id',
  firstSeenMs: seen,
  publishedAt: published,
  read: read,
  starred: starred,
  alsoIn: alsoIn,
  kind: kind,
  popularity: heat,
  popularityKind: unit,
  description: description,
);

Future<NewsController> loaded(
  NewsSnapshot snapshot, {
  DateTime Function()? now,
}) async {
  final controller = NewsController(
    FakeNewsGateway(cached: snapshot),
    now: now,
  );
  addTearDown(controller.dispose);
  await controller.load();
  return controller;
}

void main() {
  test(
    'ranges, independent counts, disabled stars and unfiltered unread',
    () async {
      final c = await loaded(
        NewsSnapshot(
          sources: [
            source('a'),
            source('b', enabled: false, category: SourceCategory.tools),
          ],
          items: [
            item('unread', kind: 'model', description: 'Find me'),
            item('read', read: true),
            item('disabled', sourceId: 'b'),
            item('merged', sourceId: 'b', alsoIn: ['a']),
          ],
          starred: [
            item(
              'saved',
              sourceId: 'b',
              starred: true,
              kind: 'model',
              description: 'Find me',
            ),
          ],
        ),
      );
      expect(c.view, NewsView.all);
      expect(c.visibleItems.map((i) => i.id), ['unread', 'read', 'merged']);
      expect(c.viewCount(NewsView.all), 3);
      expect(c.viewCount(NewsView.unread), 2);
      expect(c.viewCount(NewsView.starred), 1);
      expect(c.totalUnread, 2);
      c.setView(NewsView.unread);
      expect(c.visibleItems.map((i) => i.id), ['unread', 'merged']);
      c.setView(NewsView.starred);
      expect(c.visibleItems.single.id, 'saved');
      c.setCategory(SourceCategory.tools);
      c.toggleSourceFilter('b');
      c.toggleKindFilter('model');
      c.setQuery('  FIND ME  ');
      expect(c.visibleItems.single.id, 'saved');
      expect(c.viewCount(NewsView.all), 0);
      expect(c.viewCount(NewsView.unread), 0);
      expect(c.viewCount(NewsView.starred), 1);
      expect(c.totalUnread, 2);
      c.setQuery('missing');
      expect(c.visibleItems, isEmpty);
      expect(c.totalUnread, 2);
    },
  );

  test(
    'star category and source filters match alsoIn without enabled check',
    () async {
      final c = await loaded(
        NewsSnapshot(
          sources: [
            source('a'),
            source('b', enabled: false, category: SourceCategory.official),
          ],
          starred: [
            item('merged', starred: true, alsoIn: ['b']),
          ],
        ),
      );
      c.setView(NewsView.starred);
      c.setCategory(SourceCategory.official);
      c.toggleSourceFilter('b');
      expect(c.visibleItems.single.id, 'merged');
      expect(c.categoryCount(SourceCategory.official), 1);
      expect(c.viewCount(NewsView.starred), 1);
    },
  );

  test('latest sorts first seen, publication, registration, snapshot order in both ranges', () async {
    final items = [
      item('b-tie', sourceId: 'b', seen: 10, published: '2026-01-02T00:00:00Z'),
      item('a-tie-1', seen: 10, published: '2026-01-02T00:00:00Z'),
      item('a-tie-2', seen: 10, published: '2026-01-02T00:00:00Z'),
      item('no-date', seen: 10),
      item('older-published', seen: 10, published: '2026-01-01'),
      item('newly-seen', seen: 11),
      item('old-seen', seen: 9, published: '2027-01-01'),
      item('invalid-date', seen: 10, published: 'invalid'),
    ];
    final c = await loaded(
      NewsSnapshot(
        sources: [source('a'), source('b')],
        items: items,
        starred: items.map((i) => i.copyWith(starred: true)).toList(),
      ),
    );
    const expected = [
      'newly-seen',
      'a-tie-1',
      'a-tie-2',
      'b-tie',
      'older-published',
      'no-date',
      'invalid-date',
      'old-seen',
    ];
    expect(c.visibleItems.map((i) => i.id), expected);
    c.setView(NewsView.starred);
    expect(c.visibleItems.map((i) => i.id), expected);
  });

  test(
    'hot sorting retains publication tie break and availability follows range',
    () async {
      final c = await loaded(
        NewsSnapshot(
          sources: [source('a')],
          items: [
            item(
              'old-published',
              seen: 100,
              published: '2026-01-01',
              heat: 9,
              unit: 'stars',
            ),
            item(
              'new-published',
              seen: 1,
              published: '2026-01-02',
              heat: 9,
              unit: 'stars',
            ),
            item('highest', heat: 10, unit: 'stars'),
            item('no-heat'),
          ],
          starred: [item('votes', starred: true, heat: 1, unit: 'votes')],
        ),
      );
      expect(c.hotSortAvailable, isTrue);
      c.setSort(NewsSort.hot);
      expect(c.visibleItems.map((i) => i.id), [
        'highest',
        'new-published',
        'old-published',
        'no-heat',
      ]);
      c.setView(NewsView.starred);
      expect(c.hotSortAvailable, isTrue);
      expect(c.sortExplanation, contains('votes'));
      c.setQuery('missing');
      expect(c.hotSortAvailable, isFalse);
      expect(c.sort, NewsSort.latest);
    },
  );

  test(
    'starred ties keep starred snapshot order instead of live item order',
    () async {
      final first = item('first', starred: true);
      final second = item('second', starred: true);
      final c = await loaded(
        NewsSnapshot(
          sources: [source('a')],
          items: [first, second],
          starred: [second, first],
        ),
      );
      expect(c.visibleItems.map((i) => i.id), ['first', 'second']);
      c.setView(NewsView.starred);
      expect(c.visibleItems.map((i) => i.id), ['second', 'first']);
    },
  );

  test(
    'local midnight groups preserve order, dates, today/yesterday and unread',
    () async {
      final midnight = DateTime(2026, 11, 11);
      final times = [
        midnight.add(const Duration(minutes: 1)),
        midnight.subtract(const Duration(minutes: 1)),
        DateTime(2026, 11, 9, 12),
      ];
      final c = await loaded(
        NewsSnapshot(
          sources: [source('a')],
          items: [
            item('before', seen: times[1].millisecondsSinceEpoch, read: true),
            item('after', seen: times[0].millisecondsSinceEpoch),
            item('older', seen: times[2].millisecondsSinceEpoch),
          ],
        ),
        now: () => midnight.add(const Duration(hours: 12)),
      );
      final groups = c.dayGroups;
      expect(groups, hasLength(3));
      for (var n = 0; n < times.length; n++) {
        final local = DateTime.fromMillisecondsSinceEpoch(
          times[n].millisecondsSinceEpoch,
        ).toLocal();
        expect(groups[n].date, DateTime(local.year, local.month, local.day));
        expect(groups[n].isToday, n == 0);
        expect(groups[n].isYesterday, n == 1);
        expect(groups[n].isHot, isFalse);
      }
      expect(
        groups.expand((g) => g.items).map((i) => i.id),
        c.visibleItems.map((i) => i.id),
      );
      expect(groups.map((g) => g.unreadCount), [1, 0, 1]);
    },
  );

  test(
    'hot grouping is one undated group, including an empty latest result',
    () async {
      final c = await loaded(
        NewsSnapshot(
          sources: [source('a')],
          items: [
            item('hot', heat: 3, unit: 'stars'),
            item('read', heat: 1, unit: 'stars', read: true),
          ],
        ),
      );
      c.setSort(NewsSort.hot);
      final group = c.dayGroups.single;
      expect(group.date, isNull);
      expect(group.isHot, isTrue);
      expect(group.isToday, isFalse);
      expect(group.isYesterday, isFalse);
      expect(group.unreadCount, 1);
      expect(group.items, c.visibleItems);
      c.setQuery('missing');
      expect(c.dayGroups, isEmpty);
    },
  );

  test(
    'hot tabs fixed order, fallback, top five and filter independence',
    () async {
      final c = await loaded(
        NewsSnapshot(
          sources: [
            source('hf-spaces', enabled: false),
            source('hf-papers'),
            source('hf-models'),
            source('github-new'),
            source('hn-ai'),
            source('other'),
          ],
          items: [
            for (var n = 0; n < 7; n++)
              item(
                'hn$n',
                sourceId: 'hn-ai',
                heat: n == 6 ? 5 : n,
                seen: n,
                unit: 'votes',
              ),
            item('github', sourceId: 'github-new', heat: 10, unit: 'stars'),
            item('models', sourceId: 'hf-models'),
            item('papers', sourceId: 'hf-papers', heat: 0, unit: 'likes'),
            item('spaces', sourceId: 'hf-spaces', heat: 10, unit: 'likes'),
            item('other', sourceId: 'other', heat: 10, unit: 'likes'),
          ],
        ),
      );
      expect(c.hotTabs, ['hn-ai', 'github-new', 'hf-papers']);
      expect(c.hotTab, 'hn-ai');
      c.setHotTab('github-new');
      expect(c.hotTab, 'github-new');
      c.setCategory(SourceCategory.tools);
      c.toggleSourceFilter('other');
      c.toggleKindFilter('model');
      c.setView(NewsView.starred);
      c.setQuery('missing');
      expect(c.hotItems('hn-ai').map((i) => i.id), [
        'hn6',
        'hn5',
        'hn4',
        'hn3',
        'hn2',
      ]);
      expect(c.hotTabs, ['hn-ai', 'github-new', 'hf-papers']);
      await c.setSourceEnabled('github-new', false);
      expect(c.hotTab, 'hn-ai');
      expect(c.hotItems('github-new'), isEmpty);
      c.setHotTab('invalid');
      expect(c.hotTab, 'hn-ai');
      await c.setSourceEnabled('hn-ai', false);
      await c.setSourceEnabled('hf-papers', false);
      expect(c.hotTabs, isEmpty);
      expect(c.hotTab, isNull);
      await c.setSourceEnabled('github-new', true);
      expect(c.hotTab, 'github-new');
    },
  );

  test('header aggregates only enabled sources', () async {
    final c = await loaded(
      NewsSnapshot(
        sources: [
          source('a', lastSuccessMs: 10),
          source(
            'b',
            lastSuccessMs: 20,
            error: const NewsError(kind: 'timeout', message: 'Timeout'),
          ),
          source(
            'c',
            enabled: false,
            lastSuccessMs: 100,
            error: const NewsError(kind: 'network', message: 'Offline'),
          ),
        ],
      ),
    );
    expect(c.lastRefreshMs, 20);
    expect(c.failedSourceCount, 1);
    final empty = await loaded(const NewsSnapshot());
    expect(empty.lastRefreshMs, isNull);
    expect(empty.failedSourceCount, 0);
  });
}
