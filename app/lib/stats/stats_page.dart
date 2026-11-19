import '../l10n/app_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../smooth_wheel.dart';
import '../stats_controller.dart';
import 'logic/detail_query.dart';
import 'logic/period.dart';
import 'logic/format.dart';
import 'logic/tools.dart';
import 'theme/palette.dart';
import 'widgets/primitives.dart';
import 'home_page.dart';
import 'detail_page.dart';
import 'sessions_page.dart';
import 'sources_page.dart';
import 'settings_page.dart';
import 'onboarding_page.dart';
import 'widgets/motion.dart';
import '../update/update_widgets.dart';

const _sidebarWidth = 244.0;

class StatsPage extends StatefulWidget {
  const StatsPage({
    super.key,
    required this.controller,
    this.news,
    this.openLink,
    this.newsListenable,
    this.newsUnread,
  });
  final StatsController controller;
  final Widget? news;
  final Future<bool> Function(Uri)? openLink;
  final Listenable? newsListenable;
  final int Function()? newsUnread;
  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  final _drawerFocus = FocusScopeNode(
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  final scaffold = GlobalKey<ScaffoldState>();
  final _contentScroll = SmoothWheelController();
  final _sidebarScroll = SmoothWheelController();
  final _updateCard = GlobalKey();
  String page = 'home', query = '';
  Map<String, String> _sessionQuery = {};
  bool get newsVisible =>
      widget.news != null && widget.controller.preferences.newsEnabled;
  Map<String, (String, IconData)> get nav {
    final strings = context.strings;
    return {
      'home': (strings.usageOverview, Icons.insights_outlined),
      'detail': (strings.usageBreakdown, Icons.manage_search),
      'sessions': (strings.sessionsNavigation, Icons.history),
      'sources': (strings.toolSources, Icons.build_outlined),
      'news': (strings.aiNews, Icons.rss_feed_rounded),
      'settings': (strings.pricingSettings, Icons.settings_outlined),
    };
  }

  @override
  void dispose() {
    _drawerFocus.dispose();
    _contentScroll.dispose();
    _sidebarScroll.dispose();
    super.dispose();
  }

  void navigate(String target, [Map<String, String> params = const {}]) {
    scaffold.currentState?.closeDrawer();
    if (target == 'news' && !newsVisible) target = 'home';
    if (page == 'sessions') {
      _sessionQuery = Uri.splitQueryString(query)
        ..remove('source')
        ..remove('session');
    }
    params = widget.controller.visibleQuery({
      ...(target == 'sessions' && params.isEmpty ? _sessionQuery : params),
    });
    setState(() {
      page = target;
      query = target == 'detail'
          ? detailSearch(
              params.containsKey('period')
                  ? StatsPeriod.parse(Uri(queryParameters: params).query)
                  : widget.controller.period,
              params,
            )
          : Uri(queryParameters: params).query;
    });
  }

  void manageHidden() => navigate('sources', {'filter': 'hidden'});

  void openUpdate() {
    navigate('settings');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final card = _updateCard.currentContext;
      if (card != null) {
        unawaited(Scrollable.ensureVisible(card, alignment: 0.12));
      }
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
  Widget unreadBadge(LensPalette p, int count) => count == 0
      ? const SizedBox.shrink()
      : Semantics(
          label: context.strings.unreadCount(count),
          excludeSemantics: true,
          child: Container(
            key: const Key('news-unread-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              color: p['clay-wash'],
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              count > 99 ? '99+' : '$count',
              style: p.text(11, p['clay-ink'], FontWeight.w500),
            ),
          ),
        );
  Widget sidebar(BuildContext context, {bool drawer = false}) {
    final p = LensPalette.of(context), c = widget.controller;
    final entries =
        <String, int>{
          for (final s in c.overview?.sources.sources ?? [])
            if (!c.isHidden(s.source)) s.source: 0,
          for (final g in c.overview?.sidebar.groups ?? [])
            if (g.key != null && !c.isHidden(g.key)) g.key!: g.grossTokens,
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
      child: LensPressFeedback(
        builder: (states) => LensFocusOutline(
          child: InkWell(
            statesController: states,
            key: key,
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: 36 * c.preferences.spacing,
              padding: EdgeInsets.symmetric(
                horizontal: 12 * c.preferences.spacing,
              ),
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
        ),
      ),
    );
    return FocusTraversalOrder(
      order: const NumericFocusOrder(0),
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Material(
          color: p['surface-0'],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(
                  width: LensPalette.hairline(context),
                  color: p['line'],
                ),
              ),
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
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(2),
                        child: LensFocusOutline(
                          child: IconButton(
                            tooltip: context.strings.closeNavigationMenu,
                            onPressed: () =>
                                scaffold.currentState?.closeDrawer(),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(0),
                    child: FocusTraversalGroup(
                      policy: ReadingOrderTraversalPolicy(),
                      child: ListView(
                        controller: _sidebarScroll,
                        padding: EdgeInsets.zero,
                        children: [
                          Semantics(
                            label: context.strings.pageNavigation,
                            container: true,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final group in [
                                  (
                                    context.strings.usage,
                                    ['home', 'detail', 'sessions', 'sources'],
                                  ),
                                  if (newsVisible)
                                    (context.strings.news, ['news']),
                                  (context.strings.settings, ['settings']),
                                ]) ...[
                                  Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      12,
                                      group.$1 == context.strings.usage
                                          ? 0
                                          : 14,
                                      12,
                                      6,
                                    ),
                                    child: Semantics(
                                      container: true,
                                      header: true,
                                      child: Text(
                                        group.$1,
                                        style: p.text(
                                          12,
                                          p.muted,
                                          FontWeight.w500,
                                        ),
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
                                        key: ValueKey('nav-$target'),
                                        trailing:
                                            target == 'news' &&
                                                widget.newsListenable != null &&
                                                widget.newsUnread != null
                                            ? ListenableBuilder(
                                                listenable:
                                                    widget.newsListenable!,
                                                builder: (context, _) =>
                                                    unreadBadge(
                                                      p,
                                                      widget.newsUnread!(),
                                                    ),
                                              )
                                            : null,
                                      ),
                                    ),
                                ],
                              ],
                            ),
                          ),
                          if (page != 'news') ...[
                            const SizedBox(height: 20),
                            if (c.loading)
                              Text(
                                context.strings.loadingUsageForThisPeriod,
                                style: p.text(12, p.muted),
                              ),
                            if (c.error != null ||
                                c.resourceErrors.containsKey('sources'))
                              LensButton(
                                label: context.strings.retryLoading,
                                size: 'xs',
                                onPressed: () => unawaited(c.load()),
                              ),
                            if (entries.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  8,
                                ),
                                child: Text(
                                  context.strings.toolsInThisPeriod,
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
                                  key: ValueKey('sidebar-tool-${entry.key}'),
                                  trailing: Text(
                                    percentage(
                                      total > 0 ? entry.value / total : 0,
                                    ),
                                    style: p.text(12, p.muted),
                                  ),
                                ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Divider(
                  height: 1,
                  thickness: LensPalette.hairline(context),
                  color: p['line'],
                ),
                const SizedBox(height: 16),
                UpdateHint(controller: c.updates, onOpen: openUpdate),
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
                        child: Text(
                          c.syncLabel,
                          style: p.text(12, p.secondary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(1),
                  child: FocusTraversalGroup(
                    policy: ReadingOrderTraversalPolicy(),
                    child: Row(
                      children: [
                        LensButton(
                          label: context.strings.syncUsage,
                          spinning: c.busy,
                          icon: Icons.refresh,
                          variant: 'ghost',
                          size: 'sidebar',
                          onPressed: c.busy ? null : () => unawaited(c.sync()),
                        ),
                        const Spacer(),
                        for (final item in [
                          (
                            'light',
                            context.strings.light,
                            Icons.light_mode_outlined,
                          ),
                          (
                            'dark',
                            context.strings.dark,
                            Icons.dark_mode_outlined,
                          ),
                        ])
                          Semantics(
                            button: true,
                            selected: c.preferences.appearance == item.$1,
                            child: Tooltip(
                              message: context.strings.themeShortcut(item.$2),
                              child: LensFocusOutline(
                                child: InkWell(
                                  onTap: () => unawaited(
                                    c.setPreferences(
                                      c.preferences.copyWith(
                                        appearance: item.$1,
                                      ),
                                    ),
                                  ),
                                  onLongPress: () => unawaited(
                                    c.setPreferences(
                                      c.preferences.copyWith(
                                        appearance: 'system',
                                      ),
                                    ),
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                  child: Padding(
                                    padding: const EdgeInsets.all(6),
                                    child: Icon(
                                      item.$3,
                                      size: 15,
                                      color: p.secondary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      if (page == 'news' && !newsVisible) {
        page = 'home';
        query = '';
      }
      if (query.isNotEmpty && widget.controller.hiddenTools.isNotEmpty) {
        final params = Uri.splitQueryString(query);
        final count = params.length;
        widget.controller.visibleQuery(params);
        if (params.length != count) query = Uri(queryParameters: params).query;
      }
      final p = LensPalette.of(context);
      final narrow = MediaQuery.sizeOf(context).width < 768;
      return FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: StatsOnboardingGate(
          controller: widget.controller,
          child: Scaffold(
            key: scaffold,
            backgroundColor: p['surface-1'],
            drawer: narrow
                ? SizedBox(
                    width: 272,
                    child: FocusScope(
                      node: _drawerFocus,
                      child: sidebar(context, drawer: true),
                    ),
                  )
                : null,
            drawerEnableOpenDragGesture: true,
            body: Row(
              children: [
                if (!narrow)
                  SizedBox(width: _sidebarWidth, child: sidebar(context)),
                Expanded(
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(1),
                    child: FocusTraversalGroup(
                      policy: ReadingOrderTraversalPolicy(),
                      child: Column(
                        children: [
                          if (narrow)
                            Container(
                              height: 52,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    width: LensPalette.hairline(context),
                                    color: p['line'],
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  LensFocusOutline(
                                    child: IconButton(
                                      tooltip:
                                          context.strings.openNavigationMenu,
                                      onPressed: () =>
                                          scaffold.currentState!.openDrawer(),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      icon: Icon(
                                        Icons.menu,
                                        size: 22,
                                        color: p.ink,
                                      ),
                                    ),
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
                                                  sidebarWidth: _sidebarWidth,
                                                  onDetail: (p) =>
                                                      navigate('detail', p),
                                                  onSessions: (p) =>
                                                      navigate('sessions', p),
                                                  onSources: () =>
                                                      navigate('sources'),
                                                  onManageHidden: manageHidden,
                                                  onSettings: () =>
                                                      navigate('settings'),
                                                )
                                              : page == 'detail'
                                              ? StatsDetail(
                                                  controller: widget.controller,
                                                  openLink: widget.openLink,
                                                  onSources: () =>
                                                      navigate('sources'),
                                                  onManageHidden: manageHidden,
                                                  onSessions: (p) =>
                                                      navigate('sessions', p),
                                                  query: query,
                                                  onQuery: (value) => setState(
                                                    () => query = value,
                                                  ),
                                                  onHome: () {
                                                    final period =
                                                        StatsPeriod.parse(
                                                          query,
                                                        );
                                                    navigate('home');
                                                    unawaited(
                                                      widget.controller
                                                          .setPeriod(period),
                                                    );
                                                  },
                                                  onSettings: () =>
                                                      navigate('settings'),
                                                )
                                              : page == 'sessions'
                                              ? StatsSessionsPage(
                                                  controller: widget.controller,
                                                  onSources: () =>
                                                      navigate('sources'),
                                                  onManageHidden: manageHidden,
                                                  query: query,
                                                  onQuery: (value) => setState(
                                                    () => query = value,
                                                  ),
                                                  onDetail: (params) =>
                                                      navigate(
                                                        'detail',
                                                        params,
                                                      ),
                                                )
                                              : page == 'sources'
                                              ? StatsSourcesPage(
                                                  controller: widget.controller,
                                                  openLink: widget.openLink,
                                                  query: query,
                                                  onDetail: (params) =>
                                                      navigate(
                                                        'detail',
                                                        params,
                                                      ),
                                                )
                                              : StatsSettingsPage(
                                                  controller: widget.controller,
                                                  updateCardKey: _updateCard,
                                                  query: query,
                                                  openLink: widget.openLink,
                                                ),
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
