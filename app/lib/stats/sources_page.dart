import 'package:flutter/material.dart';

import '../stats_controller.dart';
import '../stats_gateway.dart';
import 'logic/period.dart';
import 'logic/tools.dart';
import 'theme/palette.dart';
import 'widgets/primitives.dart';
import 'widgets/resource.dart';
import 'widgets/sources_parts.dart';

class StatsSourcesPage extends StatefulWidget {
  const StatsSourcesPage({
    super.key,
    required this.controller,
    this.query = '',
    required this.onDetail,
  });
  final StatsController controller;
  final String query;
  final ValueChanged<Map<String, String>> onDetail;

  @override
  State<StatsSourcesPage> createState() => _StatsSourcesPageState();
}

class _StatsSourcesPageState extends State<StatsSourcesPage> {
  late final sources = LensResource<StatsSources>(changed);
  late final month = LensResource<StatsBreakdown>(changed);
  StatsSync? receiptBeforeSync;
  StatsController get c => widget.controller;

  void changed() {
    if (mounted) setState(() {});
  }

  void refresh() {
    if (c.phase == StatsSyncPhase.running ||
        c.phase == StatsSyncPhase.conflict) {
      receiptBeforeSync = c.lastSync;
    }
    final range = const StatsPeriod('month').range(c.clock());
    final identity = (c.gateway, c.ledgerVersion, range.from, range.to);
    sources.read(identity, () => c.gateway.sources());
    month.read(
      identity,
      () => c.gateway.breakdown(
        'source',
        StatsFilter(from: range.from, to: range.to),
      ),
    );
    changed();
  }

  @override
  void initState() {
    super.initState();
    c.addListener(refresh);
    refresh();
  }

  @override
  void didUpdateWidget(StatsSourcesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(refresh);
      c.addListener(refresh);
      receiptBeforeSync = null;
    }
    refresh();
  }

  @override
  void dispose() {
    c.removeListener(refresh);
    sources.dispose();
    month.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 768;
    final gap = wide ? 16.0 : 12.0;
    final monthBy = {
      for (final group in month.data?.groups ?? <StatsGroup>[])
        group.key: group.grossTokens,
    };
    final list =
        (sources.data?.sources ?? <StatsSource>[])
            .where((item) => item.records > 0)
            .toList()
          ..sort((a, b) {
            final byTokens = (monthBy[b.source] ?? 0).compareTo(
              monthBy[a.source] ?? 0,
            );
            return byTokens != 0 ? byTokens : b.records.compareTo(a.records);
          });
    final found = list.map((item) => item.source).toSet();
    final issues = sources.data?.discoveryIssues ?? <StatsDiscoveryIssue>[];
    final denied = {
      for (final issue in issues)
        if (issue.permissionDenied > 0) issue.source,
    };
    final deniedOnly = denied.difference(found);
    final missing = tools.keys
        .where((id) => !found.contains(id) && !denied.contains(id))
        .toList();
    return Padding(
      // PageScroll in shared.jsx reserves pr-1 inside the page.
      padding: const EdgeInsets.only(right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              '工具',
              style: p
                  .serif(wide ? 28 : 24, weight: FontWeight.w500)
                  .copyWith(height: 1.25, letterSpacing: wide ? -.28 : -.24),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${list.isEmpty ? '' : '这台电脑上找到 ${list.length} 个 AI 编程工具。'}Token Lens 只读它们的日志，不上传，也不改动这些工具。',
            style: p
                .text(14, p.secondary)
                .copyWith(height: 1.5, letterSpacing: 0),
          ),
          SizedBox(height: gap),
          SourcesSyncStatus(
            controller: c,
            run: sources.data?.lastRun,
            discoveryFailures: issues.fold(
              0,
              (count, issue) =>
                  count +
                  issue.permissionDenied +
                  issue.ioErrors +
                  issue.unreadableEntries,
            ),
            result: identical(receiptBeforeSync, c.lastSync)
                ? null
                : c.lastSync,
          ),
          SizedBox(height: gap),
          ResourceBlock(
            resource: month,
            rows: 1,
            builder: (_) => ResourceBlock(
              resource: sources,
              rows: 5,
              builder: (_) => list.isEmpty && deniedOnly.isEmpty
                  ? const LensCard(
                      padding: EdgeInsets.all(16),
                      child: EmptyState(
                        title: '还没找到工具的日志',
                        hint: '用过支持的 AI 编程工具以后，点「立即同步」。',
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final columns = MediaQuery.sizeOf(context).width >= 1024
                            ? 2
                            : 1;
                        final width =
                            (constraints.maxWidth - gap * (columns - 1)) /
                            columns;
                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final item in list)
                              SizedBox(
                                width: width,
                                child: SourcesToolCard(
                                  key: ValueKey('tool-${item.source}'),
                                  item: item,
                                  permissionDenied: denied.contains(
                                    item.source,
                                  ),
                                  monthTokens: monthBy[item.source] ?? 0,
                                  controller: c,
                                  onDetail: () => widget.onDetail({
                                    'tool': item.source,
                                    'dim': 'model',
                                  }),
                                ),
                              ),
                            for (final id in deniedOnly)
                              SizedBox(
                                key: ValueKey('tool-$id'),
                                width: width,
                                child: SourcesUnreadableToolCard(source: id),
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ),
          if (missing.isNotEmpty) ...[
            SizedBox(height: gap),
            SourcesMissingTools(ids: missing),
          ],
        ],
      ),
    );
  }
}
