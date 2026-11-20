import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/tool_order.dart';
import 'package:token_lens_app/stats/theme/palette.dart';

void main() {
  const brands = {
    'claude': (Color(0xffd97757), Color(0xffe08a6d)),
    'codex': (Color(0xff6c9cf2), Color(0xff82acf5)),
    'qwen': (Color(0xff5a5ae8), Color(0xff7878ef)),
    'antigravity': (Color(0xff3aa86e), Color(0xff4cb980)),
    'dsh': (Color(0xff4d68e8), Color(0xff6a80ee)),
    'gemini': (Color(0xffb56fbf), Color(0xffc585cd)),
    'copilot': (Color(0xffe0679a), Color(0xffe87fab)),
    'openclaw': (Color(0xffe2574c), Color(0xffe8706a)),
    'codebuddy': (Color(0xff7560e8), Color(0xff8a79ee)),
    'zcode': (Color(0xff4f68e6), Color(0xff6b80ec)),
    'minimax': (Color(0xffe2557f), Color(0xffe9708f)),
    'trae': (Color(0xff2fae74), Color(0xff45be86)),
    'openhands': (Color(0xffc9a53a), Color(0xffd6b552)),
    'aider': (Color(0xff3e9e62), Color(0xff52ad74)),
    'continue': (Color(0xff6b5bd6), Color(0xff8073dd)),
    'zed': (Color(0xff3d6fd1), Color(0xff5583da)),
  };
  const ink = [
    (Color(0xff3b3936), Color(0xffe4e1da)),
    (Color(0xff66635d), Color(0xffbdb9b1)),
    (Color(0xff8f8c85), Color(0xff96928a)),
    (Color(0xffb3b0a8), Color(0xff76726b)),
    (Color(0xffcbc8c0), Color(0xff5e5b55)),
  ];
  for (final dark in [false, true]) {
    test('工具色与墨色档位 dark=$dark', () {
      final colors = assignToolColors([
        for (final id in brands.keys) (id, 1000),
        ('future-tool', 3),
        ('cursor', 8),
        ('pi', 20),
        ('kimi', 12),
        ('goose', 6),
        ('opencode', 10),
        ('cursor', 4),
      ], LensPalette(dark));
      Color choose((Color, Color) colors) => dark ? colors.$2 : colors.$1;
      expect(colors, {
        for (final entry in brands.entries) entry.key: choose(entry.value),
        'pi': choose(ink[0]),
        'cursor': choose(ink[1]),
        'kimi': choose(ink[2]),
        'opencode': choose(ink[3]),
        'goose': choose(ink[4]),
        'future-tool': choose(ink[4]),
      });
    });
  }
}
