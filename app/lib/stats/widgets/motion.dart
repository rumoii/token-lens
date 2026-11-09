import 'package:flutter/material.dart';

import '../theme/palette.dart';

double _numberEase(double t) => 1 - (1 - t) * (1 - t) * (1 - t);

class SampledSpring extends Curve {
  const SampledSpring();
  static const samples = [
    0.0,
    .11,
    .361,
    .649,
    .899,
    1.076,
    1.064,
    1.016,
    .983,
    .966,
    .962,
    .968,
    .978,
    .989,
    .998,
    1.004,
    1.007,
    1.007,
    1.006,
    1.004,
    1.0,
  ];
  @override
  double transformInternal(double t) {
    final at = t * (samples.length - 1),
        index = (t * (samples.length - 1)).floor().clamp(0, samples.length - 2);
    return samples[index] +
        (samples[index + 1] - samples[index]) * (at - index);
  }
}

class LensLoop extends StatefulWidget {
  const LensLoop({super.key, required this.builder, required this.duration});
  final Widget Function(BuildContext, double) builder;
  final Duration duration;
  @override
  State<LensLoop> createState() => _LensLoopState();
}

class _LensLoopState extends State<LensLoop>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.stop();
      controller.value = 0;
    } else if (!controller.isAnimating) {
      controller.repeat();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => widget.builder(context, controller.value),
  );
}

class TimelineMotion extends StatefulWidget {
  const TimelineMotion({
    super.key,
    required this.duration,
    required this.builder,
  });
  final Duration duration;
  final Widget Function(BuildContext, double) builder;
  @override
  State<TimelineMotion> createState() => _TimelineMotionState();
}

class _TimelineMotionState extends State<TimelineMotion>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  bool started = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.stop();
      controller.value = 1;
    } else if (!started) {
      started = true;
      controller.forward();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => widget.builder(
      context,
      controller.value * widget.duration.inMilliseconds,
    ),
  );
}

class LensEnter extends StatelessWidget {
  const LensEnter({super.key, required this.child, this.index = 0});
  final Widget child;
  final int index;
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TimelineMotion(
      duration: LensTokens.enter + LensTokens.stagger * index,
      builder: (context, ms) {
        final raw = ((ms - index * 57) / 900).clamp(0.0, 1.0);
        final value = const SampledSpring().transform(raw);
        return Transform.translate(
          offset: Offset(0, 8 * (1 - value)),
          child: Opacity(opacity: value.clamp(0.0, 1.0), child: child),
        );
      },
    );
  }
}

class LensGrow extends StatelessWidget {
  const LensGrow({
    super.key,
    required this.child,
    this.delay = 230,
    this.axis = Axis.horizontal,
    this.reveal = false,
  });
  final Widget child;
  final int delay;
  final Axis axis;
  final bool reveal;
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TimelineMotion(
      duration: Duration(milliseconds: delay + 690),
      builder: (context, ms) {
        final v = LensTokens.gentleEase.transform(
          ((ms - delay) / 690).clamp(0.0, 1.0),
        );
        if (reveal) return ClipRect(clipper: _RevealClipper(v), child: child);
        return Transform.scale(
          scaleX: axis == Axis.horizontal ? v : 1,
          scaleY: axis == Axis.vertical ? v : 1,
          alignment: axis == Axis.horizontal
              ? Alignment.centerLeft
              : Alignment.bottomCenter,
          child: child,
        );
      },
    );
  }
}

class _RevealClipper extends CustomClipper<Rect> {
  const _RevealClipper(this.progress);
  final double progress;
  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * progress, size.height);
  @override
  bool shouldReclip(_RevealClipper old) => old.progress != progress;
}

class TweenValue extends StatefulWidget {
  const TweenValue({super.key, required this.value, required this.builder});
  final num value;
  final Widget Function(num) builder;
  @override
  State<TweenValue> createState() => _TweenValueState();
}

class _TweenValueState extends State<TweenValue>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1090),
  );
  double from = 0;
  bool first = true, started = false;
  double get shown {
    final t = first
        ? ((controller.value * 1090 - 230) / 860).clamp(0.0, 1.0)
        : controller.value;
    return from + (widget.value - from) * _numberEase(t);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.stop();
      controller.value = 1;
    } else if (!started) {
      started = true;
      controller.forward();
    }
  }

  @override
  void didUpdateWidget(TweenValue old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      final t = first
          ? ((controller.value * 1090 - 230) / 860).clamp(0.0, 1.0)
          : controller.value;
      from = from + (old.value - from) * _numberEase(t);
      first = false;
      controller.duration = const Duration(milliseconds: 570);
      if (MediaQuery.disableAnimationsOf(context)) {
        controller.value = 1;
      } else {
        controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => widget.builder(
      MediaQuery.disableAnimationsOf(context) ? widget.value : shown,
    ),
  );
}

class SyncDot extends StatelessWidget {
  const SyncDot({super.key, required this.color, required this.revision});
  final Color color;
  final int revision;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 8,
    height: 8,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        if (revision > 0 && !MediaQuery.disableAnimationsOf(context))
          Positioned.fill(
            child: TimelineMotion(
              key: ValueKey(revision),
              duration: LensTokens.pulse,
              builder: (context, ms) {
                final v = Curves.easeOut.transform((ms / 1000).clamp(0.0, 1.0));
                return DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: LensPalette.of(context).pulse
                            .withValues(alpha: .55 * (1 - v)),
                        spreadRadius: 9 * v,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          child: const SizedBox.expand(),
        ),
      ],
    ),
  );
}
