import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../theme/palette.dart';
import 'primitives.dart';

const statsSidebarWidth = 244.0;

class StatsSidebar extends StatelessWidget {
  const StatsSidebar({
    super.key,
    required this.content,
    required this.footer,
    this.closeDrawer,
  });

  final Widget content;
  final List<Widget> footer;
  final VoidCallback? closeDrawer;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
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
                    if (closeDrawer != null)
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(2),
                        child: LensIconButton(
                          tooltip: context.strings.closeNavigationMenu,
                          onPressed: closeDrawer,
                          icon: Icons.close,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(0),
                    child: FocusTraversalGroup(
                      policy: ReadingOrderTraversalPolicy(),
                      child: content,
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
                ...footer,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class StatsNavigation extends StatelessWidget {
  const StatsNavigation({
    super.key,
    required this.page,
    required this.navigate,
    required this.showNews,
    required this.spacing,
    this.newsBadge,
    this.statisticsAvailable = true,
    this.newsEnabled = true,
  });

  final String page;
  final ValueChanged<String> navigate;
  final bool showNews, statisticsAvailable, newsEnabled;
  final double spacing;
  final Widget? newsBadge;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context), s = context.strings;
    final nav = {
      'home': (
        statisticsAvailable ? s.usageOverview : s.startupOverview,
        Icons.insights_outlined,
      ),
      'detail': (
        statisticsAvailable ? s.usageBreakdown : s.startupDetail,
        Icons.manage_search,
      ),
      'sessions': (
        statisticsAvailable ? s.sessionsNavigation : s.startupSessions,
        Icons.history,
      ),
      'sources': (s.toolSources, Icons.build_outlined),
      'news': (s.aiNews, Icons.rss_feed_rounded),
      'settings': (s.pricingSettings, Icons.settings_outlined),
    };
    return Semantics(
      label: s.pageNavigation,
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (heading, targets) in [
            (s.usage, ['home', 'detail', 'sessions', 'sources']),
            if (showNews) (s.news, ['news']),
            (s.settings, ['settings']),
          ]) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                heading == s.usage ? 0 : 14,
                12,
                6,
              ),
              child: Semantics(
                container: true,
                header: true,
                child: Text(
                  heading,
                  style: p.text(12, p.muted, FontWeight.w500),
                ),
              ),
            ),
            for (final target in targets)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: StatsNavRow(
                  key: ValueKey('nav-$target'),
                  label: nav[target]!.$1,
                  icon: Icon(nav[target]!.$2, size: 17, color: p.secondary),
                  spacing: spacing,
                  onTap:
                      (target == 'news'
                          ? newsEnabled
                          : target == 'home' || statisticsAvailable)
                      ? () => navigate(target)
                      : null,
                  active: page == target,
                  trailing: target == 'news' && newsEnabled ? newsBadge : null,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class StatsNavRow extends StatelessWidget {
  const StatsNavRow({
    super.key,
    required this.label,
    required this.icon,
    required this.spacing,
    required this.onTap,
    this.active = false,
    this.trailing,
  });

  final String label;
  final Widget icon;
  final double spacing;
  final VoidCallback? onTap;
  final bool active;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final enabled = onTap != null;
    return Semantics(
      selected: active,
      button: true,
      enabled: enabled,
      child: LensPressFeedback(
        builder: (states) => LensFocusOutline(
          child: InkWell(
            statesController: states,
            onTap: onTap,
            canRequestFocus: enabled,
            borderRadius: BorderRadius.circular(8),
            child: Opacity(
              opacity: enabled ? 1 : LensTokens.disabledOpacity,
              child: Container(
                height: 36 * spacing,
                padding: EdgeInsets.symmetric(horizontal: 12 * spacing),
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
      ),
    );
  }
}

class StatsNewsBadge extends StatelessWidget {
  const StatsNewsBadge({
    super.key,
    required this.listenable,
    required this.unread,
  });

  final Listenable listenable;
  final int Function() unread;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: listenable,
    builder: (context, _) {
      final count = unread();
      if (count == 0) return const SizedBox.shrink();
      final p = LensPalette.of(context);
      return Semantics(
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
    },
  );
}
