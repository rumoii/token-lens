import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/theme/palette.dart';

import 'demo_visual_support.dart';

Future<({double width, double ink})> renderText(
  WidgetTester tester,
  String text,
  TextStyle style, {
  required bool dark,
}) async {
  final boundary = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      theme: LensPalette(dark).theme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox(
              width: 1600,
              height: 120,
              child: Text(text, style: style),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
  final effective = (paragraph.text as TextSpan).style!;
  final painter = TextPainter(
    text: paragraph.text,
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  final ink = await tester.runAsync(() async {
    final image =
        await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    var sum = 0;
    for (var i = 3; i < bytes.lengthInBytes; i += 4) {
      sum += bytes.getUint8(i);
    }
    image.dispose();
    return sum / 255;
  });
  debugPrint(
    'RENDER text=$text dark=$dark family=${effective.fontFamily} fallback=${effective.fontFamilyFallback} weight=${effective.fontWeight} axes=${effective.fontVariations} width=$width ink=$ink',
  );
  return (width: width, ink: ink!);
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('English ink increases and YaHei keeps two weights dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1800, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadSystemFonts(tester);
      debugPrint(
        'LOADER same as screenshots: Segoe UI Variable Text <- ${Platform.environment['SystemRoot']}/Fonts/SegUIVar.ttf; Segoe UI <- segoeui.ttf,segoeuib.ttf; Microsoft YaHei <- msyh.ttc,msyhbd.ttc',
      );
      final results = <String, List<double>>{};
      for (final text in [
        'Token Lens harbor-api lumen 123456',
        '品牌名称 会话记录 用量明细 金额',
      ]) {
        final inks = <double>[];
        for (final weight in [
          FontWeight.w400,
          FontWeight.w500,
          FontWeight.w600,
          FontWeight.w700,
        ]) {
          inks.add(
            (await renderText(
              tester,
              text,
              LensPalette(dark).text(32, Colors.black, weight),
              dark: dark,
            )).ink,
          );
        }
        results[text] = inks;
      }
      final english = results['Token Lens harbor-api lumen 123456']!;
      for (var i = 1; i < english.length; i++) {
        expect(
          english[i],
          greaterThan(english[i - 1]),
          reason:
              'English dark=$dark ${[400, 500, 600, 700][i - 1]} -> ${[400, 500, 600, 700][i]} must render heavier',
        );
      }
      final chinese = results['品牌名称 会话记录 用量明细 金额']!;
      expect(chinese[1], chinese[0], reason: 'YaHei w400 = w500');
      expect(
        chinese[2],
        greaterThan(chinese[1]),
        reason: 'YaHei Regular < Bold',
      );
      expect(chinese[3], chinese[2], reason: 'YaHei w600 = w700');
    }, skip: !Platform.isWindows);
    testWidgets('18px brand w600 has visibly more ink than w500 dark=$dark', (
      tester,
    ) async {
      await loadSystemFonts(tester);
      final style = LensPalette(dark).text(18, Colors.black, FontWeight.w600);
      final actual = await renderText(tester, 'Token Lens', style, dark: dark);
      final medium = await renderText(
        tester,
        'Token Lens',
        LensPalette(dark).text(18, Colors.black, FontWeight.w500),
        dark: dark,
      );
      debugPrint('BRAND dark=$dark w600/w500=${actual.ink / medium.ink}');
      expect(
        actual.ink,
        greaterThan(medium.ink * 1.08),
        reason: '18px brand w600 must have over 8% more ink than w500',
      );
    }, skip: !Platform.isWindows);
  }
}
