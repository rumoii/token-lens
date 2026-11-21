part of 'mini_panel.dart';

class _MiniResizeFeedback extends StatelessWidget {
  const _MiniResizeFeedback({required this.hovered, required this.dimensions});

  final bool hovered;
  final ValueListenable<Size?> dimensions;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : LensTokens.hover;
    return Positioned(
      right: 5,
      bottom: 5,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ValueListenableBuilder<Size?>(
                valueListenable: dimensions,
                builder: (context, size, _) => AnimatedSwitcher(
                  duration: duration,
                  child: size == null
                      ? const SizedBox.shrink()
                      : Container(
                          key: const Key('mini-resize-size'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: p['surface-2'],
                            border: Border.all(color: p['line']),
                            borderRadius: BorderRadius.circular(
                              LensTokens.radii['sm']!,
                            ),
                          ),
                          child: Text(
                            '${size.width.round()} × ${size.height.round()}',
                            style: p.text(10, p.muted),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 4),
              AnimatedOpacity(
                key: const Key('mini-resize-grip'),
                opacity: hovered ? .8 : 0,
                duration: duration,
                child: CustomPaint(
                  size: const Size.square(10),
                  painter: _MiniGrip(p.faint),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniGrip extends CustomPainter {
  const _MiniGrip(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    for (final length in [3.0, 6.0, 9.0]) {
      canvas.drawLine(Offset(9 - length, 9), Offset(9, 9 - length), stroke);
    }
  }

  @override
  bool shouldRepaint(_MiniGrip oldDelegate) => oldDelegate.color != color;
}

class MiniReveal extends StatelessWidget {
  const MiniReveal({super.key, required this.child, this.animate = true});
  final Widget child;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    if (!animate || MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: LensTokens.hover,
      curve: LensTokens.ease,
      child: child,
      builder: (_, value, child) => Opacity(
        opacity: value,
        child: Transform.scale(
          scale: .96 + .04 * value,
          alignment: Alignment.bottomLeft,
          child: child,
        ),
      ),
    );
  }
}

class _MiniTabContent extends StatelessWidget {
  const _MiniTabContent({
    super.key,
    required this.forward,
    required this.child,
  });
  final bool forward;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return ClipRect(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: LensTokens.hover,
        curve: LensTokens.ease,
        child: child,
        builder: (_, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset((forward ? 8 : -8) * (1 - value), 0),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _MiniFlash extends StatefulWidget {
  const _MiniFlash({
    required this.revision,
    required this.slideIn,
    required this.child,
  });
  final int? revision;
  final bool slideIn;
  final Widget child;

  @override
  State<_MiniFlash> createState() => _MiniFlashState();
}

class _MiniFlashState extends State<_MiniFlash>
    with SingleTickerProviderStateMixin {
  static final duration = LensTokens.pulse + LensTokens.tip;
  late final animation = AnimationController(
    vsync: this,
    value: 1,
    duration: duration,
  );
  int? _seen;

  void _apply() {
    if (MediaQuery.disableAnimationsOf(context)) {
      animation.value = 1;
      _seen = widget.revision;
    } else if (widget.revision != null && widget.revision != _seen) {
      _seen = widget.revision;
      animation.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _apply();
  }

  @override
  void didUpdateWidget(_MiniFlash oldWidget) {
    super.didUpdateWidget(oldWidget);
    _apply();
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = LensPalette.of(context)['clay-wash'];
    return AnimatedBuilder(
      animation: animation,
      child: widget.child,
      builder: (context, child) {
        final progress = animation.value;
        final slide =
            (progress *
                    duration.inMilliseconds /
                    LensTokens.gentle.inMilliseconds)
                .clamp(0.0, 1.0);
        return Transform.translate(
          offset: Offset(
            0,
            widget.slideIn
                ? -8 * (1 - LensTokens.gentleEase.transform(slide))
                : 0,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(
                alpha: 1 - LensTokens.ease.transform(progress),
              ),
              borderRadius: BorderRadius.circular(LensTokens.radii['lg']!),
            ),
            child: child,
          ),
        );
      },
    );
  }
}

class _ProjectBar extends StatelessWidget {
  const _ProjectBar({
    required this.tools,
    required this.colors,
    required this.maximum,
  });
  final List<StatsMiniTool> tools;
  final Map<String, Color> colors;
  final int maximum;

  @override
  Widget build(BuildContext context) {
    final total = tools.fold(0, (sum, tool) => sum + tool.grossTokens);
    final radius = BorderRadius.circular(LensTokens.radii['xs']!);
    return SizedBox(
      width: 52,
      height: 2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: LensPalette.of(context)['line-soft'],
          borderRadius: radius,
        ),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: maximum <= 0 ? 0 : total / maximum),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : LensTokens.grow,
          curve: LensTokens.ease,
          builder: (context, fraction, _) => Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: fraction.clamp(0, 1),
              heightFactor: 1,
              child: ClipRRect(
                borderRadius: radius,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final tool in tools)
                      if (tool.grossTokens > 0)
                        Expanded(
                          flex: tool.grossTokens,
                          child: ColoredBox(color: colors[tool.source]!),
                        ),
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

class _MiniScroll extends StatefulWidget {
  const _MiniScroll({required this.builder});
  final Widget Function(ScrollController) builder;

  @override
  State<_MiniScroll> createState() => _MiniScrollState();
}

class _MiniScrollState extends State<_MiniScroll> {
  final _scroll = ScrollController();
  bool _hover = false, _above = false, _below = false;

  void _edges(ScrollMetrics metrics) {
    final above = metrics.extentBefore > 1, below = metrics.extentAfter > 1;
    if (_above == above && _below == below) return;
    setState(() {
      _above = above;
      _below = below;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (event) {
            _edges(event.metrics);
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (event) {
              _edges(event.metrics);
              return false;
            },
            child: RawScrollbar(
              controller: _scroll,
              thumbVisibility: _hover && (_above || _below),
              radius: const Radius.circular(1.5),
              thickness: 3,
              crossAxisMargin: 2,
              thumbColor: p.faint,
              fadeDuration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : LensTokens.tip,
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (box) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, 12 / box.height, 1 - 15 / box.height, 1],
                  colors: [
                    _above ? Colors.transparent : Colors.black,
                    Colors.black,
                    Colors.black,
                    _below ? Colors.transparent : Colors.black,
                  ],
                ).createShader(box),
                child: widget.builder(_scroll),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
