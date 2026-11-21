part of 'mini_panel.dart';

class _MiniUsageChart extends StatefulWidget {
  const _MiniUsageChart({
    super.key,
    required this.values,
    required this.lastMinute,
    required this.unitSystem,
    required this.tip,
    required this.onSelectionChanged,
  });

  static const minWidth = 96.0, maxWidth = 176.0, height = 66.0;
  final List<int> values;
  final int lastMinute;
  final String unitSystem;
  final String Function(int) tip;
  final ValueChanged<int?> onSelectionChanged;

  @override
  State<_MiniUsageChart> createState() => _MiniUsageChartState();
}

class _MiniUsageChartState extends State<_MiniUsageChart> {
  int? _hovered, _focused;
  int _revision = 0;

  @override
  void didUpdateWidget(_MiniUsageChart old) {
    super.didUpdateWidget(old);
    if (!listEquals(old.values, widget.values)) _revision++;
  }

  int get _last => widget.values.length - 1;
  int? get _selected => _hovered ?? _focused;

  void _select({int? hovered, int? focused}) {
    if (_hovered == hovered && _focused == focused) return;
    final previous = _selected;
    setState(() {
      _hovered = hovered;
      _focused = focused;
    });
    if (previous != _selected) widget.onSelectionChanged(_selected);
  }

  String _tokens(num n) => tokenCount(n, unitSystem: widget.unitSystem);

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: _MiniUsageChart.maxWidth),
    child: SizedBox(
      key: const Key('mini-usage-chart'),
      width: double.infinity,
      height: _MiniUsageChart.height,
      child: LayoutBuilder(builder: _chart),
    ),
  );

  Widget _chart(BuildContext context, BoxConstraints bounds) {
    final s = context.strings, p = LensPalette.of(context);
    final geometry = _MiniChartGeometry(
      width: bounds.maxWidth,
      values: widget.values,
      lastMinute: widget.lastMinute,
    );
    final plot = geometry.plot;
    final selected = _selected;
    final current = selected ?? _last;
    final tip = widget.tip;

    void step(int delta) => _select(focused: (current + delta).clamp(0, _last));

    void hover(PointerEvent event) {
      final position = event.localPosition;
      final inside =
          position.dx >= plot.left &&
          position.dx <= bounds.maxWidth &&
          position.dy <= plot.bottom + 4;
      _select(
        hovered: inside ? geometry.indexAt(position.dx) : null,
        focused: _focused,
      );
    }

    final style = p.text(9.5, p.faint).copyWith(height: 1);
    Widget label(String text, Alignment align) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: align,
      child: Text(text, style: style),
    );
    final numberLabels = geometry.maximum == 0
        ? const [0]
        : [0, geometry.maximum / 2, geometry.maximum];
    final xLabelWidth = math.min(40.0, geometry.step * geometry.tickEvery - 2);
    final axes = CustomPaint(painter: _MiniChartAxes(geometry, p, selected));
    Widget curve(double reveal, double halo) => CustomPaint(
      key: const Key('mini-usage-curve'),
      painter: _MiniChartCurve(geometry, p, reveal, halo, selected),
    );
    final animate =
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    return Semantics(
      container: true,
      label: s.miniChartLabel(widget.values.length),
      value: tip(current),
      liveRegion: selected != null,
      increasedValue: current == _last ? null : tip(current + 1),
      decreasedValue: current == 0 ? null : tip(current - 1),
      onIncrease: current == _last ? null : () => step(1),
      onDecrease: current == 0 ? null : () => step(-1),
      child: Focus(
        onFocusChange: (hasFocus) =>
            _select(hovered: _hovered, focused: hasFocus ? _last : null),
        onKeyEvent: (_, event) {
          if (event is KeyUpEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            step(-1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            step(1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          onEnter: hover,
          onHover: hover,
          onExit: (_) => _select(focused: _focused),
          child: ExcludeSemantics(
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                axes,
                if (geometry.maximum > 0)
                  if (animate)
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: LensTokens.enter,
                      curve: LensTokens.ease,
                      builder: (_, reveal, _) => TweenAnimationBuilder<double>(
                        key: ValueKey(_revision),
                        tween: Tween(begin: _revision == 0 ? 1 : 0, end: 1),
                        duration: LensTokens.pulse,
                        curve: LensTokens.ease,
                        builder: (_, halo, _) => curve(reveal, halo),
                      ),
                    )
                  else
                    curve(1, 1),
                for (final n in numberLabels)
                  Positioned(
                    left: 0,
                    top: geometry.yAt(n) - 6,
                    width: plot.left - 5,
                    height: 12,
                    child: label(
                      n == .5 ? '0.5' : _tokens(n),
                      Alignment.centerRight,
                    ),
                  ),
                for (final (x, time) in geometry.ticks)
                  Positioned(
                    left: x - xLabelWidth / 2,
                    bottom: 0,
                    width: xLabelWidth,
                    height: 12,
                    child: label(_chartTime(time), Alignment.center),
                  ),
                Positioned(
                  right: bounds.maxWidth - plot.right,
                  bottom: 0,
                  width: 29,
                  height: 12,
                  child: label(s.miniChartNow, Alignment.centerRight),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _chartTime(DateTime time) =>
    "${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}";

const _chartMinute = Duration.millisecondsPerMinute;

int _chartMinuteOf(DateTime time) {
  final ms = time.millisecondsSinceEpoch;
  return (ms - ms % _chartMinute) ~/ _chartMinute;
}

DateTime _chartTimeAt(int lastMinute, int length, int index) =>
    DateTime.fromMillisecondsSinceEpoch(
      (lastMinute - length + 1 + index) * _chartMinute,
    );

class _MiniChartGeometry {
  _MiniChartGeometry({
    required double width,
    required this.values,
    required this.lastMinute,
  }) : plot = Rect.fromLTRB(28, 5, width - 2, 50),
       maximum = _roundedMaximum(values.fold(0, math.max));

  final Rect plot;
  final List<int> values;
  final double maximum;
  final int lastMinute;

  static double _roundedMaximum(int peak) {
    if (peak <= 0) return 0;
    var magnitude = 1.0;
    while (magnitude * 10 < peak) {
      magnitude *= 10;
    }
    return [
      magnitude,
      2 * magnitude,
      5 * magnitude,
      10 * magnitude,
    ].firstWhere((n) => n >= peak);
  }

  double get step => plot.width / values.length;
  int get tickEvery => values.length == 60 ? 15 : values.length ~/ 3;
  double xAt(int i) => plot.left + (i + .5) * step;
  double yAt(num n) => maximum == 0
      ? plot.bottom
      : plot.bottom - math.max(0, n) / maximum * plot.height;
  Offset point(int i) => Offset(xAt(i), yAt(values[i]));
  int indexAt(double x) =>
      ((x - plot.left) / step).floor().clamp(0, values.length - 1);
  Iterable<(double, DateTime)> get ticks sync* {
    for (var i = 0; i < values.length; i++) {
      final x = xAt(i);
      if (x - plot.left < 10 || plot.right - x < 34) continue;
      final time = _chartTimeAt(lastMinute, values.length, i);
      if ((time.hour * 60 + time.minute) % tickEvery == 0) yield (x, time);
    }
  }
}

class _MiniChartAxes extends CustomPainter {
  const _MiniChartAxes(this.geometry, this.palette, this.selected);
  final _MiniChartGeometry geometry;
  final LensPalette palette;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = geometry.plot;
    final grid = Paint()..color = palette['line'];
    final axis = Paint()..color = palette['line-strong'];
    if (geometry.maximum > 0) {
      for (final y in [plot.top, plot.center.dy]) {
        for (var x = plot.left; x < plot.right; x += 5) {
          canvas.drawLine(
            Offset(x, y),
            Offset(math.min(x + 2, plot.right), y),
            grid,
          );
        }
      }
    }
    canvas.drawLine(
      Offset(plot.left - .5, plot.top - 2),
      Offset(plot.left - .5, plot.bottom + .5),
      axis,
    );
    canvas.drawLine(
      Offset(plot.left, plot.bottom + .5),
      Offset(plot.right, plot.bottom + .5),
      axis,
    );
    for (final (x, _) in geometry.ticks) {
      canvas.drawLine(
        Offset(x, plot.bottom + .5),
        Offset(x, plot.bottom + 3.5),
        axis,
      );
    }
    if (selected case final i?) {
      final x = geometry.xAt(i);
      canvas.drawLine(Offset(x, plot.top - 2), Offset(x, plot.bottom), axis);
    }
  }

  @override
  bool shouldRepaint(_MiniChartAxes old) =>
      old.geometry.plot != geometry.plot ||
      old.geometry.maximum != geometry.maximum ||
      old.geometry.lastMinute != geometry.lastMinute ||
      old.palette.dark != palette.dark ||
      old.selected != selected;
}

class _MiniChartCurve extends CustomPainter {
  const _MiniChartCurve(
    this.geometry,
    this.palette,
    this.reveal,
    this.halo,
    this.selected,
  );
  final _MiniChartGeometry geometry;
  final LensPalette palette;
  final double reveal, halo;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final first = geometry.point(0);
    var end = first;
    final line = Path()..moveTo(first.dx, first.dy);
    for (var i = 1; i < geometry.values.length; i++) {
      final next = geometry.point(i);
      final mid = (end.dx + next.dx) / 2;
      line.cubicTo(mid, end.dy, mid, next.dy, next.dx, next.dy);
      end = next;
    }
    final plot = geometry.plot;
    if (reveal == 1) {
      final area = Path.from(line)
        ..lineTo(end.dx, plot.bottom)
        ..lineTo(first.dx, plot.bottom)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              palette['clay-glow'].withValues(alpha: .16),
              LensPalette.transparent,
            ],
          ).createShader(plot),
      );
    }
    final stroke = Paint()
      ..color = palette.toolInk(3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round;
    if (reveal == 1) {
      canvas.drawPath(line, stroke);
    } else {
      final metric = line.computeMetrics().single;
      canvas.drawPath(metric.extractPath(0, metric.length * reveal), stroke);
    }
    if (reveal >= .99) {
      if (halo < 1) {
        canvas.drawCircle(
          end,
          2 + 7 * halo,
          Paint()
            ..color = palette['clay-glow'].withValues(alpha: .25 * (1 - halo)),
        );
      }
      canvas.drawCircle(end, 2.4, Paint()..color = palette['clay']);
    }
    if (selected case final i?) {
      final point = geometry.point(i);
      canvas.drawCircle(point, 2.6, Paint()..color = palette['surface-1']);
      canvas.drawCircle(point, 2.6, stroke);
    }
  }

  @override
  bool shouldRepaint(_MiniChartCurve old) =>
      old.geometry.plot != geometry.plot ||
      old.geometry.values != geometry.values ||
      old.palette.dark != palette.dark ||
      old.reveal != reveal ||
      old.halo != halo ||
      old.selected != selected;
}
