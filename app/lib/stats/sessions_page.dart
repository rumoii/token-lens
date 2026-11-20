import '../l10n/app_strings.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
import 'widgets/empty_ledger.dart';
import 'widgets/session_usage.dart';
import 'widgets/primitives.dart';
import 'widgets/sync_status.dart';
import 'widgets/resource.dart';
import 'widgets/side_panel.dart';
import 'widgets/timing.dart';
import 'widgets/request_log.dart';

String hm(String iso) => usageTime(iso);

String spanText(
  String start,
  String end, [
  AppStrings strings = chineseStrings,
]) {
  final a = DateTime.tryParse(start), b = DateTime.tryParse(end);
  if (a == null || b == null) return '—';
  final elapsed = b.difference(a);
  if (elapsed.inDays > 0) {
    return strings.daysAndHoursDuration(elapsed.inDays, elapsed.inHours % 24);
  }
  final minutes = math.max(0, (elapsed.inMilliseconds / 60000).round());
  return minutes < 60
      ? strings.minutesDuration(minutes)
      : strings.hoursAndMinutesDuration(minutes ~/ 60, minutes % 60);
}

String dayName(
  String iso,
  DateTime now, [
  AppStrings strings = chineseStrings,
]) => usageDate(iso, now, strings: strings);
String startText(
  StatsSessionItem row,
  DateTime now, [
  AppStrings strings = chineseStrings,
]) => '${dayName(row.startedAt, now, strings)} ${hm(row.startedAt)}';

class StatsSessionsPage extends StatefulWidget {
  const StatsSessionsPage({
    super.key,
    required this.controller,
    required this.query,
    required this.onQuery,
    required this.onDetail,
    this.onSources,
    this.onManageHidden,
  });
  final StatsController controller;
  final String query;
  final ValueChanged<String> onQuery;
  final ValueChanged<Map<String, String>> onDetail;
  final VoidCallback? onSources, onManageHidden;
  @override
  State<StatsSessionsPage> createState() => _StatsSessionsPageState();
}

class _StatsSessionsPageState extends State<StatsSessionsPage> {
  late final page = LensResource<StatsSessions>(changed);
  late final sources = LensResource<StatsSources>(changed);
  late final projects = LensResource<StatsBreakdown>(changed);
  late final models = LensResource<StatsBreakdown>(changed);
  late final search = TextEditingController(text: q['q'] ?? '');
  Timer? searchDelay;
  List<StatsSessionItem> history = [];
  String? cursor, _pageIdentity, _opened;
  bool _panel = false, _navigating = false;
  StatsController get c => widget.controller;
  Map<String, String> get q =>
      c.visibleQuery(Uri.splitQueryString(widget.query));
  static const sortKeys = ['tokens', 'cost', 'started', 'recent', 'requests'];
  String get sort => sortKeys.contains(q['sort']) ? q['sort']! : 'tokens';
  String get dir => q['dir'] == 'asc' ? 'asc' : 'desc';
  String _scope = '';
  StatsPeriod get period => q.containsKey('period')
      ? StatsPeriod.parse(widget.query)
            .withWeekStart(c.preferences.weekStartsOn)
      : c.period;
  bool get scoped =>
      period.period != 'all' ||
      ['tool', 'project', 'model'].any((key) => q[key]?.isNotEmpty == true);
  String get periodLabel =>
      sessionUsageLabel(period, usageFilter, context.strings);
  String get usageLabel => context.strings.periodUsage(periodLabel);
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
    if (Uri.splitQueryString(old.query)['q'] != q['q']) {
      searchDelay?.cancel();
      final value = q['q'] ?? '';
      if (search.text != value) search.text = value;
    }
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
    searchDelay?.cancel();
    search.dispose();
    page.dispose();
    sources.dispose();
    projects.dispose();
    models.dispose();
    super.dispose();
  }

  StatsFilter get usageFilter {
    final range = period.range(c.clock()), params = q;
    return c.visibleFilter(
      StatsFilter(
        from: range.from,
        to: range.to,
        source: params['tool']?.isNotEmpty == true ? params['tool'] : null,
        project: params['project']?.isNotEmpty == true
            ? params['project']
            : null,
        model: params['model']?.isNotEmpty == true ? params['model'] : null,
      ),
    );
  }

  int get offsetMinutes =>
      page.data?.snapshot.filters.offsetMinutes ??
      c.clock().timeZoneOffset.inMinutes;

  void refresh() {
    final params = q;
    final scope = c.hiddenScope;
    final retainData = scope == _scope;
    _scope = scope;
    final query = params['q']?.trim();
    final identity =
        '${c.ledgerVersion}|${params['tool']}|${params['project']}|${params['model']}|${period.query}|${period.range(c.clock())}|$scope|${Uri.encodeComponent(query ?? '')}|$sort|$dir';
    if (_pageIdentity != identity) {
      _pageIdentity = identity;
      history = [];
      cursor = null;
    }
    final filter = usageFilter;
    final at = cursor;
    final gateway = c.gateway;
    final queryGateway = gateway.sessionQueryGateway;
    final options = StatsSessionQuery(
      q: query,
      sort: sort,
      dir: dir,
      limit: 50,
      cursor: at,
    );
    page.read(
      '$identity|$cursor',
      () =>
          queryGateway?.querySessions(filter, options) ??
          gateway.sessions(filter, limit: 50, cursor: at),
      retainData: retainData,
    );
    sources.read(c.ledgerVersion, () => c.gateway.sources());
    projects.read(
      (c.ledgerVersion, scope),
      () =>
          c.gateway.breakdown('project', c.visibleFilter(const StatsFilter())),
      retainData: retainData,
    );
    models.read(
      (c.ledgerVersion, scope),
      () => gateway.breakdown('model', c.visibleFilter(const StatsFilter())),
      retainData: retainData,
    );
  }

  List<StatsSessionItem> get items => [
    ...history,
    if (page.fresh) ...page.data?.items ?? [],
  ];
  Map<String, Color> toolColors() => assignToolColors(
    items.map((item) => (item.source, item.grossTokens)),
    LensPalette.of(context),
  );

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

  void orderBy(String key, {bool reverseCurrent = false}) {
    final direction = key == sort && reverseCurrent
        ? (dir == 'desc' ? 'asc' : 'desc')
        : key == sort
        ? dir
        : 'desc';
    widget.onQuery(
      Uri(queryParameters: {...q, 'sort': key, 'dir': direction}).query,
    );
  }

  Map<String, String> sortLabels(AppStrings strings) => {
    'tokens': usageLabel,
    'cost': strings.sessionSortCost,
    'started': strings.sessionSortStarted,
    'recent': strings.sessionSortRecent,
    'requests': strings.sessionSortRequests,
  };

  String sortInSentence(AppStrings strings) => switch (sort) {
    'cost' => strings.sessionSortCostInSentence,
    'started' => strings.sessionSortStartedInSentence,
    'recent' => strings.sessionSortRecentInSentence,
    'requests' => strings.sessionSortRequestsInSentence,
    _ => strings.sessionSortUsageInSentence(periodLabel),
  };

  Widget searchField() {
    final strings = context.strings;
    final hintWidth = TextPainter.computeWidth(
      text: TextSpan(
        text: strings.sessionSearch,
        style: DefaultTextStyle.of(context).style.merge(p.text(13)),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    return SizedBox(
      width: math.max(
        strings.isChinese ? 250 : 295,
        hintWidth.ceilToDouble() + 76,
      ),
      child: LensInput(
        search: true,
        controller: search,
        hint: strings.sessionSearch,
        clearLabel: strings.clearSessionSearch,
        onChanged: (_) {
          searchDelay?.cancel();
          searchDelay = Timer(const Duration(milliseconds: 250), () {
            filter('q', search.text.trim());
          });
          changed();
        },
        onClear: () {
          searchDelay?.cancel();
          filter('q', '');
        },
      ),
    );
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

  Future<void> open(String source, String sessionId, {Color? listColor}) async {
    if (_panel || c.isHidden(source)) return;
    _panel = true;
    final found = items
        .where((r) => r.source == source && r.sessionId == sessionId)
        .firstOrNull;
    final tool = toolOf(source).name;
    final accent = listColor ?? p.toolBrand(source) ?? p.toolInk(1);
    final fallbackTitle = context.strings.sessionForTool(tool);
    PanelHeading headingFor(String? project, String started, String ended) => (
      title:
          projectName(project, peers: items.map((item) => item.projectKey)) ??
          fallbackTitle,
      hint: context.strings.sessionHeading(
        tool,
        usageDate(started, c.clock(), strings: context.strings),
        usageTime(started),
        spanText(started, ended, context.strings),
      ),
      tooltip: project,
    );
    final heading = ValueNotifier<PanelHeading>(
      found == null
          ? (
              title: fallbackTitle,
              hint: context.strings.loadingSession,
              tooltip: null,
            )
          : headingFor(found.projectKey, found.startedAt, found.lastSeenAt),
    );
    var receiving = true;
    try {
      await showLensPanel(
        context,
        title: heading.value.title,
        hint: heading.value.hint,
        heading: heading,
        icon: ToolTile(source, size: 40, accent: accent),
        body: SessionDetail(
          controller: c,
          source: source,
          sessionId: sessionId,
          toolColor: accent,
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
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      searchField(),
      FilterPick(
        label: context.strings.tool,
        selected: q['tool'],
        selectedLabel: q['tool'] == null ? null : toolOf(q['tool']!).name,
        selectedTool: q['tool'],
        onClear: q['tool'] == null ? null : () => filter('tool', ''),
        options: [
          for (final s in sources.data?.sources ?? <StatsSource>[])
            if (s.records > 0 && !c.isHidden(s.source))
              FilterOption(s.source, toolOf(s.source).name, tool: s.source),
        ],
        onPick: (v) => filter('tool', v),
      ),
      FilterPick(
        label: context.strings.project,
        selected: q['project'],
        selectedLabel: projectName(q['project']) ?? q['project'],
        onClear: q['project'] == null ? null : () => filter('project', ''),
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
      FilterPick(
        label: context.strings.model,
        selected: q['model'],
        selectedLabel: q['model'],
        onClear: q['model'] == null ? null : () => filter('model', ''),
        options: [
          for (final g in models.data?.groups ?? <StatsGroup>[])
            if (g.key?.isNotEmpty == true) FilterOption(g.key!, g.key!),
        ],
        onPick: (v) => filter('model', v),
      ),
      FilterPick(
        key: const Key('sessions-sort'),
        label: sortLabels(context.strings)[sort]!,
        selected: sort,
        searchable: false,
        options: [
          for (final entry in sortLabels(context.strings).entries)
            FilterOption(entry.key, entry.value),
        ],
        onPick: orderBy,
      ),
      LensSortDirection(
        ascending: dir == 'asc',
        onPressed: () => orderBy(sort, reverseCurrent: true),
      ),
    ],
  );
  Widget list() {
    final filter = usageFilter;
    final groupByDate =
        (sort == 'recent' || c.gateway.sessionQueryGateway == null) &&
        ![filter.from, filter.to].any((value) => value?.isNotEmpty == true);
    final groups = <({String key, List<StatsSessionItem> rows})>[];
    for (final row in items) {
      final day = dayName(row.lastSeenAt, c.clock(), context.strings);
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
            context.strings.session,
            context.strings.start,
            usageLabel,
            context.strings.requests0(periodLabel),
            context.strings.total,
            context.strings.totalRequests,
            context.strings.estCost0(periodLabel),
          ]
        : [
            context.strings.session,
            context.strings.start,
            context.strings.duration,
            usageLabel,
            context.strings.estCost,
            context.strings.requests,
          ];
    final columns = scoped
        ? [null, 'started', 'tokens', 'requests', null, null, 'cost']
        : [null, 'started', null, 'tokens', 'cost', 'requests'];
    String recentText(StatsSessionItem row) =>
        '${dayName(row.lastSeenAt, c.clock(), context.strings)} ${hm(row.lastSeenAt)}';
    String nt(int n) => tokenCount(n, unitSystem: c.unitSystem);
    String requests(int? n, {int? lifetimeCount}) => n == null
        ? requestText(
            null,
            strings: context.strings,
            lifetimeCount: lifetimeCount,
          )
        : toDisplayNumber(n);
    List<String> values(StatsSessionItem r) => [
      projectName(r.projectKey, peers: items.map((item) => item.projectKey)) ??
          context.strings.noProjectLogged,
      startText(r, c.clock(), context.strings),
      if (scoped) ...[
        nt(r.grossTokens),
        requests(r.requestCount, lifetimeCount: r.cumulative.requestCount),
        nt(r.cumulative.grossTokens),
        requests(r.cumulative.requestCount),
      ] else ...[
        spanText(r.startedAt, r.lastSeenAt, context.strings),
        nt(r.grossTokens),
      ],
      r.costMicros == null
          ? context.strings.unpriced
          : usdCurrency(
              microsUsd(r.costMicros!),
              currency: c.preferences.currency,
              rate: rateFor(c.preferences.rates, c.preferences.currency),
            ),
      if (!scoped)
        requests(r.requestCount, lifetimeCount: r.cumulative.requestCount),
    ];
    TextStyle valueStyle(int column) {
      final emphasis = column == (scoped ? 2 : 3);
      return p.text(
        13,
        emphasis ? null : p.secondary,
        emphasis ? FontWeight.w600 : FontWeight.w400,
      );
    }

    final titleStyle = p
        .text(narrow ? 14 : 13, null, FontWeight.w500)
        .copyWith(height: 1.5);
    final toolStyle = p.text(12, p.muted).copyWith(height: 1.4);
    final idStyle = toolStyle.copyWith(
      fontFamily: LensPalette.monoFonts.first,
      fontFamilyFallback: LensPalette.monoFonts.skip(1).toList(),
    );
    String shortId(StatsSessionItem row) =>
        row.sessionId.characters.takeLast(8).join();
    final badgeWidth =
        textWidth(
          context.strings.spansPeriod,
          p.text(11, p.secondary, FontWeight.w500),
        ) +
        12;
    bool spansPeriod(StatsSessionItem row) => sessionStartedBefore(
      row.startedAt,
      period,
      c.clock(),
      offsetMinutes: offsetMinutes,
    );

    // Reserve room for complete body values before giving headers extra space.
    final minimum = List.filled(labels.length, 22.0);
    for (final r in items) {
      final texts = values(r);
      for (var i = 0; i < minimum.length; i++) {
        var width = textWidth(texts[i], valueStyle(i));
        if (i == 1) {
          width = math.max(width, textWidth(recentText(r), p.text(12)));
        }
        if (i == 0) {
          width = textWidth(texts[i], titleStyle);
          if (spansPeriod(r)) width += 6 + badgeWidth;
          final metadata =
              textWidth(toolOf(r.source).name, toolStyle) +
              textWidth(' · ', toolStyle) +
              textWidth(shortId(r), idStyle) +
              2;
          width = math.max(width, metadata) + 38;
        }
        minimum[i] = math.max(minimum[i], width.ceilToDouble());
      }
    }
    final firstWidth = (minimum[0] + 20).clamp(208.0, 280.0);
    minimum[0] = math.min(firstWidth - 20, minimum[0]);
    final preferred = [
      for (final (column, label) in labels.indexed)
        math.max(
          minimum[column],
          textWidth(label, p.text(12)) + (columns[column] == sort ? 10 : 0),
        ),
    ];
    preferred[1] = math.max(
      preferred[1],
      textWidth(context.strings.sessionSortRecent, p.text(12)) +
          (sort == 'recent' ? 10 : 0),
    );
    final minimumTotal = minimum.reduce((a, b) => a + b);
    final preferredTotal = preferred.reduce((a, b) => a + b);
    var columnWidths = minimum;
    var cellInset = 10.0;
    Widget cell(Widget child, int column, {bool right = true}) => SizedBox(
      width: columnWidths[column] + 2 * cellInset,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: cellInset),
        child: Align(
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: child,
        ),
      ),
    );
    Widget singleLine(Widget child, {bool right = true}) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: right ? Alignment.centerRight : Alignment.centerLeft,
      child: child,
    );
    final colors = toolColors();
    Widget row(StatsSessionItem r) {
      final texts = values(r);
      final title =
          projectName(
            r.projectKey,
            peers: items.map((item) => item.projectKey),
          ) ??
          context.strings.noProjectLogged;
      final label = context.strings.viewSession01(title, toolOf(r.source).name);
      final name = Row(
        children: [
          ToolTile(r.source, size: narrow ? 32 : 28, accent: colors[r.source]),
          SizedBox(width: narrow ? 12 : 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Tooltip(
                        message: r.projectKey ?? title,
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                      ),
                    ),
                    if (spansPeriod(r)) ...[
                      const SizedBox(width: 6),
                      SessionStartChip(
                        startedAt: r.startedAt,
                        now: c.clock(),
                        offsetMinutes: offsetMinutes,
                        showDate: false,
                      ),
                    ],
                  ],
                ),
                Row(
                  children: [
                    Flexible(
                      child: singleLine(
                        Text(
                          toolOf(r.source).name,
                          maxLines: 1,
                          style: toolStyle,
                        ),
                        right: false,
                      ),
                    ),
                    Text(' · ', style: toolStyle),
                    Semantics(
                      button: true,
                      child: Tooltip(
                        message: context.strings.copySessionId,
                        child: LensFocusOutline(
                          child: InkWell(
                            onTap: () async {
                              await Clipboard.setData(
                                ClipboardData(text: r.sessionId),
                              );
                              if (!mounted) return;
                              ScaffoldMessenger.of(context)
                                ..hideCurrentSnackBar()
                                ..showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      context.strings.sessionIdCopied,
                                    ),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                            },
                            child: Text(
                              shortId(r),
                              style: idStyle,
                              maxLines: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
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
              onTap: () => unawaited(
                open(r.source, r.sessionId, listColor: colors[r.source]),
              ),
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  narrow ? 10 : 0,
                  (narrow ? 12 : 10) * c.preferences.spacing,
                  narrow ? 10 : 0,
                  (narrow ? 12 : 9) * c.preferences.spacing,
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
                                    unitSystem: c.unitSystem,
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
                                  context.strings.sessionStartLabel(
                                    startText(r, c.clock(), context.strings),
                                  ),
                                  style: p.text(12.5, p.secondary),
                                ),
                                Text(
                                  scoped
                                      ? context.strings.total01(
                                          nt(r.cumulative.grossTokens),
                                          requestText(
                                            r.cumulative.requestCount,
                                            strings: context.strings,
                                          ),
                                        )
                                      : spanText(
                                          r.startedAt,
                                          r.lastSeenAt,
                                          context.strings,
                                        ),
                                  style: p.text(12.5, p.secondary),
                                ),
                                Text(
                                  '${scoped ? '$periodLabel ' : ''}${requestText(r.requestCount, strings: context.strings, lifetimeCount: r.cumulative.requestCount)}',
                                  style: p.text(12.5, p.secondary),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      context.strings.estCost02(
                                        scoped ? periodLabel : '',
                                      ),
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
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                singleLine(
                                  Text(texts[1], style: valueStyle(1)),
                                  right: false,
                                ),
                                singleLine(
                                  Text(
                                    recentText(r),
                                    style: p.text(12, p.muted),
                                  ),
                                  right: false,
                                ),
                              ],
                            ),
                            1,
                            right: false,
                          ),
                          for (var i = 2; i < labels.length; i++)
                            cell(
                              singleLine(
                                i == (scoped ? 6 : 4)
                                    ? money(r.costMicros)
                                    : Text(texts[i], style: valueStyle(i)),
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

    Widget header(String title, String? key) {
      final selected = key != null && key == sort;
      final text = Text(
        title,
        style: p.text(12, selected ? p.ink : p.muted).copyWith(height: 1.4),
      );
      if (key == null) return text;
      return Semantics(
        button: true,
        selected: selected,
        child: LensFocusOutline(
          child: InkWell(
            key: Key('sessions-header-$key'),
            onTap: () => orderBy(key, reverseCurrent: true),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: text),
                if (selected)
                  Icon(
                    dir == 'asc' ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 10,
                  ),
              ],
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
                    i == 1
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              header(labels[i], columns[i]),
                              header(
                                context.strings.sessionSortRecent,
                                'recent',
                              ),
                            ],
                          )
                        : header(labels[i], columns[i]),
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
                final tableWidth = MediaQuery.sizeOf(context).width >= 1024
                    ? box.maxWidth
                    : math.max(
                        preferredTotal + 20 * labels.length,
                        box.maxWidth,
                      );
                cellInset = ((tableWidth - minimumTotal) / (2 * labels.length))
                    .clamp(4, 10);
                final available = tableWidth - 2 * cellInset * labels.length;
                final spare = available - minimumTotal;
                final firstSpare = spare <= 0
                    ? 0.0
                    : math.min(
                        spare * preferred.first / preferredTotal,
                        firstWidth - 2 * cellInset - minimum.first,
                      );
                columnWidths = [
                  for (final (column, required) in minimum.indexed)
                    spare < 0
                        ? required * available / minimumTotal
                        : required +
                              (column == 0
                                  ? firstSpare
                                  : (spare - firstSpare) *
                                        preferred[column] /
                                        (preferredTotal - preferred.first)),
                ];
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: tableWidth, child: content()),
                );
              },
            ),
          );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (c.fullSyncRunning || c.syncReceipt != null) ...[
        StatsSyncBanner(controller: c, onSources: widget.onSources),
        SizedBox(height: narrow ? 12 : 16),
      ],
      LensPageHeader(
        title: StatsSyncTitle(
          controller: c,
          title: Text(
            context.strings.sessions,
            style: p
                .serif(narrow ? 24 : 28, weight: FontWeight.w500)
                .copyWith(height: 1.25),
          ),
        ),
        controls: LensHeaderControls(
          children: [
            if (!c.emptyLedger)
              PeriodControl(
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
          ],
        ),
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
              context.strings.sortedSessions(
                period.isShortcut
                    ? period.inSentence(context.strings)
                    : periodLabel,
                sortInSentence(context.strings),
              ),
              style: p.text(14, p.secondary),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      if (c.emptyLedger)
        EmptyLedgerCard(controller: c, onTools: widget.onSources)
      else
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                padding:
                    const EdgeInsets.fromLTRB(0, 8, 0, 16) *
                    c.preferences.spacing,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: page.ready ? 0 : 18,
                      ),
                      child: ResourceBlock(
                        resource: page,
                        rows: 6,
                        builder: (_) => items.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                ),
                                child: EmptyState(
                                  title: q['q']?.isNotEmpty == true
                                      ? context.strings.noMatchingSessions(
                                          q['q']!,
                                        )
                                      : context.strings.noSessionsYet,
                                  hint: q['q']?.isNotEmpty == true
                                      ? null
                                      : q['tool']?.isNotEmpty == true ||
                                            q['project']?.isNotEmpty == true
                                      ? context.strings.tryAnotherFilter
                                      : context
                                            .strings
                                            .sessionsAppearHereAfterSyncingToolLogs,
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
                              context.strings.showing0Session(items.length),
                              style: p.text(12, p.muted).copyWith(height: 1.4),
                            ),
                            if (nextCursor != null)
                              LensButton(
                                label: context.strings.loadMore,
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
                                context.strings.allSessionsShown,
                                style: p
                                    .text(12, p.muted)
                                    .copyWith(height: 1.4),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(height: narrow ? 12 : 16),
              Text(
                context.strings.usageIsCountedWhenEachRecordOccurred,
                style: p.text(12, p.muted).copyWith(height: 1.4),
              ),
            ],
          ),
        ),
    ],
  );
}

class SessionDetail extends StatefulWidget {
  const SessionDetail({
    super.key,
    required this.controller,
    required this.source,
    required this.sessionId,
    required this.onDetail,
    this.toolColor,
    this.period,
    this.onLoaded,
    this.filter,
  });
  final StatsPeriod? period;
  final StatsFilter? filter;
  final StatsController controller;
  final String source, sessionId;
  final Color? toolColor;
  final ValueChanged<StatsSessionSummary>? onLoaded;
  final ValueChanged<Map<String, String>> onDetail;
  @override
  State<SessionDetail> createState() => _SessionDetailState();
}

class _SessionDetailState extends State<SessionDetail> {
  late final detail = LensResource<StatsSessionDetail?>(changed);
  bool technical = false;
  bool requestsTab = false;
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

  StatsPeriod get period =>
      (widget.period ?? c.period).withWeekStart(c.preferences.weekStartsOn);
  String get periodLabel => sessionUsageLabel(
    period,
    widget.filter ?? const StatsFilter(),
    context.strings,
  );
  void refresh() {
    final range = period.range(c.clock());
    final scope = c.hiddenScope;
    final filter = c.visibleFilter(
      widget.filter ?? StatsFilter(from: range.from, to: range.to),
    );
    if (c.isHidden(widget.source) && widget.onLoaded != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !c.isHidden(widget.source)) return;
        final route = ModalRoute.of(context);
        if (route != null && route is RawDialogRoute && route.isActive) {
          route.navigator?.removeRoute(route);
        }
      });
    }
    detail.read(
      '${widget.source}|${widget.sessionId}|${c.ledgerVersion}|${period.query}|${filter.from}|${filter.to}|${filter.source}|${filter.model}|${filter.project}|$scope',
      () => c.isHidden(widget.source)
          ? Future.value(null)
          : c.gateway.sessionDetail(
              widget.source,
              widget.sessionId,
              'day',
              filter: filter,
            ),
      retainData: !c.isHidden(widget.source),
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
    if (old.source != widget.source || old.sessionId != widget.sessionId) {
      requestsTab = false;
    }
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
  String nt(num n) => tokenCount(n, unitSystem: c.unitSystem);
  Widget token(num? n, {TextStyle? style}) => TokenText(
    n,
    unitSystem: c.unitSystem,
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
          padding:
              const EdgeInsets.fromLTRB(16, 12, 16, 16) * c.preferences.spacing,
          child: body,
        ),
      ],
    ),
  );
  Widget content(StatsSessionDetail? value) {
    if (value == null) {
      return EmptyState(
        title: context.strings.sessionUnavailable,
        hint: context.strings.thisSessionMayNoLongerBeIn,
      );
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
    final modelColor =
        widget.toolColor ?? p.toolBrand(widget.source) ?? p.toolInk(1);
    final kinds = [
      s.inputTokens,
      s.outputTokens,
      s.cacheReadTokens,
      s.cacheWriteTokens,
    ];
    final kindSum = kinds.fold<int>(0, (n, k) => n + (k ?? 0));
    Widget mini(String label, Widget v, {Key? key}) => Expanded(
      child: Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            left:
                label == periodLabel ||
                    label == context.strings.estCost ||
                    label == context.strings.estCost0(periodLabel)
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
                    requestText(
                      periodRequests,
                      strings: context.strings,
                      lifetimeCount: s.requestCount,
                    ),
                    style: p.text(12, p.muted),
                  ),
                ],
              ),
            ),
            mini(
              context.strings.fullSessionTotal,
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
                    context.strings.sessionSpan(
                      requestText(s.requestCount, strings: context.strings),
                      spanDays,
                    ),
                    style: p.text(12, p.muted),
                  ),
                  Text(
                    context.strings.includesAllUsage,
                    style: p.text(11.5, p.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      if (onlyTotals)
        card(
          context.strings.sessionTotalsOnly,
          null,
          Text(
            context.strings.sessionTotalsOnlyForTool(
              toolOf(widget.source).name,
            ),
            style: p.text(13, p.muted),
          ),
        )
      else
        card(
          context.strings.byDay,
          context.strings.dailyUsageForThisSessionTodayIs,
          LayoutBuilder(
            builder: (context, box) => SizedBox(
              child: SizedBox(
                width: box.maxWidth,
                child: Column(
                  children: [
                    Row(
                      children: [
                        for (final title in [
                          context.strings.date,
                          context.strings.usage,
                          context.strings.requests,
                          context.strings.avgPerRequest,
                          context.strings.estCost,
                        ])
                          Expanded(
                            flex: title == context.strings.date ? 3 : 2,
                            child: Text(
                              title,
                              textAlign: title == context.strings.date
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
                                      strings: context.strings,
                                    ),
                                    maxLines: 1,
                                    softWrap: false,
                                    style: p.text(12, p.secondary),
                                  ),
                                  if ([
                                    context.strings.today,
                                    context.strings.yesterday,
                                  ].contains(
                                    usageDate(
                                      day.bucket,
                                      c.clock(),
                                      strings: context.strings,
                                    ),
                                  ))
                                    Text(
                                      usageDate(
                                        day.bucket,
                                        c.clock(),
                                        strings: context.strings,
                                      ),
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
                                        strings: context.strings,
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
                                          strings: context.strings,
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
                        child: Text(
                          context.strings.noDailyRecords,
                          style: p.text(13, p.muted),
                        ),
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
              value.period != null
                  ? context.strings.estCost0(periodLabel)
                  : context.strings.estCost,
              money(
                value.period != null ? value.period!.costMicros : s.costMicros,
                style: p
                    .serif(19, weight: FontWeight.w600)
                    .copyWith(height: 1.5),
              ),
            ),
            if (value.period != null)
              mini(
                context.strings.totalEstCost,
                money(
                  s.costMicros,
                  style: p
                      .serif(19, weight: FontWeight.w600)
                      .copyWith(height: 1.5),
                ),
              ),
            mini(
              value.period != null
                  ? context.strings.cacheHit0(periodLabel)
                  : context.strings.cacheHit,
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
        context.strings.modelsUsed,
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
                            value.models[i].model ??
                                context.strings.modelNotLogged,
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
                    bar(value.models[i].grossTokens / topModel, modelColor),
                  ],
                ),
              ),
          ],
        ),
      ),
      card(
        context.strings.whereTheTokensWent,
        context.strings.mostTokensAreReusedContextWhichCosts,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (kindSum > 0)
              Semantics(
                label: context.strings.tokenBreakdown,
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
                        '${[context.strings.newInput, context.strings.output, context.strings.cacheRead, context.strings.cacheWrite][i]} ',
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
              label: context.strings.view0InBreakdown(
                projectName(s.projectKey) ?? s.projectKey,
              ),
              icon: Icons.arrow_forward,
              trailingIcon: true,
              size: 'sm',
              onPressed: () =>
                  widget.onDetail({'period': 'all', 'project': s.projectKey!}),
            ),
          LensButton(
            label: context.strings.view0InBreakdown(toolOf(widget.source).name),
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
            LensDisclosure(
              expanded: technical,
              onPressed: () => setState(() => technical = !technical),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(
                context.strings.technicalDetails,
                style: p.text(13, p.secondary),
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
                      (context.strings.sessionId, s.sessionId),
                      (
                        context.strings.workingDirectory,
                        s.projectKey ?? context.strings.theToolDidNotLogThis,
                      ),
                      (
                        context.strings.records,
                        context.strings.sessionRecordSummary(
                          s.recordCount,
                          onlyTotals
                              ? context.strings.thisToolLogsOneTotalPerSession
                              : context.strings.onePerRequest,
                        ),
                      ),
                      (context.strings.source, widget.source),
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
        if (value.kinds.event > 0) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: LensSegmented(
              key: const Key('session-tabs'),
              small: true,
              options: {
                'overview': context.strings.overview2,
                'requests': context.strings.requests,
              },
              value: requestsTab ? 'requests' : 'overview',
              onChanged: (tab) =>
                  setState(() => requestsTab = tab == 'requests'),
              label: '',
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (requestsTab && value.kinds.event > 0)
          LensCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: RequestLog(
                key: const Key('session-request-log'),
                controller: c,
                identity:
                    '${widget.source}|${widget.sessionId}|${c.ledgerVersion}',
                filter: c.visibleFilter(const StatsFilter()),
                source: widget.source,
                sessionId: widget.sessionId,
              ),
            ),
          )
        else
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
