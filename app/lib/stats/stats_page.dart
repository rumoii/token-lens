import 'dart:async';

import 'package:flutter/material.dart';

import '../smooth_wheel.dart';
import '../stats_controller.dart';
import 'logic/detail_query.dart';
import 'logic/period.dart';
import 'logic/tools.dart';
import 'theme/palette.dart';
import 'widgets/primitives.dart';
import 'home_page.dart';
import 'detail_page.dart';
import 'sessions_page.dart';
import 'widgets/motion.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key, required this.controller, this.news});
  final StatsController controller;
  final Widget? news;
  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  final scaffold = GlobalKey<ScaffoldState>();
  final _contentScroll = SmoothWheelController();
  final _sidebarScroll = SmoothWheelController();
  String page = 'home', query = '';
  static const nav = {
    'home': ('用量总览', Icons.insights_outlined),
    'detail': ('用量明细', Icons.manage_search),
    'sessions': ('会话记录', Icons.history),
    'sources': ('工具来源', Icons.build_outlined),
    'news': ('AI 热点', Icons.rss_feed_rounded),
    'settings': ('价格与设置', Icons.settings_outlined),
  };
  @override
  void dispose() {
    _contentScroll.dispose();
    _sidebarScroll.dispose();
    super.dispose();
  }

  void navigate(String target, [Map<String, String> params = const {}]) {
    scaffold.currentState?.closeDrawer();
    setState(() {
      page = target;
      query = target == 'detail'
          ? detailSearch(
              params.containsKey('period')
                  ? StatsPeriod.parse(Uri(queryParameters: params).query)
                  : widget.controller.preferences.period,
              params,
            )
          : Uri(queryParameters: params).query;
    });
  }

  Widget dot(LensPalette p) => Semantics(
    label: widget.controller.syncLabel,
    child: SyncDot(
      revision: widget.controller.ledgerVersion,
      color: widget.controller.syncFailed
          ? p['danger']
          : widget.controller.busy
          ? p.muted
          : widget.controller.syncSuccessful
          ? p['ok']
          : p.muted,
    ),
  );
  Widget sidebar(BuildContext context, {bool drawer = false}) {
    final p = LensPalette.of(context), c = widget.controller;
    final entries =
        <String, int>{
          for (final s in c.overview?.sources.sources ?? []) s.source: 0,
          for (final g in c.overview?.sidebar.groups ?? [])
            if (g.key != null) g.key!: g.grossTokens,
        }.entries.toList()..sort((a, b) {
          final delta = b.value - a.value;
          return delta != 0 ? delta : a.key.compareTo(b.key);
        });
    final total = c.overview?.sidebar.totals.grossTokens ?? 0;
    Widget navRow(
      String label,
      Widget icon,
      VoidCallback onTap, {
      bool active = false,
      Widget? trailing,
      Key? key,
    }) => Semantics(
      selected: active,
      button: true,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: active ? p['fill-hover'] : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              icon,
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: p.text(
                    14,
                    active ? p.ink : p.secondary,
                    active ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
    return Material(
      color: p['surface-0'],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: p['line'])),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const BrandMark(),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Token Lens',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: p.text(18, null, FontWeight.w600),
                  ),
                ),
                if (drawer) ...[
                  IconButton(
                    tooltip: '关闭导航菜单',
                    onPressed: () => scaffold.currentState?.closeDrawer(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 24),
            Expanded(
              child: ListView(
                controller: _sidebarScroll,
                padding: EdgeInsets.zero,
                children: [
                  Semantics(
                    label: '页面导航',
                    container: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final group in [
                          ('用量', ['home', 'detail', 'sessions', 'sources']),
                          if (widget.news != null) ('资讯', ['news']),
                          ('设置', ['settings']),
                        ]) ...[
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              12,
                              group.$1 == '用量' ? 0 : 14,
                              12,
                              6,
                            ),
                            child: Semantics(
                              container: true,
                              header: true,
                              child: Text(
                                group.$1,
                                style: p.text(12, p.muted, FontWeight.w500),
                              ),
                            ),
                          ),
                          for (final target in group.$2)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: navRow(
                                nav[target]!.$1,
                                Icon(
                                  nav[target]!.$2,
                                  size: 17,
                                  color: p.secondary,
                                ),
                                () => navigate(target),
                                active: page == target,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  if (page != 'news') ...[
                    const SizedBox(height: 20),
                    if (c.loading)
                      Text('正在读取本期用量…', style: p.text(12, p.muted)),
                    if (c.error != null ||
                        c.resourceErrors.containsKey('sources'))
                      LensButton(
                        label: '重试读取',
                        size: 'xs',
                        onPressed: () => unawaited(c.load()),
                      ),
                    if (entries.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: Text(
                          '本期工具',
                          style: p.text(12, p.muted, FontWeight.w500),
                        ),
                      ),
                      for (final entry in entries)
                        navRow(
                          toolOf(entry.key).name,
                          ToolTile(entry.key, size: 20),
                          () => navigate('detail', {
                            'tool': entry.key,
                            'dim': 'model',
                          }),
                          trailing: Text(
                            '${total > 0 ? (entry.value / total * 100).round() : 0}%',
                            style: p.text(12, p.muted),
                          ),
                        ),
                    ],
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            Divider(height: 1, color: p['line']),
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: dot(p),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(c.syncLabel, style: p.text(12, p.secondary)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                LensButton(
                  label: '同步用量',
                  spinning: c.busy,
                  icon: Icons.refresh,
                  variant: 'ghost',
                  size: 'sidebar',
                  onPressed: c.busy ? null : () => unawaited(c.sync()),
                ),
                const Spacer(),
                for (final item in [
                  ('light', '浅色', Icons.light_mode_outlined),
                  ('dark', '深色', Icons.dark_mode_outlined),
                ])
                  Semantics(
                    button: true,
                    selected: c.preferences.appearance == item.$1,
                    child: Tooltip(
                      message: '${item.$2}；长按跟随系统',
                      child: InkWell(
                        onTap: () => unawaited(
                          c.setPreferences(
                            c.preferences.copyWith(appearance: item.$1),
                          ),
                        ),
                        onLongPress: () => unawaited(
                          c.setPreferences(
                            c.preferences.copyWith(appearance: 'system'),
                          ),
                        ),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(item.$3, size: 15, color: p.secondary),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final p = LensPalette.of(context);
      final narrow = MediaQuery.sizeOf(context).width < 768;
      return Scaffold(
        key: scaffold,
        backgroundColor: p['surface-1'],
        drawer: narrow
            ? SizedBox(width: 272, child: sidebar(context, drawer: true))
            : null,
        drawerEnableOpenDragGesture: true,
        body: Row(
          children: [
            if (!narrow) SizedBox(width: 244, child: sidebar(context)),
            Expanded(
              child: Column(
                children: [
                  if (narrow)
                    Container(
                      height: 52,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: p['line'])),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: '打开导航菜单',
                            onPressed: () =>
                                scaffold.currentState!.openDrawer(),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: Icon(Icons.menu, size: 22, color: p.ink),
                          ),
                          const SizedBox(width: 12),
                          const BrandMark(),
                          const SizedBox(width: 6),
                          Text(
                            'Token Lens',
                            style: p.text(16, null, FontWeight.w600),
                          ),
                          const Spacer(),
                          dot(p),
                        ],
                      ),
                    ),
                  Expanded(
                    child: page == 'news'
                        ? widget.news!
                        : SingleChildScrollView(
                            key: const Key('stats-scroll'),
                            controller: _contentScroll,
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 1120,
                                ),
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    narrow ? 14 : 36,
                                    narrow ? 18 : 28,
                                    narrow ? 14 : 36,
                                    24,
                                  ),
                                  child: page == 'home'
                                      ? StatsHome(
                                          controller: widget.controller,
                                          onDetail: (p) =>
                                              navigate('detail', p),
                                          onSessions: (p) =>
                                              navigate('sessions', p),
                                          onSources: () => navigate('sources'),
                                        )
                                      : page == 'detail'
                                      ? StatsDetail(
                                          controller: widget.controller,
                                          query: query,
                                          onQuery: (value) =>
                                              setState(() => query = value),
                                          onHome: () {
                                            final period = StatsPeriod.parse(
                                              query,
                                            );
                                            navigate('home');
                                            unawaited(
                                              widget.controller.setPeriod(
                                                period,
                                              ),
                                            );
                                          },
                                          onSettings: () =>
                                              navigate('settings'),
                                        )
                                      : page == 'sessions'
                                      ? StatsSessionsPage(
                                          controller: widget.controller,
                                          query: query,
                                          onQuery: (value) =>
                                              setState(() => query = value),
                                          onDetail: (params) =>
                                              navigate('detail', params),
                                        )
                                      : Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              nav[page]!.$1,
                                              style: p.serif(30),
                                            ),
                                            const SizedBox(height: 18),
                                            const Text('这一页还在迁移'),
                                            if (query.isNotEmpty) ...[
                                              const SizedBox(height: 16),
                                              SelectableText(
                                                query,
                                                key: const Key('detail-query'),
                                                style: p.text(13, p.secondary),
                                              ),
                                            ],
                                          ],
                                        ),
                                ),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
