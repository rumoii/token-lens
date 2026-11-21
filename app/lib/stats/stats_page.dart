import '../l10n/app_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../smooth_wheel.dart';
import '../stats_controller.dart';
import 'logic/detail_query.dart';
import 'logic/period.dart';
import 'logic/format.dart';
import 'logic/tool_order.dart';
import 'logic/tools.dart';
import 'mini/mini_panel.dart';
import 'mini/mini_window.dart';
import 'theme/palette.dart';
import 'widgets/primitives.dart';
import 'widgets/request_log.dart' show requestSessionQuery;
import 'widgets/sidebar.dart';
import 'home_page.dart';
import 'detail_page.dart';
import 'sessions_page.dart';
import 'sources_page.dart';
import 'settings_page.dart';
import 'onboarding_page.dart';
import 'widgets/motion.dart';
import '../update/update_widgets.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({
    super.key,
    required this.controller,
    this.miniWindow,
    this.news,
    this.openLink,
    this.newsListenable,
    this.newsUnread,
  });
  final StatsController controller;
  final MiniWindow? miniWindow;
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
  int _restored = 0;
  bool get newsVisible =>
      widget.news != null && widget.controller.preferences.newsEnabled;
  VoidCallback? get onMini => widget.miniWindow == null
      ? null
      : () => unawaited(_switchMini(enter: true));
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

  Future<void> _switchMini({bool enter = false, VoidCallback? restored}) async {
    final window = widget.miniWindow;
    if (window == null || window.switching) return;
    try {
      if (enter) {
        await window.enter();
      } else {
        await window.exit();
        if (!mounted) return;
        setState(() => _restored++);
        restored?.call();
      }
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.strings.miniSwitchFailed)),
        );
      }
    }
  }

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
    final colors = assignToolColors(
      entries.map((entry) => (entry.key, entry.value)),
      p,
    );
    return StatsSidebar(
      closeDrawer: drawer ? () => scaffold.currentState?.closeDrawer() : null,
      content: ListView(
        controller: _sidebarScroll,
        padding: EdgeInsets.zero,
        children: [
          StatsNavigation(
            page: page,
            navigate: navigate,
            showNews: newsVisible,
            spacing: c.preferences.spacing,
            newsBadge:
                widget.newsListenable != null && widget.newsUnread != null
                ? StatsNewsBadge(
                    listenable: widget.newsListenable!,
                    unread: widget.newsUnread!,
                  )
                : null,
          ),
          if (page != 'news') ...[
            const SizedBox(height: 20),
            if (c.loading)
              Text(
                context.strings.loadingUsageForThisPeriod,
                style: p.text(12, p.muted),
              ),
            if (c.error != null || c.resourceErrors.containsKey('sources'))
              LensButton(
                label: context.strings.retryLoading,
                size: 'xs',
                onPressed: () => unawaited(c.load()),
              ),
            if (entries.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  context.strings.toolsInThisPeriod,
                  style: p.text(12, p.muted, FontWeight.w500),
                ),
              ),
              for (final entry in entries)
                StatsNavRow(
                  key: ValueKey('sidebar-tool-${entry.key}'),
                  label: toolOf(entry.key).name,
                  icon: ToolTile(
                    entry.key,
                    size: 20,
                    accent: colors[entry.key],
                  ),
                  spacing: c.preferences.spacing,
                  onTap: () =>
                      navigate('detail', {'tool': entry.key, 'dim': 'model'}),
                  trailing: Text(
                    percentage(total > 0 ? entry.value / total : 0),
                    style: p.text(12, p.muted),
                  ),
                ),
            ],
          ],
        ],
      ),
      footer: [
        UpdateHint(controller: c.updates, onOpen: openUpdate),
        Semantics(
          liveRegion: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 5), child: dot(p)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(c.syncLabel, style: p.text(12, p.secondary)),
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
                LensThemeToggle(
                  value: c.preferences.appearance,
                  onChanged: (value) => unawaited(
                    c.setPreferences(c.preferences.copyWith(appearance: value)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      if (widget.miniWindow case final window? when c.miniMode) {
        final panel = MiniPanel(
          controller: c,
          window: window,
          onExpand: () => unawaited(_switchMini()),
          onProject: (project) => unawaited(
            _switchMini(
              restored: () {
                navigate('detail', {
                  'period': 'today',
                  if (project == null)
                    'missing': 'project'
                  else
                    'project': project,
                });
              },
            ),
          ),
          onRequest: (request) {
            final params = requestSessionQuery(
              request,
              const StatsPeriod('today'),
            );
            if (params != null) {
              unawaited(
                _switchMini(restored: () => navigate('sessions', params)),
              );
            }
          },
        );
        return Scaffold(body: panel);
      }
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
      final fullWindow = FocusTraversalGroup(
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
                  SizedBox(width: statsSidebarWidth, child: sidebar(context)),
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
                                  LensIconButton(
                                    tooltip: context.strings.openNavigationMenu,
                                    onPressed: () =>
                                        scaffold.currentState!.openDrawer(),
                                    icon: Icons.menu,
                                    color: p.ink,
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
                                          maxWidth: 1440,
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
                                                  sidebarWidth:
                                                      statsSidebarWidth,
                                                  onDetail: (p) =>
                                                      navigate('detail', p),
                                                  onSessions: (p) =>
                                                      navigate('sessions', p),
                                                  onSources: () =>
                                                      navigate('sources'),
                                                  onManageHidden: manageHidden,
                                                  onMini: onMini,
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
                                                  onMini: onMini,
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
      if (_restored == 0) return fullWindow;
      return ColoredBox(
        color: p['surface-1'],
        child: MiniReveal(key: ValueKey(_restored), child: fullWindow),
      );
    },
  );
}
