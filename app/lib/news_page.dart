import 'package:flutter/material.dart';

import 'news_controller.dart';
import 'news_gateway.dart';

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
                  constraints.maxWidth >= 1000 &&
                  constraints.maxHeight >= 550 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 21;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (wide) _sidebar(colors),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(wide ? 36 : 24),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1220),
                          child: _content(colors, wide),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _sidebar(_NewsColors colors) => Container(
    width: 218,
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
    decoration: BoxDecoration(
      color: colors.base,
      border: Border(right: BorderSide(color: colors.line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _brand(colors),
        const SizedBox(height: 40),
        Text('工作台', style: _small(colors)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: colors.hover,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(Icons.rss_feed_rounded, size: 18, color: colors.accent),
              const SizedBox(width: 10),
              Text(
                'AI 动态',
                style: TextStyle(
                  color: colors.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Divider(color: colors.line),
        const SizedBox(height: 12),
        Text('用量统计', style: TextStyle(color: colors.secondary, fontSize: 13)),
        const SizedBox(height: 6),
        Text('请使用原版查看统计', style: _small(colors)),
        const Spacer(),
        Divider(color: colors.line),
        const SizedBox(height: 14),
        Row(
          children: [
            Icon(Icons.shield_outlined, size: 15, color: colors.secondary),
            const SizedBox(width: 7),
            Text('本地优先', style: _small(colors)),
          ],
        ),
        const SizedBox(height: 8),
        Text('仅在手动刷新时连接 OpenAI', style: _small(colors)),
      ],
    ),
  );

  Widget _brand(_NewsColors colors) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      CustomPaint(size: const Size(28, 28), painter: _LensMark(colors.accent)),
      const SizedBox(width: 9),
      Flexible(
        child: Text(
          'Token Lens',
          style: TextStyle(
            color: colors.ink,
            fontSize: 19,
            fontWeight: FontWeight.w600,
            letterSpacing: -.5,
          ),
        ),
      ),
    ],
  );

  Widget _content(_NewsColors colors, bool wide) {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!wide) ...[_brand(colors), const SizedBox(height: 24)],
        LayoutBuilder(
          builder: (context, constraints) {
            final largeText = MediaQuery.textScalerOf(context).scale(14) > 21;
            final title = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        'AI 动态',
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.7,
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
              onPressed: snapshot.refreshing || controller.loadingSnapshot
                  ? null
                  : controller.refresh,
              style: FilledButton.styleFrom(
                backgroundColor: colors.ink,
                foregroundColor: colors.page,
                disabledBackgroundColor: colors.hover,
                disabledForegroundColor: colors.secondary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
              ),
              icon: snapshot.refreshing
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: colors.secondary,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded, size: 17),
              label: Text(snapshot.refreshing ? '正在刷新' : '手动刷新'),
            );
            return largeText || constraints.maxWidth < 500
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [title, const SizedBox(height: 16), refresh],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: title),
                      const SizedBox(width: 18),
                      refresh,
                    ],
                  );
          },
        ),
        const SizedBox(height: 14),
        Text(
          snapshot.lastSuccessMs == null
              ? '尚无成功刷新记录'
              : '上次成功刷新：${_formatTime(snapshot.lastSuccessMs!)}',
          style: _small(colors),
        ),
        const SizedBox(height: 22),
        _panel(
          colors,
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: colors.wash,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.rss_feed_rounded,
                  color: colors.accent,
                  size: 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'OpenAI 官方动态',
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '手动刷新 RSS；标题与摘要来自来源，原文在浏览器中打开。',
                      style: _small(colors),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        if (controller.loadingSnapshot) ...[
          Semantics(
            liveRegion: true,
            child: Text('正在读取本地缓存…', style: TextStyle(color: colors.secondary)),
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            color: colors.accent,
            backgroundColor: colors.hover,
          ),
          const SizedBox(height: 18),
        ],
        if (snapshot.refreshing) ...[
          _notice(
            colors,
            Icons.sync_rounded,
            controller.cancelling ? '正在取消刷新…' : '正在刷新 OpenAI…',
            '现有内容保留供继续阅读。',
            action: TextButton(
              onPressed: controller.cancelling
                  ? null
                  : controller.cancelRefresh,
              child: Text(controller.cancelling ? '正在取消' : '取消刷新'),
            ),
          ),
          const SizedBox(height: 16),
        ] else if (snapshot.error != null) ...[
          _notice(
            colors,
            snapshot.error!.kind == 'cancelled'
                ? Icons.info_outline
                : Icons.wifi_off_rounded,
            snapshot.error!.kind == 'cancelled'
                ? '刷新已取消'
                : snapshot.items.isNotEmpty
                ? '刷新失败 · 正在查看离线缓存'
                : '暂时无法获取动态',
            _errorCopy(snapshot.error!),
          ),
          const SizedBox(height: 16),
        ],
        Row(
          children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  '${snapshot.items.length} 条动态${snapshot.items.isNotEmpty ? ' · 本地缓存' : ''}',
                  style: TextStyle(color: colors.secondary, fontSize: 12),
                ),
              ),
            ),
            _viewButton(
              colors,
              '信息流布局',
              Icons.view_list_outlined,
              !_cards,
              () => setState(() => _cards = false),
            ),
            const SizedBox(width: 3),
            _viewButton(
              colors,
              '卡片布局',
              Icons.grid_view_rounded,
              _cards,
              () => setState(() => _cards = true),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (snapshot.items.isEmpty && !controller.loadingSnapshot)
          _empty(colors, snapshot.lastSuccessMs != null)
        else if (snapshot.items.isNotEmpty)
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
                        for (final item in snapshot.items)
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
                            index < snapshot.items.length;
                            index++
                          ) ...[
                            if (index > 0)
                              Divider(height: 1, color: colors.line),
                            _article(snapshot.items[index], colors, false),
                          ],
                        ],
                      ),
                    );
            },
          ),
        const SizedBox(height: 22),
        Text('当前仅预览 OpenAI RSS。用量统计尚未迁移；此页不读取真实账本。', style: _small(colors)),
        const SizedBox(height: 6),
        Text('无自动刷新。外部页面仅在点击原文后打开。', style: _small(colors)),
      ],
    );
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
                'OpenAI',
                style: TextStyle(
                  color: colors.secondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '发布日期：${_publishedTime(item.publishedAt)}',
                style: _small(colors),
              ),
            ],
          ),
          const SizedBox(height: 10),
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
                  : '本地暂无缓存。点击「手动刷新」获取 OpenAI 官方动态。',
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
    'network' => '无法连接 OpenAI，请检查网络后手动重试。',
    'timeout' => '连接 OpenAI 超时，请稍后手动重试。',
    'rate_limited' => 'OpenAI 暂时限制请求，请稍后手动重试。',
    'parse' => '来源内容无法解析，本次未更新缓存。',
    'cache' => '本地缓存暂不可用，可尝试手动刷新。',
    'busy' => '已有刷新正在进行，请等待完成。',
    'closed' => '预览已关闭，请重新打开窗口。',
    'cancelled' => '已有内容保留，可随时再次手动刷新。',
    'cancel' => '取消请求失败，请等待当前刷新结束。',
    _ => '刷新失败，请稍后手动重试。',
  };

  String _publishedTime(String? value) {
    final date = value == null ? null : DateTime.tryParse(value);
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

class _LensMark extends CustomPainter {
  const _LensMark(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width / 2 - 2,
      paint,
    );
    paint.style = PaintingStyle.fill;
    for (var index = 0; index < 3; index++) {
      final height = 6.0 + index * 4;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(7 + index * 5, 21 - height, 3, height),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LensMark oldDelegate) => color != oldDelegate.color;
}
