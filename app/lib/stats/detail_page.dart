import '../l10n/app_strings.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../stats_controller.dart';
import '../stats_cache.dart';
import '../stats_gateway.dart';
import 'logic/detail_query.dart';
import 'logic/comparison.dart';
import 'logic/period.dart';
import 'logic/display.dart';
export 'logic/display.dart' show projectName;
import 'logic/format.dart';
import 'logic/home_data.dart';
import 'logic/tool_order.dart';
import 'logic/tools.dart';
import 'theme/palette.dart';
import 'widgets/primitives.dart';
import 'widgets/sync_status.dart';
import 'widgets/charts.dart';
import 'widgets/date_range.dart';
import 'widgets/empty_ledger.dart';
import 'widgets/filters.dart';
import 'widgets/resource.dart';
import 'widgets/timing.dart';
import 'widgets/request_log.dart';

String bucketText(
  String bucket, [
  DateTime? now,
  AppStrings strings = chineseStrings,
]) => usageBucket(bucket, now, strings);

class DetailRow {
  DetailRow({
    required this.id,
    required this.name,
    required this.tokens,
    required this.kinds,
    this.costMicros,
    this.requestCount,
    this.eventGrossTokens,
    this.timing,
    this.sub,
    this.relativeDay,
    this.drill,
    this.tools = const [],
  });
  final String id, name;
  final int tokens;
  final List<int?> kinds;
  final int? costMicros, requestCount, eventGrossTokens;
  final StatsTiming? timing;
  final String? sub, relativeDay;
  final (String, String)? drill;
  final List<String> tools;
}

List<DetailRow> detailRows(
  String dim,
  Object? data,
  Map<String, String> detail, {
  DateTime? now,
  AppStrings strings = chineseStrings,
}) {
  if (data is StatsTimeseries) {
    final today = now == null ? null : dayKey(now);
    final yesterday = now == null
        ? null
        : dayKey(DateTime(now.year, now.month, now.day - 1));
    DetailRow timeRow(StatsBucket r) {
      final date = data.granularity == 'day'
          ? DateTime.tryParse(r.bucket)
          : null;
      return DetailRow(
        id: r.bucket,
        name: date == null
            ? bucketText(r.bucket, now, strings)
            : strings.calendarDayWithWeekday(
                date.month,
                date.day,
                date.weekday,
              ),
        relativeDay: date == null
            ? null
            : r.bucket == today
            ? strings.today
            : r.bucket == yesterday
            ? strings.yesterday
            : null,
        tokens: r.grossTokens,
        requestCount: r.requestCount,
        eventGrossTokens: r.eventGrossTokens,
        costMicros: r.costMicros,
        kinds: [
          r.inputTokens,
          r.outputTokens,
          r.cacheReadTokens,
          r.cacheWriteTokens,
        ],
        drill: detail['bucket']!.isEmpty && !r.bucket.contains('T')
            ? ('bucket', r.bucket)
            : null,
      );
    }

    return [
      for (final r in data.points)
        if (r.grossTokens > 0) timeRow(r),
    ];
  }
  if (data is! StatsBreakdown) return [];
  if (dim == 'model') {
    final groups = <String?, List<StatsGroup>>{};
    for (final g in data.groups) {
      groups.putIfAbsent(g.model, () => []).add(g);
    }
    return [
      for (final e in groups.entries)
        (() {
          final kinds = <int?>[null, null, null, null];
          int? cost, requests;
          int? eventGross = 0;
          var tokens = 0;
          final tools = <String>{};
          for (final g in e.value) {
            tokens += g.grossTokens;
            eventGross = eventGross == null || g.eventGrossTokens == null
                ? null
                : eventGross + g.eventGrossTokens!;
            if (g.requestCount != null) {
              requests = (requests ?? 0) + g.requestCount!;
            }
            if (g.source != null) tools.add(g.source!);
            if (g.costMicros != null) cost = (cost ?? 0) + g.costMicros!;
            final values = [
              g.inputTokens,
              g.outputTokens,
              g.cacheReadTokens,
              g.cacheWriteTokens,
            ];
            for (var i = 0; i < 4; i++) {
              if (values[i] != null) kinds[i] = (kinds[i] ?? 0) + values[i]!;
            }
          }
          return DetailRow(
            id: e.key ?? '—',
            name: e.key ?? strings.modelNotLogged,
            tokens: tokens,
            requestCount: requests,
            eventGrossTokens: eventGross,
            kinds: kinds,
            costMicros: cost,
            tools: tools.toList(),
            // Percentiles cannot be merged from per-tool summaries. Rust returns
            // the model's request distribution under the same filter/snapshot.
            timing: e.value.first.modelTiming,
            sub: tools.map((id) => toolOf(id).name).join(strings.listSeparator),
            drill:
                detail['model']!.isEmpty && e.key != null && e.key!.isNotEmpty
                ? ('model', e.key!)
                : null,
          );
        })(),
    ];
  }
  return [
    for (final g in data.groups)
      DetailRow(
        id: g.key ?? '—',
        name: dim == 'tool'
            ? toolOf(g.key ?? '').name
            : projectName(
                    g.key,
                    peers: data.groups.map((group) => group.key),
                  ) ??
                  strings.noProjectLogged,
        tokens: g.grossTokens,
        requestCount: g.requestCount,
        eventGrossTokens: g.eventGrossTokens,
        kinds: [
          g.inputTokens,
          g.outputTokens,
          g.cacheReadTokens,
          g.cacheWriteTokens,
        ],
        costMicros: g.costMicros,
        tools: dim == 'tool' ? [g.key ?? ''] : [],
        timing: g.timing,
        drill: detail[dim]!.isEmpty && g.key != null && g.key!.isNotEmpty
            ? (dim, g.key!)
            : null,
      ),
  ];
}

class StatsDetail extends StatefulWidget {
  const StatsDetail({
    super.key,
    required this.controller,
    required this.query,
    required this.onQuery,
    required this.onHome,
    required this.onSettings,
    this.onSessions,
    this.onSources,
    this.onManageHidden,
    this.openLink,
    this.downloadsDirectory,
  });
  final StatsController controller;
  final String query;
  final ValueChanged<String> onQuery;
  final VoidCallback onHome, onSettings;
  final VoidCallback? onSources, onManageHidden;
  final ValueChanged<Map<String, String>>? onSessions;
  final Future<bool> Function(Uri)? openLink;
  final Future<Directory?> Function()? downloadsDirectory;
  @override
  State<StatsDetail> createState() => _StatsDetailState();
}

class _StatsDetailState extends State<StatsDetail> {
  late final options = LensResource<List<StatsBreakdown>>(changed);
  late final summary = LensResource<StatsSummary>(changed);
  late final trendCoverage = LensResource<StatsSummary>(changed);
  late final trend = LensResource<({PeriodAxis axis, StatsMatrix data})>(
    changed,
  );
  late final table = LensResource<({String kind, Object data})>(changed);
  late final comparison = LensResource<StatsComparison>(changed);
  String? sortKey;
  int sortDir = -1;
  bool exporting = false, projectPaths = false;
  bool trendCost = false;
  final exportFocus = FocusNode();
  final exportAnchor = GlobalKey();
  String? exportedPath;
  Object? exportError;
  StatsController get c => widget.controller;
  String _scope = '';
  Map<String, String> get d {
    final query = readDetail(widget.query);
    if (c.isHidden(query['tool'])) query['tool'] = '';
    return query;
  }

  StatsPeriod get period =>
      StatsPeriod.parse(widget.query).withWeekStart(c.preferences.weekStartsOn);
  static const comparisonGroups = {
    'tool': 'source',
    'model': 'model',
    'project': 'project',
  };
  bool get comparing =>
      d['compare'] == '1' &&
      comparisonGroups.containsKey(d['dim']) &&
      period.compare(c.clock()) != null;
  LensPalette get p => LensPalette.of(context);
  bool get narrow => MediaQuery.sizeOf(context).width < 768;
  void changed() {
    if (mounted) setState(() {});
  }

  StatsFilter detailFilter(Map<String, String> detail, DayRange range) =>
      StatsFilter(
        from: range.from,
        to: range.to,
        source: detail['tool']!.isEmpty ? null : detail['tool'],
        model: detail['model']!.isEmpty ? null : detail['model'],
        project: detail['project']!.isEmpty ? null : detail['project'],
        missing: detail['missing'],
      );

  Future<void> exportUsage(
    StatsUsageExporter exporter,
    String by,
    String format,
  ) async {
    if (exporting) return;
    final current = period;
    final detail = d;
    final range = current.range(c.clock());
    final picked = bucketRange(detail['bucket']!, range);
    final filter = detailFilter(detail, picked ?? range);
    final paths = projectPaths;
    final gateway = c.gateway;
    setState(() {
      exporting = true;
      exportedPath = null;
      exportError = null;
    });
    try {
      Directory? downloads;
      try {
        downloads =
            await (widget.downloadsDirectory ?? getDownloadsDirectory)();
      } catch (_) {
        /* Fall back to the application data directory. */
      }
      final directory =
          downloads?.path ??
          '${(await gateway.health()).dataDir}${Platform.pathSeparator}exports';
      final path = await exporter.exportUsage(
        by: by,
        period: picked == null || picked == range ? current.period : 'custom',
        filter: filter,
        format: format,
        projectPaths: paths,
        directory: directory,
      );
      if (mounted) setState(() => exportedPath = path);
    } catch (error) {
      if (mounted) setState(() => exportError = error);
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Future<void> openExportFolder(String path) async {
    try {
      final opened = await widget.openLink?.call(
        Uri.directory(File(path).parent.path),
      );
      if (opened == true) return;
      if (mounted) {
        setState(
          () => exportError = context.strings.couldNotOpenTheContainingFolder,
        );
      }
    } catch (error) {
      if (mounted) setState(() => exportError = error);
    }
  }

  Widget exportMenu(StatsUsageExporter exporter, String? by) {
    final strings = context.strings;
    return LensButton(
      key: exportAnchor,
      label: strings.export,
      size: 'sm',
      icon: Icons.download_outlined,
      focusNode: exportFocus,
      onPressed: by == null || exporting
          ? null
          : () async {
              exportFocus.requestFocus();
              final format = await LensMenu.show<String>(
                context,
                anchor: exportAnchor.currentContext!,
                width: 250,
                builder: (context) => StatefulBuilder(
                  builder: (context, updateMenu) => LensMenu(
                    entries: [
                      LensMenuEntry(
                        Text(strings.exportCsv),
                        onPressed: () => Navigator.pop(context, 'csv'),
                      ),
                      LensMenuEntry(
                        Text(strings.exportJson),
                        onPressed: () => Navigator.pop(context, 'json'),
                      ),
                      LensMenuEntry(
                        Text(strings.includeFullProjectPaths),
                        checked: projectPaths,
                        onPressed: () {
                          setState(() => projectPaths = !projectPaths);
                          updateMenu(() {});
                        },
                      ),
                    ],
                  ),
                ),
              );
              if (mounted && format != null) {
                await exportUsage(exporter, by, format);
              }
            },
    );
  }

  @override
  void initState() {
    super.initState();
    c.addListener(refresh);
    refresh();
  }

  @override
  void didUpdateWidget(StatsDetail old) {
    super.didUpdateWidget(old);
    if (old.controller != c) {
      old.controller.removeListener(refresh);
      c.addListener(refresh);
    }
    refresh();
  }

  @override
  void dispose() {
    c.removeListener(refresh);
    options.dispose();
    summary.dispose();
    trendCoverage.dispose();
    trend.dispose();
    table.dispose();
    comparison.dispose();
    exportFocus.dispose();
    super.dispose();
  }

  void refresh() {
    final detail = d, current = period, now = c.clock();
    final range = current.range(now);
    final base = c.visibleFilter(StatsFilter(from: range.from, to: range.to));
    final scope = c.hiddenScope;
    final retainData = scope == _scope;
    _scope = scope;
    final picked = bucketRange(detail['bucket']!, range);
    final filter = c.visibleFilter(detailFilter(detail, range));
    final scoped = picked == null
        ? filter
        : c.visibleFilter(detailFilter(detail, picked));
    final pk =
        '${current.query}|$range|${filter.source}|${filter.model}|${filter.project}|${filter.missing}|${c.ledgerVersion}|$scope';
    final sk =
        '$pk|${picked != null || detail['bucket']!.contains('T') ? detail['bucket'] : ''}';
    Future<PeriodAxis> axis() => current.period == 'all'
        ? mapStats(
            c.gateway.summary(base),
            (value) => current.axis(now, value.activity.firstSeen),
          )
        : StatsCacheHit(current.axis(now));
    options.read(
      '${current.query}|$range|${c.ledgerVersion}|$scope',
      () => waitForStats([
        c.gateway.breakdown('source_model', base),
        c.gateway.breakdown('project', base),
      ]),
      retainData: retainData,
    );
    summary.read(sk, () => c.gateway.summary(scoped), retainData: retainData);
    if (trendCost && picked != null) {
      trendCoverage.read(
        pk,
        () => c.gateway.summary(filter),
        retainData: false,
      );
    }
    trend.read(
      pk,
      () => mapStats(
        axis(),
        (a) => mapStats(
          c.gateway.matrix(a.granularity, 'source', filter),
          (data) => (axis: a, data: data),
        ),
      ),
      retainData: retainData,
    );
    final prior = current.compare(now);
    final dimension = comparisonGroups[detail['dim']];
    final compareGateway = c.gateway.comparisonGateway;
    if (detail['compare'] == '1' &&
        prior != null &&
        dimension != null &&
        compareGateway != null) {
      final previous = c.visibleFilter(
        detailFilter(detail, (from: prior.from, to: prior.to)),
      );
      comparison.read(
        (sk, dimension, prior.from, prior.to, detail['missing']),
        () => compareGateway.comparison(dimension, scoped, previous),
        retainData: false,
      );
    }
    if (detail['dim'] == 'request') return;
    table.read('$sk|${detail['dim']}', () {
      if (detail['dim'] == 'date') {
        return mapStats(
          axis(),
          (a) => mapStats(
            c.gateway.timeseries(
              picked != null ? 'day' : a.granularity,
              scoped,
            ),
            (data) => (kind: 'date', data: data),
          ),
        );
      }
      return mapStats(
        c.gateway.breakdown(
          const {
            'tool': 'source',
            'model': 'source_model',
            'project': 'project',
          }[detail['dim']]!,
          scoped,
        ),
        (data) => (kind: detail['dim']!, data: data),
      );
    }, retainData: retainData);
  }

  void go(Map<String, String> next, [StatsPeriod? value]) =>
      widget.onQuery(detailSearch(value ?? period, next));
  void setFilter(String key, String value) => go({
    ...d,
    key: value,
    if (d['missing'] == key) 'missing': '',
    'dim': d['dim'] == 'request'
        ? 'request'
        : value.isNotEmpty
        ? nextDim(key)
        : d['dim']!,
  });
  Widget token(num? v, {TextStyle? style}) => TokenText(
    v,
    unitSystem: c.unitSystem,
    style: style ?? p.text(13, p.secondary),
  );
  Widget money(int? micros, {TextStyle? style}) => MoneyText(
    micros == null ? null : microsUsd(micros),
    currency: c.preferences.currency,
    rate: rateFor(c.preferences.rates, c.preferences.currency),
    style: style ?? p.text(13),
  );
  Widget head(String title, String sub, {Widget? action}) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 0) * c.preferences.spacing,
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: 12,
      runSpacing: 12,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: p.text(15, null, FontWeight.w600)),
            const SizedBox(height: 2),
            Text(sub, style: p.text(12.5, p.muted)),
          ],
        ),
        ?action,
      ],
    ),
  );
  Widget filters(List<StatsBreakdown>? data) {
    final pairs = data?[0].groups ?? <StatsGroup>[],
        projects = data?[1].groups ?? <StatsGroup>[];
    final tools = <String, int>{},
        models = <String, ({int tokens, String? tool})>{};
    for (final g in pairs) {
      if (g.grossTokens <= 0) continue;
      if (g.source != null) {
        tools.update(
          g.source!,
          (v) => v + g.grossTokens,
          ifAbsent: () => g.grossTokens,
        );
      }
      if (g.model?.isNotEmpty == true) {
        final old = models[g.model];
        models[g.model!] = (
          tokens: (old?.tokens ?? 0) + g.grossTokens,
          tool: old?.tool ?? g.source,
        );
      }
    }
    final ts = tools.entries.toList()..sort((a, b) => b.value - a.value);
    final ms = models.entries.toList()
      ..sort((a, b) => b.value.tokens - a.value.tokens);
    final ps =
        projects
            .where((g) => g.key?.isNotEmpty == true && g.grossTokens > 0)
            .toList()
          ..sort((a, b) => b.grossTokens - a.grossTokens);
    final detail = d;
    final selected =
        bucketRange(detail['bucket']!, period.range(c.clock())) != null ||
        detail['bucket']!.contains('T');
    String? value(String field) =>
        detail[field]!.isEmpty ? null : detail[field];
    final tool = value('tool');
    final model = value('model');
    final project = value('project');
    final missing = detail['missing'];
    final missingLabel = missing == null
        ? null
        : comparisonGroupName(missing, null, const [], context.strings);
    final tags = [
      for (final k in ['tool', 'model', 'project', 'bucket'])
        if (detail[k]!.isNotEmpty && (k != 'bucket' || selected)) k,
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilterPick(
          label: context.strings.tool,
          selected: tool,
          selectedLabel: tool == null ? null : toolOf(tool).name,
          selectedTool: tool,
          onClear: tool == null ? null : () => setFilter('tool', ''),
          options: [
            for (final t in ts)
              FilterOption(
                t.key,
                toolOf(t.key).name,
                tool: t.key,
                tokens: t.value,
              ),
          ],
          onPick: (v) => setFilter('tool', v),
          unitSystem: c.unitSystem,
        ),
        FilterPick(
          label: context.strings.model,
          selected: model,
          selectedLabel: missing == 'model' ? missingLabel : model,
          onClear: missing == 'model'
              ? () => go({...detail, 'missing': ''})
              : model == null
              ? null
              : () => setFilter('model', ''),
          options: [
            for (final m in ms)
              FilterOption(
                m.key,
                m.key,
                tool: m.value.tool,
                tokens: m.value.tokens,
              ),
          ],
          onPick: (v) => setFilter('model', v),
          unitSystem: c.unitSystem,
        ),
        FilterPick(
          label: context.strings.project,
          selected: project,
          selectedLabel: missing == 'project'
              ? missingLabel
              : projectName(project) ?? project,
          onClear: missing == 'project'
              ? () => go({...detail, 'missing': ''})
              : project == null
              ? null
              : () => setFilter('project', ''),
          options: [
            for (final g in ps)
              FilterOption(
                g.key!,
                projectName(g.key, peers: projects.map((group) => group.key)) ??
                    g.key!,
                tooltip: g.key,
                tokens: g.grossTokens,
              ),
          ],
          onPick: (v) => setFilter('project', v),
          unitSystem: c.unitSystem,
        ),
        if (tags.contains('bucket'))
          LensFilterTrigger(
            label: context.strings.time,
            value: bucketText(detail['bucket']!, c.clock(), context.strings),
            onPressed: null,
            onClear: () => setFilter('bucket', ''),
          ),
        if (tags.isNotEmpty || detail['missing'] != null)
          LensTextLink(
            label: context.strings.clearFilters,
            onTap: () => go({
              'dim': detail['dim']!,
              if (detail['compare'] == '1') 'compare': '1',
            }),
          ),
      ],
    );
  }

  Widget strip(StatsSummary? data) {
    final totals = data?.totals;
    final unpriced = totals?.unpricedRecords ?? 0;
    final cells = [
      (
        context.strings.usage,
        token(
          totals?.grossTokens,
          style: p.serif(22, weight: FontWeight.w600).copyWith(height: 1.5),
        ),
        context.strings.tokenUnit,
      ),
      (
        context.strings.estCost,
        money(
          totals?.costMicros,
          style: p.serif(22, weight: FontWeight.w600).copyWith(height: 1.5),
        ),
        totals != null && totals.recordCount > 0 && totals.costMicros == null
            ? context.strings.noPricingYet
            : unpriced > 0
            ? context.strings.listPriceWithUnpricedRecords(
                toDisplayNumber(unpriced),
              )
            : context.strings.atListPrices,
      ),
      (
        context.strings.sessions,
        Text(
          '${data?.activity.sessions ?? 0}',
          style: p.serif(22, weight: FontWeight.w600).copyWith(height: 1.5),
        ),
        context.strings.withUsageInThisPeriod,
      ),
      (
        context.strings.cacheHit,
        Text(
          data?.activity.cacheHitRatio == null
              ? '—'
              : percentage(data!.activity.cacheHitRatio),
          style: p.serif(22, weight: FontWeight.w600).copyWith(height: 1.5),
        ),
        context.strings.shareOfInputServedFromCache,
      ),
    ];
    final columns = narrow ? 2 : 4;
    return Wrap(
      children: [
        for (var i = 0; i < 4; i++)
          FractionallySizedBox(
            widthFactor: 1 / columns,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 14) *
                  c.preferences.spacing,
              decoration: BoxDecoration(
                border: Border(
                  left: i % columns > 0
                      ? BorderSide(
                          width: LensPalette.hairline(context),
                          color: p['line-soft'],
                        )
                      : BorderSide.none,
                  top: i >= columns
                      ? BorderSide(
                          width: LensPalette.hairline(context),
                          color: p['line-soft'],
                        )
                      : BorderSide.none,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(cells[i].$1, style: p.text(12.5, p.muted)),
                      ),
                      if (i == 3) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: context
                              .strings
                              .cacheReadsNewInputCacheReadsHigher,
                          child: Container(
                            width: 15,
                            height: 15,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              border: Border.all(
                                width: LensPalette.hairline(context),
                                color: p['line-strong'],
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: Text('?', style: p.text(10, p.muted)),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  cells[i].$2,
                  Text(
                    cells[i].$3,
                    style: p.text(12, p.muted).copyWith(height: 1.4),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget trendContent(({PeriodAxis axis, StatsMatrix data})? value) {
    if (value == null) return const SizedBox();
    final buckets = buildBuckets(
      value.data.rows,
      value.axis,
      c.clock(),
      cost: trendCost,
    );
    final sequence = sourceSequence(
      c.overview?.sources.sources
              .where((s) => !c.isHidden(s.source))
              .toList() ??
          [],
    );
    final order = sortByToolOrder(
      buckets
          .expand((b) => b.by.keys)
          .toSet()
          .where((id) => buckets.any((b) => (b.by[id] ?? 0) > 0))
          .toList(),
      sequence,
    );
    final sources = order.toSet();
    final slots = assignToolColors(
      value.data.rows
          .where((row) => sources.contains(row.key ?? ''))
          .map((row) => (row.key ?? '', row.grossTokens)),
      p,
    );
    final unit = {
      'hour': context.strings.hour,
      'day': context.strings.day,
      'month': context.strings.month,
    }[value.axis.granularity]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        head(
          context.strings.trend,
          context.strings.usageTrendHint(
            unit,
            value.axis.granularity != 'hour'
                ? context.strings.selectABarToFilterToThat(unit)
                : '',
          ),
          action: TrendMetricControl(
            key: const Key('trend-metric'),
            cost: trendCost,
            onChanged: (value) {
              setState(() => trendCost = value);
              refresh();
            },
          ),
        ),
        Padding(
          padding:
              const EdgeInsets.fromLTRB(18, 14, 18, 18) * c.preferences.spacing,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 14,
                runSpacing: 4,
                children: [
                  for (final id in order.take(8))
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: slots[id],
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          toolOf(id).name,
                          style: p.text(12, p.secondary).copyWith(height: 1.4),
                        ),
                      ],
                    ),
                ],
              ),
              TrendChart(
                buckets: buckets,
                order: order,
                slots: slots,
                granularity: value.axis.granularity,
                now: c.clock(),
                weekdays: period.weekdays,
                costMode: trendCost,
                selected: d['bucket']!.isEmpty ? null : d['bucket'],
                onPick: value.axis.granularity == 'hour'
                    ? null
                    : (v) => setFilter('bucket', v),
                unitSystem: c.unitSystem,
                currency: c.preferences.currency,
                rate: rateFor(c.preferences.rates, c.preferences.currency),
              ),
              if (trendCost &&
                  (value.data.rows.any((row) => row.unpricedRecords > 0) ||
                      ((bucketRange(d['bucket']!, period.range(c.clock())) !=
                                          null
                                      ? trendCoverage.data
                                      : summary.data)
                                  ?.totals
                                  .unpricedRecords ??
                              0) >
                          0))
                Text(
                  context.strings.trendUnpricedNote,
                  style: p.text(12, p.muted),
                ),
              if ((value.data.unallocated?.grossTokens ?? 0) > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    context.strings.chartSpanningSessions(
                      tokenCount(
                        value.data.unallocated!.grossTokens,
                        unitSystem: c.unitSystem,
                      ),
                      unit,
                    ),
                    style: p.text(12.5, p.muted),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget rowName(DetailRow row) {
    final style = p
        .text(narrow ? 16 : 13, null, FontWeight.w500)
        .copyWith(height: 1.5);
    final relative = row.relativeDay;
    final name = relative == null
        ? Text(
            row.name,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: style,
          )
        : Text.rich(
            TextSpan(
              text: row.name,
              children: [
                TextSpan(
                  text: ' · $relative',
                  style: TextStyle(color: p.secondary),
                ),
              ],
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: style,
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final id in row.tools.take(3)) ...[
          ToolTile(id, size: d['dim'] == 'tool' ? 24 : 16),
          const SizedBox(width: 8),
        ],
        if (row.tools.length > 3) ...[
          Tooltip(
            message: row.tools
                .map((id) => toolOf(id).name)
                .join(context.strings.listSeparator),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: p['fill-hover'],
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '+${row.tools.length - 3}',
                style: p.text(10, p.muted),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: d['dim'] == 'model' || d['dim'] == 'project'
              ? Tooltip(
                  message: d['dim'] == 'project' ? row.id : row.name,
                  child: name,
                )
              : name,
        ),
      ],
    );
  }

  ({Widget? sort, Widget content}) tableContent(
    ({String kind, Object data})? snapshot, {
    required bool compact,
  }) {
    final data = snapshot?.data;
    final detail = d, dim = snapshot?.kind ?? detail['dim']!;
    final nameFlex = switch (dim) {
      'model' => 30,
      'project' => 22,
      'tool' => 26,
      'date' when data is StatsTimeseries && data.granularity == 'day' => 24,
      _ => 16,
    };
    var rows = detailRows(
      dim,
      data,
      detail,
      now: c.clock(),
      strings: context.strings,
    );
    final compared = comparing && snapshot?.kind == d['dim'] && comparison.fresh
        ? comparison.data
        : null;
    final changes = <String, GroupChange>{};
    if (compared != null) {
      final groups = groupChanges(compared);
      final existing = {for (final row in rows) row.id: row};
      final peers = groups.map((group) => group.key);
      rows = [
        for (final group in groups)
          (() {
            final id = group.key ?? '—';
            changes[id] = group;
            final row = existing[id], g = group.current;
            final key = group.key;
            return DetailRow(
              id: id,
              name: comparisonGroupName(
                compared.by,
                key,
                peers,
                context.strings,
              ),
              tokens: g?.grossTokens ?? 0,
              kinds: [
                g?.inputTokens,
                g?.outputTokens,
                g?.cacheReadTokens,
                g?.cacheWriteTokens,
              ],
              requestCount: g?.requestCount,
              eventGrossTokens: g?.eventGrossTokens,
              costMicros: g?.costMicros,
              timing: row?.timing,
              sub: row?.sub,
              tools: row?.tools ?? (dim == 'tool' && key != null ? [key] : []),
              drill:
                  row?.drill ??
                  (detail[dim]!.isEmpty && key != null && key.isNotEmpty
                      ? (dim, key)
                      : null),
            );
          })(),
      ];
    }
    final showTiming = dim == 'tool' || dim == 'model';
    Widget timingStrip(DetailRow r, {bool turn = false}) => TimingStrip(
      timing: r.timing,
      turn: turn,
      requestCount: r.requestCount ?? 0,
      metricKey: (kind) =>
          Key('detail-${turn ? 'turn-' : ''}${kind.name}-${r.id}'),
    );
    final sortOptions = {
      'name': {
        'date': context.strings.time,
        'tool': context.strings.tool,
        'model': context.strings.model,
        'project': context.strings.project,
      }[dim]!,
      'v': context.strings.usage,
      if (compared != null) ...{
        'previous': context.strings.comparisonPreviousColumn,
        'delta': context.strings.comparisonChange,
      },
      'cost': context.strings.estCost,
      'share': context.strings.share,
      for (var i = 0; i < 4; i++)
        'k$i': [
          context.strings.newInput,
          context.strings.output,
          context.strings.cacheRead,
          context.strings.cacheWrite,
        ][i],
      'requests': context.strings.requests,
      'average': context.strings.avgPerRequest,
    };
    final selectedSort = sortOptions.containsKey(sortKey)
        ? sortKey!
        : (dim == 'date' ? 'name' : 'v');
    num value(DetailRow r) => switch (selectedSort) {
      'previous' => changes[r.id]?.previous?.grossTokens ?? 0,
      'delta' => changes[r.id]?.delta() ?? 0,
      'cost' => r.costMicros ?? -1,
      'requests' => r.requestCount ?? -1,
      'average' =>
        r.requestCount != null &&
                r.requestCount! > 0 &&
                r.eventGrossTokens != null
            ? r.eventGrossTokens! / r.requestCount!
            : -1,
      _ when selectedSort.startsWith('k') =>
        r.kinds[int.parse(selectedSort.substring(1))] ?? -1,
      _ => r.tokens,
    };
    rows.sort(
      (a, b) =>
          (selectedSort == 'name'
              ? (dim == 'date'
                    ? a.id.compareTo(b.id)
                    : a.name.compareTo(b.name))
              : value(a).compareTo(value(b))) *
          sortDir,
    );
    final sum = rows.fold<int>(0, (s, r) => s + r.tokens);
    double share(DetailRow r) => sum == 0 ? 0 : r.tokens / sum;
    String percent(DetailRow r) => percentage(share(r));
    void open(DetailRow r) {
      if (r.drill != null) setFilter(r.drill!.$1, r.drill!.$2);
    }

    Widget row(DetailRow r, {bool compact = false}) {
      final change = changes[r.id];
      final previous = change?.previous?.grossTokens ?? 0;
      final delta = change?.delta() ?? 0;
      final badge = change?.badge(context.strings);
      final unused = change?.unused ?? false;
      Widget emptyCell() => Text('—', style: p.text(13, p.muted));
      Widget cost() => unused ? emptyCell() : money(r.costMicros);
      Widget requests({bool label = false}) => unused
          ? emptyCell()
          : Text(
              r.requestCount == null
                  ? context.strings.notLogged
                  : '${toDisplayNumber(r.requestCount)}${label ? context.strings.requestCountSuffix(r.requestCount!) : ''}',
              style: p.text(13, p.secondary),
            );
      Widget average() => unused
          ? emptyCell()
          : r.requestCount == null
          ? Text(context.strings.notLogged, style: p.text(13, p.muted))
          : token(
              r.requestCount! > 0 && r.eventGrossTokens != null
                  ? (r.eventGrossTokens! / r.requestCount!).round()
                  : null,
            );
      Widget deltaText() => Text(
        signedValue(
          delta,
          (value) => tokenCount(value, unitSystem: c.unitSystem),
        ),
        style: p.text(
          13,
          delta >= 0 ? p['clay-ink'] : p['ok'],
          FontWeight.w500,
        ),
      );
      Widget tokenKind(int i) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${[context.strings.newInput, context.strings.output, context.strings.cacheRead, context.strings.cacheWrite][i]} ',
            style: p.text(12.5, p.secondary),
          ),
          token(r.kinds[i]),
        ],
      );
      final name = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          rowName(r),
          if (badge != null) Text(badge, style: p.text(11, p.muted)),
          if (r.sub != null)
            Text(
              r.sub!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: p.text(12, p.muted).copyWith(height: 1.4),
            ),
        ],
      );
      return Semantics(
        button: r.drill != null,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 0),
          child: Material(
            type: MaterialType.transparency,
            clipBehavior: Clip.none,
            child: LensFocusOutline(
              child: InkWell(
                key: Key('detail-row-${r.id}'),
                onTap: r.drill == null ? null : () => open(r),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: (compact ? 12 : 10) * c.preferences.spacing,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: narrow
                          ? BorderSide.none
                          : BorderSide(
                              width: LensPalette.hairline(context),
                              color: p['line-soft'],
                            ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      compact
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(child: name),
                                    token(
                                      r.tokens,
                                      style: p
                                          .text(16, null, FontWeight.w600)
                                          .copyWith(height: 1.5),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 12,
                                  children: [
                                    if (change != null) ...[
                                      Text(
                                        '${context.strings.comparisonPreviousColumn} ${tokenCount(previous, unitSystem: c.unitSystem)}',
                                        style: p.text(12.5, p.secondary),
                                      ),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        spacing: 4,
                                        children: [
                                          Text(
                                            context.strings.comparisonChange,
                                            style: p.text(12.5, p.secondary),
                                          ),
                                          deltaText(),
                                        ],
                                      ),
                                    ],
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          context.strings.estimatedCostPrefix,
                                          style: p.text(12.5, p.secondary),
                                        ),
                                        cost(),
                                      ],
                                    ),
                                    requests(label: true),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          context
                                              .strings
                                              .averagePerRequestPrefix,
                                          style: p.text(12.5, p.secondary),
                                        ),
                                        average(),
                                      ],
                                    ),
                                    Text(
                                      context.strings.shareOfTotal(percent(r)),
                                      style: p.text(12.5, p.secondary),
                                    ),
                                    for (var i = 0; i < r.kinds.length; i += 2)
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          tokenKind(i),
                                          if (i + 1 < r.kinds.length) ...[
                                            const SizedBox(width: 12),
                                            tokenKind(i + 1),
                                          ],
                                        ],
                                      ),
                                  ],
                                ),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(flex: nameFlex, child: name),
                                Expanded(
                                  flex: 10,
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: token(
                                      r.tokens,
                                      style: p.text(13, null, FontWeight.w600),
                                    ),
                                  ),
                                ),
                                if (change != null) ...[
                                  Expanded(
                                    flex: 10,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: token(previous),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 10,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: deltaText(),
                                    ),
                                  ),
                                ],
                                Expanded(
                                  flex: 10,
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: cost(),
                                  ),
                                ),
                                Expanded(
                                  flex: 20,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      SizedBox(
                                        width: 56,
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            99,
                                          ),
                                          child: LinearProgressIndicator(
                                            value: share(r),
                                            minHeight: 5,
                                            color: p['clay'],
                                            backgroundColor: p['fill-hover'],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        percent(r),
                                        style: p
                                            .text(12, p.secondary)
                                            .copyWith(height: 1.4),
                                      ),
                                    ],
                                  ),
                                ),
                                for (final k in r.kinds)
                                  Expanded(
                                    flex: 11,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: token(k),
                                    ),
                                  ),
                                for (final child in [requests(), average()])
                                  Expanded(
                                    flex: 12,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: child,
                                    ),
                                  ),
                              ],
                            ),
                      if (showTiming && TimingStrip.hasSamples(r.timing))
                        Padding(
                          padding: EdgeInsets.only(
                            top: 8,
                            left: compact ? 0 : 36,
                          ),
                          child: timingStrip(r),
                        ),
                      if (showTiming && (r.timing?.turn?.turnCount ?? 0) > 0)
                        Padding(
                          padding: EdgeInsets.only(
                            top: 8,
                            left: compact ? 0 : 36,
                          ),
                          child: timingStrip(r, turn: true),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget header(String text, String key, int flex) => Expanded(
      flex: flex,
      child: LensFocusOutline(
        child: InkWell(
          onTap: () => setState(() {
            sortDir = sortKey == key ? -sortDir : -1;
            sortKey = key;
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '$text${sortKey == key
                  ? sortDir > 0
                        ? ' ↑'
                        : ' ↓'
                  : ''}',
              textAlign: key == 'name' ? TextAlign.left : TextAlign.right,
              style: p.text(12, p.muted).copyWith(height: 1.4),
            ),
          ),
        ),
      ),
    );
    final sort = compact && rows.isNotEmpty
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilterPick(
                key: const Key('detail-sort'),
                searchable: false,
                label: context.strings.sortBy0(sortOptions[selectedSort]),
                selected: selectedSort,
                size: 'sm',
                options: [
                  for (final option in sortOptions.entries)
                    FilterOption(option.key, option.value),
                ],
                onPick: (key) => setState(() {
                  sortKey = key;
                  sortDir = -1;
                }),
              ),
              const SizedBox(width: 8),
              LensSortDirection(
                ascending: sortDir >= 0,
                size: 'sm',
                tooltip: sortDir < 0
                    ? context.strings.highestFirst
                    : context.strings.lowestFirst,
                onPressed: () => setState(() {
                  sortKey = selectedSort;
                  sortDir = -sortDir;
                }),
              ),
            ],
          )
        : null;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 18),
            child: Text(
              context.strings.noUsageMatchesTheseFiltersInThis,
              textAlign: TextAlign.center,
              style: p.text(14, p.muted),
            ),
          )
        else if (compact)
          for (final r in rows) row(r, compact: true)
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      header(
                        {
                          'date': context.strings.time,
                          'tool': context.strings.tool,
                          'model': context.strings.model,
                          'project': context.strings.project,
                        }[dim]!,
                        'name',
                        nameFlex,
                      ),
                      header(context.strings.usage, 'v', 10),
                      if (compared != null) ...[
                        header(
                          context.strings.comparisonPreviousColumn,
                          'previous',
                          10,
                        ),
                        header(context.strings.comparisonChange, 'delta', 10),
                      ],
                      header(context.strings.estCost, 'cost', 10),
                      header(context.strings.share, 'share', 20),
                      for (var i = 0; i < 4; i++)
                        header(
                          [
                            context.strings.newInput,
                            context.strings.output,
                            context.strings.cacheRead,
                            context.strings.cacheWrite,
                          ][i],
                          'k$i',
                          11,
                        ),
                      header(context.strings.requests, 'requests', 12),
                      header(context.strings.avgPerRequest, 'average', 12),
                    ],
                  ),
                ),
                ...rows.map(row),
              ],
            ),
          ),
        if (data is StatsTimeseries && (data.unallocated?.grossTokens ?? 0) > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            child: Text(
              context.strings.tableSpanningSessions(
                tokenCount(
                  data.unallocated!.grossTokens,
                  unitSystem: c.unitSystem,
                ),
                {
                      'hour': context.strings.hour,
                      'day': context.strings.day,
                      'month': context.strings.month,
                    }[trend.data?.axis.granularity] ??
                    context.strings.day,
                {
                      'hour': context.strings.hour,
                      'day': context.strings.day,
                      'month': context.strings.month,
                    }[trend.data?.axis.granularity] ??
                    context.strings.day,
              ),
              style: p.text(12.5, p.muted),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
          child: Text(
            context.strings.newInputIsContentSentToThe,
            style: p.text(12.5, p.muted),
          ),
        ),
      ],
    );
    return (sort: sort, content: content);
  }

  @override
  Widget build(BuildContext context) {
    final controls = LensHeaderControls(
      children: [
        LensSegmented(
          options: {
            'overview': context.strings.overview,
            'detail': context.strings.breakdown,
          },
          value: 'detail',
          onChanged: (v) {
            if (v == 'overview') widget.onHome();
          },
          label: context.strings.view2,
        ),
        if (!c.emptyLedger)
          PeriodControl(
            period: period,
            now: c.clock(),
            onChanged: (value) {
              go({...d, 'bucket': ''}, value);
              unawaited(c.setPeriod(value));
            },
          ),
      ],
    );
    final dim = d['dim']!,
        picked = bucketRange(d['bucket']!, period.range(c.clock()));
    final gateway = c.gateway;
    final strings = context.strings;
    final prior = period.compare(c.clock(), strings);
    final compareLabel = strings.compareWith(
      prior?.label ?? strings.comparisonPreviousColumn,
    );
    void setCompare(bool value) {
      setState(() {
        sortKey = null;
        sortDir = -1;
      });
      go({
        ...d,
        'compare': value ? '1' : '',
        if (value) 'bucket': '',
        if (value && !comparisonGroups.containsKey(dim)) 'dim': 'project',
      });
    }

    final exportBy = dim != 'date'
        ? dim
        : picked != null
        ? 'day'
        : period.period == 'all'
        ? (trend.fresh ? trend.data?.axis.granularity : null)
        : period.granularity;
    final filtered = dim == 'request'
        ? false
        : dim == 'date'
        ? d['bucket']!.isNotEmpty
        : d[dim]!.isNotEmpty;
    final compareSwitch = Tooltip(
      message: prior == null ? strings.noComparisonPeriod : compareLabel,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          SizedBox(
            height: 30,
            child: LensSwitch(
              key: const Key('detail-compare'),
              label: compareLabel,
              value: comparing,
              onChanged: prior == null ? null : setCompare,
            ),
          ),
          GestureDetector(
            onTap: prior == null ? null : () => setCompare(!comparing),
            child: Text(
              compareLabel,
              style: p.text(12.5, prior == null ? p.muted : p.secondary),
            ),
          ),
        ],
      ),
    );
    final dimensionTabs = LensSegmented(
      options: {
        'date': trend.data?.axis.granularity == 'hour' && picked == null
            ? context.strings.byHour
            : context.strings.byTime,
        'tool': context.strings.byTool,
        'model': context.strings.byModel,
        'project': context.strings.byProject,
        'request': context.strings.byRequest,
      },
      value: dim,
      onChanged: (v) {
        setState(() {
          sortKey = null;
          sortDir = -1;
        });
        go({
          ...d,
          'dim': v,
          if (!comparisonGroups.containsKey(v)) 'compare': '',
        });
      },
      label: context.strings.groupBy,
      small: true,
    );

    Widget toolbar(Widget? sort) {
      final trailing = Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [compareSwitch, ?sort],
      );
      return Padding(
        padding:
            const EdgeInsets.fromLTRB(18, 12, 18, 0) * c.preferences.spacing,
        child: LayoutBuilder(
          builder: (context, box) => box.maxWidth < 760
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 6,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: dimensionTabs,
                    ),
                    Align(alignment: Alignment.centerRight, child: trailing),
                  ],
                )
              : OverflowBar(
                  alignment: MainAxisAlignment.spaceBetween,
                  overflowAlignment: OverflowBarAlignment.end,
                  spacing: 8,
                  overflowSpacing: 6,
                  children: [dimensionTabs, trailing],
                ),
        ),
      );
    }

    return Column(
      spacing: narrow ? 12 : 16,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c.fullSyncRunning || c.syncReceipt != null)
          StatsSyncBanner(controller: c, onSources: widget.onSources),
        LensPageHeader(
          title: StatsSyncTitle(
            controller: c,
            title: Text(
              context.strings.breakdown,
              style: p
                  .serif(narrow ? 24 : 28, weight: FontWeight.w500)
                  .copyWith(height: 1.25),
            ),
          ),
          controls: controls,
          spacing: 4,
          description: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (c.hiddenTools.isNotEmpty && widget.onManageHidden != null)
                StatsHiddenNotice(
                  controller: c,
                  onManage: widget.onManageHidden!,
                ),
              Text(
                context.strings.breakdownDescription(switch (period.period) {
                  'all' => context.strings.periodAllTime,
                  'custom' => context.strings.selectedPeriodInSentence,
                  _ => period.inSentence(context.strings),
                }),
                style: p.text(14, p.secondary),
              ),
            ],
          ),
        ),
        if (c.emptyLedger)
          EmptyLedgerCard(controller: c, onTools: widget.onSources)
        else ...[
          ResourceBlock(resource: options, rows: 1, builder: filters),
          LensCard(
            child: ResourceBlock(resource: summary, rows: 2, builder: strip),
          ),
          LensCard(
            child: ResourceBlock(
              resource: trend,
              rows: 6,
              builder: trendContent,
            ),
          ),
          LensCard(
            child: LayoutBuilder(
              builder: (context, box) {
                final useComparison =
                    comparing && gateway.comparisonGateway != null;
                final ready = useComparison
                    ? comparison.ready && comparison.error == null
                    : table.ready && table.error == null;
                final view = dim != 'request' && ready
                    ? tableContent(
                        table.data,
                        compact:
                            narrow ||
                            box.maxWidth - (table.ready ? 0 : 36) - 16 < 860,
                      )
                    : null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    head(
                      context.strings.breakdown2,
                      dim == 'request'
                          ? context.strings.oneRowPerRequestSelectARow
                          : filtered
                          ? context.strings.alreadyFilteredByThisFieldTryAnother
                          : context.strings.selectARowToAddItTo,
                      action: dim != 'request' && gateway.usageExporter != null
                          ? exportMenu(gateway.usageExporter!, exportBy)
                          : null,
                    ),
                    toolbar(view?.sort),
                    if (comparing && prior != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                        child: Text(
                          comparisonSubtitle(
                            picked ?? period.range(c.clock()),
                            (from: prior.from, to: prior.to),
                            strings,
                          ),
                          style: p.text(12, p.muted),
                        ),
                      ),
                    if (dim != 'request' &&
                        (exportedPath != null || exportError != null))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                        child: Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (exportedPath case final path?) ...[
                              Text(
                                context.strings.exportCompleted(
                                  File(path).uri.pathSegments.last,
                                ),
                              ),
                              TextButton(
                                onPressed: () => openExportFolder(path),
                                child: Text(
                                  context.strings.openContainingFolder,
                                ),
                              ),
                            ],
                            if (exportError case final error?)
                              Text(
                                context.strings.diagnosticsExportFailed(error),
                                style: p.text(13, p['danger']),
                              ),
                          ],
                        ),
                      ),
                    if (dim == 'request')
                      Padding(
                        padding:
                            const EdgeInsets.only(top: 12, bottom: 18) *
                            c.preferences.spacing,
                        child: RequestLog(
                          controller: c,
                          identity:
                              '${period.query}|${d['tool']}|${d['model']}|${d['project']}|${d['missing']}|${d['bucket']}|${c.ledgerVersion}',
                          filter: c.visibleFilter(
                            detailFilter(d, picked ?? period.range(c.clock())),
                          ),
                          onOpen: (r) {
                            final params = requestSessionQuery(r, period);
                            if (params != null) widget.onSessions?.call(params);
                          },
                        ),
                      )
                    else
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          table.ready ? 0 : 18,
                          12,
                          table.ready ? 0 : 18,
                          18,
                        ),
                        child: useComparison
                            ? ResourceBlock(
                                resource: comparison,
                                rows: 5,
                                builder: (_) => view!.content,
                              )
                            : ResourceBlock(
                                resource: table,
                                rows: 5,
                                builder: (_) => view!.content,
                              ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}
