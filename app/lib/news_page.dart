import 'l10n/app_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'news_controller.dart';
import 'news_gateway.dart';
import 'smooth_wheel.dart';
import 'stats/theme/palette.dart';
import 'stats/widgets/filters.dart';
import 'stats/widgets/primitives.dart';
import 'stats/widgets/side_panel.dart';

Map<String, String> _kindNames(AppStrings strings) => {
  'release': strings.release,
  'api': 'API',
  'deprecation': strings.deprecation,
  'pricing': strings.pricing,
  'model': strings.model,
  'general': strings.generalNoLabel,
};

Map<String, (String, String)> _metrics(AppStrings strings) => {
  'points': (strings.pts, strings.hackerNewsPoints),
  'stars': (strings.stars, strings.githubStars),
  'likes': (strings.likes, strings.huggingFaceLikes),
  'upvotes': (strings.upvotes, strings.huggingFacePaperUpvotes),
};

// These sources publish a calendar day without a time of day.
const _dateOnlySources = {'openai-api', 'anthropic-api', 'aibase'};

class NewsPage extends StatefulWidget {
  const NewsPage({
    super.key,
    required this.controller,
    required this.openLink,
    this.now = DateTime.now,
  });

  final NewsController controller;
  final Future<bool> Function(Uri) openLink;
  final DateTime Function() now;

  @override
  State<NewsPage> createState() => _NewsPageState();
}

class _NewsPageState extends State<NewsPage> {
  final Set<String> _opening = {};
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = SmoothWheelController();
  final _headerKey = GlobalKey();
  final _stuck = ValueNotifier(false);
  final _filterButtonFocus = FocusNode();
  final _filterAnchor = GlobalKey();
  final _manageFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.load();
    _search.text = widget.controller.query;
    _scroll.addListener(_measureStuck);
    HardwareKeyboard.instance.addHandler(_slash);
  }

  @override
  void didUpdateWidget(NewsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) widget.controller.load();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_slash);
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    _stuck.dispose();
    _filterButtonFocus.dispose();
    _manageFocus.dispose();
    super.dispose();
  }

  void _measureStuck() {
    final header = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (header == null || !_scroll.hasClients) return;
    _stuck.value = _scroll.offset > header.size.height;
  }

  bool _slash(KeyEvent event) {
    if (event is! KeyDownEvent || event.character != '/') return false;
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    _searchFocus.requestFocus();
    return true;
  }

  Future<void> _open(NewsItem item) async {
    if (_opening.contains(item.id)) return;
    if (!item.read) unawaited(widget.controller.openedItem(item.id));
    final uri = Uri.tryParse(item.url);
    if (uri == null ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      _showOpenError();
      return;
    }
    setState(() => _opening.add(item.id));
    var success = false;
    try {
      success = await widget.openLink(uri);
    } catch (_) {
      success = false;
    }
    if (!mounted) return;
    setState(() => _opening.remove(item.id));
    if (!success) _showOpenError();
  }

  void _showOpenError() {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(context.strings.couldNotOpenTheArticleCheckYour)),
    );
  }

  Future<void> _manageSources() async {
    await showLensPanel(
      context,
      label: context.strings.manageSources,
      title: context.strings.manageSources,
      hint: context.strings.enableOrDisableSourcesAndCheckRefresh,
      icon: Icon(
        Icons.tune_rounded,
        size: 20,
        color: LensPalette.of(context).secondary,
      ),
      body: _SourcesPanel(controller: widget.controller, now: widget.now),
    );
    if (mounted) _manageFocus.requestFocus();
  }

  void _clearFilters() {
    _search.clear();
    widget.controller.clearFilters();
  }

  String _sourceName(String id) =>
      widget.controller.snapshot.sources
          .where((source) => source.id == id)
          .map((source) => source.name)
          .firstOrNull ??
      id;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => Scaffold(
        backgroundColor: p['surface-1'],
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = MediaQuery.sizeOf(context).width < 768;
              final pad = narrow ? 14.0 : 36.0;
              final gutter = ((constraints.maxWidth - 1000) / 2)
                  .clamp(0.0, double.infinity)
                  .toDouble();
              // A pinned toolbar must leave room to read the list.
              final pinned =
                  constraints.maxHeight >= 560 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 21;
              return CustomScrollView(
                key: const Key('news-scroll'),
                controller: _scroll,
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      gutter + pad,
                      narrow ? 18 : 28,
                      gutter + pad,
                      0,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: KeyedSubtree(
                        key: _headerKey,
                        child: _header(p, narrow),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: gutter),
                    sliver: pinned
                        ? PinnedHeaderSliver(child: _toolbar(p, pad))
                        : SliverToBoxAdapter(child: _toolbar(p, pad)),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      gutter + pad - 8,
                      0,
                      gutter + pad - 8,
                      48,
                    ),
                    sliver: _list(p),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _header(LensPalette p, bool narrow) {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            context.strings.aiNews,
            style: p
                .serif(narrow ? 26 : 30, weight: FontWeight.w500)
                .copyWith(height: 1.25, letterSpacing: -.3),
          ),
        ),
        const SizedBox(height: 6),
        _subtitle(p),
      ],
    );
    final busy =
        snapshot.refreshing ||
        controller.loadingSnapshot ||
        controller.updatingSourceId != null;
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LensButton(
          key: const Key('manage-sources'),
          label: context.strings.manageSources,
          icon: Icons.tune_rounded,
          focusNode: _manageFocus,
          onPressed: _manageSources,
        ),
        const SizedBox(width: 8),
        snapshot.refreshing
            ? LensButton(
                key: const Key('refresh-news'),
                label: controller.cancelling
                    ? context.strings.canceling
                    : context.strings.cancelRefresh,
                icon: Icons.refresh_rounded,
                spinning: true,
                onPressed: controller.cancelling
                    ? null
                    : controller.cancelRefresh,
              )
            : LensIconButton(
                tonal: true,
                key: const Key('refresh-news'),
                tooltip: context.strings.refreshNow,
                icon: Icons.refresh_rounded,
                onPressed: busy ? null : () => controller.refresh(),
              ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 16,
          runSpacing: 12,
          children: [title, actions],
        ),
        ..._notices(p),
        if (controller.hotTabs.isNotEmpty) ...[
          const SizedBox(height: 22),
          _hotCard(p),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _subtitle(LensPalette p) {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    final sources = snapshot.sources.where((source) => source.enabled);
    final failed = controller.failedSourceCount;
    final style = p.text(13, p.muted);
    final String text;
    final Color dot;
    if (snapshot.refreshing) {
      text = controller.cancelling
          ? context.strings.cancelingRefresh
          : context.strings.refreshProgress(
              controller.refreshDone,
              controller.refreshTotal,
            );
      dot = p['clay'];
    } else {
      final last = controller.lastRefreshMs;
      final when = last == null
          ? context.strings.neverRefreshed
          : context.strings.refreshed0(
              _refreshTime(last, widget.now(), context.strings),
            );
      text = context.strings.newsRefreshSummary(sources.length, when);
      dot = failed > 0 ? p['warn'] : p['ok'];
    }
    return Semantics(
      liveRegion: true,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: [
          ExcludeSemantics(
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
          ),
          Text(text, style: style),
          if (failed > 0 && !snapshot.refreshing) ...[
            Text('·', style: style),
            LensTextLink(
              key: const Key('failed-sources'),
              label: context.strings.sourcesNotUpdated(failed),
              onTap: _manageSources,
              tone: 'warn',
              fontSize: 13,
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _notices(LensPalette p) {
    final snapshot = widget.controller.snapshot;
    final notices = <(String, String)>[
      if (!snapshot.refreshing && snapshot.error != null)
        snapshot.error!.kind == 'cancelled'
            ? (
                context.strings.refreshCanceled,
                _errorCopy(snapshot.error!, context.strings),
              )
            : (
                context.strings.refreshFailedShowingCachedNews,
                _errorCopy(snapshot.error!, context.strings),
              ),
      if (snapshot.stateError != null)
        (
          context.strings.readAndStarredStatusUnavailable,
          context.strings.couldNotReadOrSaveLocalStatus,
        ),
    ];
    return [
      for (final notice in notices) ...[
        const SizedBox(height: 14),
        Semantics(
          liveRegion: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: p['surface-0'],
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: p['warn'],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${notice.$1}  ',
                          style: p.text(13, p.ink, FontWeight.w500),
                        ),
                        TextSpan(
                          text: notice.$2,
                          style: p.text(13, p.secondary),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ];
  }

  Widget _hotCard(LensPalette p) {
    final controller = widget.controller;
    final tab = controller.hotTab!;
    final items = controller.hotItems(tab);
    return LensCard(
      key: const Key('hot-card'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      radius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: p['clay'],
                        shape: BoxShape.circle,
                      ),
                    ),
                    Semantics(
                      header: true,
                      child: Text(
                        context.strings.trendingNow,
                        style: p.text(14, null, FontWeight.w600),
                      ),
                    ),
                    Text(
                      context.strings.rankedByThisSource,
                      style: p.text(12, p.faint),
                    ),
                  ],
                ),
                ScrollFade(
                  child: LensSegmented(
                    label: context.strings.trendingSources,
                    small: true,
                    options: {
                      for (final id in controller.hotTabs)
                        id: _sourceName(id)
                            .replaceFirst('Hugging Face ', 'HF '),
                    },
                    value: tab,
                    onChanged: controller.setHotTab,
                  ),
                ),
              ],
            ),
          ),
          for (final (index, item) in items.indexed)
            _HotRow(
              key: ValueKey('hot-${item.id}'),
              rank: index + 1,
              item: item,
              onOpen: () => _open(item),
            ),
        ],
      ),
    );
  }

  Widget _toolbar(LensPalette p, double pad) {
    final controller = widget.controller;
    final chips = Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final category in [null, ...SourceCategory.values])
          LensChip(
            key: Key('category-${category?.name ?? 'all'}'),
            size: 'sm',
            label: category == null
                ? context.strings.all
                : _categoryName(category, context.strings),
            count: controller.categoryCount(category),
            selected: controller.category == category,
            onPressed: () => controller.setCategory(category),
          ),
      ],
    );
    final unread = controller.viewCount(NewsView.unread);
    final starred = controller.viewCount(NewsView.starred);
    final filtered =
        controller.sourceIds.isNotEmpty || controller.kindIds.isNotEmpty;
    final controls = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        LensSegmented(
          key: const Key('news-view'),
          label: context.strings.view,
          small: true,
          options: {
            'all': context.strings.all,
            'unread': unread == 0
                ? context.strings.unread
                : context.strings.unread0(unread),
            'starred': starred == 0
                ? context.strings.starred
                : context.strings.starred0(starred),
          },
          value: controller.view.name,
          onChanged: (value) =>
              controller.setView(NewsView.values.byName(value)),
        ),
        if (controller.hotSortAvailable)
          LensSegmented(
            key: const Key('news-sort'),
            label: context.strings.sort,
            small: true,
            options: {
              'latest': context.strings.latest,
              'hot': context.strings.popular,
            },
            value: controller.sort.name,
            onChanged: (value) =>
                controller.setSort(NewsSort.values.byName(value)),
          ),
        _searchField(p),
        _filterMenu(p, filtered),
      ],
    );
    return ValueListenableBuilder(
      valueListenable: _stuck,
      builder: (context, stuck, child) => Container(
        padding: EdgeInsets.fromLTRB(pad, 10, pad, 10),
        decoration: BoxDecoration(
          color: p['surface-1'],
          border: Border(
            bottom: BorderSide(
              width: LensPalette.hairline(context),
              color: stuck ? p['line'] : LensPalette.transparent,
            ),
          ),
        ),
        child: child,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: [chips, controls],
          ),
          if (filtered) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final id in controller.sourceIds)
                  FilterTag(
                    key: Key('filter-tag-$id'),
                    label: context.strings.source,
                    value: _sourceName(id),
                    onRemove: () => controller.toggleSourceFilter(id),
                  ),
                for (final kind in controller.kindIds)
                  FilterTag(
                    key: Key('filter-tag-kind-$kind'),
                    label: context.strings.type,
                    value: _kindNames(context.strings)[kind] ?? kind,
                    onRemove: () => controller.toggleKindFilter(kind),
                  ),
                LensButton(
                  label: context.strings.clearFilters,
                  variant: 'ghost',
                  size: 'xs',
                  onPressed: _clearFilters,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _searchField(LensPalette p) => SizedBox(
    width: 205,
    child: LensInput(
      key: const Key('news-search'),
      controller: _search,
      focusNode: _searchFocus,
      size: 'sm',
      search: true,
      hint: context.strings.searchTitlesAndSummaries,
      onChanged: widget.controller.setQuery,
      hintAccessory: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Text('/', style: p.text(12, p.faint)),
        ),
      ),
    ),
  );

  Widget _filterMenu(LensPalette p, bool filtered) {
    final controller = widget.controller;
    final strings = context.strings;
    final kinds = _kindNames(strings);
    Future<void> open() async {
      _filterButtonFocus.requestFocus();
      await LensMenu.show<void>(
        context,
        anchor: _filterAnchor.currentContext!,
        width: 278,
        maxHeight: 560,
        builder: (context) => ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final counts = <String, int>{};
            for (final item in controller.snapshot.items) {
              for (final id in {item.sourceId, ...item.alsoIn}) {
                counts[id] = (counts[id] ?? 0) + 1;
              }
            }
            LensMenuEntry group(String key, String label) => LensMenuEntry(
              key: Key(key),
              Text(label, style: p.text(12, p.muted, FontWeight.w500)),
            );
            return LensMenu(
              entries: [
                group('filter-group-kind', strings.type),
                for (final kind in kinds.keys)
                  LensMenuEntry(
                    key: Key('kind-filter-$kind'),
                    Text(kinds[kind]!),
                    checked: controller.kindIds.contains(kind),
                    onPressed: () => controller.toggleKindFilter(kind),
                  ),
                for (final category in SourceCategory.values) ...[
                  group(
                    'filter-group-${category.name}',
                    _categoryName(category, strings),
                  ),
                  for (final source in controller.snapshot.sources.where(
                    (source) => source.category == category && source.enabled,
                  ))
                    LensMenuEntry(
                      key: Key('filter-${source.id}'),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              source.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${counts[source.id] ?? 0}',
                            style: p.text(12, p.faint),
                          ),
                        ],
                      ),
                      checked: controller.sourceIds.contains(source.id),
                      onPressed: () => controller.toggleSourceFilter(source.id),
                    ),
                ],
              ],
            );
          },
        ),
      );
    }

    return Stack(
      key: _filterAnchor,
      clipBehavior: Clip.none,
      children: [
        LensIconButton(
          key: const Key('news-filter'),
          tooltip: strings.filterBySourceAndType,
          icon: Icons.filter_list_rounded,
          focusNode: _filterButtonFocus,
          onPressed: open,
          size: 'sm',
        ),
        if (filtered)
          Positioned(
            top: 4,
            right: 4,
            child: IgnorePointer(
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: p['clay'],
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _list(LensPalette p) {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    final groups = controller.dayGroups;
    final rows = <(Object, NewsDayGroup)>[
      for (final group in groups)
        if (group.items.isNotEmpty) ...[
          (group, group),
          for (final item in group.items) (item, group),
        ],
    ];
    if (rows.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 24),
          child: controller.loadingSnapshot
              ? const SkeletonLines(rows: 4)
              : _empty(p, snapshot),
        ),
      );
    }
    return SliverList.builder(
      key: const Key('news-list'),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final (row, group) = rows[index];
        if (row is NewsDayGroup) return _dayHeader(p, row);
        final item = row as NewsItem;
        return _NewsRow(
          key: ValueKey('item-${item.id}'),
          item: item,
          first: rows[index - 1].$1 is NewsDayGroup,
          time: group.isHot
              ? _monthDay(item.firstSeenMs, context.strings)
              : _clock(item.firstSeenMs),
          sourceName: _sourceName(item.sourceId),
          alsoIn: item.alsoIn.map(_sourceName).toList(),
          opening: _opening.contains(item.id),
          onOpen: () => _open(item),
          onStar: () => controller.toggleStar(item.id),
          onRead: () => controller.setRead([item.id], !item.read),
        );
      },
    );
  }

  Widget _dayHeader(LensPalette p, NewsDayGroup group) {
    final unread = group.unreadCount;
    final count = group.items.length;
    final String title;
    if (group.isHot) {
      title = context.strings.byPopularity;
    } else {
      final date = group.date!;
      final strings = context.strings;
      final base = date.year == widget.now().year
          ? strings.calendarDayWithWeekday(date.month, date.day, date.weekday)
          : strings.calendarDayWeekdayWithYear(
              date.year,
              date.month,
              date.day,
              date.weekday,
            );
      title = group.isToday
          ? context.strings.today0(base)
          : group.isYesterday
          ? context.strings.yesterday0(base)
          : base;
    }
    final meta = context.strings.newsItemsSummary(
      count,
      unread == 0
          ? ''
          : unread == count
          ? context.strings.allUnread
          : context.strings.partiallyUnreadSuffix(unread),
    );
    final key = group.date == null
        ? 'hot'
        : '${group.date!.year}-${group.date!.month}-${group.date!.day}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 18, 8, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: LensPalette.hairline(context),
              color: p['line'],
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Wrap(
                spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: p.text(15, null, FontWeight.w600),
                    ),
                  ),
                  Text(meta, style: p.text(12, p.muted)),
                ],
              ),
            ),
            if (unread > 0)
              LensButton(
                key: Key('read-day-$key'),
                label: group.isHot
                    ? context.strings.markAllAsRead
                    : context.strings.markThisDayAsRead,
                variant: 'ghost',
                size: 'xs',
                onPressed: () => widget.controller.markDayRead(group),
              ),
          ],
        ),
      ),
    );
  }

  Widget _empty(LensPalette p, NewsSnapshot snapshot) {
    final controller = widget.controller;
    if (snapshot.refreshing && snapshot.items.isEmpty) {
      return Column(
        children: [
          EmptyState(
            title: context.strings.newsFetchProgress(
              controller.refreshDone,
              controller.refreshTotal,
            ),
            action: LensButton(
              label: context.strings.cancel,
              onPressed: controller.cancelling
                  ? null
                  : controller.cancelRefresh,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: SkeletonLines(rows: 4),
          ),
        ],
      );
    }
    final retryAt = controller.nextRetryAt;
    if (retryAt != null && snapshot.items.isEmpty) {
      return EmptyState(
        title: context.strings.retryingAt0(
          _clock(retryAt.millisecondsSinceEpoch),
        ),
        action: LensButton(
          label: context.strings.refreshNow,
          icon: Icons.refresh_rounded,
          onPressed: () => controller.refresh(),
        ),
      );
    }
    final filtered =
        controller.category != null ||
        controller.sourceIds.isNotEmpty ||
        controller.kindIds.isNotEmpty ||
        controller.query.trim().isNotEmpty;
    if (filtered) {
      return EmptyState(
        title: context.strings.noMatchingArticles,
        hint: context.strings.tryAnotherCategorySourceTypeOrSearch,
        action: LensButton(
          key: const Key('clear-filters'),
          label: context.strings.clearFilters,
          onPressed: _clearFilters,
        ),
      );
    }
    return switch (controller.view) {
      NewsView.unread => EmptyState(
        title: context.strings.allCaughtUp,
        hint: context.strings.newArticlesWillAppearAfterTheNext,
      ),
      NewsView.starred => EmptyState(
        title: context.strings.noStarredArticles,
        hint: context.strings.selectTheStarNextToAnArticle,
      ),
      NewsView.all => EmptyState(
        title: context.strings.noArticlesYet,
        hint: snapshot.sources.any((source) => source.lastSuccessMs != null)
            ? context.strings.enabledSourcesHaveNoArticlesToShow
            : context.strings.nothingIsCachedYetTheAppRefreshes,
        action: snapshot.refreshing
            ? null
            : LensButton(
                label: context.strings.refreshNow,
                icon: Icons.refresh_rounded,
                onPressed: () => controller.refresh(),
              ),
      ),
    };
  }
}

class _HotRow extends StatelessWidget {
  const _HotRow({
    super.key,
    required this.rank,
    required this.item,
    required this.onOpen,
  });

  final int rank;
  final NewsItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final metric = _metrics(context.strings)[item.popularityKind];
    final rankColor = switch (rank) {
      1 => p['clay'],
      2 => p['clay-hover'].withValues(alpha: .85),
      3 => p['clay-ink'].withValues(alpha: .7),
      _ => p.faint,
    };
    final value = _compact(item.popularity!);
    final unit = metric?.$1 ?? item.popularityKind ?? '';
    return Semantics(
      link: true,
      label: context.strings.trendingItemLabel(rank, item.title, value, unit),
      onTap: onOpen,
      excludeSemantics: true,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(8),
        hoverColor: p['fill-hover'],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '$rank',
                  textAlign: TextAlign.center,
                  style: p.text(14, rankColor, FontWeight.w700),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: p.text(13.5, null, FontWeight.w500),
                ),
              ),
              const SizedBox(width: 12),
              Tooltip(
                message: metric?.$2 ?? '',
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: value,
                        style: p.text(13, p.secondary, FontWeight.w600),
                      ),
                      TextSpan(text: ' $unit'),
                    ],
                  ),
                  style: p.text(12, p.muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewsRow extends StatefulWidget {
  const _NewsRow({
    super.key,
    required this.item,
    required this.first,
    required this.time,
    required this.sourceName,
    required this.alsoIn,
    required this.opening,
    required this.onOpen,
    required this.onStar,
    required this.onRead,
  });

  final NewsItem item;
  final bool first, opening;
  final String? time;
  final String sourceName;
  final List<String> alsoIn;
  final VoidCallback onOpen, onStar, onRead;

  @override
  State<_NewsRow> createState() => _NewsRowState();
}

class _NewsRowState extends State<_NewsRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final item = widget.item;
    final read = item.read;
    final description = item.description?.trim() ?? '';
    final metric = _metrics(context.strings)[item.popularityKind];
    final meta = p.text(12, p.muted);
    final sep = Text('·', style: p.text(12, p.faint));
    final reveal = _hovered || _focused;
    final value = [
      if (!read) context.strings.unread,
      context.strings.source0(widget.sourceName),
      if (description.isNotEmpty) description,
    ].join(context.strings.isChinese ? '，' : ', ');
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 48,
          child: Tooltip(
            message: _publishedLabel(item, context.strings),
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                widget.time ?? '--:--',
                maxLines: 1,
                softWrap: false,
                style: p.text(
                  12,
                  widget.time == null ? LensPalette.transparent : p.faint,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: p['fill-active'],
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.sourceName.characters.first.toUpperCase(),
                      style: p
                          .text(9.5, p.secondary, FontWeight.w700)
                          .copyWith(height: 1),
                    ),
                  ),
                  Text(
                    widget.sourceName,
                    style: p.text(12, p.secondary, FontWeight.w500),
                  ),
                  if (item.origin != null && item.origin!.trim().isNotEmpty)
                    Text('· ${item.origin!.split('：').first}', style: meta),
                  if (item.kind != 'general' &&
                      _kindNames(context.strings).containsKey(item.kind)) ...[
                    sep,
                    Container(
                      key: Key('item-kind-${item.kind}'),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: p['fill-active'],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _kindNames(context.strings)[item.kind]!,
                        style: p.text(11, p.secondary),
                      ),
                    ),
                  ],
                  if (item.popularity != null &&
                      item.popularityKind != null) ...[
                    sep,
                    Tooltip(
                      message: metric?.$2 ?? item.popularityKind!,
                      child: Text(
                        '${_compact(item.popularity!)} ${metric?.$1 ?? item.popularityKind}',
                        style: p.text(12, p.secondary),
                      ),
                    ),
                  ],
                  if (widget.alsoIn.isNotEmpty) ...[
                    sep,
                    Tooltip(
                      message: context.strings.alsoOn0(
                        widget.alsoIn.join(context.strings.listSeparator),
                      ),
                      child: Text(
                        context.strings.additionalNewsSources(
                          widget.alsoIn.length,
                        ),
                        style: meta.copyWith(
                          decoration: TextDecoration.underline,
                          decorationStyle: TextDecorationStyle.dotted,
                          decorationColor: p.faint,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 3),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!read) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: Container(
                        key: const Key('unread-dot'),
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: p['clay'],
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      item.title,
                      style: p
                          .text(
                            15,
                            read ? p.muted : p.ink,
                            read ? FontWeight.w500 : FontWeight.w600,
                          )
                          .copyWith(height: 1.5),
                    ),
                  ),
                ],
              ),
              if (description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        if (item.aiSummary)
                          TextSpan(
                            text: context.strings.aiSummary,
                            style: p.text(11, p['clay-ink']),
                          ),
                        TextSpan(text: description),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: p
                        .text(13, read ? p.muted : p.secondary)
                        .copyWith(height: 1.7),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (value) => setState(() => _focused = value),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.first)
              Container(
                margin: const EdgeInsets.only(left: 68, right: 8),
                height: LensPalette.hairline(context),
                color: _hovered ? LensPalette.transparent : p['line-soft'],
              ),
            AnimatedContainer(
              duration: LensTokens.fast,
              decoration: BoxDecoration(
                color: _hovered ? p['fill-hover'] : LensPalette.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Semantics(
                      link: true,
                      label: context.strings.openArticleInDefaultBrowser0(
                        item.title,
                      ),
                      value: value,
                      onTap: widget.opening ? null : widget.onOpen,
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: widget.opening ? null : widget.onOpen,
                        borderRadius: BorderRadius.circular(10),
                        hoverColor: LensPalette.transparent,
                        focusColor: p['fill-active'],
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 9, 0, 9),
                          child: content,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _RowTool(
                          key: Key('star-${item.id}'),
                          visible: reveal || item.starred,
                          tooltip: item.starred
                              ? context.strings.unstar
                              : context.strings.star,
                          icon: item.starred
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          color: item.starred ? p['clay'] : null,
                          onPressed: widget.onStar,
                        ),
                        _RowTool(
                          key: Key('read-${item.id}'),
                          visible: reveal,
                          tooltip: read
                              ? context.strings.markAsUnread
                              : context.strings.markAsRead,
                          icon: read
                              ? Icons.mark_email_unread_outlined
                              : Icons.done_rounded,
                          onPressed: widget.onRead,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowTool extends StatelessWidget {
  const _RowTool({
    super.key,
    required this.visible,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final bool visible;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : LensTokens.fast,
      child: LensIconButton(
        tooltip: tooltip,
        icon: icon,
        onPressed: onPressed,
        color: color ?? p.faint,
        size: 'xs',
      ),
    );
  }
}

class _SourcesPanel extends StatelessWidget {
  const _SourcesPanel({required this.controller, required this.now});

  final NewsController controller;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final p = LensPalette.of(context);
      final snapshot = controller.snapshot;
      final busy =
          snapshot.refreshing ||
          controller.loadingSnapshot ||
          controller.updatingSourceId != null;
      return Column(
        key: const Key('source-status-panel'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  width: LensPalette.hairline(context),
                  color: p['line-soft'],
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.strings.autoRefresh,
                        style: p.text(13, null, FontWeight.w500),
                      ),
                      Text(
                        context.strings.refreshesEvery30MinutesWhileOpenRate,
                        style: p.text(12, p.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                LensButton(
                  key: const Key('refresh-all-sources'),
                  label: snapshot.refreshing
                      ? context.strings.refreshing
                      : context.strings.refreshAll,
                  icon: Icons.refresh_rounded,
                  spinning: snapshot.refreshing,
                  onPressed: busy ? null : () => controller.refresh(),
                ),
              ],
            ),
          ),
          for (final category in SourceCategory.values)
            if (snapshot.sources.any((s) => s.category == category)) ...[
              Padding(
                key: Key('status-group-${category.name}'),
                padding: const EdgeInsets.fromLTRB(6, 14, 6, 4),
                child: Semantics(
                  header: true,
                  child: Text(
                    _categoryName(category, context.strings),
                    style: p.text(12, p.muted, FontWeight.w500),
                  ),
                ),
              ),
              for (final source in snapshot.sources.where(
                (s) => s.category == category,
              ))
                _SourceRow(
                  source: source,
                  status: _sourceStatus(source, now(), context.strings),
                  busy: busy,
                  onRefresh: () => controller.refresh(sourceIds: [source.id]),
                  onToggle: (value) =>
                      controller.setSourceEnabled(source.id, value),
                ),
            ],
          if (snapshot.sources.any((source) => source.id == 'aihot'))
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 14, 6, 0),
              child: Text(
                context.strings.aihotPicksComeFromThePublicRss,
                style: p.text(12, p.muted),
              ),
            ),
        ],
      );
    },
  );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.status,
    required this.busy,
    required this.onRefresh,
    required this.onToggle,
  });

  final NewsSource source;
  final String status;
  final bool busy;
  final VoidCallback onRefresh;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final off = !source.enabled;
    final failed = source.enabled && source.error != null;
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p['fill-active'],
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              source.name.characters.first.toUpperCase(),
              style: p
                  .text(10, p.secondary, FontWeight.w700)
                  .copyWith(height: 1),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(source.name, style: p.text(13, off ? p.faint : p.ink)),
                if (source.id == 'aihot')
                  LensBadge(context.strings.aiSummary2, tone: 'clay'),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Tooltip(
              message: failed ? _errorCopy(source.error!, context.strings) : '',
              child: Text(
                status,
                key: Key('source-status-${source.id}'),
                textAlign: TextAlign.right,
                style: p.text(
                  12,
                  off
                      ? p.faint
                      : failed
                      ? p['danger']
                      : p.muted,
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          Builder(
            builder: (anchor) => LensIconButton(
              key: Key('source-row-${source.id}'),
              tooltip: context.strings.moreActionsFor0(source.name),
              icon: Icons.more_horiz_rounded,
              size: 'xs',
              onPressed: () async {
                final strings = context.strings;
                final action = await LensMenu.show<bool>(
                  context,
                  anchor: anchor,
                  alignRight: true,
                  width: 296,
                  builder: (context) => LensMenu(
                    rowHeight: 42,
                    entries: [
                      LensMenuEntry(
                        Text(
                          source.lastSuccessMs == null
                              ? strings.noSuccessfulRefreshYet
                              : strings.lastSuccessfulRefresh0(
                                  _fullTime(source.lastSuccessMs!, strings),
                                ),
                          style: p.text(12, p.muted),
                        ),
                      ),
                      if (source.error != null)
                        LensMenuEntry(
                          Text(
                            _errorCopy(source.error!, strings),
                            key: Key('error-${source.id}'),
                            style: p.text(12, p['danger']),
                          ),
                        ),
                      LensMenuEntry(
                        key: Key('refresh-${source.id}'),
                        Text(strings.refreshThisSource, style: p.text(13)),
                        onPressed: source.enabled && !busy
                            ? () => Navigator.pop(context, true)
                            : null,
                      ),
                    ],
                  ),
                );
                if (context.mounted && action == true) onRefresh();
              },
            ),
          ),
          const SizedBox(width: 4),
          LensSwitch(
            key: Key('enabled-${source.id}'),
            label:
                '${source.enabled ? context.strings.disable : context.strings.enable} ${source.name}',
            value: source.enabled,
            onChanged: busy ? null : onToggle,
          ),
        ],
      ),
    );
  }
}

String _categoryName(SourceCategory category, AppStrings strings) =>
    switch (category) {
      SourceCategory.official => strings.official,
      SourceCategory.tools => strings.toolUpdates,
      SourceCategory.community => strings.community,
      SourceCategory.chinese => strings.chinese,
    };

String _compact(int value) => value >= 10000
    ? '${(value / 1000).toStringAsFixed(0)}k'
    : value >= 1000
    ? '${(value / 1000).toStringAsFixed(1)}k'
    : '$value';

String _two(int value) => value.toString().padLeft(2, '0');

DateTime? _local(int milliseconds) {
  try {
    return DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  } on RangeError {
    return null;
  }
}

String? _clock(int milliseconds) {
  final date = _local(milliseconds);
  return date == null ? null : '${_two(date.hour)}:${_two(date.minute)}';
}

String? _monthDay(int milliseconds, AppStrings strings) {
  final date = _local(milliseconds);
  return date == null
      ? null
      : strings.isChinese
      ? '${_two(date.month)}/${_two(date.day)}'
      : strings.calendarDay(date.month, date.day);
}

String _fullTime(int milliseconds, AppStrings strings) {
  final date = _local(milliseconds);
  return date == null
      ? strings.timeUnavailable
      : '${strings.isChinese ? '${date.year}-${_two(date.month)}-${_two(date.day)}' : strings.calendarDayWithYear(date.year, date.month, date.day)} ${_two(date.hour)}:${_two(date.minute)}';
}

String _refreshTime(int milliseconds, DateTime now, AppStrings strings) {
  final date = _local(milliseconds);
  if (date == null) return strings.timeUnavailable;
  final clock = '${_two(date.hour)}:${_two(date.minute)}';
  final today = now.toLocal();
  return date.year == today.year &&
          date.month == today.month &&
          date.day == today.day
      ? clock
      : '${strings.calendarDay(date.month, date.day)} $clock';
}

String _publishedLabel(NewsItem item, AppStrings strings) {
  final date = DateTime.tryParse(item.publishedAt ?? '');
  if (date == null) return strings.theSourceDidNotProvideAPublication;
  if (_dateOnlySources.contains(item.sourceId)) {
    final utc = date.toUtc();
    return strings.publishedOn0(
      strings.isChinese
          ? utc.toIso8601String().split('T').first
          : strings.calendarDayWithYear(utc.year, utc.month, utc.day),
    );
  }
  return strings.publishedAt0(_fullTime(date.millisecondsSinceEpoch, strings));
}

String _ago(int milliseconds, DateTime now, AppStrings strings) {
  final minutes = now
      .difference(DateTime.fromMillisecondsSinceEpoch(milliseconds))
      .inMinutes;
  if (minutes < 1) return strings.justNow;
  if (minutes < 60) return strings.minutesAgo(minutes);
  if (minutes < 1440) return strings.hoursAgo((minutes / 60).round());
  return strings.daysAgo((minutes / 1440).round());
}

String _sourceStatus(NewsSource source, DateTime now, AppStrings strings) {
  if (!source.enabled) return strings.disabled;
  if (source.refreshing) return strings.refreshing2;
  final last =
      source.lastSuccessMs == null || _local(source.lastSuccessMs!) == null
      ? null
      : _ago(source.lastSuccessMs!, now, strings);
  if (source.error != null) {
    final label = switch (source.error!.kind) {
      'rate_limited' => strings.rateLimited,
      'network' => strings.offline,
      'timeout' => strings.timedOut,
      'parse' => strings.couldNotParse,
      'too_large' => strings.responseTooLarge,
      'content_type' => strings.unsupportedFormat,
      'cancelled' => strings.canceled,
      _ => strings.didNotUpdate,
    };
    return last == null
        ? label
        : strings.sourceStatusWithLastRefresh(label, last);
  }
  if (source.lastSuccessMs == null) return strings.neverRefreshed;
  return last ?? strings.timeUnavailable;
}

String _errorCopy(NewsError error, AppStrings strings) => switch (error.kind) {
  'network' => strings.couldNotReachTheSourceCheckYour,
  'timeout' => strings.theSourceTimedOutTryAgainShortly,
  'rate_limited' => strings.theSourceIsRateLimitingRequestsIt,
  'http' => strings.theSourceIsUnavailableTryAgainShortly,
  'parse' => strings.couldNotParseThisSourceCachedArticles,
  'too_large' => strings.theResponseExceededTheSizeLimitCached,
  'content_type' => strings.theSourceReturnedAnUnsupportedFormatCached,
  'cache' => strings.theLocalCacheIsUnavailableTryRefreshing,
  'busy' => strings.aRefreshIsAlreadyRunningWaitFor,
  'closed' => strings.aiNewsIsClosedReopenTheWindow,
  'cancelled' => strings.cachedArticlesAreStillAvailableYouCan,
  'cancel' => strings.couldNotCancelWaitForTheCurrent,
  _ => strings.refreshFailedTryAgainShortly,
};
