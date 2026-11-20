import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../stats_controller.dart';
import '../stats_gateway.dart';
import 'logic/period.dart';
import 'logic/tools.dart';
import 'theme/palette.dart';
import 'widgets/primitives.dart';
import 'widgets/resource.dart';
import 'widgets/sources_parts.dart';
import 'widgets/source_inventory.dart';

class StatsSourcesPage extends StatefulWidget {
  const StatsSourcesPage({
    super.key,
    required this.controller,
    this.query = '',
    required this.onDetail,
    this.openLink,
  });
  final StatsController controller;
  final String query;
  final ValueChanged<Map<String, String>> onDetail;
  final Future<bool> Function(Uri)? openLink;

  @override
  State<StatsSourcesPage> createState() => _StatsSourcesPageState();
}

class _StatsSourcesPageState extends State<StatsSourcesPage> {
  late final sources = LensResource<StatsSources>(changed);
  late final inventory = LensResource<StatsDiscovery>(changed);
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
    sources.read(identity, c.gateway.sourcesFresh);
    inventory.read((
      c.gateway,
      c.syncDiscoveryRevision,
    ), () => c.gateway.discovery(fresh: true));
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
    inventory.dispose();
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
    final discovery = inventory.data;
    final hasInventory = discovery?.tools.isNotEmpty == true;
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
              context.strings.tools,
              style: p
                  .serif(wide ? 28 : 24, weight: FontWeight.w500)
                  .copyWith(height: 1.25, letterSpacing: wide ? -.28 : -.24),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hasInventory
                ? context.strings.inventoryIntro(
                    discovery!.supported,
                    discovery.tools
                        .where((tool) => tool.status == 'found')
                        .length,
                  )
                : context.strings.sourcesIntro(
                    list.isEmpty
                        ? ''
                        : context.strings.toolsFoundOnComputer(list.length),
                  ),
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
          if (hasInventory)
            ResourceBlock(
              resource: inventory,
              rows: 5,
              builder: (_) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (month.error != null)
                    ResourceBlock(
                      resource: month,
                      builder: (_) => const SizedBox.shrink(),
                    ),
                  if (sources.error != null)
                    ResourceBlock(
                      resource: sources,
                      builder: (_) => const SizedBox.shrink(),
                    ),
                  SourceInventory(
                    discovery: discovery!,
                    sources: sources.data?.sources ?? const [],
                    month: monthBy,
                    controller: c,
                    query: widget.query,
                    onDetail: widget.onDetail,
                    openLink: widget.openLink,
                  ),
                ],
              ),
            )
          else if (!inventory.ready)
            ResourceBlock(
              resource: inventory,
              rows: 5,
              builder: (_) => const SizedBox.shrink(),
            )
          else
            ResourceBlock(
              resource: month,
              rows: 1,
              builder: (_) => ResourceBlock(
                resource: sources,
                rows: 5,
                builder: (_) => list.isEmpty && deniedOnly.isEmpty
                    ? LensCard(
                        padding: EdgeInsets.all(16),
                        child: EmptyState(
                          title: context.strings.noToolLogsFoundYet,
                          hint: context.strings.useASupportedAiCodingToolThen,
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final columns =
                              MediaQuery.sizeOf(context).width >= 1024 ? 2 : 1;
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
          if (inventory.ready && !hasInventory && missing.isNotEmpty) ...[
            SizedBox(height: gap),
            SourcesMissingTools(ids: missing),
          ],
        ],
      ),
    );
  }
}
