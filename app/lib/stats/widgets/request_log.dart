import '../../l10n/app_strings.dart';

import 'package:flutter/foundation.dart' show listEquals;
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

Map<String, String> requestSortNames(AppStrings strings) => {
  'time': strings.time,
  'cost': strings.cost,
  'ttft': strings.firstToken,
  'speed': strings.speed,
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
    final changedScope = !listEquals(
      old.filter.excludeSources,
      widget.filter.excludeSources,
    );
    if (old.identity != widget.identity ||
        old.controller != c ||
        changedScope) {
      load(retainData: !changedScope);
    }
  }

  @override
  void dispose() {
    resource.dispose();
    super.dispose();
  }

  void load({bool more = false, bool retainData = true}) {
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
    }, retainData: retainData);
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
          text:
              '${usageDate(r.observedAt, c.clock(), strings: context.strings)} ',
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
        ? context.strings.theLogDidNotRecordThisField
        : tokenTooltip(n, unitSystem: c.unitSystem),
    child: Text(
      n == null ? '—' : tokenCount(n, unitSystem: c.unitSystem),
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
                ? context.strings.thisCodexRequestBeganWithATool
                : context.strings.toolDidNotLogFirstTokenTime(tool)
          : r.status != null && r.status != 'completed'
          ? context.strings.thisRequestDidNotFinishNormallySo
          : context.strings.toolDidNotLogGenerationTime(tool);
    } else if (r.scope == 'turn') {
      hint = context.strings.thisToolLogsTimingForAWhole;
    } else if (approx) {
      hint = context.strings.averageSpeedIncludesWait(tool);
    } else {
      hint = isSlow ? context.strings.slowerThan90OfRequestsHere : null;
    }
    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: n == null
                ? '—'
                : ttft
                ? context.strings.secondsDuration((n / 1000).toStringAsFixed(1))
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
                (context.strings.newInput, r.inputTokens),
                (context.strings.output, r.outputTokens),
                (context.strings.cacheRead, r.cacheReadTokens),
                (context.strings.cacheWrite, r.cacheWriteTokens),
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
                    Text(
                      ttft
                          ? context.strings.firstToken2
                          : context.strings.speed2,
                      style: p.text(11.5, p.muted),
                    ),
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
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 10) *
          c.preferences.spacing,
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
          ? Tooltip(
              message: context.strings.theLogHasNoSessionIdFor,
              child: content,
            )
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
        searchable: false,
        key: const Key('request-sort-menu'),
        label: context.strings.sortBy0(requestSortNames(context.strings)[sort]),
        onPick: order,
        options: [
          for (final e in requestSortNames(context.strings).entries)
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
            tooltip: descending
                ? context.strings.highestFirst
                : context.strings.lowestFirst,
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
                      label: context.strings.timedOnly,
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
                        child: Text(
                          context.strings.timedOnly,
                          style: p.text(12.5),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              const Spacer(),
            if (resource.data?.total != null)
              Text(
                context.strings.requestCount(
                  toDisplayNumber(resource.data!.total!),
                ),
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
                          for (final e in requestSortNames(
                            context.strings,
                          ).entries)
                            e.key:
                                '${e.value}${sort == e.key ? (descending ? ' ▼' : ' ▲') : ''}',
                        },
                        value: sort,
                        onChanged: order,
                        label: context.strings.sort,
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
                      header(context.strings.time, 'time'),
                      header(context.strings.tool, null),
                      header(context.strings.model, null),
                      header(context.strings.cost, 'cost'),
                      header(context.strings.newInput, null),
                      header(context.strings.output, null),
                      header(context.strings.cacheRead, null),
                      header(context.strings.cacheWrite, null),
                      header(context.strings.firstToken, 'ttft'),
                      header(context.strings.speedTokenS, 'speed'),
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
                          ? context.strings.noRequestsInThisPeriodHaveTiming
                          : context
                                .strings
                                .noIndividualRequestsInThisPeriodTools,
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
                            ? context.strings.show0More(
                                toDisplayNumber(remaining),
                              )
                            : context.strings.show30More0Left(
                                toDisplayNumber(remaining),
                              ),
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
                    '${context.strings.aDashMeansTheLogOmitsThe}${session ? '' : context.strings.toolsThatLogOnlySessionTotalsHave}',
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
