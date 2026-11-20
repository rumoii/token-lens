import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../stats_gateway.dart';
import '../logic/format.dart';
import '../theme/palette.dart';
import 'primitives.dart';

enum TimingKind {
  ttft,
  speed,
  throughput;

  (String label, String shortName, String hint) copy(AppStrings strings) =>
      switch (this) {
        ttft => (
          strings.firstTokenWaitForTheReply,
          strings.firstToken,
          strings.timeFromSendingTheRequestToThe,
        ),
        speed => (
          strings.speedTokensPerSecondWhileReplying,
          strings.speed,
          strings.tokensGeneratedPerSecondAfterOutputBegins,
        ),
        throughput => (
          strings.averageSpeedIncludesTheWait,
          strings.averageSpeed,
          strings.outputTokensDividedByTotalRequestTime,
        ),
      };

  bool hasSamples(StatsTiming? timing, {bool turn = false}) => switch (this) {
    ttft =>
      (turn ? timing?.turn?.ttft : timing?.ttft)?.any(
            (t) => t.sampleCount > 0,
          ) ??
          false,
    speed =>
      (turn ? timing?.turn?.speed : timing?.speed)?.any(
            (t) => t.sampleCount > 0,
          ) ??
          false,
    throughput =>
      (turn ? timing?.turn?.throughput : timing?.throughput)?.any(
            (t) => t.sampleCount > 0,
          ) ??
          false,
  };
}

class TimingStrip extends StatelessWidget {
  const TimingStrip({
    super.key,
    required this.timing,
    this.turn = false,
    this.requestCount = 0,
    this.scopeAsTitle = false,
    required this.metricKey,
  });
  final StatsTiming? timing;
  final bool turn, scopeAsTitle;
  final int requestCount;
  final Key Function(TimingKind) metricKey;

  static bool hasSamples(StatsTiming? timing) =>
      TimingKind.values.any((kind) => kind.hasSamples(timing));

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final missing = TimingKind.values
        .where((kind) => !kind.hasSamples(timing, turn: turn))
        .map((kind) => kind.copy(context.strings).$2)
        .join(context.strings.listSeparator);
    final hint = turn
        ? context.strings.thisToolLogsTimingForAWhole2
        : context.strings.perRequestEstimatesBasedOnLogTimestamps;
    final missingHint = missing.isEmpty
        ? null
        : context.strings.missingFromLogs0(missing);
    final scope = LensFocusTooltip(
      description: [hint, ?missingHint].join('\n'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hint),
          if (missingHint != null)
            Text(missingHint, style: p.text(11.5, p.muted)),
        ],
      ),
      child: Text(
        turn ? context.strings.perTurn : context.strings.perRequest2,
        style: scopeAsTitle && !turn
            ? p.text(14.5, null, FontWeight.w600)
            : p.text(12, p['clay']),
      ),
    );
    final metrics = Wrap(
      spacing: 24,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!scopeAsTitle) scope,
        for (final kind in TimingKind.values)
          if (kind.hasSamples(timing, turn: turn))
            TimingMetric(
              key: metricKey(kind),
              timing: timing,
              kind: kind,
              turn: turn,
              requestCount: requestCount,
            ),
      ],
    );
    return scopeAsTitle
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [scope, const SizedBox(height: 8), metrics],
          )
        : metrics;
  }
}

class TimingMetric extends StatelessWidget {
  const TimingMetric({
    super.key,
    required this.timing,
    required this.kind,
    this.turn = false,
    this.requestCount = 0,
  });
  final StatsTiming? timing;
  final TimingKind kind;
  final bool turn;
  final int requestCount;

  String source(String method, AppStrings strings) => switch (method) {
    'client_reported' => strings.timingReportedByTheClient,
    'log_timestamps' => strings.estimatedFromLogTimestamps,
    'content_event_proxy' => strings.estimatedFromReasoningStartEvents,
    _ => strings.unknownTimingSource,
  };

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final (label, shortName, hint) = kind.copy(context.strings);
    final n = turn
        ? timing?.turn?.turnCount ?? requestCount
        : timing?.requestCount ?? requestCount;
    final ttft = turn ? timing?.turn?.ttft : timing?.ttft;
    final speed = turn ? timing?.turn?.speed : timing?.speed;
    final throughput = turn ? timing?.turn?.throughput : timing?.throughput;
    final samples = switch (kind) {
      TimingKind.ttft => [
        for (final t in ttft ?? <StatsTtft>[])
          if (t.sampleCount > 0)
            (
              method: t.method,
              count: t.sampleCount,
              value: t.sampleCount == 1 || t.medianMs == t.p90Ms
                  ? context.strings.secondsDuration(
                      (t.medianMs / 1000).toStringAsFixed(2),
                    )
                  : context.strings.typicalAndSlowTiming(
                      (t.medianMs / 1000).toStringAsFixed(2),
                      (t.p90Ms / 1000).toStringAsFixed(2),
                    ),
            ),
      ],
      TimingKind.speed => [
        for (final t in speed ?? <StatsSpeed>[])
          if (t.sampleCount > 0)
            (
              method: t.method,
              count: t.sampleCount,
              value: context.strings.about0TokenS(
                t.tokensPerSecond.toStringAsFixed(1),
              ),
            ),
      ],
      TimingKind.throughput => [
        for (final t in throughput ?? <StatsThroughput>[])
          if (t.sampleCount > 0)
            (
              method: t.method,
              count: t.sampleCount,
              value: context.strings.about0TokenS(
                t.tokensPerSecond.toStringAsFixed(1),
              ),
            ),
      ],
    };
    if (samples.isEmpty) return const SizedBox.shrink();
    final primary = samples.firstWhere(
      (sample) => sample.method == 'client_reported',
      orElse: () => samples.first,
    );
    final multiple = samples.length > 1;
    final lines = <({String value, String detail})>[
      for (final sample in samples)
        (
          value: multiple
              ? '${sample.value} · ${source(sample.method, context.strings)}'
              : sample.value,
          detail: [
            if (sample.count < n)
              context.strings.timedRequestCoverage(
                toDisplayNumber(n),
                toDisplayNumber(sample.count),
              ),
            if (!multiple) source(sample.method, context.strings),
          ].join(' · '),
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(label, style: p.text(12, p.muted))),
            const SizedBox(width: 5),
            Tooltip(
              message: hint,
              child: Semantics(
                label: context.strings.about0(shortName),
                child: Container(
                  width: 14,
                  height: 14,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: p['line']),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '?',
                    style: p.text(10, p.muted).copyWith(height: 1),
                  ),
                ),
              ),
            ),
          ],
        ),
        LensFocusTooltip(
          description: [
            for (final line in lines) ...[
              line.value,
              if (line.detail.isNotEmpty) line.detail,
            ],
          ].join('\n'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (index, line) in lines.indexed) ...[
                if (index > 0) const SizedBox(height: 6),
                Text(line.value),
                if (line.detail.isNotEmpty)
                  Text(line.detail, style: p.text(11.5, p.muted)),
              ],
            ],
          ),
          child: Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _TimingValue(primary.value),
              if (multiple)
                Text(
                  context.strings.moreTimingEstimates(samples.length - 1),
                  style: p.text(11, p.muted),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TimingValue extends StatefulWidget {
  const _TimingValue(this.value);

  final String value;

  @override
  State<_TimingValue> createState() => _TimingValueState();
}

class _TimingValueState extends State<_TimingValue> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Text(
        widget.value,
        style: p
            .text(13, p.secondary)
            .copyWith(
              decoration: _hovered
                  ? TextDecoration.underline
                  : TextDecoration.none,
              decorationStyle: TextDecorationStyle.dashed,
              decorationColor: p.faint,
            ),
      ),
    );
  }
}
