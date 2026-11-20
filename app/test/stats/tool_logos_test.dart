import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/tools.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

const logoDir = 'assets/tool-logos';
const newIcons = [
  'qwen',
  'antigravity',
  'minimax',
  'openhands',
  'trae',
  'commandcode',
  'goose',
  'kilo',
];

void main() {
  testWidgets('登记的 PNG 文件均已打包，SVG 来源目录不入包', (tester) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets();
    for (final entry in tools.entries) {
      final logo = entry.value.logo;
      if (logo == null) continue;
      final path = '$logoDir/$logo';
      expect(File(path).existsSync(), isTrue, reason: entry.key);
      expect(assets, contains(path));
    }
    expect(assets.where((path) => path.startsWith('$logoDir/src/')), isEmpty);
  });

  testWidgets('八个工具加载新 PNG 且无字母', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Wrap(
            children: [
              for (final id in newIcons) ToolTile(id, key: ValueKey(id)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final id in newIcons) {
      final tile = find.byKey(ValueKey(id));
      final image = find.descendant(of: tile, matching: find.byType(Image));
      expect(image, findsOneWidget, reason: id);
      expect(tester.widget<Image>(image).image, AssetImage('$logoDir/$id.png'));
      expect(
        find.descendant(of: tile, matching: find.text(toolOf(id).letter)),
        findsNothing,
      );
      expect(toolOf(id).darkGlyph, isFalse);
    }
  });
}
