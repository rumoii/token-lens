import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../stats_controller.dart';
import '../stats_gateway.dart';
import 'logic/display.dart';
import 'logic/format.dart';
import 'logic/period.dart';
import 'logic/home_data.dart';
import 'logic/tools.dart';
import 'logic/tool_order.dart';
import 'theme/palette.dart';
import 'widgets/filters.dart';
import 'widgets/date_range.dart';
import 'widgets/session_usage.dart';
import 'widgets/primitives.dart';
import 'widgets/resource.dart';
import 'widgets/side_panel.dart';
import 'widgets/timing.dart';

String hm(String iso) => usageTime(iso);

String spanText(String start, String end) {
  final a = DateTime.tryParse(start), b = DateTime.tryParse(end);
  if (a == null || b == null) return '—';
  final minutes = math.max(
    0,
    ((b.difference(a).inMilliseconds) / 60000).round(),
  );
  return minutes < 60 ? '$minutes 分钟' : '${minutes ~/ 60} 小时 ${minutes % 60} 分';
}

String dayName(String iso, DateTime now) => usageDate(iso, now);
String startText(StatsSessionItem row, DateTime now) =>
    '${dayName(row.startedAt, now)} ${hm(row.startedAt)}';

class StatsSessionsPage extends StatefulWidget {
  const StatsSessionsPage({
    super.key,
    required this.controller,
    required this.query,
    required this.onQuery,
    required this.onDetail,
  });
  final StatsController controller;
  final String query;
  final ValueChanged<String> onQuery;
  final ValueChanged<Map<String, String>> onDetail;
  @override
  State<StatsSessionsPage> createState() => _StatsSessionsPageState();
}

class _StatsSessionsPageState extends State<StatsSessionsPage> {
  late final page = LensResource<StatsSessions>(changed);
  late final sources = LensResource<StatsSources>(changed);
  late final projects = LensResource<StatsBreakdown>(changed);
  List<StatsSessionItem> history = [];
  String? cursor, _pageIdentity, _opened;
  bool _panel = false, _navigating = false;
  StatsController get c => widget.controller;
  Map<String, String> get q => Uri.splitQueryString(widget.query);
  StatsPeriod get period => q.containsKey('period')
      ? StatsPeriod.parse(widget.query)
      : c.preferences.period;
  bool get scoped =>
      period.period != 'all' ||
      ['tool', 'project', 'model'].any((key) => q[key]?.isNotEmpty == true);
  String get periodLabel => sessionUsageLabel(period, usageFilter);
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
    schedulePanel();
  }

  @override
  void didUpdateWidget(StatsSessionsPage old) {
    super.didUpdateWidget(old);
    if (old.controller != c) {
      old.controller.removeListener(refresh);
      c.addListener(refresh);
    }
    refresh();
    schedulePanel();
  }

  @override
  void dispose() {
    c.removeListener(refresh);
    page.dispose();
    sources.dispose();
    projects.dispose();
    super.dispose();
  }

  StatsFilter get usageFilter {
    final range = period.range(c.clock()), params = q;
    return StatsFilter(
      from: range.from,
      to: range.to,
      source: params['tool']?.isNotEmpty == true ? params['tool'] : null,
      project: params['project']?.isNotEmpty == true ? params['project'] : null,
      model: params['model']?.isNotEmpty == true ? params['model'] : null,
    );
  }

  int get offsetMinutes =>
      page.data?.snapshot.filters.offsetMinutes ??
      c.clock().timeZoneOffset.inMinutes;

  void refresh() {
    final params = q;
    final identity =
        '${c.ledgerVersion}|${params['tool']}|${params['project']}|${params['model']}|${period.query}|${period.range(c.clock())}';
    if (_pageIdentity != identity) {
      _pageIdentity = identity;
      history = [];
      cursor = null;
    }
    final filter = usageFilter;
    final at = cursor;
    page.read(
      '$identity|$cursor',
      () => c.gateway.sessions(filter, limit: 50, cursor: at),
    );
    sources.read(c.ledgerVersion, () => c.gateway.sources());
    projects.read(
      c.ledgerVersion,
      () => c.gateway.breakdown('project', const StatsFilter()),
    );
  }

  List<StatsSessionItem> get items => [
    ...history,
    if (page.fresh) ...page.data?.items ?? [],
  ];
  String? get nextCursor => page.fresh ? page.data?.nextCursor : null;
  void filter(String key, String value) {
    final next = {...q};
    if (value.isEmpty) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    widget.onQuery(Uri(queryParameters: next).query);
  }

  void schedulePanel() {
    final params = q;
    if (params['source']?.isNotEmpty == true &&
        params['session']?.isNotEmpty == true &&
        !_panel &&
        _opened != '${params['source']}:${params['session']}') {
      _opened = '${params['source']}:${params['session']}';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(open(params['source']!, params['session']!));
      });
    }
  }

  Future<void> open(String source, String sessionId) async {
    if (_panel) return;
    _panel = true;
    final found = items
        .where((r) => r.source == source && r.sessionId == sessionId)
        .firstOrNull;
    PanelHeading headingFor(String? project, String started, String ended) => (
      title:
          projectName(project, peers: items.map((item) => item.projectKey)) ??
          toolOf(source).name,
      hint:
          '${toolOf(source).name} · ${usageDate(started, c.clock())} ${usageTime(started)} 开始 · 持续 ${spanText(started, ended)}',
      tooltip: project,
    );
    final heading = ValueNotifier<PanelHeading>(
      found == null
          ? (title: toolOf(source).name, hint: '正在读取会话…', tooltip: null)
          : headingFor(found.projectKey, found.startedAt, found.lastSeenAt),
    );
    var receiving = true;
    try {
      await showLensPanel(
        context,
        title: heading.value.title,
        hint: heading.value.hint,
        heading: heading,
        icon: ToolTile(source, size: 40),
        body: SessionDetail(
          controller: c,
          source: source,
          sessionId: sessionId,
          onLoaded: (session) {
            if (receiving) {
              heading.value = headingFor(
                session.projectKey,
                session.startedAt,
                session.lastSeenAt,
              );
            }
          },
          period: period,
          filter: usageFilter,
          onDetail: (params) {
            _navigating = true;
            Navigator.pop(context);
            widget.onDetail(params);
          },
        ),
      );
    } finally {
      receiving = false;
      heading.dispose();
    }
    if (!mounted || _navigating) return;
    _panel = false;
    final next = {...q}
      ..remove('source')
      ..remove('session');
    _opened = null;
    widget.onQuery(Uri(queryParameters: next).query);
  }

  Widget money(int? cost) => MoneyText(
    cost == null ? null : microsUsd(cost),
    currency: c.preferences.currency,
    rate: rateFor(c.preferences.rates, c.preferences.currency),
    style: p.text(13, p.secondary),
  );
  Widget filters() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      FilterPick(
        label: '工具',
        options: [
          for (final s in sources.data?.sources ?? <StatsSource>[])
            if (s.records > 0)
              FilterOption(s.source, toolOf(s.source).name, tool: s.source),
        ],
        onPick: (v) => filter('tool', v),
      ),
      FilterPick(
        label: '项目',
        options: [
          for (final g
              in (projects.data?.groups ?? <StatsGroup>[])
                  .where((g) => g.key?.isNotEmpty == true)
                  .toList()
                ..sort((a, b) => b.grossTokens - a.grossTokens))
            FilterOption(
              g.key!,
              projectName(
                    g.key,
                    peers:
                        projects.data?.groups.map((group) => group.key) ?? [],
                  ) ??
                  g.key!,
              tooltip: g.key,
            ),
        ],
        onPick: (v) => filter('project', v),
      ),
      if (q['tool']?.isNotEmpty == true)
        FilterTag(
          label: '工具',
          value: toolOf(q['tool']!).name,
          tool: q['tool'],
          onRemove: () => filter('tool', ''),
        ),
      if (q['project']?.isNotEmpty == true)
        FilterTag(
          label: '项目',
          value: projectName(q['project']) ?? q['project']!,
          onRemove: () => filter('project', ''),
        ),
      if (q['model']?.isNotEmpty == true)
        FilterTag(
          label: '模型',
          value: q['model']!,
          onRemove: () => filter('model', ''),
        ),
    ],
  );
  Widget list() {
    final filter = usageFilter;
    final groupByDate = ![
      filter.from,
      filter.to,
    ].any((value) => value?.isNotEmpty == true);
    final groups = <({String key, List<StatsSessionItem> rows})>[];
    for (final row in items) {
      final day = dayName(row.lastSeenAt, c.clock());
      if (groups.isNotEmpty && groups.last.key == day) {
        groups.last.rows.add(row);
      } else {
        groups.add((key: day, rows: [row]));
      }
    }
    double textWidth(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final labels = scoped
        ? [
            '会话',
            '开始',
            periodLabel,
            '$periodLabel请求',
            '累计',
            '累计请求',
            '$periodLabel约值',
          ]
        : ['会话', '开始', '时长', '用量', '约值', '请求'];
    String nt(int n) => tokenCount(n, unitSystem: c.preferences.unitSystem);
    String requests(int? n, {int? lifetimeCount}) => n == null
        ? requestText(null, lifetimeCount: lifetimeCount)
        : toDisplayNumber(n);
    List<String> values(StatsSessionItem r) => [
      projectName(r.projectKey, peers: items.map((item) => item.projectKey)) ??
          '没有记录项目',
      startText(r, c.clock()),
      if (scoped) ...[
        nt(r.grossTokens),
        requests(r.requestCount, lifetimeCount: r.cumulative.requestCount),
        nt(r.cumulative.grossTokens),
        requests(r.cumulative.requestCount),
      ] else ...[
        spanText(r.startedAt, r.lastSeenAt),
        nt(r.grossTokens),
      ],
      r.costMicros == null
          ? '未定价'
          : usdCurrency(
              microsUsd(r.costMicros!),
              currency: c.preferences.currency,
              rate: rateFor(c.preferences.rates, c.preferences.currency),
            ),
      if (!scoped)
        requests(r.requestCount, lifetimeCount: r.cumulative.requestCount),
    ];
    final preferred = [
      for (final label in labels) textWidth(label, p.text(12)),
    ];
    for (final r in items) {
      final texts = values(r);
      for (var i = 0; i < preferred.length; i++) {
        var width = textWidth(texts[i], p.text(13));
        if (i == 0) {
          width =
              math.max(width, textWidth(toolOf(r.source).name, p.text(12))) +
              38;
          if (sessionStartedBefore(
            r.startedAt,
            period,
            c.clock(),
            offsetMinutes: offsetMinutes,
          )) {
            width += 132;
          }
        }
        preferred[i] = math.max(preferred[i], width);
      }
    }
    for (var i = 0; i < preferred.length; i++) {
      preferred[i] += 20;
    }
    // Match table auto layout: share available width by each column's widest content.
    final total = preferred.reduce((a, b) => a + b);
    var tableWidth = 0.0;
    Widget cell(Widget child, int column, {bool right = true}) => SizedBox(
      width: column == 0
          ? math.min(208, tableWidth * preferred.first / total)
          : (tableWidth - math.min(208, tableWidth * preferred.first / total)) *
                preferred[column] /
                (total - preferred.first),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Align(
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: child,
        ),
      ),
    );
    Widget row(StatsSessionItem r) {
      final title =
          projectName(
            r.projectKey,
            peers: items.map((item) => item.projectKey),
          ) ??
          '没有记录项目';
      final label = '查看会话：$title，${toolOf(r.source).name}';
      final name = Row(
        children: [
          ToolTile(r.source, size: narrow ? 32 : 28),
          SizedBox(width: narrow ? 12 : 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Tooltip(
                      message: r.projectKey ?? title,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: p
                            .text(narrow ? 14 : 13, null, FontWeight.w500)
                            .copyWith(height: 1.5),
                      ),
                    ),
                    if (sessionStartedBefore(
                      r.startedAt,
                      period,
                      c.clock(),
                      offsetMinutes: offsetMinutes,
                    ))
                      SessionStartChip(
                        startedAt: r.startedAt,
                        now: c.clock(),
                        offsetMinutes: offsetMinutes,
                      ),
                  ],
                ),
                Text(
                  toolOf(r.source).name,
                  style: p.text(12, p.muted).copyWith(height: 1.4),
                ),
              ],
            ),
          ),
        ],
      );
      return Semantics(
        label: label,
        button: true,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: narrow ? 8 : 0),
          child: LensFocusOutline(
            child: InkWell(
              key: Key('session-row-${r.source}:${r.sessionId}'),
              onTap: () => unawaited(open(r.source, r.sessionId)),
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  narrow ? 10 : 0,
                  narrow ? 12 : 10,
                  narrow ? 10 : 0,
                  narrow ? 12 : 9,
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
                child: narrow
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: name),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (scoped)
                                    Text(
                                      '$periodLabel ',
                                      style: p.text(12.5, p.secondary),
                                    ),
                                  TokenText(
                                    r.grossTokens,
                                    unitSystem: c.preferences.unitSystem,
                                    style: p.text(14, null, FontWeight.w600),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 44, top: 4),
                            child: Wrap(
                              spacing: 12,
                              children: [
                                Text(
                                  '${startText(r, c.clock())} 开始',
                                  style: p.text(12.5, p.secondary),
                                ),
                                Text(
                                  scoped
                                      ? '累计 ${nt(r.cumulative.grossTokens)} · ${requestText(r.cumulative.requestCount)}'
                                      : spanText(r.startedAt, r.lastSeenAt),
                                  style: p.text(12.5, p.secondary),
                                ),
                                Text(
                                  '${scoped ? '$periodLabel ' : ''}${requestText(r.requestCount, lifetimeCount: r.cumulative.requestCount)}',
                                  style: p.text(12.5, p.secondary),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '${scoped ? periodLabel : ''}约值 ',
                                      style: p.text(12.5, p.secondary),
                                    ),
                                    money(r.costMicros),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          cell(name, 0, right: false),
                          cell(
                            Text(
                              startText(r, c.clock()),
                              style: p.text(13, p.secondary),
                            ),
                            1,
                            right: false,
                          ),
                          for (var i = 2; i < labels.length; i++)
                            cell(
                              i == (scoped ? 6 : 4)
                                  ? money(r.costMicros)
                                  : Text(
                                      values(r)[i],
                                      style: p.text(
                                        13,
                                        (scoped && i == 2 || !scoped && i == 3)
                                            ? null
                                            : p.secondary,
                                        (scoped && i == 2 || !scoped && i == 3)
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                              i,
                            ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      );
    }

    Widget content() => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!narrow)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
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
                for (var i = 0; i < labels.length; i++)
                  cell(
                    Text(
                      labels[i],
                      style: p.text(12, p.muted).copyWith(height: 1.4),
                    ),
                    i,
                    right: i > 1,
                  ),
              ],
            ),
          ),
        if (!groupByDate)
          ...items.map(row)
        else
          for (final g in groups) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(
                narrow ? 22 : 10,
                narrow ? 2 : 16,
                0,
                6,
              ),
              child: Text(
                g.key,
                style: p
                    .text(12, p.muted, FontWeight.w500)
                    .copyWith(height: 1.4),
              ),
            ),
            ...g.rows.map(row),
          ],
      ],
    );
    return narrow
        ? content()
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: LayoutBuilder(
              builder: (context, box) {
                tableWidth = math.max(total, box.maxWidth);
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: tableWidth, child: content()),
                );
              },
            ),
          );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '会话',
          style: p
              .serif(narrow ? 24 : 28, weight: FontWeight.w500)
              .copyWith(height: 1.25),
        ),
        const SizedBox(height: 4),
        Text(
          scoped
              ? period.period == 'all'
                    ? '筛选后的用量，累计是整个会话的总数，不受筛选影响。'
                    : '$periodLabel有用量的会话，按时段内用量排序。累计是整个会话的总数。'
              : '每次打开 AI 工具做的一件事，最近的在最上面。点一个看它用了哪些模型、花在什么时候。',
          style: p.text(14, p.secondary),
        ),
        SizedBox(height: narrow ? 12 : 16),
        Align(
          alignment: Alignment.centerLeft,
          child: PeriodControl(
            period: period,
            now: c.clock(),
            onChanged: (value) {
              final next = {...q}
                ..remove('period')
                ..remove('from')
                ..remove('to');
              next.addAll(Uri.splitQueryString(value.query));
              widget.onQuery(Uri(queryParameters: next).query);
              unawaited(c.setPeriod(value));
            },
          ),
        ),
        const SizedBox(height: 12),
        ResourceBlock(
          resource: projects,
          rows: 1,
          builder: (_) => ResourceBlock(
            resource: sources,
            rows: 1,
            builder: (_) => filters(),
          ),
        ),
        SizedBox(height: narrow ? 12 : 16),
        LensCard(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: page.ready ? 0 : 18),
                child: ResourceBlock(
                  resource: page,
                  rows: 6,
                  builder: (_) => items.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: EmptyState(
                            title: '还没有会话',
                            hint:
                                q['tool']?.isNotEmpty == true ||
                                    q['project']?.isNotEmpty == true
                                ? '换个筛选看看。'
                                : '同步之后，工具记录的每个会话都会出现在这里。',
                          ),
                        )
                      : list(),
                ),
              ),
              if (items.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '已显示 ${items.length} 个会话',
                        style: p.text(12, p.muted).copyWith(height: 1.4),
                      ),
                      if (nextCursor != null)
                        LensButton(
                          label: '加载更多',
                          size: 'sm',
                          onPressed: () {
                            final next = nextCursor;
                            if (next == null) return;
                            setState(() {
                              history = items;
                              cursor = next;
                              refresh();
                            });
                          },
                        )
                      else
                        Text(
                          '已经是全部了',
                          style: p.text(12, p.muted).copyWith(height: 1.4),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        SizedBox(height: narrow ? 12 : 16),
        Text(
          '时段用量按记录发生时间归属；只记录总数的会话算在开始那天，不记录请求数。全部会话按最近活动排序。',
          style: p.text(12, p.muted).copyWith(height: 1.4),
        ),
      ],
    ),
  );
}

class SessionDetail extends StatefulWidget {
  const SessionDetail({
    super.key,
    required this.controller,
    required this.source,
    required this.sessionId,
    required this.onDetail,
    this.period,
    this.onLoaded,
    this.filter,
  });
  final StatsPeriod? period;
  final StatsFilter? filter;
  final StatsController controller;
  final String source, sessionId;
  final ValueChanged<StatsSessionSummary>? onLoaded;
  final ValueChanged<Map<String, String>> onDetail;
  @override
  State<SessionDetail> createState() => _SessionDetailState();
}

class _SessionDetailState extends State<SessionDetail> {
  late final detail = LensResource<StatsSessionDetail?>(changed);
  bool technical = false;
  StatsController get c => widget.controller;
  LensPalette get p => LensPalette.of(context);
  void changed() {
    if (mounted) {
      if (detail.fresh && detail.data != null) {
        widget.onLoaded?.call(detail.data!.session);
      }
      setState(() {});
    }
  }

  StatsPeriod get period => widget.period ?? c.preferences.period;
  String get periodLabel =>
      sessionUsageLabel(period, widget.filter ?? const StatsFilter());
  void refresh() {
    final range = period.range(c.clock());
    final filter = widget.filter ?? StatsFilter(from: range.from, to: range.to);
    detail.read(
      '${widget.source}|${widget.sessionId}|${c.ledgerVersion}|${period.query}|${filter.from}|${filter.to}|${filter.source}|${filter.model}|${filter.project}',
      () => c.gateway.sessionDetail(
        widget.source,
        widget.sessionId,
        'day',
        filter: filter,
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    c.addListener(refresh);
    refresh();
  }

  @override
  void didUpdateWidget(SessionDetail old) {
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
    detail.dispose();
    super.dispose();
  }

  Widget money(int? cost, {String? state, TextStyle? style}) => MoneyText(
    cost == null ? null : microsUsd(cost),
    state: state,
    currency: c.preferences.currency,
    rate: rateFor(c.preferences.rates, c.preferences.currency),
    style: style ?? p.text(13, p.secondary),
  );
  String nt(num n) => tokenCount(n, unitSystem: c.preferences.unitSystem);
  Widget token(num? n, {TextStyle? style}) => TokenText(
    n,
    unitSystem: c.preferences.unitSystem,
    style: style ?? p.text(13, p.secondary),
  );
  Widget card(String title, String? sub, Widget body) => LensCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: p.text(14.5, null, FontWeight.w600)),
              if (sub != null) ...[
                const SizedBox(height: 2),
                Text(sub, style: p.text(12.5, p.muted)),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: body,
        ),
      ],
    ),
  );
  Widget content(StatsSessionDetail? value) {
    if (value == null) {
      return const EmptyState(title: '会话不存在', hint: '这条会话可能已不在账本中。');
    }
    final s = value.session,
        onlyTotals = value.kinds.cumulative > 0 && value.kinds.event == 0;
    final input = value.period != null
        ? value.period!.inputTokens
        : s.inputTokens;
    final cached = value.period != null
        ? value.period!.cacheReadTokens
        : s.cacheReadTokens;
    final cacheBase = input == null || cached == null ? null : input + cached;
    final hit = cacheBase != null && cacheBase > 0 ? cached! / cacheBase : null;
    final days = [...value.timeline]
      ..sort((a, b) => b.bucket.compareTo(a.bucket));
    final peak = days.fold<int>(1, (n, b) => math.max(n, b.grossTokens));
    final start = DateTime.tryParse(s.startedAt)?.toLocal(),
        end = DateTime.tryParse(s.lastSeenAt)?.toLocal();
    final spanDays = start == null || end == null
        ? 1
        : math.max(
            1,
            DateTime.utc(end.year, end.month, end.day)
                    .difference(
                      DateTime.utc(start.year, start.month, start.day),
                    )
                    .inDays +
                1,
          );
    final periodTokens = value.period?.grossTokens ?? s.grossTokens;
    final periodRequests = value.period != null
        ? value.period!.requestCount
        : (onlyTotals ? null : s.requestCount);
    final topModel = value.models.fold<int>(
      1,
      (n, m) => math.max(n, m.grossTokens),
    );
    final kinds = [
      s.inputTokens,
      s.outputTokens,
      s.cacheReadTokens,
      s.cacheWriteTokens,
    ];
    final kindSum = kinds.fold<int>(0, (n, k) => n + (k ?? 0));
    final slots = assignToolColors(
      sourceSequence(c.overview?.sources.sources ?? []),
    );
    Widget mini(String label, Widget v, {Key? key}) => Expanded(
      child: Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            left:
                label == periodLabel ||
                    label == '约值' ||
                    label == '$periodLabel约值'
                ? BorderSide.none
                : BorderSide(
                    width: LensPalette.hairline(context),
                    color: p['line-soft'],
                  ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: p.text(12, p.muted).copyWith(height: 1.4)),
            v,
          ],
        ),
      ),
    );
    Widget timingCard(bool turn) => LensCard(
      padding: const EdgeInsets.all(18),
      child: TimingStrip(
        timing: value.timing,
        turn: turn,
        scopeAsTitle: true,
        requestCount: value.period?.requestCount ?? s.requestCount ?? 0,
        metricKey: (kind) => Key('session-${turn ? 'turn-' : ''}${kind.name}'),
      ),
    );
    Widget bar(double fraction, Color color, {double height = 5}) => ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: height,
        child: LinearProgressIndicator(
          value: fraction,
          color: color,
          backgroundColor: p['fill-hover'],
        ),
      ),
    );
    final children = <Widget>[
      LensCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            mini(
              periodLabel,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  token(
                    periodTokens,
                    style: p.serif(28, weight: FontWeight.w600),
                  ),
                  Text(
                    requestText(periodRequests, lifetimeCount: s.requestCount),
                    style: p.text(12, p.muted),
                  ),
                ],
              ),
            ),
            mini(
              '整个会话累计',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  token(
                    s.grossTokens,
                    style: p.serif(
                      28,
                      color: p.secondary,
                      weight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${requestText(s.requestCount)} · 跨 $spanDays 天',
                    style: p.text(12, p.muted),
                  ),
                  Text('不受筛选影响', style: p.text(11.5, p.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
      if (onlyTotals)
        card(
          '只记录总数',
          null,
          Text(
            '${toolOf(widget.source).name} 只记录每个会话的总数，算在开始那天，没有每次请求的时间，无法按天拆分。',
            style: p.text(13, p.muted),
          ),
        )
      else
        card(
          '按天',
          '这个会话每天用了多少；今天高亮',
          LayoutBuilder(
            builder: (context, box) => SizedBox(
              child: SizedBox(
                width: box.maxWidth,
                child: Column(
                  children: [
                    Row(
                      children: [
                        for (final title in ['日期', '用量', '请求', '平均每次', '约值'])
                          Expanded(
                            flex: title == '日期' ? 3 : 2,
                            child: Text(
                              title,
                              textAlign: title == '日期'
                                  ? TextAlign.left
                                  : TextAlign.right,
                              style: p.text(12, p.muted),
                            ),
                          ),
                      ],
                    ),
                    for (final day in days)
                      Container(
                        key: Key('session-day-${day.bucket}'),
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 2,
                        ),
                        decoration: BoxDecoration(
                          color: day.bucket == dayKey(c.clock())
                              ? p['clay-wash']
                              : null,
                          border: Border(
                            bottom: BorderSide(
                              width: LensPalette.hairline(context),
                              color: p['line-soft'],
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    usageDate(
                                      day.bucket,
                                      c.clock(),
                                      relativeLabel: false,
                                    ),
                                    maxLines: 1,
                                    softWrap: false,
                                    style: p.text(12, p.secondary),
                                  ),
                                  if ([
                                    '今天',
                                    '昨天',
                                  ].contains(usageDate(day.bucket, c.clock())))
                                    Text(
                                      usageDate(day.bucket, c.clock()),
                                      style: p.text(11, p.muted),
                                    ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (box.maxWidth >= 600)
                                    SizedBox(
                                      width: 32,
                                      child: bar(
                                        day.grossTokens / peak,
                                        p['clay'],
                                      ),
                                    ),
                                  if (box.maxWidth >= 600)
                                    const SizedBox(width: 6),
                                  token(day.grossTokens),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                day.requestCount == null
                                    ? requestText(
                                        null,
                                        lifetimeCount: s.requestCount,
                                      )
                                    : toDisplayNumber(day.requestCount),
                                textAlign: TextAlign.right,
                                style: p.text(13, p.secondary),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: day.requestCount == null
                                    ? Text(
                                        requestText(
                                          null,
                                          lifetimeCount: s.requestCount,
                                        ),
                                        style: p.text(12, p.muted),
                                      )
                                    : token(
                                        day.requestCount! > 0 &&
                                                day.eventGrossTokens != null
                                            ? (day.eventGrossTokens! /
                                                      day.requestCount!)
                                                  .round()
                                            : null,
                                      ),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: money(day.costMicros),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (days.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text('没有按天记录', style: p.text(13, p.muted)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      LensCard(
        child: Row(
          children: [
            mini(
              value.period != null ? '$periodLabel约值' : '约值',
              money(
                value.period != null ? value.period!.costMicros : s.costMicros,
                style: p
                    .serif(19, weight: FontWeight.w600)
                    .copyWith(height: 1.5),
              ),
            ),
            if (value.period != null)
              mini(
                '累计约值',
                money(
                  s.costMicros,
                  style: p
                      .serif(19, weight: FontWeight.w600)
                      .copyWith(height: 1.5),
                ),
              ),
            mini(
              value.period != null ? '$periodLabel缓存命中' : '缓存命中',
              Text(
                percentage(hit),
                style: p
                    .serif(19, weight: FontWeight.w600)
                    .copyWith(height: 1.5),
              ),
              key: const Key('session-hit'),
            ),
          ],
        ),
      ),
      if (s.source != 'grok' &&
          ((value.timing?.requestCount ?? 0) > 0 ||
              (value.timing?.turn?.turnCount ?? 0) == 0))
        timingCard(false),
      if (s.source == 'grok' || (value.timing?.turn?.turnCount ?? 0) > 0)
        timingCard(true),
      card(
        '用了哪些模型',
        null,
        Column(
          children: [
            for (var i = 0; i < value.models.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            value.models[i].model ?? '没写模型',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: p.text(13, null, FontWeight.w500),
                          ),
                        ),
                        const SizedBox(width: 8),
                        token(value.models[i].grossTokens),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 64,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: money(
                              value.models[i].costMicros,
                              state: value.models[i].priceState,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    bar(
                      value.models[i].grossTokens / topModel,
                      p.category(slots[widget.source] ?? 0),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      card(
        'token 是怎么构成的',
        '大部分是重复发送的上下文，命中缓存后便宜很多',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (kindSum > 0)
              Semantics(
                label: 'token 构成',
                image: true,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: SizedBox(
                    height: 10,
                    child: Row(
                      children: [
                        for (var i = 0; i < 4; i++)
                          if ((kinds[i] ?? 0) > 0)
                            Expanded(
                              flex: kinds[i]!,
                              child: Container(
                                margin: const EdgeInsets.only(right: 2),
                                color: p.category(i + 1),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                for (var i = 0; i < 4; i++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: p.category(i + 1),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${['新输入', '输出', '读缓存', '写缓存'][i]} ',
                        style: p.text(12, p.secondary).copyWith(height: 1.4),
                      ),
                      token(
                        kinds[i],
                        style: p
                            .text(12, p.secondary, FontWeight.w500)
                            .copyWith(height: 1.4),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (s.projectKey != null)
            LensButton(
              label: '在明细里看 ${projectName(s.projectKey) ?? s.projectKey}',
              icon: Icons.arrow_forward,
              trailingIcon: true,
              size: 'sm',
              onPressed: () =>
                  widget.onDetail({'period': 'all', 'project': s.projectKey!}),
            ),
          LensButton(
            label: '在明细里看 ${toolOf(widget.source).name}',
            icon: Icons.arrow_forward,
            trailingIcon: true,
            size: 'sm',
            onPressed: () => widget.onDetail({
              'period': 'all',
              'tool': widget.source,
              'dim': 'model',
            }),
          ),
        ],
      ),
      Container(
        decoration: BoxDecoration(
          color: p['fill-hover'],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LensFocusOutline(
              child: InkWell(
                onTap: () => setState(() => technical = !technical),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        technical ? Icons.expand_more : Icons.chevron_right,
                        size: 14,
                        color: p.secondary,
                      ),
                      const SizedBox(width: 6),
                      Text('技术细节', style: p.text(13, p.secondary)),
                    ],
                  ),
                ),
              ),
            ),
            if (technical)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: Table(
                  columnWidths: const {
                    0: IntrinsicColumnWidth(),
                    1: FlexColumnWidth(),
                  },
                  children: [
                    for (final row in [
                      ('会话 ID', s.sessionId),
                      ('工作目录', s.projectKey ?? '工具没有写进日志'),
                      (
                        '记录',
                        '${s.recordCount} 条${onlyTotals ? '（这个工具每个会话只写一条总数）' : '，每次请求一条'}',
                      ),
                      ('来源', widget.source),
                    ])
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(
                              right: 14,
                              bottom: 4,
                            ),
                            child: Text(row.$1, style: p.text(12.5, p.muted)),
                          ),
                          SelectableText(
                            row.$2,
                            style: p
                                .text(12, p.secondary)
                                .copyWith(height: 1.4),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          children[i],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ResourceBlock<StatsSessionDetail?>(
    resource: detail,
    rows: 6,
    builder: content,
  );
}
