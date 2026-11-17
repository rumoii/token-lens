import 'package:flutter/material.dart';

import '../../stats_gateway.dart';
import '../logic/format.dart';
import '../theme/palette.dart';

enum TimingKind {
  ttft(
    '首字（开始回复前要等）',
    '首字',
    '从发出请求到看到第一段输出（含思考）的时间。‘一般’是一半请求不超过这个时间，‘慢时’是九成请求不超过这个时间。',
  ),
  speed('速度（回复时每秒出多少）', '速度', '模型开始输出后，每秒生成的 token 数。'),
  throughput('平均速度（算上等待）', '平均速度', '整次请求的输出 token 除以总耗时，等待时间也算在内，所以通常比“速度”低。');

  const TimingKind(this.label, this.shortName, this.hint);
  final String label, shortName, hint;

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
        .map((kind) => kind.shortName)
        .join('、');
    final scope = Tooltip(
      message: turn
          ? '这个工具只按一整轮对话记录时间，一轮里可能有多次请求，不能和其他工具的‘每次请求’直接比。'
          : '按每次请求统计，数字是从日志时间推算的约值。',
      child: Text(turn ? '每轮对话' : '每次请求', style: p.text(12, p['clay'])),
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
          Text('日志里没记：$missing', style: p.text(11.5, p.muted)),
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

  String source(String method) => switch (method) {
    'client_reported' => '客户端记录的计时',
    'log_timestamps' => '按日志时间戳估算',
    'content_event_proxy' => '按推理开始事件估算',
    _ => '计时来源未知',
  };

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
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
                  ? '${(t.medianMs / 1000).toStringAsFixed(2)} 秒'
                  : '一般 ${(t.medianMs / 1000).toStringAsFixed(2)} 秒，慢时 ${(t.p90Ms / 1000).toStringAsFixed(2)} 秒',
            ),
      ],
      TimingKind.speed => [
        for (final t in speed ?? <StatsSpeed>[])
          if (t.sampleCount > 0)
            (
              method: t.method,
              count: t.sampleCount,
              value: '约 ${t.tokensPerSecond.toStringAsFixed(1)} token/s',
            ),
      ],
      TimingKind.throughput => [
        for (final t in throughput ?? <StatsThroughput>[])
          if (t.sampleCount > 0)
            (
              method: t.method,
              count: t.sampleCount,
              value: '约 ${t.tokensPerSecond.toStringAsFixed(1)} token/s',
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
            Flexible(child: Text(kind.label, style: p.text(12, p.muted))),
            const SizedBox(width: 5),
            Tooltip(
              message: kind.hint,
              child: Semantics(
                label: '${kind.shortName}说明',
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
            message: source(sample.method),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (samples.length > 1)
                  Text(source(sample.method), style: p.text(11, p.muted)),
                Text(sample.value, style: p.text(13, p.secondary)),
                if (sample.count < n)
                  Text(
                    '${toDisplayNumber(n)} 次里 ${toDisplayNumber(sample.count)} 次有记录',
                    style: p.text(11, p.muted),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
