import 'package:flutter/material.dart';

import 'news_controller.dart';
import 'news_gateway.dart';
import 'smooth_wheel.dart';

const _kindNames = {
  'release': '版本',
  'api': 'API',
  'deprecation': '弃用',
  'pricing': '价格',
  'model': '模型',
  'general': '常规（无标签）',
};

class NewsPage extends StatefulWidget {
  const NewsPage({super.key, required this.controller, required this.openLink});

  final NewsController controller;
  final Future<bool> Function(Uri) openLink;

  @override
  State<NewsPage> createState() => _NewsPageState();
}

class _NewsPageState extends State<NewsPage> {
  bool _cards = false;
  final Set<String> _opening = {};
  final _search = TextEditingController();
  final _scroll = SmoothWheelController();
  final _sourceMenu = MenuController();
  final _sourceButtonFocus = FocusNode();
  final _allSourcesFocus = FocusNode();
  final _kindMenu = MenuController();
  final _kindButtonFocus = FocusNode();
  final _allKindsFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.load();
  }

  @override
  void didUpdateWidget(NewsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) widget.controller.load();
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    _sourceButtonFocus.dispose();
    _allSourcesFocus.dispose();
    _kindButtonFocus.dispose();
    _allKindsFocus.dispose();
    super.dispose();
  }

  Future<void> _open(NewsItem item) async {
    if (_opening.contains(item.id)) return;
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
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('无法打开原文，请检查默认浏览器设置。')));
  }

  @override
  Widget build(BuildContext context) {
    final colors = _NewsColors(Theme.of(context).brightness == Brightness.dark);
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => Scaffold(
        backgroundColor: colors.page,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide =
                  constraints.maxWidth >= 756 &&
                  constraints.maxHeight >= 550 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 21;
              return SingleChildScrollView(
                controller: _scroll,
                padding: EdgeInsets.all(wide ? 36 : 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1220),
                    child: _content(colors, wide),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _content(_NewsColors colors, bool wide) {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final title = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        'AI 热点',
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _badge('预览', colors),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  '看见新变化，找到值得带进工作流的下一件事。',
                  style: TextStyle(
                    color: colors.secondary,
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
              ],
            );
            final refresh = FilledButton.icon(
              key: const Key('refresh-news'),
              onPressed:
                  snapshot.refreshing ||
                      controller.loadingSnapshot ||
                      controller.updatingSourceId != null
                  ? null
                  : () => controller.refresh(),
              style: FilledButton.styleFrom(
                backgroundColor: colors.ink,
                foregroundColor: colors.page,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: Text(snapshot.refreshing ? '正在刷新' : '手动刷新'),
            );
            return constraints.maxWidth >= 580 &&
                    MediaQuery.textScalerOf(context).scale(14) <= 21
                ? Row(
                    children: [
                      Expanded(child: title),
                      const SizedBox(width: 24),
                      refresh,
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [title, const SizedBox(height: 14), refresh],
                  );
          },
        ),
        const SizedBox(height: 22),
        _panel(
          colors,
          Row(
            children: [
              Icon(Icons.rss_feed_rounded, color: colors.accent, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '按来源阅读，直接抵达原文。',
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('启动只读取本地缓存；点击刷新后才连接已启用的来源。', style: _small(colors)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _feed(colors)),
              const SizedBox(width: 26),
              SizedBox(width: 260, child: _sourcePanel(colors)),
            ],
          )
        else ...[
          _feed(colors),
          const SizedBox(height: 24),
          _sourcePanel(colors),
        ],
        const SizedBox(height: 22),
        Text('无自动刷新。外部页面仅在点击原文后打开。', style: _small(colors)),
      ],
    );
  }

  Widget _feed(_NewsColors colors) {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    final items = controller.visibleItems;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _categoryTabs(colors),
        const SizedBox(height: 14),
        _filters(colors),
        const SizedBox(height: 14),
        if (controller.loadingSnapshot) ...[
          const Text('正在读取本地缓存…'),
          LinearProgressIndicator(color: colors.accent),
          const SizedBox(height: 12),
        ],
        if (snapshot.refreshing) ...[
          _notice(
            colors,
            Icons.sync_rounded,
            controller.cancelling ? '正在取消刷新…' : '正在刷新已选来源…',
            '现有内容保留供继续阅读。',
            action: TextButton(
              onPressed: controller.cancelling
                  ? null
                  : controller.cancelRefresh,
              child: Text(controller.cancelling ? '正在取消' : '取消刷新'),
            ),
          ),
          const SizedBox(height: 12),
        ] else if (snapshot.error != null) ...[
          _notice(
            colors,
            Icons.info_outline,
            snapshot.error!.kind == 'cancelled' ? '刷新已取消' : '刷新失败 · 正在查看离线缓存',
            _errorCopy(snapshot.error!),
          ),
          const SizedBox(height: 12),
        ],
        if (snapshot.sources.any(
          (source) => source.enabled && source.error != null,
        )) ...[
          Text(
            '部分来源未更新，其他内容可继续阅读。',
            style: TextStyle(color: colors.accent, fontSize: 12),
          ),
          const SizedBox(height: 10),
        ],
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Semantics(
              liveRegion: true,
              child: Text('${items.length} 条动态 · 本地缓存', style: _small(colors)),
            ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 8,
              children: [
                _sortControls(colors),
                const SizedBox(width: 8),
                _viewButton(
                  colors,
                  '信息流布局',
                  Icons.view_list_outlined,
                  !_cards,
                  () => setState(() => _cards = false),
                ),
                _viewButton(
                  colors,
                  '卡片布局',
                  Icons.grid_view_rounded,
                  _cards,
                  () => setState(() => _cards = true),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),
        Semantics(
          liveRegion: true,
          child: Text(
            controller.sortExplanation,
            key: const Key('sort-explanation'),
            style: _small(colors),
          ),
        ),
        const SizedBox(height: 12),
        if (items.isEmpty && !controller.loadingSnapshot)
          snapshot.items.isEmpty &&
                  controller.category == null &&
                  controller.sourceIds.isEmpty &&
                  controller.kindIds.isEmpty &&
                  controller.query.isEmpty
              ? _empty(
                  colors,
                  snapshot.sources.any(
                    (source) => source.lastSuccessMs != null,
                  ),
                )
              : _notice(
                  colors,
                  Icons.filter_alt_off_outlined,
                  '没有符合筛选条件的动态',
                  '试试其他分类、来源或关键词。',
                  action: TextButton(
                    key: const Key('clear-filters'),
                    onPressed: () {
                      _search.clear();
                      controller.clearFilters();
                    },
                    child: const Text('清除筛选'),
                  ),
                )
        else if (items.isNotEmpty)
          LayoutBuilder(
            builder: (context, constraints) {
              final width = _cards && constraints.maxWidth >= 680
                  ? (constraints.maxWidth - 14) / 2
                  : constraints.maxWidth;
              return _cards
                  ? Wrap(
                      key: const Key('news-cards'),
                      spacing: 14,
                      runSpacing: 14,
                      children: [
                        for (final item in items)
                          SizedBox(
                            width: width,
                            child: _article(item, colors, true),
                          ),
                      ],
                    )
                  : Container(
                      key: const Key('news-list'),
                      decoration: BoxDecoration(
                        color: colors.panel,
                        border: Border.all(color: colors.line),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (
                            var index = 0;
                            index < items.length;
                            index++
                          ) ...[
                            if (index > 0)
                              Divider(height: 1, color: colors.line),
                            _article(items[index], colors, false),
                          ],
                        ],
                      ),
                    );
            },
          ),
      ],
    );
  }

  Widget _filters(_NewsColors colors) => LayoutBuilder(
    builder: (context, constraints) {
      final search = TextField(
        key: const Key('news-search'),
        controller: _search,
        onChanged: widget.controller.setQuery,
        style: TextStyle(color: colors.ink, fontSize: 13),
        decoration: InputDecoration(
          labelText: '搜索标题和描述',
          labelStyle: TextStyle(color: colors.secondary, fontSize: 13),
          prefixIcon: Icon(Icons.search, size: 18, color: colors.secondary),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清除搜索',
                  onPressed: () {
                    _search.clear();
                    widget.controller.setQuery('');
                  },
                  icon: const Icon(Icons.close, size: 18),
                ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 14,
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: colors.line),
            borderRadius: BorderRadius.circular(7),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: colors.secondary),
            borderRadius: BorderRadius.circular(7),
          ),
        ),
      );
      final menus = Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [_sourceFilter(colors), _kindFilter(colors)],
      );
      if (constraints.maxWidth >= 560 &&
          MediaQuery.textScalerOf(context).scale(14) <= 21) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: search),
            const SizedBox(width: 8),
            menus,
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [search, const SizedBox(height: 8), menus],
      );
    },
  );

  Widget _sortControls(_NewsColors colors) {
    final controller = widget.controller;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final sort in NewsSort.values)
            Semantics(
              selected: controller.sort == sort,
              child: TextButton(
                key: Key('sort-${sort.name}'),
                onPressed: sort == NewsSort.hot && !controller.hotSortAvailable
                    ? null
                    : () => controller.setSort(sort),
                style: TextButton.styleFrom(
                  foregroundColor: colors.secondary,
                  disabledForegroundColor: colors.secondary,
                  backgroundColor: controller.sort == sort
                      ? colors.hover
                      : Colors.transparent,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  textStyle: TextStyle(
                    fontFamily: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.fontFamily,
                    fontSize: 12,
                    fontWeight: controller.sort == sort
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                child: Text(sort == NewsSort.latest ? '最新' : '热度'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _kindFilter(_NewsColors colors) {
    final controller = widget.controller;
    return CheckboxTheme(
      data: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.secondary
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(colors.panel),
        side: BorderSide(color: colors.secondary),
      ),
      child: MenuAnchor(
        controller: _kindMenu,
        childFocusNode: _kindButtonFocus,
        crossAxisUnconstrained: false,
        onOpen: _allKindsFocus.requestFocus,
        onClose: () {
          if (mounted) _kindButtonFocus.requestFocus();
        },
        style: MenuStyle(
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: WidgetStatePropertyAll(colors.panel),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          maximumSize: const WidgetStatePropertyAll(Size(300, 440)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: colors.line),
            ),
          ),
        ),
        menuChildren: [
          for (final kind in [null, ..._kindNames.keys])
            CheckboxMenuButton(
              key: Key('kind-filter-${kind ?? 'all'}'),
              focusNode: kind == null ? _allKindsFocus : null,
              value: kind == null
                  ? controller.kindIds.isEmpty
                  : controller.kindIds.contains(kind),
              closeOnActivate: false,
              onChanged: (_) => kind == null
                  ? controller.clearKindFilters()
                  : controller.toggleKindFilter(kind),
              style: MenuItemButton.styleFrom(
                foregroundColor: colors.secondary,
                minimumSize: const Size(0, 36),
                textStyle: TextStyle(
                  fontFamily: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.fontFamily,
                  fontSize: 13,
                ),
              ),
              child: Text(kind == null ? '全部类型' : _kindNames[kind]!),
            ),
        ],
        builder: (context, menu, child) => OutlinedButton(
          key: const Key('kind-filter-menu'),
          focusNode: _kindButtonFocus,
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.secondary,
            backgroundColor: colors.panel,
            side: BorderSide(color: colors.line),
            minimumSize: const Size(0, 46),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            textStyle: TextStyle(
              fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
              fontSize: 13,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                controller.kindIds.isEmpty
                    ? '全部类型'
                    : '类型（${controller.kindIds.length}）',
              ),
              const SizedBox(width: 8),
              const Icon(Icons.expand_more, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _categoryTabs(_NewsColors colors) {
    final controller = widget.controller;
    Widget tab(SourceCategory? category, String label) {
      final count = controller.categoryCount(category);
      final selected = controller.category == category;
      return Semantics(
        selected: selected,
        child: TextButton(
          key: Key('category-${category?.name ?? 'all'}'),
          onPressed: () => controller.setCategory(category),
          style: TextButton.styleFrom(
            backgroundColor: selected ? colors.hover : Colors.transparent,
            foregroundColor: selected ? colors.ink : colors.secondary,
            minimumSize: const Size(0, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            textStyle: TextStyle(
              fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label),
              const SizedBox(width: 7),
              Text(
                '$count',
                style: TextStyle(
                  color: colors.secondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Wrap(
        spacing: 2,
        runSpacing: 4,
        children: [
          tab(null, '全部'),
          for (final category in SourceCategory.values)
            tab(category, _categoryName(category)),
        ],
      ),
    );
  }

  Widget _sourceFilter(_NewsColors colors) {
    final controller = widget.controller;
    final sources = controller.snapshot.sources;
    final itemStyle = MenuItemButton.styleFrom(
      foregroundColor: colors.secondary,
      minimumSize: const Size(0, 36),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      textStyle: TextStyle(
        fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
        fontSize: 13,
      ),
    );
    return CheckboxTheme(
      data: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.secondary
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(colors.panel),
        side: BorderSide(color: colors.secondary),
      ),
      child: MenuAnchor(
        crossAxisUnconstrained: false,
        controller: _sourceMenu,
        childFocusNode: _sourceButtonFocus,
        onOpen: _allSourcesFocus.requestFocus,
        onClose: () {
          if (mounted) _sourceButtonFocus.requestFocus();
        },
        style: MenuStyle(
          elevation: const WidgetStatePropertyAll(0),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          backgroundColor: WidgetStatePropertyAll(colors.panel),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          minimumSize: const WidgetStatePropertyAll(Size(300, 0)),
          maximumSize: const WidgetStatePropertyAll(Size(340, 740)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 8),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: colors.line),
            ),
          ),
        ),
        menuChildren: [
          CheckboxMenuButton(
            key: const Key('filter-all'),
            focusNode: _allSourcesFocus,
            value: controller.sourceIds.isEmpty,
            closeOnActivate: false,
            style: itemStyle,
            onChanged: (_) {
              for (final id in controller.sourceIds) {
                controller.toggleSourceFilter(id);
              }
            },
            child: const Text('全部来源'),
          ),
          for (final category in SourceCategory.values) ...[
            Padding(
              key: Key('filter-group-${category.name}'),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Text(
                _categoryName(category),
                style: TextStyle(
                  color: colors.secondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final source in sources.where(
              (source) => source.category == category,
            ))
              CheckboxMenuButton(
                key: Key('filter-${source.id}'),
                value: controller.sourceIds.contains(source.id),
                closeOnActivate: false,
                style: itemStyle,
                onChanged: (_) => controller.toggleSourceFilter(source.id),
                child: Text(
                  '${source.name}${source.enabled ? '' : ' · 已停用'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ],
        builder: (context, menu, child) => OutlinedButton(
          key: const Key('source-filter-menu'),
          focusNode: _sourceButtonFocus,
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.secondary,
            backgroundColor: colors.panel,
            side: BorderSide(color: colors.line),
            minimumSize: const Size(0, 46),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            textStyle: TextStyle(
              fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
              fontSize: 13,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                controller.sourceIds.isEmpty
                    ? '全部来源'
                    : '来源（${controller.sourceIds.length}）',
              ),
              const SizedBox(width: 8),
              const Icon(Icons.expand_more, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sourcePanel(_NewsColors colors) {
    final sources = widget.controller.snapshot.sources;
    return Container(
      key: const Key('source-status-panel'),
      child: _panel(
        colors,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      '来源状态',
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                Text('${sources.length}', style: _small(colors)),
              ],
            ),
            const SizedBox(height: 6),
            Text('点击来源查看操作与详情', style: _small(colors)),
            for (final category in SourceCategory.values)
              if (sources.any((source) => source.category == category)) ...[
                Padding(
                  key: Key('status-group-${category.name}'),
                  padding: const EdgeInsets.only(top: 14, bottom: 5),
                  child: Text(
                    _categoryName(category),
                    style: TextStyle(
                      color: colors.secondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final source in sources.where(
                  (source) => source.category == category,
                ))
                  _sourceRow(source, colors),
              ],
          ],
        ),
      ),
    );
  }

  Widget _sourceRow(NewsSource source, _NewsColors colors) {
    final controller = widget.controller;
    final busy =
        controller.snapshot.refreshing ||
        controller.loadingSnapshot ||
        controller.updatingSourceId != null;
    return PopupMenuButton<String>(
      key: Key('source-row-${source.id}'),
      tooltip: '${source.name} 操作与详情',
      color: colors.panel,
      surfaceTintColor: Colors.transparent,
      position: PopupMenuPosition.under,
      onSelected: (action) {
        if (action == 'refresh') controller.refresh(sourceIds: [source.id]);
        if (action == 'toggle') {
          controller.setSourceEnabled(source.id, !source.enabled);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            source.name,
            style: TextStyle(
              color: colors.ink,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            source.lastSuccessMs == null
                ? '尚无成功刷新记录'
                : '上次成功：${_formatTime(source.lastSuccessMs!)}',
            style: _small(colors),
          ),
        ),
        if (source.error != null)
          PopupMenuItem<String>(
            enabled: false,
            child: Text(
              _errorCopy(source.error!),
              key: Key('error-${source.id}'),
              style: TextStyle(color: colors.accent, fontSize: 12, height: 1.6),
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          key: Key('refresh-${source.id}'),
          value: 'refresh',
          enabled: source.enabled && !busy,
          child: Text(
            '刷新此来源',
            style: TextStyle(
              color: source.enabled && !busy
                  ? colors.secondary
                  : colors.secondary.withValues(alpha: .5),
              fontSize: 13,
            ),
          ),
        ),
        PopupMenuItem<String>(
          key: Key('enabled-${source.id}'),
          value: 'toggle',
          enabled: !busy,
          child: Text(
            source.enabled ? '停用来源' : '启用来源',
            style: TextStyle(color: colors.secondary, fontSize: 13),
          ),
        ),
      ],
      child: SizedBox(
        height: (MediaQuery.textScalerOf(context).scale(13) * 1.4 + 12).clamp(
          38,
          double.infinity,
        ),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.base,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: colors.line),
              ),
              child: Text(
                source.name.characters.first.toUpperCase(),
                style: TextStyle(
                  color: colors.secondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                source.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.secondary, fontSize: 12),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _sourceStatus(source),
              style: TextStyle(
                color: source.enabled && source.error != null
                    ? colors.accent
                    : colors.secondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _sourceStatus(NewsSource source) {
    if (!source.enabled) return '已停用';
    if (source.refreshing) return '刷新中';
    if (source.error != null) {
      return switch (source.error!.kind) {
        'rate_limited' => '限流',
        'network' => '离线',
        'timeout' => '超时',
        'parse' => '解析失败',
        'too_large' => '响应过大',
        'content_type' => '类型不符',
        'cancelled' => '已取消',
        _ => '未更新',
      };
    }
    if (source.lastSuccessMs == null) return '未刷新';
    final formatted = _formatTime(source.lastSuccessMs!);
    return formatted == '时间不可用' ? formatted : formatted.substring(11, 16);
  }

  String _categoryName(SourceCategory category) => switch (category) {
    SourceCategory.official => '官方',
    SourceCategory.tools => '工具更新',
    SourceCategory.community => '社区',
    SourceCategory.chinese => '中文',
  };

  String _sourceName(String id) =>
      widget.controller.snapshot.sources
          .where((source) => source.id == id)
          .map((source) => source.name)
          .firstOrNull ??
      id;

  String _popularity(NewsItem item) {
    final value = item.popularity!;
    final number = value >= 1000
        ? '${(value / 1000).toStringAsFixed(1)}k'
        : '$value';
    return '$number ${item.popularityKind}';
  }

  Widget _article(NewsItem item, _NewsColors colors, bool card) {
    final child = Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 9,
            runSpacing: 6,
            children: [
              Text(
                _sourceName(item.sourceId),
                style: TextStyle(
                  color: colors.secondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '发布日期：${_publishedTime(item.publishedAt, dateOnly: item.sourceId == 'openai-api' || item.sourceId == 'anthropic-api' || item.sourceId == 'aibase')}',
                style: _small(colors),
              ),
              if (item.popularity != null && item.popularityKind != null)
                Text(_popularity(item), style: _small(colors)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 9,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                link: true,
                label: '在默认浏览器中打开原文：${item.title}',
                onTap: _opening.contains(item.id) ? null : () => _open(item),
                excludeSemantics: true,
                child: InkWell(
                  onTap: _opening.contains(item.id) ? null : () => _open(item),
                  borderRadius: BorderRadius.circular(4),
                  focusColor: colors.focus,
                  hoverColor: colors.hover,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      item.title,
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        height: 1.55,
                      ),
                    ),
                  ),
                ),
              ),
              if (item.kind != 'general' && _kindNames.containsKey(item.kind))
                Container(
                  key: Key('item-kind-${item.kind}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.hover,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(_kindNames[item.kind]!, style: _small(colors)),
                ),
            ],
          ),
          const SizedBox(height: 9),
          if (item.description?.trim().isNotEmpty ?? false) ...[
            Text(
              '来源摘要',
              style: TextStyle(
                color: colors.accent,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              item.description!,
              style: TextStyle(
                color: colors.secondary,
                fontSize: 13,
                height: 1.75,
              ),
            ),
          ] else
            Text(
              '来源未提供摘要。',
              style: TextStyle(
                color: colors.secondary,
                fontSize: 12,
                height: 1.7,
              ),
            ),
          if (item.alsoIn.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '也见于 ${item.alsoIn.map(_sourceName).join('、')}',
              style: _small(colors),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(Uri.tryParse(item.url)?.host ?? '', style: _small(colors)),
              TextButton.icon(
                onPressed: _opening.contains(item.id)
                    ? null
                    : () => _open(item),
                style: TextButton.styleFrom(foregroundColor: colors.secondary),
                icon: const Icon(Icons.open_in_new_rounded, size: 13),
                label: Text(
                  _opening.contains(item.id) ? '正在打开' : '打开原文',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return card ? _panel(colors, child, padding: EdgeInsets.zero) : child;
  }

  Widget _viewButton(
    _NewsColors colors,
    String label,
    IconData icon,
    bool selected,
    VoidCallback onPressed,
  ) => Semantics(
    selected: selected,
    child: Tooltip(
      message: label,
      child: IconButton(
        onPressed: onPressed,
        isSelected: selected,
        icon: Icon(icon, size: 18),
        style: IconButton.styleFrom(
          backgroundColor: selected ? colors.hover : Colors.transparent,
          foregroundColor: selected ? colors.ink : colors.secondary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    ),
  );

  Widget _empty(_NewsColors colors, bool hasRefreshed) => _panel(
    colors,
    Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Icon(Icons.article_outlined, size: 30, color: colors.secondary),
            const SizedBox(height: 14),
            Text(
              '还没有动态',
              style: TextStyle(
                color: colors.ink,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hasRefreshed
                  ? '来源暂未提供可显示的动态，可稍后手动刷新。'
                  : '本地暂无缓存。点击「手动刷新」获取已启用来源的动态。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.secondary,
                fontSize: 13,
                height: 1.8,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _notice(
    _NewsColors colors,
    IconData icon,
    String title,
    String detail, {
    Widget? action,
  }) => _panel(
    colors,
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: colors.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: TextStyle(
                    color: colors.secondary,
                    fontSize: 12,
                    height: 1.7,
                  ),
                ),
                ?action,
              ],
            ),
          ),
        ),
      ],
    ),
    background: colors.base,
  );

  Widget _panel(
    _NewsColors colors,
    Widget child, {
    EdgeInsets padding = const EdgeInsets.all(16),
    Color? background,
  }) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: background ?? colors.panel,
      border: Border.all(color: colors.line),
      borderRadius: BorderRadius.circular(10),
    ),
    child: child,
  );

  Widget _badge(String label, _NewsColors colors) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: colors.wash,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: colors.accent,
        fontSize: 11,
        fontWeight: FontWeight.w500,
      ),
    ),
  );

  TextStyle _small(_NewsColors colors) =>
      TextStyle(color: colors.secondary, fontSize: 11, height: 1.65);

  String _errorCopy(NewsError error) => switch (error.kind) {
    'network' => '无法连接来源，请检查网络后手动重试。',
    'timeout' => '连接来源超时，请稍后手动重试。',
    'rate_limited' => '来源暂时限制请求，请稍后手动重试。',
    'http' => '来源暂时无法响应，请稍后手动重试。',
    'parse' => '来源内容无法解析，本次未更新缓存。',
    'too_large' => '来源响应超过大小上限，本次未更新缓存。',
    'content_type' => '来源返回了不支持的内容类型，本次未更新缓存。',
    'cache' => '本地缓存暂不可用，可尝试手动刷新。',
    'busy' => '已有刷新正在进行，请等待完成。',
    'closed' => '预览已关闭，请重新打开窗口。',
    'cancelled' => '已有内容保留，可随时再次手动刷新。',
    'cancel' => '取消请求失败，请等待当前刷新结束。',
    _ => '刷新失败，请稍后手动重试。',
  };

  String _publishedTime(String? value, {bool dateOnly = false}) {
    final date = value == null ? null : DateTime.tryParse(value);
    if (date != null && dateOnly) {
      return date.toUtc().toIso8601String().split('T').first;
    }
    return date == null ? '未提供' : _formatTime(date.millisecondsSinceEpoch);
  }

  String _formatTime(int milliseconds) {
    DateTime date;
    try {
      date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    } on RangeError {
      return '时间不可用';
    }
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}（本地时间）';
  }
}

class _NewsColors {
  _NewsColors(bool dark)
    : page = Color(dark ? 0xff181817 : 0xfffbfbf9),
      base = Color(dark ? 0xff121211 : 0xfff5f5f3),
      panel = Color(dark ? 0xff1e1e1c : 0xffffffff),
      ink = Color(dark ? 0xffeeede9 : 0xff171716),
      secondary = Color(dark ? 0xffb3b1ab : 0xff55534e),
      line = Color(dark ? 0xff393935 : 0xffe3e2dd),
      hover = Color(dark ? 0xff292926 : 0xffeeede9),
      accent = Color(dark ? 0xffe8957a : 0xffa74b2d),
      wash = Color(dark ? 0xff2b1e19 : 0xfffbf1ec),
      focus = Color(dark ? 0xff7a4433 : 0xfff0d3c5);

  final Color page,
      base,
      panel,
      ink,
      secondary,
      line,
      hover,
      accent,
      wash,
      focus;
}
