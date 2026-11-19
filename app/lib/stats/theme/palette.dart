import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;

class LensPalette {
  const LensPalette(this.dark);
  final bool dark;
  static LensPalette of(BuildContext context) =>
      LensPalette(Theme.of(context).brightness == Brightness.dark);
  Color operator [](String name) => (dark ? darkColors : lightColors)[name]!;
  Color get ink => this['text'];
  Color get muted => this['text-muted'];
  Color get faint => this['text-faint'];
  Color get secondary => this['text-secondary'];
  Color get surface => this['surface-2'];
  Color category(int slot) =>
      this[slot > 0 && slot <= 8 ? 'cat-$slot' : 'cat-other'];
  static const transparent = Color(0x00000000);
  static const serifFonts = [
    'Noto Serif SC',
    'Source Han Serif SC',
    'Songti SC',
    'Georgia',
    'SimSun',
    'Times New Roman',
  ];
  static List<String> get bodyFonts =>
      defaultTargetPlatform == TargetPlatform.macOS
      ? const ['.AppleSystemUIFont', 'SF Pro Text', 'PingFang SC', 'Arial']
      : const [
          'Segoe UI Variable Text',
          'Segoe UI',
          'Microsoft YaHei',
          'Geist',
          'Arial',
          'PingFang SC',
        ];
  static const monoFonts = ['Geist Mono', 'SF Mono', 'Menlo', 'Consolas'];
  TextStyle text([
    double size = 14,
    Color? color,
    FontWeight weight = FontWeight.w400,
  ]) => TextStyle(
    fontFamily: bodyFonts.first,
    fontFamilyFallback: bodyFonts.skip(1).toList(),
    fontSize: size,
    height: 1.55,
    color: color ?? ink,
    fontWeight: weight,
    fontVariations: [
      FontVariation('wght', switch (weight) {
        FontWeight.w500 => dark ? 465 : 500,
        FontWeight.w600 => dark ? 560 : 580,
        FontWeight.w700 => 660,
        _ => weight.value.toDouble(),
      }),
    ],
    fontFeatures: const [FontFeature.tabularFigures()],
  );
  TextStyle serif(
    double size, {
    FontWeight weight = FontWeight.w600,
    Color? color,
  }) => text(size, color, weight).copyWith(
    fontFamily: serifFonts.first,
    fontFamilyFallback: serifFonts.skip(1).toList(),
    fontVariations: const [],
    height: 1.05,
    letterSpacing: -size * .02,
  );
  static double hairline(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return dpr >= 3
        ? 1 / 3
        : dpr >= 2
        ? .5
        : 1;
  }

  List<BoxShadow> get cardShadow => [
    BoxShadow(color: this['line'], spreadRadius: 1),
    BoxShadow(
      color: dark ? const Color(0x4d000000) : const Color(0x08000000),
      offset: const Offset(0, 1),
      blurRadius: 2,
    ),
    BoxShadow(
      color: dark ? const Color(0x73000000) : const Color(0x0f000000),
      offset: Offset(0, dark ? 6 : 4),
      blurRadius: dark ? 18 : 14,
      spreadRadius: -6,
    ),
  ];
  List<BoxShadow> get smallShadow => [
    for (final spec in [(1.0, 2.0), (2.0, 8.0)])
      BoxShadow(
        color: dark ? const Color(0x66000000) : const Color(0x0a000000),
        offset: Offset(0, spec.$1),
        blurRadius: spec.$2,
      ),
  ];
  List<BoxShadow> get popShadow => [
    BoxShadow(
      color: dark ? const Color(0x17ffffff) : this['line'],
      spreadRadius: 1,
    ),
    BoxShadow(
      color: dark ? const Color(0xb3000000) : const Color(0x29000000),
      offset: Offset(0, dark ? 12 : 10),
      blurRadius: dark ? 32 : 30,
      spreadRadius: -6,
    ),
    if (!dark)
      const BoxShadow(
        color: Color(0x0d000000),
        offset: Offset(0, 2),
        blurRadius: 6,
      ),
  ];
  List<BoxShadow> shadow(String role) {
    BoxShadow drop(
      int light,
      int night,
      double y,
      double blur, [
      double spread = 0,
    ]) => BoxShadow(
      color: Color(dark ? night : light),
      offset: Offset(0, y),
      blurRadius: blur,
      spreadRadius: spread,
    );
    final ring = BoxShadow(color: this['line'], spreadRadius: 1);
    return switch (role) {
      'sm' => smallShadow,
      'md' => [
        drop(0x0d000000, 0x66000000, 2, 4),
        drop(0x0f000000, 0x66000000, 6, 16),
      ],
      'panel' => [ring, drop(0x0a000000, 0x66000000, 1, 2)],
      'card' => cardShadow,
      'hover' => [
        BoxShadow(color: this['line-strong'], spreadRadius: 1),
        drop(0x1f000000, 0x99000000, dark ? 8 : 6, dark ? 24 : 20, -6),
      ],
      'pop' => popShadow,
      'popover' => [
        BoxShadow(
          color: dark ? const Color(0x1affffff) : this['line'],
          spreadRadius: 1,
        ),
        drop(0x1a000000, 0xa6000000, 8, dark ? 28 : 24),
        if (!dark) drop(0x0f000000, 0x0f000000, 2, 6),
      ],
      'thumb' => [
        BoxShadow(
          color: dark ? const Color(0x12ffffff) : const Color(0x0f1b1a18),
          spreadRadius: 1,
        ),
        drop(0x14000000, 0x80000000, 1, 3),
      ],
      _ => const [],
    };
  }

  Color get okWash => this['ok'].withValues(alpha: .12);
  Color get warnWash => this['warn'].withValues(alpha: dark ? .14 : .12);
  Color get dangerWash => this['danger'].withValues(alpha: dark ? .14 : .12);
  Color get pulse => this['ok'].withValues(alpha: .55);
  RoundedRectangleBorder get popoverShape =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));

  ButtonStyle get _controlTheme => ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(32, 32)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? secondary.withValues(alpha: LensTokens.disabledOpacity)
          : secondary,
    ),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) return this['fill-active'];
      if (states.contains(WidgetState.hovered)) return this['fill-hover'];
      return transparent;
    }),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  ThemeData get theme => ThemeData(
    useMaterial3: true,
    splashFactory: NoSplash.splashFactory,
    highlightColor: transparent,
    brightness: dark ? Brightness.dark : Brightness.light,
    fontFamily: bodyFonts.first,
    fontFamilyFallback: bodyFonts.skip(1).toList(),
    scaffoldBackgroundColor: this['surface-1'],
    colorScheme: ColorScheme.fromSeed(
      seedColor: this['clay'],
      brightness: dark ? Brightness.dark : Brightness.light,
      surface: surface,
      onSurface: ink,
    ),
    textTheme: TextTheme(bodyMedium: text(), bodySmall: text(12)),
    focusColor: Colors.transparent,
    dividerColor: this['line'],
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      isDense: true,
      fillColor: this['fill-hover'],
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
    ),
    switchTheme: SwitchThemeData(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(transparent),
      trackColor: WidgetStateProperty.resolveWith(
        (states) =>
            this[states.contains(WidgetState.selected)
                ? 'clay'
                : 'line-strong'],
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      side: BorderSide(color: this['line-heavy'], width: 1.5),
      fillColor: WidgetStatePropertyAll(this['clay']),
      checkColor: const WidgetStatePropertyAll(Colors.white),
    ),
    textButtonTheme: TextButtonThemeData(style: _controlTheme),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: _controlTheme.copyWith(
        side: const WidgetStatePropertyAll(BorderSide.none),
        backgroundColor: WidgetStatePropertyAll(this['fill-hover']),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: _controlTheme),
    chipTheme: ChipThemeData(
      backgroundColor: this['fill-hover'],
      selectedColor: this['clay-wash'],
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: text(12, secondary),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(this['surface-3']),
        surfaceTintColor: const WidgetStatePropertyAll(transparent),
        shape: WidgetStatePropertyAll(popoverShape),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: this['surface-3'],
      surfaceTintColor: transparent,
      shape: popoverShape,
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: text(12),
      decoration: BoxDecoration(
        color: this['surface-3'],
        borderRadius: BorderRadius.circular(8),
        boxShadow: popShadow,
      ),
    ),
  );
}

abstract final class LensTokens {
  static const disabledOpacity = .45;
  static const radii = {
    'xs': 2.0,
    'sm': 4.0,
    'md': 6.0,
    'lg': 8.0,
    'panel': 10.0,
    'xl': 12.0,
    '2xl': 16.0,
    'pill': 999.0,
  };
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 160);
  static const gentle = Duration(milliseconds: 480);
  static const enter = Duration(milliseconds: 900);
  static const stagger = Duration(milliseconds: 57);
  static const grow = Duration(milliseconds: 690);
  static const morph = Duration(milliseconds: 690);
  static const hover = Duration(milliseconds: 230);
  static const heat = Duration(milliseconds: 340);
  static const tip = Duration(milliseconds: 170);
  static const pulse = Duration(milliseconds: 1000);
  static const ease = Cubic(.32, .72, 0, 1);
  static const snap = Cubic(.34, .9, .3, 1);
  static const gentleEase = Cubic(.22, .85, .25, 1);
}

// Colour values are a direct port of styles/tokens.css, including alpha tokens.
const lightColors = <String, Color>{
  'segment-track': Color.from(alpha: .06, red: 0, green: 0, blue: 0),
  'segment-thumb': Color(0xffffffff),
  'surface-0': Color(0xfff5f5f3),
  'surface-1': Color(0xfffbfbf9),
  'surface-2': Color(0xffffffff),
  'surface-3': Color(0xffffffff),
  'clay': Color(0xffd97757),
  'clay-hover': Color(0xffc96442),
  'clay-wash': Color(0xfffbf1ec),
  'clay-ink': Color(0xffb5532f),
  'clay-glow': Color(0x40d97757),
  'clay-20': Color(0xfff2ded6),
  'clay-35': Color(0xffeabda9),
  'clay-55': Color(0xffe29b81),
  'clay-75': Color(0xffdc8a6c),
  'tile': Color(0xffffffff),
  'tile-ring': Color(0x1a1b1a18),
  'tile-dark': Color(0xff18181b),
  'tile-dark-ring': Color(0x24ffffff),
  'tile-ink': Color(0xffffffff),
  'heat-0': Color(0x0f1c1a17),
  'heat-1': Color(0xfff0d3c5),
  'heat-2': Color(0xffe6a98f),
  'heat-3': Color(0xffdc8466),
  'heat-4': Color(0xffc4603e),
  'line': Color(0x171b1a18),
  'line-soft': Color(0x0d1b1a18),
  'line-strong': Color(0x291b1a18),
  'line-heavy': Color(0x59141414),
  'text': Color(0xff171716),
  'text-secondary': Color(0xff55534e),
  'text-muted': Color(0xff75736d),
  'text-faint': Color(0xffa3a19b),
  'mark-bar': Color(0xffa3a19b),
  'text-inverse': Color(0xfffbfbfa),
  'ok': Color(0xff3f8f5f),
  'warn': Color(0xffb07d3c),
  'danger': Color(0xffc0533e),
  'fill-hover': Color(0x0b1b1a18),
  'fill-active': Color(0x141b1a18),
  'tool-claude': Color(0xffd97757),
  'tool-codex': Color(0xff3b82f6),
  'tool-qwen': Color(0xff7c5cff),
  'tool-dsh': Color(0xff4d6bfe),
  'tool-grok': Color(0xff111111),
  'tool-aider': Color(0xff16a34a),
  'tool-pi': Color(0xffe0478c),
  'tool-hermes': Color(0xff7aa83b),
  'tool-cline': Color(0xff6b7280),
  'tool-gemini': Color(0xff14a6b8),
  'tool-cursor': Color(0xff111111),
  'tool-opencode': Color(0xffe9a23b),
  'tool-kilo': Color(0xffb39b00),
  'tool-openhands': Color(0xff84786b),
  'tool-goose': Color(0xff262626),
  'tool-zed': Color(0xff084ccf),
  'tool-continue': Color(0xff6b5bd6),
  'tool-trae': Color(0xffef4444),
  'tool-copilot': Color(0xff6e40c9),
  'tool-openclaw': Color(0xffef4444),
  'tool-mimo': Color(0xffff6900),
  'tool-kimi': Color(0xff8b7cf6),
  'tool-minimax': Color(0xfff43f5e),
  'tool-zcode': Color(0xff111111),
  'tool-codebuddy': Color(0xff6c5ce7),
  'cat-1': Color(0xff62a4e0),
  'cat-2': Color(0xffd6895c),
  'cat-3': Color(0xff42b599),
  'cat-4': Color(0xffc49646),
  'cat-5': Color(0xffd081ae),
  'cat-6': Color(0xff7fae67),
  'cat-7': Color(0xff8f97e3),
  'cat-8': Color(0xffdb8374),
  'cat-other': Color(0xffa8a59e),
};
const darkColors = <String, Color>{
  'segment-track': Color.from(alpha: .08, red: 1, green: 1, blue: 1),
  'segment-thumb': Color(0xff2c2c2a),
  'surface-0': Color(0xff121211),
  'surface-1': Color(0xff181817),
  'surface-2': Color(0xff1e1e1c),
  'surface-3': Color(0xff262624),
  'clay': Color(0xffd97757),
  'clay-hover': Color(0xffe3876a),
  'clay-wash': Color(0xff2b1e19),
  'clay-ink': Color(0xffe8957a),
  'clay-glow': Color(0x4cd97757),
  'clay-20': Color(0xff3a2a24),
  'clay-35': Color(0xff55382e),
  'clay-55': Color(0xff7d4a3a),
  'clay-75': Color(0xffa35f49),
  'tile': Color(0xfff3f2ee),
  'tile-ring': Color(0x1affffff),
  'tile-dark': Color(0xff2e2e33),
  'tile-dark-ring': Color(0x52ffffff),
  'tile-ink': Color(0xffffffff),
  'heat-0': Color(0x0fffffff),
  'heat-1': Color(0xff4a2e24),
  'heat-2': Color(0xff7a4433),
  'heat-3': Color(0xffb25d43),
  'heat-4': Color(0xffe3876a),
  'line': Color(0x14ffffff),
  'line-soft': Color(0x0bffffff),
  'line-strong': Color(0x29ffffff),
  'line-heavy': Color(0x4cffffff),
  'text': Color(0xffeeede9),
  'text-secondary': Color(0xffb3b1ab),
  'text-muted': Color(0xff8e8c86),
  'text-faint': Color(0xff66645f),
  'mark-bar': Color(0xff8e8c86),
  'text-inverse': Color(0xff151515),
  'ok': Color(0xff6fb98a),
  'warn': Color(0xffd6a663),
  'danger': Color(0xffe0806b),
  'fill-hover': Color(0x0dffffff),
  'fill-active': Color(0x17ffffff),
  'tool-claude': Color(0xffd97757),
  'tool-codex': Color(0xff3b82f6),
  'tool-qwen': Color(0xff7c5cff),
  'tool-dsh': Color(0xff4d6bfe),
  'tool-grok': Color(0xff111111),
  'tool-aider': Color(0xff16a34a),
  'tool-pi': Color(0xffe0478c),
  'tool-hermes': Color(0xff7aa83b),
  'tool-cline': Color(0xff6b7280),
  'tool-gemini': Color(0xff14a6b8),
  'tool-cursor': Color(0xff111111),
  'tool-opencode': Color(0xffe9a23b),
  'tool-kilo': Color(0xffb39b00),
  'tool-openhands': Color(0xff84786b),
  'tool-goose': Color(0xff262626),
  'tool-zed': Color(0xff084ccf),
  'tool-continue': Color(0xff6b5bd6),
  'tool-trae': Color(0xffef4444),
  'tool-copilot': Color(0xff6e40c9),
  'tool-openclaw': Color(0xffef4444),
  'tool-mimo': Color(0xffff6900),
  'tool-kimi': Color(0xff8b7cf6),
  'tool-minimax': Color(0xfff43f5e),
  'tool-zcode': Color(0xff111111),
  'tool-codebuddy': Color(0xff6c5ce7),
  'cat-1': Color(0xff5698d3),
  'cat-2': Color(0xffc97c52),
  'cat-3': Color(0xff31a88d),
  'cat-4': Color(0xffb68a39),
  'cat-5': Color(0xffc275a1),
  'cat-6': Color(0xff71a25c),
  'cat-7': Color(0xff8989d4),
  'cat-8': Color(0xffce7573),
  'cat-other': Color(0xff77746d),
};
