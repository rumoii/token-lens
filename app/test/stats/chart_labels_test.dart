import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/home_data.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/charts.dart';

double _luminance(Color color) {
  double linear(double channel) => channel <= 0.04045
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * linear(color.r) +
      0.7152 * linear(color.g) +
      0.0722 * linear(color.b);
}

double _contrast(Color text, Color surface) {
  final a = _luminance(text), b = _luminance(surface);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

Future<({CustomPainter painter, Size size})> _mount(
  WidgetTester tester,
  LensPalette palette, {
  required double width,
  double scale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: palette.theme,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Center(
          child: SizedBox(
            width: width,
            child: TrendChart(
              buckets: [
                for (var i = 1; i <= 32; i++)
                  TrendBucket(dayKey(DateTime(2026, 10, i))),
              ],
              order: const [],
              slots: const {},
              granularity: 'day',
              now: DateTime(2026, 11, 1),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final plot = find.descendant(
    of: find.byType(TrendChart),
    matching: find.byType(CustomPaint),
  );
  return (
    painter: tester.widget<CustomPaint>(plot).painter!,
    size: tester.getSize(plot),
  );
}

class _DateLabelCanvas extends TestRecordingCanvas {
  final labels = <Rect>[];

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    if (offset.dy >= 192 && paragraph.longestLine > 0) {
      labels.add(offset & Size(paragraph.longestLine, paragraph.height));
    }
  }
}

void main() {
  test('图表文字在浅色和深色背景的 WCAG 对比度至少为 4.5', () {
    for (final dark in [false, true]) {
      final p = LensPalette(dark);
      for (final (foreground, background) in [
        (p.muted, p.surface), // Axis labels and chart captions.
        (p.secondary, p.surface), // Average label and legend.
        (p.ink, p['surface-3']), // Tooltip heading and values.
        (p.secondary, p['surface-3']), // Tooltip secondary text.
        (p.muted, p['surface-3']), // Tooltip hint and estimate caption.
      ]) {
        expect(
          _contrast(foreground, background),
          greaterThanOrEqualTo(4.5),
          reason: 'dark=$dark, $foreground on $background',
        );
      }
    }
  });

  for (final dark in [false, true]) {
    testWidgets('趋势图实际绘制的横轴文字对比度达标 dark=$dark', (tester) async {
      final p = LensPalette(dark);
      final plot = await _mount(tester, p, width: 720);
      final ratio = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(p.surface, BlendMode.src);
        plot.painter.paint(canvas, plot.size);
        final picture = recorder.endRecording();
        final width = plot.size.width.ceil(), height = plot.size.height.ceil();
        final image = await picture.toImage(width, height);
        final pixels = (await image.toByteData())!;
        var strongest = 1.0;
        // This strip contains only the horizontal axis, below the plot.
        for (var i = 192 * width * 4; i < pixels.lengthInBytes; i += 4) {
          final pixel = Color.fromARGB(
            pixels.getUint8(i + 3),
            pixels.getUint8(i),
            pixels.getUint8(i + 1),
            pixels.getUint8(i + 2),
          );
          strongest = math.max(strongest, _contrast(pixel, p.surface));
        }
        image.dispose();
        picture.dispose();
        return strongest;
      });
      expect(ratio, greaterThanOrEqualTo(4.5));
    });
  }

  testWidgets('150% 文字缩放时，窄趋势图中的日期间留有空隙', (tester) async {
    final normal = await _mount(tester, const LensPalette(false), width: 300);
    final normalCanvas = _DateLabelCanvas();
    normal.painter.paint(normalCanvas, normal.size);
    final scaled = await _mount(
      tester,
      const LensPalette(false),
      width: 300,
      scale: 1.5,
    );
    final scaledCanvas = _DateLabelCanvas();
    scaled.painter.paint(scaledCanvas, scaled.size);
    final dates = scaledCanvas.labels;
    expect(dates.length, greaterThan(1));
    expect(dates.first.height, greaterThan(normalCanvas.labels.first.height));
    for (var i = 0; i < dates.length; i++) {
      final date = dates[i];
      expect(date.left, greaterThanOrEqualTo(0));
      expect(date.right, lessThanOrEqualTo(scaled.size.width));
      expect(date.bottom, lessThanOrEqualTo(scaled.size.height));
      if (i > 0) expect(date.left, greaterThan(dates[i - 1].right));
    }
  });
}
