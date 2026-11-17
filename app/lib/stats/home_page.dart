import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../stats_controller.dart';
import 'logic/period.dart';
import 'logic/format.dart';
import 'logic/home_data.dart';
import 'logic/chart.dart';
import 'logic/tool_order.dart';
import 'logic/tools.dart';
import 'theme/palette.dart';
import 'widgets/primitives.dart';
import 'widgets/session_usage.dart';
import 'widgets/charts.dart';
import 'widgets/date_range.dart';
import 'widgets/motion.dart';

class StatsHome extends StatefulWidget {
  const StatsHome({
    super.key,
    required this.controller,
    required this.onDetail,
    required this.onSessions,
    required this.onSources,
  });
  final StatsController controller;
  final ValueChanged<Map<String, String>> onDetail, onSessions;
  final VoidCallback onSources;
  @override
  State<StatsHome> createState() => _StatsHomeState();
}

class _StatsHomeState extends State<StatsHome> {
  String? highlight;
  StatsController get c => widget.controller;
  LensPalette get p => LensPalette.of(context);
  bool get narrow => MediaQuery.sizeOf(context).width < 768;
  bool get large => MediaQuery.sizeOf(context).width >= 1024;
  String nt(num value) =>
      tokenCount(value, unitSystem: c.preferences.unitSystem);
  Widget token(num? value, {TextStyle? style}) =>
      TokenText(value, unitSystem: c.preferences.unitSystem, style: style);
  Widget money(
    Object? value, {
    int? digits,
    TextStyle? style,
    bool animate = false,
  }) {
    Widget render(Object? amount) => MoneyText(
      amount,
      digits: digits,
      style: style,
      currency: c.preferences.currency,
      rate: rateFor(c.preferences.rates, c.preferences.currency),
    );
    final number = double.tryParse(value?.toString() ?? '');
    return animate && number != null
        ? TweenValue(value: number, builder: render)
        : render(value);
  }

  Widget delta(int value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      color: value >= 0 ? p['clay-wash'] : p.okWash,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          value >= 0 ? Icons.arrow_upward : Icons.arrow_downward,
          size: 12,
          color: p[value >= 0 ? 'clay-ink' : 'ok'],
        ),
        Text(
          '${value.abs()}%',
          style: p.text(
            12.5,
            p[value >= 0 ? 'clay-ink' : 'ok'],
            FontWeight.w500,
          ),
        ),
      ],
    ),
  );
  Widget link(String label, VoidCallback onTap) => LensButton(
    label: label,
    icon: Icons.arrow_forward,
    trailingIcon: true,
    size: 'link',
    variant: 'ghost',
    onPressed: onTap,
  );
  Widget secHead(String title, String sub, {Widget? action}) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: p.text(15, null, FontWeight.w600)),
              const SizedBox(height: 2),
              Text(sub, style: p.text(12.5, p.muted)),
            ],
          ),
        ),
        ?action,
      ],
    ),
  );
  Widget rowLink({required Widget child, VoidCallback? onTap, String? tool}) =>
      MouseRegion(
        onEnter: tool == null ? null : (_) => setState(() => highlight = tool),
        onExit: tool == null ? null : (_) => setState(() => highlight = null),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: child,
        ),
      );
  Widget controls() => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      LensSegmented(
        options: const {'overview': '概览', 'detail': '明细'},
        value: 'overview',
        onChanged: (v) {
          if (v == 'detail') widget.onDetail({});
        },
        label: '视图',
      ),
      PeriodControl(
        period: c.preferences.period,
        now: c.clock(),
        onChanged: (v) => unawaited(c.setPeriod(v)),
      ),
    ],
  );
  Widget header(Widget summary) {
    final hour = c.clock().hour;
    final greet = hour < 6
        ? '夜深了'
        : hour < 11
        ? '早上好'
        : hour < 13
        ? '中午好'
        : hour < 18
        ? '下午好'
        : '晚上好';
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          greet,
          style: p
              .serif(narrow ? 26 : 30, weight: FontWeight.w500)
              .copyWith(height: 1.25, letterSpacing: -.3),
        ),
        const SizedBox(height: 6),
        DefaultTextStyle(
          style: p.text(15, p.secondary).copyWith(height: 1.7),
          child: summary,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 420 + 24 + 316) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: title),
              const SizedBox(width: 24),
              controls(),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [title, const SizedBox(height: 12), controls()],
        );
      },
    );
  }

  Widget failure(String error, {bool sync = false}) => LensCard(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 16, color: p['danger']),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sync ? error : '加载失败（request_failed）',
                style: p.text(12, null, FontWeight.w500),
              ),
              if (!sync) Text(error, style: p.text(12, p.muted)),
            ],
          ),
        ),
        LensButton(
          label: '重试',
          size: 'xs',
          variant: 'ghost',
          onPressed: c.busy
              ? null
              : () => unawaited(sync ? c.sync() : c.load()),
        ),
        if (sync) link('查看详情', widget.onSources),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final data = c.overview;
    final banner = <Widget>[
      if (c.syncError == null && c.syncFailed) failure('上次同步没有完成。', sync: true),
      if (c.syncError != null) failure(c.syncError!, sync: true),
      if (c.warning != null)
        Text('同步完成，有异常警告：${c.warning}', style: p.text(13.5, p['warn'])),
      if (c.error != null) failure(c.error!),
    ];
    if (data == null) {
      return Column(
        spacing: narrow ? 12 : 16,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...banner,
          header(const SizedBox(height: 16)),
          LensCard(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
            child: c.error == null
                ? const SkeletonLines(rows: 6)
                : const SizedBox.shrink(),
          ),
        ],
      );
    }
    final digest = digestPairs(data.pairs.groups), totals = data.summary.totals;
    final rank = digest.rank, models = digest.models;
    final order = sortByToolOrder(
      rank.map((g) => g.id).toList(),
      sourceSequence(data.sources.sources),
    );
    final slots = assignToolColors(sourceSequence(data.sources.sources));
    final period = data.period, now = c.clock();
    final compare = period.compare(now);
    final buckets = buildBuckets(data.matrix.rows, data.axis, now);
    var comparison = compare?.label ?? '';
    int? cmp;
    if (period.period == 'today' && data.previousHours != null) {
      comparison = '昨天同一时间';
      final cutoff =
          '${compare!.from}T${now.hour.toString().padLeft(2, '0')}:00:00';
      final prev = data.previousHours!.points
          .where((p) => p.bucket.compareTo(cutoff) <= 0)
          .fold<int>(0, (s, p) => s + p.grossTokens);
      cmp = deltaOf(
        data.matrix.rows.fold<int>(0, (s, p) => s + p.grossTokens),
        prev,
      );
    } else if (data.previous != null) {
      cmp = deltaOf(totals.grossTokens, data.previous!.totals.grossTokens);
    }
    Widget toolName(String id) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ToolTile(id, size: 16),
        const SizedBox(width: 4),
        Text(toolOf(id).name, style: p.text(15, null, FontWeight.w700)),
      ],
    );
    final summary = <InlineSpan>[];
    if (totals.recordCount == 0) {
      summary.add(
        TextSpan(text: '${period.label}还没有用量。换个时间范围看看，或者等工具产生新的日志后再同步。'),
      );
    } else {
      if (period.period == 'all') {
        final first = DateTime.tryParse(data.summary.activity.firstSeen ?? '')
            ?.toLocal();
        summary.add(
          TextSpan(
            text:
                '从 ${first == null ? '最早一条记录' : '${first.month} 月 ${first.day} 日'}开始记录，',
          ),
        );
      } else if (cmp != null) {
        final direction = cmp >= 50
            ? '用得多了不少'
            : cmp >= 10
            ? '用得多'
            : cmp <= -50
            ? '少了不少'
            : cmp <= -10
            ? '用得少'
            : '差不多';
        summary.add(
          TextSpan(
            text:
                '${period.period == 'custom' ? '这段时间' : period.label}${cmp.abs() < 10 ? '和' : '比'}$comparison',
          ),
        );
        summary.add(
          TextSpan(
            text: direction,
            style: cmp.abs() < 10
                ? null
                : p.text(15, p[cmp >= 0 ? 'clay-ink' : 'ok'], FontWeight.w500),
          ),
        );
        summary.add(const TextSpan(text: '，'));
      } else {
        summary.add(
          TextSpan(text: period.period == 'custom' ? '这段时间' : period.label),
        );
      }
      if (rank.isNotEmpty) {
        final most = rank.first.tokens / math.max(1, totals.grossTokens) >= .5;
        summary.add(TextSpan(text: most ? '大部分花在 ' : '用得最多的是 '));
        summary.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: toolName(rank.first.id),
          ),
        );
        if (most) summary.add(const TextSpan(text: ' 上'));
        if (rank.length > 1) {
          summary.add(const TextSpan(text: '，其次是 '));
          summary.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: toolName(rank[1].id),
            ),
          );
        }
      }
      summary.add(const TextSpan(text: '。'));
      if (compare != null && cmp == null) {
        summary.add(
          TextSpan(text: '$comparison还没有记录，没法比。', style: p.text(15, p.muted)),
        );
      }
    }
    final yearMap = {
      for (final point in data.year.points)
        point.bucket.substring(0, 10): point.grossTokens,
    };
    final yearKeys = bucketKeys('day', (
      from: dayKey(DateTime(now.year, now.month, now.day - 364)),
      to: dayKey(now),
    ), now);
    var streak = 0, best = 0;
    for (final key in yearKeys) {
      streak = (yearMap[key] ?? 0) > 0 ? streak + 1 : 0;
      best = math.max(best, streak);
    }
    final active = yearKeys.where((key) => (yearMap[key] ?? 0) > 0).length;
    return Column(
      spacing: narrow ? 12 : 16,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c.loading)
          Semantics(
            label: '正在加载',
            child: SizedBox(
              height: 2,
              child: LinearProgressIndicator(
                value: MediaQuery.disableAnimationsOf(context) ? .33 : null,
                color: p['clay'],
                backgroundColor: LensPalette.transparent,
              ),
            ),
          ),
        ...banner,
        header(Text.rich(TextSpan(children: summary))),
        if (totals.recordCount == 0)
          LensCard(
            child: EmptyState(
              title: '${period.label}还没有用量',
              hint: 'Token Lens 只统计已经写进日志的用量。可以换个时间范围，或者在工具里用一会儿再回来。',
              action: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LensButton(
                    label: '看本月',
                    size: 'sm',
                    onPressed: () =>
                        unawaited(c.setPeriod(const StatsPeriod('month'))),
                  ),
                  const SizedBox(width: 8),
                  LensButton(
                    label: '看全部',
                    size: 'sm',
                    onPressed: () =>
                        unawaited(c.setPeriod(const StatsPeriod('all'))),
                  ),
                ],
              ),
            ),
          )
        else ...[
          LensEnter(
            index: 0,
            child: hero(data, rank, order, slots, cmp, comparison),
          ),
          kpis(data, buckets, best),
          pair(
            LensEnter(index: 5, child: trend(data, buckets, order, slots)),
            LensEnter(index: 6, child: modelList(data, models, slots)),
          ),
          pair(
            c.resourceErrors.containsKey('year') ||
                    c.resourceErrors.containsKey('yearTools')
                ? failure(
                    c.resourceErrors['year'] ?? c.resourceErrors['yearTools']!,
                  )
                : LensEnter(
                    index: 7,
                    child: heatCard(data, yearMap, active, best),
                  ),
            c.resourceErrors.containsKey('recent')
                ? failure(c.resourceErrors['recent']!)
                : LensEnter(index: 8, child: recent(data)),
            alignStart: true,
          ),
          Text(
            '金额按各模型的公开标准价估算，用来比较和感知，不是你的账单。套餐用户的实际花费通常更低。',
            style: p.text(12, p.muted),
          ),
        ],
      ],
    );
  }

  Widget hero(
    StatsHomeData data,
    List<ToolUsage> rank,
    List<String> order,
    Map<String, int> slots,
    int? cmp,
    String comparison,
  ) {
    final total = data.summary.totals, by = {for (final g in rank) g.id: g};
    final value = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          data.period.period == 'all' ? '累计用量' : '${data.period.label}用量',
          style: p.text(13, p.muted),
        ),
        const SizedBox(height: 6),
        Tooltip(
          message: '${toDisplayNumber(total.grossTokens)} token',
          child: TweenValue(
            value: total.grossTokens,
            builder: (value) {
              final number = nt(value),
                  match = RegExp(r'^(-?[\d,.]+)(万亿|亿|万|[KMBT])?$')
                      .firstMatch(number);
              return Text.rich(
                TextSpan(
                  style: p.serif(narrow ? 44 : 52),
                  children: [
                    TextSpan(text: match?[1] ?? number),
                    TextSpan(
                      text: match?[2] ?? '',
                      style: TextStyle(
                        fontSize: (narrow ? 44 : 52) * .6,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                    TextSpan(
                      text: ' token',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                        color: p.secondary,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (total.grossTokens > 0 && total.recordCount > 0)
          Text(
            '= ${tokenCount(total.grossTokens, unitSystem: c.preferences.unitSystem == 'chinese' ? 'english' : 'chinese')} token',
            key: const Key('home-conversion'),
            style: p.text(13, p.muted),
          ),
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('约值 ', style: p.text(15, p.secondary)),
            money(total.costUsd, style: p.serif(22), animate: true),
          ],
        ),
        SizedBox(height: cmp == null ? 10 : 12),
        if (cmp == null)
          Text('按公开标准价估算，不是账单', style: p.text(12.5, p.muted))
        else
          Row(
            children: [
              delta(cmp),
              const SizedBox(width: 8),
              Text('比$comparison', style: p.text(12.5, p.muted)),
            ],
          ),
      ],
    );
    String percent(int n) {
      final ratio = n / math.max(1, total.grossTokens);
      return '${(ratio * 100).toStringAsFixed(ratio < .1 ? 1 : 0)}%';
    }

    final distribution = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Semantics(
          label: '按工具分布',
          image: true,
          child: LensGrow(
            reveal: true,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Row(
                children: [
                  for (final key in order)
                    Expanded(
                      flex: math.max(1, by[key]!.tokens),
                      child: AnimatedOpacity(
                        opacity: highlight == null || highlight == key
                            ? 1
                            : .35,
                        duration: LensTokens.hover,
                        child: Container(
                          height: 12,
                          margin: EdgeInsets.only(
                            right: key == order.last ? 0 : 2,
                          ),
                          color: p.category(slots[key] ?? 0),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        for (final g in rank.take(5))
          rowLink(
            tool: g.id,
            onTap: () => widget.onDetail({'tool': g.id, 'dim': 'model'}),
            child: SizedBox(
              height: 42,
              child: LayoutBuilder(
                builder: (context, box) => Row(
                  children: [
                    ToolTile(g.id, size: 28),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: narrow
                          ? math.max(0, box.maxWidth - 168)
                          : (box.maxWidth - 278).clamp(0.0, 150.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            toolOf(g.id).name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: p.text(14, null, FontWeight.w500),
                          ),
                          Text(
                            '${g.models} 个模型',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: p.text(12, p.muted),
                          ),
                        ],
                      ),
                    ),
                    if (!narrow) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 180,
                        child: bar(
                          g.tokens / math.max(1, rank.first.tokens),
                          p.category(slots[g.id] ?? 0),
                          height: 6,
                          delay: 230 + rank.indexOf(g) * 57,
                        ),
                      ),
                    ],
                    const SizedBox(width: 12),
                    SizedBox(
                      width: narrow ? 64 : 72,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TweenValue(
                          value: g.tokens,
                          builder: (n) => token(n, style: p.text(13.5)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: narrow ? 40 : 46,
                      child: Text(
                        percent(g.tokens),
                        textAlign: TextAlign.right,
                        style: p.text(12.5, p.muted),
                      ),
                    ),
                    if (!narrow) ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 72,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: money(
                            g.costUsd,
                            style: p.text(13, p.secondary),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        if (rank.length > 5)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '另有 ${rank.skip(5).map((g) => toolOf(g.id).name).join('、')}，合计 ${percent(rank.skip(5).fold<int>(0, (s, g) => s + g.tokens))}',
              style: p.text(12.5, p.muted),
            ),
          ),
      ],
    );
    return LensCard(
      key: const Key('home-hero'),
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 155),
        child: large
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 300, child: value),
                  const SizedBox(width: 28),
                  Expanded(child: distribution),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [value, const SizedBox(height: 20), distribution],
              ),
      ),
    );
  }

  Widget bar(double ratio, Color color, {double height = 5, int delay = 230}) =>
      ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: height,
          color: p['fill-hover'],
          alignment: Alignment.centerLeft,
          child: LensGrow(
            delay: delay,
            child: FractionallySizedBox(
              widthFactor: ratio.clamp(0, 1),
              child: Container(color: color),
            ),
          ),
        ),
      );

  Widget kpis(StatsHomeData data, List<TrendBucket> buckets, int streak) {
    final days = data.days.points,
        totals = data.summary.totals,
        now = c.clock(),
        period = data.period;
    final active = days.where((d) => d.grossTokens > 0).length;
    final perDay =
        days.fold<int>(0, (s, d) => s + d.grossTokens) / math.max(1, active);
    final prevDays = data.previousDays?.points;
    final prevPerDay = prevDays == null
        ? null
        : prevDays.fold<int>(0, (s, d) => s + d.grossTokens) /
              math.max(1, prevDays.where((d) => d.grossTokens > 0).length);
    final sessions = data.summary.activity.sessions,
        prevSessions = data.previous?.activity.sessions;
    final numStyle = p
        .serif(large ? 26 : 22)
        .copyWith(height: 1.2, letterSpacing: -.26);
    Widget hint(List<Widget> children) => Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          if (i == children.length - 1)
            Flexible(child: children[i])
          else
            children[i],
        ],
      ],
    );
    Widget card(
      String title,
      Widget value,
      Widget hint, {
      Widget? spark,
    }) => LensCard(
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title.startsWith('缓存')
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('缓存帮你省了', style: p.text(13, p.muted)),
                          const SizedBox(width: 6),
                          Tooltip(
                            message:
                                '工具重复发送的上下文命中缓存时，按缓存价而不是输入价计费。这里是两者的差额，按公开价估算。',
                            child: Container(
                              width: 15,
                              height: 15,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  width: LensPalette.hairline(context),
                                  color: p['line-strong'],
                                ),
                              ),
                              child: Text(
                                '?',
                                style: p.text(10, p.muted).copyWith(height: 1),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Text(title, style: p.text(13, p.muted)),
                const SizedBox(height: 4),
                value,
                const SizedBox(height: 4),
                hint,
              ],
            ),
          ),
          if (spark != null)
            Positioned(right: 16, top: 18, width: 76, height: 28, child: spark),
        ],
      ),
    );
    final items = <Widget>[];
    if (period.period == 'today' && data.axis.granularity == 'hour') {
      final live = buckets.where((b) => !b.future).toList()
        ..sort((a, b) => b.total - a.total);
      final busy = live.isEmpty ? null : live.first;
      final h = busy == null ? 0 : int.parse(busy.bucket.substring(11, 13));
      items.add(
        card(
          '最忙的一小时',
          Text.rich(
            TextSpan(
              text: busy == null ? '—' : '$h:00',
              style: numStyle,
              children: busy == null
                  ? []
                  : [
                      TextSpan(
                        text: ' – ${h + 1}:00',
                        style: p.text(15, p.muted),
                      ),
                    ],
            ),
          ),
          Text(
            busy == null
                ? ''
                : '${nt(busy.total)} token，占今天的 ${(busy.total / math.max(1, totals.grossTokens) * 100).round()}%',
            style: p.text(12, p.muted),
          ),
        ),
      );
      final current =
          buckets
              .where((b) => b.bucket == nowBucketKey('hour', now))
              .firstOrNull
              ?.total ??
          0;
      final yesterday = data.previousHours?.points
          .where(
            (b) => b.bucket.endsWith(
              'T${now.hour.toString().padLeft(2, '0')}:00:00',
            ),
          )
          .firstOrNull
          ?.grossTokens;
      final change = deltaOf(
        current,
        yesterday == null ? null : yesterday * now.minute / 60,
      );
      items.add(
        card(
          '这一小时',
          token(current, style: numStyle),
          hint([
            if (change != null) delta(change),
            Text(
              '${now.hour}:00 到现在${change != null ? '，比昨天这时候' : ''}',
              style: p.text(12, p.muted),
            ),
          ]),
        ),
      );
    } else {
      final change = deltaOf(perDay, prevPerDay);
      final range = period.range(now),
          map = {for (final d in days) d.bucket: d.grossTokens};
      final keys = range.from == null
          ? days.map((d) => d.bucket).toList()
          : bucketKeys('day', (
              from: range.from,
              to: (range.to ?? '').compareTo(dayKey(now)) > 0
                  ? dayKey(now)
                  : range.to,
            ), now);
      items.add(
        card(
          '日均用量',
          TweenValue(
            value: perDay,
            builder: (n) => token(n, style: numStyle),
          ),
          hint([
            if (change != null) delta(change),
            Text('按有用量的天算', style: p.text(12, p.muted)),
          ]),
          spark: keys.length < 2
              ? null
              : CustomPaint(
                  painter: _SparkPainter([
                    for (final key in keys) map[key] ?? 0,
                  ], p),
                ),
        ),
      );
    }
    final sessionDelta = deltaOf(sessions, prevSessions);
    items.add(
      card(
        '会话',
        TweenValue(
          value: sessions,
          builder: (n) => Text('${n.round()}', style: numStyle),
        ),
        hint([
          if (sessionDelta != null) delta(sessionDelta),
          Text(
            '平均每个 ${nt(totals.grossTokens / math.max(1, sessions))}',
            style: p.text(12, p.muted),
          ),
        ]),
      ),
    );
    if (period.period != 'today') {
      final elapsed = period.elapsedDays(now, data.summary.activity.firstSeen),
          used = {for (final d in days) d.bucket: d.grossTokens};
      items.add(
        card(
          '活跃天数',
          TweenValue(
            value: active,
            builder: (n) => Text.rich(
              TextSpan(
                text: '${n.round()}',
                style: numStyle,
                children: [
                  TextSpan(text: ' / $elapsed 天', style: p.text(15, p.muted)),
                ],
              ),
            ),
          ),
          period.period == 'week'
              ? Wrap(
                  spacing: 4,
                  children: [
                    for (final key in bucketKeys('day', (
                      from: data.axis.from,
                      to: data.axis.to,
                    ), now))
                      Tooltip(
                        message:
                            '$key${key.compareTo(dayKey(now)) > 0
                                ? ' · 还没到'
                                : (used[key] ?? 0) > 0
                                ? ''
                                : ' · 没有用量'}',
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: key.compareTo(dayKey(now)) > 0
                                ? null
                                : (used[key] ?? 0) > 0
                                ? p['clay']
                                : p['fill-active'],
                            border: key.compareTo(dayKey(now)) > 0
                                ? Border.all(
                                    width: LensPalette.hairline(context),
                                    color: p['line-strong'],
                                  )
                                : null,
                          ),
                        ),
                      ),
                  ],
                )
              : Text('最长连续 $streak 天', style: p.text(12, p.muted)),
        ),
      );
    }
    final ratio = data.summary.activity.cacheHitRatio;
    items.add(
      card(
        '缓存帮你省了  ⓘ',
        c.resourceErrors.containsKey('pricing')
            ? failure(c.resourceErrors['pricing']!)
            : money(
                cacheSavings(data.pairs.groups, data.pricing),
                digits: 0,
                style: numStyle,
                animate: true,
              ),
        c.resourceErrors.containsKey('pricing')
            ? const SizedBox.shrink()
            : Tooltip(
                message: '工具重复发送的上下文命中缓存时，按缓存价而不是输入价计费。这里是两者的差额，按公开价估算。',
                child: Text(
                  ratio == null ? '—' : '${(ratio * 100).round()}% 的输入走了缓存',
                  style: p.text(12, p.muted),
                ),
              ),
      ),
    );
    return Column(
      children: [
        for (var start = 0; start < items.length; start += large ? 4 : 2) ...[
          if (start > 0) const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (
                  var i = start;
                  i < math.min(items.length, start + (large ? 4 : 2));
                  i++
                ) ...[
                  if (i > start) SizedBox(width: large ? 16 : 12),
                  Expanded(
                    child: LensEnter(index: i + 1, child: items[i]),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget pair(Widget left, Widget right, {bool alignStart = false}) => large
      ? (alignStart
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 2, child: left),
                  const SizedBox(width: 16),
                  Expanded(child: right),
                ],
              )
            : IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 2, child: left),
                    const SizedBox(width: 16),
                    Expanded(child: right),
                  ],
                ),
              ))
      : Column(
          spacing: narrow ? 12 : 16,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [left, right],
        );
  Widget trend(
    StatsHomeData data,
    List<TrendBucket> buckets,
    List<String> order,
    Map<String, int> slots,
  ) {
    final granularity = data.axis.granularity,
        unit = data.axis.granularity == 'hour'
            ? '小时'
            : data.axis.granularity == 'month'
            ? '月'
            : '天';
    final unallocated = data.matrix.unallocated?.grossTokens ?? 0;
    return LensCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          secHead(
            '趋势',
            '每$unit用了多少，颜色代表工具，虚线是平均值${granularity == 'hour' ? '' : '。点柱子看那$unit的明细'}',
            action: link('看明细', () => widget.onDetail({})),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    children: [
                      for (final key in order.take(8))
                        MouseRegion(
                          onEnter: (_) => setState(() => highlight = key),
                          onExit: (_) => setState(() => highlight = null),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(
                                  color: p.category(slots[key] ?? 0),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                toolOf(key).name,
                                style: p.text(12, p.secondary),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                TrendChart(
                  buckets: buckets,
                  order: order,
                  slots: slots,
                  granularity: granularity,
                  now: c.clock(),
                  weekdays: data.period.period == 'week',
                  highlight: highlight,
                  onPick: granularity == 'hour'
                      ? null
                      : (key) =>
                            widget.onDetail({'bucket': key, 'dim': 'tool'}),
                  unitSystem: c.preferences.unitSystem,
                  currency: c.preferences.currency,
                  rate: rateFor(c.preferences.rates, c.preferences.currency),
                ),
                if (unallocated > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '另有 ${nt(unallocated)} token 来自跨$unit的会话快照，没法按$unit拆开，不在图里；上面的总量已经算上了。',
                      style: p.text(12.5, p.muted),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget modelList(
    StatsHomeData data,
    List<ModelUsage> models,
    Map<String, int> slots,
  ) => LensCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        secHead(
          '常用模型',
          '${data.period.period == 'all' ? '累计' : data.period.label}用得最多的 5 个',
          action: link('全部', () => widget.onDetail({'dim': 'model'})),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(
            children: [
              for (final model in models)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: rowLink(
                    onTap: model.name == '未知模型'
                        ? null
                        : () => widget.onDetail({'model': model.name}),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              ToolTile(model.topTool, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  model.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: p.text(13, null, FontWeight.w500),
                                ),
                              ),
                              const SizedBox(width: 8),
                              token(
                                model.tokens,
                                style: p.text(13, p.secondary),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 38,
                                child: Text(
                                  '${(model.tokens / math.max(1, data.summary.totals.grossTokens) * 100).round()}%',
                                  textAlign: TextAlign.right,
                                  style: p.text(13, p.muted),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          bar(
                            model.tokens / math.max(1, models.first.tokens),
                            p.category(slots[model.topTool] ?? 0),
                            delay: 230 + models.indexOf(model) * 57,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget heatCard(
    StatsHomeData data,
    Map<String, int> map,
    int active,
    int streak,
  ) {
    final entries = map.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final busy = entries.isEmpty
        ? null
        : (entries.toList()..sort((a, b) => b.value - a.value)).first;
    final first = entries.isEmpty ? null : DateTime.parse(entries.first.key),
        newcomer = active < 30;
    final top =
        (data.yearTools.groups.where((g) => g.key != null).toList()
              ..sort((a, b) => b.grossTokens - a.grossTokens))
            .firstOrNull;
    final busyDay = busy == null ? null : DateTime.parse(busy.key);
    final cells = <Widget>[];
    Widget cell(String title, Widget value, Widget hint) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: p.text(12, p.muted)),
          const SizedBox(height: 2),
          value,
          hint,
        ],
      ),
    );
    cells.add(
      cell(
        newcomer ? '到现在一共' : '这一年一共',
        token(
          data.yearTools.totals.grossTokens,
          style: p.text(16, null, FontWeight.w600),
        ),
        Wrap(
          children: [
            Text('约值 ', style: p.text(12, p.muted)),
            money(
              data.yearTools.totals.costUsd,
              digits: 0,
              style: p.text(12, p.muted),
            ),
          ],
        ),
      ),
    );
    cells.add(
      cell(
        '最忙的一天',
        Text(
          busyDay == null ? '—' : '${busyDay.month}月${busyDay.day}日',
          style: p.text(16, null, FontWeight.w600),
        ),
        Text(
          busy == null ? '' : '${nt(busy.value)} token',
          style: p.text(12, p.muted),
        ),
      ),
    );
    cells.add(
      cell(
        '最长连续',
        Text('$streak 天', style: p.text(16, null, FontWeight.w600)),
        Text(
          newcomer && streak == active ? '从第一天起没断过' : '一共活跃 $active 天',
          style: p.text(12, p.muted),
        ),
      ),
    );
    cells.add(
      cell(
        '用得最多',
        top == null
            ? const Text('—')
            : Row(
                children: [
                  ToolTile(top.key!, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      toolOf(top.key!).name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: p.text(16, null, FontWeight.w600),
                    ),
                  ),
                ],
              ),
        Text(
          top == null
              ? ''
              : '占 ${(top.grossTokens / math.max(1, data.yearTools.totals.grossTokens) * 100).round()}%',
          style: p.text(12, p.muted),
        ),
      ),
    );
    return LensCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          secHead(narrow ? '最近 20 周' : '这一年', '每个格子是一天，颜色越深用得越多'),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Heatmap(
                  values: map,
                  now: c.clock(),
                  narrow: narrow,
                  unitSystem: c.preferences.unitSystem,
                ),
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: newcomer
                                ? '从 ${first == null ? '' : '${first.month} 月 ${first.day} 日'}开始记录，已经活跃 '
                                : '过去一年活跃 ',
                          ),
                          TextSpan(
                            text: '$active',
                            style: p.text(12, p.ink, FontWeight.w700),
                          ),
                          TextSpan(text: newcomer ? ' 天' : ' 天，最长连续 $streak 天'),
                        ],
                      ),
                      style: p.text(12, p.muted),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('少', style: p.text(12, p.muted)),
                        for (var level = 0; level <= 4; level++)
                          Container(
                            width: 11,
                            height: 11,
                            margin: const EdgeInsets.only(left: 3),
                            decoration: BoxDecoration(
                              color: p['heat-$level'],
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        const SizedBox(width: 3),
                        Text('多', style: p.text(12, p.muted)),
                      ],
                    ),
                  ],
                ),
                if (data.yearTools.totals.grossTokens > 0) ...[
                  const SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      color: p['fill-hover'],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        for (var start = 0; start < 4; start += narrow ? 2 : 4)
                          IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (
                                  var i = start;
                                  i < math.min(4, start + (narrow ? 2 : 4));
                                  i++
                                )
                                  Expanded(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border(
                                          left: i > start
                                              ? BorderSide(
                                                  width: LensPalette.hairline(
                                                    context,
                                                  ),
                                                  color: p['line-soft'],
                                                )
                                              : BorderSide.none,
                                          top: start > 0
                                              ? BorderSide(
                                                  width: LensPalette.hairline(
                                                    context,
                                                  ),
                                                  color: p['line-soft'],
                                                )
                                              : BorderSide.none,
                                        ),
                                      ),
                                      child: cells[i],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget recent(StatsHomeData data) => LensCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        secHead(
          data.period.period == 'all'
              ? '最近会话'
              : '${sessionPeriodLabel(data.period)}的会话',
          data.period.period == 'all' ? '每次打开工具做的一件事' : '按这段时间的用量排序',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in data.recent.items)
                rowLink(
                  onTap: () => widget.onSessions({
                    ...Uri.splitQueryString(data.period.query),
                    'source': item.source,
                    'session': item.sessionId,
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Row(
                      children: [
                        ToolTile(item.source, size: 28),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      item.projectKey
                                              ?.split(RegExp(r'[/\\]'))
                                              .where((s) => s.isNotEmpty)
                                              .lastOrNull ??
                                          '没有记录项目',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: p.text(
                                        13.5,
                                        null,
                                        FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  if (sessionStartedBefore(
                                    item.startedAt,
                                    data.period,
                                    c.clock(),
                                    offsetMinutes: data
                                        .recent
                                        .snapshot
                                        .filters
                                        .offsetMinutes,
                                  ))
                                    SessionStartChip(
                                      startedAt: item.startedAt,
                                      now: c.clock(),
                                      offsetMinutes: data
                                          .recent
                                          .snapshot
                                          .filters
                                          .offsetMinutes,
                                    ),
                                ],
                              ),
                              Text(
                                item.requestCount == null &&
                                        item.cumulative.requestCount != null
                                    ? '${toolOf(item.source).name} · 本时段没有逐次请求'
                                    : item.hasCumulative &&
                                          item.cumulative.requestCount == null
                                    ? '只记录总数，算在开始那天'
                                    : '${toolOf(item.source).name} · ${requestText(item.requestCount)}',
                                maxLines: 2,
                                style: p.text(12, p.muted),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${data.period.period == 'all' ? '累计' : sessionPeriodLabel(data.period)} ${nt(item.grossTokens)}',
                              style: p.text(13, null, FontWeight.w600),
                            ),
                            if (item.cumulative.grossTokens != item.grossTokens)
                              Text(
                                '累计 ${nt(item.cumulative.grossTokens)}',
                                style: p.text(11.5, p.muted),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              link(
                '查看全部会话',
                () =>
                    widget.onSessions(Uri.splitQueryString(data.period.query)),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.p);
  final List<int> values;
  final LensPalette p;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    final points = sparkPoints(values, size.width, size.height);
    for (var i = 0; i < points.length; i++) {
      final x = points[i].x, y = points[i].y;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = p['clay']
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) => true;
}
