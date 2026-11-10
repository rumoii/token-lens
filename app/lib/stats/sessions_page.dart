import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../stats_controller.dart';
import '../stats_gateway.dart';
import 'detail_page.dart' show projectName;
import 'logic/format.dart';
import 'logic/home_data.dart';
import 'logic/tools.dart';
import 'logic/tool_order.dart';
import 'theme/palette.dart';
import 'widgets/filters.dart';
import 'widgets/primitives.dart';
import 'widgets/resource.dart';
import 'widgets/side_panel.dart';

String hm(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  return d == null ? '—' : '${d.hour}:${d.minute.toString().padLeft(2, '0')}';
}

String spanText(String start, String end) {
  final a = DateTime.tryParse(start), b = DateTime.tryParse(end);
  if (a == null || b == null) return '—';
  final minutes = math.max(
    0,
    ((b.difference(a).inMilliseconds) / 60000).round(),
  );
  return minutes < 60 ? '$minutes 分钟' : '${minutes ~/ 60} 小时 ${minutes % 60} 分';
}

String dayName(String iso, DateTime now) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '时间未知';
  final days =
      (DateTime(
                now.year,
                now.month,
                now.day,
              ).difference(DateTime(d.year, d.month, d.day)).inMilliseconds /
              86400000)
          .round();
  if (days == 0) return '今天';
  if (days == 1) return '昨天';
  return '${d.month}月${d.day}日 周${'日一二三四五六'[d.weekday % 7]}';
}

String startText(StatsSessionItem row, DateTime now) =>
    dayName(row.startedAt, now) == dayName(row.lastSeenAt, now)
    ? hm(row.startedAt)
    : '${dayName(row.startedAt, now)} ${hm(row.startedAt)}';

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

  void refresh() {
    final params = q;
    final identity =
        '${c.ledgerVersion}|${params['tool']}|${params['project']}';
    if (_pageIdentity != identity) {
      _pageIdentity = identity;
      history = [];
      cursor = null;
    }
    final filter = StatsFilter(
      source: params['tool']?.isNotEmpty == true ? params['tool'] : null,
      project: params['project']?.isNotEmpty == true ? params['project'] : null,
    );
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
    final hint = found == null
        ? toolOf(source).name
        : '${toolOf(source).name} · ${dayName(found.startedAt, c.clock())} ${hm(found.startedAt)}–${hm(found.lastSeenAt)} · ${spanText(found.startedAt, found.lastSeenAt)}';
    await showLensPanel(
      context,
      title: found == null ? '会话详情' : projectName(found.projectKey) ?? '没有记录项目',
      hint: hint,
      icon: ToolTile(source, size: 40),
      body: SessionDetail(
        controller: c,
        source: source,
        sessionId: sessionId,
        onDetail: (params) {
          _navigating = true;
          Navigator.pop(context);
          widget.onDetail(params);
        },
      ),
    );
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
            FilterOption(g.key!, projectName(g.key) ?? g.key!),
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
    ],
  );
  Widget list() {
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

    const labels = ['会话', '开始', '时长', '用量', '约值'];
    final preferred = [
      for (final label in labels) textWidth(label, p.text(12)),
    ];
    for (final r in items) {
      final cost = r.costMicros == null ? null : microsUsd(r.costMicros!);
      final rate = rateFor(c.preferences.rates, c.preferences.currency);
      final converted = cost == null ? null : double.parse(cost) * rate;
      final values = [
        38.0 +
            math.max(
              textWidth(
                projectName(r.projectKey) ?? '没有记录项目',
                p.text(13, null, FontWeight.w500),
              ),
              textWidth(toolOf(r.source).name, p.text(12)),
            ),
        textWidth(startText(r, c.clock()), p.text(13)),
        textWidth(spanText(r.startedAt, r.lastSeenAt), p.text(13)),
        textWidth(
          tokenCount(r.grossTokens, unitSystem: c.preferences.unitSystem),
          p.text(13, null, FontWeight.w600),
        ),
        textWidth(
          cost == null
              ? '未定价'
              : usdCurrency(
                  cost,
                  currency: c.preferences.currency,
                  rate: rate,
                  decimals: converted! > 0 && converted < .01 ? 4 : 2,
                ),
          p.text(13),
        ),
      ];
      for (var i = 0; i < preferred.length; i++) {
        preferred[i] = math.max(preferred[i], values[i]);
      }
    }
    for (var i = 0; i < preferred.length; i++) {
      preferred[i] += 20;
    }
    // Match table auto layout: share available width by each column's widest content.
    final total = preferred.reduce((a, b) => a + b);
    var tableWidth = 0.0;
    Widget cell(Widget child, int column, {bool right = true}) => SizedBox(
      width: tableWidth * preferred[column] / total,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Align(
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: child,
        ),
      ),
    );
    Widget row(StatsSessionItem r) {
      final title = projectName(r.projectKey) ?? '没有记录项目';
      final label = '查看会话：$title，${toolOf(r.source).name}';
      final name = Row(
        children: [
          ToolTile(r.source, size: narrow ? 32 : 28),
          SizedBox(width: narrow ? 12 : 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: p
                      .text(narrow ? 14 : 13, null, FontWeight.w500)
                      .copyWith(height: 1.5),
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
                            TokenText(
                              r.grossTokens,
                              unitSystem: c.preferences.unitSystem,
                              style: p.text(14, null, FontWeight.w600),
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
                                spanText(r.startedAt, r.lastSeenAt),
                                style: p.text(12.5, p.secondary),
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('约值 ', style: p.text(12.5, p.secondary)),
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
                        cell(
                          Text(
                            spanText(r.startedAt, r.lastSeenAt),
                            style: p.text(13, p.secondary),
                          ),
                          2,
                        ),
                        cell(
                          TokenText(
                            r.grossTokens,
                            unitSystem: c.preferences.unitSystem,
                            style: p.text(13, null, FontWeight.w600),
                          ),
                          3,
                        ),
                        cell(money(r.costMicros), 4),
                      ],
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
              border: Border(bottom: BorderSide(color: p['line'])),
            ),
            child: Row(
              children: [
                for (final e in [
                  ('会话', 0, false),
                  ('开始', 1, false),
                  ('时长', 2, true),
                  ('用量', 3, true),
                  ('约值', 4, true),
                ])
                  cell(
                    Text(
                      e.$1,
                      style: p.text(12, p.muted).copyWith(height: 1.4),
                    ),
                    e.$2,
                    right: e.$3,
                  ),
              ],
            ),
          ),
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
              style: p.text(12, p.muted, FontWeight.w500).copyWith(height: 1.4),
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
                tableWidth = box.maxWidth;
                return content();
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
          '每次打开 AI 工具做的一件事，最近的在最上面。点一个看它用了哪些模型、花在什么时候。',
          style: p.text(14, p.secondary),
        ),
        SizedBox(height: narrow ? 12 : 16),
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
          '有些工具（比如 DSH）只记录每个会话的总数，这类会话看不到时间线；会话按最后一次活动的那天分组。',
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
  });
  final StatsController controller;
  final String source, sessionId;
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
    if (mounted) setState(() {});
  }

  void refresh() => detail.read(
    '${widget.source}|${widget.sessionId}|${c.ledgerVersion}',
    () => c.gateway.sessionDetail(widget.source, widget.sessionId, 'hour'),
  );
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
    final cacheBase = s.inputTokens == null || s.cacheReadTokens == null
        ? null
        : s.inputTokens! + s.cacheReadTokens!;
    final hit = cacheBase != null && cacheBase > 0
        ? s.cacheReadTokens! / cacheBase
        : null;
    final peak = value.timeline.fold<int>(
      1,
      (n, b) => math.max(n, b.grossTokens),
    );
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
            left: label == '用量'
                ? BorderSide.none
                : BorderSide(color: p['line-soft']),
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
          children: [
            mini(
              '用量',
              token(
                s.grossTokens,
                style: p
                    .serif(19, weight: FontWeight.w600)
                    .copyWith(height: 1.5),
              ),
            ),
            mini(
              '约值',
              money(
                s.costMicros,
                style: p
                    .serif(19, weight: FontWeight.w600)
                    .copyWith(height: 1.5),
              ),
            ),
            mini(
              '缓存命中',
              Text(
                hit == null ? '—' : '${(hit * 100).round()}%',
                style: p
                    .serif(19, weight: FontWeight.w600)
                    .copyWith(height: 1.5),
              ),
              key: const Key('session-hit'),
            ),
          ],
        ),
      ),
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
        '时间线',
        onlyTotals || value.timeline.isEmpty ? null : '这次会话里每小时用了多少',
        onlyTotals || value.timeline.isEmpty
            ? Text(
                '${toolOf(widget.source).name} 只记录每个会话的总数，没有每次请求的时间，所以画不出时间线。',
                style: p.text(13, p.muted),
              )
            : Column(
                children: [
                  Semantics(
                    label: '会话时间线',
                    image: true,
                    child: SizedBox(
                      height: 70,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (var i = 0; i < value.timeline.length; i++)
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(left: i == 0 ? 0 : 2),
                                child: Tooltip(
                                  message:
                                      '${int.parse(value.timeline[i].bucket.substring(11, 13))}:00 · ${nt(value.timeline[i].grossTokens)} token',
                                  child: Container(
                                    height: math.max(
                                      4.2,
                                      value.timeline[i].grossTokens / peak * 70,
                                    ),
                                    decoration: BoxDecoration(
                                      color: p['clay'].withValues(alpha: .85),
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(3),
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
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(hm(s.startedAt), style: p.text(11, p.faint)),
                      Text(hm(s.lastSeenAt), style: p.text(11, p.faint)),
                    ],
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
            InkWell(
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
