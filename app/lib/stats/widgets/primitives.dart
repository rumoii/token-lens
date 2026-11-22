import '../../l10n/app_strings.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../theme/palette.dart';
import '../logic/tools.dart';
import '../logic/format.dart';
import '../../smooth_wheel.dart';
import 'motion.dart';

part 'primitives_controls.dart';
part 'primitives_menu.dart';

final _inputModality = _LensInputModality();

class _LensInputModality extends ChangeNotifier {
  bool keyboard = false;

  void subscribe(VoidCallback listener) {
    if (!hasListeners) {
      HardwareKeyboard.instance.addHandler(_key);
      GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    }
    addListener(listener);
  }

  void unsubscribe(VoidCallback listener) {
    removeListener(listener);
    if (!hasListeners) {
      HardwareKeyboard.instance.removeHandler(_key);
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    }
  }

  void _set(bool value) {
    if (keyboard == value) return;
    keyboard = value;
    notifyListeners();
  }

  bool _key(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) _set(true);
    return false;
  }

  void _pointer(PointerEvent event) {
    if (event is PointerDownEvent ||
        event is PointerPanZoomStartEvent ||
        event is PointerScrollEvent) {
      _set(false);
    }
  }
}

class LensFocusTooltip extends StatefulWidget {
  const LensFocusTooltip({
    super.key,
    required this.description,
    required this.content,
    required this.child,
  });

  final String description;
  final Widget content;
  final Widget child;

  @override
  State<LensFocusTooltip> createState() => _LensFocusTooltipState();
}

class _LensFocusTooltipState extends State<LensFocusTooltip> {
  final _tooltip = GlobalKey<TooltipState>();
  bool _focused = false;

  void _focusChanged(bool value) {
    _focused = value;
    if (!value) {
      Tooltip.dismissAllToolTips();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focused) _tooltip.currentState?.ensureTooltipVisible();
    });
  }

  @override
  Widget build(BuildContext context) => LensFocusOutline(
    child: Focus(
      onFocusChange: _focusChanged,
      child: Semantics(
        tooltip: widget.description,
        child: Tooltip(
          key: _tooltip,
          richMessage: WidgetSpan(child: widget.content),
          excludeFromSemantics: true,
          ignorePointer: true,
          waitDuration: const Duration(milliseconds: 250),
          child: widget.child,
        ),
      ),
    ),
  );
}

class LensFocusOutline extends StatefulWidget {
  const LensFocusOutline({
    super.key,
    required this.child,
    this.radius = 8,
    this.inset = false,
    this.error = false,
  });
  final Widget child;
  final double radius;
  final bool inset;
  final bool error;
  @override
  State<LensFocusOutline> createState() => _LensFocusOutlineState();
}

class _LensFocusOutlineState extends State<LensFocusOutline> {
  bool focused = false;
  void inputChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _inputModality.subscribe(inputChanged);
  }

  @override
  void dispose() {
    _inputModality.unsubscribe(inputChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = LensPalette.of(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (value) => setState(() => focused = value),
      child: CustomPaint(
        foregroundPainter: focused && _inputModality.keyboard
            ? LensFocusRing(
                palette[widget.error ? 'danger' : 'clay'],
                widget.radius,
                inset: widget.inset,
                isolation: palette['surface-1'],
              )
            : null,
        child: widget.child,
      ),
    );
  }
}

class LensFocusRing extends CustomPainter {
  const LensFocusRing(
    this.color,
    this.radius, {
    required this.isolation,
    this.inset = false,
  });
  final Color color;
  final Color isolation;
  final double radius;
  final bool inset;
  double get isolationWidth => 1;
  double get strokeWidth => 1.5;
  double get haloWidth => 6;
  double get offset => inset ? -strokeWidth : 0;
  @override
  void paint(Canvas canvas, Size size) {
    RRect ring(double expansion) => RRect.fromRectAndRadius(
      (Offset.zero & size).inflate(expansion),
      Radius.circular(math.max(0, radius + expansion)),
    );
    final stroke = ring(offset + strokeWidth / 2);
    canvas.drawRRect(
      stroke,
      Paint()
        ..color = color.withValues(alpha: .25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 2
        ..maskFilter = MaskFilter.blur(
          BlurStyle.outer,
          haloWidth * .57735 + .5,
        ),
    );
    canvas.drawRRect(
      ring(offset - isolationWidth / 2),
      Paint()
        ..color = isolation
        ..style = PaintingStyle.stroke
        ..strokeWidth = isolationWidth,
    );
    canvas.drawRRect(
      stroke,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );
  }

  @override
  bool shouldRepaint(LensFocusRing old) =>
      old.color != color ||
      old.isolation != isolation ||
      old.radius != radius ||
      old.inset != inset;
}

class LensCard extends StatefulWidget {
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
  State<LensCard> createState() => _LensCardState();
}

class _LensCardState extends State<LensCard> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final hairline = LensPalette.hairline(context);
    List<BoxShadow> ring(List<BoxShadow> shadows) => [
      shadows.first.copyWith(spreadRadius: hairline),
      ...shadows.skip(1),
    ];
    final normalShadow = ring(p.cardShadow);
    final hoverShadow = ring(p.shadow('hover'));
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: hovered ? 1 : 0),
        duration: const Duration(milliseconds: 200),
        curve: const Cubic(.16, 1, .3, 1),
        child: widget.child,
        builder: (context, value, child) => Transform.translate(
          offset: Offset(0, reduced ? 0 : -1.5 * value),
          child: Container(
            padding: widget.padding,
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(widget.radius),
              boxShadow: value == 0
                  ? normalShadow
                  : value == 1
                  ? hoverShadow
                  : BoxShadow.lerpList(normalShadow, hoverShadow, value),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class LensPressFeedback extends StatefulWidget {
  const LensPressFeedback({super.key, required this.builder});
  final Widget Function(WidgetStatesController) builder;
  @override
  State<LensPressFeedback> createState() => _LensPressFeedbackState();
}

class _LensPressFeedbackState extends State<LensPressFeedback> {
  final states = WidgetStatesController();
  bool pressed = false;
  @override
  void initState() {
    super.initState();
    states.addListener(updatePressed);
  }

  void updatePressed() {
    if (!mounted || pressed == states.value.contains(WidgetState.pressed)) {
      return;
    }
    // Controls also notify while updating enabled state during build.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => updatePressed());
    } else if (mounted) {
      setState(() => pressed = states.value.contains(WidgetState.pressed));
    }
  }

  @override
  void dispose() {
    states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedScale(
      scale: !reduced && pressed ? .98 : 1,
      duration: reduced ? Duration.zero : const Duration(milliseconds: 100),
      child: widget.builder(states),
    );
  }
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
    this.focusNode,
  });
  final String label, variant, size;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool trailingIcon;
  final bool spinning;
  final FocusNode? focusNode;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final h = _controlHeight(size);
    final radius = _controlRadius(size);
    return Semantics(
      button: true,
      label: label,
      enabled: onPressed != null,
      child: Opacity(
        opacity: onPressed == null ? LensTokens.disabledOpacity : 1,
        child: LensPressFeedback(
          builder: (states) => LensFocusOutline(
            radius: radius,
            child: TextButton(
              statesController: states,
              focusNode: focusNode,
              onPressed: onPressed,
              style: ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size(0, h)),
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(
                    horizontal: switch (size) {
                      'xs' || 'sidebar' => 8,
                      'sm' => 10,
                      'lg' => 20,
                      _ => 14,
                    },
                  ),
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(radius),
                  ),
                ),
                textStyle: WidgetStatePropertyAll(
                  p.text(
                    switch (size) {
                      'sm' => 12.5,
                      'sidebar' => 12,
                      'xs' => 11.5,
                      'lg' => 14.5,
                      _ => 13,
                    },
                    null,
                    FontWeight.w500,
                  ),
                ),
                animationDuration: _hoverDuration(context),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => _controlFill(p, variant, states),
                ),
                foregroundColor: WidgetStatePropertyAll(
                  variant == 'danger'
                      ? (p.dark ? p['surface-0'] : p.ink)
                      : variant == 'primary'
                      ? Colors.white
                      : p.secondary,
                ),
                overlayColor: const WidgetStatePropertyAll(
                  LensPalette.transparent,
                ),
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
          ),
        ),
      ),
    );
  }
}

class LensBadge extends StatelessWidget {
  const LensBadge(this.label, {super.key, this.tone = 'neutral', this.icon});
  final String label, tone;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final color = tone == 'clay'
        ? p['clay-ink']
        : ['ok', 'warn', 'danger'].contains(tone)
        ? p[tone]
        : p.secondary;
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: switch (tone) {
          'clay' => p['clay-wash'],
          'ok' => p.okWash,
          'warn' => p.warnWash,
          'danger' => p.dangerWash,
          _ => p['fill-hover'],
        },
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: p.text(11, color, FontWeight.w500),
            ),
          ),
        ],
      ),
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
    this.menu,
    this.anchors = const {},
    this.focusNodes = const {},
    this.slideOnHover = false,
  });
  final Map<String, String> options;
  final String value, label;
  final ValueChanged<String> onChanged;
  final bool small;
  final bool slideOnHover;
  final ({String option, Key anchor})? menu;
  final Map<String, Key> anchors;
  final Map<String, FocusNode> focusNodes;
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
      } else if (widget.slideOnHover) {
        step.animateTo(
          index.toDouble(),
          duration: LensTokens.hover,
          curve: LensTokens.ease,
        );
      } else {
        step.animateWith(
          SpringSimulation(
            const SpringDescription(mass: 1, stiffness: 500, damping: 35),
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
    final menu = widget.menu;
    final widths = [
      for (final e in widget.options.entries)
        (e.key == 'custom'
                ? 14.0
                : (TextPainter(
                    text: TextSpan(
                      text: e.value,
                      style: p.text(12, null, FontWeight.w600),
                    ),
                    textDirection: TextDirection.ltr,
                  )..layout()).width) +
            (e.key == menu?.option ? 16.0 : 0.0),
    ];
    final preferredWidth =
        widths.reduce(math.max) + (widget.options.length == 5 ? 18 : 20);
    final height = widget.small ? 28.0 : 32.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final preferred = [
          for (final width in widths)
            menu == null ? preferredWidth : width + 18,
        ];
        final total = preferred.fold<double>(0, (a, b) => a + b);
        final scale = (math.max(0.0, constraints.maxWidth - 4) / total).clamp(
          0.0,
          1.0,
        );
        final segmentWidths = preferred.map((width) => width * scale).toList();
        final starts = <double>[0];
        for (final width in segmentWidths) {
          starts.add(starts.last + width);
        }
        return Semantics(
          label: widget.label,
          container: true,
          child: Container(
            width: starts.last + 4,
            height: height,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: p['segment-track'],
              borderRadius: BorderRadius.circular(999),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedBuilder(
                  animation: step,
                  builder: (context, _) {
                    final at = step.value.clamp(0, segmentWidths.length - 1);
                    final left = at.floor(), right = at.ceil();
                    double interpolate(double a, double b) =>
                        a + (b - a) * (at - left);
                    return Transform.translate(
                      offset: Offset(
                        interpolate(starts[left], starts[right]),
                        0,
                      ),
                      child: Container(
                        width: interpolate(
                          segmentWidths[left],
                          segmentWidths[right],
                        ),
                        height: height - 4,
                        decoration: BoxDecoration(
                          color: p['segment-thumb'],
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: (p.dark ? Colors.white : Colors.black)
                                .withValues(alpha: .06),
                            strokeAlign: BorderSide.strokeAlignInside,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: p.dark ? .4 : .08,
                              ),
                              offset: const Offset(0, 1),
                              blurRadius: 3,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                Row(
                  children: [
                    for (final (i, e) in widget.options.entries.indexed)
                      Semantics(
                        label: e.value,
                        selected: e.key == widget.value,
                        button: true,
                        child: LensFocusOutline(
                          child: InkWell(
                            key:
                                widget.anchors[e.key] ??
                                (e.key == menu?.option ? menu?.anchor : null),
                            focusNode: widget.focusNodes[e.key],
                            onTap: () => widget.onChanged(e.key),
                            borderRadius: BorderRadius.circular(999),
                            child: SizedBox(
                              width: segmentWidths[i],
                              height: height - 4,
                              child: Center(
                                child: e.key == 'custom'
                                    ? Tooltip(
                                        message: context.strings.custom,
                                        child: Icon(
                                          Icons.calendar_month_outlined,
                                          size: 14,
                                          color: p.muted,
                                        ),
                                      )
                                    : Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              e.value,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: p.text(
                                                12,
                                                e.key == widget.value
                                                    ? p.ink
                                                    : p.muted,
                                                e.key == widget.value
                                                    ? FontWeight.w600
                                                    : FontWeight.w400,
                                              ),
                                            ),
                                          ),
                                          if (e.key == menu?.option) ...[
                                            const SizedBox(width: 2),
                                            Icon(
                                              Icons.expand_more,
                                              size: 14,
                                              color: p.muted,
                                            ),
                                          ],
                                        ],
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
      },
    );
  }
}

class ToolTile extends StatefulWidget {
  const ToolTile(this.id, {super.key, this.size = 24, this.accent});
  final String id;
  final double size;
  final Color? accent;
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
    final s = [14, 16, 20, 24, 28, 32, 40].contains(widget.size)
        ? widget.size
        : 24.0;
    final logo = t.logo != null && !failed;
    final brand = p.toolBrand(widget.id) ?? p.toolInk(1);
    // At this luminance, black and white have equal contrast.
    final letterColor = brand.computeLuminance() > .179
        ? Colors.black
        : p['tile-ink'];
    Widget fallback() => Center(
      child: Text(
        t.letter,
        style: p
            .text(s * .46, letterColor, FontWeight.w600)
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
            borderRadius: BorderRadius.circular(
              s == 14 ? LensTokens.radii['sm']! : s * .28,
            ),
            border: switch (widget.accent) {
              final color? => Border.all(color: color),
              null when logo => Border.all(
                color: p[t.darkGlyph ? 'tile-dark-ring' : 'tile-ring'],
              ),
              _ => null,
            },
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
    message: value == null
        ? context.strings.theClientDidNotReportThisField
        : '${toDisplayNumber(value)} ${context.strings.tokenUnit}',
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
        message: context.strings.pricingIsUnavailableForThisModel,
        child: Text(
          state == 'aggregate'
              ? context.strings.priceUnverified
              : state == 'verified'
              ? '—'
              : context.strings.unpriced,
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
          decimals: digits ?? moneyDecimals(converted),
        ),
        style: style ?? p.text(),
      ),
    );
  }
}

class TrendMetricControl extends StatelessWidget {
  const TrendMetricControl({
    super.key,
    required this.cost,
    required this.onChanged,
  });

  final bool cost;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    return SizedBox(
      height: 28,
      width: strings.isChinese ? 106 : 122,
      child: Align(
        alignment: Alignment.centerRight,
        child: LensSegmented(
          options: {'tokens': strings.trendTokens, 'cost': strings.trendCost},
          value: cost ? 'cost' : 'tokens',
          label: strings.usage,
          small: true,
          onChanged: (value) => onChanged(value == 'cost'),
        ),
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
    label: context.strings.loading,
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

class LensTextLink extends StatefulWidget {
  const LensTextLink({
    super.key,
    required this.label,
    required this.onTap,
    this.arrow = false,
    this.trailingIcon,
    this.tone = 'neutral',
    this.fontSize = 12,
    this.wrap = false,
  });
  final String label;
  final VoidCallback? onTap;
  final bool arrow, wrap;
  final String tone;
  final double fontSize;
  final IconData? trailingIcon;
  @override
  State<LensTextLink> createState() => _LensTextLinkState();
}

class _LensTextLinkState extends State<LensTextLink> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final icon =
        widget.trailingIcon ?? (widget.arrow ? Icons.arrow_forward : null);
    final color = switch (widget.tone) {
      'warn' => p['warn'],
      'danger' => p['danger'],
      'clay' => p['clay-ink'],
      _ => hovered ? p.ink : p.muted,
    };
    final style = p.text(widget.fontSize, color).copyWith(height: 1.4);
    final underlineColor = hovered ? color : p['line-strong'];
    final metrics = TextPainter(
      text: TextSpan(
        text: widget.label,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final baseline = metrics.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    metrics.dispose();
    return Semantics(
      link: true,
      enabled: widget.onTap != null,
      child: Opacity(
        opacity: widget.onTap == null ? LensTokens.disabledOpacity : 1,
        child: LensPressFeedback(
          builder: (states) => LensFocusOutline(
            child: InkWell(
              statesController: states,
              onTap: widget.onTap,
              onHover: (value) => setState(() => hovered = value),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: widget.wrap
                        ? Text(
                            widget.label,
                            style: style.copyWith(
                              decoration: TextDecoration.underline,
                              decorationColor: underlineColor,
                            ),
                          )
                        : CustomPaint(
                            foregroundPainter: LensLinkUnderline(
                              color: underlineColor,
                              baseline: baseline,
                            ),
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              style: style,
                            ),
                          ),
                  ),
                  if (icon != null) ...[
                    const SizedBox(width: 5),
                    AnimatedSlide(
                      offset: hovered ? const Offset(2 / 12, 0) : Offset.zero,
                      duration: _hoverDuration(context),
                      curve: _hoverCurve,
                      child: Icon(icon, size: 12, color: color),
                    ),
                    const SizedBox(width: 2),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LensLinkUnderline extends CustomPainter {
  const LensLinkUnderline({
    required this.color,
    required this.baseline,
    this.offset = 2,
  });
  final Color color;
  final double baseline, offset;
  double get y => baseline + offset;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawLine(
    Offset(0, y),
    Offset(size.width, y),
    Paint()
      ..color = color
      ..strokeWidth = 1,
  );
  @override
  bool shouldRepaint(LensLinkUnderline old) =>
      old.color != color || old.baseline != baseline || old.offset != offset;
}
