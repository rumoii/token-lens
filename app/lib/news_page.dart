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

const _kindNames = {
  'release': '版本',
  'api': 'API',
  'deprecation': '弃用',
  'pricing': '价格',
  'model': '模型',
  'general': '常规（无标签）',
};

const _metrics = {
  'points': ('票', 'Hacker News 票数'),
  'stars': ('星', 'GitHub 星数'),
  'likes': ('赞', 'Hugging Face 点赞'),
  'upvotes': ('赞', 'Hugging Face 论文点赞'),
};

// These sources publish a calendar day without a time of day.
const _dateOnlySources = {'openai-api', 'anthropic-api', 'aibase'};

const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

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
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('无法打开原文，请检查默认浏览器设置。')));
  }

  Future<void> _manageSources() async {
    await showLensPanel(
      context,
      label: '管理来源',
      title: '管理来源',
      hint: '启停来源、查看每个来源的刷新状态',
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
            'AI 热点',
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
          label: '管理来源',
          icon: Icons.tune_rounded,
          focusNode: _manageFocus,
          onPressed: _manageSources,
        ),
        const SizedBox(width: 8),
        snapshot.refreshing
            ? LensButton(
                key: const Key('refresh-news'),
                label: controller.cancelling ? '正在取消' : '取消刷新',
                icon: Icons.refresh_rounded,
                spinning: true,
                onPressed: controller.cancelling
                    ? null
                    : controller.cancelRefresh,
              )
            : _IconAction(
                key: const Key('refresh-news'),
                tooltip: '立即刷新',
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
          ? '正在取消刷新…'
          : '正在刷新 · 已完成 ${controller.refreshDone}/${controller.refreshTotal} 个来源';
      dot = p['clay'];
    } else {
      final last = controller.lastRefreshMs;
      final when = last == null
          ? '还没刷新过'
          : '${_refreshTime(last, widget.now())} 刷新';
      text = '${sources.length} 个来源 · $when · 每 30 分钟自动刷新';
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
            Semantics(
              button: true,
              child: InkWell(
                key: const Key('failed-sources'),
                onTap: _manageSources,
                borderRadius: BorderRadius.circular(4),
                child: Text(
                  '$failed 个来源没更新',
                  style: p
                      .text(13, p['warn'])
                      .copyWith(
                        decoration: TextDecoration.underline,
                        decorationColor: p['warn'],
                      ),
                ),
              ),
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
            ? ('刷新已取消', _errorCopy(snapshot.error!))
            : ('刷新失败 · 正在查看离线缓存', _errorCopy(snapshot.error!)),
      if (snapshot.stateError != null)
        ('已读和收藏暂不可用', '本机状态文件无法读取或保存，条目照常显示；这次的标记可能不会保留。'),
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
                        '当前热点',
                        style: p.text(14, null, FontWeight.w600),
                      ),
                    ),
                    Text('按该来源自带的热度', style: p.text(12, p.faint)),
                  ],
                ),
                ScrollFade(
                  child: LensSegmented(
                    label: '热点来源',
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
          _Chip(
            key: Key('category-${category?.name ?? 'all'}'),
            label: category == null ? '全部' : _categoryName(category),
            count: controller.categoryCount(category),
            selected: controller.category == category,
            onTap: () => controller.setCategory(category),
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
          label: '范围',
          small: true,
          options: {
            'all': '全部',
            'unread': unread == 0 ? '未读' : '未读 $unread',
            'starred': starred == 0 ? '收藏' : '收藏 $starred',
          },
          value: controller.view.name,
          onChanged: (value) =>
              controller.setView(NewsView.values.byName(value)),
        ),
        if (controller.hotSortAvailable)
          LensSegmented(
            key: const Key('news-sort'),
            label: '排序',
            small: true,
            options: const {'latest': '最新', 'hot': '热度'},
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
                    label: '来源',
                    value: _sourceName(id),
                    onRemove: () => controller.toggleSourceFilter(id),
                  ),
                for (final kind in controller.kindIds)
                  FilterTag(
                    key: Key('filter-tag-kind-$kind'),
                    label: '类型',
                    value: _kindNames[kind] ?? kind,
                    onRemove: () => controller.toggleKindFilter(kind),
                  ),
                LensButton(
                  label: '清除筛选',
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
    width: 200,
    child: TextField(
      key: const Key('news-search'),
      controller: _search,
      focusNode: _searchFocus,
      onChanged: widget.controller.setQuery,
      style: p.text(12.5),
      cursorColor: p['clay'],
      decoration: InputDecoration(
        hintText: '搜索标题和摘要',
        hintStyle: p.text(12.5, p.muted),
        isDense: true,
        filled: true,
        fillColor: (p.dark ? Colors.white : Colors.black).withValues(
          alpha: p.dark ? .08 : .06,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 7),
        prefixIcon: Icon(Icons.search_rounded, size: 15, color: p.muted),
        prefixIconConstraints: const BoxConstraints(minWidth: 32),
        suffixIcon: _search.text.isEmpty
            ? ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text('/', style: p.text(12, p.faint)),
                ),
              )
            : IconButton(
                tooltip: '清除搜索',
                padding: EdgeInsets.zero,
                iconSize: 14,
                onPressed: () {
                  _search.clear();
                  widget.controller.setQuery('');
                },
                icon: Icon(Icons.close_rounded, color: p.muted),
              ),
        suffixIconConstraints: const BoxConstraints(minWidth: 28),
        border: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: BorderRadius.circular(999),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: p['clay'], width: 1.5),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    ),
  );

  Widget _filterMenu(LensPalette p, bool filtered) {
    final controller = widget.controller;
    final counts = <String, int>{};
    for (final item in controller.snapshot.items) {
      for (final id in {item.sourceId, ...item.alsoIn}) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    final itemStyle = MenuItemButton.styleFrom(
      foregroundColor: p.ink,
      minimumSize: const Size(0, 34),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      textStyle: p.text(13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
    Widget group(String key, String label) => Padding(
      key: Key(key),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      child: Text(label, style: p.text(12, p.muted, FontWeight.w500)),
    );
    return CheckboxTheme(
      data: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.ink
              : LensPalette.transparent,
        ),
        checkColor: WidgetStatePropertyAll(p['surface-1']),
        side: BorderSide(color: p['line-strong'], width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      child: MenuAnchor(
        childFocusNode: _filterButtonFocus,
        crossAxisUnconstrained: false,
        alignmentOffset: const Offset(0, 6),
        onClose: () {
          if (mounted) _filterButtonFocus.requestFocus();
        },
        style: MenuStyle(
          elevation: const WidgetStatePropertyAll(8),
          shadowColor: WidgetStatePropertyAll(
            Colors.black.withValues(alpha: p.dark ? .6 : .2),
          ),
          backgroundColor: WidgetStatePropertyAll(p['surface-3']),
          surfaceTintColor: const WidgetStatePropertyAll(
            LensPalette.transparent,
          ),
          minimumSize: const WidgetStatePropertyAll(Size(260, 0)),
          maximumSize: const WidgetStatePropertyAll(Size(320, 480)),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: p['line']),
            ),
          ),
        ),
        menuChildren: [
          group('filter-group-kind', '类型'),
          for (final kind in _kindNames.keys)
            CheckboxMenuButton(
              key: Key('kind-filter-$kind'),
              value: controller.kindIds.contains(kind),
              closeOnActivate: false,
              style: itemStyle,
              onChanged: (_) => controller.toggleKindFilter(kind),
              child: Text(_kindNames[kind]!),
            ),
          for (final category in SourceCategory.values) ...[
            group('filter-group-${category.name}', _categoryName(category)),
            for (final source in controller.snapshot.sources.where(
              (source) => source.category == category && source.enabled,
            ))
              CheckboxMenuButton(
                key: Key('filter-${source.id}'),
                value: controller.sourceIds.contains(source.id),
                closeOnActivate: false,
                style: itemStyle,
                trailingIcon: Text(
                  '${counts[source.id] ?? 0}',
                  style: p.text(12, p.faint),
                ),
                onChanged: (_) => controller.toggleSourceFilter(source.id),
                child: Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ],
        builder: (context, menu, child) => Stack(
          clipBehavior: Clip.none,
          children: [
            _IconAction(
              key: const Key('news-filter'),
              tooltip: '按来源和类型筛选',
              icon: Icons.filter_list_rounded,
              focusNode: _filterButtonFocus,
              ghost: true,
              onPressed: () => menu.isOpen ? menu.close() : menu.open(),
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
        ),
      ),
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
              ? _monthDay(item.firstSeenMs)
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
      title = '按热度';
    } else {
      final date = group.date!;
      final year = date.year == widget.now().year ? '' : '${date.year}年';
      final base =
          '$year${date.month}月${date.day}日 周${_weekdays[date.weekday - 1]}';
      title = group.isToday
          ? '今天 · $base'
          : group.isYesterday
          ? '昨天 · $base'
          : base;
    }
    final meta =
        '$count 条${unread == 0
            ? ''
            : unread == count
            ? '，全部未读'
            : '，$unread 条未读'}';
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
                label: group.isHot ? '全部标为已读' : '本日标为已读',
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
            title:
                '正在获取动态 · 已完成 ${controller.refreshDone}/${controller.refreshTotal} 个来源',
            action: LensButton(
              label: '取消',
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
        title: '将在 ${_clock(retryAt.millisecondsSinceEpoch)} 自动重试',
        action: LensButton(
          label: '立即刷新',
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
        title: '没有符合条件的动态',
        hint: '试试其他分类、来源、类型或关键词。',
        action: LensButton(
          key: const Key('clear-filters'),
          label: '清除筛选',
          onPressed: _clearFilters,
        ),
      );
    }
    return switch (controller.view) {
      NewsView.unread => const EmptyState(
        title: '都读完了',
        hint: '新动态会在下次刷新后出现在这里。',
      ),
      NewsView.starred => const EmptyState(
        title: '还没有收藏',
        hint: '在条目右侧点星标收藏；来源不再列出它以后，收藏也会保留。',
      ),
      NewsView.all => EmptyState(
        title: '还没有动态',
        hint: snapshot.sources.any((source) => source.lastSuccessMs != null)
            ? '已启用的来源暂时没有可显示的动态，程序会每 30 分钟自动刷新。'
            : '本地还没有缓存。程序开着时每 30 分钟自动刷新，也可以现在刷新。',
        action: snapshot.refreshing
            ? null
            : LensButton(
                label: '立即刷新',
                icon: Icons.refresh_rounded,
                onPressed: () => controller.refresh(),
              ),
      ),
    };
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.focusNode,
    this.ghost = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        enabled: onPressed != null,
        excludeSemantics: true,
        child: LensPressFeedback(
          builder: (states) => TextButton(
            statesController: states,
            focusNode: focusNode,
            onPressed: onPressed,
            style: ButtonStyle(
              fixedSize: const WidgetStatePropertyAll(Size(32, 32)),
              minimumSize: const WidgetStatePropertyAll(Size(32, 32)),
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.hovered)
                    ? p['fill-active']
                    : ghost
                    ? LensPalette.transparent
                    : p['fill-hover'],
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? p.faint
                    : p.secondary,
              ),
              overlayColor: WidgetStatePropertyAll(p['fill-hover']),
            ),
            child: Icon(icon, size: 16),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final color = selected ? p['surface-1'] : p.secondary;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? p.ink : LensPalette.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          hoverColor: p['fill-hover'],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: p.text(
                    13,
                    color,
                    selected ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: p.text(11.5, color.withValues(alpha: .6)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
    final metric = _metrics[item.popularityKind];
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
      label: '热点第 $rank 名：${item.title}，$value $unit',
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
    final metric = _metrics[item.popularityKind];
    final meta = p.text(12, p.muted);
    final sep = Text('·', style: p.text(12, p.faint));
    final reveal = _hovered || _focused;
    final value = [
      if (!read) '未读',
      '来源 ${widget.sourceName}',
      if (description.isNotEmpty) description,
    ].join('，');
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 48,
          child: Tooltip(
            message: _publishedLabel(item),
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
                      _kindNames.containsKey(item.kind)) ...[
                    sep,
                    Container(
                      key: Key('item-kind-${item.kind}'),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: p['fill-active'],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _kindNames[item.kind]!,
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
                      message: '也见于 ${widget.alsoIn.join('、')}',
                      child: Text(
                        '另有 ${widget.alsoIn.length} 个来源',
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
                            text: 'AI 摘要  ',
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
                      label: '在默认浏览器中打开原文：${item.title}',
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
                          tooltip: item.starred ? '取消收藏' : '收藏',
                          icon: item.starred
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          color: item.starred ? p['clay'] : null,
                          onPressed: widget.onStar,
                        ),
                        _RowTool(
                          key: Key('read-${item.id}'),
                          visible: reveal,
                          tooltip: read ? '标为未读' : '标为已读',
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
      duration: LensTokens.fast,
      child: SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          iconSize: 16,
          onPressed: onPressed,
          style: IconButton.styleFrom(
            foregroundColor: color ?? p.faint,
            hoverColor: p['fill-active'],
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          icon: Icon(icon),
        ),
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
                      Text('自动刷新', style: p.text(13, null, FontWeight.w500)),
                      Text(
                        '程序开着时每 30 分钟刷新一次；被限流就跳过下一轮。',
                        style: p.text(12, p.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                LensButton(
                  key: const Key('refresh-all-sources'),
                  label: snapshot.refreshing ? '正在刷新' : '全部刷新',
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
                    _categoryName(category),
                    style: p.text(12, p.muted, FontWeight.w500),
                  ),
                ),
              ),
              for (final source in snapshot.sources.where(
                (s) => s.category == category,
              ))
                _SourceRow(
                  source: source,
                  status: _sourceStatus(source, now()),
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
                'AIHOT 精选来自 aihot.news 的公开 RSS，标题和摘要由它的模型生成；原文链接指向原始出处。',
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
                  const LensBadge('AI 摘要', tone: 'clay'),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Tooltip(
              message: failed ? _errorCopy(source.error!) : '',
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
          PopupMenuButton<String>(
            key: Key('source-row-${source.id}'),
            tooltip: '${source.name} 的更多操作',
            color: p['surface-3'],
            surfaceTintColor: LensPalette.transparent,
            position: PopupMenuPosition.under,
            iconSize: 16,
            icon: Icon(Icons.more_horiz_rounded, color: p.muted),
            style: IconButton.styleFrom(
              minimumSize: const Size(28, 28),
              fixedSize: const Size(28, 28),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelected: (action) {
              if (action == 'refresh') onRefresh();
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                enabled: false,
                child: Text(
                  source.lastSuccessMs == null
                      ? '尚无成功刷新记录'
                      : '上次成功：${_fullTime(source.lastSuccessMs!)}',
                  style: p.text(12, p.muted),
                ),
              ),
              if (source.error != null)
                PopupMenuItem<String>(
                  enabled: false,
                  child: Text(
                    _errorCopy(source.error!),
                    key: Key('error-${source.id}'),
                    style: p.text(12, p['danger']),
                  ),
                ),
              PopupMenuItem<String>(
                key: Key('refresh-${source.id}'),
                value: 'refresh',
                enabled: source.enabled && !busy,
                child: Text(
                  '刷新此来源',
                  style: p.text(13, source.enabled && !busy ? p.ink : p.faint),
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
          Semantics(
            label: '${source.enabled ? '停用' : '启用'} ${source.name}',
            child: SizedBox(
              width: 36,
              height: 22,
              child: FittedBox(
                child: Switch(
                  key: Key('enabled-${source.id}'),
                  value: source.enabled,
                  onChanged: busy ? null : onToggle,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  activeTrackColor: p['ok'],
                  inactiveTrackColor: p['line-strong'],
                  thumbColor: const WidgetStatePropertyAll(Colors.white),
                  trackOutlineColor: const WidgetStatePropertyAll(
                    LensPalette.transparent,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _categoryName(SourceCategory category) => switch (category) {
  SourceCategory.official => '官方',
  SourceCategory.tools => '工具更新',
  SourceCategory.community => '社区',
  SourceCategory.chinese => '中文',
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

String? _monthDay(int milliseconds) {
  final date = _local(milliseconds);
  return date == null ? null : '${_two(date.month)}/${_two(date.day)}';
}

String _fullTime(int milliseconds) {
  final date = _local(milliseconds);
  return date == null
      ? '时间不可用'
      : '${date.year}-${_two(date.month)}-${_two(date.day)} ${_two(date.hour)}:${_two(date.minute)}';
}

String _refreshTime(int milliseconds, DateTime now) {
  final date = _local(milliseconds);
  if (date == null) return '时间不可用';
  final clock = '${_two(date.hour)}:${_two(date.minute)}';
  final today = now.toLocal();
  return date.year == today.year &&
          date.month == today.month &&
          date.day == today.day
      ? clock
      : '${date.month}月${date.day}日 $clock';
}

String _publishedLabel(NewsItem item) {
  final date = DateTime.tryParse(item.publishedAt ?? '');
  if (date == null) return '来源未提供发布时间';
  if (_dateOnlySources.contains(item.sourceId)) {
    return '发布日期：${date.toUtc().toIso8601String().split('T').first}';
  }
  return '发布时间：${_fullTime(date.millisecondsSinceEpoch)}';
}

String _ago(int milliseconds, DateTime now) {
  final minutes = now
      .difference(DateTime.fromMillisecondsSinceEpoch(milliseconds))
      .inMinutes;
  if (minutes < 1) return '刚刚';
  if (minutes < 60) return '$minutes 分钟前';
  if (minutes < 1440) return '${(minutes / 60).round()} 小时前';
  return '${(minutes / 1440).round()} 天前';
}

String _sourceStatus(NewsSource source, DateTime now) {
  if (!source.enabled) return '已停用';
  if (source.refreshing) return '刷新中…';
  final last =
      source.lastSuccessMs == null || _local(source.lastSuccessMs!) == null
      ? null
      : _ago(source.lastSuccessMs!, now);
  if (source.error != null) {
    final label = switch (source.error!.kind) {
      'rate_limited' => '限流',
      'network' => '离线',
      'timeout' => '超时',
      'parse' => '解析失败',
      'too_large' => '响应过大',
      'content_type' => '类型不符',
      'cancelled' => '已取消',
      _ => '未更新',
    };
    return last == null ? label : '$label · 上次成功 $last';
  }
  if (source.lastSuccessMs == null) return '还没刷新过';
  return last ?? '时间不可用';
}

String _errorCopy(NewsError error) => switch (error.kind) {
  'network' => '无法连接来源，请检查网络后重试。',
  'timeout' => '连接来源超时，请稍后重试。',
  'rate_limited' => '来源暂时限制请求，下一轮自动刷新会跳过它。',
  'http' => '来源暂时无法响应，请稍后重试。',
  'parse' => '来源内容无法解析，本次未更新缓存。',
  'too_large' => '来源响应超过大小上限，本次未更新缓存。',
  'content_type' => '来源返回了不支持的内容类型，本次未更新缓存。',
  'cache' => '本地缓存暂不可用，可尝试刷新。',
  'busy' => '已有刷新正在进行，请等待完成。',
  'closed' => 'AI 热点已关闭，请重新打开窗口。',
  'cancelled' => '已有内容保留，可随时再次刷新。',
  'cancel' => '取消请求失败，请等待当前刷新结束。',
  _ => '刷新失败，请稍后重试。',
};
