part of 'mini_panel.dart';

void _miniPillAction(Future<void> Function() action) {
  unawaited(
    action().catchError((Object error, StackTrace stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }),
  );
}

class MiniPill extends StatefulWidget {
  const MiniPill({
    super.key,
    required this.controller,
    required this.window,
    required this.state,
  });

  final StatsController controller;
  final MiniWindow window;
  final MiniPillState state;

  static const _gap = 5.0;
  static const _separatorSpace = 8.0;
  static const _endPadding = 10.0;

  static List<TextSpan> _spans(BuildContext context, StatsController c) {
    final p = LensPalette.of(context);
    final s = context.strings;
    final usage = c.miniUsage?.totals;
    final tokens = usage == null ? '—' : _miniTokens(c, usage.grossTokens);
    final micros = usage?.costMicros;
    final cost = micros == null
        ? '—'
        : s.miniEstimate(_miniMoney(c.preferences, micros));
    return [
      TextSpan(text: tokens, style: p.serif(16)),
      TextSpan(text: s.tokenUnit, style: p.text(11, p.secondary)),
      TextSpan(text: cost, style: p.text(12, p.secondary, FontWeight.w500)),
    ];
  }

  static double widthFor(BuildContext context, StatsController c) =>
      _width(context, _spans(context, c));

  static double _width(BuildContext context, List<TextSpan> spans) {
    final line = LensPalette.hairline(context);
    var width =
        MiniWindow.pillTab +
        _gap +
        _separatorSpace * 2 +
        line +
        _endPadding +
        2;
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    for (final span in spans) {
      painter.text = span;
      painter.layout();
      width += painter.width;
    }
    painter.dispose();
    return width.ceilToDouble().clamp(
      MiniWindow.pillTab,
      MiniWindow.pillMaxWidth,
    );
  }

  @override
  State<MiniPill> createState() => _MiniPillState();
}

class _MiniPillState extends State<MiniPill> {
  (int, Offset)? _press;
  bool _focused = false;
  bool _keyboardInput = false;
  String? _tooltip;

  void _activate() => _miniPillAction(widget.window.expandPill);

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_trackKeyboardInput);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_trackKeyboardInput);
    super.dispose();
  }

  KeyEventResult _trackKeyboardInput(KeyEvent event) {
    // Tab can bring focus here after this event is routed.
    if (event is KeyDownEvent &&
        !event.synthesized &&
        (_focused || event.logicalKey == LogicalKeyboardKey.tab) &&
        !_keyboardInput) {
      setState(() => _keyboardInput = true);
    }
    return KeyEventResult.ignored;
  }

  void _trackPointerInput() {
    if (_keyboardInput) setState(() => _keyboardInput = false);
  }

  void _hover(bool hovered) => widget.window.setPillHovered(
    hovered,
    reduceMotion: MediaQuery.disableAnimationsOf(context),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateTooltip();
  }

  @override
  void didUpdateWidget(MiniPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateTooltip();
  }

  void _updateTooltip() {
    final tooltip = widget.state.edge == null
        ? context.strings.miniPillTooltip
        : null;
    if (_tooltip == tooltip) return;
    _tooltip = tooltip;
    // The native tooltip can extend beyond the 36-DIP Flutter view.
    _miniPillAction(() => widget.window.platform.setPillTooltip(tooltip));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final p = LensPalette.of(context);
    final s = context.strings;
    final spans = MiniPill._spans(context, c);
    final width = MiniPill._width(context, spans);
    if ((widget.window.pillWidth - width).abs() >= 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _miniPillAction(() => widget.window.resizePill(width));
      });
    }
    final mark = SizedBox(
      width: MiniWindow.pillTab,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.square(
            dimension: 22,
            child: DecoratedBox(
              decoration: _focused && _keyboardInput
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        LensTokens.radii['sm']!,
                      ),
                      border: Border.all(
                        color: p['clay-ink'],
                        width: 1 / MediaQuery.devicePixelRatioOf(context),
                      ),
                    )
                  : const BoxDecoration(),
              child: const Center(child: BrandMark(size: 18)),
            ),
          ),
          if (c.busy)
            Positioned(
              right: 2,
              top: 5,
              child: SyncDot(color: p['clay'], revision: 0),
            ),
        ],
      ),
    );
    final edge = widget.state.edge;
    final label = s.miniPillLabel(
      spans.first.text!,
      _miniMoney(c.preferences, c.miniUsage?.totals.costMicros),
    );
    final tuckedLeft = edge == MiniPillEdge.left && !widget.state.revealed;
    return Semantics(
      container: true,
      button: true,
      focusable: true,
      focused: _focused,
      label: label,
      onTap: _activate,
      child: FocusableActionDetector(
        autofocus: true,
        includeFocusSemantics: false,
        onFocusChange: (value) => setState(() {
          _focused = value;
          if (!value) _keyboardInput = false;
        }),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => _activate(),
          ),
        },
        child: ExcludeSemantics(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => _hover(true),
            onExit: (_) => _hover(false),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerHover: (event) {
                if (!event.synthesized && event.delta != Offset.zero) {
                  _trackPointerInput();
                }
              },
              onPointerSignal: (_) => _trackPointerInput(),
              onPointerDown: (event) {
                _trackPointerInput();
                if (_press == null && event.buttons & kPrimaryButton != 0) {
                  _press = (event.pointer, event.position);
                }
              },
              onPointerMove: (event) {
                final press = _press;
                if (press?.$1 == event.pointer &&
                    (event.position - press!.$2).distance > 4) {
                  _press = null;
                  _miniPillAction(
                    () => widget.window.startPillDragging(
                      edgeAccent: p['clay-ink'],
                    ),
                  );
                }
              },
              onPointerUp: (event) {
                if (_press?.$1 != event.pointer) return;
                _press = null;
                _activate();
              },
              onPointerCancel: (event) {
                if (_press?.$1 == event.pointer) _press = null;
              },
              child: SizedBox.expand(
                child: tuckedLeft
                    ? Align(alignment: Alignment.centerRight, child: mark)
                    : Row(
                        children: [
                          mark,
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(
                                right: MiniPill._endPadding,
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Row(
                                  children: [
                                    Text.rich(spans[0]),
                                    const SizedBox(width: MiniPill._gap),
                                    Text.rich(spans[1]),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: MiniPill._separatorSpace,
                                      ),
                                      child: SizedBox(
                                        width: LensPalette.hairline(context),
                                        height: 14,
                                        child: ColoredBox(color: p['line']),
                                      ),
                                    ),
                                    Text.rich(spans[2]),
                                  ],
                                ),
                              ),
                            ),
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
