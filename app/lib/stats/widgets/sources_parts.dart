import 'dart:async';

import 'package:flutter/material.dart';

import '../../stats_controller.dart';
import '../../stats_gateway.dart';
import '../logic/format.dart';
import '../logic/tools.dart';
import '../theme/palette.dart';
import 'motion.dart';
import 'primitives.dart';

// Arbitrary text sizes in SourcesPage.jsx inherit Tailwind's 1.5 line height.
TextStyle _sourceText(
  LensPalette p, [
  double size = 14,
  Color? color,
  FontWeight weight = FontWeight.w400,
]) => p.text(size, color, weight).copyWith(height: 1.5, letterSpacing: 0);
String _relative(String? iso, DateTime now) {
  final then = DateTime.tryParse(iso ?? '');
  if (then == null) return '—';
  final minutes = (now.difference(then).inMilliseconds / 60000 + .5).floor();
  return minutes < 1
      ? '刚刚'
      : minutes < 60
      ? '$minutes 分钟前'
      : minutes < 1440
      ? '${(minutes / 60 + .5).floor()} 小时前'
      : '${(minutes / 1440 + .5).floor()} 天前';
}

class SourcesTech extends StatefulWidget {
  const SourcesTech({super.key, this.title = '技术细节', required this.child});
  final String title;
  final Widget child;
  @override
  State<SourcesTech> createState() => _SourcesTechState();
}

class _SourcesTechState extends State<SourcesTech> {
  bool open = false;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p['fill-hover'],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: open,
            child: LensFocusOutline(
              child: TextButton(
                onPressed: () => setState(() => open = !open),
                style: TextButton.styleFrom(
                  foregroundColor: p.secondary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: open ? .25 : 0,
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : LensTokens.fast,
                      child: const Icon(Icons.chevron_right, size: 14),
                    ),
                    const SizedBox(width: 6),
                    Text(widget.title, style: _sourceText(p, 13, p.secondary)),
                  ],
                ),
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: DefaultTextStyle(
                style: _sourceText(p, 12.5, p.secondary),
                child: widget.child,
              ),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, {this.tone, this.check = false});
  final String label;
  final String? tone;
  final bool check;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final color = tone == null ? p.secondary : p[tone!];
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LensTokens.radii['pill']!),
        color: tone == null
            ? p['fill-hover']
            : color.withValues(alpha: tone == 'ok' ? .12 : .14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (check) ...[
            Icon(Icons.check, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: _sourceText(
              p,
              11.5,
              color,
              FontWeight.w500,
            ).copyWith(height: 20 / 11.5),
          ),
        ],
      ),
    );
  }
}

class SourcesSyncStatus extends StatelessWidget {
  const SourcesSyncStatus({
    super.key,
    required this.controller,
    this.run,
    this.result,
  });
  final StatsController controller;
  final StatsSourceRun? run;
  final StatsSync? result;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context), c = controller;
    final result = this.result;
    final problem = run == null
        ? '还没有同步过'
        : run!.status == 'running'
        ? '正在同步…'
        : run!.status == 'ok'
        ? null
        : run!.anomalyCount > 0
        ? '上次同步有 ${run!.anomalyCount} 处没读成功，其余已经更新'
        : '上次同步没有完成';
    final syncing =
        c.phase == StatsSyncPhase.running || c.phase == StatsSyncPhase.conflict;
    return LensCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: problem == null
                      ? [
                          BoxShadow(
                            color: p['ok'].withValues(alpha: .18),
                            spreadRadius: 3,
                          ),
                        ]
                      : null,
                ),
                child: SizedBox(
                  width: 7,
                  height: 7,
                  child: FittedBox(
                    child: SyncDot(
                      color: problem == null
                          ? p['ok']
                          : run != null && run!.status != 'running'
                          ? p['warn']
                          : p.faint,
                      revision: c.ledgerVersion,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      problem ??
                          '${_relative(run!.finishedAt, c.clock())}同步过，一切正常',
                      style: _sourceText(p, 14, null, FontWeight.w500),
                    ),
                    Text(
                      '每次打开 Token Lens 会自动同步一次，也可以手动同步。',
                      style: _sourceText(p, 12.5, p.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Opacity(
                opacity: syncing ? .6 : 1,
                child: SizedBox(
                  height: 34,
                  child: Theme(
                    // The old sync action uses text-white in both schemes.
                    data: Theme.of(context)
                        .copyWith(brightness: Brightness.light),
                    child: LensButton(
                      label: syncing ? '同步中…' : '立即同步',
                      variant: 'primary',
                      icon: Icons.refresh,
                      spinning: syncing,
                      onPressed: syncing ? null : () => unawaited(c.sync()),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (c.phase == StatsSyncPhase.success && result != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                '同步完成：扫描 ${result.fileCount} 个文件，新增 ${result.inserted} 条，有变化的 ${result.updated} 条，用时 ${(result.durationMs / 1000).toStringAsFixed(1)} 秒。',
                style: _sourceText(p, 12.5, p.secondary),
              ),
            ),
          ],
          if (c.phase == StatsSyncPhase.conflict) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text('已有同步在执行，正在等待完成', style: _sourceText(p)),
            ),
          ],
          if (c.warning != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                '同步完成，有异常警告：${c.warning}',
                style: _sourceText(p, 12.5, p.secondary),
              ),
            ),
          ],
          if (c.phase == StatsSyncPhase.error) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                '同步失败：${c.syncError ?? '请求失败'}',
                style: _sourceText(p, 12.5, p['danger']),
              ),
            ),
          ],
          if (run != null) ...[
            const SizedBox(height: 12),
            SourcesTech(
              title: '上次同步的技术细节',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '读了 ${toDisplayNumber(run!.attempted)} 条记录：新增 ${run!.inserted} 条，有变化的 ${run!.updated} 条，没变的 ${toDisplayNumber(run!.unchanged)} 条，跳过 ${run!.rejected} 条。',
                  ),
                  if (run!.anomalies.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    for (final anomaly in run!.anomalies)
                      Text(
                        '• $anomaly',
                        style: p
                            .text(12, p.secondary)
                            .copyWith(
                              fontFamily: LensPalette.monoFonts.first,
                              fontFamilyFallback: LensPalette.monoFonts
                                  .skip(1)
                                  .toList(),
                            ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class SourcesToolCard extends StatelessWidget {
  const SourcesToolCard({
    super.key,
    required this.item,
    required this.monthTokens,
    required this.controller,
    required this.onDetail,
  });
  final StatsSource item;
  final int monthTokens;
  final StatsController controller;
  final VoidCallback onDetail;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final real = item.evidence == 'A';
    final mode = switch (item.recordMode) {
      'cumulative' => ('只记录每个会话的总数', '能看到每个会话用了多少，看不到会话里每次请求的时间。'),
      'mixed' => ('大多按请求记录', '有的会话只有一条总数，这些会话看不到时间线。'),
      _ => ('每次请求都有记录', '能看到每次请求的时间、模型和用量。'),
    };
    final checks = [
      ('时间不在合理范围', item.checks.timeOutOfRange, '条'),
      ('单次请求超过 1 亿 token', item.checks.hugeRequests, '条'),
      ('没有模型名、不计价', item.checks.nullModel, '条'),
      ('同一会话混用两种记录方式', item.checks.mixedKindSessions, '个会话'),
    ].where((check) => check.$2 > 0).toList();
    final status = [
      if (item.recordMode == 'event') '每次请求都有记录',
      if (item.retention.logsGone == 0) '记录完整',
      if (checks.isEmpty) '自检正常',
    ];
    Widget text(String value, {bool muted = false, bool balance = false}) =>
        Text(
          balance ? keepTailTogether(value) : value,
          style: _sourceText(p, muted ? 12.5 : 13, muted ? p.muted : p.ink),
        );
    Widget field(String label, Widget value) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: text(label, muted: true),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: value),
      ],
    );
    Widget stack(List<Widget> children, {double gap = 0}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0 && gap > 0) SizedBox(height: gap),
          children[i],
        ],
      ],
    );
    Widget note(String label, String value, {String? tone}) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: _Pill(label, tone: tone),
        ),
        const SizedBox(width: 8),
        Expanded(child: text(value, balance: true)),
      ],
    );
    return LensCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ToolTile(item.source, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: stack([
                  Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        toolOf(item.source).name,
                        style: _sourceText(p, 15, null, FontWeight.w600),
                      ),
                      const _Pill('已接入', tone: 'ok', check: true),
                    ],
                  ),
                  Wrap(
                    runSpacing: 2,
                    children: [
                      Text(
                        '最近一次使用 ${_relative(item.lastObservedAt, controller.clock())} · ',
                        maxLines: 1,
                        softWrap: false,
                        style: _sourceText(p, 12.5, p.muted),
                      ),
                      Text(
                        '本月 ${tokenCount(monthTokens, mode: controller.preferences.tokenMode, unitSystem: controller.preferences.unitSystem)} token · ',
                        maxLines: 1,
                        softWrap: false,
                        style: _sourceText(p, 12.5, p.muted),
                      ),
                      Text(
                        '${toDisplayNumber(item.records)} 条记录',
                        maxLines: 1,
                        softWrap: false,
                        style: _sourceText(p, 12.5, p.muted),
                      ),
                    ],
                  ),
                ]),
              ),
              const SizedBox(width: 12),
              Semantics(
                link: true,
                child: LensButton(
                  label: '看用量',
                  size: 'link',
                  variant: 'ghost',
                  icon: Icons.arrow_forward,
                  trailingIcon: true,
                  onPressed: onDetail,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          stack([
            field(
              '状态',
              Wrap(
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message: real
                            ? '拿真实使用的日志逐条对过，数字可靠。'
                            : '格式按公开资料和样例确认，大概率没问题；对不上的话可以反馈。',
                        child: _Pill(
                          real ? '用真实日志核对过' : '只用样例日志核对过',
                          tone: real ? 'ok' : null,
                          check: real,
                        ),
                      ),
                      if (status.isNotEmpty) text(' · ', muted: true),
                    ],
                  ),
                  for (var i = 0; i < status.length; i++)
                    Text(
                      '${status[i]}${i < status.length - 1 ? ' · ' : ''}',
                      maxLines: 1,
                      softWrap: false,
                      style: _sourceText(p, 12.5, p.muted),
                    ),
                ],
              ),
            ),
            if (item.recordMode != 'event')
              field(
                '记录方式',
                stack([
                  text(mode.$1),
                  text(mode.$2, muted: true, balance: true),
                ]),
              ),
            if (item.retention.logsGone > 0)
              field(
                '日志留存',
                stack([
                  text(
                    '${toDisplayNumber(item.retention.reviewable)} 条还能对照原始日志复核',
                  ),
                  text(
                    '另有 ${toDisplayNumber(item.retention.logsGone)} 条的日志已经不在了，照常计入总数，但没法再复核。',
                    muted: true,
                  ),
                ]),
              ),
            if (checks.isNotEmpty)
              field(
                '自检',
                stack([
                  for (final check in checks)
                    note(
                      '待查',
                      '${check.$1}：${toDisplayNumber(check.$2)} ${check.$3}',
                      tone: 'warn',
                    ),
                ], gap: 6),
              ),
            if (item.notes.isNotEmpty)
              field(
                '要知道的',
                stack([
                  for (final n in item.notes)
                    note(
                      n.impact == 'affects' ? '有影响' : '已处理',
                      n.text,
                      tone: n.impact == 'affects' ? 'warn' : null,
                    ),
                ], gap: 6),
              ),
          ], gap: 8),
          const SizedBox(height: 12),
          SourcesTech(
            child: stack([
              field(
                '来源 ID',
                Text(
                  item.source,
                  style: p
                      .text(12, p.secondary)
                      .copyWith(
                        fontFamily: LensPalette.monoFonts.first,
                        fontFamilyFallback: LensPalette.monoFonts
                            .skip(1)
                            .toList(),
                      ),
                ),
              ),
              field('证据等级', Text(real ? 'A（真实样本）' : 'B（合成样本）')),
              if (item.limits.isNotEmpty)
                field(
                  '口径原文',
                  stack([for (final limit in item.limits) Text(limit)]),
                ),
            ], gap: 4),
          ),
        ],
      ),
    );
  }
}

class SourcesMissingTools extends StatefulWidget {
  const SourcesMissingTools({super.key, required this.ids});
  final List<String> ids;
  @override
  State<SourcesMissingTools> createState() => _SourcesMissingToolsState();
}

class _SourcesMissingToolsState extends State<SourcesMissingTools> {
  bool open = false;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return LensCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: open,
            child: LensFocusOutline(
              child: TextButton(
                onPressed: () => setState(() => open = !open),
                style: TextButton.styleFrom(
                  foregroundColor: p.secondary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: open ? .25 : 0,
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : LensTokens.fast,
                      child: const Icon(Icons.chevron_right, size: 14),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '还有 ${widget.ids.length} 个支持的工具没在这台电脑上找到',
                        style: _sourceText(p, 13.5, p.secondary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns = MediaQuery.sizeOf(context).width >= 768
                      ? 4
                      : 2;
                  return Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      for (final id in widget.ids)
                        SizedBox(
                          width:
                              (constraints.maxWidth - 16 * (columns - 1)) /
                              columns,
                          child: Row(
                            children: [
                              Opacity(
                                opacity: .6,
                                child: ColorFiltered(
                                  colorFilter: const ColorFilter.matrix([
                                    .2126,
                                    .7152,
                                    .0722,
                                    0,
                                    0,
                                    .2126,
                                    .7152,
                                    .0722,
                                    0,
                                    0,
                                    .2126,
                                    .7152,
                                    .0722,
                                    0,
                                    0,
                                    0,
                                    0,
                                    0,
                                    1,
                                    0,
                                  ]),
                                  child: ToolTile(id, size: 20),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  toolOf(id).name,
                                  style: _sourceText(p, 13, p.muted),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
              child: Text(
                '装上并用过一次以后，点「立即同步」就会出现在上面。',
                style: _sourceText(p, 12.5, p.muted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
