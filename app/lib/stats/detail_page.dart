import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../stats_controller.dart';
import '../stats_gateway.dart';
import 'logic/detail_query.dart';
import 'logic/period.dart';
import 'logic/format.dart';
import 'logic/home_data.dart';
import 'logic/tool_order.dart';
import 'logic/tools.dart';
import 'theme/palette.dart';
import 'widgets/primitives.dart';
import 'widgets/charts.dart';
import 'widgets/date_range.dart';
import 'widgets/filters.dart';
import 'widgets/resource.dart';

String? projectName(String? key) {
  final parts = key
      ?.split(RegExp(r'[\\/]'))
      .where((s) => s.isNotEmpty)
      .toList();
  return parts == null || parts.isEmpty ? null : parts.last;
}

String bucketText(String bucket) {
  if (bucket.contains('T')) return '${int.parse(bucket.substring(11, 13))}:00';
  if (bucket.length == 7) {
    return '${int.parse(bucket.substring(0, 4))}年${int.parse(bucket.substring(5, 7))}月';
  }
  final date = DateTime.parse(bucket);
  return '${date.month}月${date.day}日 周${'日一二三四五六'[date.weekday % 7]}';
}

class DetailRow {
  DetailRow({
    required this.id,
    required this.name,
    required this.tokens,
    required this.kinds,
    this.costMicros,
    this.sub,
    this.drill,
    this.tools = const [],
  });
  final String id, name;
  final int tokens;
  final List<int?> kinds;
  final int? costMicros;
  final String? sub;
  final (String, String)? drill;
  final List<String> tools;
}

List<DetailRow> detailRows(
  String dim,
  Object? data,
  Map<String, String> detail,
) {
  if (data is StatsTimeseries) {
    return [
      for (final r in data.points)
        if (r.grossTokens > 0)
          DetailRow(
            id: r.bucket,
            name: bucketText(r.bucket),
            tokens: r.grossTokens,
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
          int? cost;
          var tokens = 0;
          final tools = <String>{};
          for (final g in e.value) {
            tokens += g.grossTokens;
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
            name: e.key ?? '没写模型',
            tokens: tokens,
            kinds: kinds,
            costMicros: cost,
            tools: tools.toList(),
            sub: tools.map((id) => toolOf(id).name).join('、'),
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
            : projectName(g.key) ?? '没有记录项目',
        sub: dim == 'project' ? g.key ?? '工具没有写工作目录' : null,
        tokens: g.grossTokens,
        kinds: [
          g.inputTokens,
          g.outputTokens,
          g.cacheReadTokens,
          g.cacheWriteTokens,
        ],
        costMicros: g.costMicros,
        tools: dim == 'tool' ? [g.key ?? ''] : [],
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
  });
  final StatsController controller;
  final String query;
  final ValueChanged<String> onQuery;
  final VoidCallback onHome, onSettings;
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
  StatsController get c => widget.controller;
  Map<String, String> get d => readDetail(widget.query);
  StatsPeriod get period => StatsPeriod.parse(widget.query);
  LensPalette get p => LensPalette.of(context);
  bool get narrow => MediaQuery.sizeOf(context).width < 768;
  void changed() {
    if (mounted) setState(() {});
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
    super.dispose();
  }

  void refresh() {
    final detail = d, current = period, now = c.clock();
    final range = current.range(now);
    final base = StatsFilter(from: range.from, to: range.to);
    final picked = bucketRange(detail['bucket']!, range);
    final filter = StatsFilter(
      from: range.from,
      to: range.to,
      source: detail['tool']!.isEmpty ? null : detail['tool'],
      model: detail['model']!.isEmpty ? null : detail['model'],
      project: detail['project']!.isEmpty ? null : detail['project'],
    );
    final scoped = StatsFilter(
      from: picked?.from ?? range.from,
      to: picked?.to ?? range.to,
      source: filter.source,
      model: filter.model,
      project: filter.project,
    );
    final pk =
        '${current.query}|${filter.source}|${filter.model}|${filter.project}|${c.ledgerVersion}';
    final sk =
        '$pk|${picked != null || detail['bucket']!.contains('T') ? detail['bucket'] : ''}';
    Future<PeriodAxis> axis() async => current.axis(
      now,
      current.period == 'all'
          ? (await c.gateway.summary(base)).activity.firstSeen
          : null,
    );
    options.read(
      '${current.query}|${c.ledgerVersion}',
      () => Future.wait([
        c.gateway.breakdown('source_model', base),
        c.gateway.breakdown('project', base),
      ]),
    );
    summary.read(sk, () => c.gateway.summary(scoped));
    trend.read(pk, () async {
      final a = await axis();
      return (
        axis: a,
        data: await c.gateway.matrix(a.granularity, 'source', filter),
      );
    });
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
    });
  }

  void go(Map<String, String> next, [StatsPeriod? value]) =>
      widget.onQuery(detailSearch(value ?? period, next));
  void setFilter(String key, String value) => go({
    ...d,
    key: value,
    'dim': value.isNotEmpty ? nextDim(key) : d['dim']!,
  });
  Widget token(num? v, {TextStyle? style}) => TokenText(
    v,
    unitSystem: c.preferences.unitSystem,
    style: style ?? p.text(13, p.secondary),
  );
  Widget money(int? micros, {TextStyle? style}) => MoneyText(
    micros == null ? null : microsUsd(micros),
    currency: c.preferences.currency,
    rate: rateFor(defaultRates, c.preferences.currency),
    style: style ?? p.text(13),
  );
  Widget head(String title, String sub, {Widget? action}) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
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
          label: '工具',
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
          unitSystem: c.preferences.unitSystem,
        ),
        FilterPick(
          label: '模型',
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
          unitSystem: c.preferences.unitSystem,
        ),
        FilterPick(
          label: '项目',
          options: [
            for (final g in ps)
              FilterOption(
                g.key!,
                projectName(g.key) ?? g.key!,
                tokens: g.grossTokens,
              ),
          ],
          onPick: (v) => setFilter('project', v),
          unitSystem: c.preferences.unitSystem,
        ),
        for (final k in tags)
          FilterTag(
            label: const {
              'tool': '工具',
              'model': '模型',
              'project': '项目',
              'bucket': '时间',
            }[k]!,
            value: k == 'bucket'
                ? bucketText(detail[k]!)
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
            label: '清除筛选',
            size: 'link',
            variant: 'ghost',
            onPressed: () => go({'dim': detail['dim']!}),
          )
        else
          Text('从首页点工具、模型或柱子进来，会自动带上筛选', style: p.text(12.5, p.muted)),
      ],
    );
  }

  Widget strip(StatsSummary? data) {
    final cells = [
      (
        '用量',
        token(
          data?.totals.grossTokens,
          style: p.serif(22, weight: FontWeight.w600).copyWith(height: 1.5),
        ),
        'token',
      ),
      (
        '约值',
        money(
          data?.totals.costMicros,
          style: p.serif(22, weight: FontWeight.w600).copyWith(height: 1.5),
        ),
        '按公开价估算',
      ),
      (
        '会话',
        Text(
          '${data?.activity.sessions ?? 0}',
          style: p.serif(22, weight: FontWeight.w600).copyWith(height: 1.5),
        ),
        '这段时间里有用量的',
      ),
      (
        '缓存命中',
        Text(
          data?.activity.cacheHitRatio == null
              ? '—'
              : '${(data!.activity.cacheHitRatio! * 100).round()}%',
          style: p.serif(22, weight: FontWeight.w600).copyWith(height: 1.5),
        ),
        '输入里走缓存的比例',
      ),
    ];
    final columns = narrow ? 2 : 4;
    return Wrap(
      children: [
        for (var i = 0; i < 4; i++)
          FractionallySizedBox(
            widthFactor: 1 / columns,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                border: Border(
                  left: i % columns > 0
                      ? BorderSide(color: p['line-soft'])
                      : BorderSide.none,
                  top: i >= columns
                      ? BorderSide(color: p['line-soft'])
                      : BorderSide.none,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(cells[i].$1, style: p.text(12.5, p.muted)),
                      if (i == 3) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: '读缓存 ÷（新输入 + 读缓存）。越高越省钱。',
                          child: Container(
                            width: 15,
                            height: 15,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              border: Border.all(color: p['line-strong']),
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
    final sequence = sourceSequence(c.overview?.sources.sources ?? []),
        slots = assignToolColors(sequence);
    final order = sortByToolOrder(
      buckets
          .expand((b) => b.by.keys)
          .toSet()
          .where((id) => buckets.any((b) => (b.by[id] ?? 0) > 0))
          .toList(),
      sequence,
    );
    final unit = const {
      'hour': '小时',
      'day': '天',
      'month': '月',
    }[value.axis.granularity]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        head(
          '趋势',
          '每$unit用了多少，颜色代表工具${value.axis.granularity != 'hour' ? '。点柱子只看那$unit' : ''}',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
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
                unitSystem: c.preferences.unitSystem,
                currency: c.preferences.currency,
                rate: rateFor(defaultRates, c.preferences.currency),
              ),
              if ((value.data.unallocated?.grossTokens ?? 0) > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '另有 ${tokenCount(value.data.unallocated!.grossTokens, unitSystem: c.preferences.unitSystem)} token 来自跨$unit的会话快照，不在图里；上面的用量已经算上了。',
                    style: p.text(12.5, p.muted),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget rowName(DetailRow row) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final id in row.tools) ...[
        ToolTile(id, size: d['dim'] == 'tool' ? 24 : 16),
        const SizedBox(width: 8),
      ],
      Flexible(
        child: Text(
          row.name,
          overflow: TextOverflow.ellipsis,
          style: p
              .text(narrow ? 16 : 13, null, FontWeight.w500)
              .copyWith(height: 1.5),
        ),
      ),
    ],
  );
  Widget tableContent(({String kind, Object data})? snapshot) {
    final data = snapshot?.data;
    final detail = d, dim = snapshot?.kind ?? detail['dim']!;
    final nameFlex = dim == 'model'
        ? 30
        : dim == 'project'
        ? 22
        : dim == 'tool'
        ? 20
        : 16;
    final rows = detailRows(dim, data, detail);
    num value(DetailRow r) => sortKey == 'cost'
        ? r.costMicros ?? -1
        : sortKey?.startsWith('k') == true
        ? r.kinds[int.parse(sortKey!.substring(1))] ?? -1
        : r.tokens;
    rows.sort(
      (a, b) => sortKey != null
          ? value(a).compareTo(value(b)) * sortDir
          : dim == 'date'
          ? b.id.compareTo(a.id)
          : b.tokens - a.tokens,
    );
    final sum = rows.fold<int>(0, (s, r) => s + r.tokens);
    double share(DetailRow r) => sum == 0 ? 0 : r.tokens / sum;
    String percent(DetailRow r) =>
        '${(share(r) * 100).toStringAsFixed(share(r) < .1 ? 1 : 0)}%';
    void open(DetailRow r) {
      if (r.drill != null) setFilter(r.drill!.$1, r.drill!.$2);
    }

    Widget row(DetailRow r) {
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
          padding: EdgeInsets.symmetric(horizontal: narrow ? 8 : 0),
          child: InkWell(
            key: Key('detail-row-${r.id}'),
            onTap: r.drill == null ? null : () => open(r),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: narrow ? 12 : 10,
              ),
              decoration: BoxDecoration(
                border: Border(
                  bottom: narrow
                      ? BorderSide.none
                      : BorderSide(color: p['line-soft']),
                ),
              ),
              child: narrow
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
                                Text('约值 ', style: p.text(12.5, p.secondary)),
                                money(r.costMicros),
                              ],
                            ),
                            Text(
                              '占 ${percent(r)}',
                              style: p.text(12.5, p.secondary),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('读缓存 ', style: p.text(12.5, p.secondary)),
                                token(r.kinds[2]),
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
                                  borderRadius: BorderRadius.circular(99),
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
                      ],
                    ),
            ),
          ),
        ),
      );
    }

    Widget header(String text, String? key, int flex) => Expanded(
      flex: flex,
      child: InkWell(
        onTap: key == null
            ? null
            : () => setState(() {
                sortDir = sortKey == key ? -sortDir : -1;
                sortKey = key;
              }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            '$text${sortKey == key && key != null
                ? sortDir > 0
                      ? ' ↑'
                      : ' ↓'
                : ''}',
            textAlign: key == null && text != '占比'
                ? TextAlign.left
                : TextAlign.right,
            style: p.text(12, p.muted).copyWith(height: 1.4),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 18),
            child: Text(
              '这段时间没有符合筛选的用量。',
              textAlign: TextAlign.center,
              style: p.text(14, p.muted),
            ),
          )
        else if (narrow)
          ...rows.map(row)
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(620, box.maxWidth),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            header(
                              const {
                                'date': '时间',
                                'tool': '工具',
                                'model': '模型',
                                'project': '项目',
                              }[dim]!,
                              null,
                              nameFlex,
                            ),
                            header('用量', 'v', 10),
                            header('约值', 'cost', 10),
                            header('占比', null, 20),
                            for (var i = 0; i < 4; i++)
                              header(['新输入', '输出', '读缓存', '写缓存'][i], 'k$i', 11),
                          ],
                        ),
                      ),
                      ...rows.map(row),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (data is StatsTimeseries && (data.unallocated?.grossTokens ?? 0) > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            child: Text(
              '另有 ${tokenCount(data.unallocated!.grossTokens, unitSystem: c.preferences.unitSystem)} token 来自跨${const {'hour': '小时', 'day': '天', 'month': '月'}[trend.data?.axis.granularity] ?? '天'}的会话快照，没法按${const {'hour': '小时', 'day': '天', 'month': '月'}[trend.data?.axis.granularity] ?? '天'}拆开，不在这张表里；上面的用量已经算上了。',
              style: p.text(12.5, p.muted),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
          child: Text(
            '新输入：这次新发给模型的内容 · 输出：模型写回来的 · 读缓存：重复发送、命中缓存的上下文，便宜很多 · 写缓存：第一次写进缓存的内容。四类互不重叠，加起来就是用量。',
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
          options: const {'overview': '概览', 'detail': '明细'},
          value: 'detail',
          onChanged: (v) {
            if (v == 'overview') widget.onHome();
          },
          label: '视图',
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
    final filtered = dim == 'date'
        ? d['bucket']!.isNotEmpty
        : d[dim]!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final title = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '明细',
                  style: p
                      .serif(narrow ? 24 : 28, weight: FontWeight.w500)
                      .copyWith(height: 1.25),
                ),
                const SizedBox(height: 4),
                Text(
                  '${period.label == '全部'
                      ? '全部时间'
                      : period.label == '自定义'
                      ? '这段时间'
                      : period.label}的用量，按工具、模型、项目和时间拆开看。',
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
                      controls,
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [title, const SizedBox(height: 12), controls],
                  );
          },
        ),
        const SizedBox(height: 4),
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
                '拆开看',
                filtered ? '已经按这一项筛选了，换个拆法看看' : '点一行，把它加进筛选',
                action: LensSegmented(
                  options: {
                    'date':
                        trend.data?.axis.granularity == 'hour' && picked == null
                        ? '按小时'
                        : '按时间',
                    'tool': '按工具',
                    'model': '按模型',
                    'project': '按项目',
                  },
                  value: dim,
                  onChanged: (v) {
                    setState(() {
                      sortKey = null;
                      sortDir = -1;
                    });
                    go({...d, 'dim': v});
                  },
                  label: '拆分方式',
                  small: true,
                ),
              ),
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
              '金额按各模型的公开标准价估算，用来比较和感知，不是你的账单。 ',
              style: p.text(12, p.muted).copyWith(height: 1.4),
            ),
            LensTextLink(label: '价格怎么算', onTap: widget.onSettings),
          ],
        ),
      ],
    );
  }
}
