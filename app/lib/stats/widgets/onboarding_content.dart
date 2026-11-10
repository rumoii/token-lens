import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../smooth_wheel.dart';
import '../../stats_controller.dart';
import '../../stats_gateway.dart';
import '../logic/format.dart';
import '../logic/tools.dart';
import '../theme/palette.dart';
import 'motion.dart';
import 'primitives.dart';
import 'resource.dart';

enum OnboardingStep { discover, counting, done }

class OnboardingContent extends StatefulWidget {
  const OnboardingContent({
    super.key,
    required this.controller,
    required this.step,
    required this.discovery,
    required this.completed,
    required this.onStart,
    required this.onRescan,
    required this.onEnter,
  });
  final StatsController controller;
  final OnboardingStep step;
  final LensResource<StatsDiscovery> discovery;
  final LensResource<StatsSummary> completed;
  final VoidCallback onStart, onRescan, onEnter;
  @override
  State<OnboardingContent> createState() => _OnboardingContentState();
}

class _OnboardingContentState extends State<OnboardingContent> {
  final scroll = SmoothWheelController();
  bool moreOpen = false;
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final counting = widget.step == OnboardingStep.counting;
    final done = widget.step == OnboardingStep.done;
    final found = widget.discovery.data?.sources ?? <StatsDiscoveredSource>[];
    final supported = widget.discovery.data?.supported ?? tools.length;
    final missing = tools.keys.where((id) => !found.any((s) => s.source == id));
    final missingCount = math.max(0, supported - found.length);
    final c = widget.controller;
    Widget text(
      String value,
      double size, {
      Color? color,
      FontWeight weight = FontWeight.w400,
      TextAlign? align,
    }) => Text(
      value,
      textAlign: align,
      style: p.text(size, color, weight).copyWith(height: 1.5),
    );
    Widget statusText(String value) => Semantics(
      liveRegion: true,
      child: text(value, 12.5, color: p.secondary, align: TextAlign.center),
    );
    Widget action(
      String label,
      VoidCallback? onPressed, {
      bool arrow = false,
    }) => Opacity(
      opacity: onPressed == null ? .45 : 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: p.smallShadow,
        ),
        child: TextButton(
          onPressed: onPressed,
          style:
              TextButton.styleFrom(
                fixedSize: const Size.fromHeight(44),
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: p['clay'],
                foregroundColor: p['text-inverse'],
                disabledBackgroundColor: p['clay'],
                disabledForegroundColor: p['text-inverse'],
                textStyle: p
                    .text(16, null, FontWeight.w500)
                    .copyWith(height: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ).copyWith(
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.hovered)
                      ? p['clay-hover']
                      : p['clay'],
                ),
              ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label),
              if (arrow) ...[
                const SizedBox(width: 6),
                const Icon(Icons.arrow_forward, size: 14),
              ],
            ],
          ),
        ),
      ),
    );
    final title = Text(
      done ? '统计好了' : '欢迎使用 Token Lens',
      textAlign: TextAlign.center,
      style: p
          .serif(width >= 768 ? 34 : 28, weight: FontWeight.w500)
          .copyWith(
            height: 1.5,
            letterSpacing: -(width >= 768 ? 34 : 28) * .01,
          ),
    );
    final summary = widget.completed.fresh ? widget.completed.data : null;
    final firstSeen = DateTime.tryParse(summary?.activity.firstSeen ?? '')
        ?.toLocal();
    final firstSeenText = firstSeen == null
        ? '—'
        : '${firstSeen.year} 年 ${firstSeen.month} 月 ${firstSeen.day} 日';
    return Material(
      color: p['surface-0'],
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _OnboardingGlow(p['clay'])),
            ),
          ),
          SingleChildScrollView(
            controller: scroll,
            padding: EdgeInsets.fromLTRB(
              width >= 768 ? 20 : 14,
              width >= 768 ? 56 : 32,
              width >= 768 ? 20 : 14,
              40,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: done
                          ? Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: p['clay'],
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x8cd97757),
                                    offset: Offset(0, 8),
                                    blurRadius: 24,
                                    spreadRadius: -6,
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.check,
                                size: 30,
                                color: p['tile-ink'],
                              ),
                            )
                          : ExcludeSemantics(
                              child: SizedBox(
                                key: const Key('onboarding-mark'),
                                width: 48,
                                height: 48,
                                child: CustomPaint(painter: _OnboardingMark(p)),
                              ),
                            ),
                    ),
                    const SizedBox(height: 18),
                    Semantics(header: true, child: title),
                    const SizedBox(height: 6),
                    text(
                      done
                          ? '最早的一条记录在 $firstSeenText。更早的用量，工具已经没有保留日志，所以统计不到。以后每次打开都会自动补上新的用量。'
                          : '看看你的 AI 编程工具用了多少 token、按公开价值多少钱。',
                      16,
                      color: p.secondary,
                      align: TextAlign.center,
                    ),
                    const SizedBox(height: 28),
                    if (done) ...[
                      LensCard(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final entry in [
                              (
                                summary == null
                                    ? '—'
                                    : tokenCount(
                                        summary.totals.grossTokens,
                                        mode: c.preferences.tokenMode,
                                        unitSystem: c.preferences.unitSystem,
                                      ),
                                'token',
                              ),
                              (
                                summary == null
                                    ? '—'
                                    : toDisplayNumber(
                                        summary.totals.recordCount,
                                      ),
                                '条记录',
                              ),
                              (
                                summary == null
                                    ? '—'
                                    : toDisplayNumber(
                                        summary.activity.sessions,
                                      ),
                                '个会话',
                              ),
                            ].indexed)
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 16,
                                  ),
                                  foregroundDecoration: BoxDecoration(
                                    border: entry.$1 == 0
                                        ? null
                                        : Border(
                                            left: BorderSide(
                                              width: LensPalette.hairline(
                                                context,
                                              ),
                                              color: p['line-soft'],
                                            ),
                                          ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Tooltip(
                                        message:
                                            entry.$1 == 0 && summary != null
                                            ? '${toDisplayNumber(summary.totals.grossTokens)} token'
                                            : '',
                                        child: Text(
                                          entry.$2.$1,
                                          style: p
                                              .serif(width >= 1024 ? 26 : 20)
                                              .copyWith(height: 1.2),
                                        ),
                                      ),
                                      text(entry.$2.$2, 12.5, color: p.muted),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final item in found)
                            ToolTile(item.source, size: 32),
                        ],
                      ),
                      const SizedBox(height: 24),
                      if (c.warning != null) ...[
                        statusText('同步完成，有异常警告：${c.warning}'),
                        const SizedBox(height: 12),
                      ],
                      if (widget.completed.error != null) ...[
                        ResourceBlock(
                          resource: widget.completed,
                          builder: (_) => const SizedBox(),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Center(child: action('去看看', widget.onEnter, arrow: true)),
                    ] else ...[
                      LensCard(
                        child: ResourceBlock(
                          resource: widget.discovery,
                          builder: (_) => Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (counting)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    14,
                                    18,
                                    6,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Semantics(
                                        liveRegion: true,
                                        child: text(
                                          '正在读取日志…',
                                          14,
                                          weight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        child: SizedBox(
                                          height: 6,
                                          child: ColoredBox(
                                            color: p['fill-hover'],
                                            child: LayoutBuilder(
                                              builder: (context, size) => LensLoop(
                                                duration: const Duration(
                                                  milliseconds: 2200,
                                                ),
                                                builder: (context, value) => Align(
                                                  alignment: Alignment(
                                                    -1 +
                                                        2 *
                                                            Curves.easeInOut
                                                                .transform(
                                                                  1 -
                                                                      (value * 2 -
                                                                              1)
                                                                          .abs(),
                                                                ),
                                                    0,
                                                  ),
                                                  child: Container(
                                                    width: size.maxWidth * .4,
                                                    decoration: BoxDecoration(
                                                      color: p['clay'],
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            999,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (!counting)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    16,
                                    18,
                                    6,
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: [
                                      text(
                                        '在这台电脑上找到 ${found.length} 个工具',
                                        14,
                                        weight: FontWeight.w600,
                                      ),
                                      text(
                                        '支持 $supported 个',
                                        12.5,
                                        color: p.muted,
                                      ),
                                    ],
                                  ),
                                ),
                              if (found.isEmpty && !counting)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    4,
                                    18,
                                    16,
                                  ),
                                  child: text(
                                    '这台电脑上还没找到支持的工具的日志。装好并用过其中任意一个后再回来。',
                                    13,
                                    color: p.muted,
                                  ),
                                )
                              else
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    4,
                                    10,
                                    8,
                                  ),
                                  child: Column(
                                    children: [
                                      for (final item in found.indexed)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 9,
                                          ),
                                          foregroundDecoration: BoxDecoration(
                                            border: item.$1 == 0
                                                ? null
                                                : Border(
                                                    top: BorderSide(
                                                      width:
                                                          LensPalette.hairline(
                                                            context,
                                                          ),
                                                      color: p['line-soft'],
                                                    ),
                                                  ),
                                          ),
                                          child: Row(
                                            children: [
                                              ToolTile(
                                                item.$2.source,
                                                size: 32,
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    text(
                                                      toolOf(item.$2.source)
                                                          .name,
                                                      14,
                                                      weight: FontWeight.w500,
                                                    ),
                                                    text(
                                                      '${toDisplayNumber(item.$2.files)} 个日志文件',
                                                      12.5,
                                                      color: p.muted,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (counting)
                                                text(
                                                  '读取中…',
                                                  12.5,
                                                  color: p.muted,
                                                )
                                              else ...[
                                                Icon(
                                                  Icons.check,
                                                  size: 14,
                                                  color: p['ok'],
                                                ),
                                                const SizedBox(width: 4),
                                                text(
                                                  '找到',
                                                  12.5,
                                                  color: p['ok'],
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              if (!counting && missingCount > 0) ...[
                                Container(
                                  foregroundDecoration: BoxDecoration(
                                    border: Border(
                                      top: BorderSide(
                                        width: LensPalette.hairline(context),
                                        color: p['line-soft'],
                                      ),
                                    ),
                                  ),
                                  child: Semantics(
                                    button: true,
                                    expanded: moreOpen,
                                    child: InkWell(
                                      onTap: () =>
                                          setState(() => moreOpen = !moreOpen),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 18,
                                          vertical: 12,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              moreOpen
                                                  ? Icons.expand_more
                                                  : Icons.chevron_right,
                                              size: 14,
                                              color: p.secondary,
                                            ),
                                            const SizedBox(width: 6),
                                            Flexible(
                                              child: text(
                                                '还有 $missingCount 个支持的工具没在这台电脑上找到',
                                                13,
                                                color: p.secondary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (moreOpen)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      18,
                                      0,
                                      18,
                                      16,
                                    ),
                                    child: LayoutBuilder(
                                      builder: (context, size) => Wrap(
                                        spacing: 16,
                                        runSpacing: 6,
                                        children: [
                                          for (final id in missing)
                                            SizedBox(
                                              width: (size.maxWidth - 16) / 2,
                                              child: Row(
                                                children: [
                                                  Opacity(
                                                    opacity: .65,
                                                    child: ColorFiltered(
                                                      colorFilter:
                                                          const ColorFilter.matrix(
                                                            [
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
                                                            ],
                                                          ),
                                                      child: ToolTile(
                                                        id,
                                                        size: 20,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Flexible(
                                                    child: text(
                                                      toolOf(id).name,
                                                      13,
                                                      color: p.muted,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (counting && c.phase == StatsSyncPhase.conflict) ...[
                        statusText('已有同步在执行，正在等待完成'),
                        const SizedBox(height: 12),
                      ],
                      Center(
                        child: found.isEmpty && !counting
                            ? action(
                                '重新检测',
                                widget.discovery.loading
                                    ? null
                                    : widget.onRescan,
                              )
                            : action(
                                counting
                                    ? '统计中…'
                                    : c.syncError != null
                                    ? '重试'
                                    : '开始统计',
                                counting ? null : widget.onStart,
                              ),
                      ),
                      if (c.syncError != null) ...[
                        const SizedBox(height: 12),
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: Semantics(
                              liveRegion: true,
                              child: text(
                                c.syncError!,
                                12.5,
                                color: p['danger'],
                                align: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.lock_outline, size: 14, color: p.muted),
                          const SizedBox(width: 6),
                          Flexible(
                            child: text(
                              '只读取本机日志，不上传任何内容，也不改动这些工具。',
                              12.5,
                              color: p.muted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingGlow extends CustomPainter {
  const _OnboardingGlow(this.clay);
  final Color clay;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, -size.height * .1);
    canvas.scale(1200, 500);
    canvas.drawCircle(
      Offset.zero,
      .7,
      Paint()
        ..shader = RadialGradient(
          colors: [clay.withValues(alpha: .09), clay.withValues(alpha: 0)],
        ).createShader(const Rect.fromLTRB(-.7, -.7, .7, .7)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OnboardingGlow oldDelegate) => clay != oldDelegate.clay;
}

class _OnboardingMark extends CustomPainter {
  const _OnboardingMark(this.p);
  final LensPalette p;
  @override
  void paint(Canvas canvas, Size size) {
    // OnboardingPage Mark48 uses its own 24 x 24 SVG, not the sidebar mark.
    canvas.scale(size.width / 24, size.height / 24);
    final line = Paint()
      ..color = p['line-strong']
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(const Offset(12, 12), 8.5, line);
    canvas.drawCircle(
      const Offset(12, 12),
      4.5,
      Paint()
        ..color = p['clay']
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(const Offset(12, 12), 1.4, Paint()..color = p['clay']);
    for (final points in [
      (const Offset(12, 1.5), const Offset(12, 4.5)),
      (const Offset(12, 19.5), const Offset(12, 22.5)),
      (const Offset(1.5, 12), const Offset(4.5, 12)),
      (const Offset(19.5, 12), const Offset(22.5, 12)),
    ]) {
      canvas.drawLine(points.$1, points.$2, line);
    }
  }

  @override
  bool shouldRepaint(_OnboardingMark oldDelegate) =>
      p.dark != oldDelegate.p.dark;
}
