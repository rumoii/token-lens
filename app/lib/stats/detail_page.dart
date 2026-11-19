import '../l10n/app_strings.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../stats_controller.dart';
import '../stats_gateway.dart';
import 'logic/detail_query.dart';
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
    this.drill,
    this.tools = const [],
  });
  final String id, name;
  final int tokens;
  final List<int?> kinds;
  final int? costMicros, requestCount, eventGrossTokens;
  final StatsTiming? timing;
  final String? sub;
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
    return [
      for (final r in data.points)
        if (r.grossTokens > 0)
          DetailRow(
            id: r.bucket,
            name: bucketText(r.bucket, now, strings),
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
          ),
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
  late final trend = LensResource<({PeriodAxis axis, StatsMatrix data})>(
    changed,
  );
  late final table = LensResource<({String kind, Object data})>(changed);
  String? sortKey;
  int sortDir = -1;
  bool exporting = false, projectPaths = false;
  final exportFocus = FocusNode();
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
    return MenuAnchor(
      childFocusNode: exportFocus,
      reservedPadding: const EdgeInsets.all(12),
      alignmentOffset: const Offset(0, 4),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: p['line-strong'])),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        elevation: const WidgetStatePropertyAll(4),
      ),
      menuChildren: [
        MenuItemButton(
          onPressed: by == null ? null : () => exportUsage(exporter, by, 'csv'),
          child: Text(strings.exportCsv),
        ),
        MenuItemButton(
          onPressed: by == null
              ? null
              : () => exportUsage(exporter, by, 'json'),
          child: Text(strings.exportJson),
        ),
        CheckboxMenuButton(
          value: projectPaths,
          closeOnActivate: false,
          onChanged: (value) => setState(() => projectPaths = value ?? false),
          child: Text(strings.includeFullProjectPaths),
        ),
      ],
      builder: (context, menu, child) => LensButton(
        label: strings.export,
        size: 'sm',
        variant: 'ghost',
        focusNode: exportFocus,
        onPressed: by == null || exporting
            ? null
            : () {
                if (menu.isOpen) {
                  menu.close();
                } else {
                  menu.open();
                }
              },
      ),
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
    trend.dispose();
    table.dispose();
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
        '${current.query}|$range|${filter.source}|${filter.model}|${filter.project}|${c.ledgerVersion}|$scope';
    final sk =
        '$pk|${picked != null || detail['bucket']!.contains('T') ? detail['bucket'] : ''}';
    Future<PeriodAxis> axis() async => current.axis(
      now,
      current.period == 'all'
          ? (await c.gateway.summary(base)).activity.firstSeen
          : null,
    );
    options.read(
      '${current.query}|$range|${c.ledgerVersion}|$scope',
      () => Future.wait([
        c.gateway.breakdown('source_model', base),
        c.gateway.breakdown('project', base),
      ]),
      retainData: retainData,
    );
    summary.read(sk, () => c.gateway.summary(scoped), retainData: retainData);
    trend.read(pk, () async {
      final a = await axis();
      return (
        axis: a,
        data: await c.gateway.matrix(a.granularity, 'source', filter),
      );
    }, retainData: retainData);
    if (detail['dim'] == 'request') return;
    table.read('$sk|${detail['dim']}', () async {
      if (detail['dim'] == 'date') {
        final a = await axis();
        return (
          kind: 'date',
          data: await c.gateway.timeseries(
            picked != null ? 'day' : a.granularity,
            scoped,
          ),
        );
      }
      return (
        kind: detail['dim']!,
        data: await c.gateway.breakdown(
          const {
            'tool': 'source',
            'model': 'source_model',
            'project': 'project',
          }[detail['dim']]!,
          scoped,
        ),
      );
    }, retainData: retainData);
  }

  void go(Map<String, String> next, [StatsPeriod? value]) =>
      widget.onQuery(detailSearch(value ?? period, next));
  void setFilter(String key, String value) => go({
    ...d,
    key: value,
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
        for (final k in tags)
          FilterTag(
            label: {
              'tool': context.strings.tool,
              'model': context.strings.model,
              'project': context.strings.project,
              'bucket': context.strings.time,
            }[k]!,
            value: k == 'bucket'
                ? bucketText(detail[k]!, c.clock(), context.strings)
                : k == 'tool'
                ? toolOf(detail[k]!).name
                : k == 'project'
                ? projectName(detail[k]) ?? detail[k]!
                : detail[k]!,
            tool: k == 'tool' ? detail[k] : null,
            onRemove: () => setFilter(k, ''),
          ),
        if (tags.isNotEmpty)
          LensButton(
            label: context.strings.clearFilters,
            size: 'link',
            variant: 'ghost',
            onPressed: () => go({'dim': detail['dim']!}),
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
    final buckets = buildBuckets(value.data.rows, value.axis, c.clock());
    final sequence = sourceSequence(
          c.overview?.sources.sources
                  .where((s) => !c.isHidden(s.source))
                  .toList() ??
              [],
        ),
        slots = assignToolColors(sequence);
    final order = sortByToolOrder(
      buckets
          .expand((b) => b.by.keys)
          .toSet()
          .where((id) => buckets.any((b) => (b.by[id] ?? 0) > 0))
          .toList(),
      sequence,
    );
    final unit = {
      'hour': context.strings.hour,
      'day': context.strings.day,
      'month': context.strings.month,
    }[value.axis.granularity]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        head(
          context.strings.trend,
          context.strings.usageTrendHint(
            unit,
            value.axis.granularity != 'hour'
                ? context.strings.selectABarToFilterToThat(unit)
                : '',
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
                            color: p.category(slots[id] ?? 0),
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
                weekdays: period.period == 'week',
                selected: d['bucket']!.isEmpty ? null : d['bucket'],
                onPick: value.axis.granularity == 'hour'
                    ? null
                    : (v) => setFilter('bucket', v),
                unitSystem: c.unitSystem,
                currency: c.preferences.currency,
                rate: rateFor(c.preferences.rates, c.preferences.currency),
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
    final name = Text(
      row.name,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      style: p
          .text(narrow ? 16 : 13, null, FontWeight.w500)
          .copyWith(height: 1.5),
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

  Widget tableContent(({String kind, Object data})? snapshot) {
    final data = snapshot?.data;
    final detail = d, dim = snapshot?.kind ?? detail['dim']!;
    final nameFlex = dim == 'model'
        ? 30
        : dim == 'project'
        ? 22
        : dim == 'tool'
        ? 26
        : 16;
    final rows = detailRows(
      dim,
      data,
      detail,
      now: c.clock(),
      strings: context.strings,
    );
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
    final selectedSort = sortKey ?? (dim == 'date' ? 'name' : 'v');
    num value(DetailRow r) => switch (selectedSort) {
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

    Widget requests(DetailRow r, {bool label = false}) => Text(
      r.requestCount == null
          ? context.strings.notLogged
          : '${toDisplayNumber(r.requestCount)}${label ? context.strings.requestCountSuffix(r.requestCount!) : ''}',
      style: p.text(13, p.secondary),
    );
    Widget average(DetailRow r) => r.requestCount == null
        ? Text(context.strings.notLogged, style: p.text(13, p.muted))
        : token(
            r.requestCount! > 0 && r.eventGrossTokens != null
                ? (r.eventGrossTokens! / r.requestCount!).round()
                : null,
          );
    Widget row(DetailRow r, {bool compact = false}) {
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
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          context.strings.estimatedCostPrefix,
                                          style: p.text(12.5, p.secondary),
                                        ),
                                        money(r.costMicros),
                                      ],
                                    ),
                                    requests(r, label: true),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          context
                                              .strings
                                              .averagePerRequestPrefix,
                                          style: p.text(12.5, p.secondary),
                                        ),
                                        average(r),
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
                                Expanded(
                                  flex: 10,
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: money(r.costMicros),
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
                                for (final child in [requests(r), average(r)])
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
    Widget compactTable() => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
          child: Row(
            children: [
              FilterPick(
                key: const Key('detail-sort'),
                label: context.strings.sortBy0(sortOptions[selectedSort]),
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
              Container(
                height: 30,
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: p.smallShadow,
                ),
                child: LensFocusOutline(
                  child: IconButton(
                    tooltip: sortDir < 0
                        ? context.strings.highestFirst
                        : context.strings.lowestFirst,
                    onPressed: () => setState(() {
                      sortKey = selectedSort;
                      sortDir = -sortDir;
                    }),
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    icon: Icon(
                      sortDir < 0 ? Icons.south : Icons.north,
                      size: 16,
                      color: p.secondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        for (final r in rows) row(r, compact: true),
      ],
    );
    return Column(
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
        else if (narrow)
          compactTable()
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: LayoutBuilder(
              builder: (context, box) {
                if (box.maxWidth < 860) {
                  return compactTable();
                }
                return SizedBox(
                  child: SizedBox(
                    width: box.maxWidth,
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
                              header(
                                context.strings.avgPerRequest,
                                'average',
                                12,
                              ),
                            ],
                          ),
                        ),
                        ...rows.map(row),
                      ],
                    ),
                  ),
                );
              },
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
  }

  @override
  Widget build(BuildContext context) {
    final controls = Wrap(
      spacing: 10,
      runSpacing: 10,
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
    return Column(
      spacing: narrow ? 12 : 16,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c.fullSyncRunning || c.syncReceipt != null)
          StatsSyncBanner(controller: c, onSources: widget.onSources),
        LayoutBuilder(
          builder: (context, box) {
            final title = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatsSyncTitle(
                  controller: c,
                  title: Text(
                    context.strings.breakdown,
                    style: p
                        .serif(narrow ? 24 : 28, weight: FontWeight.w500)
                        .copyWith(height: 1.25),
                  ),
                ),
                if (c.hiddenTools.isNotEmpty && widget.onManageHidden != null)
                  StatsHiddenNotice(
                    controller: c,
                    onManage: widget.onManageHidden!,
                  ),
                const SizedBox(height: 4),
                Text(
                  context.strings.breakdownDescription(switch (period.period) {
                    'all' => context.strings.periodAllTime,
                    'custom' => context.strings.selectedPeriodInSentence,
                    _ =>
                      context.strings.isChinese
                          ? period.labelFor(context.strings)
                          : period.labelFor(context.strings).toLowerCase(),
                  }),
                  style: p.text(14, p.secondary),
                ),
              ],
            );
            return box.maxWidth >= 760
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: title),
                      const SizedBox(width: 24),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: box.maxWidth - 420 - 24,
                        ),
                        child: Align(
                          alignment: Alignment.topRight,
                          child: controls,
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [title, const SizedBox(height: 12), controls],
                  );
          },
        ),
        ResourceBlock(resource: options, rows: 1, builder: filters),
        LensCard(
          child: ResourceBlock(resource: summary, rows: 2, builder: strip),
        ),
        LensCard(
          child: ResourceBlock(resource: trend, rows: 6, builder: trendContent),
        ),
        LensCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              head(
                context.strings.breakdown2,
                dim == 'request'
                    ? context.strings.oneRowPerRequestSelectARow
                    : filtered
                    ? context.strings.alreadyFilteredByThisFieldTryAnother
                    : context.strings.selectARowToAddItTo,
                action: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    LensSegmented(
                      options: {
                        'date':
                            trend.data?.axis.granularity == 'hour' &&
                                picked == null
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
                        go({...d, 'dim': v});
                      },
                      label: context.strings.groupBy,
                      small: true,
                    ),
                    if (dim != 'request' && gateway is StatsUsageExporter)
                      exportMenu(gateway as StatsUsageExporter, exportBy),
                  ],
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
                          child: Text(context.strings.openContainingFolder),
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
                        '${period.query}|${d['tool']}|${d['model']}|${d['project']}|${d['bucket']}|${c.ledgerVersion}',
                    filter: c.visibleFilter(
                      StatsFilter(
                        from: picked?.from ?? period.range(c.clock()).from,
                        to: picked?.to ?? period.range(c.clock()).to,
                        source: d['tool']!.isEmpty ? null : d['tool'],
                        model: d['model']!.isEmpty ? null : d['model'],
                        project: d['project']!.isEmpty ? null : d['project'],
                      ),
                    ),
                    onOpen: (r) {
                      final sessionId = r.sessionId;
                      if (sessionId != null) {
                        widget.onSessions?.call({
                          ...Uri.splitQueryString(period.query),
                          'source': r.source,
                          'session': sessionId,
                        });
                      }
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
                  child: ResourceBlock(
                    resource: table,
                    rows: 5,
                    builder: tableContent,
                  ),
                ),
            ],
          ),
        ),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              context.strings.costsAreEstimatesAtEachModelS,
              style: p.text(12, p.muted).copyWith(height: 1.4),
            ),
            LensTextLink(
              label: context.strings.howPricesWork,
              onTap: widget.onSettings,
            ),
          ],
        ),
      ],
    );
  }
}
