import 'package:flutter/material.dart';

import 'l10n/app_strings.dart';
import 'smooth_wheel.dart';
import 'startup_failure_page.dart';
import 'stats/stats_page.dart';
import 'stats/theme/palette.dart';
import 'stats/widgets/primitives.dart';
import 'stats/widgets/sidebar.dart';
import 'stats_controller.dart';

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    this.statsController,
    this.failureCard,
    required this.news,
    this.openLink,
    this.newsListenable,
    this.newsUnread,
    this.newsEnabled = true,
    this.sidebarSpacing = 1,
  });

  final StatsController? statsController;
  final StartupFailureCard? failureCard;
  final Widget news;
  final Future<bool> Function(Uri)? openLink;
  final Listenable? newsListenable;
  final int Function()? newsUnread;
  final bool newsEnabled;
  final double sidebarSpacing;

  @override
  Widget build(BuildContext context) => statsController != null
      ? StatsPage(
          controller: statsController!,
          news: news,
          openLink: openLink,
          newsListenable: newsListenable,
          newsUnread: newsUnread,
        )
      : failureCard != null
      ? StatsFailureShell(
          card: failureCard!,
          news: news,
          newsEnabled: newsEnabled,
          newsListenable: newsListenable,
          newsUnread: newsUnread,
          spacing: sidebarSpacing,
        )
      : Scaffold(body: SafeArea(child: newsEnabled ? news : const SizedBox()));
}

class StatsFailureShell extends StatefulWidget {
  const StatsFailureShell({
    super.key,
    required this.card,
    required this.news,
    required this.newsEnabled,
    this.newsListenable,
    this.newsUnread,
    this.spacing = 1,
  });

  final StartupFailureCard card;
  final Widget news;
  final bool newsEnabled;
  final Listenable? newsListenable;
  final int Function()? newsUnread;
  final double spacing;

  @override
  State<StatsFailureShell> createState() => _StatsFailureShellState();
}

class _StatsFailureShellState extends State<StatsFailureShell> {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _drawerFocus = FocusScopeNode(
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  final _sidebarScroll = SmoothWheelController();
  bool _showNews = false;

  @override
  void didUpdateWidget(StatsFailureShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.newsEnabled) _showNews = false;
  }

  @override
  void dispose() {
    _drawerFocus.dispose();
    _sidebarScroll.dispose();
    super.dispose();
  }

  void _navigate(String page) {
    _scaffold.currentState?.closeDrawer();
    setState(() => _showNews = page == 'news');
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context), s = context.strings;
    final narrow = MediaQuery.sizeOf(context).width < 768;
    final sidebar = StatsSidebar(
      closeDrawer: narrow ? () => _scaffold.currentState?.closeDrawer() : null,
      content: ListView(
        controller: _sidebarScroll,
        padding: EdgeInsets.zero,
        children: [
          StatsNavigation(
            page: _showNews ? 'news' : 'home',
            navigate: _navigate,
            showNews: true,
            newsEnabled: widget.newsEnabled,
            statisticsAvailable: false,
            spacing: widget.spacing,
            newsBadge:
                widget.newsListenable == null || widget.newsUnread == null
                ? null
                : StatsNewsBadge(
                    listenable: widget.newsListenable!,
                    unread: widget.newsUnread!,
                  ),
          ),
        ],
      ),
      footer: [
        Text(s.startupStatisticsUnavailable, style: p.text(12, p.muted)),
      ],
    );
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Scaffold(
        key: _scaffold,
        backgroundColor: p['surface-1'],
        drawer: narrow
            ? SizedBox(
                width: 272,
                child: FocusScope(node: _drawerFocus, child: sidebar),
              )
            : null,
        body: Row(
          children: [
            if (!narrow) SizedBox(width: statsSidebarWidth, child: sidebar),
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
                          padding: const EdgeInsets.symmetric(horizontal: 14),
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
                                tooltip: s.openNavigationMenu,
                                onPressed: () =>
                                    _scaffold.currentState!.openDrawer(),
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
                            ],
                          ),
                        ),
                      Expanded(
                        child: _showNews
                            ? widget.news
                            : SingleChildScrollView(
                                padding: EdgeInsets.symmetric(
                                  horizontal: narrow ? 16 : 32,
                                  vertical: narrow ? 20 : 28,
                                ),
                                child: Align(
                                  alignment: Alignment.topLeft,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 640,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Semantics(
                                          header: true,
                                          child: Text(
                                            s.startupOverview,
                                            style: p.serif(22),
                                          ),
                                        ),
                                        const SizedBox(height: 18),
                                        LensCard(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 24,
                                            vertical: 22,
                                          ),
                                          child: widget.card,
                                        ),
                                      ],
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
    );
  }
}
