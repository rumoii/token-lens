import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../theme/palette.dart';
import '../logic/tools.dart';
import '../logic/format.dart';
import 'motion.dart';

class LensCard extends StatelessWidget {
  const LensCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 14,
  });
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: LensPalette.of(context).surface,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: LensPalette.of(context).cardShadow,
    ),
    child: child,
  );
}

class LensButton extends StatelessWidget {
  const LensButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.variant = 'secondary',
    this.size = 'md',
    this.trailingIcon = false,
    this.spinning = false,
  });
  final String label, variant, size;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool trailingIcon;
  final bool spinning;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final h =
        const {
          'xs': 24.0,
          'sm': 28.0,
          'md': 32.0,
          'lg': 40.0,
          'link': 24.0,
          'sidebar': 30.0,
        }[size] ??
        32;
    return Semantics(
      button: true,
      label: label,
      enabled: onPressed != null,
      child: TextButton(
        onPressed: onPressed,
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, h)),
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: size == 'link'
                  ? 6
                  : size == 'xs' || size == 'sidebar'
                  ? 8
                  : 12,
            ),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          textStyle: WidgetStatePropertyAll(
            p.text(
              size == 'link'
                  ? 12.5
                  : size == 'sidebar'
                  ? 12
                  : size == 'xs'
                  ? 11
                  : size == 'sm'
                  ? 12
                  : 14,
              null,
              FontWeight.w500,
            ),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => variant == 'primary'
                ? p['clay']
                : states.contains(WidgetState.hovered)
                ? p['fill-active']
                : variant == 'ghost'
                ? LensPalette.transparent
                : p['fill-hover'],
          ),
          foregroundColor: WidgetStatePropertyAll(
            variant == 'primary' ? p['text-inverse'] : p.secondary,
          ),
          overlayColor: WidgetStatePropertyAll(p['fill-hover']),
        ),
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null && !trailingIcon) ...[
                spinning
                    ? LensLoop(
                        duration: const Duration(seconds: 1),
                        builder: (context, v) => Transform.rotate(
                          angle: v * math.pi * 2,
                          child: Icon(icon, size: 14),
                        ),
                      )
                    : Icon(icon, size: 14),
                const SizedBox(width: 6),
              ],
              Text(label),
              if (icon != null && trailingIcon) ...[
                const SizedBox(width: 4),
                Icon(icon, size: 12),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class LensBadge extends StatelessWidget {
  const LensBadge(this.label, {super.key, this.tone = 'neutral'});
  final String label, tone;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final color = tone == 'clay'
        ? p['clay']
        : ['ok', 'warn', 'danger'].contains(tone)
        ? p[tone]
        : p.secondary;
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: tone == 'clay' ? p['clay-wash'] : p['fill-hover'],
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: p.text(11, color, FontWeight.w500)),
    );
  }
}

class LensSegmented extends StatefulWidget {
  const LensSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.label,
    this.small = false,
  });
  final Map<String, String> options;
  final String value, label;
  final ValueChanged<String> onChanged;
  final bool small;
  @override
  State<LensSegmented> createState() => _LensSegmentedState();
}

class _LensSegmentedState extends State<LensSegmented>
    with SingleTickerProviderStateMixin {
  late final step = AnimationController.unbounded(
    vsync: this,
    value: index.toDouble(),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      step.stop();
      step.value = index.toDouble();
    }
  }

  int get index => widget.options.keys
      .toList()
      .indexOf(widget.value)
      .clamp(0, widget.options.length - 1);
  @override
  void didUpdateWidget(LensSegmented old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      if (MediaQuery.disableAnimationsOf(context)) {
        step.stop();
        step.value = index.toDouble();
      } else {
        step.animateWith(
          SpringSimulation(
            const SpringDescription(mass: 1, stiffness: 600, damping: 30),
            step.value,
            index.toDouble(),
            step.velocity,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    step.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final widths = [
      for (final e in widget.options.entries)
        e.key == 'custom'
            ? 14.0
            : (TextPainter(
                text: TextSpan(
                  text: e.value,
                  style: p.text(12, null, FontWeight.w500),
                ),
                textDirection: TextDirection.ltr,
              )..layout()).width,
    ];
    final width =
            widths.reduce(math.max) + (widget.options.length == 5 ? 18 : 20),
        height = widget.small ? 28.0 : 32.0;
    return Semantics(
      label: widget.label,
      container: true,
      child: Container(
        width: width * widths.length + 4,
        height: height,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: p['fill-hover'],
          borderRadius: BorderRadius.circular(999),
        ),
        child: Stack(
          children: [
            AnimatedBuilder(
              animation: step,
              builder: (context, _) => Transform.translate(
                offset: Offset(step.value * width, 0),
                child: Container(
                  width: width,
                  height: height - 4,
                  decoration: BoxDecoration(
                    color: p.surface,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: p.smallShadow,
                  ),
                ),
              ),
            ),
            Row(
              children: [
                for (final e in widget.options.entries)
                  Semantics(
                    label: e.value,
                    selected: e.key == widget.value,
                    button: true,
                    child: InkWell(
                      onTap: () => widget.onChanged(e.key),
                      borderRadius: BorderRadius.circular(999),
                      child: SizedBox(
                        width: width,
                        height: height - 4,
                        child: Center(
                          child: e.key == 'custom'
                              ? Tooltip(
                                  message: '自定义',
                                  child: Icon(
                                    Icons.calendar_month_outlined,
                                    size: 14,
                                    color: p.muted,
                                  ),
                                )
                              : Text(
                                  e.value,
                                  style: p.text(
                                    12,
                                    e.key == widget.value ? p.ink : p.muted,
                                    e.key == widget.value
                                        ? FontWeight.w500
                                        : FontWeight.w400,
                                  ),
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
    );
  }
}

class ToolTile extends StatefulWidget {
  const ToolTile(this.id, {super.key, this.size = 24});
  final String id;
  final double size;
  @override
  State<ToolTile> createState() => _ToolTileState();
}

class _ToolTileState extends State<ToolTile> {
  bool failed = false;
  @override
  void didUpdateWidget(ToolTile old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) failed = false;
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final t = toolOf(widget.id);
    final s = [16, 20, 24, 28, 32, 40].contains(widget.size)
        ? widget.size
        : 24.0;
    final logo = t.logo != null && !failed;
    final brand =
        (p.dark ? darkColors : lightColors)['tool-${widget.id}'] ?? p.muted;
    Widget fallback() => Center(
      child: Text(
        t.letter,
        style: p
            .text(s * .46, p['tile-ink'], FontWeight.w600)
            .copyWith(height: 1),
      ),
    );
    return Tooltip(
      message: t.name,
      child: ExcludeSemantics(
        child: Container(
          width: s,
          height: s,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: logo ? p[t.darkGlyph ? 'tile-dark' : 'tile'] : brand,
            borderRadius: BorderRadius.circular(s * .28),
            border: logo
                ? Border.all(
                    color: p[t.darkGlyph ? 'tile-dark-ring' : 'tile-ring'],
                  )
                : null,
          ),
          child: logo
              ? Center(
                  child: Image.asset(
                    'assets/tool-logos/${t.logo}',
                    width: s * .68,
                    height: s * .68,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && !failed) setState(() => failed = true);
                      });
                      return fallback();
                    },
                  ),
                )
              : fallback(),
        ),
      ),
    );
  }
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 28});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(
      painter: _MarkPainter(LensPalette.of(context), size <= 32),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.p, this.small);
  final LensPalette p;
  final bool small;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 32, size.height / 32);
    canvas.drawCircle(
      const Offset(16, 16),
      10.5,
      Paint()
        ..color = p['mark-bar']
        ..style = PaintingStyle.stroke
        ..strokeWidth = small ? 2.53 : 2.2,
    );
    if (!small) {
      canvas.drawArc(
        const Rect.fromLTWH(8.5, 8.5, 15, 15),
        200 * math.pi / 180,
        50 * math.pi / 180,
        false,
        Paint()
          ..color = p['mark-bar']
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.54
          ..strokeCap = StrokeCap.round,
      );
    }
    final bars = small
        ? [(11.2, 7.0), (16.0, 11.0), (20.8, 5.0)]
        : [(10.6, 6.0), (14.4, 10.0), (18.2, 13.0), (22.0, 7.0)];
    final width = small ? 3.4 : 2.6;
    for (var i = 0; i < bars.length; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            bars[i].$1 - width / 2,
            21.5 - bars[i].$2,
            width,
            bars[i].$2,
          ),
          Radius.circular(width / 2.6),
        ),
        Paint()..color = p[i == (small ? 1 : 2) ? 'clay' : 'mark-bar'],
      );
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.p.dark != p.dark || old.small != small;
}

class TokenText extends StatelessWidget {
  const TokenText(
    this.value, {
    super.key,
    this.style,
    this.unitSystem = 'chinese',
    this.mode = 'compact',
  });
  final num? value;
  final TextStyle? style;
  final String unitSystem, mode;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: value == null ? '客户端没有上报该字段' : '${toDisplayNumber(value)} token',
    child: Text(
      value == null
          ? '—'
          : tokenCount(value, unitSystem: unitSystem, mode: mode),
      style: style ?? LensPalette.of(context).text(),
    ),
  );
}

class MoneyText extends StatelessWidget {
  const MoneyText(
    this.value, {
    super.key,
    this.state,
    this.digits,
    this.style,
    this.currency = 'USD',
    this.rate = 1,
  });
  final Object? value;
  final String? state;
  final int? digits;
  final TextStyle? style;
  final String currency;
  final double rate;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    if (value == null || value == '') {
      return Tooltip(
        message: '该模型没有可用价格',
        child: Text(
          state == 'aggregate'
              ? '待核价'
              : state == 'verified'
              ? '—'
              : '未定价',
          style: style ?? p.text(14, p.muted),
        ),
      );
    }
    final amount = double.tryParse(value.toString());
    if (amount == null || !amount.isFinite) {
      return Text('—', style: style ?? p.text(14, p.muted));
    }
    final converted = amount * (currency == 'USD' ? 1 : rate);
    return Tooltip(
      message: '\$$value',
      child: Text(
        usdCurrency(
          value,
          currency: currency,
          rate: rate,
          decimals: digits ?? (converted > 0 && converted < .01 ? 4 : 2),
        ),
        style: style ?? p.text(),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.hint, this.action});
  final String title;
  final String? hint;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: LensPalette.of(context).text(14, null, FontWeight.w500),
        ),
        if (hint != null) ...[
          const SizedBox(height: 8),
          Text(
            hint!,
            textAlign: TextAlign.center,
            style: LensPalette.of(context)
                .text(12, LensPalette.of(context).muted),
          ),
        ],
        if (action != null) ...[const SizedBox(height: 12), action!],
      ],
    ),
  );
}

class SkeletonLines extends StatelessWidget {
  const SkeletonLines({super.key, this.rows = 3});
  final int rows;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '正在加载',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: FractionallySizedBox(
              widthFactor: math.max(.18, .88 - i * .14),
              child: Container(
                height: 12,
                decoration: BoxDecoration(
                  color: LensPalette.of(context)['fill-hover'],
                  borderRadius: BorderRadius.circular(4),
                ),
                clipBehavior: Clip.hardEdge,
                child: LayoutBuilder(
                  builder: (context, box) => LensLoop(
                    duration: const Duration(milliseconds: 1600),
                    builder: (context, v) => Transform.translate(
                      offset: Offset((2 * v - 1) * box.maxWidth, 0),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              LensPalette.transparent,
                              LensPalette.of(
                                context,
                              )['tile-ink'].withValues(alpha: .55),
                              LensPalette.transparent,
                            ],
                            stops: const [.2, .5, .8],
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
  );
}

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.hint,
  });
  final String label;
  final Widget value;
  final Widget? hint;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: LensPalette.of(context)
              .text(11, LensPalette.of(context).muted, FontWeight.w500),
        ),
        const SizedBox(height: 4),
        value,
        if (hint != null) ...[const SizedBox(height: 4), hint!],
      ],
    ),
  );
}

class ScrollFade extends StatefulWidget {
  const ScrollFade({super.key, required this.child});
  final Widget child;
  @override
  State<ScrollFade> createState() => _ScrollFadeState();
}

class _ScrollFadeState extends State<ScrollFade> {
  final controller = ScrollController();
  bool left = false, right = false;
  void measure() {
    if (!mounted || !controller.hasClients) return;
    final l = controller.offset > 0;
    final r = controller.position.maxScrollExtent - controller.offset > 1;
    if (l != left || r != right) {
      setState(() {
        left = l;
        right = r;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    controller.addListener(measure);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => measure());
    final p = LensPalette.of(context);
    return Stack(
      children: [
        SingleChildScrollView(
          controller: controller,
          scrollDirection: Axis.horizontal,
          child: widget.child,
        ),
        for (final isLeft in [true, false])
          if (isLeft ? left : right)
            Positioned(
              top: 0,
              bottom: 0,
              left: isLeft ? 0 : null,
              right: isLeft ? null : 0,
              width: 24,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: isLeft
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      end: isLeft
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      colors: [p.surface, p.surface.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}
