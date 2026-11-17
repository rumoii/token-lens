import 'package:flutter/material.dart';

import '../../stats_controller.dart';
import '../../stats_gateway.dart';
import '../logic/display.dart';
import '../logic/format.dart';
import '../logic/home_data.dart' show microsUsd;
import '../logic/tools.dart';
import '../theme/palette.dart';
import 'primitives.dart';
import 'resource.dart';
import 'filters.dart';

const requestLegend = '“—”表示日志里没记，鼠标停上去看原因。褐色是这里最慢的一成。带“≈”的是算上等待的平均速度。';
const requestTotalsLegend = '只记录会话总数的工具没有逐次请求，不出现在这里。';
const requestSortNames = {
  'time': '时间',
  'cost': '金额',
  'ttft': '首字',
  'speed': '速度',
};

class RequestLog extends StatefulWidget {
  const RequestLog({
    super.key,
    required this.controller,
    required this.identity,
    required this.filter,
    this.bucket,
    this.source,
    this.sessionId,
    this.onOpen,
  });
  final StatsController controller;
  final String identity;
  final StatsFilter filter;
  final String? bucket, source, sessionId;
  final ValueChanged<StatsRequest>? onOpen;
  @override
  State<RequestLog> createState() => _RequestLogState();
}

class _RequestLogState extends State<RequestLog> {
  late final resource = LensResource<StatsRequests>(() {
    if (mounted) setState(() {});
  });
  String sort = 'time';
  bool descending = true, timedOnly = false;
  int generation = 0;
  StatsController get c => widget.controller;
  LensPalette get p => LensPalette.of(context);
  bool get session => widget.sessionId != null;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(RequestLog old) {
    super.didUpdateWidget(old);
    if (old.identity != widget.identity || old.controller != c) load();
  }

  @override
  void dispose() {
    resource.dispose();
    super.dispose();
  }

  void load({bool more = false}) {
    if (more && (resource.loading || resource.data == null)) return;
    final previous = more ? resource.data : null;
    final query = StatsRequestQuery(
      source: widget.source,
      sessionId: widget.sessionId,
      bucket: widget.bucket,
      timedOnly: timedOnly,
      sort: sort,
      descending: descending,
      limit: 30,
      offset: previous?.items.length ?? 0,
      includeSummary: !more,
    );
    final filter = widget.filter;
    resource.read(++generation, () async {
      final next = await c.gateway.requestList(filter, query);
      return previous == null
          ? next
          : StatsRequests(
              items: [...previous.items, ...next.items],
              total: previous.total,
              slow: previous.slow,
              snapshot: next.snapshot,
            );
    });
  }

  void order(String key) {
    descending = sort == key ? !descending : key != 'speed';
    sort = key;
    load();
  }

  Widget time(StatsRequest r) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '${usageDate(r.observedAt, c.clock())} ',
          style: p.text(12, p.muted),
        ),
        TextSpan(text: usageTime(r.observedAt), style: p.text(12)),
      ],
    ),
  );
  Widget model(StatsRequest r) => Tooltip(
    message: r.model ?? '—',
    child: Text(
      r.model ?? '—',
      key: Key('request-model-${r.id}'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: p.text(12.5, r.model == null ? p.muted : null),
    ),
  );
  Widget amount(StatsRequest r) {
    final currency = c.preferences.currency;
    final rate = rateFor(c.preferences.rates, currency);
    final converted = (r.costMicros ?? 0) / 1000000 * rate;
    return KeyedSubtree(
      key: Key('request-money-${r.id}'),
      child: converted > 0 && converted < .001
          ? Tooltip(
              message: '\$${microsUsd(r.costMicros!)}',
              child: Text(
                '<${currencySymbol(currency)}0.001',
                style: p.text(12.5),
              ),
            )
          : MoneyText(
              r.costMicros == null ? null : microsUsd(r.costMicros!),
              digits: 3,
              currency: currency,
              rate: rate,
              style: p.text(12.5),
            ),
    );
  }

  Widget tokens(int? n) => Tooltip(
    message: n == null
        ? '日志里没记这一项。'
        : tokenTooltip(n, unitSystem: c.preferences.unitSystem),
    child: Text(
      n == null ? '—' : tokenCount(n, unitSystem: c.preferences.unitSystem),
      style: p.text(12, n == null ? p.muted : null),
    ),
  );

  Widget metric(StatsRequest r, StatsRequestSlow? slow, {required bool ttft}) {
    final n = ttft ? r.ttftMs?.toDouble() : r.speedTps ?? r.throughputTps;
    final approx = !ttft && r.speedTps == null && r.throughputTps != null;
    final isSlow =
        r.scope == 'request' &&
        n != null &&
        (ttft
            ? slow?.ttftMs != null && n >= slow!.ttftMs!
            : r.speedTps != null &&
                  slow?.speedTps != null &&
                  n <= slow!.speedTps!);
    final tool = toolOf(r.source).name;
    final String? hint;
    if (n == null) {
      hint = ttft
          ? r.source == 'codex' && r.status != null
                ? 'Codex 这次请求直接从工具调用开始，日志里看不到第一段输出的时间。'
                : '$tool 的日志里没记首字时间。'
          : r.status != null && r.status != 'completed'
          ? '这次请求没有正常结束，不算速度。'
          : '$tool 的日志里没记生成时长。';
    } else if (r.scope == 'turn') {
      hint = '这个工具按一整轮对话记录时间，一轮里可能有多次请求。';
    } else if (approx) {
      hint = '$tool 只记了整次请求的时长，这是算上等待的平均速度。';
    } else {
      hint = isSlow ? '比这里九成请求都慢' : null;
    }
    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: n == null
                ? '—'
                : ttft
                ? '${(n / 1000).toStringAsFixed(1)} 秒'
                : n.toStringAsFixed(1),
            style: p.text(
              12,
              n == null
                  ? p.muted
                  : isSlow
                  ? p['warn']
                  : p.ink,
            ),
          ),
          if (approx) TextSpan(text: '≈', style: p.text(10, p.muted)),
        ],
      ),
    );
    return hint == null ? text : Tooltip(message: hint, child: text);
  }

  Widget tool(StatsRequest r) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ToolTile(r.source, size: 14),
      const SizedBox(width: 5),
      Flexible(
        child: Text(
          toolOf(r.source).name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: p.text(12),
        ),
      ),
    ],
  );

  Widget compact(StatsRequest r, StatsRequestSlow? slow) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: time(r),
          ),
          if (!session) ...[const SizedBox(width: 10), tool(r)],
          const SizedBox(width: 12),
          Expanded(child: model(r)),
          const SizedBox(width: 12),
          amount(r),
        ],
      ),
      const SizedBox(height: 5),
      Wrap(
        key: Key('request-meta-${r.id}'),
        spacing: 16,
        runSpacing: 4,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              for (final (label, n) in [
                ('新输入', r.inputTokens),
                ('输出', r.outputTokens),
                ('读缓存', r.cacheReadTokens),
                ('写缓存', r.cacheWriteTokens),
              ])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$label ', style: p.text(11.5, p.muted)),
                    tokens(n),
                  ],
                ),
            ],
          ),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              for (final ttft in [true, false])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(ttft ? '首字 ' : '速度 ', style: p.text(11.5, p.muted)),
                    metric(r, slow, ttft: ttft),
                  ],
                ),
            ],
          ),
        ],
      ),
    ],
  );
  static const flexes = [14, 13, 18, 10, 9, 9, 9, 9, 9, 12];
  Widget columns(List<Widget> children) => Row(
    children: [
      for (var i = 0; i < children.length; i++)
        Expanded(
          flex: flexes[i],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Align(
              alignment: i < 3 ? Alignment.centerLeft : Alignment.centerRight,
              child: children[i],
            ),
          ),
        ),
    ],
  );
  Widget wide(StatsRequest r, StatsRequestSlow? slow) => columns([
    time(r),
    tool(r),
    model(r),
    amount(r),
    tokens(r.inputTokens),
    tokens(r.outputTokens),
    tokens(r.cacheReadTokens),
    tokens(r.cacheWriteTokens),
    metric(r, slow, ttft: true),
    metric(r, slow, ttft: false),
  ]);
  Widget row(StatsRequest r, StatsRequestSlow? slow, bool small) {
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p['line'])),
      ),
      child: small ? compact(r, slow) : wide(r, slow),
    );
    return Padding(
      key: Key('request-row-${r.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: session
          ? content
          : r.sessionId == null
          ? Tooltip(message: '这次请求的日志里没有会话编号，打不开所在的会话。', child: content)
          : Material(
              type: MaterialType.transparency,
              child: LensFocusOutline(
                child: InkWell(
                  onTap: () => widget.onOpen?.call(r),
                  child: content,
                ),
              ),
            ),
    );
  }

  Widget header(String label, String? key) {
    final text = Text(
      '$label${key == sort ? (descending ? ' ↓' : ' ↑') : ''}',
      style: p.text(12, p.muted).copyWith(height: 1.4),
    );
    return key == null
        ? text
        : LensFocusOutline(
            child: InkWell(
              key: Key('request-sort-$key'),
              onTap: () => order(key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: text,
              ),
            ),
          );
  }

  Widget compactSort() => Row(
    children: [
      FilterPick(
        key: const Key('request-sort-menu'),
        label: '排序：${requestSortNames[sort]}',
        onPick: order,
        options: [
          for (final e in requestSortNames.entries)
            FilterOption(e.key, e.value),
        ],
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
            tooltip: descending ? '从大到小' : '从小到大',
            onPressed: () => order(sort),
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            icon: Icon(
              descending ? Icons.south : Icons.north,
              size: 16,
              color: p.secondary,
            ),
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [
            if (!session)
              Expanded(
                child: Row(
                  children: [
                    Semantics(
                      label: '只看有计时的',
                      child: Checkbox(
                        value: timedOnly,
                        onChanged: (value) {
                          timedOnly = value ?? false;
                          load();
                        },
                        visualDensity: VisualDensity.compact,
                        activeColor: p['clay'],
                      ),
                    ),
                    Flexible(
                      child: InkWell(
                        onTap: () {
                          timedOnly = !timedOnly;
                          load();
                        },
                        child: Text('只看有计时的', style: p.text(12.5)),
                      ),
                    ),
                  ],
                ),
              )
            else
              const Spacer(),
            if (resource.data?.total != null)
              Text(
                '${toDisplayNumber(resource.data!.total!)} 次请求',
                key: const Key('request-total'),
                style: p.text(12, p.muted),
              )
            else
              const SizedBox(width: 100, child: SkeletonLines(rows: 1)),
          ],
        ),
      ),
      ResourceBlock(
        resource: resource,
        rows: 5,
        builder: (data) => LayoutBuilder(
          builder: (context, box) {
            final small =
                session ||
                MediaQuery.sizeOf(context).width < 768 ||
                box.maxWidth - 16 < 860;
            final items = data?.items ?? <StatsRequest>[];
            final remaining = (data?.total ?? 0) - items.length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (session)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: LensSegmented(
                        key: const Key('request-sort-pills'),
                        small: true,
                        options: {
                          for (final e in requestSortNames.entries)
                            e.key:
                                '${e.value}${sort == e.key ? (descending ? ' ▼' : ' ▲') : ''}',
                        },
                        value: sort,
                        onChanged: order,
                        label: '排序',
                      ),
                    ),
                  )
                else if (small)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: compactSort(),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: columns([
                      header('时间', 'time'),
                      header('工具', null),
                      header('模型', null),
                      header('金额', 'cost'),
                      header('新输入', null),
                      header('输出', null),
                      header('读缓存', null),
                      header('写缓存', null),
                      header('首字', 'ttft'),
                      header('速度 token/s', 'speed'),
                    ]),
                  ),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 24,
                    ),
                    child: Text(
                      timedOnly
                          ? '这段时间的请求都没有计时记录。'
                          : '这段时间没有逐次请求。只记录会话总数的工具不出现在这里。',
                      style: p.text(13, p.muted),
                    ),
                  )
                else
                  for (final r in items) row(r, data?.slow, small),
                if (remaining > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Center(
                      child: LensButton(
                        label: remaining < 30
                            ? '再显示 ${toDisplayNumber(remaining)} 条'
                            : '再显示 30 条（还有 ${toDisplayNumber(remaining)} 条）',
                        size: 'sm',
                        variant: 'ghost',
                        onPressed: resource.loading
                            ? null
                            : () => load(more: true),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                  child: Text(
                    '$requestLegend${session ? '' : requestTotalsLegend}',
                    style: p.text(11.5, p.muted),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ],
  );
}
