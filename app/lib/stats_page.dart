import 'dart:async';

import 'package:flutter/material.dart';

import 'stats_controller.dart';
import 'stats_gateway.dart';

class StatsPage extends StatelessWidget {
  const StatsPage({super.key, required this.controller});
  final StatsController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final overview = controller.overview;
      return Scaffold(
        appBar: AppBar(
          title: const Text('统计总览'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton.icon(
                onPressed: controller.busy
                    ? null
                    : () => unawaited(controller.sync()),
                icon: controller.busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(controller.busy ? '同步中…' : '同步'),
              ),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('全部历史 · USD', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(_status(overview?.lastRun)),
              ),
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(controller.error!),
                  ),
                ),
              if (overview == null) ...[
                const SizedBox(height: 32),
                if (controller.loading)
                  const Center(child: CircularProgressIndicator())
                else
                  const Text('暂无可显示的统计。'),
              ] else ...[
                const SizedBox(height: 20),
                Wrap(
                  spacing: 16,
                  runSpacing: 12,
                  children: [
                    _metric(
                      context,
                      '总 Token',
                      _tokens(
                        overview.totals.grossTokens,
                        overview.totals.recordCount,
                        [
                          overview.totals.inputTokens,
                          overview.totals.outputTokens,
                          overview.totals.cacheReadTokens,
                          overview.totals.cacheWriteTokens,
                        ],
                      ),
                    ),
                    _metric(
                      context,
                      '总金额 (USD)',
                      _money(overview.totals.costUsd),
                    ),
                  ],
                ),
                if (overview.totals.unpricedRecords > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '未定价 ${overview.totals.unpricedRecords} 条，金额仅含已定价记录。',
                    ),
                  ),
                if (overview.totals.recordCount == 0)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text('尚无统计记录，点击同步读取本机日志。'),
                  ),
                const SizedBox(height: 24),
                _table(context, '按来源', '来源', overview.sources),
                const SizedBox(height: 24),
                _table(context, '按模型', '模型', overview.models),
                if (overview.generatedAt != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text('统计时间：${overview.generatedAt}'),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );

  String _status(StatsRun? run) {
    if (controller.busy) return '正在读取本机日志并同步统计。';
    if (run == null) return '尚未采集';
    final label = switch (run.status) {
      'ok' => '成功',
      'completed_with_anomalies' => '已完成，含异常',
      'running' => '正在采集',
      'failed' => '失败',
      'abandoned' => '中断',
      _ => '未知',
    };
    final time = run.finishedAt ?? run.startedAt;
    return '上次采集：$label${time == null ? '' : ' · ${DateTime.fromMillisecondsSinceEpoch(time * 1000).toLocal()}'}';
  }

  String _tokens(int gross, int count, List<int?> fields) =>
      count > 0 && fields.every((value) => value == null) ? '未知' : '$gross';
  String _money(String? usd) => usd == null ? '未知' : '\$$usd';
  Widget _metric(BuildContext context, String label, String value) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: SizedBox(
        width: 240,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 8),
            Text(value, style: Theme.of(context).textTheme.headlineMedium),
          ],
        ),
      ),
    ),
  );

  Widget _table(
    BuildContext context,
    String title,
    String dimension,
    List<StatsGroup> rows,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      const SizedBox(height: 8),
      if (rows.isEmpty)
        const Text('暂无记录')
      else
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: [
              DataColumn(label: Text(dimension)),
              const DataColumn(label: Text('Token'), numeric: true),
              const DataColumn(label: Text('金额 (USD)'), numeric: true),
              const DataColumn(label: Text('状态')),
            ],
            rows: rows
                .map(
                  (row) => DataRow(
                    cells: [
                      DataCell(Text(row.key ?? '未知')),
                      DataCell(
                        Text(
                          _tokens(row.grossTokens, row.recordCount, [
                            row.inputTokens,
                            row.outputTokens,
                            row.cacheReadTokens,
                            row.cacheWriteTokens,
                          ]),
                        ),
                      ),
                      DataCell(Text(_money(row.costUsd))),
                      DataCell(
                        Text(
                          row.unpricedRecords > 0
                              ? '未定价 ${row.unpricedRecords} 条'
                              : '已定价',
                        ),
                      ),
                    ],
                  ),
                )
                .toList(),
          ),
        ),
    ],
  );
}
