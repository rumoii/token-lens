import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../stats_gateway.dart';
import '../logic/format.dart';
import '../theme/palette.dart';

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
    final scope = Tooltip(
      message: turn
          ? context.strings.thisToolLogsTimingForAWhole2
          : context.strings.perRequestEstimatesBasedOnLogTimestamps,
      child: Text(
        turn ? context.strings.perTurn : context.strings.perRequest2,
        style: p.text(12, p['clay']),
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
        if (missing.isNotEmpty)
          Text(
            context.strings.missingFromLogs0(missing),
            style: p.text(11.5, p.muted),
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
        for (final sample in samples)
          Tooltip(
            message: source(sample.method, context.strings),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (samples.length > 1)
                  Text(
                    source(sample.method, context.strings),
                    style: p.text(11, p.muted),
                  ),
                Text(sample.value, style: p.text(13, p.secondary)),
                if (sample.count < n)
                  Text(
                    context.strings.timedRequestCoverage(
                      toDisplayNumber(n),
                      toDisplayNumber(sample.count),
                    ),
                    style: p.text(11, p.muted),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
